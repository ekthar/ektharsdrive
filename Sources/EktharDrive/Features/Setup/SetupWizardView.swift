import EktharDriveCore
import SwiftUI

/// First-launch setup. Every "connected" or "mounted" state shown here comes from a real check.
struct SetupWizardView: View {
    @Environment(AppModel.self) private var model
    @Environment(DriveManager.self) private var drives
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var installing = false
    @State private var installStatus: String?
    @State private var installError: DriveError?
    @State private var mounting = false

    private let titles = ["Welcome", "How it works", "Google Drive", "Oracle server", "Dependencies", "Cache", "Mount", "Finish"]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(titles.indices, id: \.self) { i in
                    Capsule().fill(i <= step ? Color.accentColor : Color.secondary.opacity(0.25)).frame(height: 4)
                }
            }
            .padding([.horizontal, .top], 24)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(titles[step]).font(.title.weight(.semibold))
                    page
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            Divider()
            HStack {
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                if step == 2 || step == 3 { Button("Set Up Later") { step += 1 } }
                Button(step == titles.count - 1 ? "Finish" : "Continue") { next() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinue)
            }
            .padding(16)
        }
        .frame(width: 640, height: 600)
        .task { await drives.refreshDependencies() }
    }

    @ViewBuilder private var page: some View {
        switch step {
        case 0:
            Image(systemName: "externaldrive.connected.to.line.below").font(.system(size: 52)).foregroundStyle(.tint)
            Text("Your storage. One native experience.").font(.title3)
            Text("Ekthar Drive puts your Google Drive and your Oracle Cloud server in Finder as two separate volumes. Files open on demand; nothing is copied in bulk to this Mac.")
                .foregroundStyle(.secondary)
        case 1:
            VStack(alignment: .leading, spacing: 12) {
                Label("Google Drive appears as its own volume, using your existing Google account and storage.", systemImage: "externaldrive.badge.icloud")
                Label("Your Oracle VM appears as a second volume, over SSH (SFTP) with a key you control.", systemImage: "server.rack")
                Label("Recently used files are cached on this Mac so they open quickly. Changes upload in the background.", systemImage: "internaldrive")
                Label("There is no Ekthar Drive server. Credentials stay in your Keychain.", systemImage: "lock.shield")
            }
            if drives.dependencies?.rclone == nil { rcloneInstallBox }
        case 2:
            if drives.dependencies?.rclone == nil { rcloneInstallBox }
            GoogleConnectSheet(embedded: true).environment(drives)
        case 3:
            if drives.dependencies?.rclone == nil { rcloneInstallBox }
            Text("Use a dedicated, non-root SFTP account on the VM. Documentation/ORACLE_SFTP_SETUP.md has the exact steps and an optional setup script you run yourself.")
                .font(.callout).foregroundStyle(.secondary)
            OracleConfigSheet(embedded: true).environment(drives)
        case 4:
            dependencyRow("rclone", ok: drives.dependencies?.rclone != nil, detail: drives.dependencies?.rclone?.version ?? "Required")
            if drives.dependencies?.rclone == nil { rcloneInstallBox }
            dependencyRow("macFUSE", ok: drives.dependencies?.macFUSEUsable == true,
                          detail: drives.dependencies?.macFUSEVersion ?? "Optional. Without it, Ekthar Drive uses the built-in NFS engine.")
            dependencyRow("Mount engine", ok: drives.dependencies?.canMount == true,
                          detail: (try? drives.dependencies?.resolve(drives.settings.mountEngine).displayName) ?? "Unavailable")
            Button("Check Again") { Task { await drives.refreshDependencies() } }
        case 5:
            ForEach(drives.drives) { d in
                LabeledContent(d.name) {
                    Stepper("\(d.cache.maxSizeBytes / .gibibyte) GB cache", value: Binding(
                        get: { Int(d.cache.maxSizeBytes / .gibibyte) },
                        set: { v in var c = d; c.cache.maxSizeBytes = Int64(v) * .gibibyte; try? drives.saveDrive(c) }), in: 1...512)
                }
            }
            Text("Free space on this Mac: \(ByteFormat.string(DiskSpace.freeBytes(at: drives.paths.cacheRoot.path))). Ekthar Drive keeps at least \(drives.settings.minFreeSpaceGB) GB free.")
                .foregroundStyle(.secondary)
        case 6:
            ForEach(drives.drives) { d in
                let rt = drives.state(d.id)
                HStack {
                    Image(systemName: d.provider.symbol)
                    Text(d.name)
                    Spacer()
                    StatusLabel(text: rt.phase.isActive ? "Mounted at \(rt.mountPath ?? "")" : (rt.connection.isConfigured ? rt.phase.label : "Not connected"), health: rt.health)
                    if rt.connection.isConfigured && !rt.phase.isActive {
                        Button("Mount") { Task { mounting = true; await drives.mount(d.id); mounting = false } }.disabled(mounting)
                    }
                }
                if let e = rt.lastError { ErrorBanner(error: e) }
            }
            ForEach(drives.drives) { d in
                Toggle("Mount \(d.name) automatically at launch", isOn: Binding(get: { d.autoMount }, set: { v in var c = d; c.autoMount = v; try? drives.saveDrive(c) }))
                    .disabled(!drives.state(d.id).connection.isConfigured)
            }
        default:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(.green)
            Text(summary).foregroundStyle(.secondary)
            Text("Ekthar Drive keeps running in the menu bar when you close this window.").foregroundStyle(.secondary)
        }
    }

    private var summary: String {
        let connected = drives.drives.filter { if case .connected = drives.state($0.id).connection { return true }; return drives.state($0.id).phase.isActive }.map(\.name)
        return connected.isEmpty ? "No drives are connected yet. You can connect them any time in Settings > Accounts." : "Connected: \(connected.joined(separator: ", "))."
    }

    private var canContinue: Bool { !(step == 4 && drives.dependencies?.rclone == nil) }

    private func next() {
        if step == titles.count - 1 {
            model.updateSettings { $0.setupCompleted = true }
            dismiss()
        } else {
            step += 1
        }
    }

    private func dependencyRow(_ name: String, ok: Bool, detail: String) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(ok ? .green : .orange)
            Text(name).bold()
            Spacer()
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }

    private var rcloneInstallBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("rclone is needed to connect your storage.").bold()
            HStack {
                if installing { ProgressView().controlSize(.small) }
                Text(installStatus ?? "Install the official build from rclone.org (checksum verified).").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Install rclone") {
                    installing = true; installError = nil
                    Task {
                        do { try await drives.installRclone { s in Task { @MainActor in installStatus = s } } } catch { installError = .wrap(error) }
                        installing = false
                    }
                }
                .disabled(installing)
            }
            if let installError { ErrorBanner(error: installError) }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }
}
