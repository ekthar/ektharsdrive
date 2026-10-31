import EktharDriveCore
import QuickLook
import SwiftUI

/// Finder-style view of one drive: toolbar navigation, icon/list content, path + status bar, inspector.
struct DriveBrowserView: View {
    @Environment(AppModel.self) private var model
    @Environment(DriveManager.self) private var drives
    @Bindable var browser: FileBrowserModel

    @State private var dropTargeted = false

    var body: some View {
        if let d = drives.drive(browser.driveID) {
            let rt = drives.state(d.id)
            VStack(spacing: 0) {
                if let e = browser.error ?? (rt.phase.isActive ? rt.lastError : nil) {
                    ErrorBanner(error: e, actions: browser.error != nil ? [("Dismiss", { withAnimation(Theme.spring) { browser.error = nil } })] : [])
                        .padding(.horizontal, 18).padding(.top, 14)
                }
                if rt.phase.isActive, browser.root != nil {
                    // Files scroll under the floating glass path bar.
                    content(d)
                        .safeAreaInset(edge: .bottom, spacing: 0) { BrowserBottomBar(browser: browser, drive: d) }
                        .transition(.opacity)
                } else {
                    NotMountedView(drive: d)
                        .transition(.opacity)
                }
            }
            .background(Theme.canvas)
            .animation(Theme.spring, value: rt.phase.isActive)
            .animation(Theme.spring, value: browser.error)
            .navigationTitle(rt.phase.isActive ? (browser.current?.standardizedFileURL == browser.root?.standardizedFileURL ? d.name : (browser.current?.lastPathComponent ?? d.name)) : d.name)
            .navigationSubtitle(rt.phase.isActive ? (browser.loading && browser.items.isEmpty ? "Loading…" : "\(browser.visibleItems.count) items") : rt.connection.label)
            .searchable(text: $browser.search, placement: .toolbar, prompt: "Search \(browser.current?.lastPathComponent ?? d.name)")
            .toolbar { toolbar(d, rt) }
            .focusedSceneValue(\.activeBrowser, rt.phase.isActive ? browser : nil)
            .quickLookPreview($browser.quickLookURL)
            .onKeyPress(.space) { browser.toggleQuickLook(); return .handled }
            .onKeyPress(.return) { guard browser.singleSelected != nil else { return .ignored }; browser.requestRename(); return .handled }
            .overlay(alignment: .bottom) {
                if let toast = browser.toast {
                    GlassToast(text: toast).padding(.bottom, 60)
                }
            }
            .animation(Theme.spring, value: browser.toast)
            .onChange(of: model.windowWidth, initial: true) { _, w in browser.fitInspector(windowWidth: w) }
            .inspector(isPresented: $browser.showInspector) {
                DriveInspector(drive: d, browser: browser)
                    .inspectorColumnWidth(min: 250, ideal: 280, max: 360)
            }
            .task(id: "\(rt.phase.isActive)|\(rt.mountPath ?? "")") {
                await browser.attach(mountPath: rt.phase.isActive ? rt.mountPath : nil)
            }
            // Speed: a file that stays selected for a moment has its start read ahead, so Space or
            // double-click opens from disk.
            .task(id: browser.singleSelected?.url) {
                guard drives.settings.prefetchSelection, let item = browser.singleSelected, !item.isDirectory else { return }
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                drives.warmStart(item.url)
            }
            // Speed: load the listings of the folders shown here, so opening any of them is instant.
            .task(id: "\(browser.current?.path ?? "")|\(browser.items.count)") {
                guard let root = browser.root, !browser.items.isEmpty else { return }
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                let dirs = browser.items.filter(\.isDirectory).compactMap { CloudActions.remotePath(of: $0.url, mountPath: root.path) }
                drives.prefetchListings(d.id, relativeDirs: dirs)
            }
            .alert("Rename", isPresented: Binding(get: { browser.renameTarget != nil }, set: { if !$0 { browser.renameTarget = nil } })) {
                TextField("Name", text: $browser.renameText)
                Button("Rename") { if let item = browser.renameTarget { let name = browser.renameText; Task { await browser.rename(item, to: name) } } }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(deleteTitle, isPresented: Binding(get: { !browser.deleteTargets.isEmpty }, set: { if !$0 { browser.deleteTargets = [] } })) {
                Button("Delete", role: .destructive) { let urls = browser.deleteTargets; Task { await browser.delete(urls) } }
            } message: {
                switch d.provider {
                case .googleDrive: Text("Items go to the trash in your Google Drive, where you can restore them for 30 days.")
                case .vault: Text("Items go to your Google Drive trash, still encrypted, for 30 days. Restoring them there brings them back to the vault.")
                case .oracleSFTP: Text("Items are permanently deleted from your Oracle server. This cannot be undone.")
                }
            }
        }
    }

    private var deleteTitle: String {
        browser.deleteTargets.count == 1 ? "Delete “\(browser.deleteTargets[0].lastPathComponent)”?" : "Delete \(browser.deleteTargets.count) items?"
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
            if browser.loading && browser.items.isEmpty && browser.viewMode == .list {
                ProgressView().controlSize(.regular)
            } else if !browser.loading && browser.visibleItems.isEmpty {
                EmptyStateView(title: browser.search.isEmpty ? "This folder is empty" : "No results",
                               message: browser.search.isEmpty ? "Drag files here to upload them to \(d.name)." : "Nothing in this folder matches “\(browser.search)”.",
                               symbol: browser.search.isEmpty ? "tray" : "magnifyingglass")
            }
        }
        .overlay {
            if dropTargeted {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Theme.accent.opacity(0.05))
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Theme.accent.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [9, 7]))
                    VStack(spacing: 10) {
                        Image(systemName: "arrow.down.doc.fill").font(.system(size: 34, weight: .medium)).foregroundStyle(Theme.accentGradient)
                        Text("Drop to upload to \(browser.current?.lastPathComponent ?? d.name)").font(.bodyStrong).foregroundStyle(Theme.accent)
                    }
                }
                .padding(14)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .allowsHitTesting(false)
            }
        }
        .animation(Theme.snappy, value: dropTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            Task { await browser.receive(urls) }
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private var actions: FileActions {
        FileActions(
            rename: { item in browser.requestRename(item) },
            delete: { urls in browser.requestDelete(urls) },
            download: { urls in Task { await browser.download(urls) } })
    }

    @ToolbarContentBuilder
    private func toolbar(_ d: DriveConfiguration, _ rt: DriveRuntime) -> some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            ControlGroup {
                Button { browser.goBack() } label: { Label("Back", systemImage: "chevron.left").labelStyle(.iconOnly) }
                    .disabled(!browser.canGoBack).help("Back")
                Button { browser.goForward() } label: { Label("Forward", systemImage: "chevron.right").labelStyle(.iconOnly) }
                    .disabled(!browser.canGoForward).help("Forward")
            }
            .controlGroupStyle(.navigation)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if rt.phase.isActive {
                Picker("View", selection: $browser.viewMode) {
                    Label("Icons", systemImage: "square.grid.2x2").labelStyle(.iconOnly).tag(BrowserViewMode.icons).help("Icons")
                    Label("List", systemImage: "list.bullet").labelStyle(.iconOnly).tag(BrowserViewMode.list).help("List")
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
                } label: { Label("Sort", systemImage: "arrow.up.arrow.down").labelStyle(.iconOnly) }
                .help("Sort")
                Menu {
                    Button("New Folder") { Task { await browser.newFolder() } }.keyboardShortcut("n", modifiers: [.command, .shift])
                    Button("Upload Files…") { Task { await browser.upload() } }
                    Divider()
                    Button("Reload") { Task { await browser.reload() } }.keyboardShortcut("r")
                    Button("Show in Finder") { AppActions.openInFinder(browser.current?.path) }
                } label: { Label("Actions", systemImage: "ellipsis.circle").labelStyle(.iconOnly) }
                .help("Actions")
                Button { Task { await drives.unmount(d.id, waitForUploads: false) } } label: { Label("Eject", systemImage: "eject").labelStyle(.iconOnly) }
                    .help("Eject \(d.name)")
            } else if rt.connection.isConfigured {
                Button { Task { await drives.mount(d.id) } } label: { Label("Mount", systemImage: "play.fill") }
                    .disabled(rt.phase == .mounting)
            }
            Button { browser.toggleInspector() } label: { Label(browser.showInspector ? "Hide Info" : "Show Info", systemImage: "sidebar.right").labelStyle(.iconOnly) }
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
    @Environment(DriveManager.self) private var drives
    @Bindable var browser: FileBrowserModel
    let actions: FileActions

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112, maximum: 132), spacing: 10)], spacing: 14) {
                if browser.loading && browser.items.isEmpty {
                    ForEach(0..<12, id: \.self) { _ in SkeletonTile() }
                }
                ForEach(Array(browser.visibleItems.enumerated()), id: \.element.id) { i, item in
                    // No entrance or selection animation: folders open and selection changes hundreds of times a day.
                    FileTile(item: item, selected: browser.selection.contains(item.url), previews: drives.settings.showPreviews)
                        .onTapGesture(count: 2) { browser.open(item) }
                        .onTapGesture { browser.select(item, extend: NSEvent.modifierFlags.contains(.command)) }
                        .contextMenu { FileContextMenu(item: item, browser: browser, actions: actions) }
                        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider(object: item.url as NSURL) }
                        .dropDestination(for: URL.self) { urls, _ in
                            guard item.isDirectory else { return false }
                            Task { await browser.receive(urls, into: item.url) }
                            return true
                        }
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 18)
        }
        .background(Theme.canvas)
        .contentShape(Rectangle())
        .onTapGesture { browser.selection = [] }
        .contextMenu { BackgroundContextMenu(browser: browser) }
    }
}

