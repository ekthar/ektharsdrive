import AppKit
import CryptoKit
import EktharDriveCore
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// Real previews for images, PDFs and videos. Made only for tiles on screen, at most three at a time,
/// and kept in memory and on disk (keyed by path, size and date), so scrolling back never reads again.
@MainActor
final class Thumbnails {
    static let shared = Thumbnails()

    private let memory = NSCache<NSString, CGImageBox>()
    private let limiter = ConcurrencyLimiter(3)
    private let directory: URL
    /// Files that could not be previewed, so they are not tried again this session.
    private var failed: Set<String> = []

    private init() {
        memory.countLimit = 600
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EktharDrive/thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Images and PDFs up to 40 MB (Quick Look reads the whole file); videos of any size (it reads a frame).
    static func isEligible(_ item: FileItem) -> Bool {
        guard !item.isDirectory, let t = UTType(filenameExtension: item.pathExtension) else { return false }
        if t.conforms(to: .movie) || t.conforms(to: .video) { return true }
        guard t.conforms(to: .image) || t.conforms(to: .pdf) else { return false }
        return (item.size ?? 0) <= 40 << 20
    }

    static func key(_ item: FileItem) -> String {
        let raw = "\(item.url.path)|\(item.size ?? -1)|\(item.modified?.timeIntervalSince1970 ?? 0)"
        return SHA256.hash(data: Data(raw.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    func cached(_ item: FileItem) -> CGImage? { memory.object(forKey: Self.key(item) as NSString)?.image }

    func thumbnail(for item: FileItem, pixels: Int = 192) async -> CGImage? {
        let key = Self.key(item)
        if let hit = memory.object(forKey: key as NSString) { return hit.image }
        guard !failed.contains(key) else { return nil }
        let file = directory.appendingPathComponent(key + ".png")
        if let disk = await Task.detached(priority: .utility, operation: { Self.load(file) }).value {
            memory.setObject(CGImageBox(disk), forKey: key as NSString)
            return disk
        }
        await limiter.acquire()
        defer { Task { await limiter.release() } }
        guard !Task.isCancelled else { return nil } // scrolled away while waiting
        let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: pixels, height: pixels),
                                                   scale: 1, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            failed.insert(key)
            return nil
        }
        let image = rep.cgImage
        memory.setObject(CGImageBox(image), forKey: key as NSString)
        Task.detached(priority: .background) { Self.save(image, to: file) }
        return image
    }

    nonisolated private static func load(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    nonisolated private static func save(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}

final class CGImageBox: NSObject {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// Simple async semaphore.
actor ConcurrencyLimiter {
    private var free: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ n: Int) { free = n }
    func acquire() async {
        if free > 0 { free -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { free += 1 } else { waiters.removeFirst().resume() }
    }
}

/// The tile's picture: the file-type icon at once, replaced by a real preview when one is ready.
struct FileThumbnail: View {
    let item: FileItem
    var enabled = true
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.hairlineStrong, lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
                if FileIcons.isVideo(item) {
                    Image(systemName: "play.circle.fill").font(.system(size: 18)).symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.45))
                }
            } else {
                Image(decorative: FileIcons.bitmap(for: item), scale: 2).resizable().interpolation(.high)
            }
        }
        .frame(width: 64, height: 64)
        .task(id: enabled ? Thumbnails.key(item) : "") {
            guard enabled, Thumbnails.isEligible(item) else { image = nil; return }
            if let hit = Thumbnails.shared.cached(item) { image = hit; return }
            // Short wait so fast scrolling does not start reads for tiles that are only passing by.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            image = await Thumbnails.shared.thumbnail(for: item)
        }
    }
}
