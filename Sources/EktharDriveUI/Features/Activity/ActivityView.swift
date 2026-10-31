import EktharDriveCore
import SwiftUI

struct ActivityRow: Identifiable {
    let event: ActivityEvent
    var id: String { event.timestampID }
    var timestamp: Date { event.timestamp }
    var eventType: String { event.eventType }
    var message: String { event.message }
}

struct ActivityView: View {
    @Environment(DriveManager.self) private var drives
    @State private var search = ""
    @State private var driveFilter = "all"
    @State private var severity: Severity? = nil
    @State private var rows: [ActivityRow] = []
    @State private var selection: ActivityRow.ID?
    @State private var sortOrder = [KeyPathComparator(\ActivityRow.timestamp, order: .reverse)]

    var body: some View {
        VStack(spacing: 0) {
            Table(rows.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Time", value: \.timestamp) { r in
                    Text(r.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute().second()).monospacedDigit()
                }
                .width(150)
                TableColumn("") { r in Image(systemName: r.event.severity.symbol).foregroundStyle(r.event.severity.color) }.width(20)
                TableColumn("Drive") { r in Text(r.event.driveID.flatMap { drives.drive($0)?.name } ?? "App") }.width(110)
                TableColumn("Type", value: \.eventType).width(90)
                TableColumn("Message", value: \.message) { r in Text(r.message).lineLimit(1) }
            }
            if let id = selection, let e = rows.first(where: { $0.id == id })?.event {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(e.severity.rawValue.capitalized, systemImage: e.severity.symbol).foregroundStyle(e.severity.color)
                        Text(e.timestamp.formatted(date: .long, time: .standard)).foregroundStyle(.secondary)
                    }
                    Text(e.message).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        }
        .searchable(text: $search, prompt: "Search activity")
        .scrollContentBackground(.hidden)
        .background(Theme.canvas)
        .navigationTitle("Activity")
        .toolbar {
            Picker("Drive", selection: $driveFilter) {
                Text("All drives").tag("all")
                ForEach(drives.drives) { Text($0.name).tag($0.id) }
            }
            Picker("Level", selection: $severity) {
                Text("All levels").tag(Severity?.none)
                Text("Warnings and errors").tag(Severity?.some(.warning))
                Text("Errors only").tag(Severity?.some(.error))
            }
        }
        .overlay {
            if rows.isEmpty {
                if search.isEmpty { ContentUnavailableView("No activity", systemImage: "list.bullet.rectangle") }
                else { ContentUnavailableView.search(text: search) }
            }
        }
        .task(id: "\(search)|\(driveFilter)|\(String(describing: severity))|\(drives.recentActivity.first?.timestampID ?? "")") {
            rows = drives.searchActivity(driveID: driveFilter == "all" ? nil : driveFilter, minimumSeverity: severity, search: search)
                .map(ActivityRow.init(event:))
        }
    }
}
