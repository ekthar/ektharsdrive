import EktharDriveCore
import SwiftUI

/// Finder-style view of one drive: toolbar navigation, icon/list content, path + status bar, inspector.
struct DriveBrowserView: View {
    @Environment(AppModel.self) private var model
    @Environment(DriveManager.self) private var drives
    @Bindable var browser: FileBrowserModel

    @State private var renaming: FileItem?
    @State private var newName = ""
    @State private var pendingDelete: [URL] = []
    @State private var dropTargeted = false

    var body: some View {
        if let d = drives.drive(browser.driveID) {
            let rt = drives.state(d.id)
            VStack(spacing: 0) {
                if let e = browser.error ?? (rt.phase.isActive ? rt.lastError : nil) {
                    ErrorBanner(error: e, actions: browser.error != nil ? [("Dismiss", { browser.error = nil })] : [])
                        .padding([.horizontal, .top], 14)
                }
                if rt.phase.isActive, browser.root != nil {
                    content(d)
                    Divider()
                    BrowserBottomBar(browser: browser, drive: d)
                } else {
                    NotMountedView(drive: d)
                }
            }
            .navigationTitle(rt.phase.isActive ? (browser.current?.standardizedFileURL == browser.root?.standardizedFileURL ? d.name : (browser.current?.lastPathComponent ?? d.name)) : d.name)
            .navigationSubtitle(rt.phase.isActive ? "\(browser.visibleItems.count) items" : rt.connection.label)
            .searchable(text: $browser.search, placement: .toolbar, prompt: "Search \(browser.current?.lastPathComponent ?? d.name)")
            .toolbar { toolbar(d, rt) }
            .inspector(isPresented: $browser.showInspector) {
                DriveInspector(drive: d, browser: browser)
                    .inspectorColumnWidth(min: 250, ideal: 280, max: 360)
            }
            .task(id: "\(rt.phase.isActive)|\(rt.mountPath ?? "")") {
                await browser.attach(mountPath: rt.phase.isActive ? rt.mountPath : nil)
            }
            .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Rename") { if let item = renaming { Task { await browser.rename(item, to: newName) } } }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(deleteTitle, isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })) {
                Button("Delete", role: .destructive) { let urls = pendingDelete; Task { await browser.delete(urls) } }
            } message: {
                Text(d.provider == .googleDrive
                     ? "Items go to the trash in your Google Drive, where you can restore them for 30 days."
                     : "Items are permanently deleted from your Oracle server. This cannot be undone.")
            }
        }
    }

    private var deleteTitle: String {
        pendingDelete.count == 1 ? "Delete “\(pendingDelete[0].lastPathComponent)”?" : "Delete \(pendingDelete.count) items?"
    }

    @ViewBuilder
    private func content(_ d: DriveConfiguration) -> some View {
        Group {
            switch browser.viewMode {
            case .icons: FileGridView(browser: browser, actions: actions)
            case .list: FileListView(browser: browser, actions: actions)
            }
        }
        .overlay {
            if browser.loading && browser.items.isEmpty {
                ProgressView().controlSize(.large)
            } else if !browser.loading && browser.visibleItems.isEmpty {
                ContentUnavailableView(browser.search.isEmpty ? "This folder is empty" : "No results",
                                       systemImage: browser.search.isEmpty ? "folder" : "magnifyingglass",
                                       description: Text(browser.search.isEmpty ? "Drag files here to upload them to \(d.name)." : "Nothing in this folder matches “\(browser.search)”."))
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await browser.receive(urls) }
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private var actions: FileActions {
        FileActions(
            rename: { item in newName = item.name; renaming = item },
            delete: { urls in pendingDelete = urls },
            download: { urls in Task { await browser.download(urls) } })
    }

    @ToolbarContentBuilder
    private func toolbar(_ d: DriveConfiguration, _ rt: DriveRuntime) -> some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            ControlGroup {
                Button { browser.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!browser.canGoBack).help("Back")
                Button { browser.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!browser.canGoForward).help("Forward")
            }
            .controlGroupStyle(.navigation)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if rt.phase.isActive {
                Picker("View", selection: $browser.viewMode) {
                    Image(systemName: "square.grid.2x2").tag(BrowserViewMode.icons).help("Icons")
                    Image(systemName: "list.bullet").tag(BrowserViewMode.list).help("List")
                }
                .pickerStyle(.segmented)
                Menu {
                    Picker("Sort By", selection: $browser.sort) {
                        Text("Name").tag(FileSort.name)
                        Text("Date Modified").tag(FileSort.modified)
                        Text("Size").tag(FileSort.size)
                        Text("Kind").tag(FileSort.kind)
                    }
                    Divider()
                    Toggle("Ascending", isOn: $browser.ascending)
                } label: { Image(systemName: "arrow.up.arrow.down") }
                .help("Sort")
                Menu {
                    Button("New Folder") { Task { await browser.newFolder() } }.keyboardShortcut("n", modifiers: [.command, .shift])
                    Button("Upload Files…") { Task { await browser.upload() } }
                    Divider()
                    Button("Reload") { Task { await browser.reload() } }.keyboardShortcut("r")
                    Button("Show in Finder") { AppActions.openInFinder(browser.current?.path) }
                } label: { Image(systemName: "ellipsis.circle") }
                .help("Actions")
                Button { Task { await drives.unmount(d.id, waitForUploads: false) } } label: { Image(systemName: "eject") }
                    .help("Eject \(d.name)")
            } else if rt.connection.isConfigured {
                Button { Task { await drives.mount(d.id) } } label: { Label("Mount", systemImage: "play.fill") }
                    .disabled(rt.phase == .mounting)
            }
            Button { browser.showInspector.toggle() } label: { Image(systemName: "sidebar.right") }
                .help("Show or hide info")
        }
    }
}

