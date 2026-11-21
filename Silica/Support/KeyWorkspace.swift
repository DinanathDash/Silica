import AppKit
import Combine
import SwiftUI

/// The workspace whose window is key, for menu commands and shortcuts to act on.
final class KeyWorkspace: ObservableObject {
    static let shared = KeyWorkspace()
    @Published var current: WorkspaceModel?
    private init() {}

    private var keyMonitor: Any?
    private static let nextTab = Keybind(key: "]", modifiers: [.shift, .command])!
    private static let previousTab = Keybind(key: "[", modifiers: [.shift, .command])!

    /// Shortcuts for the key workspace, handled here as well as in the menus because
    /// menu items bound to ⇧⌘ + a letter didn't reliably win over the plain ⌘ + letter
    /// items (⇧⌘V lost to Paste, ⇧⌘F to Find). Each one follows its command's keybind,
    /// so a keybind changed in Settings moves it here too.
    func installKeyboardShortcuts() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
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
            let keybinds = KeybindSettings.shared
            guard let workspace = self?.current,
                  // Not while a sheet or alert is up, or while Settings records a keybind.
                  event.window?.attachedSheet == nil, NSApp.modalWindow == nil,
                  !keybinds.isRecorderWindow(event.window),
                  let pressed = Keybind(event: event) else { return event }
            // In the terminal, a keybind without ⌘ goes to the shell; see ConfigKeyCommand.
            let terminalHasFocus = workspace.terminal?.isFocused == true
            func runs(_ command: ConfigKeyCommand) -> Bool {
                pressed == keybinds.keybind(for: command)
                    && !(terminalHasFocus && command.leavesToShell(pressed))
            }
            switch pressed {
            case _ where runs(.togglePreview):
                guard let buffer = workspace.activeBuffer, buffer.previewFormat != nil else { return event }
                buffer.togglePreview()
            case _ where runs(.findInProject):
                workspace.showSearch()
            case keybinds.keybind(for: FixedKeyCommand.explorer):
                workspace.showExplorer()
            case keybinds.keybind(for: FixedKeyCommand.saveAs):
                guard workspace.activeBuffer?.textController != nil else { return event }
                workspace.saveActiveAs()
            case keybinds.keybind(for: FixedKeyCommand.closeWindow):
                event.window?.performClose(nil)
            // Here as well as in the menu, for keybinds such as ⇧⌘]: the menu item could
            // lose ⇧⌘] to Indent's ⌘].
            case _ where runs(.selectNextTab):
                guard workspace.canSelectOtherTab else { return event }
                workspace.selectTab(offsetBy: 1)
            case _ where runs(.selectPreviousTab):
                guard workspace.canSelectOtherTab else { return event }
                workspace.selectTab(offsetBy: -1)
            // The other usual pair for stepping through tabs, next to the menu's keybind,
            // unless a command uses it.
            case Self.nextTab where !keybinds.isBound(pressed):
                workspace.selectTab(offsetBy: 1)
            case Self.previousTab where !keybinds.isBound(pressed):
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

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            workspace?.window = window
            NotificationCenter.default.addObserver(
                self, selector: #selector(keyStateDidChange),
                name: NSWindow.didBecomeKeyNotification, object: window
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(keyStateDidChange),
                name: NSWindow.didResignKeyNotification, object: window
            )
            if window.isKeyWindow { keyStateDidChange() }
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
