import Foundation
import os

public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    public static func string(_ bytes: Int64?) -> String {
        guard let bytes else { return "Unavailable" }
        return string(bytes)
    }

    public static func speed(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return "--" }
        return string(Int64(bytesPerSecond)) + "/s"
    }

    /// rclone size suffix, e.g. 8589934592 -> "8192M".
    public static func rcloneSize(_ bytes: Int64) -> String {
        if bytes % .gibibyte == 0 { return "\(bytes / .gibibyte)G" }
        if bytes % .mebibyte == 0 { return "\(bytes / .mebibyte)M" }
        if bytes % .kibibyte == 0 { return "\(bytes / .kibibyte)K" }
        return "\(bytes)B"
    }
}

/// Bounded exponential backoff: 2s, 5s, 15s, 30s, 60s, then give up.
public struct RetryPolicy: Sendable, Equatable {
    public var delays: [Duration]

    public init(delays: [Duration] = [.seconds(2), .seconds(5), .seconds(15), .seconds(30), .seconds(60)]) {
        self.delays = delays
    }

    public static let standard = RetryPolicy()

    /// Delay before retry number `attempt` (1-based), or `nil` when retries are exhausted.
    public func delay(forAttempt attempt: Int, maxAttempts: Int? = nil) -> Duration? {
        let limit = min(maxAttempts ?? delays.count, delays.count)
        guard attempt >= 1, attempt <= limit else { return nil }
        return delays[attempt - 1]
    }
}

/// A tiny thread-safe box for state shared with Foundation callbacks.
public final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var value: Value

    public init(_ value: Value) { self.value = value }

    public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    public var current: Value { withLock { $0 } }
}

/// Fixed-size ring buffer of recent log lines.
public struct RingBuffer<Element: Sendable>: Sendable {
    public private(set) var elements: [Element] = []
    public let capacity: Int

    public init(capacity: Int) { self.capacity = max(1, capacity) }

    public mutating func append(_ element: Element) {
        elements.append(element)
        if elements.count > capacity { elements.removeFirst(elements.count - capacity) }
    }

    public mutating func removeAll() { elements.removeAll() }
}