struct FileActions {
    var rename: (FileItem) -> Void
    var delete: ([URL]) -> Void
    var download: ([URL]) -> Void
}

// MARK: - Icon grid

struct FileGridView: View {
    @Bindable var browser: FileBrowserModel
    let actions: FileActions

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 128), spacing: 8)], spacing: 10) {
                ForEach(browser.visibleItems) { item in
                    FileTile(item: item, selected: browser.selection.contains(item.url))
                        .onTapGesture(count: 2) { browser.open(item) }
                        .onTapGesture { browser.select(item, extend: NSEvent.modifierFlags.contains(.command)) }
                        .contextMenu { FileContextMenu(item: item, browser: browser, actions: actions) }
                        .draggable(item.url)
                        .dropDestination(for: URL.self) { urls, _ in
                            guard item.isDirectory else { return false }
                            Task { await browser.receive(urls, into: item.url) }
                            return true
                        }
                }
            }
            .padding(16)
        }
        .contentShape(Rectangle())
        .onTapGesture { browser.selection = [] }
        .contextMenu { BackgroundContextMenu(browser: browser) }
    }
}

struct FileTile: View {
    let item: FileItem
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: FileIcons.icon(for: item))
                .resizable().interpolation(.high)
                .frame(width: 60, height: 60)
                .padding(6)
                .background(selected ? Color.primary.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
            Text(item.name)
                .font(.callout)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .foregroundStyle(selected ? .white : .primary)
                .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .frame(width: 104)
        .padding(.vertical, 4)
        .contentShape(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous))
        .help(item.name)
    }
}

// MARK: - List

struct FileListView: View {
    @Bindable var browser: FileBrowserModel
    let actions: FileActions

    var body: some View {
        Table(browser.visibleItems, selection: $browser.selection) {
            TableColumn("Name") { item in
                HStack(spacing: 8) {
                    Image(nsImage: FileIcons.icon(for: item)).resizable().frame(width: 18, height: 18)
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                }
                .draggable(item.url)
            }
            .width(min: 220, ideal: 340)
            TableColumn("Date Modified") { item in
                Text(item.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "--").foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 170)
            TableColumn("Size") { item in
                Text(item.isDirectory ? "--" : ByteFormat.string(item.size)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 90)
            TableColumn("Kind") { item in Text(FileIcons.kind(for: item)).foregroundStyle(.secondary) }
                .width(min: 80, ideal: 140)
        }
        .contextMenu(forSelectionType: URL.self) { urls in
            if let url = urls.first, let item = browser.items.first(where: { $0.url == url }), urls.count == 1 {
                FileContextMenu(item: item, browser: browser, actions: actions)
            } else if !urls.isEmpty {
                Button("Download \(urls.count) Items…") { actions.download(Array(urls)) }
                Divider()
                Button("Delete \(urls.count) Items…", role: .destructive) { actions.delete(Array(urls)) }
            } else {
                BackgroundContextMenu(browser: browser)
            }
        } primaryAction: { urls in
            if let url = urls.first, let item = browser.items.first(where: { $0.url == url }) { browser.open(item) }
        }
    }
}

// MARK: - Menus

struct FileContextMenu: View {
    let item: FileItem
    let browser: FileBrowserModel
    let actions: FileActions

