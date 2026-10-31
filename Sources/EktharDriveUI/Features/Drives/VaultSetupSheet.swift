import EktharDriveCore
import SwiftUI

/// Creates a vault, or unlocks an existing one with its password.
struct VaultSetupSheet: View {
    @Environment(DriveManager.self) private var drives
    @Environment(\.dismiss) private var dismiss
    /// The vault is already set up on this Mac and only needs its password.
    let existing: Bool
    @State private var password = ""
    @State private var confirm = ""
    @State private var savedIt = false
    @State private var working = false
    @State private var error: DriveError?

    private var problem: String? {
        existing ? (password.isEmpty ? "Enter the vault password." : nil)
                 : VaultProvider.passwordProblem(password, confirm: confirm)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                DriveIconTile(provider: .vault, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(existing ? "Unlock Vault" : "Set Up Vault").titleStyle()
                    Text("Folder “\(VaultProvider.defaultFolder)” in your Google Drive").font(.caption12).secondaryText()
                }
            }
            if let error { ErrorBanner(error: error) }
            Form {
                SecureField("Password", text: $password)
                if !existing {
                    SecureField("Confirm password", text: $confirm)
                }
            }
            .formStyle(.grouped)
            .frame(height: existing ? 80 : 120)
            if !existing {
                VStack(alignment: .leading, spacing: 6) {
                    Label("The password is the only key. Nobody can reset it, not even Google or Ekthar Drive.", systemImage: "key.fill")
                    Label("Already have a vault folder from another Mac? Enter the same password to open it.", systemImage: "arrow.triangle.2.circlepath")
                    Label("It is saved in this Mac's Keychain. Lock the vault to remove it.", systemImage: "lock")
                }
                .font(.caption12).foregroundStyle(Theme.inkSecondary)
                Toggle("I wrote this password down somewhere safe", isOn: $savedIt)
            }
            if let problem, !password.isEmpty { Text(problem).font(.caption12).foregroundStyle(Theme.warning) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    working = true
                    Task {
                        defer { working = false }
                        do { try await drives.setUpVault(password: password); dismiss() } catch let e { error = .wrap(e) }
                    }
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Text(existing ? "Unlock" : "Create Vault") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil || working || (!existing && !savedIt))
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}

/// The right connect / unlock sheet for a provider.
struct ConnectSheet: View {
    @Environment(DriveManager.self) private var drives
    let provider: ProviderKind
    var body: some View {
        switch provider {
        case .googleDrive: GoogleConnectSheet()
        case .oracleSFTP: OracleConfigSheet()
        case .vault: VaultSetupSheet(existing: drives.vaultDrive != nil)
        }
    }
}
