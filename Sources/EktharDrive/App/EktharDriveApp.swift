import EktharDriveCore
import EktharDriveUI
import SwiftUI

@main
struct EktharDriveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Ekthar Drive", id: AppWindow.main) {
            RootView()
                .environment(appDelegate.model)
                .environment(appDelegate.model.drives)
                .frame(minWidth: Layout.windowMinWidth, minHeight: 600)
        }
        .defaultSize(width: 1080, height: 720)
        .windowToolbarStyle(.unified)
        .commands {
            BrowserCommands()
            CommandMenu("Drives") {
                Button("Mount All") { Task { await appDelegate.model.drives.mountAll() } }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Unmount All") { Task { await appDelegate.model.drives.unmountAll(waitForUploads: true) } }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                Divider()
                Button("Refresh") { Task { await appDelegate.model.drives.refreshAll() } }
                    .keyboardShortcut("r")
            }
        }

        Settings {
            SettingsRoot()
                .environment(appDelegate.model)
                .environment(appDelegate.model.drives)
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(appDelegate.model)
                .environment(appDelegate.model.drives)
        } label: {
            MenuBarIcon(drives: appDelegate.model.drives)
        }
        .menuBarExtraStyle(.menu)
    }
}
