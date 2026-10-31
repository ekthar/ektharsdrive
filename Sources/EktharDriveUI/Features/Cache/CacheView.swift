import EktharDriveCore
import SwiftUI

struct CacheView: View {
    @Environment(DriveManager.self) private var drives
    @State private var message: String?
    @State private var error: DriveError?

    var body: some View {
        Form {
            if let w = drives.diskWarning {
                Section { ErrorBanner(error: .localDiskFull(freeBytes: w.freeBytes)) }
            }
            if let error { Section { ErrorBanner(error: error) } }
            Section("This Mac") {
                LabeledContent("Free space", value: ByteFormat.string(DiskSpace.freeBytes(at: drives.paths.cacheRoot.path)))
                LabeledContent("Keep at least") {
                    Stepper("\(drives.settings.minFreeSpaceGB) GB free", value: Binding(
                        get: { drives.settings.minFreeSpaceGB },
                        set: { v in var s = drives.settings; s.minFreeSpaceGB = v; drives.saveSettings(s) }), in: 1...100)
                }
                Text("rclone stops growing the cache when free space drops below this. Applies on the next mount.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Cache folder", value: drives.paths.cacheRoot.path).textSelection(.enabled)
            }
            Section("Kept offline") {
                if drives.offlinePins.isEmpty {
                    Text("Right-click a folder or file and choose Keep Offline. It downloads in the background, stays in the cache, and is refreshed every 6 hours.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(drives.offlinePins) { pin in OfflinePinRow(pin: pin) }
                    Text("Offline items live in the drive's cache, so the cache limit must be larger than what you keep.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(drives.drives) { d in
                CacheSection(drive: d, message: $message, error: $error)
            }
            if let message { Section { Text(message).foregroundStyle(.secondary) } }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Theme.canvas)
        .navigationTitle("Cache")
        .toolbar { Button { drives.measureCaches(); Task { _ = await drives.pollOnce() } } label: { Label("Refresh", systemImage: "arrow.clockwise") } }
        .task { drives.measureCaches() }
    }
}

private struct CacheSection: View {
    @Environment(DriveManager.self) private var drives
    let drive: DriveConfiguration
    @Binding var message: String?
    @Binding var error: DriveError?
    @State private var confirm = false

    var body: some View {
        let rt = drives.state(drive.id)
        let used = rt.cache?.bytesUsed ?? 0
        Section(drive.name) {
            ProgressView(value: min(1, Double(used) / Double(max(1, drive.cache.maxSizeBytes))))
            LabeledContent("Used", value: "\(ByteFormat.string(rt.cache?.bytesUsed)) of \(ByteFormat.string(drive.cache.maxSizeBytes))")
            if let files = rt.cache?.files { LabeledContent("Cached files", value: "\(files)") }
            LabeledContent("Waiting to upload", value: "\(rt.cache?.pendingUploads ?? 0)")
            LabeledContent("Measured", value: rt.cache.map { "\($0.measuredAt.relative) (\($0.source == .liveProcess ? "live from rclone" : "from disk"))" } ?? "Not yet")
            LabeledContent("Last cleanup", value: drives.lastCacheClear[drive.id]?.relative ?? "Never")
            LabeledContent("Limit") {
                Stepper("\(drive.cache.maxSizeBytes / .gibibyte) GB", value: Binding(
                    get: { Int(drive.cache.maxSizeBytes / .gibibyte) },
                    set: { v in var d = drive; d.cache.maxSizeBytes = Int64(v) * .gibibyte; try? drives.saveDrive(d) }), in: 1...512)
            }
            LabeledContent("Keep files for") {
                Stepper("\(drive.cache.maxAgeHours) hours", value: Binding(
                    get: { drive.cache.maxAgeHours },
                    set: { v in var d = drive; d.cache.maxAgeHours = v; try? drives.saveDrive(d) }), in: 1...8760, step: 24)
            }
            HStack {
                Text(rt.phase.isActive ? "While mounted, rclone evicts old files itself. Unmount to clear manually." : "Removes only copies already uploaded.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear Safe Cache…") { confirm = true }.disabled(rt.phase.isActive)
            }
        }
        .confirmationDialog("Clear \(drive.name) cache?", isPresented: $confirm) {
            Button("Clear Safe Cache") {
                do {
                    let r = try drives.clearSafeCache(drive.id)
                    message = "\(drive.name): removed \(r.removedFiles) file(s), freed \(ByteFormat.string(r.freedBytes)); kept \(r.keptDirty) waiting to upload."
                    error = nil
                } catch let e { error = .wrap(e) }
            }
        } message: { Text("Files waiting to upload are never removed. Nothing is deleted from the remote drive.") }
    }
}

struct OfflinePinRow: View {
    @Environment(DriveManager.self) private var drives
    let pin: OfflinePin

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(pin.name).font(.bodyStrong)
                Text("\(drives.drive(pin.driveID)?.name ?? pin.driveID) · \(pin.path.isEmpty ? "/" : pin.path)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                status
            }
            Spacer()
            Button("Remove") { drives.removeOffline(pin) }.buttonStyle(.borderless)
        }
    }

    @ViewBuilder private var status: some View {
        switch drives.pinStatus[pin.id] ?? .waiting {
        case .waiting:
            Text(drives.state(pin.driveID).phase == .mounted ? "Waiting" : "Starts when the drive is mounted")
                .font(.caption).foregroundStyle(.secondary)
        case .downloading(let done, let total):
            ProgressView(value: total > 0 ? Double(done) / Double(total) : 0) {
                Text(total > 0 ? "\(ByteFormat.string(done)) of \(ByteFormat.string(total))" : "Counting files…")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            .frame(maxWidth: 260)
        case .ready(let files, let bytes, let at):
            Label("\(files) file\(files == 1 ? "" : "s"), \(ByteFormat.string(bytes)) on this Mac · \(at.relative)", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(Theme.success)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
        }
    }
}
