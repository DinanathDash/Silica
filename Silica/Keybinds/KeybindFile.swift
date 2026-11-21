import Foundation

struct KeybindFile: Identifiable, Codable {
    
    let id: String
    let version: Int
    let title: String
    let fixed: [Binding]
    let configurable: [Binding]
    
    static let defaultFileId = "silica"
    
    func binding(for command: FixedKeyCommand) -> Binding? {
        self.fixed.first { $0.id == command.id }
    }
    
    func binding(for command: ConfigKeyCommand) -> Binding? {
        self.configurable.first { $0.id == command.id }
    }
}

// MARK: Binding

extension KeybindFile {
    
    struct Binding: Identifiable, Codable {
        
        enum Modifier: String, Codable {
            case command = "cmd"
            case option = "opt"
            case control = "ctrl"
            case shift = "shift"
        }
        
        let id: String
        let title: String
        let key: String
        let mods: [Modifier]
        
        func asKeybind() -> Keybind? {
            .init(binding: self)
        }
    }
}

// MARK: Loading

extension KeybindFile {
    
    enum LoadError: LocalizedError {
        
        case missingDefaultFile
        case uniqueFileIds
        case unsupportedVersion
        case bindingCollision(KeybindFile.ID, Keybind)
        case bindingMismatch(KeybindFile.ID)
        case invalidKeybinds(KeybindFile.ID)
        
        var errorDescription: String? {
            switch self {
            case .missingDefaultFile: "Missing default keybind file."
            case .uniqueFileIds: "Keybind file IDs must be unique."
            case .unsupportedVersion: "Unsupported keybind file version."
            case let .bindingCollision(fileId, keybind): "Keybind file '\(fileId)' assigns \(keybind.displayName) to more than one command."
            case let .bindingMismatch(fileId): "Keybind file '\(fileId)' does not contain expected bindings."
            case let .invalidKeybinds(fileId): "Keybind file '\(fileId)' contains invalid keybinds."
            }
        }
    }
    
    static func loadAllFromBundle() -> [Self] {
        guard let urls = Bundle.main.urls(
            forResourcesWithExtension: "silicakb",
            subdirectory: nil
        ) else {
            fatalError("No bundled keybind files found.")
        }
        do {
            let files = try urls.sorted {
                $0.lastPathComponent < $1.lastPathComponent
            }
            .map {
                try JSONDecoder().decode(
                    KeybindFile.self,
                    from: Data(contentsOf: $0)
                )
            }
            try validateFiles(files)
            return files
        } catch {
            fatalError("Invalid bundled keybind file: \(error)")
        }
    }
    
    static func load(from url: URL) throws -> KeybindFile {
        let data = try Data(contentsOf: url)
        let file = try JSONDecoder().decode(KeybindFile.self, from: data)
        try validateFile(file)
        return file
    }
    
    private static func validateFiles(_ files: [KeybindFile]) throws {
        guard files.contains(where: { $0.id == Self.defaultFileId }) else {
            throw LoadError.missingDefaultFile
        }
        guard Set(files.map(\.id)).count == files.count else {
            throw LoadError.uniqueFileIds
        }
        for file in files {
            try validateFile(file)
        }
    }
    
    static func validateFile(_ file: KeybindFile) throws {
        guard file.version == 1 else {
            throw LoadError.unsupportedVersion
        }
        try validateBindings(
            file.fixed,
            expectedIds: Set(FixedKeyCommand.allCases.map(\.id)),
            in: file
        )
        try validateBindings(
            file.configurable,
            expectedIds: Set(ConfigKeyCommand.allCases.map(\.id)),
            in: file
        )
        // A ⌥ keybind that types a character never reaches its menu item from the editor.
        // Only Toggle Word Wrap is caught before that; see EditorSettings.
        let typing = file.configurable.first {
            $0.id != ConfigKeyCommand.toggleWordWrap.id && $0.asKeybind()!.typesCharacter
        }
        if typing != nil {
            throw LoadError.invalidKeybinds(file.id)
        }
        // Fixed commands keep their keys in the terminal too (only configurable ones
        // stand aside for the shell), so each needs ⌘ to stay clear of the shell's keys.
        guard file.fixed.allSatisfy({ $0.asKeybind()!.modifiers.contains(.command) }) else {
            throw LoadError.invalidKeybinds(file.id)
        }
        // One keystroke can only run one command; a menu would silently pick one.
        var used = Set(SystemKeyCommand.allCases.map(\.keybind))
        for keybind in (file.fixed + file.configurable).compactMap({ $0.asKeybind() }) {
            guard used.insert(keybind).inserted else {
                throw LoadError.bindingCollision(file.id, keybind)
            }
        }
    }
    
    private static func validateBindings(
        _ bindings: [Binding],
        expectedIds: Set<Binding.ID>,
        in file: KeybindFile
    ) throws {
        let bindingIds = bindings.map(\.id)
        guard bindings.count == expectedIds.count,
              Set(bindingIds).count == bindingIds.count,
              Set(bindingIds) == expectedIds
        else {
            throw LoadError.bindingMismatch(file.id)
        }
        guard bindings.allSatisfy({ $0.asKeybind() != nil }) else {
            throw LoadError.invalidKeybinds(file.id)
        }
    }
}
