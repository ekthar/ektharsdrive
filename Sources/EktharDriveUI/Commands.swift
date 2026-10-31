import EktharDriveCore
import SwiftUI

extension FocusedValues {
    /// The browser in the key window, when a mounted drive is shown. Menu commands act on it.
    @Entry var activeBrowser: FileBrowserModel?
}

/// File, View and Go menu commands so every browser action is reachable from the menu bar with standard
/// shortcuts (designing-for-macos.md: "Use the menu bar to give people easy access to all the commands").
public struct BrowserCommands: Commands {
    @FocusedValue(\.activeBrowser) private var browser
    public init() {}

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Folder") { if let b = browser { Task { await b.newFolder() } } }
                .keyboardShortcut("n", modifiers: [.command, .shift]).disabled(browser == nil)
            Button("Upload Files…") { if let b = browser { Task { await b.upload() } } }
                .keyboardShortcut("u", modifiers: [.command, .shift]).disabled(browser == nil)
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button("Open") { browser?.openSelection() }
                .keyboardShortcut("o").disabled(browser?.hasSelection != true)
            Button("Quick Look") { browser?.toggleQuickLook() }
                .keyboardShortcut("y").disabled(browser?.singleSelected == nil)
            Button("Rename…") { browser?.requestRename() }
                .disabled(browser?.singleSelected == nil)
            Button("Download a Copy…") { if let b = browser { let urls = Array(b.selection); Task { await b.download(urls) } } }
                .keyboardShortcut("d", modifiers: [.command, .option]).disabled(browser?.hasSelection != true)
            Divider()
            Button("Delete…") { browser?.requestDelete() }
                .keyboardShortcut(.delete, modifiers: .command).disabled(browser?.hasSelection != true)
        }
        CommandGroup(after: .toolbar) {
            Button("as Icons") { browser?.viewMode = .icons }.keyboardShortcut("1").disabled(browser == nil)
            Button("as List") { browser?.viewMode = .list }.keyboardShortcut("2").disabled(browser == nil)
            Divider()
            Button(browser?.showInspector == false ? "Show Info" : "Hide Info") { browser?.toggleInspector() }
                .keyboardShortcut("i", modifiers: [.command, .option]).disabled(browser == nil)
            Divider()
        }
        CommandMenu("Go") {
            Button("Back") { browser?.goBack() }.keyboardShortcut("[").disabled(browser?.canGoBack != true)
            Button("Forward") { browser?.goForward() }.keyboardShortcut("]").disabled(browser?.canGoForward != true)
            Button("Enclosing Folder") { browser?.goUp() }.keyboardShortcut(.upArrow, modifiers: .command).disabled(browser?.canGoUp != true)
        }
    }
}
