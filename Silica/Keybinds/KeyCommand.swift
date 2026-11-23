import Foundation
import SwiftUI

/// Protocol describing a key command.
protocol KeyCommand: Identifiable, CaseIterable, RawRepresentable where RawValue == String {}

// MARK: FixedKeyCommand

/// A fixed (non-configurable) key command. Presets can still bind it to a different key.
enum FixedKeyCommand: String, KeyCommand {

    var id: String {
        self.rawValue
    }

    case settings
    case newFile = "new_file"
    case newFolder = "new_folder"
    case `open`
    case welcomeWindow = "welcome_window"
    case save
    case saveAs = "save_as"
    case saveAll = "save_all"
    case closeTab = "close_tab"
    case closeWindow = "close_window"
    case explorer = "explorer"
    case refreshExplorer = "refresh_explorer"
    case indent
    case outdent
}

// MARK: ConfigKeyCommand

/// A configurable key command.
enum ConfigKeyCommand: String, KeyCommand {

    var id: String {
        self.rawValue
    }

    case quickOpen = "quick_open"
    case findInProject = "find_in_project"
    case sourceControl = "source_control"
    case filterTreeFiles = "filter_tree_files"
    case goToLine = "go_to_line"
    case togglePreview = "toggle_preview"
    case toggleSidebar = "toggle_sidebar"
    case toggleTerminal = "toggle_terminal"
    case newTerminal = "new_terminal"
    case clearTerminal = "clear_terminal"
    case selectNextTab = "select_next_tab"
    case selectPreviousTab = "select_previous_tab"
    case splitRight = "split_right"
    case splitDown = "split_down"
    case focusNextPane = "focus_next_pane"
    case focusPreviousPane = "focus_previous_pane"
    case closePane = "close_pane"
    case toggleComment = "toggle_comment"
    case moveLineUp = "move_line_up"
    case moveLineDown = "move_line_down"
    case duplicateLineUp = "duplicate_line_up"
    case duplicateLineDown = "duplicate_line_down"
    case toggleWordWrap = "toggle_word_wrap"
    case increaseFontSize = "increase_font_size"
    case decreaseFontSize = "decrease_font_size"
    case resetFontSize = "reset_font_size"
    
    /// Whether the command is for the terminal too, so its keybind still works while the
    /// terminal has focus even without ⌘. Other keybinds without ⌘ are left to the shell.
    var worksInTerminal: Bool {
        switch self {
        case .toggleTerminal, .newTerminal, .clearTerminal, .selectNextTab, .selectPreviousTab: true
        default: false
        }
    }
    
    /// Whether the keybind, while the terminal has focus, goes to the shell rather than to
    /// this command: it has no ⌘, so it may be a key the shell uses (⌃R, ⌃G).
    func leavesToShell(_ keybind: Keybind) -> Bool {
        !worksInTerminal && !keybind.modifiers.contains(.command)
    }
}

// MARK: SystemKeyCommand

/// A shortcut that doesn't come from `AppCommands`, so it can't change: a menu item
/// from macOS or from SwiftUI's `TextEditingCommands`, or a key a view handles itself.
/// Listed so a keybind can't take its shortcut. The Window menu's tiling items, bound
/// only with the Globe key, are left out: the recorder can't record that key.
enum SystemKeyCommand: String, CaseIterable, Identifiable {
    
    var id: String {
        self.rawValue
    }
    
    // Silica menu
    case hide
    case hideOthers
    case quit
    case quitAndKeepWindows
    // Edit menu
    case undo
    case redo
    case cut
    case copy
    case paste
    case selectAll
    case find
    case findAndReplace
    case findNext
    case findPrevious
    case useSelectionForFind
    case jumpToSelection
    case showSpellingAndGrammar
    case checkDocumentNow
    case emojiAndSymbols
    // View menu
    case showAllTabs
    case enterFullScreen
    // Window menu
    case minimize
    case minimizeAll
    // Apple menu
    case forceQuit
    case forceQuitSilica
    case lockScreen
    case logOut
    case logOutNow
    // Help menu
    case help
    // Handled by views, which get keys after the menus do.
    case commit
    
