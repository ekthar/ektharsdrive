import EktharDriveCore
import QuickLook
import SwiftUI

/// Google's Starred or Trash list, read from Google directly (not by walking the mounted volume).
struct CollectionView: View {
    @Environment(DriveManager.self) private var drives
    let driveID: String
    let kind: CloudActions.Collection

    @State private var entries: [RemoteEntry] = []
    @State private var loading = false
    @State private var error: DriveError?
    @State private var selection: RemoteEntry.ID?
    @State private var confirmRestore = false
    @State private var quickLook: URL?
    @State private var toast: String?

    private var title: String { kind == .starred ? "Starred" : "Trash" }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error { ErrorBanner(error: error).padding(.horizontal, 24).padding(.bottom, 12) }
            if drives.cloudActions(driveID) == nil {
                EmptyStateView(title: "Mount Google Drive first", message: "Starred and Trash are read from your mounted drive.", symbol: "externaldrive.badge.exclamationmark")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if loading && entries.isEmpty {
                VStack(spacing: 10) { ForEach(0..<6, id: \.self) { _ in RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceSunken).frame(height: 34) } }
                    .shimmer().padding(24)
                Spacer()
            } else if entries.isEmpty {
                EmptyStateView(title: kind == .starred ? "No starred files" : "Trash is empty",
                               message: kind == .starred ? "Star files in Google Drive and they appear here." : "Files you delete from Google Drive appear here for 30 days.",
                               symbol: kind == .starred ? "star" : "trash")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(entries, selection: $selection) {
                    TableColumn("Name") { e in
                        HStack(spacing: 8) {
                            Image(decorative: FileIcons.bitmap(for: e.asFileItem), scale: 2).resizable().frame(width: 18, height: 18)
                            Text(e.name).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .width(min: 220, ideal: 360)
                    TableColumn("Where") { e in Text((e.path as NSString).deletingLastPathComponent.isEmpty ? "My Drive" : (e.path as NSString).deletingLastPathComponent).foregroundStyle(Theme.inkSecondary).lineLimit(1) }
                        .width(min: 120, ideal: 220)
                    TableColumn("Modified") { e in Text(e.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "--").foregroundStyle(Theme.inkSecondary) }
                        .width(min: 110, ideal: 150)
                    TableColumn("Size") { e in Text(FileIcons.sizeLabel(for: e.asFileItem)).monospacedDigit().foregroundStyle(Theme.inkSecondary) }
                        .width(min: 60, ideal: 90)
                }
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: RemoteEntry.ID.self) { ids in
                    if kind == .starred, let id = ids.first, let url = mountedURL(id) {
                        Button("Open") { NSWorkspace.shared.open(url) }
                        Button("Quick Look") { quickLook = url }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                } primaryAction: { ids in
                    if kind == .starred, let id = ids.first, let url = mountedURL(id) { NSWorkspace.shared.open(url) }
                }
            }
        }
        .background(Theme.canvas)
        .navigationTitle(title)
        .navigationSubtitle(loading ? "Loading…" : "\(entries.count) item\(entries.count == 1 ? "" : "s")")
        .quickLookPreview($quickLook)
        .toolbar {
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.help("Reload")
        }
        .confirmationDialog("Restore everything in Trash?", isPresented: $confirmRestore) {
            Button("Restore All") { Task { await restoreAll() } }
        } message: { Text("Google Drive moves all \(entries.count) item(s) back to where they were. Google's API restores whole folders, not single files.") }
        .overlay(alignment: .bottom) {
            if let toast {
                GlassToast(text: toast).padding(.bottom, 24)
            }
        }
        .animation(Theme.spring, value: toast)
        .task(id: "\(driveID)|\(kind.rawValue)|\(drives.state(driveID).phase.isActive)") { await load() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(kind == .starred ? Theme.warning.opacity(0.12) : Theme.inkTertiary.opacity(0.14)).frame(width: 44, height: 44)
                Image(systemName: kind == .starred ? "star.fill" : "trash.fill").font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(kind == .starred ? Theme.warning : Theme.inkSecondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).titleStyle()
                Text(kind == .starred ? "Files you starred in Google Drive" : "Deleted files are kept by Google for 30 days")
                    .font(.caption12).secondaryText()
            }
            Spacer()
            if kind == .trash {
                Link("Open in Google Drive", destination: URL(string: "https://drive.google.com/drive/trash")!)
                    .font(.system(size: 12, weight: .semibold))
                Button("Restore All…") { confirmRestore = true }.buttonStyle(.secondary).disabled(entries.isEmpty)
            }
        }
        .padding(24)
    }

    private func mountedURL(_ path: String) -> URL? {
        guard let mp = drives.state(driveID).mountPath else { return nil }
        return URL(fileURLWithPath: mp).appendingPathComponent(path)
    }

    private func load() async {
        guard let actions = drives.cloudActions(driveID) else { entries = []; return }
        loading = true
        defer { loading = false }
        do { entries = try await actions.list(kind); error = nil } catch let e { error = e }
    }

    private func restoreAll() async {
        guard let actions = drives.cloudActions(driveID) else { return }
        do {
            try await actions.untrash(relativeDir: "")
            toast = "Restored. Files are back in their folders."
            drives.log(driveID, "trash", "Restored \(entries.count) item(s) from Google Drive Trash.", .info)
            await load()
            try? await Task.sleep(for: .seconds(2.6)); toast = nil
        } catch let e { error = e }
    }
}

extension RemoteEntry {
    var asFileItem: FileItem {
        FileItem(url: URL(fileURLWithPath: "/" + path), name: name, isDirectory: isDirectory, size: size, modified: modified)
    }
}
