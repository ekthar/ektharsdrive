import EktharDriveCore
import SwiftUI

/// Right-hand info panel: the selected item, or the drive itself when nothing is selected.
struct DriveInspector: View {
    @Environment(DriveManager.self) private var drives
    let drive: DriveConfiguration
    let browser: FileBrowserModel

    @State private var showConnect = false
    @State private var confirmDisconnect = false
    @State private var confirmClear = false
    @State private var message: String?
    @State private var error: DriveError?
    @State private var fingerprint: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let item = browser.selectedItems.first, browser.selection.count == 1 {
                    itemInfo(item)
                } else if browser.selection.count > 1 {
                    multiInfo
                }
                driveInfo
            }
            .padding(14)
        }
        .background(Theme.surface)
        .sheet(isPresented: $showConnect) {
            if drive.provider == .googleDrive { GoogleConnectSheet().environment(drives) } else { OracleConfigSheet().environment(drives) }
        }
        .confirmationDialog("Disconnect \(drive.name)?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) {
                Task { do { try await drives.disconnect(drive.id); error = nil } catch let e { error = .wrap(e) } }
            }
        } message: { Text("Credentials are removed from this Mac. No files are deleted anywhere.") }
        .confirmationDialog("Clear cached copies?", isPresented: $confirmClear) {
            Button("Clear Safe Cache") {
                do {
                    let r = try drives.clearSafeCache(drive.id)
                    message = "Freed \(ByteFormat.string(r.freedBytes)). Kept \(r.keptDirty) waiting to upload."
                    error = nil
                } catch let e { error = .wrap(e) }
            }
        } message: { Text("Only copies already uploaded are removed.") }
        .task(id: drives.sftpConnection?.host) { fingerprint = await drives.trustedOracleFingerprints().first }
    }

    // MARK: Item

    private func itemInfo(_ item: FileItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer()
                Image(nsImage: FileIcons.icon(for: item)).resizable().frame(width: 84, height: 84)
                Spacer()
            }
            Text(item.name).font(.headline).multilineTextAlignment(.center).frame(maxWidth: .infinity).textSelection(.enabled)
            VStack(spacing: 8) {
                row("Kind", FileIcons.kind(for: item))
                if !item.isDirectory { row("Size", FileIcons.sizeLabel(for: item)) }
                row("Modified", item.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "--")
                row("Where", item.url.deletingLastPathComponent().path)
            }
            HStack {
                Button("Open") { browser.open(item) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            }
            .controlSize(.small)
        }
        .premiumCard(padding: 14)
    }

    private var multiInfo: some View {
        let items = browser.selectedItems
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(items.count) items selected").font(.headline)
            row("Total size", ByteFormat.string(items.compactMap(\.size).reduce(0, +)))
            row("Folders", "\(items.filter(\.isDirectory).count)")
        }
        .premiumCard(padding: 14)
    }

    // MARK: Drive

    private var driveInfo: some View {
        let rt = drives.state(drive.id)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                DriveIconTile(provider: drive.provider, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(drive.name).font(.headline)
                    StatusLabel(text: rt.phase.isActive ? rt.phase.label : rt.connection.label, health: rt.health).font(.caption)
                }
            }
            HStack(spacing: 14) {
                CapacityRing(usage: rt.usage, size: 64, lineWidth: 7)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(ByteFormat.string(rt.usage?.used)) used").font(.callout.weight(.medium)).monospacedDigit()
                    Text("\(ByteFormat.string(rt.usage?.free)) free").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Text("of \(ByteFormat.string(rt.usage?.total))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Divider()
            VStack(spacing: 8) {
                if drive.provider == .googleDrive {
                    row("Account", rt.accountLabel ?? (rt.connection.isConfigured ? "Signed in" : "None"))
                } else {
                    row("Server", drives.sftpConnection.map { "\($0.username)@\($0.host)" } ?? "None")
                    row("Folder", drive.remotePath)
                    row("Host key", fingerprint.map { String($0.prefix(22)) + "…" } ?? "Not verified")
                }
                if rt.phase.isActive {
                    row("Mounted at", rt.mountPath ?? "--")
                    row("Engine", rt.engine?.displayName ?? "--")
                }
                row("Cache", rt.cache.map { "\(ByteFormat.string($0.bytesUsed)) of \(ByteFormat.string(drive.cache.maxSizeBytes))" }
                    ?? "Empty · limit \(ByteFormat.string(drive.cache.maxSizeBytes))")
                row("Uploading", "\(rt.cache?.pendingUploads ?? 0)")
                row("Last connected", rt.lastSuccessfulConnection?.relative ?? "Never")
            }
            let active = drives.activeTransfers[drive.id] ?? []
            if !active.isEmpty {
                Divider()
                Text("Transfers").font(.subheadline.weight(.semibold))
                ForEach(active.prefix(4)) { t in TransferRow(transfer: t, driveName: drive.name) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Button { Task { await drives.testConnection(drive.id) } } label: { Label("Test Connection", systemImage: "checkmark.seal") }
                    .disabled(!rt.connection.isConfigured)
                Button { Task { await drives.refreshUsage(drive.id) } } label: { Label("Refresh Storage", systemImage: "arrow.clockwise") }
                    .disabled(!rt.connection.isConfigured)
                Button { confirmClear = true } label: { Label("Clear Safe Cache…", systemImage: "trash.slash") }
                    .disabled(rt.phase.isActive)
                Button { showConnect = true } label: { Label(rt.connection.isConfigured ? "Account Settings…" : "Connect…", systemImage: "person.crop.circle") }
                    .disabled(rt.phase.isActive)
                Button(role: .destructive) { confirmDisconnect = true } label: { Label("Disconnect…", systemImage: "link.badge.plus") }
                    .disabled(!rt.connection.isConfigured || rt.phase.isActive)
            }
            .buttonStyle(.borderless)
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if let error { ErrorBanner(error: error) }
        }
        .premiumCard(padding: 14)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 86, alignment: .leading)
            Text(value).font(.caption).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}
