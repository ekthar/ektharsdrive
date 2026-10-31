import EktharDriveCore
import SwiftUI

struct MenuBarIcon: View {
    let drives: DriveManager
    var body: some View {
        switch drives.overallHealth {
        case .error: Image(systemName: "externaldrive.badge.exclamationmark")
        case .degraded: Image(systemName: "externaldrive.badge.timemachine")
        default:
            Image(systemName: drives.allActiveTransfers.isEmpty ? "externaldrive.connected.to.line.below" : "arrow.up.arrow.down.circle")
        }
    }
}

/// Menu-bar menu. Every line is read from DriveManager state; nothing is hardcoded.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(DriveManager.self) private var drives

    var body: some View {
        Text("EKTHAR DRIVE")
        ForEach(drives.drives) { d in
            let rt = drives.state(d.id)
            Button {
                if rt.phase.isActive { AppActions.openInFinder(rt.mountPath) } else { model.selection = .drive(d.id); AppActions.openDashboard() }
            } label: {
                Text("\(d.name)    \(statusText(rt))")
            }
        }
        Divider()
        let active = drives.allActiveTransfers
        if active.isEmpty {
            Text("No active transfers")
        } else {
            Text("Active transfers")
            ForEach(active.prefix(6)) { t in
                Text("\(t.direction == .upload ? "Uploading" : "Downloading") \(t.name)\(t.fraction.map { "  \(Int($0 * 100))%" } ?? "")")
            }
            if active.count > 6 { Text("and \(active.count - 6) more") }
        }
        Divider()
        Text("Cache usage")
        ForEach(drives.drives) { d in
            Text("\(d.name): \(ByteFormat.string(drives.state(d.id).cache?.bytesUsed))")
        }
        Divider()
        Button("Open Dashboard") { model.selection = .dashboard; AppActions.openDashboard() }
            .keyboardShortcut("d")
        Button("Mount All") { Task { await drives.mountAll() } }
            .disabled(!drives.drives.contains { drives.state($0.id).connection.isConfigured && !drives.state($0.id).phase.isActive })
        Button("Unmount All") { Task { await drives.unmountAll(waitForUploads: true) } }
            .disabled(!drives.drives.contains { drives.state($0.id).phase.isActive })
        Button("Settings…") { model.selection = .general; AppActions.openDashboard() }
            .keyboardShortcut(",")
        Divider()
        Button("Quit Ekthar Drive") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func statusText(_ rt: DriveRuntime) -> String {
        switch rt.phase {
        case .mounted:
            if let c = rt.cache, c.pendingUploads > 0 { return "Mounted, \(c.pendingUploads) uploading" }
            return rt.lastError == nil ? "Mounted" : "Mounted (\(rt.lastError!.title))"
        case .unmounted:
            if case .failed(let e) = rt.connection { return e.title }
            return rt.connection.isConfigured ? "Connected, not mounted" : "Not connected"
        default: return rt.phase.label
        }
    }
}
