import EktharDriveCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(DriveManager.self) private var drives
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selection) {
                Section("Overview") {
                    Label("Dashboard", systemImage: "gauge.with.dots.needle.33percent").tag(SidebarItem.dashboard)
                }
                Section("Drives") {
                    ForEach(drives.drives) { d in
                        HStack {
                            Label(d.name, systemImage: d.provider.symbol)
                            Spacer()
                            StatusDot(health: drives.state(d.id).health)
                        }
                        .tag(SidebarItem.drive(d.id))
                    }
                }
                Section("Management") {
                    Label {
                        HStack {
                            Text("Transfers")
                            Spacer()
                            if !drives.allActiveTransfers.isEmpty {
                                Text("\(drives.allActiveTransfers.count)").font(.caption).monospacedDigit()
                                    .padding(.horizontal, 6).background(.quaternary, in: Capsule())
                            }
                        }
                    } icon: { Image(systemName: "arrow.up.arrow.down") }
                    .tag(SidebarItem.transfers)
                    Label("Cache", systemImage: "internaldrive").tag(SidebarItem.cache)
                    Label("Activity", systemImage: "list.bullet.rectangle").tag(SidebarItem.activity)
                }
                Section("Settings") {
                    Label("Accounts", systemImage: "person.crop.circle").tag(SidebarItem.accounts)
                    Label("General", systemImage: "gearshape").tag(SidebarItem.general)
                    Label("Advanced", systemImage: "wrench.and.screwdriver").tag(SidebarItem.advanced)
                    Label("About", systemImage: "info.circle").tag(SidebarItem.about)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .sheet(isPresented: $model.showSetup) {
            SetupWizardView().environment(model).environment(drives)
        }
        .onAppear { AppActions.openWindowAction = openWindow }
    }

    @ViewBuilder private var detail: some View {
        switch model.selection ?? .dashboard {
        case .dashboard: DashboardView()
        case .drive(let id): DriveDetailView(driveID: id).id(id)
        case .transfers: TransfersView()
        case .cache: CacheView()
        case .activity: ActivityView()
        case .accounts: AccountsView()
        case .general: GeneralSettingsView()
        case .advanced: AdvancedSettingsView()
        case .about: AboutView()
        }
    }
}
