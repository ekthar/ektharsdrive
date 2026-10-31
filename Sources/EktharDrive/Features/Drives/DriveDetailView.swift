import EktharDriveCore
import SwiftUI

struct DriveDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(DriveManager.self) private var drives
    let driveID: String

    @State private var showConnect = false
    @State private var confirmDisconnect = false
    @State private var confirmClear = false
    @State private var actionError: DriveError?
    @State private var clearResult: CacheClearResult?
    @State private var busy = false
    @State private var trusted: [String] = []

    var body: some View {
        if let d = drives.drive(driveID) {
            content(d)
        } else {
            ContentUnavailableView("Drive not found", systemImage: "questionmark.folder")
        }
    }

    private func content(_ d: DriveConfiguration) -> some View {
        let rt = drives.state(d.id)
        return Form {
            if let e = actionError ?? rt.lastError {
                Section { ErrorBanner(error: e, actions: recoveryActions(for: e, drive: d)) }
            }
            Section("Status") {
                LabeledContent("Connection") { StatusLabel(text: rt.connection.label, health: connectionHealth(rt.connection)) }
                LabeledContent("Volume") { StatusLabel(text: rt.phase.label, health: rt.health) }
                LabeledContent("Mount location", value: rt.mountPath ?? MountPathResolver.path(for: d, engine: (try? drives.dependencies?.resolve(drives.settings.mountEngine)) ?? .nfs))
                if let engine = rt.engine, rt.phase.isActive { LabeledContent("Engine", value: engine.displayName) }
                if d.provider == .googleDrive {
                    LabeledContent("Account", value: rt.accountLabel ?? (rt.connection.isConfigured ? "Signed in" : "Not connected"))
                } else {
                    LabeledContent("Server", value: drives.sftpConnection.map { "\($0.username)@\($0.host):\($0.port)" } ?? "Not configured")
                    LabeledContent("Remote directory", value: d.remotePath)
                    LabeledContent("Host verification") {
                        if trusted.isEmpty { Text("Not verified").foregroundStyle(.orange) }
                        else { Text(trusted.first ?? "").font(.caption.monospaced()).textSelection(.enabled) }
                    }
                }
                LabeledContent("Last successful connection", value: rt.lastSuccessfulConnection?.relative ?? "Never")
            }
            Section("Storage") {
                CapacityView(usage: rt.usage)
                if let trashed = rt.usage?.trashed, trashed > 0 { LabeledContent("In trash", value: ByteFormat.string(trashed)) }
                if let at = rt.usage?.fetchedAt { LabeledContent("Updated", value: at.relative) }
            }
            Section("Cache") {
                LabeledContent("Used", value: "\(ByteFormat.string(rt.cache?.bytesUsed)) of \(ByteFormat.string(d.cache.maxSizeBytes))")
                LabeledContent("Pending uploads", value: "\(rt.cache?.pendingUploads ?? 0)")
                if let errored = rt.cache?.erroredFiles, errored > 0 {
                    LabeledContent("Failed uploads", value: "\(errored) (kept in cache, retried automatically)")
                }
                if let r = clearResult {
                    Text("Removed \(r.removedFiles) file(s), freed \(ByteFormat.string(r.freedBytes)). Kept \(r.keptDirty) not-yet-uploaded file(s).")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Transfers") {
                let active = drives.activeTransfers[d.id] ?? []
                if active.isEmpty { Text("No transfers in progress.").foregroundStyle(.secondary) }
                ForEach(active) { t in TransferRow(transfer: t, driveName: d.name) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(d.name)
        .navigationSubtitle(rt.phase.isActive ? (rt.mountPath ?? "") : rt.connection.label)
        .toolbar { toolbar(d, rt) }
        .disabled(busy)
        .sheet(isPresented: $showConnect) {
            if d.provider == .googleDrive { GoogleConnectSheet().environment(drives) }
            else { OracleConfigSheet().environment(drives) }
        }
        .confirmationDialog("Disconnect \(d.name)?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) { run { try await drives.disconnect(d.id) } }
        } message: {
            Text(d.provider == .googleDrive
                 ? "Ekthar Drive will revoke its access and forget the sign-in. Files in Google Drive are not touched."
                 : "Ekthar Drive will forget the server settings and its trusted host key. Files on the server are not touched.")
        }
        .confirmationDialog("Clear cached copies?", isPresented: $confirmClear) {
            Button("Clear Safe Cache") {
                do { clearResult = try drives.clearSafeCache(d.id); actionError = nil } catch { actionError = .wrap(error) }
            }
        } message: {
            Text("Only local copies that are already uploaded are removed. Files waiting to upload are kept. Nothing is deleted from \(d.name).")
        }
        .task(id: d.id) {
            trusted = await drives.trustedOracleFingerprints()
            if rt.usage == nil, rt.connection.isConfigured { await drives.refreshUsage(d.id) }
            drives.measureCaches()
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ d: DriveConfiguration, _ rt: DriveRuntime) -> some ToolbarContent {
        ToolbarItemGroup {
            if rt.phase.isActive {
                Button { AppActions.openInFinder(rt.mountPath) } label: { Label("Open in Finder", systemImage: "folder") }
                Menu {
                    Button("Unmount") { Task { await drives.unmount(d.id, waitForUploads: false) } }
                    Button("Unmount When Uploads Finish") { drives.unmountWhenUploadsFinish(d.id) }
                } label: { Label("Unmount", systemImage: "eject") } primaryAction: {
                    Task { await drives.unmount(d.id, waitForUploads: false) }
                }
                .help("Unmount safely. Ekthar Drive refuses while uploads are pending.")
            } else if case .waitingForUploads = rt.phase {
                Button("Stop Waiting") { drives.cancelPendingUnmount(d.id) }
            } else {
                Button { Task { await drives.mount(d.id) } } label: { Label("Mount", systemImage: "play.circle") }
                    .disabled(!rt.connection.isConfigured || rt.phase == .mounting)
            }
            Button { Task { await drives.testConnection(d.id) } } label: { Label("Test Connection", systemImage: "checkmark.seal") }
                .disabled(!rt.connection.isConfigured || rt.connection == .testing)
            Button { Task { await drives.refreshUsage(d.id); trusted = await drives.trustedOracleFingerprints() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            Menu {
                Button(rt.connection.isConfigured ? (d.provider == .googleDrive ? "Reconnect Account…" : "Configure…") : "Connect…") { showConnect = true }
                    .disabled(rt.phase.isActive)
                Button("Clear Safe Cache…") { confirmClear = true }.disabled(rt.phase.isActive)
                Divider()
                Button("Disconnect…", role: .destructive) { confirmDisconnect = true }
                    .disabled(!rt.connection.isConfigured || rt.phase.isActive)
            } label: { Label("More", systemImage: "ellipsis.circle") }
        }
        if !rt.connection.isConfigured {
            ToolbarItem(placement: .primaryAction) {
                Button(d.provider == .googleDrive ? "Connect Google Drive" : "Configure Oracle") { showConnect = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func recoveryActions(for e: DriveError, drive d: DriveConfiguration) -> [(String, () -> Void)] {
        switch e {
        case .authenticationFailed, .notConfigured, .hostKeyMismatch, .hostKeyUnknown:
            return [(d.provider == .googleDrive ? "Reconnect Account" : "Review Server Settings", { showConnect = true })]
        case .pendingWrites:
            return [("Unmount When Uploads Finish", { drives.unmountWhenUploadsFinish(d.id) })]
        case .dependencyMissing:
            return [("Open Advanced Settings", { model.selection = .advanced })]
        case .localDiskFull, .cacheFull:
            return [("Manage Cache", { model.selection = .cache })]
        case .mountPointOccupied, .invalidConfiguration:
            return [("Change Mount Location", { model.selection = .general })]
        default:
            return [("Retry", { Task { await drives.mount(d.id) } }), ("View Activity", { model.selection = .activity })]
        }
    }

    private func connectionHealth(_ c: ConnectionState) -> HealthLevel {
        switch c {
        case .connected: .healthy
        case .failed: .error
        case .testing: .degraded
        default: .inactive
        }
    }

    private func run(_ op: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task {
            do { try await op(); actionError = nil } catch { actionError = .wrap(error) }
            busy = false
        }
    }
}
