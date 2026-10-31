import EktharDriveCore
import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @Environment(DriveManager.self) private var drives

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                warnings
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    MetricTile(title: "Connected", value: "\(drives.connectedCount) of \(drives.drives.count)", symbol: "link")
                    MetricTile(title: "Mounted", value: "\(drives.drives.filter { drives.state($0.id).phase.isActive }.count)", symbol: "externaldrive.connected.to.line.below")
                    MetricTile(title: "Active transfers", value: "\(drives.allActiveTransfers.count)", symbol: "arrow.up.arrow.down",
                               detail: pendingDetail)
                    MetricTile(title: "Cache", value: ByteFormat.string(totalCache), symbol: "internaldrive",
                               detail: "\(ByteFormat.string(DiskSpace.freeBytes(at: drives.paths.cacheRoot.path))) free on this Mac")
                }
                HStack(alignment: .top, spacing: 12) {
                    ForEach(drives.drives) { d in DriveSummaryCard(drive: d) }
                }
                HStack(alignment: .top, spacing: 12) {
                    Card(title: "Transfers") {
                        let active = drives.allActiveTransfers.prefix(5)
                        if active.isEmpty {
                            Text("No transfers in progress.").foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(active)) { t in TransferRow(transfer: t, driveName: drives.drive(t.driveID)?.name ?? t.driveID) }
                        }
                    }
                    Card(title: "Recent activity") {
                        let events = drives.recentActivity.prefix(6)
                        if events.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
                        ForEach(Array(events), id: \.timestampID) { e in
                            HStack(alignment: .firstTextBaseline) {
                                Image(systemName: e.severity.symbol).foregroundStyle(e.severity.color).font(.caption)
                                Text(e.message).font(.callout).lineLimit(2)
                                Spacer()
                                Text(e.timestamp.relative).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Dashboard")
        .toolbar {
            ToolbarItemGroup {
                Button { Task { await drives.mountAll() } } label: { Label("Mount All", systemImage: "play.circle") }
                    .help("Mount every connected drive")
                Button { Task { await drives.unmountAll(waitForUploads: true) } } label: { Label("Unmount All", systemImage: "eject") }
                    .help("Unmount every drive after pending uploads finish")
                Button { Task { await drives.refreshAll() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: drives.overallHealth == .healthy ? "checkmark.circle.fill" : drives.overallHealth == .inactive ? "circle.dashed" : "exclamationmark.circle.fill")
                .font(.system(size: 30)).foregroundStyle(drives.overallHealth.color)
            VStack(alignment: .leading) {
                Text(headline).font(.title2.weight(.semibold))
                Text("Your storage. One native experience.").foregroundStyle(.secondary)
            }
        }
    }

    private var headline: String {
        switch drives.overallHealth {
        case .healthy: "All drives are working"
        case .degraded: "Some drives need a moment"
        case .error: "A drive needs attention"
        case .inactive: drives.connectedCount == 0 ? "Connect a drive to get started" : "No drives mounted"
        }
    }

    @ViewBuilder private var warnings: some View {
        if let deps = drives.dependencies, deps.rclone == nil {
            ErrorBanner(error: .dependencyMissing(.rclone, detail: "Ekthar Drive uses rclone to talk to your storage. Install it in Settings > Advanced."),
                        actions: [("Open Advanced Settings", { model.selection = .advanced })])
        }
        if !drives.isOnline {
            ErrorBanner(error: .networkUnavailable)
        }
        if let w = drives.diskWarning {
            ErrorBanner(error: .localDiskFull(freeBytes: w.freeBytes), actions: [("Manage Cache", { model.selection = .cache })])
        }
        if let e = model.fatalError ?? drives.startupError {
            ErrorBanner(error: .unknown(e))
        }
    }

    private var totalCache: Int64 { drives.drives.compactMap { drives.state($0.id).cache?.bytesUsed }.reduce(0, +) }
    private var pendingDetail: String? {
        let pending = drives.drives.compactMap { drives.state($0.id).cache?.pendingUploads }.reduce(0, +)
        return pending > 0 ? "\(pending) upload\(pending == 1 ? "" : "s") pending" : nil
    }
}

struct DriveSummaryCard: View {
    @Environment(AppModel.self) private var model
    @Environment(DriveManager.self) private var drives
    let drive: DriveConfiguration

    var body: some View {
        let rt = drives.state(drive.id)
        Button { model.selection = .drive(drive.id) } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: drive.provider.symbol).font(.title2).foregroundStyle(.tint)
                    VStack(alignment: .leading) {
                        Text(drive.name).font(.headline)
                        StatusLabel(text: rt.phase.isActive || rt.phase != .unmounted ? rt.phase.label : rt.connection.label, health: rt.health)
                            .font(.caption)
                    }
                    Spacer()
                }
                CapacityView(usage: rt.usage, compact: true)
                HStack {
                    Label(ByteFormat.string(rt.cache?.bytesUsed), systemImage: "internaldrive")
                    Spacer()
                    if let p = rt.mountPath, rt.phase.isActive { Text(p).lineLimit(1).truncationMode(.middle) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

extension Severity {
    var symbol: String {
        switch self {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }

    var color: Color {
        switch self {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}

extension ActivityEvent {
    var timestampID: String { "\(id ?? 0)-\(timestamp.timeIntervalSince1970)" }
}
