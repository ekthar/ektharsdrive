import EktharDriveCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(DriveManager.self) private var drives
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 300)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
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
            Image(systemName: "laptopcomputer").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("This Mac").font(.caption.weight(.semibold))
                Text("\(ByteFormat.string(DiskSpace.freeBytes(at: drives.paths.cacheRoot.path))) free").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            SettingsLink { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Settings")
        }
        .padding(10)
        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous).strokeBorder(Theme.hairline))
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
                        ProgressView(value: f).controlSize(.mini).tint(f > 0.9 ? .red : .accentColor).frame(maxWidth: 90)
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
                StatusDot(health: rt.health)
            }
        }
    }
}
