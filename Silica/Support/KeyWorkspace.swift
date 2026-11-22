import AppKit
import Combine
import SwiftUI

/// The workspace whose window is key, for menu commands and shortcuts to act on.
final class KeyWorkspace: ObservableObject {
    static let shared = KeyWorkspace()
    weak var current: WorkspaceModel? {
        didSet {
            objectWillChange.send()
        }
    }
    private init() {}

    private var keyMonitor: Any?
    private var pendingChord: String?
    private var chordTimestamp: TimeInterval = 0

    /// ⇧⌘ shortcuts for the key workspace, handled here as well as in the menus
    /// because menu items bound to ⇧⌘ + a letter didn't reliably win over the plain
    /// ⌘ + letter items (⇧⌘V lost to Paste, ⇧⌘F to Find).
    func installKeyboardShortcuts() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])

            // Chord handling: ⌘K then W (or ⌘W) closes all saved tabs
            if let pending = self?.pendingChord, pending == "cmd+k" {
                self?.pendingChord = nil
                let elapsed = ProcessInfo.processInfo.systemUptime - (self?.chordTimestamp ?? 0)
                if elapsed < 2.0, event.charactersIgnoringModifiers?.lowercased() == "w" {
                    if let workspace = self?.current {
                        DispatchQueue.main.async {
                            workspace.closeAllSavedTabs()
                        }
                    }
                    return nil
                }
            }

            if flags == .command, (event.keyCode == 40 || event.charactersIgnoringModifiers?.lowercased() == "k") {
                if let workspace = self?.current {
                    let firstResponder = event.window?.firstResponder
                    let terminalView = workspace.terminal?.view
                    let isTerminalActive = workspace.terminal?.isFocused == true ||
                        (firstResponder is TerminalView) ||
                        (terminalView != nil && (firstResponder as? NSView)?.isDescendant(of: terminalView!) == true)

                    if isTerminalActive, let terminal = workspace.terminal {
                        DispatchQueue.main.async {
                            terminal.clear()
                        }
                        return nil
                    }
                }
                self?.pendingChord = "cmd+k"
                self?.chordTimestamp = ProcessInfo.processInfo.systemUptime
                return nil
            }
            // Quick Open's field takes focus a moment after the panel appears; keys typed
            // in between (⌘L then a quick "100") belong in the query, not the editor.
            if let workspace = self?.current, workspace.isQuickOpenVisible,
               !flags.contains(.command), !flags.contains(.control),
               !((event.window?.firstResponder as? NSTextView)?.isFieldEditor ?? false),
               let characters = event.characters, !characters.isEmpty,
               characters.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F && $0.value < 0xF700 }) {
                workspace.quickOpen.query += characters
                return nil
            }
            // Escape to close Settings panel when open
            if event.keyCode == 53, let workspace = self?.current, workspace.isSettingsVisible,
               flags.isEmpty, !((event.window?.firstResponder as? NSTextView)?.isFieldEditor ?? false) {
                workspace.hideSettings()
                return nil
            }
            // ⌘, to toggle integrated Settings in active workspace
            if flags == .command, event.charactersIgnoringModifiers == ",", let workspace = self?.current {
                workspace.toggleSettings()
                return nil
            }
            // ⌃⇧G to toggle Source Control sidebar
            if flags == [.control, .shift], event.charactersIgnoringModifiers?.lowercased() == "g", let workspace = self?.current {
                workspace.toggleSourceControl()
                return nil
            }
            // ⌘⌫ (Move to Trash) and ⌘⌥⌫ (Delete Immediately) for selected item(s) in file tree
            if (event.keyCode == 51 || event.keyCode == 117),
               let workspace = self?.current,
               (!workspace.selections.isEmpty || workspace.selection != nil),
               workspace.treeEdit == nil,
               workspace.sidebarMode == .explorer {
                let firstResponder = event.window?.firstResponder
                let isEditingField = (firstResponder as? NSTextView)?.isFieldEditor ?? false
                let isEditorTextView = (firstResponder as? NSTextView) != nil &&
                    (firstResponder === workspace.activeBuffer?.textController?.textView)
                let isTerminalFocused = workspace.terminal?.isFocused == true

                if !isEditingField && !isEditorTextView && !isTerminalFocused {
                    let targets = !workspace.selections.isEmpty ? Array(workspace.selections) : (workspace.selection.map { [$0] } ?? [])
                    if flags == [.command, .option] {
                        DispatchQueue.main.async {
                            workspace.deleteImmediately(targets)
                        }
                        return nil
                    } else if flags == .command {
                        DispatchQueue.main.async {
                            workspace.moveToTrash(targets)
                        }
                        return nil
                    }
                }
            }
            guard flags == [.command, .shift], let workspace = self?.current,
                  // Not while a sheet or alert is up.
                  event.window?.attachedSheet == nil, NSApp.modalWindow == nil,
                  let key = event.charactersIgnoringModifiers?.lowercased() else { return event }
            switch key {
            case "v":
                guard let buffer = workspace.activeBuffer, buffer.previewFormat != nil else { return event }
                buffer.togglePreview()
            case "f":
                workspace.showSearch()
            case "e":
                workspace.showExplorer()
            case "s":
                guard workspace.activeBuffer?.textController != nil else { return event }
                workspace.saveActiveAs()
            case "w":
                event.window?.performClose(nil)
            // The other usual pair for stepping through tabs, next to ⌃Tab in the menu.
            case "}", "]":
                workspace.selectTab(offsetBy: 1)
            case "{", "[":
                workspace.selectTab(offsetBy: -1)
            default:
                return event
            }
            return nil
        }
    }
}

