import Foundation

@Observable
final class KeybindSettings {
    
    typealias KeybindOverrideMap = [ConfigKeyCommand.ID: Keybind]
    
    private enum DefaultsKey {
        static let presetId = "keybinds.presetId"
        static let overrides = "keybinds.overrides"
    }
    
    static let shared = KeybindSettings()
    
    let presets: [KeybindFile]
    private(set) var activePresetId: KeybindFile.ID
    private var overrides = KeybindOverrideMap()
    private let defaults = UserDefaults.standard
    
    var hasCustomKeybinds: Bool {
        !self.overrides.isEmpty
    }
    
    private init() {
        self.presets = KeybindFile.loadAllFromBundle()
        
        self.activePresetId = if let presetId = self.defaults.string(forKey: DefaultsKey.presetId) {
            if self.presets.contains(where: { $0.id == presetId }) {
                presetId
            } else {
                KeybindFile.defaultFileId
            }
        } else {
            KeybindFile.defaultFileId
        }
        
        guard let overrideData = self.defaults.data(forKey: DefaultsKey.overrides),
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
            self.overrides.removeValue(forKey: command.id)
            save()
            return
        }
        if let conflict = conflict(for: keybind, excluding: command) {
            throw Error.commandConflict(command, conflict)
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

    private func conflict(
        for candidate: Keybind,
        excluding excludedCommand: ConfigKeyCommand
    ) -> (any KeyCommand)? {
        if let fixed = FixedKeyCommand.allCases.first(where: { keybind(for: $0) == candidate }) {
            return fixed
        }
        return ConfigKeyCommand.allCases.first {
            guard $0 != excludedCommand else { return false }
            return keybind(for: $0) == candidate
        }
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
    
    enum Error: LocalizedError {
        
        case unknownPreset(KeybindFile.ID)
        case commandConflict(ConfigKeyCommand, any KeyCommand)

        var errorDescription: String? {
            switch self {
            case .unknownPreset(let id):
                "Keybind preset '\(id)' is missing."
            case let .commandConflict(proposed, existing):
                "Keybind '\(proposed.title)' conflicts with '\(existing.title)'."
            }
        }
    }
}
