import AppKit
import SwiftUI

struct Keybind: Codable, Hashable {
    
    let key: String
    let modifiers: Modifiers
    
    /// Keybinds are equal when they're the same keystroke, so "+" with ⌘ (how a menu
    /// writes it) matches "=" with ⇧⌘ (what the recorder sees on a US keyboard).
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.stroke == rhs.stroke
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(stroke)
    }
    
    /// A key that macOS can't use as a shortcut without ⌘ or ⌃: in the editor, ⌥ or
    /// ⇧⌥ with it types a character ("Ω" for ⌥Z, a no-break space for ⌥Space) before a
    /// menu item sees the key. Only the arrows, which are function keys, are safe.
    var typesCharacter: Bool {
        guard modifiers.isDisjoint(with: [.command, .control]) else { return false }
        let scalar = key.unicodeScalars.first!.value
        return !(0xF700...0xF8FF).contains(scalar)
    }
    
    var keyEquivalent: KeyEquivalent {
        .init(self.key.first!)
    }
    
    var shortcut: KeyboardShortcut {
        KeyboardShortcut(keyEquivalent, modifiers: eventModifiers)
    }
    
    var eventModifiers: EventModifiers {
        var eventModifiers = EventModifiers()
        if modifiers.contains(.command) { eventModifiers.insert(.command) }
        if modifiers.contains(.option) { eventModifiers.insert(.option) }
        if modifiers.contains(.control) { eventModifiers.insert(.control) }
        if modifiers.contains(.shift) { eventModifiers.insert(.shift) }
        return eventModifiers
    }
    
    /// The shortcut as macOS writes it in menus, modifiers in ⌃⌥⇧⌘ order.
    var displayName: String {
        var mods = ""
        if self.modifiers.contains(.control) { mods += "⌃" }
        if self.modifiers.contains(.option) { mods += "⌥" }
        if self.modifiers.contains(.shift) { mods += "⇧" }
        if self.modifiers.contains(.command) { mods += "⌘" }

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

        // On a non-Latin layout (Russian, Greek), keys without ⌘ type that layout's own
        // letters, but shortcuts are written in Latin ones: read the key on the Latin
        // layout macOS keeps beside it, as menus do.
        if let latin = CurrentKeyboardLayout.shared.latinCharacter(
            forKeyCode: event.keyCode, withCommand: flags.contains(.command)
        ) {
            self.init(key: String(latin), modifiers: modifiers)
            return
        }
        // The unshifted character, so ⇧⌘1 is recorded as "1" with ⇧⌘, the way presets
        // write it, not as "!". (`charactersIgnoringModifiers` keeps Shift.) ⌘ stays
        // applied: layouts such as "Dvorak – QWERTY ⌘" switch keys while it's held, and
        // the menus match key equivalents against that ⌘ layout. A dead key (` or ' on
        // U.S. International) can translate to nothing, so fall back to the key's
        // character as AppKit reports it.
        let translated = event.characters(byApplyingModifiers: flags.intersection(.command))
        guard let key = translated?.isEmpty == false ? translated : event.charactersIgnoringModifiers else {
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

// MARK: Decoding

extension Keybind {
    
    /// Decodes through the validating initializer, so a saved keybind can't hold an empty
    /// or unusable key.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let key = try container.decode(String.self, forKey: .key)
        let modifiers = try container.decode(Modifiers.self, forKey: .modifiers)
        guard let keybind = Keybind(key: key, modifiers: modifiers) else {
            throw DecodingError.dataCorruptedError(
                forKey: .key, in: container, debugDescription: "Not a usable keybind: \(key.debugDescription)"
            )
        }
        self = keybind
    }
}

// MARK: Stroke

extension Keybind {
    
    /// The keystroke itself: the unshifted key and every modifier, Shift included.
    struct Stroke: Hashable {
        let key: Character
        let modifiers: Modifiers
    }
    
    var stroke: Stroke {
        let character = key.first!
        if let unshifted = Self.unshiftedKeys[character] {
            return Stroke(key: unshifted, modifiers: modifiers.union(.shift))
        }
        return Stroke(key: character, modifiers: modifiers)
    }
    
    /// The keystroke on `layout`: the physical key and every modifier, Shift included.
    /// Special keys, and characters the layout doesn't type, fall back to `stroke`.
    func keystroke(on layout: KeyboardLayout) -> Keystroke {
        let character = key.first!
        if SpecialKey.byCharacterMap[character] == nil,
           let found = layout.key(typing: character, withCommand: modifiers.contains(.command)) {
            return Keystroke(key: .code(found.keyCode), modifiers: modifiers.union(found.modifiers))
        }
        return Keystroke(key: .character(stroke.key), modifiers: stroke.modifiers)
    }
    
    struct Keystroke: Hashable {
        enum Key: Hashable {
            case code(UInt16)
            case character(Character)
        }
        let key: Key
        let modifiers: Modifiers
    }
    
    /// Characters typed with Shift on a US keyboard, and the key that types them.
    /// Presets are written for that layout, as the menus' own shortcuts are; comparing
    /// keybinds through the user's own layout is `keystroke(on:)`.
    private static let unshiftedKeys: [Character: Character] = [
        "~": "`", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6",
        "&": "7", "*": "8", "(": "9", ")": "0", "_": "-", "+": "=", "{": "[",
        "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/",
    ]
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
