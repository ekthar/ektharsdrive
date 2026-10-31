import AppKit
import EktharDriveCore
import Observation

enum BrowserViewMode: String, CaseIterable { case icons, list }

/// Per-drive browser state: location, history, listing, selection. Listing happens off the main thread.
@MainActor
@Observable
final class FileBrowserModel {
    let driveID: String
    private(set) var root: URL?
    private(set) var current: URL?
    private(set) var items: [FileItem] = []
    private(set) var loading = false
    var selection: Set<URL> = []
    var error: DriveError?
    var search = ""
    var sort: FileSort = .name
    var ascending = true
    var viewMode: BrowserViewMode {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: "browser.viewMode") }
    }
    var showInspector = true
    /// The user's own choice; automatic hiding on narrow windows never overrides it.
    private var userWantsInspector = true
    private var autoHidden = false

    func toggleInspector() {
        userWantsInspector.toggle()
        autoHidden = false
        showInspector = userWantsInspector
    }

    /// Below this width the file area gets too cramped next to the info panel, and macOS starts
    /// collapsing the sidebar into an overlay. Hide the panel instead, and bring it back when there is room.
    func fitInspector(detailWidth: CGFloat) {
        guard detailWidth > 0 else { return }
        if showInspector, detailWidth < Layout.hideInspectorBelow { autoHidden = true; showInspector = false }
        else if !showInspector, autoHidden, userWantsInspector, detailWidth >= Layout.showInspectorAbove { autoHidden = false; showInspector = true }
    }
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []

    init(driveID: String) {
        self.driveID = driveID
        viewMode = BrowserViewMode(rawValue: UserDefaults.standard.string(forKey: "browser.viewMode") ?? "") ?? .icons
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { guard let root, let current else { return false } ; return current.standardizedFileURL != root.standardizedFileURL }

    var visibleItems: [FileItem] {
        let filtered = search.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(search) }
        return FileBrowsing.sorted(filtered, by: sort, ascending: ascending)
    }

    var selectedItems: [FileItem] { items.filter { selection.contains($0.url) } }
    var totalSize: Int64 { items.compactMap(\.size).reduce(0, +) }

    /// Called when the drive's mount path changes (mount, unmount, remount elsewhere).
    func attach(mountPath: String?) async {
        let newRoot = mountPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard newRoot?.path != root?.path else { return }
        root = newRoot
        backStack.removeAll(); forwardStack.removeAll()
        current = newRoot
        items = []
        selection = []
        if newRoot != nil { await reload() }
    }

    func reload() async {
        guard let dir = current else { return }
        loading = true
        let result: Result<[FileItem], DriveError> = await Task.detached(priority: .userInitiated) {
            Result { () throws(DriveError) -> [FileItem] in try FileBrowsing.list(dir) }
        }.value
        guard dir == current else { return } // navigated away meanwhile
        switch result {
        case .success(let list):
            items = list
            selection = selection.filter { url in list.contains { $0.url == url } }
            error = nil
        case .failure(let e):
            error = e
        }
        loading = false
    }

    func navigate(to url: URL, record: Bool = true) {
        guard let root, FileBrowsing.isInside(url, root: root), url != current else { return }
        if record, let current { backStack.append(current); forwardStack.removeAll() }
        current = url
        items = []
        selection = []
        search = ""
        Task { await reload() }
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        if let current { forwardStack.append(current) }
        navigate(to: previous, record: false)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        if let current { backStack.append(current) }
        navigate(to: next, record: false)
    }

    func goUp() {
        guard canGoUp, let current else { return }
        navigate(to: current.deletingLastPathComponent())
    }

    func open(_ item: FileItem) {
        if item.isDirectory { navigate(to: item.url) } else { NSWorkspace.shared.open(item.url) }
    }

    func select(_ item: FileItem, extend: Bool) {
        if extend {
            if selection.contains(item.url) { selection.remove(item.url) } else { selection.insert(item.url) }
        } else {
            selection = [item.url]
        }
    }

    // MARK: Operations (all confined to the mounted root)

    /// Runs a file operation on a background thread. Every call into the mounted volume can wait on the
    /// network, so none of them may run on the main thread (that is what froze the window).
    private func offMain<T: Sendable>(_ op: @escaping @Sendable () throws(DriveError) -> T) async -> T? {
        let result: Result<T, DriveError> = await Task.detached(priority: .userInitiated) {
            Result { () throws(DriveError) -> T in try op() }
        }.value
        switch result {
        case .success(let v): error = nil; return v
        case .failure(let e): error = e; return nil
        }
    }

    func newFolder() async {
        guard let root, let current else { return }
        let url = await offMain { () throws(DriveError) in try FileBrowsing.createFolder(in: current, root: root) }
        await reload()
        if let url { selection = [url] }
    }

    func rename(_ item: FileItem, to name: String) async {
        guard let root else { return }
        let url = await offMain { () throws(DriveError) in try FileBrowsing.rename(item.url, to: name, root: root) }
        await reload()
        if let url { selection = [url] }
    }

    func delete(_ urls: [URL]) async {
        guard let root else { return }
        _ = await offMain { () throws(DriveError) in try FileBrowsing.delete(urls, root: root) }
        await reload()
    }

    /// Drop handler: items already on this drive are moved, anything else is copied in (uploaded).
    func receive(_ urls: [URL], into folder: URL? = nil) async {
        guard let root, let target = folder ?? current else { return }
        let local = urls.filter { FileBrowsing.isInside($0, root: root) }
        let external = urls.filter { !FileBrowsing.isInside($0, root: root) }
        if !local.isEmpty {
            _ = await offMain { () throws(DriveError) in try FileBrowsing.move(local, into: target, root: root) }
        }
        if !external.isEmpty {
            do { _ = try await FileBrowsing.copyIn(external, to: target, root: root); error = nil } catch let e { error = e }
        }
        await reload()
    }

    func upload() async {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Upload"
        panel.message = "Choose files or folders to copy to \(current?.lastPathComponent ?? "this drive")."
        guard panel.runModal() == .OK else { return }
        await receive(panel.urls)
    }

    func download(_ urls: [URL]) async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose where to save a copy."
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            let out = try await FileBrowsing.copyOut(urls, to: dest)
            NSWorkspace.shared.activateFileViewerSelecting(out)
            error = nil
        } catch let e { error = e }
    }
}
