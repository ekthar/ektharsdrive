import AppKit
import EktharDriveCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var lockFD: Int32 = -1
    private var terminationApproved = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard acquireSingleInstanceLock() else {
            if let id = Bundle.main.bundleIdentifier,
               let other = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { $0 != .current }) {
                other.activate()
            }
            let alert = NSAlert()
            alert.messageText = "Ekthar Drive is already running"
            alert.informativeText = "Only one copy can manage your drives at a time. Use the menu bar icon of the running copy."
            alert.runModal()
            exit(0)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.drives.systemDidWake() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            // Keep running in the menu bar after the window closes; drop the Dock icon.
            DispatchQueue.main.async {
                if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) { NSApp.setActivationPolicy(.accessory) }
            }
        }
        Task {
            await model.start()
            if model.drives.settings.startMinimized && model.drives.settings.setupCompleted {
                for w in NSApp.windows where w.canBecomeMain { w.close() }
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppActions.openDashboard() }
        return true
    }

    /// Never quit with uploads pending without the user choosing what happens.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationApproved { return .terminateNow }
        Task { @MainActor in
            let drives = model.drives
            switch await drives.terminationCheck() {
            case .safe:
                await drives.shutdown()
                finishTermination(true)
            case .pendingUploads(let n):
                NSApp.activate()
                let alert = NSAlert()
                alert.messageText = "\(n) upload\(n == 1 ? " is" : "s are") still in progress"
                alert.informativeText = "Quitting now will not lose data. You can wait for uploads to finish and unmount, or leave the volumes running in the background; Ekthar Drive reattaches to them next time it opens."
                alert.addButton(withTitle: "Wait for Uploads, Then Quit")
                alert.addButton(withTitle: "Quit and Keep Volumes Running")
                alert.addButton(withTitle: "Cancel")
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    await drives.shutdown()
                    finishTermination(true)
                case .alertSecondButtonReturn:
                    drives.detachForQuit()
                    finishTermination(true)
                default:
                    finishTermination(false)
                }
            }
        }
        return .terminateLater
    }

    private func finishTermination(_ quit: Bool) {
        terminationApproved = quit
        NSApp.reply(toApplicationShouldTerminate: quit)
    }

    /// flock on a file in our 0700 run directory; works for bundled and `swift run` builds alike.
    private func acquireSingleInstanceLock() -> Bool {
        let path = model.drives.paths.lockFileURL.path
        lockFD = open(path, O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0 else { return true }
        return flock(lockFD, LOCK_EX | LOCK_NB) == 0
    }
}

@MainActor
enum AppActions {
    static var openWindowAction: OpenWindowAction?

    static func openDashboard() {
        NSApp.setActivationPolicy(.regular)
        if let w = NSApp.windows.first(where: { $0.canBecomeMain && $0.identifier?.rawValue.contains(AppWindow.main) == true }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            openWindowAction?(id: AppWindow.main)
        }
        NSApp.activate()
    }

    static func openInFinder(_ path: String?) {
        guard let path, MountTable.isMounted(path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
