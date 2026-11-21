import Foundation

@Observable
final class KeybindSettings {

    typealias KeybindOverrideMap = [ConfigKeyCommand.ID: Keybind]

    private enum DefaultsKey {
        static let presetId = "keybinds.presetId"
        static let overrides = "keybinds.overrides"
    }

    static let shared = KeybindSettings(
        presets: KeybindFile.loadAllFromBundle(),
        defaults: .standard
    )

    let presets: [KeybindFile]
    private(set) var activePresetId: KeybindFile.ID
    private var overrides = KeybindOverrideMap()
    @ObservationIgnored private let defaults: UserDefaults

    /// The window of Settings' keybind recorder while it's open. The app's own key
    /// monitors let keys typed there through to the recorder instead of acting on
    /// them; other windows keep their shortcuts.
    @ObservationIgnored weak var recorderWindow: AnyObject?

    var hasCustomKeybinds: Bool {
        !self.overrides.isEmpty
    }
    
    /// How many commands have a keybind of their own instead of the preset's.
    var customKeybindCount: Int {
        self.overrides.count
    }
    
    var activePreset: KeybindFile {
        getActivePreset()
    }

    init(presets: [KeybindFile], defaults: UserDefaults) {
        self.presets = presets
        self.defaults = defaults

        self.activePresetId = if let presetId = defaults.string(forKey: DefaultsKey.presetId),
                                 presets.contains(where: { $0.id == presetId }) {
            presetId
        } else {
            KeybindFile.defaultFileId
        }

        guard let overrideData = defaults.data(forKey: DefaultsKey.overrides),
              let overrideMap = try? JSONDecoder().decode(KeybindOverrideMap.self, from: overrideData)
        else {
            self.overrides = [:]
            return
        }

        // Retain only overrides for commands the current app still supports.
        self.overrides = overrideMap.filter {
            ConfigKeyCommand(rawValue: $0.key) != nil
        }
    }

    // Every preset binds every command to a valid keybind: KeybindFile's validation
    // checks that when the presets load.

    func keybind(for command: FixedKeyCommand) -> Keybind {
        presetBinding(for: command).asKeybind()!
    }

    func keybind(for command: ConfigKeyCommand) -> Keybind {
        self.overrides[command.id] ?? presetBinding(for: command).asKeybind()!
    }

    func title(for command: FixedKeyCommand) -> String {
        presetBinding(for: command).title
    }

    func title(for command: ConfigKeyCommand) -> String {
        presetBinding(for: command).title
    }

    func isDefaultKeybind(for command: ConfigKeyCommand) -> Bool {
        self.overrides[command.id] == nil
    }

    /// A tooltip naming the command's current keybind: "Quick Open (⌘P)".
    func help(_ title: String, for command: ConfigKeyCommand) -> String {
        "\(title) (\(keybind(for: command).displayName))"
    }
    
    func help(_ title: String, for command: FixedKeyCommand) -> String {
        "\(title) (\(keybind(for: command).displayName))"
    }
    
    /// Whether `window` is the keybind recorder's, so a key typed in it is being recorded.
    func isRecorderWindow(_ window: AnyObject?) -> Bool {
        window != nil && window === recorderWindow
    }
    
    /// Whether any command, system ones included, runs on `keybind`.
    func isBound(_ keybind: Keybind) -> Bool {
        commandTitle(boundTo: keybind, excluding: nil) != nil
    }

    func setActivePreset(id: KeybindFile.ID) throws {
        guard let preset = self.presets.first(where: { $0.id == id }) else {
            throw Error.unknownPreset(id)
        }
        // Choosing the preset already in use keeps the keybinds set on top of it.
        guard preset.id != self.activePresetId else { return }
        self.activePresetId = preset.id
        self.overrides = [:]
        save()
    }

    func setKeybind(
        _ keybind: Keybind?,
        for command: ConfigKeyCommand
    ) throws {
        guard let keybind else {
            // Another command may have taken the preset's keystroke in the meantime.
            let preset = presetBinding(for: command).asKeybind()!
            if let conflict = commandTitle(boundTo: preset, excluding: command) {
                throw Error.commandConflict(preset, conflict)
            }
            self.overrides.removeValue(forKey: command.id)
            save()
            return
        }
        // Only Toggle Word Wrap is caught before the editor types the character; see
        // EditorSettings.installKeyboardShortcuts().
        if keybind.typesCharacter, command != .toggleWordWrap {
            throw Error.typesCharacter(keybind)
        }
        if let conflict = commandTitle(boundTo: keybind, excluding: command) {
            throw Error.commandConflict(keybind, conflict)
        }
        if keybind == presetBinding(for: command).asKeybind() {
            // If keybind is equal to our preset's default, remove the override.
            self.overrides.removeValue(forKey: command.id)
        }
        else {
            self.overrides[command.id] = keybind
        }
        save()
    }

    func reset() {
        guard !self.overrides.isEmpty else { return }
        self.overrides = [:]
        save()
    }

    // MARK: Private

    private func getActivePreset() -> KeybindFile {
        guard let preset = self.presets.first(where: { $0.id == self.activePresetId }) else {
            preconditionFailure("Current keybind preset is missing.")
        }
        return preset
    }

    private func presetBinding(for command: FixedKeyCommand) -> KeybindFile.Binding {
        guard let binding = getActivePreset().binding(for: command) else {
            preconditionFailure("Keybind preset has no binding for \(command.id).")
        }
        return binding
    }
    
    private func presetBinding(for command: ConfigKeyCommand) -> KeybindFile.Binding {
        guard let binding = getActivePreset().binding(for: command) else {
            preconditionFailure("Keybind preset has no binding for \(command.id).")
        }
        return binding
    }

    /// The title of the command that `candidate` runs, other than `excludedCommand`.
    private func commandTitle(
        boundTo candidate: Keybind,
        excluding excludedCommand: ConfigKeyCommand?
    ) -> String? {
        if let system = SystemKeyCommand.allCases.first(where: { $0.keybind == candidate }) {
            return system.title
        }
        if let fixed = FixedKeyCommand.allCases.first(where: { keybind(for: $0) == candidate }) {
            return title(for: fixed)
        }
        let config = ConfigKeyCommand.allCases.first {
            $0 != excludedCommand && keybind(for: $0) == candidate
        }
        return config.map { title(for: $0) }
    }

    private func save() {
        self.defaults.set(
            self.activePresetId,
            forKey: DefaultsKey.presetId
        )
        guard !self.overrides.isEmpty else {
            self.defaults.removeObject(forKey: DefaultsKey.overrides)
            return
        }
        do {
            let data = try JSONEncoder().encode(self.overrides)
            self.defaults.set(data, forKey: DefaultsKey.overrides)
        } catch {
            assertionFailure("Failed to save keybind overrides: \(error)")
        }
    }
}

// MARK: KeybindSettings.Error

extension KeybindSettings {

    enum Error: LocalizedError, Equatable {

        case unknownPreset(KeybindFile.ID)
        case commandConflict(Keybind, String)
        case typesCharacter(Keybind)

        var errorDescription: String? {
            switch self {
            case .unknownPreset(let id):
                "Keybind preset '\(id)' is missing."
            case let .commandConflict(keybind, existing):
                "\(keybind.displayName) is already used by \(existing)."
            case let .typesCharacter(keybind):
                "\(keybind.displayName) types a character in the editor. Add ⌘ or ⌃."
            }
        }
    }
}
