import AppKit
import EktharDriveCore
import SwiftUI
import UniformTypeIdentifiers

struct AccountsView: View {
    @Environment(DriveManager.self) private var drives
    @State private var sheet: ProviderKind?
    @State private var confirm: DriveConfiguration?
    @State private var error: DriveError?
    @State private var fingerprints: [String] = []

    var body: some View {
        Form {
            if let error { Section { ErrorBanner(error: error) } }
            ForEach(drives.drives) { d in
                let rt = drives.state(d.id)
                Section(d.name) {
                    LabeledContent("Status") { StatusLabel(text: rt.connection.label, health: rt.connection.isConfigured ? (rt.health == .inactive ? .healthy : rt.health) : .inactive) }
                    if d.provider == .googleDrive {
                        LabeledContent("Account", value: rt.accountLabel ?? (rt.connection.isConfigured ? "Signed in" : "None"))
                        LabeledContent("OAuth client", value: drives.settings.googleClientID ?? "rclone shared client")
                        LabeledContent("Token storage", value: "Encrypted rclone.conf, key in Keychain")
                    } else {
                        LabeledContent("Server", value: drives.sftpConnection.map { "\($0.username)@\($0.host):\($0.port)" } ?? "None")
                        LabeledContent("Private key", value: drives.sftpConnection?.privateKeyPath ?? "None")
                        LabeledContent("Trusted host key") {
                            Text(fingerprints.first ?? "None").font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                    HStack {
                        Spacer()
                        Button(rt.connection.isConfigured ? (d.provider == .googleDrive ? "Reconnect…" : "Reconfigure…") : "Connect…") { sheet = d.provider }
                            .disabled(rt.phase.isActive)
                        Button("Disconnect…", role: .destructive) { confirm = d }
                            .disabled(!rt.connection.isConfigured || rt.phase.isActive)
                    }
                    if rt.phase.isActive { Text("Unmount \(d.name) to change its account.").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Accounts")
        .sheet(item: $sheet) { kind in
            if kind == .googleDrive { GoogleConnectSheet().environment(drives) } else { OracleConfigSheet().environment(drives) }
        }
        .confirmationDialog("Disconnect \(confirm?.name ?? "")?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { d in
            Button("Disconnect and Remove Credentials", role: .destructive) {
                Task {
                    do { try await drives.disconnect(d.id); error = nil } catch let e { error = .wrap(e) }
                    fingerprints = await drives.trustedOracleFingerprints()
                }
            }
        } message: { _ in Text("Credentials and trusted keys are removed from this Mac. No files are deleted anywhere.") }
        .task(id: drives.sftpConnection?.host) { fingerprints = await drives.trustedOracleFingerprints() }
    }
}

extension ProviderKind: Identifiable {
    public var id: String { rawValue }
}

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(DriveManager.self) private var drives

    var body: some View {
        Form {
            Section("App") {
                Toggle("Launch at login", isOn: Binding(get: { model.loginItems.enabled }, set: { model.loginItems.set($0) }))
                if let m = model.loginItems.message { Text(m).font(.caption).foregroundStyle(.secondary) }
                Toggle("Start in the menu bar only", isOn: binding(\.startMinimized))
                Toggle("Notify me about drive problems", isOn: binding(\.notificationsEnabled))
                Picker("Appearance", selection: binding(\.theme)) { ForEach(AppTheme.allCases, id: \.self) { Text($0.label) } }
                Toggle("Reconnect automatically after errors", isOn: binding(\.autoReconnect))
            }
            Section("Speed") {
                Picker("Limit transfers to", selection: Binding(
                    get: { drives.settings.bandwidthLimitMBps ?? 0 },
                    set: { v in model.updateSettings { $0.bandwidthLimitMBps = v > 0 ? v : nil }; Task { await drives.applyBandwidthLimit() } })) {
                    Text("No limit").tag(0.0)
                    ForEach([1.0, 2, 5, 10, 25, 50], id: \.self) { Text("\(Int($0)) MB/s").tag($0) }
                }
                Text("Applies to uploads and downloads on every drive right away.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(drives.drives) { d in DriveSettingsSection(drive: d) }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }

    private func binding<T>(_ kp: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { drives.settings[keyPath: kp] }, set: { v in model.updateSettings { $0[keyPath: kp] = v } })
    }
}

private struct DriveSettingsSection: View {
    @Environment(DriveManager.self) private var drives
    let drive: DriveConfiguration
    @State private var customPath = ""
    @State private var error: DriveError?

    var body: some View {
        Section(drive.name) {
            Toggle("Mount automatically when Ekthar Drive starts", isOn: Binding(get: { drive.autoMount }, set: { v in var d = drive; d.autoMount = v; save(d) }))
            Toggle("Enabled", isOn: Binding(get: { drive.enabled }, set: { v in var d = drive; d.enabled = v; save(d) }))
            LabeledContent("Mount location") {
                HStack {
                    TextField("Default", text: $customPath, prompt: Text(MountPathResolver.path(for: DriveConfiguration(id: drive.id, name: drive.name, provider: drive.provider, remoteName: drive.remoteName, remotePath: drive.remotePath, cache: drive.cache), engine: drives.effectiveEngine ?? .nfs)))
                        .onSubmit(applyPath)
                    Button("Apply", action: applyPath)
                }
            }
            Stepper("Retry up to \(drive.maxRetryAttempts) times", value: Binding(get: { drive.maxRetryAttempts }, set: { v in var d = drive; d.maxRetryAttempts = v; save(d) }), in: 0...5)
            Stepper("Upload \(drive.cache.writeBackSeconds) s after a file is closed", value: Binding(get: { drive.cache.writeBackSeconds }, set: { v in var d = drive; d.cache.writeBackSeconds = v; save(d) }), in: 0...600)
            Stepper("Connection timeout \(drive.connectionTimeoutSeconds) s", value: Binding(get: { drive.connectionTimeoutSeconds }, set: { v in var d = drive; d.connectionTimeoutSeconds = v; save(d) }), in: 5...120, step: 5)
            if let error { Text(error.detail).font(.caption).foregroundStyle(.red) }
            if drives.state(drive.id).phase.isActive { Text("Changes apply the next time \(drive.name) is mounted.").font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear { customPath = drive.mountPath ?? "" }
    }

    private func applyPath() {
        var d = drive
        let p = customPath.trimmingCharacters(in: .whitespaces)
        d.mountPath = p.isEmpty ? nil : (p as NSString).expandingTildeInPath
        save(d)
    }

    private func save(_ d: DriveConfiguration) {
        do { try drives.saveDrive(d); error = nil } catch let e { error = .wrap(e) }
    }
}

struct AdvancedSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(DriveManager.self) private var drives
    @State private var installing = false
    @State private var installStatus: String?
    @State private var installError: DriveError?
    @State private var processInfo: [String: SupervisedProcessInfo] = [:]

    var body: some View {
        Form {
            Section("Dependencies") {
                let deps = drives.dependencies
                LabeledContent("rclone") {
                    if let r = deps?.rclone { Text("\(r.version) at \(r.url.path)").textSelection(.enabled) }
                    else { Text("Not installed").foregroundStyle(.red) }
                }
                if let r = deps?.rclone, !r.supportsFUSEMount {
                    Text("This rclone build cannot use macFUSE (Homebrew builds cannot). The Built-in NFS engine still works, or install the official build.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if installing { ProgressView().controlSize(.small) }
                    Text(installStatus ?? "Downloads the official build from rclone.org and verifies its SHA-256 checksum.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(deps?.rclone == nil ? "Install rclone" : "Update rclone") { install() }.disabled(installing)
                }
                if let installError { ErrorBanner(error: installError) }
                LabeledContent("macFUSE") {
                    if let v = deps?.macFUSEVersion { Text("\(v)\(deps?.libfuseInstalled == true ? "" : " (libfuse missing)")") }
                    else { Link("Not installed. Get macFUSE…", destination: URL(string: "https://macfuse.github.io")!) }
                }
                LabeledContent("macOS NFS client", value: deps?.nfsClientAvailable == true ? "Available" : "Unavailable")
                Button("Check Again") { Task { await drives.refreshDependencies() } }
            }
            Section("Filesystem") {
                Picker("Mount engine", selection: binding(\.mountEngine)) {
                    ForEach(MountEngine.allCases, id: \.self) { Text($0.displayName) }
                }
                Text(engineHelp).font(.caption).foregroundStyle(.secondary)
                LabeledContent("rclone path") {
                    HStack {
                        TextField("Automatic", text: Binding(get: { drives.settings.rclonePath ?? "" }, set: { v in model.updateSettings { $0.rclonePath = v.isEmpty ? nil : v } }))
                        Button("Choose…") { chooseRclone() }
                    }
                }
                Picker("rclone log level", selection: binding(\.logLevel)) { ForEach(MountGlobals.allowedLogLevels, id: \.self) { Text($0) } }
            }
            Section("Processes") {
                ForEach(drives.drives) { d in
                    LabeledContent(d.name) {
                        if let p = processInfo[d.id] { Text("rclone pid \(p.pid)\(p.adopted ? " (reattached)" : "")").monospacedDigit() }
                        else { Text("Not running").foregroundStyle(.secondary) }
                    }
                }
            }
            Section("Diagnostics") {
                HStack {
                    Text("Exports versions, drive states and recent rclone output. Credentials are redacted.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Export Diagnostics…") { exportDiagnostics() }
                }
                HStack {
                    Button("Show Logs in Finder") { NSWorkspace.shared.open(drives.paths.logsDirectory) }
                    Button("Show App Data in Finder") { NSWorkspace.shared.open(drives.paths.supportDirectory) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Advanced")
        .task {
            while !Task.isCancelled {
                var info: [String: SupervisedProcessInfo] = [:]
                for d in drives.drives { info[d.id] = await drives.supervisor.info(for: d.id) }
                processInfo = info
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private var engineHelp: String {
        switch drives.settings.mountEngine {
        case .automatic: "Uses macFUSE when installed (volumes appear in /Volumes), otherwise the built-in NFS engine (volumes appear in ~/Volumes)."
        case .macFUSE: "Requires macFUSE and the official rclone build. Volumes appear in /Volumes."
        case .nfs: "No kernel extension needed. rclone serves NFS on 127.0.0.1 only and macOS mounts it in ~/Volumes."
        }
    }

    private func binding<T>(_ kp: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { drives.settings[keyPath: kp] }, set: { v in model.updateSettings { $0[keyPath: kp] = v } })
    }

    private func install() {
        installing = true; installError = nil
        Task {
            do {
                try await drives.installRclone { s in Task { @MainActor in installStatus = s } }
            } catch { installError = .wrap(error) }
            installing = false
        }
    }

    private func chooseRclone() {
        let p = NSOpenPanel()
        p.canChooseDirectories = false
        p.message = "Choose the rclone executable"
        if p.runModal() == .OK, let url = p.url { model.updateSettings { $0.rclonePath = url.path } }
    }

    private func exportDiagnostics() {
        Task {
            let report = await drives.diagnosticsReport()
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "EktharDrive-diagnostics-\(Int(Date().timeIntervalSince1970)).txt"
            panel.allowedContentTypes = [.plainText]
            if panel.runModal() == .OK, let url = panel.url {
                try? Data(report.utf8).write(to: url, options: .atomic)
            }
        }
    }
}

struct AboutView: View {
    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build" }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "externaldrive.connected.to.line.below").font(.system(size: 56)).foregroundStyle(.tint)
            Text("Ekthar Drive").font(.largeTitle.weight(.semibold))
            Text("Your storage. One native experience.").foregroundStyle(.secondary)
            Text("Version \(version)").font(.callout).foregroundStyle(.secondary)
            Divider().frame(width: 280)
            VStack(spacing: 4) {
                Text("Built on open-source software:").font(.callout)
                Link("rclone (MIT License)", destination: URL(string: "https://rclone.org")!)
                Link("macFUSE", destination: URL(string: "https://macfuse.github.io")!)
            }
            Text("Ekthar Drive does not run any server of its own. Your files travel directly between this Mac and your Google Drive or Oracle server.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("About")
    }
}
