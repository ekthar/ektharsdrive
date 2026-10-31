import AppKit
import EktharDriveCore
import SwiftUI

/// Settings > General > Time Machine. Creates a backup disk image on a drive and shows the one
/// admin command that points Time Machine at it.
struct TimeMachineSection: View {
    @Environment(DriveManager.self) private var drives
    @State private var target: String = ""
    @State private var sizeGB = 500
    @State private var error: DriveError?
    @State private var copied = false

    private var candidates: [DriveConfiguration] {
        drives.drives.filter { drives.state($0.id).phase == .mounted && $0.provider != .vault }
    }

    var body: some View {
        Section("Time Machine") {
            if let error { ErrorBanner(error: error) }
            if let id = drives.timeMachineDriveID {
                LabeledContent("Backup disk", value: "On \(drives.drive(id)?.name ?? id)")
                LabeledContent("Status", value: TimeMachineDisk.attachedVolume != nil ? "Open at /Volumes/\(TimeMachineDisk.volumeName)" : "Closed")
                if TimeMachineDisk.attachedVolume == nil {
                    Button("Open Backup Disk") { Task { await drives.openTimeMachineDisk(id) } }
                }
                Text("One time only: open Terminal, paste this, and enter your Mac password.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(TimeMachineDisk.setDestinationCommand).font(.caption.monospaced()).textSelection(.enabled)
                    Spacer()
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(TimeMachineDisk.setDestinationCommand, forType: .string)
                        copied = true
                    }
                }
                Text("After that, Time Machine backs up on its own whenever the drive is mounted. The first backup is large; later ones send only changes.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if candidates.isEmpty {
                Text("Mount Google Drive or Oracle Drive to make a Time Machine disk on it.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("Drive", selection: $target) {
                    ForEach(candidates) { Text($0.name).tag($0.id) }
                }
                Stepper("Up to \(sizeGB) GB", value: $sizeGB, in: 100...8000, step: 100)
                Text("Makes a growing disk image on the drive. It uses only the space backups need, up to this size. The drive's cache should hold at least a few GB.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if let busy = drives.timeMachineBusy { ProgressView().controlSize(.small); Text(busy).font(.caption) }
                    Spacer()
                    Button("Create Backup Disk") {
                        let id = target.isEmpty ? candidates[0].id : target
                        Task {
                            do { try await drives.createTimeMachineDisk(id, sizeGB: sizeGB); error = nil } catch let e { error = .wrap(e) }
                        }
                    }
                    .disabled(drives.timeMachineBusy != nil)
                }
            }
        }
        .onAppear { if target.isEmpty { target = candidates.first?.id ?? "" } }
    }
}
