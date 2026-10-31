import Foundation
import os

/// OSLog wrapper that redacts every message first. Use instead of `print`.
public struct AppLogger: Sendable {
    private let logger: Logger

    public init(category: String) {
        logger = Logger(subsystem: "com.ekthar.drive", category: category)
    }

    public func info(_ message: String) { logger.info("\(Redactor.redact(message), privacy: .public)") }
    public func notice(_ message: String) { logger.notice("\(Redactor.redact(message), privacy: .public)") }
    public func warning(_ message: String) { logger.warning("\(Redactor.redact(message), privacy: .public)") }
    public func error(_ message: String) { logger.error("\(Redactor.redact(message), privacy: .public)") }
    public func debug(_ message: String) { logger.debug("\(Redactor.redact(message), privacy: .public)") }
}

/// Appends redacted rclone output to a per-drive log file, rotating at 5 MB (one previous file kept).
public final class RotatingLogFile: @unchecked Sendable {
    private let url: URL
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "com.ekthar.drive.logfile")
    private var handle: FileHandle?

    public init(url: URL, maxBytes: Int = 5 * 1024 * 1024) {
        self.url = url
        self.maxBytes = maxBytes
    }

    public func append(_ line: String) {
        let data = Data((Redactor.redact(line) + "\n").utf8)
        queue.async { [self] in
            do {
                if handle == nil {
                    if !FileManager.default.fileExists(atPath: url.path) {
                        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
                    }
                    handle = try FileHandle(forWritingTo: url)
                    try handle?.seekToEnd()
                }
                try handle?.write(contentsOf: data)
                if let size = try handle?.offset(), size > maxBytes { rotate() }
            } catch {
                handle = nil
            }
        }
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let old = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }

    public func flush() { queue.sync { try? handle?.synchronize() } }
}
