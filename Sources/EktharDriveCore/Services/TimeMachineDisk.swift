import Foundation

/// Time Machine on a cloud drive.
///
/// Time Machine only backs up to a local disk or an SMB share that advertises Time Machine. A rclone
/// volume (NFS or macFUSE) is neither, so macOS hides it. The fix is the one Apple's own network backups
/// use: an APFS sparse bundle disk image stored ON the drive. Attached, it is an ordinary external APFS
/// disk, which Time Machine accepts. Its 16 MB bands are plain files, so rclone uploads only the bands
/// that change.
public enum TimeMachineDisk {
    public static let bundleName = "Ekthar Time Machine.sparsebundle"
    public static let volumeName = "Ekthar Time Machine"
    static let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")

    public static func bundleURL(mountPath: String) -> URL {
        URL(fileURLWithPath: mountPath).appendingPathComponent(bundleName, isDirectory: true)
    }

    public static func exists(mountPath: String) -> Bool {
        FileManager.default.fileExists(atPath: bundleURL(mountPath: mountPath).appendingPathComponent("Info.plist").path)
    }

    /// Where the attached disk appears, or nil when it is not attached.
    public static var attachedVolume: String? {
        let p = "/Volumes/\(volumeName)"
        return MountTable.isMounted(p) ? p : nil
    }

    /// The one command the user runs once (Time Machine settings need an admin password).
    public static var setDestinationCommand: String { "sudo tmutil setdestination -a \"/Volumes/\(volumeName)\"" }

    /// Arguments for creating the image. Growable up to `sizeGB`; it only takes the space it uses.
    static func createArguments(bundle: URL, sizeGB: Int) -> [String] {
        ["create", "-size", "\(sizeGB)g", "-type", "SPARSEBUNDLE", "-fs", "APFS", "-volname", volumeName,
         "-imagekey", "sparse-band-size=32768", bundle.path]
    }

    public static func create(mountPath: String, sizeGB: Int) async throws(DriveError) {
        guard (50...16_000).contains(sizeGB) else { throw .invalidConfiguration("Pick a size between 50 GB and 16 TB.") }
        let bundle = bundleURL(mountPath: mountPath)
        guard !FileManager.default.fileExists(atPath: bundle.path) else { throw .invalidConfiguration("A Time Machine disk already exists on this drive.") }
        try await run(createArguments(bundle: bundle, sizeGB: sizeGB), timeout: .seconds(300), what: "Creating the backup disk")
    }

    /// Attaches the image (no Finder window; owners on, as Time Machine requires).
    public static func attach(mountPath: String) async throws(DriveError) {
        guard attachedVolume == nil else { return }
        try await run(["attach", "-nobrowse", "-owners", "on", bundleURL(mountPath: mountPath).path], timeout: .seconds(180), what: "Opening the backup disk")
    }

    /// Detaches without force: macOS refuses while Time Machine is writing, and then the drive stays mounted.
    public static func detach() async throws(DriveError) {
        guard let v = attachedVolume else { return }
        do {
            try await run(["detach", v], timeout: .seconds(120), what: "Closing the backup disk")
        } catch {
            throw .mountPointBusy(path: "/Volumes/\(volumeName)")
        }
    }

    @discardableResult
    static func run(_ args: [String], timeout: Duration, what: String) async throws(DriveError) -> ProcessResult {
        let r: ProcessResult
        do {
            r = try await ProcessRunner().run(hdiutil, arguments: args, environment: SafeEnvironment.base(extra: [:]), stdin: nil, timeout: timeout)
        } catch { throw .unknown("\(what) failed: \(error.localizedDescription)") }
        guard r.succeeded else {
            throw .unknown("\(what) failed: \(Redactor.redact(ErrorClassifier.lastMeaningfulLine(r.combinedLines) ?? "hdiutil exit \(r.exitCode)"))")
        }
        return r
    }
}
