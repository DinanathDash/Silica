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
    /// The key that types `character`, and the modifiers it needs for that (Shift, ⌥,
    /// or both), using the layout's ⌘ table when `withCommand` is true (some layouts,
    /// such as "Dvorak – QWERTY ⌘", switch keys while ⌘ is held). Nil if no key types it.
    func key(typing character: Character, withCommand: Bool) -> (keyCode: UInt16, modifiers: Keybind.Modifiers)?
}

extension Notification.Name {
    /// Posted after the user switches keyboard layouts.
    static let keyboardLayoutDidChange = Notification.Name("SilicaKeyboardLayoutDidChange")
}

// MARK: KeyboardLayoutTable

/// One keyboard layout's keys, read from its layout data.
struct KeyboardLayoutTable: KeyboardLayout {
    private var keys: [Bool: [Character: (keyCode: UInt16, modifiers: Keybind.Modifiers)]] = [:]
    /// The unshifted character of each key, by ⌘ table.
    private(set) var characters: [Bool: [UInt16: Character]] = [:]

    /// The layout with `inputSourceID`, such as "com.apple.keylayout.German", whether or
    /// not the user has it enabled.
    init?(inputSourceID: String) {
        let filter = [kTISPropertyInputSourceID as String: inputSourceID] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = sources.first else { return nil }
        self.init(source: source)
    }

    init?(source: TISInputSource) {
        guard let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue() as Data
        let keyboardType = UInt32(LMGetKbdType())
        for command in [false, true] {
            (keys[command], characters[command]) = Self.keys(in: layoutData, command: command, keyboardType: keyboardType)
        }
    }

    func key(typing character: Character, withCommand: Bool) -> (keyCode: UInt16, modifiers: Keybind.Modifiers)? {
        keys[withCommand]?[character]
    }

    /// The main keyboard's keys: the letter, number and punctuation keys, the ISO key
    /// beside the left Shift and the JIS keys, but not the keypad, whose "+", "=" and
    /// digits aren't the keys menus mean.
    private static let typingKeyCodes: [UInt16] = Array(0...63) + [93, 94]

    /// The modifiers a character can need, tried in this order so a character gets
    /// the simplest keystroke that types it: none, Shift, ⌥ ("]" is ⌥6 on German),
    /// then both.
    private static let layers: [Keybind.Modifiers] = [[], .shift, .option, [.option, .shift]]

    /// Every character the layout types, with the key and modifiers that type it, and
    /// the unshifted character of each key.
    private static func keys(
        in layoutData: Data, command: Bool, keyboardType: UInt32
    ) -> ([Character: (keyCode: UInt16, modifiers: Keybind.Modifiers)], [UInt16: Character]) {
        var keys: [Character: (keyCode: UInt16, modifiers: Keybind.Modifiers)] = [:]
        var characters: [UInt16: Character] = [:]
        // Each layer's modifiers as UCKeyTranslate takes them, worked out here rather
        // than inside the closure below, which isn't on the main actor.
        let layers = Self.layers.map { layer in
            var carbon: UInt32 = 0
            if layer.contains(.shift) { carbon |= UInt32(shiftKey >> 8) & 0xFF }
            if layer.contains(.option) { carbon |= UInt32(optionKey >> 8) & 0xFF }
            return (modifiers: layer, carbon: carbon)
        }
        layoutData.withUnsafeBytes { bytes in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            func character(_ keyCode: UInt16, command: Bool, _ layer: UInt32) -> Character? {
                var modifiers = layer
                if command { modifiers |= UInt32(cmdKey >> 8) & 0xFF }
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
            // The key that types each character with no modifiers, without ⌘.
            var plainKeys: [Character: UInt16] = [:]
            for keyCode in typingKeyCodes {
                if let typed = character(keyCode, command: false, 0), plainKeys[typed] == nil {
                    plainKeys[typed] = keyCode
                }
            }
            for layer in layers {
                for keyCode in typingKeyCodes {
                    guard var typed = character(keyCode, command: command, layer.carbon) else { continue }
                    // A ⌘ table often ignores Shift or ⌥ (⇧⌘/ gives "/" on a U.S. layout),
                    // while menus write that keystroke with the shifted character (⌘?).
                    // Take it then from the key that types the same character without ⌘:
                    // the same key on most layouts, another on "Dvorak – QWERTY ⌘".
                    if command, layer.carbon != 0, let unmodified = character(keyCode, command: true, 0),
                       typed == unmodified {
                        guard let plainKey = plainKeys[unmodified],
                              let layered = character(plainKey, command: false, layer.carbon) else { continue }
                        typed = layered
                    }
                    if layer.carbon == 0 { characters[keyCode] = typed }
                    if keys[typed] == nil { keys[typed] = (keyCode, layer.modifiers) }
                }
            }
        }
        return (keys, characters)
    }
}

// MARK: CurrentKeyboardLayout

/// The keyboard layout the user types shortcuts with: the selected layout, or for a
/// non-Latin one (Russian, Greek) the Latin layout macOS keeps beside it, which is the
/// one shortcuts are written in.
final class CurrentKeyboardLayout: KeyboardLayout {
    static let shared = CurrentKeyboardLayout()

    private struct Snapshot {
        let keyboardType: UInt32
        /// Whether the selected layout types Latin letters itself.
        let selectedIsLatin: Bool
        let table: KeyboardLayoutTable?
    }

    /// Rebuilt when the user switches layouts or plugs in another kind of keyboard,
    /// not on every comparison: the key monitors compare many keybinds per key press.
    private var snapshot: Snapshot?
    private var observers: [Any] = []

    private init() {
        let invalidate: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                self?.snapshot = nil
                NotificationCenter.default.post(name: .keyboardLayoutDidChange, object: nil)
            }
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

    func key(typing character: Character, withCommand: Bool) -> (keyCode: UInt16, modifiers: Keybind.Modifiers)? {
        current().table?.key(typing: character, withCommand: withCommand)
    }

    /// What `keyCode` types on the Latin layout when the selected layout isn't Latin, so
    /// ⌃ + the G key on a Russian layout is "g", not "п". Nil on a Latin layout, where
    /// the event's own characters are already right.
    func latinCharacter(forKeyCode keyCode: UInt16, withCommand: Bool) -> Character? {
        let snapshot = current()
        guard !snapshot.selectedIsLatin else { return nil }
        return snapshot.table?.characters[withCommand]?[keyCode]
    }

    private func current() -> Snapshot {
        let keyboardType = UInt32(LMGetKbdType())
        if let snapshot, snapshot.keyboardType == keyboardType { return snapshot }
        let selected = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        let selectedIsLatin = selected.flatMap { source in
            TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable)
                .map { CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque($0).takeUnretainedValue()) }
        } ?? true
        let table = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()
            .flatMap { KeyboardLayoutTable(source: $0.takeRetainedValue()) }
        let snapshot = Snapshot(keyboardType: keyboardType, selectedIsLatin: selectedIsLatin, table: table)
        self.snapshot = snapshot
        return snapshot
    }
}
