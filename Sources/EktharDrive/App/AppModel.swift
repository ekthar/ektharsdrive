import AppKit
import EktharDriveCore
import Observation
import ServiceManagement
@preconcurrency import UserNotifications

/// Builds the object graph once and holds app-level UI state.
@MainActor
@Observable
final class AppModel {
    let drives: DriveManager
    let loginItems = LoginItemController()
    var selection: SidebarItem? = .dashboard
    var showSetup = false
    var fatalError: String?

    init() {
        let paths = AppPaths.standard()
        try? paths.prepare()
        let database: AppDatabase
        do {
            database = try AppDatabase(url: paths.databaseURL)
        } catch {
            // Last resort: in-memory-like temp DB so the UI can still explain the problem.
            let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("ekthar-drive-fallback-\(UUID().uuidString).sqlite")
            database = try! AppDatabase(url: fallback)
            fatalError = "The local database could not be opened (\(error.localizedDescription)). Settings will not be saved this session."
        }
        drives = DriveManager(paths: paths, secrets: KeychainStore(), database: database, notifier: UserNotifier())
    }

    func start() async {
        await drives.start()
        applyTheme()
        if !drives.settings.setupCompleted { showSetup = true }
        loginItems.refresh()
    }

    func applyTheme() {
        switch drives.settings.theme {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        var s = drives.settings
        change(&s)
        drives.saveSettings(s)
        applyTheme()
    }
}

enum SidebarItem: Hashable {
    case dashboard
    case drive(String)
    case transfers, cache, activity
    case accounts, general, advanced, about
}

/// Launch at login through SMAppService (macOS 13+). Works for the bundled app; reports why when it cannot.
@MainActor
@Observable
final class LoginItemController {
    private(set) var enabled = false
    private(set) var message: String?

    func refresh() {
        let status = SMAppService.mainApp.status
        enabled = status == .enabled
        message = status == .requiresApproval ? "Approve Ekthar Drive in System Settings > General > Login Items." : nil
    }

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            message = nil
        } catch {
            message = Bundle.main.bundleIdentifier == nil
                ? "Launch at login is available when Ekthar Drive runs as an installed app."
                : "Could not change the login item: \(error.localizedDescription)"
        }
        refresh()
    }
}

/// Local notifications for errors. Requires a bundled app (UserNotifications needs a bundle identifier).
struct UserNotifier: Notifier {
    func notify(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
