import EktharDriveCore
import SwiftUI

struct TransfersView: View {
    @Environment(DriveManager.self) private var drives
    @State private var scope: Scope = .active
    @State private var selection: Transfer.ID?

    enum Scope: String, CaseIterable { case active = "Active", history = "History" }

    var rows: [Transfer] { scope == .active ? drives.allActiveTransfers : drives.transferHistory }

    var body: some View {
        VStack(spacing: 0) {
            Table(rows, selection: $selection) {
                TableColumn("Name") { t in
                    Label { Text(t.name).lineLimit(1).truncationMode(.middle) } icon: {
                        Image(systemName: t.direction == .upload ? "arrow.up" : "arrow.down")
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
                    Text(t.status.label).foregroundStyle(t.status == .failed ? .red : (t.status == .completed ? .secondary : .primary))
                }
                .width(90)
            }
            if let id = selection, let t = rows.first(where: { $0.id == id }), let err = t.errorMessage {
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
        }
    }
}
