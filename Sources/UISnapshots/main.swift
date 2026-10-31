// Renders the real app window offscreen with sample data and writes PNGs.
// Usage: swift run UISnapshots <output-dir>
// Uses its own temporary data folder and an in-memory secret store; it never touches the user's drives.
import AppKit
import EktharDriveCore
import EktharDriveUI
import SwiftUI

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "snapshots", isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
NSApp.appearance = NSAppearance(named: .aqua)

@MainActor
func makeSampleFolder(_ root: URL) {
    let fm = FileManager.default
    try? fm.removeItem(at: root)
    for d in ["Projects", "Photos 2026", "Invoices", "Design Assets", "Backups"] {
        try? fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
    }
    let files: [(String, Int)] = [("Quarterly Report.pdf", 2_400_000), ("Pitch Deck.key", 48_000_000), ("Budget 2026.xlsx", 310_000),
                                  ("Product Demo.mp4", 820_000_000), ("Logo.svg", 24_000), ("Contract.docx", 120_000),
                                  ("Sunset.jpg", 6_100_000), ("Notes.txt", 3_000), ("Archive.zip", 706_000_000)]
    for (name, size) in files {
        let url = root.appendingPathComponent(name)
        fm.createFile(atPath: url.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: url) { try? h.truncate(atOffset: UInt64(size)); try? h.close() }
    }
}

@MainActor
func snapshot(_ view: some View, size: CGSize, name: String, settle: Double = 1.6) async {
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -10000, y: -10000), size: size),
                          styleMask: [.titled, .fullSizeContentView, .resizable, .closable, .miniaturizable], backing: .buffered, defer: false)
    window.titlebarAppearsTransparent = false
    window.contentView = host
    window.setContentSize(size)
    window.orderFrontRegardless()
    // Let async loads and entrance animations finish.
    try? await Task.sleep(for: .seconds(settle))
    host.layoutSubtreeIfNeeded()
    guard let frameView = window.contentView?.superview,
          let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
    frameView.cacheDisplay(in: frameView.bounds, to: rep)
    if let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: out.appendingPathComponent("\(name).png"))
        print("wrote \(name).png")
    }
    window.orderOut(nil)
}

Task { @MainActor in
    let base = out.appendingPathComponent(".state")
    try? FileManager.default.removeItem(at: base)
    let paths = AppPaths(supportDirectory: base.appendingPathComponent("s"), cacheRoot: base.appendingPathComponent("c"), logsDirectory: base.appendingPathComponent("l"))
    try? paths.prepare()
    let db = try! AppDatabase(url: paths.databaseURL)
    var settings = AppSettings()
    settings.setupCompleted = true
    settings.theme = .light
    try? db.setSetting("app", String(decoding: try! JSONEncoder().encode(settings), as: UTF8.self))
    try? db.setSetting("ui.whiteTheme", "1")
    let drives = DriveManager(paths: paths, secrets: InMemorySecretStore(), database: db)
    await drives.start()

    let sample = base.appendingPathComponent("Google Drive")
    makeSampleFolder(sample)
    drives.update("google") {
        $0.connection = .connected(at: Date())
        $0.phase = .mounted
        $0.mountPath = sample.path
        $0.engine = .nfs
        $0.accountLabel = "ekthar@example.com"
        $0.lastSuccessfulConnection = Date().addingTimeInterval(-300)
        $0.usage = StorageUsage(total: 5 * 1024 * .gibibyte, used: Int64(3.2 * 1024) * .gibibyte, free: Int64(1.8 * 1024) * .gibibyte)
        $0.cache = CacheStats(bytesUsed: 9_400_000, files: 5, uploadsInProgress: 1, uploadsQueued: 1, source: .liveProcess)
        $0.lastError = nil
    }
    drives.update("oracle") {
        $0.connection = .unverified
        $0.phase = .unmounted
        $0.usage = StorageUsage(total: 200 * .gibibyte, used: 42 * .gibibyte, free: 158 * .gibibyte)
        $0.lastError = nil
    }
    for (msg, sev) in [("Google Drive mounted at ~/Volumes/Google Drive.", Severity.info),
                       ("Uploaded Quarterly Report.pdf (2.4 MB).", .info),
                       ("Oracle Drive connection test succeeded.", .info),
                       ("Google rate limit reached; retrying in 2 s.", .warning)] {
        drives.log("google", "demo", msg, sev)
    }

    let model = AppModel(drives: drives)
    let size = CGSize(width: 1320, height: 840)
    func root() -> some View { RootView().environment(model).environment(drives) }

    if CommandLine.arguments.contains("--small") {
        // The size of the user's window in their screenshot.
        let small = CGSize(width: 930, height: 620)
        model.select(.drive("google"))
        await snapshot(root(), size: small, name: "small-browser", settle: 2.4)
        model.select(.dashboard)
        await snapshot(root(), size: small, name: "small-overview", settle: 2.2)
        exit(0)
    }
    model.select(.dashboard)
    await snapshot(root(), size: size, name: "1-overview", settle: 2.2)
    model.select(.drive("google"))
    await snapshot(root(), size: size, name: "2-browser-icons", settle: 2.4)
    model.select(.drive("oracle"))
    await snapshot(root(), size: size, name: "3-not-mounted", settle: 2.2)
    exit(0)
}

app.run()
