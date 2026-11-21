import Foundation

/// Protocol describing a key command.
protocol KeyCommand: Identifiable, CaseIterable, RawRepresentable where RawValue == String {}

extension KeyCommand {

    var title: String {
        self.rawValue
            .split(separator: "_")
            .map(\.localizedCapitalized)
            .joined(separator: " ")
    }
}

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
    case toggleComment = "toggle_comment"
    case moveLineUp = "move_line_up"
    case moveLineDown = "move_line_down"
    case duplicateLineUp = "duplicate_line_up"
    case duplicateLineDown = "duplicate_line_down"
    case toggleWordWrap = "toggle_word_wrap"
    case increaseFontSize = "increase_font_size"
    case decreaseFontSize = "decrease_font_size"
    case resetFontSize = "reset_font_size"
}

// MARK: SystemKeyCommand

/// A command whose menu item comes from macOS rather than from `AppCommands`, so its
/// shortcut can't change. Listed so a keybind can't take its shortcut.
enum SystemKeyCommand: String, CaseIterable, Identifiable {

    var id: String {
        self.rawValue
    }

    case cut
    case copy
    case paste
    case selectAll
    case undo
    case redo
    case minimize
    case hide
    case hideOthers
    case quit

    var title: String {
        switch self {
        case .cut: "Cut"
        case .copy: "Copy"
        case .paste: "Paste"
        case .selectAll: "Select All"
        case .undo: "Undo"
        case .redo: "Redo"
        case .minimize: "Minimize"
        case .hide: "Hide Silica"
        case .hideOthers: "Hide Others"
        case .quit: "Quit Silica"
        }
    }

    var keybind: Keybind {
        switch self {
        case .cut: .init(key: "x", modifiers: .command)!
        case .copy: .init(key: "c", modifiers: .command)!
        case .paste: .init(key: "v", modifiers: .command)!
        case .selectAll: .init(key: "a", modifiers: .command)!
        case .undo: .init(key: "z", modifiers: .command)!
        case .redo: .init(key: "z", modifiers: [.shift, .command])!
        case .minimize: .init(key: "m", modifiers: .command)!
        case .hide: .init(key: "h", modifiers: .command)!
        case .hideOthers: .init(key: "h", modifiers: [.option, .command])!
        case .quit: .init(key: "q", modifiers: .command)!
        }
    }
}
