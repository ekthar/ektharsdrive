import EktharDriveCore
import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @Environment(DriveManager.self) private var drives

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                warnings
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], spacing: 16) {
                    ForEach(drives.drives) { d in DriveCard(drive: d) }
                }
                HStack(alignment: .top, spacing: 16) {
                    transfersCard
                    activityCard
                }
            }
            .padding(28)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Overview")
        .toolbar {
            ToolbarItemGroup {
                Button { Task { await drives.mountAll() } } label: { Image(systemName: "play.circle") }
                    .help("Mount every connected drive")
                Button { Task { await drives.unmountAll(waitForUploads: true) } } label: { Image(systemName: "eject") }
                    .help("Eject every drive after uploads finish")
                Button { Task { await drives.refreshAll() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(drives.overallHealth.color.opacity(0.14)).frame(width: 56, height: 56)
                Image(systemName: headerSymbol).font(.system(size: 26, weight: .semibold)).foregroundStyle(drives.overallHealth.color)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(headline).font(.title.weight(.semibold))
                Text("Your storage. One native experience.").foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 10) {
                Pill(text: "\(drives.connectedCount) of \(drives.drives.count) connected", color: drives.connectedCount > 0 ? .green : .secondary)
                Pill(text: "\(ByteFormat.string(totalCache)) cached")
            }
        }
    }

    private var headerSymbol: String {
        switch drives.overallHealth {
        case .healthy: "checkmark"
        case .inactive: "externaldrive"
        default: "exclamationmark"
        }
    }

    private var headline: String {
        switch drives.overallHealth {
        case .healthy: "Everything is in sync"
        case .degraded: "Some drives need a moment"
        case .error: "A drive needs attention"
        case .inactive: drives.connectedCount == 0 ? "Connect a drive to begin" : "No drives mounted"
        }
    }

    @ViewBuilder private var warnings: some View {
        if let deps = drives.dependencies, deps.rclone == nil {
            ErrorBanner(error: .dependencyMissing(.rclone, detail: "Ekthar Drive uses rclone to talk to your storage. Install it in Settings > Advanced."),
                        actions: [("Open Settings", { AppActions.openSettings(.advanced, model: model) })])
        }
        if !drives.isOnline { ErrorBanner(error: .networkUnavailable) }
        if let w = drives.diskWarning {
            ErrorBanner(error: .localDiskFull(freeBytes: w.freeBytes), actions: [("Manage Cache", { model.selection = .cache })])
        }
        if let e = model.fatalError ?? drives.startupError { ErrorBanner(error: .unknown(e)) }
    }

    private var transfersCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Transfers").font(.headline)
                Spacer()
                Button("See All") { model.selection = .transfers }.buttonStyle(.link)
            }
            let active = drives.allActiveTransfers.prefix(5)
            if active.isEmpty {
                Label("No transfers in progress", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            } else {
                ForEach(Array(active)) { t in TransferRow(transfer: t, driveName: drives.drive(t.driveID)?.name ?? t.driveID) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard()
    }

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent activity").font(.headline)
                Spacer()
                Button("See All") { model.selection = .activity }.buttonStyle(.link)
            }
            let events = drives.recentActivity.prefix(6)
            if events.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
            ForEach(Array(events), id: \.timestampID) { e in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: e.severity.symbol).foregroundStyle(e.severity.color).font(.caption)
                    Text(e.message).font(.callout).lineLimit(2)
                    Spacer()
                    Text(e.timestamp.relative).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard()
    }

    private var totalCache: Int64 { drives.drives.compactMap { drives.state($0.id).cache?.bytesUsed }.reduce(0, +) }
}

/// Large drive card: icon tile, status, capacity ring, and the one action that matters right now.
struct DriveCard: View {
    @Environment(AppModel.self) private var model
    @Environment(DriveManager.self) private var drives
    let drive: DriveConfiguration
    @State private var hovering = false

    var body: some View {
        let rt = drives.state(drive.id)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                DriveIconTile(provider: drive.provider, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(drive.name).font(.title3.weight(.semibold))
                    StatusLabel(text: rt.phase == .unmounted ? rt.connection.label : rt.phase.label, health: rt.health).font(.callout)
                }
                Spacer()
                CapacityRing(usage: rt.usage, size: 58, lineWidth: 6)
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Available").font(.caption).foregroundStyle(.secondary)
                    Text(ByteFormat.string(rt.usage?.free)).font(.headline).monospacedDigit()
                }
                Spacer()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cache").font(.caption).foregroundStyle(.secondary)
                    Text(ByteFormat.string(rt.cache?.bytesUsed)).font(.headline).monospacedDigit()
                }
                Spacer()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Uploading").font(.caption).foregroundStyle(.secondary)
                    Text("\(rt.cache?.pendingUploads ?? 0)").font(.headline).monospacedDigit()
                }
            }
            HStack {
                Button { model.selection = .drive(drive.id) } label: {
                    Label(rt.phase.isActive ? "Browse" : "Open", systemImage: "folder").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                if rt.phase.isActive {
                    Button { Task { await drives.unmount(drive.id, waitForUploads: false) } } label: {
                        Label("Eject", systemImage: "eject").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                } else if rt.connection.isConfigured {
                    Button { Task { await drives.mount(drive.id) } } label: {
                        Label("Mount", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(rt.phase == .mounting)
                }
            }
        }
        .premiumCard(radius: 20, padding: 20)
        .scaleEffect(hovering ? 1.01 : 1)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
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