struct FileTile: View {
    let item: FileItem
    let selected: Bool
    var previews = true
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 8) {
            FileThumbnail(item: item, enabled: previews)
                .clipped()
                .shadow(color: .black.opacity(hovering ? 0.14 : 0), radius: 8, y: 5)

            VStack(spacing: 2) {
                Text(item.name)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(selected ? Theme.accent : Theme.ink)
                Text(FileIcons.sizeLabel(for: item))
                    .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(Theme.inkTertiary)
            }
        }
        .frame(width: 104)
        .padding(.vertical, 12).padding(.horizontal, 4)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(selected ? Theme.accentSoft : (hovering ? Theme.surface : .clear))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? Theme.accent.opacity(0.35) : .clear, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(Theme.snappy, value: hovering)
        .animation(Theme.snappy, value: selected)
        .onHover { hovering = $0 }
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
                .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider(object: item.url as NSURL) }
            }
            .width(min: 220, ideal: 340)
            TableColumn("Date Modified") { item in
                Text(item.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "--").foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 170)
            TableColumn("Size") { item in
                Text(item.isDirectory ? "--" : FileIcons.sizeLabel(for: item)).monospacedDigit().foregroundStyle(.secondary)
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
    @Environment(DriveManager.self) private var drives
    let item: FileItem
    let browser: FileBrowserModel
    let actions: FileActions

    var body: some View {
        let targets = browser.selection.contains(item.url) && browser.selection.count > 1 ? Array(browser.selection) : [item.url]
        Button("Open") { browser.open(item) }
        if !item.isDirectory {
            Button("Quick Look") { browser.quickLookURL = item.url }
            if FileIcons.isVideo(item) {
                Button("Play in QuickTime") {
                    let qt = URL(fileURLWithPath: "/System/Applications/QuickTime Player.app")
                    NSWorkspace.shared.open([item.url], withApplicationAt: qt, configuration: NSWorkspace.OpenConfiguration())
                }
            }
        }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        Divider()
        Button("Rename…") { actions.rename(item) }.disabled(targets.count > 1)
        Button(targets.count > 1 ? "Download \(targets.count) Items…" : "Download a Copy…") { actions.download(targets) }
        if let root = browser.root, let rel = CloudActions.remotePath(of: item.url, mountPath: root.path) {
            if let pin = drives.pin(for: browser.driveID, path: rel) {
                Button("Stop Keeping Offline") { drives.removeOffline(pin) }
            } else {
                Button("Keep Offline") {
                    drives.keepOffline(browser.driveID, path: rel)
                    browser.flash("Keeping “\(item.name)” on this Mac. See Cache for progress.")
                }
                .disabled(targets.count > 1)
            }
        }
        if drives.drive(browser.driveID)?.provider == .googleDrive {
            Button("Copy Share Link") { Task { await browser.copyShareLink(item, drives: drives) } }.disabled(targets.count > 1)
        }
        let others = drives.copyTargets(from: browser.driveID)
        if !others.isEmpty {
            Menu("Copy to") {
                ForEach(others) { t in
                    Button(t.name) {
                        let chosen = browser.items.filter { targets.contains($0.url) }
                        Task { await browser.copy(chosen, to: t, drives: drives) }
                    }
                    .disabled(!drives.state(t.id).connection.isConfigured)
                }
            }
        }
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
        HStack(spacing: 12) {
            if let root = browser.root, let current = browser.current {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        let crumbs = FileBrowsing.breadcrumbs(for: current, root: root, rootName: drive.name)
                        ForEach(Array(crumbs.enumerated()), id: \.offset) { i, c in
                            if i > 0 { Image(systemName: "chevron.compact.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.inkTertiary) }
                            let last = i == crumbs.count - 1
                            Button { browser.navigate(to: c.url) } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: i == 0 ? drive.provider.symbol : "folder.fill")
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(i == 0 ? drive.provider.tint : Theme.accent.opacity(0.8))
                                    Text(c.name).font(.system(size: 11.5, weight: last ? .semibold : .medium)).foregroundStyle(last ? Theme.ink : Theme.inkSecondary)
                                }
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(Capsule().fill(last ? Theme.canvas.opacity(0.75) : .clear))
                                .overlay(Capsule().strokeBorder(last ? Theme.hairline : .clear))
                            }
                            .buttonStyle(.plain)
                            .dropDestination(for: URL.self) { urls, _ in
                                Task { await browser.receive(urls, into: c.url) }
                                return true
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .clipShape(Capsule())
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if let pending = rt.cache?.pendingUploads, pending > 0 {
                    Pill(text: "\(pending)", color: Theme.accent, symbol: "arrow.up")
                        .fixedSize()
                        .help("\(pending) upload\(pending == 1 ? "" : "s") in progress")
                        .transition(.scale.combined(with: .opacity))
                }
                if let busy = browser.busyMessage {
                    ProgressView().controlSize(.mini)
                    Text(busy).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent).lineLimit(1)
                } else if browser.loading { ProgressView().controlSize(.mini) }
                ViewThatFits(in: .horizontal) {
                    Text(statusText).lineLimit(1)
                    Text(shortStatusText).lineLimit(1)
                }
                .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.trailing, 14)
            .animation(Theme.snappy, value: rt.cache?.pendingUploads)
        }
        .frame(height: 34)
        .glassCapsule()
        .padding(.horizontal, 12).padding(.bottom, 10)
    }

    private var shortStatusText: String {
        let n = browser.visibleItems.count
        return browser.selection.isEmpty ? "\(n) items" : "\(browser.selection.count) selected"
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
            VStack(spacing: 26) {
                ZStack {
                    Circle().fill(drive.provider.tint.opacity(0.08)).frame(width: 170, height: 170).blur(radius: 2)
                    Circle().strokeBorder(drive.provider.tint.opacity(0.10), lineWidth: 1).frame(width: 220, height: 220)
                    DriveIconTile(provider: drive.provider, size: 92)
                }
                .appearAnimation(index: 0, offset: 14)
                VStack(spacing: 8) {
                    Text(drive.name).displayStyle()
                    StatusLabel(text: rt.phase == .unmounted ? rt.connection.label : rt.phase.label, health: rt.health, pulsing: rt.phase.isBusy)
                }
                .appearAnimation(index: 1)
                if rt.connection.isConfigured {
                    HStack(spacing: 30) {
                        CapacityRing(usage: rt.usage, size: 104, lineWidth: 10)
                        VStack(alignment: .leading, spacing: 10) {
                            stat("Used", ByteFormat.string(rt.usage?.used))
                            stat("Available", ByteFormat.string(rt.usage?.free))
                            stat("Total", ByteFormat.string(rt.usage?.total))
                        }
                    }
                    .premiumCard(radius: 22, padding: 24)
                    .appearAnimation(index: 2)
                }
                if let e = rt.lastError {
                    ErrorBanner(error: e, actions: e.category == .authentication || e == .notConfigured ? [("Review Account", { showConnect = true })] : [])
                        .frame(maxWidth: 520)
                }
                HStack(spacing: 12) {
                    if rt.connection.isConfigured {
                        Button { Task { await drives.mount(drive.id) } } label: {
                            HStack(spacing: 7) {
                                if rt.phase == .mounting { ProgressView().controlSize(.small).tint(.white) } else { Image(systemName: "play.fill") }
                                Text(rt.phase == .mounting ? "Mounting…" : "Mount \(drive.name)")
                            }
                            .frame(minWidth: 190)
                        }
                        .buttonStyle(.primaryLarge)
                        .disabled(rt.phase == .mounting)
                        Button("Account…") { showConnect = true }.buttonStyle(.secondaryLarge)
                    } else {
                        Button { showConnect = true } label: {
                            Label(drive.provider == .googleDrive ? "Connect Google Drive" : (drive.provider == .vault ? "Unlock Vault" : "Connect Oracle Server"), systemImage: drive.provider == .vault ? "lock.open" : "link").frame(minWidth: 220)
                        }
                        .buttonStyle(.primaryLarge)
                        .disabled(drives.dependencies?.rclone == nil)
                    }
                }
                .appearAnimation(index: 3)
                if drives.dependencies?.rclone == nil {
                    Text("Install rclone in Settings > Advanced first.").font(.caption12).foregroundStyle(Theme.warning)
                }
                Text(drive.provider == .googleDrive
                     ? "Files open on demand. Nothing is downloaded until you use it."
                     : "Connects over SSH with your key. Ekthar Drive never changes your server.")
                    .font(.caption12).foregroundStyle(Theme.inkTertiary)
                    .appearAnimation(index: 4)
            }
            .padding(.vertical, 56).padding(.horizontal, 40)
            .frame(maxWidth: .infinity)
            .animation(Theme.spring, value: rt.phase)
        }
        .background(Theme.canvas)
        .sheet(isPresented: $showConnect) {
            ConnectSheet(provider: drive.provider).environment(drives)
        }
        .task(id: drive.id) {
            if rt.usage == nil, rt.connection.isConfigured { await drives.refreshUsage(drive.id) }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 14) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.inkTertiary).frame(width: 70, alignment: .leading)
            Text(value).font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(Theme.ink)
                .contentTransition(.numericText())
        }
    }
}


struct DetailWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
