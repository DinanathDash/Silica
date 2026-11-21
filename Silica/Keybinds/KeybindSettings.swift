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

    func keybind(for command: FixedKeyCommand) -> Keybind {
        let current = getActivePreset().binding(for: command)?.asKeybind()
        return current ?? Keybind.Fallback.fixed(for: command)
    }

    func keybind(for command: ConfigKeyCommand) -> Keybind {
        let override = self.overrides[command.id]
        let current = getActivePreset().binding(for: command)?.asKeybind()
        return override ?? current ?? Keybind.Fallback.config(for: command)
    }

    func title(for command: FixedKeyCommand) -> String {
        let current = getActivePreset().binding(for: command)?.title
        let `default` = getDefaultPreset().binding(for: command)?.title
        let fallback = command.title
        return current ?? `default` ?? fallback
    }

    func title(for command: ConfigKeyCommand) -> String {
        let current = getActivePreset().binding(for: command)?.title
        let `default` = getDefaultPreset().binding(for: command)?.title
        let fallback = command.title
        return current ?? `default` ?? fallback
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
            if let preset = getActivePreset().binding(for: command)?.asKeybind(),
               let conflict = commandTitle(boundTo: preset, excluding: command) {
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
        if keybind == getActivePreset().binding(for: command)?.asKeybind() {
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

    private func getDefaultPreset() -> KeybindFile {
        guard let preset = self.presets.first(where: { $0.id == KeybindFile.defaultFileId }) else {
            preconditionFailure("Default keybind preset is missing.")
        }
        return preset
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
