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

/// A fixed (non-configurable) key command.
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
    case cut
    case copy
    case paste
    case selectAll = "select_all"
    case undo
    case redo
    case minimize
    case hide
    case hideOthers = "hide_others"
    case quit
}

// MARK: ConfigKeyCommand

/// A configurable key command.
enum ConfigKeyCommand: String, KeyCommand {
    
    var id: String {
        self.rawValue
    }
    
    case quickOpen = "quick_open"
    case quickJumpToFile = "quick_jump_to_file"
    case findInProject = "find_in_project"
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
