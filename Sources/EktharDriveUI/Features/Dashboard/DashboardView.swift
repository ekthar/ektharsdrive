import EktharDriveCore
import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @Environment(DriveManager.self) private var drives

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                hero.appearAnimation(index: 0)
                warnings
                VStack(alignment: .leading, spacing: 12) {
                    Text("Locations").eyebrowStyle()
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 18)], spacing: 18) {
                        ForEach(Array(drives.drives.enumerated()), id: \.element.id) { i, d in
                            DriveCard(drive: d).appearAnimation(index: i + 1)
                        }
                    }
                }
                HStack(spacing: 14) {
                    MetricTile(title: "Connected", value: "\(drives.connectedCount)/\(drives.drives.count)", symbol: "link", detail: "drives")
                    MetricTile(title: "Transfers", value: "\(drives.allActiveTransfers.count)", symbol: "arrow.up.arrow.down", detail: pendingDetail)
                    MetricTile(title: "Cached", value: ByteFormat.string(totalCache), symbol: "internaldrive", detail: "on this Mac")
                    MetricTile(title: "This Mac", value: ByteFormat.string(DiskSpace.freeBytes(at: drives.paths.cacheRoot.path)), symbol: "laptopcomputer", detail: "free")
                }
                .appearAnimation(index: 3)
                HStack(alignment: .top, spacing: 18) {
                    transfersCard
                    activityCard
                }
                .appearAnimation(index: 4)
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 30)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
            .animation(Theme.spring, value: drives.overallHealth)
        }
        .background(Theme.canvas)
        .navigationTitle("Overview")
        .toolbar {
            ToolbarItemGroup {
                Button { Task { await drives.mountAll() } } label: { Label("Mount All", systemImage: "play.circle") }
                    .help("Mount every connected drive")
                Button { Task { await drives.unmountAll(waitForUploads: true) } } label: { Label("Eject All", systemImage: "eject") }
                    .help("Eject every drive after uploads finish")
                Button { Task { await drives.refreshAll() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Refresh")
            }
        }
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(greeting).eyebrowStyle()
                Text(headline).displayStyle().contentTransition(.opacity)
                Text("Your storage. One native experience.").font(.body13).secondaryText()
            }
            Spacer()
            HealthBadge(level: drives.overallHealth)
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
    }

    private var headline: String {
        switch drives.overallHealth {
        case .healthy: "Everything is in sync"
        case .degraded: "Some drives need a moment"
        case .error: "A drive needs attention"
        case .inactive: drives.connectedCount == 0 ? "Connect a drive to begin" : "Your drives are resting"
        }
    }

    @ViewBuilder private var warnings: some View {
        VStack(spacing: 10) {
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
        .animation(Theme.spring, value: drives.isOnline)
    }

    private var transfersCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Transfers").font(.titleSmall).foregroundStyle(Theme.ink)
                Spacer()
                Button("See all") { model.selection = .transfers }.buttonStyle(.inlineLink)
            }
            let active = drives.allActiveTransfers.prefix(5)
            if active.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                    Text("Nothing moving right now").font(.body13).secondaryText()
                }
                .padding(.vertical, 6)
            } else {
                ForEach(Array(active)) { t in TransferRow(transfer: t, driveName: drives.drive(t.driveID)?.name ?? t.driveID) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Theme.spring, value: drives.allActiveTransfers.map(\.id))
        .premiumCard(padding: 20)
    }

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent activity").font(.titleSmall).foregroundStyle(Theme.ink)
                Spacer()
                Button("See all") { model.selection = .activity }.buttonStyle(.inlineLink)
            }
            let events = drives.recentActivity.prefix(6)
            if events.isEmpty { Text("Nothing yet.").font(.body13).secondaryText() }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(events.enumerated()), id: \.element.timestampID) { i, e in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(spacing: 0) {
                            Circle().fill(e.severity.color).frame(width: 7, height: 7).padding(.top, 5)
                            if i < events.count - 1 { Rectangle().fill(Theme.hairline).frame(width: 1).frame(maxHeight: .infinity) }
                        }
                        .frame(width: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.message).font(.system(size: 12.5)).foregroundStyle(Theme.ink).lineLimit(2)
                            Text(e.timestamp.relative).font(.system(size: 11)).foregroundStyle(Theme.inkTertiary)
                        }
                        .padding(.bottom, 10)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard(padding: 20)
    }

    private var totalCache: Int64 { drives.drives.compactMap { drives.state($0.id).cache?.bytesUsed }.reduce(0, +) }
    private var pendingDetail: String? {
        let pending = drives.drives.compactMap { drives.state($0.id).cache?.pendingUploads }.reduce(0, +)
        return pending > 0 ? "\(pending) uploading" : "all synced"
    }
}

