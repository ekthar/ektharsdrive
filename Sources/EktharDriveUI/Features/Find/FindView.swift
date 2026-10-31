import AppKit
import EktharDriveCore
import SwiftUI

/// The Find screens in the sidebar.
public enum FindMode: Hashable {
    case search, recents, duplicates, space
    case smart(String)
}

/// Per-drive state for Find, so results survive switching screens. The full file list (for Duplicates
/// and Space) is fetched once and reused for five minutes.
@MainActor
@Observable
final class FindModel {
    let driveID: String
    var query = DriveSearchQuery()
    private(set) var results: [DriveFile] = []
    private(set) var loading = false
    private(set) var searchedAt: Date?
    var error: DriveError?
    private(set) var allFiles: [DriveFile]?
    private var allFilesAt: Date?
    private(set) var loadingAll = false
    var spaceFolder = ""

    init(driveID: String) { self.driveID = driveID }

    func run(_ q: DriveSearchQuery, drives: DriveManager) async {
        guard let s = drives.search(driveID) else { error = .invalidConfiguration("Mount the drive to search it."); return }
        loading = true
        defer { loading = false }
        do {
            let found = try await s.search(q)
            guard !Task.isCancelled else { return }
            results = found
            searchedAt = Date()
            error = nil
        } catch let e { if !Task.isCancelled { error = e } }
    }

    func clearResults() { results = []; searchedAt = nil }

    func loadAll(drives: DriveManager, force: Bool = false) async {
        if !force, allFiles != nil, let at = allFilesAt, Date().timeIntervalSince(at) < 300 { return }
        guard let s = drives.search(driveID) else { error = .invalidConfiguration("Mount the drive to scan it."); return }
        loadingAll = true
        defer { loadingAll = false }
        do {
            allFiles = try await s.allFiles()
            allFilesAt = Date()
            error = nil
        } catch let e { error = e }
    }

    func forget(_ paths: Set<String>) {
        allFiles?.removeAll { paths.contains($0.path) }
        results.removeAll { paths.contains($0.path) }
    }
}

struct FindView: View {
    @Environment(AppModel.self) private var model
    @Environment(DriveManager.self) private var drives
    let driveID: String
    let mode: FindMode

    var body: some View {
        let finder = model.finder(for: driveID)
        let rt = drives.state(driveID)
        Group {
            if !rt.phase.isActive {
                EmptyStateView(title: "\(drives.drive(driveID)?.name ?? "Drive") is not mounted",
                               message: "Find works on the live drive. Mount it first.", symbol: "magnifyingglass")
            } else {
                switch mode {
                case .search: SearchScreen(finder: finder, driveID: driveID, smart: nil)
                case .recents: SearchScreen(finder: finder, driveID: driveID, smart: SmartFolder(id: "recents", name: "Recents", driveID: driveID, query: .recents), fixed: true)
                case .smart(let id):
                    if let f = drives.smartFolders.first(where: { $0.id == id }) {
                        SearchScreen(finder: finder, driveID: driveID, smart: f).id(id)
                    } else {
                        EmptyStateView(title: "Smart folder removed", message: "Choose another item in the sidebar.", symbol: "folder.badge.questionmark")
                    }
                case .duplicates: DuplicatesScreen(finder: finder, driveID: driveID)
                case .space: SpaceScreen(finder: finder, driveID: driveID)
                }
            }
        }
        .background(Theme.canvas)
    }
}

// MARK: - Shared result helpers

@MainActor
enum FindActions {
    static func url(_ f: DriveFile, drives: DriveManager, driveID: String) -> URL? {
        guard let m = drives.state(driveID).mountPath else { return nil }
        return URL(fileURLWithPath: m).appendingPathComponent(f.path)
    }

    static func open(_ f: DriveFile, drives: DriveManager, driveID: String, model: AppModel) {
        guard let u = url(f, drives: drives, driveID: driveID) else { return }
        if f.isFolder {
            model.browser(for: driveID).reveal(u, isFolder: true)
            model.selection = .drive(driveID)
        } else {
            NSWorkspace.shared.open(u)
        }
    }

    static func showInBrowser(_ f: DriveFile, drives: DriveManager, driveID: String, model: AppModel) {
        guard let u = url(f, drives: drives, driveID: driveID) else { return }
        model.browser(for: driveID).reveal(u, isFolder: false)
        model.selection = .drive(driveID)
    }
}

private func folderOf(_ path: String) -> String {
    let dir = (path as NSString).deletingLastPathComponent
    return dir.isEmpty ? "Top level" : dir
}

// MARK: - Search, Recents, Smart folders

