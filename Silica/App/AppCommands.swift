import SwiftUI

struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    /// The project in the key window. Tracked from AppKit key-window changes, since
    /// `focusedSceneValue` came back nil while the editor's NSTextView had focus.
    @ObservedObject private var keyWorkspace = KeyWorkspace.shared
    private var workspace: WorkspaceModel? { keyWorkspace.current }
    @ObservedObject private var updater = AppUpdater.shared
    @Bindable private var keybinds = KeybindSettings.shared
    
    private var recents: RecentProjectsStore { .shared }
    private var settings: EditorSettings { .shared }
    private var opener: ProjectOpener { ProjectOpener(openWindow: openWindow) }

    /// "Show Markdown", "Show CSV" or "Show HTML" while the preview is up, to go back to the source.
    private var previewToggleTitle: String {
        guard let buffer = workspace?.activeBuffer, buffer.isShowingPreview,
              let format = buffer.previewFormat else { return "Show Preview" }
        return "Show \(format.sourceName)"
    }

    var body: some Commands {
        // Lets Finder's open requests at launch open windows before any exists.
        let _ = ExternalOpener.shared.provide(openWindow)

        // About lives in Settings, next to the open-source licenses.
        CommandGroup(replacing: .appInfo) {
            Button("About Silica") {
                UserDefaults.standard.set(SettingsView.Pane.about.rawValue, forKey: SettingsView.paneKey)
                openWindow(id: WindowID.settings)
            }

            Button("Check for Updates…") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
        }

        // Settings is a regular Window scene (so it can resize), which doesn't get
        // the Settings… item on its own.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { openWindow(id: WindowID.settings) }
                .keybindShortcut(for: .settings, keybinds: keybinds)
        }

        CommandGroup(replacing: .newItem) {
            Button("New File") { workspace?.newUntitledFile() }
                .keybindShortcut(for: .newFile, keybinds: keybinds)
                .disabled(workspace == nil)

            Button("New File in Project…") { workspace?.beginNewItem(isDirectory: false) }
                .disabled(workspace == nil)

            Button("New Folder") { workspace?.beginNewItem(isDirectory: true) }
                .keybindShortcut(for: .newFolder, keybinds: keybinds)
                .disabled(workspace == nil)

            Divider()

            Button("Open…") { opener.chooseAndOpen() }
                .keybindShortcut(for: .open, keybinds: keybinds)

            Menu("Open Recent") {
                ForEach(recents.projects) { project in
                    Button(project.name) { opener.open(project) }
                }
                Divider()
                Button("Clear Menu") { recents.clear() }
                    .disabled(recents.projects.isEmpty)
            }

            Divider()

            Button("Quick Open…") { workspace?.toggleQuickOpen() }
                .keybindShortcut(for: .quickOpen, keybinds: keybinds)
                .disabled(workspace == nil)

            Divider()

            Button("Welcome Window") { openWindow(id: WindowID.welcome) }
                .keybindShortcut(for: .welcomeWindow, keybinds: keybinds)
        }

        // No printing; ⌘P is our default Quick Open shortcut, as in other code editors.
        CommandGroup(replacing: .printItem) {}

        CommandGroup(replacing: .saveItem) {
            Button("Save") { workspace?.saveActive() }
                .keybindShortcut(for: .save, keybinds: keybinds)
                .disabled(workspace?.activeBuffer.map { $0.isDirty || $0.isUntitled } != true)

            Button("Save As…") { workspace?.saveActiveAs() }
                .keybindShortcut(for: .saveAs, keybinds: keybinds)
                .disabled(workspace?.activeBuffer?.textController == nil)

            Button("Save All") { workspace?.saveAll() }
                .keybindShortcut(for: .saveAll, keybinds: keybinds)
                .disabled(workspace?.hasUnsavedChanges != true)

            Divider()

            // As in VS Code: ⌘W closes the tab, and the window once no tabs are left.
            Button("Close Tab") {
                if let workspace, workspace.activeTab != nil {
                    workspace.closeActiveTab()
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keybindShortcut(for: .closeTab, keybinds: keybinds)

            // ⇧⌘W is also handled by KeyWorkspace.installKeyboardShortcuts().
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keybindShortcut(for: .closeWindow, keybinds: keybinds)
        }

        CommandGroup(replacing: .sidebar) {
            Button(workspace?.isSidebarVisible == false ? "Show Sidebar" : "Hide Sidebar") {
                workspace?.toggleSidebar()
            }
            .keybindShortcut(for: .toggleSidebar, keybinds: keybinds)
            .disabled(workspace == nil)

            // ⇧⌘E, ⇧⌘F and ⇧⌘S are also handled by KeyWorkspace.installKeyboardShortcuts().
            Button("Explorer") { workspace?.showExplorer() }
                .keybindShortcut(for: .explorer, keybinds: keybinds)
                .disabled(workspace == nil)

            Button("Find in Project") { workspace?.showSearch() }
                .keybindShortcut(for: .findInProject, keybinds: keybinds)
                .disabled(workspace == nil)

            Button("Filter Files") { workspace?.focusTreeFilter() }
                .keybindShortcut(for: .filterTreeFiles, keybinds: keybinds)
                .disabled(workspace == nil)

            Button("Refresh Explorer") { workspace?.refresh() }
                .keybindShortcut(for: .refreshExplorer, keybinds: keybinds)
                .disabled(workspace == nil)

            Divider()

            Button("Terminal") { workspace?.toggleTerminal() }
                .keybindShortcut(for: .toggleTerminal, keybinds: keybinds)
                .disabled(workspace == nil)

            Button("New Terminal") { workspace?.newTerminal() }
                .keybindShortcut(for: .newTerminal, keybinds: keybinds)
                .disabled(workspace == nil)

            Button("Clear Terminal") { workspace?.terminal?.clear() }
                .keybindShortcut(for: .clearTerminal, keybinds: keybinds)
                .disabled(workspace?.terminal?.isFocused != true)

            Divider()

            // ⇧⌘V itself is handled by KeyWorkspace.installKeyboardShortcuts().
            Button(previewToggleTitle) {
                workspace?.activeBuffer?.togglePreview()
            }
            .keybindShortcut(for: .togglePreview, keybinds: keybinds)
            .disabled(workspace?.activeBuffer?.previewFormat == nil)

            Divider()

            // The file tabs, not the window tabs of the Window menu's Show Next Tab, which
            // has ⌃Tab as well: this menu comes first, so the file tabs get the key.
            // ⇧⌘] and ⇧⌘[ do the same; see KeyWorkspace.installKeyboardShortcuts().
            // From a terminal with others beside it, they step through the terminals.
            let hasOtherTabs = workspace?.canSelectOtherTab == true

            Button("Select Next Tab") { workspace?.selectTab(offsetBy: 1) }
                .keybindShortcut(for: .selectNextTab, keybinds: keybinds)
                .disabled(!hasOtherTabs)

            Button("Select Previous Tab") { workspace?.selectTab(offsetBy: -1) }
                .keybindShortcut(for: .selectPreviousTab, keybinds: keybinds)
                .disabled(!hasOtherTabs)
        }

        CommandGroup(after: .sidebar) {
            Divider()

            Toggle("Word Wrap", isOn: Binding(
                get: { settings.wrapsLines },
                set: { settings.wrapsLines = $0 }
            ))
            .keybindShortcut(for: .toggleWordWrap, keybinds: keybinds)

            Toggle("Minimap", isOn: Binding(
                get: { settings.showsMinimap },
                set: { settings.showsMinimap = $0 }
            ))

            Divider()

            // ⌘= also zooms in; see EditorSettings.installKeyboardShortcuts().
            Button("Increase Font Size") { settings.increaseFontSize() }
                .keybindShortcut(for: .increaseFontSize, keybinds: keybinds)
                .disabled(!settings.canIncreaseFontSize)

            Button("Decrease Font Size") { settings.decreaseFontSize() }
                .keybindShortcut(for: .decreaseFontSize, keybinds: keybinds)
                .disabled(!settings.canDecreaseFontSize)

            Button("Reset Font Size") { settings.resetFontSize() }
                .keybindShortcut(for: .resetFontSize, keybinds: keybinds)
                .disabled(settings.isDefaultFontSize)
        }

        CommandMenu("Editor") {
            let hasText = workspace?.activeBuffer?.textController != nil

            Button("Go to Line…") { workspace?.showGoToLine() }
                .keybindShortcut(for: .goToLine, keybinds: keybinds)
                .disabled(!hasText)

            Divider()

            configurableEditorAction("Toggle Comment", .toggleComment, #selector(EditorTextView.toggleComment(_:)))
            fixedEditorAction("Indent", .indent, #selector(EditorTextView.indentLines(_:)))
            fixedEditorAction("Outdent", .outdent, #selector(EditorTextView.outdentLines(_:)))

            Divider()

            configurableEditorAction("Move Line Up", .moveLineUp, #selector(EditorTextView.moveLinesUp(_:)))
            configurableEditorAction("Move Line Down", .moveLineDown, #selector(EditorTextView.moveLinesDown(_:)))
            configurableEditorAction("Duplicate Line Up", .duplicateLineUp, #selector(EditorTextView.duplicateLinesUp(_:)))
            configurableEditorAction("Duplicate Line Down", .duplicateLineDown, #selector(EditorTextView.duplicateLinesDown(_:)))
        }
    }
    
    private func fixedEditorAction(
        _ title: String,
        _ command: FixedKeyCommand,
        _ action: Selector
    ) -> some View {
        Button(title) { NSApp.sendAction(action, to: nil, from: nil) }
            .keybindShortcut(for: command, keybinds: keybinds)
            .disabled(workspace?.activeBuffer?.textController == nil)
    }
    
    private func configurableEditorAction(
        _ title: String,
        _ command: ConfigKeyCommand,
        _ action: Selector
    ) -> some View {
        Button(title) { NSApp.sendAction(action, to: nil, from: nil) }
            .keybindShortcut(for: command, keybinds: keybinds)
            .disabled(workspace?.activeBuffer?.textController == nil)
    }
}
