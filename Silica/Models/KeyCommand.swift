import Foundation

// MARK: KeyCommand

/// Protocol describing a key command.
protocol KeyCommand: Identifiable, CaseIterable, RawRepresentable where RawValue == String {
    var id: String { get }
    var title: String { get }
    var defaultKeybind: Keybind { get }
}

// MARK: FixedKeyCommand

/// A fixed (non-configurable) key command.
enum FixedKeyCommand: String, KeyCommand {
    
    case settings
    case newFile
    case newFolder
    case open
    case welcomeWindow
    case save
    case saveAs
    case saveAll
    case closeTab
    case closeWindow
    case explorer
    case refreshExplorer
    case indent
    case outdent
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
    
    var id: String {
        self.rawValue
    }
    
    var title: String {
        switch self {
        case .settings: "Settings"
        case .newFile: "New File"
        case .newFolder: "New Folder"
        case .open: "Open"
        case .welcomeWindow: "Welcome Window"
        case .save: "Save"
        case .saveAs: "Save As"
        case .saveAll: "Save All"
        case .closeTab: "Close Tab"
        case .closeWindow: "Close Window"
        case .explorer: "Explorer"
        case .refreshExplorer: "Refresh Explorer"
        case .indent: "Indent"
        case .outdent: "Outdent"
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
    
    var defaultKeybind: Keybind {
        switch self {
        case .settings: .settings
        case .newFile: .newFile
        case .newFolder: .newFolder
        case .open: .open
        case .welcomeWindow: .welcomeWindow
        case .save: .save
        case .saveAs: .saveAs
        case .saveAll: .saveAll
        case .closeTab: .closeTab
        case .closeWindow: .closeWindow
        case .explorer: .explorer
        case .refreshExplorer: .refreshExplorer
        case .indent: .indent
        case .outdent: .outdent
        case .cut: .cut
        case .copy: .copy
        case .paste: .paste
        case .selectAll: .selectAll
        case .undo: .undo
        case .redo: .redo
        case .minimize: .minimize
        case .hide: .hide
        case .hideOthers: .hideOthers
        case .quit: .quit
        }
    }
}

// MARK: ConfigKeyCommand

/// A configurable key command.
enum ConfigKeyCommand: String, KeyCommand {
    
    case quickOpen
    case findInProject
    case filterTreeFiles
    case goToLine
    case togglePreview
    case toggleSidebar
    case toggleTerminal
    case newTerminal
    case clearTerminal
    case selectNextTab
    case selectPreviousTab
    case toggleComment
    case moveLineUp
    case moveLineDown
    case duplicateLineUp
    case duplicateLineDown
    case toggleWordWrap
    case increaseFontSize
    case decreaseFontSize
    case resetFontSize
    
    var id: String {
        self.rawValue
    }
    
    var title: String {
        switch self {
        case .quickOpen: "Quick Open"
        case .findInProject: "Find in Project"
        case .filterTreeFiles: "Filter Files"
        case .goToLine: "Go to Line"
        case .togglePreview: "Toggle Preview"
        case .toggleSidebar: "Toggle Sidebar"
        case .toggleTerminal: "Toggle Terminal"
        case .newTerminal: "New Terminal"
        case .clearTerminal: "Clear Terminal"
        case .selectNextTab: "Select Next Tab"
        case .selectPreviousTab: "Select Previous Tab"
        case .toggleComment: "Toggle Comment"
        case .moveLineUp: "Move Line Up"
        case .moveLineDown: "Move Line Down"
        case .duplicateLineUp: "Duplicate Line Up"
        case .duplicateLineDown: "Duplicate Line Down"
        case .toggleWordWrap: "Toggle Word Wrap"
        case .increaseFontSize: "Increase Font Size"
        case .decreaseFontSize: "Decrease Font Size"
        case .resetFontSize: "Reset Font Size"
        }
    }
    
    var defaultKeybind: Keybind {
        switch self {
        case .quickOpen: .quickOpen
        case .findInProject: .findInProject
        case .filterTreeFiles: .filterTreeFiles
        case .goToLine: .goToLine
        case .togglePreview: .togglePreview
        case .toggleSidebar: .toggleSidebar
        case .toggleTerminal: .toggleTerminal
        case .newTerminal: .newTerminal
        case .clearTerminal: .clearTerminal
        case .selectNextTab: .selectNextTab
        case .selectPreviousTab: .selectPreviousTab
        case .toggleComment: .toggleComment
        case .moveLineUp: .moveLineUp
        case .moveLineDown: .moveLineDown
        case .duplicateLineUp: .duplicateLineUp
        case .duplicateLineDown: .duplicateLineDown
        case .toggleWordWrap: .toggleWordWrap
        case .increaseFontSize: .increaseFontSize
        case .decreaseFontSize: .decreaseFontSize
        case .resetFontSize: .resetFontSize
        }
    }
}
