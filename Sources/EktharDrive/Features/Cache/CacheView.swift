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
            ForEach(drives.drives) { d in
                CacheSection(drive: d, message: $message, error: $error)
            }
            if let message { Section { Text(message).foregroundStyle(.secondary) } }
        }
        .formStyle(.grouped)
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
