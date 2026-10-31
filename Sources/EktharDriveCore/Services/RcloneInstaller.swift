import CryptoKit
import Foundation

/// Installs the official rclone build (which includes macFUSE support, unlike Homebrew's) into the app's
/// own bin directory. Only runs when the user clicks Install. Verifies the SHA-256 published by rclone.org.
public enum RcloneInstaller {
    public static let base = URL(string: "https://downloads.rclone.org")!

    public static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "amd64"
        #endif
    }

    public static func install(into binDirectory: URL, session: URLSession = .shared,
                               progress: (@Sendable (String) -> Void)? = nil) async throws(DriveError) -> RcloneBinary {
        do {
            progress?("Checking the latest rclone version…")
            let (vData, vResp) = try await session.data(from: base.appendingPathComponent("version.txt"))
            guard (vResp as? HTTPURLResponse)?.statusCode == 200 else { throw DriveError.remoteUnavailable("rclone.org did not return a version.") }
            let versionLine = String(decoding: vData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let version = versionLine.split(separator: " ").last.map(String.init),
                  version.range(of: #"^v\d+\.\d+\.\d+$"#, options: .regularExpression) != nil else {
                throw DriveError.remoteUnavailable("Unexpected version string from rclone.org.")
            }
            let zipName = "rclone-\(version)-osx-\(architecture).zip"

            progress?("Fetching checksums for rclone \(version)…")
            let (sums, _) = try await session.data(from: base.appendingPathComponent(version).appendingPathComponent("SHA256SUMS"))
            let sumsText = String(decoding: sums, as: UTF8.self)
            guard let expected = sumsText.split(whereSeparator: \.isNewline)
                .map({ $0.split(separator: " ", omittingEmptySubsequences: true) })
                .first(where: { $0.count == 2 && $0[1] == zipName })?[0].lowercased() else {
                throw DriveError.remoteUnavailable("No published checksum for \(zipName).")
            }

            progress?("Downloading \(zipName)…")
            let (tmpZip, zResp) = try await session.download(from: base.appendingPathComponent(version).appendingPathComponent(zipName))
            guard (zResp as? HTTPURLResponse)?.statusCode == 200 else { throw DriveError.remoteUnavailable("Download failed.") }
            let actual = SHA256.hash(data: try Data(contentsOf: tmpZip, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
            guard actual == String(expected) else {
                try? FileManager.default.removeItem(at: tmpZip)
                throw DriveError.permissionDenied("Checksum mismatch for the downloaded rclone. Nothing was installed.")
            }

            progress?("Installing…")
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("ekthar-rclone-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work); try? FileManager.default.removeItem(at: tmpZip) }
            let unzip = try await ProcessRunner().run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-x", "-k", tmpZip.path, work.path], timeout: .seconds(120))
            guard unzip.exitCode == 0 else { throw DriveError.unknown("Could not unpack rclone.") }
            let extracted = work.appendingPathComponent("rclone-\(version)-osx-\(architecture)/rclone")
            guard FileManager.default.fileExists(atPath: extracted.path) else { throw DriveError.unknown("The rclone archive had an unexpected layout.") }

            try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
            let target = binDirectory.appendingPathComponent("rclone")
            let previous = binDirectory.appendingPathComponent("rclone.previous")
            if FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.removeItem(at: previous)
                try FileManager.default.moveItem(at: target, to: previous) // keep the old binary
            }
            try FileManager.default.moveItem(at: extracted, to: target)
            try FilePermissions.set(target.path, mode: 0o755)
            guard let probed = await RcloneService.probe(target) else {
                if FileManager.default.fileExists(atPath: previous.path) {
                    try? FileManager.default.removeItem(at: target)
                    try? FileManager.default.moveItem(at: previous, to: target)
                }
                throw DriveError.unknown("The installed rclone did not run. The previous version was restored.")
            }
            progress?("Installed rclone \(probed.version).")
            return probed
        } catch let e as DriveError {
            throw e
        } catch {
            throw .remoteUnavailable("Could not download rclone: \(error.localizedDescription)")
        }
    }
}
