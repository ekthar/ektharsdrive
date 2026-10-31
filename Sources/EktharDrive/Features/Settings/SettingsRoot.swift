import EktharDriveCore
import SwiftUI

enum SettingsTab: Hashable { case accounts, general, advanced, about }

/// Standard macOS Settings window (⌘,).
struct SettingsRoot: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            AccountsView().tabItem { Label("Accounts", systemImage: "person.crop.circle") }.tag(SettingsTab.accounts)
            GeneralSettingsView().tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            AdvancedSettingsView().tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }.tag(SettingsTab.advanced)
            AboutView().tabItem { Label("About", systemImage: "info.circle") }.tag(SettingsTab.about)
        }
        .frame(width: 680, height: 560)
    }
}
