import Foundation
import SwiftUI
import Testing

private let presetsFolder = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: "Silica/Keybinds/Presets")

private func preset(_ id: String) throws -> KeybindFile {
    try KeybindFile.load(from: presetsFolder.appending(path: "\(id).silicakb"))
}

private func keybind(_ key: String, _ modifiers: Keybind.Modifiers) -> Keybind {
    Keybind(key: key, modifiers: modifiers)!
}

/// `file` with one configurable binding changed.
private func replacing(_ id: ConfigKeyCommand, in file: KeybindFile, key: String, mods: [KeybindFile.Binding.Modifier]) -> KeybindFile {
    KeybindFile(
        id: file.id,
        version: file.version,
        title: file.title,
        fixed: file.fixed,
        configurable: file.configurable.map {
            $0.id == id.id ? .init(id: $0.id, title: $0.title, key: key, mods: mods) : $0
        }
    )
}

@Suite("Keybind")
struct KeybindTests {
    @Test func sameKeystrokeIsEqual() {
        // How menus write a shifted key, and how the recorder sees it on a US keyboard.
        #expect(keybind("+", .command) == keybind("=", [.shift, .command]))
        #expect(keybind("!", .command) == keybind("1", [.shift, .command]))
        #expect(keybind("}", .command) == keybind("]", [.shift, .command]))
        #expect(keybind("P", .command) == keybind("p", .command))
        #expect(Set([keybind("+", .command), keybind("=", [.shift, .command])]).count == 1)
    }

    @Test func differentKeystrokesDiffer() {
        #expect(keybind("+", .command) != keybind("=", .command))
        #expect(keybind("1", .command) != keybind("1", [.shift, .command]))
    }

    @Test func displayNameUsesMenuOrder() {
        #expect(keybind("1", [.command, .shift]).displayName == "⇧⌘1")
        #expect(keybind("s", [.command, .control]).displayName == "⌃⌘S")
        #expect(keybind("n", [.command, .option]).displayName == "⌥⌘N")
        #expect(Keybind(key: .tab, modifiers: [.shift, .control])!.displayName == "⌃⇧Tab")
    }

    @Test func optionWithLetterTypesCharacter() {
        #expect(keybind("z", .option).typesCharacter)
        #expect(keybind("z", [.option, .shift]).typesCharacter)
        #expect(!keybind("z", [.option, .command]).typesCharacter)
        #expect(!Keybind(key: .upArrow, modifiers: .option)!.typesCharacter)
        // A no-break space, a tab and a line break: only the arrows are function keys.
        #expect(Keybind(key: .space, modifiers: .option)!.typesCharacter)
        #expect(Keybind(key: .tab, modifiers: .option)!.typesCharacter)
        #expect(Keybind(key: .return, modifiers: [.option, .shift])!.typesCharacter)
    }

    @Test func needsCommandOptionOrControl() {
        #expect(Keybind(key: "a", modifiers: []) == nil)
        #expect(Keybind(key: "a", modifiers: .shift) == nil)
    }
}

@Suite("KeybindFile")
struct KeybindFileTests {
    @Test(arguments: ["silica", "vscode", "xcode"])
    func bundledPresetLoads(id: String) throws {
        let file = try preset(id)
        #expect(file.id == id)
    }

    @Test func rejectsTwoCommandsOnOneKeystroke() throws {
        // ⇧⌘+ is ⌘+ (Increase Font Size) on a US keyboard.
        let file = replacing(.resetFontSize, in: try preset("silica"), key: "+", mods: [.shift, .command])
        #expect(throws: KeybindFile.LoadError.self) { try KeybindFile.validateFile(file) }
    }

    @Test func rejectsASystemShortcut() throws {
        let file = replacing(.quickOpen, in: try preset("silica"), key: "c", mods: [.command])
        #expect(throws: KeybindFile.LoadError.self) { try KeybindFile.validateFile(file) }
    }
}

@Suite("KeybindSettings")
final class KeybindSettingsTests {
    let suiteName = "KeybindSettingsTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let presets: [KeybindFile]

