import Foundation
import Darwin

/// Talks to rclone's remote-control API over a Unix domain socket that lives in a 0700 directory.
/// No TCP port is opened, so no other user or machine can reach it, and no password is needed.
public struct RcClient: Sendable {
    public let socketPath: String
    public var timeoutSeconds: Int

    public init(socketPath: String, timeoutSeconds: Int = 10) {
        self.socketPath = socketPath
        self.timeoutSeconds = timeoutSeconds
    }

    public func call(_ method: String, params: [String: String] = [:]) async throws(DriveError) -> Data {
        let path = socketPath, timeout = timeoutSeconds
        let body = (try? JSONSerialization.data(withJSONObject: params)) ?? Data("{}".utf8)
        let result: Result<Data, DriveError> = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: Result { () throws(DriveError) -> Data in
                    try UnixHTTP.post(socketPath: path, path: "/" + method, body: body, timeoutSeconds: timeout)
                })
            }
        }
        return try result.get()
    }

    /// Calls an rc method with arbitrary JSON parameters (nested objects, booleans).
    public func callJSON(_ method: String, _ params: [String: any Sendable]) async throws(DriveError) -> [String: Any] {
        let path = socketPath, timeout = timeoutSeconds
        let body = (try? JSONSerialization.data(withJSONObject: params)) ?? Data("{}".utf8)
        let result: Result<Data, DriveError> = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: Result { () throws(DriveError) -> Data in
                    try UnixHTTP.post(socketPath: path, path: "/" + method, body: body, timeoutSeconds: timeout)
                })
            }
        }
        let data = try result.get()
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }

    public func decode<T: Decodable>(_ type: T.Type, _ method: String, params: [String: String] = [:]) async throws(DriveError) -> T {
        let data = try await call(method, params: params)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw .rcUnavailable("Unexpected response from rclone for \(method).")
        }
    }

    public func isResponsive() async -> Bool {
        (try? await call("rc/noop")) != nil
    }

    // MARK: Typed endpoints

    public func vfsStats() async throws(DriveError) -> RcVFSStats { try await decode(RcVFSStats.self, "vfs/stats") }
    public func coreStats() async throws(DriveError) -> RcCoreStats { try await decode(RcCoreStats.self, "core/stats") }
    public func transferred() async throws(DriveError) -> RcTransferred { try await decode(RcTransferred.self, "core/transferred") }
    public func vfsQueue() async throws(DriveError) -> RcVFSQueue { try await decode(RcVFSQueue.self, "vfs/queue") }
    public func about(fs: String) async throws(DriveError) -> RcAbout { try await decode(RcAbout.self, "operations/about", params: ["fs": fs]) }
}

// MARK: - Response models (field names match rclone's JSON)

public struct RcVFSStats: Decodable, Sendable {
    public struct DiskCache: Decodable, Sendable {
        public var bytesUsed: Int64
        public var erroredFiles: Int
        public var files: Int
        public var outOfSpace: Bool
        public var uploadsInProgress: Int
        public var uploadsQueued: Int
        public var path: String?
    }
    public var diskCache: DiskCache?
    public var fs: String?
}

public struct RcTransferring: Decodable, Sendable, Equatable {
    public var name: String
    public var bytes: Int64
    public var size: Int64?
    public var speed: Double?
    public var speedAvg: Double?
    public var eta: Double?
    public var percentage: Int?
    public var srcFs: String?
    public var dstFs: String?
    public var group: String?
}

public struct RcCoreStats: Decodable, Sendable {
    public var bytes: Int64?
    public var speed: Double?
    public var errors: Int?
    public var lastError: String?
    public var transferring: [RcTransferring]?
    public var transfers: Int?
}

public struct RcCompletedTransfer: Decodable, Sendable, Equatable {
    public var name: String
    public var size: Int64?
    public var bytes: Int64?
    public var error: String?
    public var checked: Bool?
    public var startedAt: String?
    public var completedAt: String?
    public var srcFs: String?
    public var dstFs: String?
    public var group: String?

    enum CodingKeys: String, CodingKey {
        case name, size, bytes, error, checked, group, srcFs, dstFs
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }
}

public struct RcTransferred: Decodable, Sendable {
    public var transferred: [RcCompletedTransfer]?
}

public struct RcVFSQueue: Decodable, Sendable {
    public struct Item: Decodable, Sendable, Equatable {
        public var name: String
        public var id: Int64?
        public var size: Int64?
        public var expiry: Double?
        public var tries: Int?
        public var delay: Double?
        public var uploading: Bool?
    }
    public var queue: [Item]?
}

public struct RcAbout: Decodable, Sendable {
    public var total: Int64?
    public var used: Int64?
    public var free: Int64?
    public var trashed: Int64?
    public var other: Int64?

    public var usage: StorageUsage { StorageUsage(total: total, used: used, free: free, trashed: trashed) }
}

// MARK: - Minimal HTTP/1.1 over AF_UNIX

enum UnixHTTP {
    static func post(socketPath: String, path: String, body: Data, timeoutSeconds: Int) throws(DriveError) -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .rcUnavailable("socket() failed") }
        defer { close(fd) }

        var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else { throw .rcUnavailable("Control socket path is too long.") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw .rcUnavailable("The filesystem process is not answering (\(String(cString: strerror(errno)))).") }

        var request = Data("POST \(path) HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        request.append(body)
        try request.withUnsafeBytes { (raw: UnsafeRawBufferPointer) throws(DriveError) in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard n > 0 else { throw .rcUnavailable("Write to control socket failed.") }
                offset += n
            }
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 { response.append(contentsOf: buffer[0..<n]) }
            else if n == 0 { break }
            else { throw .timeout("rclone did not answer \(path) within \(timeoutSeconds)s.") }
        }
        return try parse(response, path: path)
    }

    static func parse(_ response: Data, path: String) throws(DriveError) -> Data {
        guard let sep = response.range(of: Data("\r\n\r\n".utf8)) else { throw .rcUnavailable("Malformed reply from rclone.") }
        let head = String(decoding: response[..<sep.lowerBound], as: UTF8.self)
        var body = Data(response[sep.upperBound...])
        let lines = head.components(separatedBy: "\r\n")
        let status = lines.first.flatMap { Int($0.split(separator: " ").dropFirst().first ?? "") } ?? 0
        let chunked = lines.contains { $0.lowercased().hasPrefix("transfer-encoding:") && $0.lowercased().contains("chunked") }
        if chunked { body = dechunk(body) }
        guard (200..<300).contains(status) else {
            let msg = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? String
            throw .rcUnavailable("rclone \(path) returned \(status): \(Redactor.redact(msg ?? "error"))")
        }
        return body
    }

    static func dechunk(_ data: Data) -> Data {
        var out = Data()
        var index = data.startIndex
        let crlf = Data("\r\n".utf8)
        while index < data.endIndex {
            guard let lineEnd = data.range(of: crlf, in: index..<data.endIndex) else { break }
            let sizeText = String(decoding: data[index..<lineEnd.lowerBound], as: UTF8.self).split(separator: ";").first ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size > 0 else { break }
            let start = lineEnd.upperBound
            let end = data.index(start, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
            out.append(data[start..<end])
            index = data.index(end, offsetBy: 2, limitedBy: data.endIndex) ?? data.endIndex
        }
        return out
    }
}
