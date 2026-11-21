import AppKit
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

extension Notification.Name {
    /// Posted after the user switches keyboard layouts.
    static let keyboardLayoutDidChange = Notification.Name("SilicaKeyboardLayoutDidChange")
}

/// The keyboard layout the user types shortcuts with: the selected layout, or for a
/// non-Latin one (Russian, Greek) the Latin layout macOS keeps beside it, which is the
/// one shortcuts are written in.
final class CurrentKeyboardLayout: KeyboardLayout {
    static let shared = CurrentKeyboardLayout()

    private struct Snapshot {
        let keyboardType: UInt32
        /// Whether the selected layout types Latin letters itself.
        let selectedIsLatin: Bool
        let keys: [Bool: [Character: (keyCode: UInt16, shift: Bool)]]
        /// The unshifted character of each key, by ⌘ table.
        let characters: [Bool: [UInt16: Character]]
    }

    /// Rebuilt when the user switches layouts or plugs in another kind of keyboard,
    /// not on every comparison: the key monitors compare many keybinds per key press.
    private var snapshot: Snapshot?
    private var observers: [Any] = []

    private init() {
        let invalidate: (Notification) -> Void = { [weak self] _ in
            self?.snapshot = nil
            NotificationCenter.default.post(name: .keyboardLayoutDidChange, object: nil)
        }
        observers = [
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
                object: nil, queue: .main, using: invalidate
            ),
            // Distributed notifications can be held back while the app is in the background.
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main, using: invalidate
            ),
        ]
    }

    func key(typing character: Character, withCommand: Bool) -> (keyCode: UInt16, shift: Bool)? {
        current().keys[withCommand]?[character]
    }

    /// What `keyCode` types on the Latin layout when the selected layout isn't Latin, so
    /// ⌃ + the G key on a Russian layout is "g", not "п". Nil on a Latin layout, where
    /// the event's own characters are already right.
    func latinCharacter(forKeyCode keyCode: UInt16, withCommand: Bool) -> Character? {
        let snapshot = current()
        guard !snapshot.selectedIsLatin else { return nil }
        return snapshot.characters[withCommand]?[keyCode]
    }

    private func current() -> Snapshot {
        let keyboardType = UInt32(LMGetKbdType())
        if let snapshot, snapshot.keyboardType == keyboardType { return snapshot }
        let snapshot = Self.makeSnapshot(keyboardType: keyboardType)
        self.snapshot = snapshot
        return snapshot
    }

    private static func makeSnapshot(keyboardType: UInt32) -> Snapshot {
        let selected = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        let selectedIsLatin = selected.flatMap { source in
            TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable)
                .map { CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque($0).takeUnretainedValue()) }
        } ?? true
        guard let latin = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let data = TISGetInputSourceProperty(latin, kTISPropertyUnicodeKeyLayoutData) else {
            return Snapshot(keyboardType: keyboardType, selectedIsLatin: selectedIsLatin, keys: [:], characters: [:])
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue() as Data
        var keys: [Bool: [Character: (keyCode: UInt16, shift: Bool)]] = [:]
        var characters: [Bool: [UInt16: Character]] = [:]
        for command in [false, true] {
            (keys[command], characters[command]) = Self.keys(in: layoutData, command: command, keyboardType: keyboardType)
        }
        return Snapshot(keyboardType: keyboardType, selectedIsLatin: selectedIsLatin, keys: keys, characters: characters)
    }

    /// The main keyboard's keys: the letter, number and punctuation keys, the ISO key
    /// beside the left Shift and the JIS keys, but not the keypad, whose "+", "=" and
    /// digits aren't the keys menus mean.
    private static let typingKeyCodes: [UInt16] = Array(0...63) + [93, 94]

    /// Every character the layout types without Shift, then the ones only Shift types,
    /// and the unshifted character of each key.
    private static func keys(
        in layoutData: Data, command: Bool, keyboardType: UInt32
    ) -> ([Character: (keyCode: UInt16, shift: Bool)], [UInt16: Character]) {
        var keys: [Character: (keyCode: UInt16, shift: Bool)] = [:]
        var characters: [UInt16: Character] = [:]
        layoutData.withUnsafeBytes { bytes in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            func character(_ keyCode: UInt16, command: Bool, shift: Bool) -> Character? {
                var modifiers: UInt32 = 0
                if command { modifiers |= UInt32(cmdKey >> 8) & 0xFF }
                if shift { modifiers |= UInt32(shiftKey >> 8) & 0xFF }
                var deadKeyState: UInt32 = 0
                var length = 0
                var units = [UniChar](repeating: 0, count: 4)
                // No dead keys: ` on U.S. International, or ^ on German, is then the
                // character itself rather than the start of an accent.
                let status = UCKeyTranslate(
                    layout, keyCode, UInt16(kUCKeyActionDisplay), modifiers, keyboardType,
                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, units.count, &length, &units
                )
                guard status == noErr, length == 1 else { return nil }
                return String(utf16CodeUnits: units, count: length).lowercased().first
            }
            for shift in [false, true] {
                for keyCode in typingKeyCodes {
                    guard var typed = character(keyCode, command: command, shift: shift) else { continue }
                    // A ⌘ table often ignores Shift (⇧⌘/ gives "/" on a U.S. layout),
                    // while menus write that keystroke with the shifted character (⌘?).
                    // Take it from the plain Shift table then.
                    if command, shift, typed == character(keyCode, command: true, shift: false),
                       let shifted = character(keyCode, command: false, shift: true) {
                        typed = shifted
                    }
                    if !shift { characters[keyCode] = typed }
                    if keys[typed] == nil { keys[typed] = (keyCode, shift) }
                }
            }
        }
        return (keys, characters)
    }
}