    var body: some View {
        let targets = browser.selection.contains(item.url) && browser.selection.count > 1 ? Array(browser.selection) : [item.url]
        Button("Open") { browser.open(item) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        Divider()
        Button("Rename…") { actions.rename(item) }.disabled(targets.count > 1)
        Button(targets.count > 1 ? "Download \(targets.count) Items…" : "Download a Copy…") { actions.download(targets) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.url.path, forType: .string)
        }
        Divider()
        Button(targets.count > 1 ? "Delete \(targets.count) Items…" : "Delete…", role: .destructive) { actions.delete(targets) }
    }
}

struct BackgroundContextMenu: View {
    let browser: FileBrowserModel
    var body: some View {
        Button("New Folder") { Task { await browser.newFolder() } }
        Button("Upload Files…") { Task { await browser.upload() } }
        Divider()
        Button("Reload") { Task { await browser.reload() } }
        Button("Show in Finder") { AppActions.openInFinder(browser.current?.path) }
    }
}

// MARK: - Path bar + status bar

struct BrowserBottomBar: View {
    @Environment(DriveManager.self) private var drives
    let browser: FileBrowserModel
    let drive: DriveConfiguration

    var body: some View {
        let rt = drives.state(drive.id)
        VStack(spacing: 0) {
            if let root = browser.root, let current = browser.current {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        let crumbs = FileBrowsing.breadcrumbs(for: current, root: root, rootName: drive.name)
                        ForEach(Array(crumbs.enumerated()), id: \.offset) { i, c in
                            if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                            Button { browser.navigate(to: c.url) } label: {
                                Label(c.name, systemImage: i == 0 ? drive.provider.symbol : "folder.fill")
                                    .font(.caption)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(i == crumbs.count - 1 ? Color.primary.opacity(0.07) : .clear, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .dropDestination(for: URL.self) { urls, _ in
                                Task { await browser.receive(urls, into: c.url) }
                                return true
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .frame(height: 26)
                Divider().opacity(0.5)
            }
            HStack(spacing: 6) {
                Text(statusText).monospacedDigit()
                if let pending = rt.cache?.pendingUploads, pending > 0 {
                    Text("·")
                    ProgressView().controlSize(.mini)
                    Text("Uploading \(pending)")
                }
                if browser.loading { ProgressView().controlSize(.mini) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 24)
        }
        .background(.bar)
    }

    private var statusText: String {
        let rt = drives.state(drive.id)
        let n = browser.visibleItems.count
        let count = browser.selection.isEmpty ? "\(n) item\(n == 1 ? "" : "s")" : "\(browser.selection.count) of \(n) selected"
        return rt.usage?.free.map { "\(count), \(ByteFormat.string($0)) available" } ?? count
    }
}

// MARK: - Not mounted

struct NotMountedView: View {
    @Environment(DriveManager.self) private var drives
    let drive: DriveConfiguration
    @State private var showConnect = false

    var body: some View {
        let rt = drives.state(drive.id)
        ScrollView {
            VStack(spacing: 22) {
                DriveIconTile(provider: drive.provider, size: 84)
                VStack(spacing: 6) {
                    Text(drive.name).font(.largeTitle.weight(.semibold))
                    StatusLabel(text: rt.phase == .unmounted ? rt.connection.label : rt.phase.label, health: rt.health)
                }
                if rt.connection.isConfigured {
                    HStack(spacing: 28) {
                        CapacityRing(usage: rt.usage, size: 92, lineWidth: 9)
                        VStack(alignment: .leading, spacing: 6) {
                            stat("Used", ByteFormat.string(rt.usage?.used))
                            stat("Available", ByteFormat.string(rt.usage?.free))
                            stat("Total", ByteFormat.string(rt.usage?.total))
                        }
                    }
                    .premiumCard()
                }
                if let e = rt.lastError {
                    ErrorBanner(error: e, actions: e.category == .authentication || e == .notConfigured ? [("Review Account", { showConnect = true })] : [])
                        .frame(maxWidth: 520)
                }
                HStack(spacing: 12) {
                    if rt.connection.isConfigured {
                        Button { Task { await drives.mount(drive.id) } } label: {
                            Label(rt.phase == .mounting ? "Mounting…" : "Mount \(drive.name)", systemImage: "play.fill").frame(minWidth: 160)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(rt.phase == .mounting)
                        Button("Account…") { showConnect = true }.controlSize(.large)
                    } else {
                        Button { showConnect = true } label: {
                            Label(drive.provider == .googleDrive ? "Connect Google Drive" : "Connect Oracle Server", systemImage: "link").frame(minWidth: 200)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(drives.dependencies?.rclone == nil)
                    }
                }
                if drives.dependencies?.rclone == nil {
                    Text("Install rclone in Settings > Advanced first.").font(.callout).foregroundStyle(.orange)
                }
                Text(drive.provider == .googleDrive
                     ? "Files open on demand. Nothing is downloaded until you use it."
                     : "Connects over SSH with your key. Ekthar Drive never changes your server.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showConnect) {
            if drive.provider == .googleDrive { GoogleConnectSheet().environment(drives) } else { OracleConfigSheet().environment(drives) }
        }
        .task(id: drive.id) {
            if rt.usage == nil, rt.connection.isConfigured { await drives.refreshUsage(drive.id) }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
            Text(value).monospacedDigit().fontWeight(.medium)
        }
    }
}
