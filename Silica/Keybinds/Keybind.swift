import AppKit
import SwiftUI

struct Keybind: Codable, Hashable {
    
    let key: String
    let modifiers: Modifiers
    
    var keyEquivalent: KeyEquivalent {
        .init(self.key.first!)
    }
    
    var eventModifiers: EventModifiers {
        var eventModifiers = EventModifiers()
        if modifiers.contains(.command) { eventModifiers.insert(.command) }
        if modifiers.contains(.option) { eventModifiers.insert(.option) }
        if modifiers.contains(.control) { eventModifiers.insert(.control) }
        if modifiers.contains(.shift) { eventModifiers.insert(.shift) }
        return eventModifiers
    }
    
    var displayName: String {
        var mods = ""
        if self.modifiers.contains(.command) { mods += "⌘" }
        if self.modifiers.contains(.option) { mods += "⌥" }
        if self.modifiers.contains(.control) { mods += "⌃" }
        if self.modifiers.contains(.shift) { mods += "⇧" }

        let keyName = SpecialKey.byCharacterMap[self.key.first!]?.title ?? self.key.uppercased()
        return mods + keyName
    }
    
    init?(
        key: String,
        modifiers: Modifiers
    ) {
        let _key = key.lowercased()

        // Keybind must contain ⌘, ⌥, or ⌃. Keybinds that only contain ⇧ are not valid.
        guard !modifiers.intersection([.command, .control, .option]).isEmpty else {
            return nil
        }

        // Keybind must contain a single key.
        guard _key.count == 1,
              _key.unicodeScalars.count == 1,
              let character = _key.first,
              let scalar = _key.unicodeScalars.first
        else {
            return nil
        }

        let isSupportedSpecialKey = SpecialKey.byCharacterMap[character] != nil
        let isPrintable = scalar.value >= 0x20
            && scalar.value != 0x7F
            && !(UInt32(0xF700)...UInt32(0xF8FF)).contains(scalar.value)

        // Key must be a supported special key, or printable.
        guard isSupportedSpecialKey || isPrintable else {
            return nil
        }

        self.key = _key
        self.modifiers = modifiers
    }

    init?(
        key: KeyEquivalent,
        modifiers: Modifiers
    ) {
        self.init(
            key: String(key.character),
            modifiers: modifiers
        )
    }

    init?(event: NSEvent) {
        var modifiers = Modifiers()
        let flags = event.modifierFlags
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }

        guard let key = event.charactersIgnoringModifiers else {
            return nil
        }

        self.init(
            key: key,
            modifiers: modifiers
        )
    }
    
    init?(binding: KeybindFile.Binding) {
        let modifiers = Modifiers(modifiers: binding.mods)
        if let specialKey = SpecialKey(rawValue: binding.key) {
            self.init(
                key: specialKey.keyEquivalent,
                modifiers: modifiers
            )
        } else {
            self.init(
                key: binding.key,
                modifiers: modifiers
            )
        }
    }
}

// MARK: Modifiers

extension Keybind {
    
    struct Modifiers: OptionSet, Codable, Hashable {
        
        let rawValue: UInt8
        
        static let command = Self(rawValue: 1 << 0)
        static let option = Self(rawValue: 1 << 1)
        static let control = Self(rawValue: 1 << 2)
        static let shift = Self(rawValue: 1 << 3)
        
        init(rawValue: UInt8) {
            self.rawValue = rawValue
        }
        
        init(modifiers: [KeybindFile.Binding.Modifier]) {
            var mods = Self()
            for mod in modifiers {
                switch mod {
                case .command: mods.insert(.command)
                case .option: mods.insert(.option)
                case .control: mods.insert(.control)
                case .shift: mods.insert(.shift)
                }
            }
            self = mods
        }
        
        func asBindingModifiers() -> [KeybindFile.Binding.Modifier] {
            var modifiers = [KeybindFile.Binding.Modifier]()
            if contains(.command) { modifiers.append(.command) }
            if contains(.option) { modifiers.append(.option) }
            if contains(.control) { modifiers.append(.control) }
            if contains(.shift) { modifiers.append(.shift) }
            return modifiers
        }
    }
}

