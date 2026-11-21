import Carbon.HIToolbox
import Foundation

/// Where a keyboard layout puts the characters keybinds are written with, so two
/// keybinds can be compared as the keystroke someone actually presses.
///
/// Keybinds name characters ("/" with ⌘), and menus match them against the layout
/// in use. On a German layout "/" is ⇧7, so ⌘/ and a recorded ⇧⌘7 are one keystroke;
/// on a U.S. layout they're two.
protocol KeyboardLayout {
    /// The key that types `character`, and whether Shift is needed for it, using the
    /// layout's ⌘ table when `withCommand` is true (some layouts, such as
    /// "Dvorak – QWERTY ⌘", switch keys while ⌘ is held). Nil if no key types it.
    func key(typing character: Character, withCommand: Bool) -> (keyCode: UInt16, shift: Bool)?
}

/// The keyboard layout the user has selected, read again whenever they switch.
final class CurrentKeyboardLayout: KeyboardLayout {
    static let shared = CurrentKeyboardLayout()

    private var layoutID: String?
    private var keys: [Bool: [Character: (keyCode: UInt16, shift: Bool)]] = [:]

    func key(typing character: Character, withCommand: Bool) -> (keyCode: UInt16, shift: Bool)? {
        refreshIfLayoutChanged()
        return keys[withCommand]?[character]
    }

    private func refreshIfLayoutChanged() {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
            keys = [:]
            return
        }
        let id = property(kTISPropertyInputSourceID, of: source).map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }
        guard id != layoutID || keys.isEmpty else { return }
        layoutID = id
        guard let data = property(kTISPropertyUnicodeKeyLayoutData, of: source) else {
            keys = [:]
            return
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue() as Data
        keys = [
            false: Self.keys(in: layoutData, command: false),
            true: Self.keys(in: layoutData, command: true),
        ]
    }

    private func property(_ key: CFString, of source: TISInputSource) -> UnsafeMutableRawPointer? {
        TISGetInputSourceProperty(source, key)
    }

    /// The main keyboard's keys: the letter, number and punctuation keys, the ISO key
    /// beside the left Shift and the JIS keys, but not the keypad, whose "+", "=" and
    /// digits aren't the keys menus mean.
    private static let typingKeyCodes: [UInt16] = Array(0...63) + [93, 94]

    /// Every character the layout types without Shift, then the ones only Shift types.
    private static func keys(in layoutData: Data, command: Bool) -> [Character: (keyCode: UInt16, shift: Bool)] {
        var keys: [Character: (keyCode: UInt16, shift: Bool)] = [:]
        layoutData.withUnsafeBytes { bytes in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for shift in [false, true] {
                var modifiers: UInt32 = 0
                if command { modifiers |= UInt32(cmdKey >> 8) & 0xFF }
                if shift { modifiers |= UInt32(shiftKey >> 8) & 0xFF }
                for keyCode in typingKeyCodes {
                    var deadKeyState: UInt32 = 0
                    var length = 0
                    var characters = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(
                        layout, keyCode, UInt16(kUCKeyActionDisplay), modifiers, UInt32(LMGetKbdType()),
                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count, &length, &characters
                    )
                    guard status == noErr, length == 1,
                          let character = String(utf16CodeUnits: characters, count: length).lowercased().first,
                          keys[character] == nil else { continue }
                    keys[character] = (keyCode, shift)
                }
            }
        }
        return keys
    }
}
