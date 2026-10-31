import AppKit
import EktharDriveCore
import SwiftUI

/// Google sign-in. Success is shown only after rclone stored a token AND Google answered a real API call.
struct GoogleConnectSheet: View {
    @Environment(DriveManager.self) private var drives
    @Environment(\.dismiss) private var dismiss
    var embedded = false

    @State private var useOwnClient = false
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var phase: Phase = .idle
    @State private var authURL: URL?

    enum Phase: Equatable { case idle, waiting, done, failed(DriveError) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !embedded {
                Label("Connect Google Drive", systemImage: "externaldrive.badge.icloud").font(.title2.weight(.semibold))
            }
            Text("Your browser will open Google's sign-in page. Ekthar Drive asks for full Drive access so it can show the files you already have. The sign-in token is stored in an encrypted file whose key is in your Keychain.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            DisclosureGroup("Use my own Google Cloud OAuth client (recommended)", isExpanded: $useOwnClient) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Without your own client, rclone's shared client is used. It works but has lower rate limits. See Documentation/GOOGLE_OAUTH_SETUP.md for the 5-minute setup.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Client ID (…apps.googleusercontent.com)", text: $clientID)
                    SecureField("Client secret", text: $clientSecret)
                }
                .textFieldStyle(.roundedBorder)
                .padding(.top, 6)
            }

            switch phase {
            case .idle: EmptyView()
            case .waiting:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in in your browser…")
                }
                if let authURL {
                    HStack {
                        Text("Browser did not open?").font(.caption).foregroundStyle(.secondary)
                        Link("Open the sign-in page", destination: authURL).font(.caption)
                    }
                }
            case .done:
                let rt = drives.state(drives.googleDrive?.id ?? "google")
                Label("Connected\(rt.accountLabel.map { " as \($0)" } ?? "")", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                CapacityView(usage: rt.usage)
            case .failed(let e):
                ErrorBanner(error: e)
            }

            HStack {
                Spacer()
                if !embedded { Button(phase == .done ? "Done" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                Button(phase == .waiting ? "Signing In…" : (phase == .done ? "Sign In Again" : "Sign In with Google")) { signIn() }
                    .buttonStyle(.borderedProminent)
                    .disabled(phase == .waiting || drives.dependencies?.rclone == nil || (useOwnClient && (clientID.isEmpty || clientSecret.isEmpty)))
                    .keyboardShortcut(.defaultAction)
            }
            if drives.dependencies?.rclone == nil {
                Text("Install rclone first (Settings > Advanced).").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(embedded ? 0 : 24)
        .frame(width: embedded ? nil : 520)
        .onAppear { clientID = drives.settings.googleClientID ?? ""; useOwnClient = !clientID.isEmpty }
    }

    private func signIn() {
        phase = .waiting
        authURL = nil
        Task {
            do {
                try await drives.connectGoogle(clientID: useOwnClient ? clientID.trimmingCharacters(in: .whitespaces) : nil,
                                               clientSecret: useOwnClient ? clientSecret : nil) { url in
                    Task { @MainActor in authURL = url }
                }
                phase = .done
            } catch {
                phase = .failed(.wrap(error))
            }
        }
    }
}

/// Oracle SFTP configuration: fetch host key -> user verifies fingerprint -> save -> real SFTP test.
struct OracleConfigSheet: View {
    @Environment(DriveManager.self) private var drives
    @Environment(\.dismiss) private var dismiss
    var embedded = false

    @State private var host = ""
    @State private var port = 22
    @State private var username = "ekthar-drive"
    @State private var keyPath = ""
    @State private var hasPassphrase = false
    @State private var passphrase = ""
    @State private var remoteDir = "/srv/ekthar-drive/files"
    @State private var keys: [HostKey] = []
    @State private var fingerprintConfirmed = false
    @State private var working = false
    @State private var error: DriveError?
    @State private var success = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !embedded { Label("Oracle Cloud server", systemImage: "server.rack").font(.title2.weight(.semibold)) }
            Form {
                Section("Server") {
                    TextField("Host name or IP", text: $host)
                    TextField("SSH port", value: $port, format: .number.grouping(.never))
                    TextField("SFTP user (not root)", text: $username)
                    TextField("Remote directory", text: $remoteDir)
                }
                Section("SSH key") {
                    HStack {
                        TextField("Private key file", text: $keyPath).truncationMode(.middle)
                        Button("Choose…") { chooseKey() }
                    }
                    Toggle("Key has a passphrase", isOn: $hasPassphrase)
                    if hasPassphrase { SecureField("Passphrase (stored in Keychain)", text: $passphrase) }
                }
                Section("Server identity") {
                    if keys.isEmpty {
                        Button("Fetch Server Fingerprint") { fetchKeys() }.disabled(host.isEmpty || working)
                        Text("Ekthar Drive only connects to a server whose host key you have verified.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(keys) { k in
                            LabeledContent(k.keyType) { Text(k.fingerprint).font(.caption.monospaced()).textSelection(.enabled) }
                        }
                        Text("On the server, run:  ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub  and check that it prints the same SHA256 value.")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Toggle("I compared the fingerprint and it matches", isOn: $fingerprintConfirmed)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: embedded ? 380 : 460)

            if let error { ErrorBanner(error: error) }
            if success { Label("Connected. Ekthar Drive listed \(remoteDir) on the server.", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }

            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                if !embedded { Button(success ? "Done" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                Button("Save and Test Connection") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(working || keys.isEmpty || !fingerprintConfirmed || keyPath.isEmpty || username.isEmpty || drives.dependencies?.rclone == nil)
            }
        }
        .padding(embedded ? 0 : 24)
        .frame(width: embedded ? nil : 560)
        .onAppear(perform: load)
        .onChange(of: host) { keys = []; fingerprintConfirmed = false }
        .onChange(of: port) { keys = []; fingerprintConfirmed = false }
    }

    private func load() {
        if let c = drives.sftpConnection {
            host = c.host; port = c.port; username = c.username; keyPath = c.privateKeyPath; hasPassphrase = c.keyHasPassphrase
        } else if FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.ssh/id_ed25519") {
            keyPath = NSHomeDirectory() + "/.ssh/id_ed25519"
        }
        remoteDir = drives.oracleDrive?.remotePath ?? remoteDir
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
        panel.message = "Choose the SSH private key for the SFTP user (not the .pub file)."
        if panel.runModal() == .OK, let url = panel.url { keyPath = url.path }
    }

    private func fetchKeys() {
        working = true; error = nil
        Task {
            do { keys = try await drives.scanOracleHostKeys(host: host.trimmingCharacters(in: .whitespaces), port: port) }
            catch { self.error = .wrap(error) }
            working = false
        }
    }

    private func save() {
        working = true; error = nil; success = false
        let h = host.trimmingCharacters(in: .whitespaces)
        let c = SFTPConnection(host: h, port: port, username: username.trimmingCharacters(in: .whitespaces),
                               privateKeyPath: keyPath, keyHasPassphrase: hasPassphrase)
        Task {
            do {
                if keyPath.hasSuffix(".pub") { throw DriveError.invalidConfiguration("Choose the private key, not the .pub file.") }
                try drives.trustOracleHostKeys(keys, host: h, port: port)
                try await drives.configureOracle(c, passphrase: hasPassphrase ? passphrase : nil, remoteDirectory: remoteDir)
                success = true
            } catch {
                self.error = .wrap(error)
            }
            working = false
        }
    }
}