/// Round badge on the right of the hero, tinted by overall health. Still: motion here would only distract.
struct HealthBadge: View {
    let level: HealthLevel

    var body: some View {
        ZStack {
            Circle().fill(level.color.opacity(0.08)).frame(width: 74, height: 74)
            Circle().fill(Theme.canvas).frame(width: 56, height: 56).shadow(color: .black.opacity(0.08), radius: 10, y: 5)
                .overlay(Circle().strokeBorder(Theme.hairline))
            Image(systemName: symbol).font(.system(size: 22, weight: .semibold)).foregroundStyle(level.color.gradient)
                .contentTransition(.symbolEffect(.replace))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Overall status: \(level.label)")
    }

    private var symbol: String {
        switch level {
        case .healthy: "checkmark"
        case .inactive: "moon.zzz"
        case .degraded: "hourglass"
        case .error: "exclamationmark"
        }
    }
}

/// Large drive card: glossy icon tile, status, animated capacity ring, key numbers and the one action that matters.
struct DriveCard: View {
    @Environment(AppModel.self) private var model
    @Environment(DriveManager.self) private var drives
    let drive: DriveConfiguration

    var body: some View {
        let rt = drives.state(drive.id)
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 14) {
                DriveIconTile(provider: drive.provider, size: 50)
                VStack(alignment: .leading, spacing: 5) {
                    Text(drive.name).font(.titleSmall).foregroundStyle(Theme.ink)
                    StatusLabel(text: rt.phase == .unmounted ? rt.connection.label : rt.phase.label, health: rt.health, pulsing: rt.phase.isBusy)
                }
                Spacer()
                CapacityRing(usage: rt.usage, size: 66, lineWidth: 7)
            }
            HStack(spacing: 0) {
                stat("Available", ByteFormat.string(rt.usage?.free))
                divider
                stat("Total", ByteFormat.string(rt.usage?.total))
                divider
                stat("Uploading", "\(rt.cache?.pendingUploads ?? 0)")
            }
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
            HStack(spacing: 10) {
                Button { model.selection = .drive(drive.id) } label: {
                    Label(rt.phase.isActive ? "Browse files" : "Open", systemImage: "folder").frame(maxWidth: .infinity)
                }
                .buttonStyle(.secondaryLarge)
                if rt.phase.isActive {
                    Button { Task { await drives.unmount(drive.id, waitForUploads: false) } } label: {
                        Label("Eject", systemImage: "eject.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.secondaryLarge)
                } else if rt.connection.isConfigured {
                    Button { Task { await drives.mount(drive.id) } } label: {
                        HStack(spacing: 6) {
                            if rt.phase == .mounting { ProgressView().controlSize(.small).tint(.white) } else { Image(systemName: "play.fill") }
                            Text(rt.phase == .mounting ? "Mounting…" : "Mount")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.primaryLarge)
                    .disabled(rt.phase == .mounting)
                }
            }
        }
        .premiumCard(radius: 22, padding: 22)
        .hoverLift()
        .animation(Theme.spring, value: rt.phase)
    }

    private var divider: some View { Rectangle().fill(Theme.hairline).frame(width: 1, height: 28) }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(Theme.ink)
                .contentTransition(.numericText())
            Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.inkTertiary)
        }
        .frame(maxWidth: .infinity)
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
        case .info: Theme.accent.opacity(0.55)
        case .warning: Theme.warning
        case .error: Theme.danger
        }
    }
}

extension ActivityEvent {
    var timestampID: String { "\(id ?? 0)-\(timestamp.timeIntervalSince1970)" }
}
