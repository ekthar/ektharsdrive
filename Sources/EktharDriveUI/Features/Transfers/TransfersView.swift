import EktharDriveCore
import SwiftUI

struct TransfersView: View {
    @Environment(DriveManager.self) private var drives
    @State private var scope: Scope = .active
    @State private var selection: Set<Transfer.ID> = []

    enum Scope: String, CaseIterable { case active = "Active", history = "History" }

    var rows: [Transfer] { scope == .active ? drives.allActiveTransfers : drives.transferHistory }
    private var selected: [Transfer] { rows.filter { selection.contains($0.id) } }

    /// Drives with uploads waiting or paused, for the toolbar's Pause All / Resume All.
    private var queuedDrives: [String] {
        Array(Set(drives.allActiveTransfers.filter { $0.queueID != nil }.map(\.driveID))).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            Table(rows, selection: $selection) {
                TableColumn("Name") { t in
                    Label { Text(t.name).lineLimit(1).truncationMode(.middle) } icon: {
                        Image(systemName: t.status == .paused ? "pause.circle" : (t.direction == .upload ? "arrow.up" : "arrow.down"))
                    }
                    .help(t.direction == .upload ? t.destinationPath : t.sourcePath)
                }
                .width(min: 180, ideal: 260)
                TableColumn("Drive") { t in Text(drives.drive(t.driveID)?.name ?? t.driveID) }.width(110)
                TableColumn("Progress") { t in
                    if t.status == .running, let f = t.fraction { ProgressView(value: f).controlSize(.small) }
                    else { Text(t.progressText).monospacedDigit().foregroundStyle(.secondary) }
                }
                .width(min: 100, ideal: 140)
                TableColumn("Transferred") { t in Text(t.progressText).monospacedDigit() }.width(150)
                TableColumn("Speed") { t in Text(t.status == .running ? ByteFormat.speed(t.speed) : "--").monospacedDigit() }.width(90)
                TableColumn("Remaining") { t in Text(t.etaText).monospacedDigit() }.width(80)
                TableColumn("Started") { t in Text(t.startedAt, format: .dateTime.hour().minute().second()) }.width(80)
                TableColumn("Status") { t in
                    Text(Self.statusText(t)).foregroundStyle(t.status == .failed ? .red : (t.status == .completed ? .secondary : .primary))
                }
                .width(110)
            }
            .contextMenu(forSelectionType: Transfer.ID.self) { ids in
                menu(for: rows.filter { ids.contains($0.id) })
            }
            if !selected.isEmpty, scope == .active { actionBar }
            if selected.count == 1, let err = selected.first?.errorMessage {
                Divider()
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(err).textSelection(.enabled).font(.callout)
                    Spacer()
                }
                .padding(12)
            }
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView(scope == .active ? "No active transfers" : "No transfer history",
                                       systemImage: "arrow.up.arrow.down",
                                       description: Text(scope == .active ? "Uploads and downloads through your mounted drives appear here as rclone reports them." : "Completed and failed transfers are kept here."))
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.canvas)
        .navigationTitle("Transfers")
        .toolbar {
            Picker("Show", selection: $scope) { ForEach(Scope.allCases, id: \.self) { Text($0.rawValue) } }
                .pickerStyle(.segmented)
            if scope == .active {
                let anyHeld = drives.drives.contains { drives.hasHeldUploads($0.id) }
                if anyHeld {
                    Button { Task { for d in drives.drives where drives.hasHeldUploads(d.id) { await drives.resumeAllUploads(d.id) } } } label: {
                        Label("Resume All", systemImage: "play.fill")
                    }
                    .help("Start every paused upload")
                }
                Button { Task { for id in queuedDrives { await drives.pauseAllUploads(id) } } } label: {
                    Label("Pause Uploads", systemImage: "pause.fill")
                }
                .disabled(queuedDrives.isEmpty)
                .help("Keep waiting uploads on this Mac until you resume them. Ones already sending finish.")
            }
        }
    }

    @ViewBuilder private func menu(for list: [Transfer]) -> some View {
        let queued = list.filter { $0.queueID != nil && $0.status != .paused }
        let paused = list.filter { $0.status == .paused }
        let jobs = list.filter { $0.jobID != nil && !$0.status.isTerminal }
        if !queued.isEmpty {
            Button("Upload Now") { Task { for t in queued { await drives.uploadNow(t) } } }
            Button("Pause") { Task { for t in queued { await drives.pauseUpload(t) } } }
        }
        if !paused.isEmpty {
            Button("Resume") { Task { for t in paused { await drives.resumeUpload(t) } } }
            Button("Upload Now") { Task { for t in paused { await drives.uploadNow(t) } } }
        }
        if !jobs.isEmpty {
            Button("Cancel Copy", role: .destructive) { Task { for t in jobs { await drives.cancelJob(t) } } }
        }
        if queued.isEmpty, paused.isEmpty, jobs.isEmpty {
            Text(list.contains { $0.status == .running } ? "Sending now. It cannot be paused." : "No actions")
        }
    }

    private var actionBar: some View {
        let queued = selected.filter { $0.queueID != nil && $0.status != .paused }
        let paused = selected.filter { $0.status == .paused }
        let jobs = selected.filter { $0.jobID != nil && !$0.status.isTerminal }
        return HStack(spacing: 10) {
            Text("\(selected.count) selected").font(.caption12).foregroundStyle(.secondary)
            Spacer()
            if !queued.isEmpty || !paused.isEmpty {
                Button("Upload Now") { Task { for t in queued + paused { await drives.uploadNow(t) } } }
            }
            if !queued.isEmpty { Button("Pause") { Task { for t in queued { await drives.pauseUpload(t) } } } }
            if !paused.isEmpty { Button("Resume") { Task { for t in paused { await drives.resumeUpload(t) } } } }
            if !jobs.isEmpty { Button("Cancel Copy", role: .destructive) { Task { for t in jobs { await drives.cancelJob(t) } } } }
            if queued.isEmpty, paused.isEmpty, jobs.isEmpty {
                Text("Sending now. It will finish on its own.").font(.caption12).foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    static func statusText(_ t: Transfer) -> String {
        switch t.status {
        case .paused: return "Paused"
        case .queued:
            if let s = t.startsIn, s > 1 { return "Starts in \(Int(s.rounded())) s" }
            return "Up next"
        default: return t.status.label
        }
    }
}