// MARK: SpecialKey

extension Keybind {
    
    enum SpecialKey: String, Codable, Hashable, CaseIterable {
        
        case space
        case tab
        case escape = "esc"
        case `return` = "⏎"
        case upArrow = "↑"
        case downArrow = "↓"
        case leftArrow = "←"
        case rightArrow = "→"
        
        var title: String {
            switch self {
            case .escape: "esc"
            default: self.rawValue.capitalized
            }
        }
        
        var keyEquivalent: KeyEquivalent {
            switch self {
            case .space: .space
            case .tab: .tab
            case .escape: .escape
            case .return: .return
            case .upArrow: .upArrow
            case .downArrow: .downArrow
            case .leftArrow: .leftArrow
            case .rightArrow: .rightArrow
            }
        }
        
        static let byCharacterMap = Dictionary(
            uniqueKeysWithValues: SpecialKey.allCases.map {
                ($0.keyEquivalent.character, $0)
            }
        )
    }
}

// MARK: Fallbacks

extension Keybind {
    
    struct Fallback {
        
        static func get(for command: FixedKeyCommand) -> Keybind {
            fixed(for: command)
        }
        
        static func get(for command: ConfigKeyCommand) -> Keybind {
            config(for: command)
        }
        
        // Fixed
        
        static let settings: Keybind = .init(key: ",", modifiers: .command)!
        static let newFile: Keybind = .init(key: "n", modifiers: .command)!
        static let newFolder: Keybind = .init(key: "n", modifiers: [.option, .command])!
        static let open: Keybind = .init(key: "o", modifiers: .command)!
        static let welcomeWindow: Keybind = .init(key: "1", modifiers: [.shift, .command])!
        static let save: Keybind = .init(key: "s", modifiers: .command)!
        static let saveAs: Keybind = .init(key: "s", modifiers: [.shift, .command])!
        static let saveAll: Keybind = .init(key: "s", modifiers: [.option, .command])!
        static let closeTab: Keybind = .init(key: "w", modifiers: .command)!
        static let closeWindow: Keybind = .init(key: "w", modifiers: [.shift, .command])!
        static let explorer: Keybind = .init(key: "e", modifiers: [.shift, .command])!
        static let refreshExplorer: Keybind = .init(key: "r", modifiers: [.shift, .command])!
        static let indent: Keybind = .init(key: "]", modifiers: .command)!
        static let outdent: Keybind = .init(key: "[", modifiers: .command)!
        static let cut: Keybind = .init(key: "x", modifiers: .command)!
        static let copy: Keybind = .init(key: "c", modifiers: .command)!
        static let paste: Keybind = .init(key: "v", modifiers: .command)!
        static let selectAll: Keybind = .init(key: "a", modifiers: .command)!
        static let undo: Keybind = .init(key: "z", modifiers: .command)!
        static let redo: Keybind = .init(key: "z", modifiers: [.shift, .command])!
        static let minimize: Keybind = .init(key: "m", modifiers: .command)!
        static let hide: Keybind = .init(key: "h", modifiers: .command)!
        static let hideOthers: Keybind = .init(key: "h", modifiers: [.option, .command])!
        static let quit: Keybind = .init(key: "q", modifiers: .command)!
        
        static func fixed(for command: FixedKeyCommand) -> Keybind {
            switch command {
            case .settings: self.settings
            case .newFile: self.newFile
            case .newFolder: self.newFolder
            case .open: self.open
            case .welcomeWindow: self.welcomeWindow
            case .save: self.save
            case .saveAs: self.saveAs
            case .saveAll: self.saveAll
            case .closeTab: self.closeTab
            case .closeWindow: self.closeWindow
            case .explorer: self.explorer
            case .refreshExplorer: self.refreshExplorer
            case .indent: self.indent
            case .outdent: self.outdent
            case .cut: self.cut
            case .copy: self.copy
            case .paste: self.paste
            case .selectAll: self.selectAll
            case .undo: self.undo
            case .redo: self.redo
            case .minimize: self.minimize
            case .hide: self.hide
            case .hideOthers: self.hideOthers
            case .quit: self.quit
            }
        }
        