    init() throws {
        defaults = UserDefaults(suiteName: suiteName)!
        presets = try ["silica", "vscode", "xcode"].map(preset)
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private func settings() -> KeybindSettings {
        KeybindSettings(presets: presets, defaults: defaults)
    }

    @Test func recordedShiftedDigitConflicts() {
        // The recorder sees ⇧⌘1 as "1" with ⇧⌘; a menu-style "!" with ⌘ is the same key.
        let settings = settings()
        #expect(throws: KeybindSettings.Error.commandConflict(keybind("1", [.shift, .command]), "Welcome Window")) {
            try settings.setKeybind(keybind("1", [.shift, .command]), for: .quickOpen)
        }
        #expect(throws: KeybindSettings.Error.self) {
            try settings.setKeybind(keybind("!", .command), for: .quickOpen)
        }
    }

    @Test func systemShortcutConflicts() {
        #expect(throws: KeybindSettings.Error.commandConflict(keybind("c", .command), "Copy")) {
            try settings().setKeybind(keybind("c", .command), for: .quickOpen)
        }
    }

    @Test(arguments: [
        (keybind("f", .command), "Find"),
        (keybind("g", [.shift, .command]), "Find Previous"),
        (keybind(";", [.shift, .command]), "Show Spelling and Grammar"),
        (keybind("f", [.control, .command]), "Enter Full Screen"),
        (keybind("q", [.option, .command]), "Quit and Keep Windows"),
    ])
    func editAndWindowMenuShortcutsConflict(keybind: Keybind, title: String) {
        #expect(throws: KeybindSettings.Error.commandConflict(keybind, title)) {
            try settings().setKeybind(keybind, for: .goToLine)
        }
    }

    @Test func optionLetterOnlyForWordWrap() throws {
        let settings = settings()
        #expect(throws: KeybindSettings.Error.typesCharacter(keybind("x", .option))) {
            try settings.setKeybind(keybind("x", .option), for: .quickOpen)
        }
        try settings.setKeybind(keybind("x", .option), for: .toggleWordWrap)
        #expect(settings.keybind(for: .toggleWordWrap) == keybind("x", .option))
    }

    @Test func presetKeybindClearsOverride() throws {
        let settings = settings()
        try settings.setKeybind(keybind("p", [.control, .command]), for: .quickOpen)
        #expect(!settings.isDefaultKeybind(for: .quickOpen))
        try settings.setKeybind(keybind("p", .command), for: .quickOpen)
        #expect(settings.isDefaultKeybind(for: .quickOpen))
    }

    @Test func restoringADefaultChecksForConflicts() throws {
        let settings = settings()
        try settings.setKeybind(keybind("b", [.control, .command]), for: .toggleSidebar)
        try settings.setKeybind(keybind("s", [.control, .command]), for: .goToLine)
        #expect(throws: KeybindSettings.Error.commandConflict(keybind("s", [.control, .command]), "Go to Line")) {
            try settings.setKeybind(nil, for: .toggleSidebar)
        }
        #expect(settings.keybind(for: .toggleSidebar) == keybind("b", [.control, .command]))

        try settings.setKeybind(nil, for: .goToLine)
        try settings.setKeybind(nil, for: .toggleSidebar)
        #expect(!settings.hasCustomKeybinds)
    }

    @Test func overridesPersistAndPresetChangeClearsThem() throws {
        try settings().setKeybind(keybind("p", [.control, .command]), for: .quickOpen)
        let reloaded = settings()
        #expect(reloaded.keybind(for: .quickOpen) == keybind("p", [.control, .command]))

        try reloaded.setActivePreset(id: "xcode")
        #expect(!reloaded.hasCustomKeybinds)
        #expect(settings().activePresetId == "xcode")
        #expect(settings().keybind(for: .quickOpen) == keybind("o", [.shift, .command]))
    }

    @Test func tooltipsFollowThePresetAndOverrides() throws {
        let settings = settings()
        #expect(settings.help("Hide Sidebar", for: .toggleSidebar) == "Hide Sidebar (⌃⌘S)")
        try settings.setActivePreset(id: "vscode")
        #expect(settings.help("Hide Sidebar", for: .toggleSidebar) == "Hide Sidebar (⌘B)")
        try settings.setKeybind(keybind("t", [.control, .command]), for: .toggleTerminal)
        #expect(settings.help("Show Terminal", for: .toggleTerminal) == "Show Terminal (⌃⌘T)")
        try settings.setActivePreset(id: "xcode")
        #expect(settings.help("Refresh", for: .refreshExplorer) == "Refresh (⇧⌘R)")
        #expect(settings.help("Show Explorer", for: .explorer) == "Show Explorer (⌘1)")
        // As in Xcode: ⌘0 hides the navigator, ⇧⌘1 opens the Welcome window.
        #expect(settings.help("Hide Sidebar", for: .toggleSidebar) == "Hide Sidebar (⌘0)")
        #expect(settings.keybind(for: .welcomeWindow) == keybind("1", [.shift, .command]))
    }

    @Test func tabAliasIsFreeOnlyWhenUnbound() throws {
        let settings = settings()
        #expect(!settings.isBound(keybind("]", [.shift, .command])))
        try settings.setActivePreset(id: "xcode")
        #expect(settings.isBound(keybind("]", [.shift, .command])))
    }
}
