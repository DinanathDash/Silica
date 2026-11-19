import Foundation

@Observable
final class KeybindSettings {
    
    static let shared = KeybindSettings()
    private static let defaultsKey = "keybinds"
    
    private var overrides = [String: Keybind]()
    
    private init() {
        guard
            let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
            let storedKeybinds = try? JSONDecoder().decode([String: Keybind].self, from: data)
        else {
            self.overrides = [:]
            return
        }
        var keybindOverrides = [String: Keybind]()
        for (commandId, keybind) in storedKeybinds {
            guard let command = ConfigKeyCommand(rawValue: commandId) else { continue }
            guard keybind != command.defaultKeybind else { continue }
            keybindOverrides[commandId] = keybind
        }
        self.overrides = keybindOverrides
    }
    
    func keybind(for command: any KeyCommand) -> Keybind {
        self.overrides[command.rawValue] ?? command.defaultKeybind
    }
    
    func isDefaultKeybind(for command: any KeyCommand) -> Bool {
        self.overrides[command.rawValue] == nil
    }
    
    func conflict(
        for keybind: Keybind,
        excluding excludedCommand: (any KeyCommand)? = nil
    ) -> (any KeyCommand)? {
        if let fixed = FixedKeyCommand.allCases.first(where: { $0.defaultKeybind == keybind }) {
            return fixed
        }
        else if let config = ConfigKeyCommand.allCases.first(where: {
            if let excludedCommand, excludedCommand.id == $0.id {
                return false
            }
            return self.keybind(for: $0) == keybind
        }) {
            return config
        }
        return nil
    }
    
    func setKeybind(
        _ keybind: Keybind,
        for command: ConfigKeyCommand
    ) throws {
        if let conflict = conflict(for: keybind, excluding: command) {
            throw Error.conflict(conflict)
        }
        if keybind == command.defaultKeybind {
            self.overrides.removeValue(forKey: command.rawValue)
        }
        else {
            self.overrides[command.rawValue] = keybind
        }
        save()
    }
    
    func resetKeybind(for command: ConfigKeyCommand) {
        guard self.overrides.removeValue(forKey: command.rawValue) != nil else {
            return
        }
        save()
    }
    
    func resetAll() {
        guard !self.overrides.isEmpty else {
            return
        }
        self.overrides = [:]
        save()
    }
    
    // MARK: Private
    
    private func save() {
        guard !self.overrides.isEmpty else {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
            return
        }
        do {
            let data = try JSONEncoder().encode(overrides)
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        } catch {
            assertionFailure("Failed to save keybind overrides: \(error)")
        }
    }
}

// MARK: KeybindSettings.Error

extension KeybindSettings {
    
    enum Error: LocalizedError {
        
        case conflict(any KeyCommand)

        var errorDescription: String? {
            switch self {
            case let .conflict(cmd): "This shortcut is already assigned to \"\(cmd.title)\"."
            }
        }
    }
}
