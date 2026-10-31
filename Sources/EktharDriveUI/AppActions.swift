import AppKit
import EktharDriveCore
import SwiftUI

public enum AppWindow {
    public static let main = "main"
}

@MainActor
public enum AppActions {
    public static var openWindowAction: OpenWindowAction?
    public static var openSettingsAction: OpenSettingsAction?

    public static func openSettings(_ tab: SettingsTab, model: AppModel) {
        model.settingsTab = tab
        NSApp.activate()
        openSettingsAction?()
    }

    public static func openDashboard() {
        NSApp.setActivationPolicy(.regular)
        if let w = NSApp.windows.first(where: { $0.canBecomeMain && $0.identifier?.rawValue.contains(AppWindow.main) == true }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            openWindowAction?(id: AppWindow.main)
        }
        NSApp.activate()
    }

    public static func openInFinder(_ path: String?) {
        guard let path, MountTable.isMounted(path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path, isDirectory: true)])
    }
}