        // Configurable
        
        static let quickOpen: Keybind = .init(key: "p", modifiers: .command)!
        static let quickJumpToFile: Keybind = .init(key: "p", modifiers: [.shift, .command])!
        static let findInProject: Keybind = .init(key: "f", modifiers: [.shift, .command])!
        static let filterTreeFiles: Keybind = .init(key: "j", modifiers: [.option, .command])!
        static let goToLine: Keybind = .init(key: "l", modifiers: .command)!
        static let togglePreview: Keybind = .init(key: "v", modifiers: [.shift, .command])!
        static let toggleSidebar: Keybind = .init(key: "s", modifiers: [.control, .command])!
        static let toggleTerminal: Keybind = .init(key: "`", modifiers: .control)!
        static let newTerminal: Keybind = .init(key: "`", modifiers: [.control, .shift])!
        static let clearTerminal: Keybind = .init(key: "k", modifiers: .command)!
        static let selectNextTab: Keybind = .init(key: .tab, modifiers: .control)!
        static let selectPreviousTab: Keybind = .init(key: .tab, modifiers: [.control, .shift])!
        static let toggleComment: Keybind = .init(key: "/", modifiers: .command)!
        static let moveLineUp: Keybind = .init(key: .upArrow, modifiers: .option)!
        static let moveLineDown: Keybind = .init(key: .downArrow, modifiers: .option)!
        static let duplicateLineUp: Keybind = .init(key: .upArrow, modifiers: [.shift, .option])!
        static let duplicateLineDown: Keybind = .init(key: .downArrow, modifiers: [.shift, .option])!
        static let toggleWordWrap: Keybind = .init(key: "z", modifiers: .option)!
        static let increaseFontSize: Keybind = .init(key: "+", modifiers: .command)!
        static let decreaseFontSize: Keybind = .init(key: "-", modifiers: .command)!
        static let resetFontSize: Keybind = .init(key: "0", modifiers: .command)!
        
        static func config(for command: ConfigKeyCommand) -> Keybind {
            switch command {
            case .quickOpen: self.quickOpen
            case .quickJumpToFile: self.quickJumpToFile
            case .findInProject: self.findInProject
            case .filterTreeFiles: self.filterTreeFiles
            case .goToLine: self.goToLine
            case .togglePreview: self.togglePreview
            case .toggleSidebar: self.toggleSidebar
            case .toggleTerminal: self.toggleTerminal
            case .newTerminal: self.newTerminal
            case .clearTerminal: self.clearTerminal
            case .selectNextTab: self.selectNextTab
            case .selectPreviousTab: self.selectPreviousTab
            case .toggleComment: self.toggleComment
            case .moveLineUp: self.moveLineUp
            case .moveLineDown: self.moveLineDown
            case .duplicateLineUp: self.duplicateLineUp
            case .duplicateLineDown: self.duplicateLineDown
            case .toggleWordWrap: self.toggleWordWrap
            case .increaseFontSize: self.increaseFontSize
            case .decreaseFontSize: self.decreaseFontSize
            case .resetFontSize: self.resetFontSize
            }
        }
    }
}

// MARK: View + Keybind

extension View {
    
    func keybindShortcut(
        for command: FixedKeyCommand,
        _ keybinds: KeybindSettings
    ) -> some View {
        let keybind = keybinds.keybind(for: command)
        return keyboardShortcut(
            keybind.keyEquivalent,
            modifiers: keybind.eventModifiers
        )
    }
    
    func keybindShortcut(
        for command: ConfigKeyCommand,
        _ keybinds: KeybindSettings
    ) -> some View {
        let keybind = keybinds.keybind(for: command)
        return keyboardShortcut(
            keybind.keyEquivalent,
            modifiers: keybind.eventModifiers
        )
    }
}
