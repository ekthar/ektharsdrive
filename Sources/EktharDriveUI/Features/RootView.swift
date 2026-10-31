import EktharDriveCore
import SwiftUI

public struct RootView: View {
    public init() {}
    @Environment(AppModel.self) private var model
    @Environment(DriveManager.self) private var drives
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    public var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 300)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Theme.canvas)
                .animation(Theme.spring, value: model.selection)
        }
        .background(GeometryReader { g in
            Color.clear.onChange(of: g.size.width, initial: true) { _, w in if abs(model.windowWidth - w) > 1 { model.windowWidth = w } }
        })
        .sheet(isPresented: $model.showSetup) {
            SetupWizardView().environment(model).environment(drives)
        }
        .onAppear {
            AppActions.openWindowAction = openWindow
            AppActions.openSettingsAction = openSettings
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.selection ?? .dashboard {
        case .dashboard: DashboardView()
        case .drive(let id): DriveBrowserView(browser: model.browser(for: id)).id(id)
        case .collection(let id, let kind): CollectionView(driveID: id, kind: kind).id("\(id)-\(kind.rawValue)")
        case .transfers: TransfersView()
        case .cache: CacheView()
        case .activity: ActivityView()
        }
    }
}

/// Finder-style sidebar: locations with eject buttons, management items, and a storage footer.
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(DriveManager.self) private var drives

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section("Ekthar Drive") {
                Label("Overview", systemImage: "square.grid.2x2").tag(SidebarItem.dashboard)
            }
            Section("Locations") {
                ForEach(drives.drives) { d in
                    DriveSidebarRow(drive: d).tag(SidebarItem.drive(d.id))
                }
            }
            if let g = drives.googleDrive, drives.state(g.id).connection.isConfigured {
                Section("Google") {
                    Label("Starred", systemImage: "star").tag(SidebarItem.collection(g.id, .starred))
                    Label("Trash", systemImage: "trash").tag(SidebarItem.collection(g.id, .trash))
                }
            }
            Section("Activity") {
                HStack {
                    Label("Transfers", systemImage: "arrow.up.arrow.down.circle")
                    Spacer()
                    let n = drives.allActiveTransfers.count
                    if n > 0 { Text("\(n)").font(.caption2.weight(.semibold)).monospacedDigit().padding(.horizontal, 6).padding(.vertical, 1).background(.tint.opacity(0.18), in: Capsule()) }
                }
                .tag(SidebarItem.transfers)
                Label("Cache", systemImage: "internaldrive").tag(SidebarItem.cache)
                Label("History", systemImage: "clock.arrow.circlepath").tag(SidebarItem.activity)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { footer }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.accentGradient).frame(width: 26, height: 26)
                Image(systemName: "laptopcomputer").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("This Mac").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.ink)
                Text("\(ByteFormat.string(DiskSpace.freeBytes(at: drives.paths.cacheRoot.path))) free").font(.system(size: 10.5)).foregroundStyle(Theme.inkSecondary).monospacedDigit()
            }
            Spacer()
            SettingsLink { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Settings")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.canvas.opacity(0.85)).shadow(color: .black.opacity(0.05), radius: 6, y: 2))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
        .padding(10)
    }
}

struct DriveSidebarRow: View {
    @Environment(DriveManager.self) private var drives
    let drive: DriveConfiguration

    var body: some View {
        let rt = drives.state(drive.id)
        HStack(spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(drive.name)
                    if let f = rt.usage?.usedFraction {
                        CapacityBar(fraction: f, height: 3).frame(maxWidth: 96)
                    }
                }
            } icon: { Image(systemName: drive.provider.symbol) }
            Spacer(minLength: 4)
            switch rt.phase {
            case .mounted:
                Button { Task { await drives.unmount(drive.id, waitForUploads: false) } } label: {
                    Image(systemName: "eject.fill").font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Eject \(drive.name)")
            case .mounting, .unmounting, .waitingForUploads, .retrying:
                ProgressView().controlSize(.mini)
            default:
                StatusDot(health: rt.health, pulsing: rt.phase.isBusy)
            }
        }
    }
}
