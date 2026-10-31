import AppKit
import EktharDriveCore
import SwiftUI

/// A drop zone that appears under the menu bar while you drag files toward the top of the screen.
/// Drop on a drive to copy the files into it; they upload in the background.
///
/// How it works: a mouse monitor (no Accessibility permission needed for mouse events) watches drags.
/// When the drag pasteboard holds files and the pointer comes within reach of the menu bar, a small
/// floating panel shows one target per mounted drive. It hides when the drag ends.
@MainActor
@Observable
public final class DropZoneController {
    @ObservationIgnored private weak var drives: DriveManager?
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var dragChangeCount = -1
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    /// Shown in the panel after a drop ("Added 3 items to Google Drive").
    var result: String?
    var busy = false
    /// How close to the menu bar the pointer must come, in points.
    static let reach: CGFloat = 70

    public init() {}

    public func start(drives: DriveManager) {
        self.drives = drives
        guard monitors.isEmpty else { return }
        let handler: (NSEvent) -> Void = { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
        }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { e in handler(e); return e }) { monitors.append(l) }
    }

    public func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        panel?.orderOut(nil)
    }

    private func handle(_ e: NSEvent) {
        guard let drives, drives.settings.menuBarDropZone else { return }
        switch e.type {
        case .leftMouseDown:
            // The drag pasteboard keeps the last drag's files. Only a drag that starts after this press counts,
            // so moving a window to the top of the screen never opens the panel.
            dragChangeCount = NSPasteboard(name: .drag).changeCount
        case .leftMouseDragged:
            let pb = NSPasteboard(name: .drag)
            guard pb.changeCount != dragChangeCount else { return }
            let point = NSEvent.mouseLocation
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return }
            let nearTop = point.y >= screen.frame.maxY - (screen.frame.maxY - screen.visibleFrame.maxY) - Self.reach
            guard nearTop, panel?.isVisible != true else { return }
            guard pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return }
            guard drives.drives.contains(where: { drives.state($0.id).phase == .mounted }) else { return }
            show(at: point, on: screen)
        case .leftMouseUp:
            // A drop lands after mouse-up; give it a moment, then hide unless a copy is running.
            scheduleHide(after: busy || result != nil ? 2.0 : 0.35)
        default: break
        }
    }

    private func show(at point: NSPoint, on screen: NSScreen) {
        hideTask?.cancel()
        result = nil
        let size = NSSize(width: 300, height: 74 + CGFloat(mountedCount) * 46)
        let x = min(max(point.x - size.width / 2, screen.frame.minX + 8), screen.frame.maxX - size.width - 8)
        let y = screen.visibleFrame.maxY - size.height - 6
        let p = panel ?? makePanel()
        p.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        p.orderFrontRegardless()
        panel = p
    }

    private var mountedCount: Int { drives?.drives.filter { drives?.state($0.id).phase == .mounted }.count ?? 1 }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        if let drives {
            p.contentView = NSHostingView(rootView: DropZoneView(controller: self).environment(drives))
        }
        return p
    }

    func scheduleHide(after seconds: Double) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, !self.busy else { return }
            self.panel?.orderOut(nil)
            self.result = nil
        }
    }

    /// Copies dropped files into the top of the drive. Name clashes get " 2", never overwrite.
    func receive(_ urls: [URL], into driveID: String) async {
        guard let drives, let d = drives.drive(driveID), let mount = drives.state(driveID).mountPath else { return }
        let root = URL(fileURLWithPath: mount, isDirectory: true)
        busy = true
        hideTask?.cancel()
        defer { busy = false; scheduleHide(after: 1.8) }
        do {
            let copied = try await FileBrowsing.copyIn(urls, to: root, root: root)
            result = "Added \(copied.count) item\(copied.count == 1 ? "" : "s") to \(d.name)"
            drives.log(driveID, "transfer", "Dropped \(copied.count) item\(copied.count == 1 ? "" : "s") on the menu bar drop zone; uploading to \(d.name).", .info)
        } catch let e {
            result = "Could not add: \(e.title)"
            drives.log(driveID, "transfer", "Menu bar drop failed: \(e.title). \(e.detail)", .error)
        }
    }
}

struct DropZoneView: View {
    let controller: DropZoneController
    @Environment(DriveManager.self) private var drives

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.to.line.circle.fill").foregroundStyle(Theme.accent)
                Text(controller.result ?? (controller.busy ? "Copying…" : "Drop to upload")).font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.ink).lineLimit(1)
                Spacer()
                if controller.busy { ProgressView().controlSize(.small) }
            }
            ForEach(drives.drives.filter { drives.state($0.id).phase == .mounted }) { d in
                DropTarget(drive: d, controller: controller)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glass(cornerRadius: 18)
        .padding(2)
    }
}

private struct DropTarget: View {
    let drive: DriveConfiguration
    let controller: DropZoneController
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 10) {
            DriveIconTile(provider: drive.provider, size: 26)
            Text(drive.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
            Spacer()
            Image(systemName: targeted ? "plus.circle.fill" : "plus.circle").foregroundStyle(targeted ? Theme.accent : Theme.inkTertiary)
        }
        .padding(.horizontal, 10).frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(targeted ? Theme.accentSoft : Theme.canvas.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(targeted ? Theme.accent.opacity(0.6) : Theme.hairline))
        .animation(Theme.press, value: targeted)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            Task { await controller.receive(files, into: drive.id) }
            return true
        } isTargeted: { targeted = $0 }
        .accessibilityLabel("Drop files to upload to \(drive.name)")
    }
}
