import AppKit
import SwiftUI

struct Keybind: Codable, Hashable, Sendable {
  
    struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        let rawValue: UInt8
        static let command = Self(rawValue: 1 << 0)
        static let option = Self(rawValue: 1 << 1)
        static let control = Self(rawValue: 1 << 2)
        static let shift = Self(rawValue: 1 << 3)
    }
    
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
        
        let keyName = Self.specialKeyNameMap[self.key.first!] ?? self.key.uppercased()
        return mods + keyName
    }
    
    private static let specialKeyNameMap: [Character: String] = [
        KeyEquivalent.space.character: "Space",
        KeyEquivalent.tab.character: "Tab",
        KeyEquivalent.escape.character: "Esc",
        KeyEquivalent.upArrow.character: "↑",
        KeyEquivalent.downArrow.character: "↓",
        KeyEquivalent.leftArrow.character: "←",
        KeyEquivalent.rightArrow.character: "→"
    ]
    
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
        
        let isSupportedSpecialKey = Self.specialKeyNameMap[character] != nil
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
}

// MARK: Defaults

extension Keybind {
    
    // Fixed
    
    static let settings: Self = .init(key: ",", modifiers: .command)!
    static let newFile: Self = .init(key: "n", modifiers: .command)!
    static let newFolder: Self = .init(key: "n", modifiers: [.option, .command])!
    static let open: Self = .init(key: "o", modifiers: .command)!
    static let welcomeWindow: Self = .init(key: "1", modifiers: [.shift, .command])!
    static let save: Self = .init(key: "s", modifiers: .command)!
    static let saveAs: Self = .init(key: "s", modifiers: [.shift, .command])!
    static let saveAll: Self = .init(key: "s", modifiers: [.option, .command])!
    static let closeTab: Self = .init(key: "w", modifiers: .command)!
    static let closeWindow: Self = .init(key: "w", modifiers: [.shift, .command])!
    static let explorer: Self = .init(key: "e", modifiers: [.shift, .command])!
    static let refreshExplorer: Self = .init(key: "r", modifiers: [.shift, .command])!
    static let indent: Self = .init(key: "]", modifiers: .command)!
    static let outdent: Self = .init(key: "[", modifiers: .command)!
    static let cut: Self = .init(key: "x", modifiers: .command)!
    static let copy: Self = .init(key: "c", modifiers: .command)!
    static let paste: Self = .init(key: "v", modifiers: .command)!
    static let selectAll: Self = .init(key: "a", modifiers: .command)!
    static let undo: Self = .init(key: "z", modifiers: .command)!
    static let redo: Self = .init(key: "z", modifiers: [.shift, .command])!
    static let minimize: Self = .init(key: "m", modifiers: .command)!
    static let hide: Self = .init(key: "h", modifiers: .command)!
    static let hideOthers: Self = .init(key: "h", modifiers: [.option, .command])!
    static let quit: Self = .init(key: "q", modifiers: .command)!
    
    // Configurable
    
    static let quickOpen: Self = .init(key: "p", modifiers: .command)!
    static let findInProject: Self = .init(key: "f", modifiers: [.shift, .command])!
    static let filterTreeFiles: Self = .init(key: "j", modifiers: [.option, .command])!
    static let goToLine: Self = .init(key: "l", modifiers: .command)!
    static let togglePreview: Self = .init(key: "v", modifiers: [.shift, .command])!
    static let toggleSidebar: Self = .init(key: "s", modifiers: [.control, .command])!
    static let toggleTerminal: Self = .init(key: "`", modifiers: .control)!
    static let newTerminal: Self = .init(key: "`", modifiers: [.control, .shift])!
    static let clearTerminal: Self = .init(key: "k", modifiers: .command)!
    static let selectNextTab: Self = .init(key: .tab, modifiers: .control)!
    static let selectPreviousTab: Self = .init(key: .tab, modifiers: [.control, .shift])!
    static let toggleComment: Self = .init(key: "/", modifiers: .command)!
    static let moveLineUp: Self = .init(key: .upArrow, modifiers: .option)!
    static let moveLineDown: Self = .init(key: .downArrow, modifiers: .option)!
    static let duplicateLineUp: Self = .init(key: .upArrow, modifiers: [.shift, .option])!
    static let duplicateLineDown: Self = .init(key: .downArrow, modifiers: [.shift, .option])!
    static let toggleWordWrap: Self = .init(key: "z", modifiers: .option)!
    static let increaseFontSize: Self = .init(key: "+", modifiers: .command)!
    static let decreaseFontSize: Self = .init(key: "-", modifiers: .command)!
    static let resetFontSize: Self = .init(key: "0", modifiers: .command)!
}

// MARK: View + Keybind

extension View {
    
    func keybindShortcut(
        for command: FixedKeyCommand,
        keybinds: KeybindSettings
    ) -> some View {
        let keybind = keybinds.keybind(for: command)
        return keyboardShortcut(
            keybind.keyEquivalent,
            modifiers: keybind.eventModifiers
        )
    }
    
    func keybindShortcut(
        for command: ConfigKeyCommand,
        keybinds: KeybindSettings
    ) -> some View {
        let keybind = keybinds.keybind(for: command)
        return keyboardShortcut(
            keybind.keyEquivalent,
            modifiers: keybind.eventModifiers
        )
    }
}