    var title: String {
        switch self {
        case .hide: "Hide Silica"
        case .hideOthers: "Hide Others"
        case .quit: "Quit Silica"
        case .quitAndKeepWindows: "Quit and Keep Windows"
        case .undo: "Undo"
        case .redo: "Redo"
        case .cut: "Cut"
        case .copy: "Copy"
        case .paste: "Paste"
        case .selectAll: "Select All"
        case .find: "Find"
        case .findAndReplace: "Find and Replace"
        case .findNext: "Find Next"
        case .findPrevious: "Find Previous"
        case .useSelectionForFind: "Use Selection for Find"
        case .jumpToSelection: "Jump to Selection"
        case .showSpellingAndGrammar: "Show Spelling and Grammar"
        case .checkDocumentNow: "Check Document Now"
        // Shown as 🌐E, but ⌃⌘Space still works.
        case .emojiAndSymbols: "Emoji & Symbols"
        case .showAllTabs: "Show All Tabs"
        // Shown as 🌐F, but ⌃⌘F still works.
        case .enterFullScreen: "Enter Full Screen"
        case .minimize: "Minimize"
        case .minimizeAll: "Minimize All"
        case .forceQuit: "Force Quit"
        case .forceQuitSilica: "Force Quit Silica"
        case .lockScreen: "Lock Screen"
        case .logOut: "Log Out"
        case .logOutNow: "Log Out Without Asking"
        case .help: "Silica Help"
        case .commit: "Commit (in the commit message)"
        }
    }
    
    var keybind: Keybind {
        switch self {
        case .hide: .init(key: "h", modifiers: .command)!
        case .hideOthers: .init(key: "h", modifiers: [.option, .command])!
        case .quit: .init(key: "q", modifiers: .command)!
        case .quitAndKeepWindows: .init(key: "q", modifiers: [.option, .command])!
        case .undo: .init(key: "z", modifiers: .command)!
        case .redo: .init(key: "z", modifiers: [.shift, .command])!
        case .cut: .init(key: "x", modifiers: .command)!
        case .copy: .init(key: "c", modifiers: .command)!
        case .paste: .init(key: "v", modifiers: .command)!
        case .selectAll: .init(key: "a", modifiers: .command)!
        case .find: .init(key: "f", modifiers: .command)!
        case .findAndReplace: .init(key: "f", modifiers: [.option, .command])!
        case .findNext: .init(key: "g", modifiers: .command)!
        case .findPrevious: .init(key: "g", modifiers: [.shift, .command])!
        case .useSelectionForFind: .init(key: "e", modifiers: .command)!
        case .jumpToSelection: .init(key: "j", modifiers: .command)!
        case .showSpellingAndGrammar: .init(key: ":", modifiers: .command)!
        case .checkDocumentNow: .init(key: ";", modifiers: .command)!
        case .emojiAndSymbols: .init(key: .space, modifiers: [.control, .command])!
        case .showAllTabs: .init(key: "\\", modifiers: [.shift, .command])!
        case .enterFullScreen: .init(key: "f", modifiers: [.control, .command])!
        case .minimize: .init(key: "m", modifiers: .command)!
        case .minimizeAll: .init(key: "m", modifiers: [.option, .command])!
        case .forceQuit: .init(key: .escape, modifiers: [.option, .command])!
        case .forceQuitSilica: .init(key: .escape, modifiers: [.option, .shift, .command])!
        case .lockScreen: .init(key: "q", modifiers: [.control, .command])!
        case .logOut: .init(key: "q", modifiers: [.shift, .command])!
        case .logOutNow: .init(key: "q", modifiers: [.option, .shift, .command])!
        case .help: .init(key: "?", modifiers: .command)!
        case .commit: .init(key: .return, modifiers: .command)!
        }
    }
}