private struct SearchScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(DriveManager.self) private var drives
    @Bindable var finder: FindModel
    let driveID: String
    let smart: SmartFolder?
    var fixed = false
    @State private var selection: Set<String> = []
    @State private var saving = false
    @State private var saveName = ""

    private var title: String { smart?.name ?? "Search" }

    var body: some View {
        VStack(spacing: 0) {
            if !fixed { filterBar.padding(.horizontal, 22).padding(.vertical, 14) }
            if let e = finder.error { ErrorBanner(error: e).padding(.horizontal, 18).padding(.bottom, 10) }
            results
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar {
            if smart == nil {
                Button { saveName = finder.query.text.isEmpty ? finder.query.kind.label : finder.query.text; saving = true } label: {
                    Label("Save as Smart Folder", systemImage: "folder.badge.gearshape")
                }
                .disabled(finder.query.isEmpty)
                .help("Save this search in the sidebar")
            } else if !fixed, let smart {
                Button { drives.saveSmartFolder(SmartFolder(id: smart.id, name: smart.name, driveID: driveID, query: finder.query)) } label: {
                    Label("Update Smart Folder", systemImage: "square.and.arrow.down")
                }
                .help("Save the current filters to “\(smart.name)”")
                Button(role: .destructive) { drives.deleteSmartFolder(smart.id); model.selection = .find(driveID, .search) } label: {
                    Label("Delete Smart Folder", systemImage: "trash")
                }
                .help("Remove “\(smart.name)” from the sidebar")
            }
            Button { Task { await finder.run(finder.query, drives: drives) } } label: { Label("Search Again", systemImage: "arrow.clockwise") }
                .help("Search again")
        }
        .alert("Save Smart Folder", isPresented: $saving) {
            TextField("Name", text: $saveName)
            Button("Save") {
                let f = SmartFolder(name: saveName.isEmpty ? "Smart Folder" : saveName, driveID: driveID, query: finder.query)
                drives.saveSmartFolder(f)
                model.selection = .find(driveID, .smart(f.id))
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("It appears under Find in the sidebar and runs again each time you open it.") }
        .onAppear {
            if let smart { finder.query = smart.query } else if finder.query == DriveSearchQuery.recents { finder.query = DriveSearchQuery() }
            if smart != nil || finder.query.isEmpty { finder.clearResults() }
        }
        // Typing waits 400 ms before searching, so each keystroke does not hit Google.
        .task(id: finder.query) {
            guard !finder.query.isEmpty else { finder.clearResults(); return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await finder.run(finder.query, drives: drives)
        }
    }

    private var subtitle: String {
        if finder.loading { return "Searching…" }
        guard finder.searchedAt != nil else { return drives.drive(driveID)?.name ?? "" }
        return "\(finder.results.count == 1000 ? "First 1000" : "\(finder.results.count)") result\(finder.results.count == 1 ? "" : "s")"
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.inkTertiary)
                TextField("Search all of \(drives.drive(driveID)?.name ?? "the drive")", text: $finder.query.text)
                    .textFieldStyle(.plain).font(.system(size: 14))
                if finder.loading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 12).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
            Picker("Kind", selection: $finder.query.kind) {
                ForEach(DriveSearchQuery.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden().fixedSize()
            Picker("Modified", selection: $finder.query.modifiedWithinDays) {
                Text("Any date").tag(Int?.none)
                Text("Past 7 days").tag(Int?.some(7))
                Text("Past 30 days").tag(Int?.some(30))
                Text("Past year").tag(Int?.some(365))
            }
            .labelsHidden().fixedSize()
            Picker("Size", selection: $finder.query.minSizeBytes) {
                Text("Any size").tag(Int64?.none)
                Text("Over 10 MB").tag(Int64?.some(10 << 20))
                Text("Over 100 MB").tag(Int64?.some(100 << 20))
                Text("Over 1 GB").tag(Int64?.some(1 << 30))
            }
            .labelsHidden().fixedSize()
        }
    }

    @ViewBuilder private var results: some View {
        if finder.results.isEmpty, !finder.loading {
            if finder.searchedAt != nil {
                EmptyStateView(title: "No results", message: "Nothing on the drive matches. Google searches whole words at the start of names, so try the first part of a word.", symbol: "magnifyingglass")
            } else if smart == nil {
                EmptyStateView(title: "Search the whole drive", message: "Type a name, or pick a kind, date or size. Results come straight from Google, so nothing has to be downloaded first.", symbol: "magnifyingglass")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ResultsTable(files: finder.results, driveID: driveID, selection: $selection)
        }
    }
}

private struct ResultsTable: View {
    @Environment(AppModel.self) private var model
    @Environment(DriveManager.self) private var drives
    let files: [DriveFile]
    let driveID: String
    @Binding var selection: Set<String>

    var body: some View {
        Table(files, selection: $selection) {
            TableColumn("Name") { f in
                HStack(spacing: 8) {
                    Image(nsImage: FileIcons.icon(for: f.asItem(root: drives.state(driveID).mountPath)))
                        .resizable().frame(width: 18, height: 18)
                    Text(f.name).lineLimit(1).truncationMode(.middle)
                }
            }
            .width(min: 200, ideal: 300)
            TableColumn("Folder") { f in Text(folderOf(f.path)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
                .width(min: 120, ideal: 220)
            TableColumn("Size") { f in Text(f.isFolder ? "--" : (f.size.map { ByteFormat.string($0) } ?? "--")).monospacedDigit().foregroundStyle(.secondary) }
                .width(min: 70, ideal: 90)
            TableColumn("Modified") { f in Text(f.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "--").foregroundStyle(.secondary) }
                .width(min: 120, ideal: 160)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let f = files.first(where: { $0.id == id }) {
                Button("Open") { FindActions.open(f, drives: drives, driveID: driveID, model: model) }
                Button("Show in Folder") { FindActions.showInBrowser(f, drives: drives, driveID: driveID, model: model) }
                Button("Show in Finder") { if let u = FindActions.url(f, drives: drives, driveID: driveID) { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
                if let link = f.webLink { Button("Open in Google Drive") { NSWorkspace.shared.open(link) } }
                Divider()
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(FindActions.url(f, drives: drives, driveID: driveID)?.path ?? f.path, forType: .string)
                }
            }
        } primaryAction: { ids in
            for id in ids { if let f = files.first(where: { $0.id == id }) { FindActions.open(f, drives: drives, driveID: driveID, model: model) } }
        }
    }
}

extension DriveFile {
    /// A FileItem for icon lookup and the browser helpers.
    func asItem(root: String?) -> FileItem {
        FileItem(url: URL(fileURLWithPath: root ?? "/").appendingPathComponent(path), name: name,
                 isDirectory: isFolder, size: size, modified: modified)
    }
}

// MARK: - Duplicates

private struct DuplicatesScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(DriveManager.self) private var drives
    let finder: FindModel
    let driveID: String
    @State private var confirmDelete: DriveFile?
    @State private var expanded: Set<String> = []

    var body: some View {
        let groups = finder.allFiles.map(DriveAnalysis.duplicates) ?? []
        let wasted = groups.reduce(0) { $0 + $1.wastedBytes }
        VStack(spacing: 0) {
            if let e = finder.error { ErrorBanner(error: e).padding(18) }
            if finder.allFiles == nil {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Reading the list of files from Google. Only names and checksums are read.").font(.caption12).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if groups.isEmpty {
                EmptyStateView(title: "No duplicates", message: "No two files on this drive have the same contents.", symbol: "checkmark.seal")
            } else {
                List {
                    Section {
                        ForEach(groups) { g in
                            DisclosureGroup(isExpanded: Binding(get: { expanded.contains(g.id) }, set: { if $0 { expanded.insert(g.id) } else { expanded.remove(g.id) } })) {
                                ForEach(g.files) { f in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(f.name).lineLimit(1)
                                            Text(folderOf(f.path)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                                        }
                                        Spacer()
                                        Text(f.modified?.formatted(date: .abbreviated, time: .omitted) ?? "").font(.caption).foregroundStyle(.secondary)
                                        Button { FindActions.showInBrowser(f, drives: drives, driveID: driveID, model: model) } label: { Image(systemName: "folder") }
                                            .buttonStyle(.borderless).help("Show in folder")
                                        Button(role: .destructive) { confirmDelete = f } label: { Image(systemName: "trash") }
                                            .buttonStyle(.borderless).help("Delete this copy")
                                    }
                                }
                            } label: {
                                HStack {
                                    Image(nsImage: FileIcons.icon(for: g.files[0].asItem(root: nil))).resizable().frame(width: 20, height: 20)
                                    Text(g.files[0].name).font(.bodyStrong).lineLimit(1)
                                    Spacer()
                                    Text("\(g.files.count) copies · \(ByteFormat.string(g.size)) each").font(.caption).foregroundStyle(.secondary)
                                    Pill(text: "\(ByteFormat.string(g.wastedBytes)) extra", color: Theme.warning)
                                }
                            }
                        }
                    } header: {
                        Text("\(groups.count) sets of identical files. Deleting the extra copies would free \(ByteFormat.string(wasted)).")
                    }
                }
            }
        }
        .navigationTitle("Duplicates")
        .navigationSubtitle(finder.loadingAll ? "Scanning…" : (finder.allFiles.map { "\($0.count) files checked" } ?? ""))
        .toolbar {
            Button { Task { await finder.loadAll(drives: drives, force: true) } } label: { Label("Scan Again", systemImage: "arrow.clockwise") }
                .disabled(finder.loadingAll).help("Scan again")
        }
        .task { await finder.loadAll(drives: drives) }
        .confirmationDialog("Delete “\(confirmDelete?.name ?? "")”?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete This Copy", role: .destructive) {
                guard let f = confirmDelete, let root = drives.state(driveID).mountPath,
                      let u = FindActions.url(f, drives: drives, driveID: driveID) else { return }
                Task {
                    let r: Result<Void, DriveError> = await Task.detached { Result { () throws(DriveError) in try FileBrowsing.delete([u], root: URL(fileURLWithPath: root)) } }.value
                    if case .failure(let e) = r { finder.error = e } else { finder.forget([f.path]) }
                }
            }
        } message: {
            Text("\(folderOf(confirmDelete?.path ?? "")). It goes to your Google Drive trash, where you can restore it for 30 days.")
        }
    }
}

// MARK: - Space

private struct SpaceScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(DriveManager.self) private var drives
    @Bindable var finder: FindModel
    let driveID: String

    var body: some View {
        let entries = finder.allFiles.map { DriveAnalysis.spaceMap($0, in: finder.spaceFolder) } ?? []
        let total = max(1, entries.reduce(0) { $0 + $1.bytes })
        VStack(spacing: 0) {
            if let e = finder.error { ErrorBanner(error: e).padding(18) }
            header(total: entries.isEmpty ? 0 : total)
            if finder.allFiles == nil {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Reading the list of files from Google. Only names and sizes are read.").font(.caption12).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                EmptyStateView(title: "Nothing here", message: "This folder has no files with a size.", symbol: "chart.bar")
            } else {
                List(entries.prefix(300)) { e in
                    SpaceRow(entry: e, fraction: Double(e.bytes) / Double(total), maxFraction: Double(entries[0].bytes) / Double(total))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { if e.isFolder { finder.spaceFolder = e.path } }
                        .contextMenu {
                            if e.isFolder { Button("Open in Space") { finder.spaceFolder = e.path } }
                            Button("Show in Folder") {
                                let f = DriveFile(id: e.path, name: e.name, path: e.path, size: e.bytes, modified: nil,
                                                  mimeType: e.isFolder ? DriveSearchQuery.folderMime : "application/octet-stream")
                                if e.isFolder { FindActions.open(f, drives: drives, driveID: driveID, model: model) }
                                else { FindActions.showInBrowser(f, drives: drives, driveID: driveID, model: model) }
                            }
                        }
                }
            }
        }
        .navigationTitle("Space")
        .navigationSubtitle(finder.loadingAll ? "Scanning…" : (finder.allFiles.map { "\($0.count) files" } ?? ""))
        .toolbar {
            Button { Task { await finder.loadAll(drives: drives, force: true) } } label: { Label("Scan Again", systemImage: "arrow.clockwise") }
                .disabled(finder.loadingAll).help("Scan again")
        }
        .task { await finder.loadAll(drives: drives) }
    }

    private func header(total: Int64) -> some View {
        HStack(spacing: 8) {
            Button { finder.spaceFolder = "" } label: { Text(drives.drive(driveID)?.name ?? "Drive") }
                .buttonStyle(.inlineLink).disabled(finder.spaceFolder.isEmpty)
            let parts = finder.spaceFolder.split(separator: "/").map(String.init)
            ForEach(Array(parts.enumerated()), id: \.offset) { i, p in
                Image(systemName: "chevron.compact.right").foregroundStyle(Theme.inkTertiary)
                Button { finder.spaceFolder = parts[0...i].joined(separator: "/") } label: { Text(p) }
                    .buttonStyle(.inlineLink).disabled(i == parts.count - 1)
            }
            Spacer()
            if total > 0 { Text("\(ByteFormat.string(total)) in this folder").font(.caption12).monospacedDigit().foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
    }
}

private struct SpaceRow: View {
    let entry: SpaceEntry
    let fraction: Double
    let maxFraction: Double

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isFolder ? "folder.fill" : "doc.fill")
                .foregroundStyle(entry.isFolder ? Theme.accent : Theme.inkTertiary).frame(width: 18)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(entry.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(ByteFormat.string(entry.bytes)).monospacedDigit().font(.bodyStrong)
                    Text(String(format: "%.1f%%", fraction * 100)).monospacedDigit().font(.caption).foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                }
                GeometryReader { g in
                    Capsule().fill(Theme.surfaceSunken)
                        .overlay(alignment: .leading) {
                            Capsule().fill(Theme.accentGradient).frame(width: max(3, g.size.width * fraction / max(maxFraction, 0.0001)))
                        }
                }
                .frame(height: 5)
                if entry.isFolder {
                    Text("\(entry.fileCount) file\(entry.fileCount == 1 ? "" : "s") · double-click to open").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