/// Invisible view that reports when its window becomes or stops being key.
struct KeyWindowTracker: NSViewRepresentable {
    let workspace: WorkspaceModel

    func makeNSView(context: Context) -> TrackerView {
        TrackerView(workspace: workspace)
    }

    func updateNSView(_ nsView: TrackerView, context: Context) {
        nsView.workspace = workspace
    }

    final class TrackerView: NSView {
        weak var workspace: WorkspaceModel?

        init(workspace: WorkspaceModel) {
            self.workspace = workspace
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            workspace?.window = window
            workspace?.isFullScreen = window.styleMask.contains(.fullScreen)
            NotificationCenter.default.addObserver(
                self, selector: #selector(keyStateDidChange),
                name: NSWindow.didBecomeKeyNotification, object: window
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(keyStateDidChange),
                name: NSWindow.didResignKeyNotification, object: window
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(fullScreenStateDidChange),
                name: NSWindow.didEnterFullScreenNotification, object: window
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(fullScreenStateDidChange),
                name: NSWindow.didExitFullScreenNotification, object: window
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(fullScreenStateDidChange),
                name: NSWindow.willEnterFullScreenNotification, object: window
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(fullScreenStateDidChange),
                name: NSWindow.willExitFullScreenNotification, object: window
            )
            if window.isKeyWindow { keyStateDidChange() }
        }

        @objc private func fullScreenStateDidChange(_ notification: Notification) {
            DispatchQueue.main.async { [weak self] in
                guard let self, let workspace = self.workspace, let window = self.window else { return }
                let isEntering = notification.name == NSWindow.willEnterFullScreenNotification || notification.name == NSWindow.didEnterFullScreenNotification
                let isExiting = notification.name == NSWindow.willExitFullScreenNotification || notification.name == NSWindow.didExitFullScreenNotification
                let isFS: Bool
                if isEntering {
                    isFS = true
                } else if isExiting {
                    isFS = false
                } else {
                    isFS = window.styleMask.contains(.fullScreen)
                }
                if workspace.isFullScreen != isFS {
                    withAnimation(.smooth(duration: 0.25)) {
                        workspace.isFullScreen = isFS
                    }
                }
            }
        }

        /// Published a turn later: this is reached in the middle of a SwiftUI view update
        /// (the view joining a window that is already key, or SwiftUI making the window
        /// key), where changing what `AppCommands` observes isn't allowed.
        @objc private func keyStateDidChange() {
            DispatchQueue.main.async { [weak self] in self?.publishKeyState() }
        }

        /// Reads the window's state now rather than trusting the notification, so a
        /// window that became key and resigned again before this ran isn't published.
        private func publishKeyState() {
            guard let workspace else { return }
            let key = KeyWorkspace.shared
            if window?.isKeyWindow == true {
                if key.current !== workspace { key.current = workspace }
            } else if key.current === workspace {
                key.current = nil
            }
        }
    }
}
