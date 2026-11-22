import SwiftUI
import UniformTypeIdentifiers

/// Pierre VS Code icon + tint for files, loaded natively from SVG.
/// Folders get the icon Finder shows for them.
struct FileIcon: View {
    let url: URL
    var isDirectory = false
    var isExpanded = false
    var width: CGFloat = 16

    var body: some View {
        let (iconName, fallbackSymbol, color) = Self.style(for: url, isDirectory: isDirectory, isExpanded: isExpanded)
        if let iconName, let nsImage = PierreIconCache.shared.image(named: iconName) {
            Image(nsImage: nsImage)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(color)
                .frame(width: width, height: width)
        } else if isDirectory {
            Image(nsImage: FolderIcons.shared.icon(for: url))
                .resizable()
                .interpolation(.high)
                .frame(width: width, height: width)
        } else {
            Image(systemName: fallbackSymbol)
                .foregroundStyle(color)
                .frame(width: width)
        }
    }

    static func style(for url: URL, isDirectory: Bool, isExpanded: Bool) -> (String?, String, Color) {
        typealias C = FileIconPalette
        if isDirectory {
            let iconName = isExpanded ? "folder-open" : "folder"
            let fallbackSymbol = isExpanded ? "folder.fill" : "folder"
            return (iconName, fallbackSymbol, C.folder)
        }
        let code = "chevron.left.forwardslash.chevron.right"
        let name = url.lastPathComponent.lowercased()

        // Specific filenames
        switch name {
        case "package.swift": return ("lang-swift", "swift", C.swift)
        case "dockerfile", "docker-compose.yml", "docker-compose.yaml": return ("docker", "shippingbox", C.blue)
        case "makefile": return ("gear", "hammer", C.brown)
        case "license", "license.md", "license.txt": return ("file-text-duo", "checkmark.seal", C.yellow)
        case ".gitignore", ".gitattributes", ".gitmodules": return ("git", "arrow.triangle.branch", C.red)
        case "package.json", "package-lock.json": return ("npm-duo", "curlybraces.square", C.red)
        case "bun.lockb", "bunfig.toml": return ("bun-duo", "curlybraces", C.amber)
        case "tsconfig.json", "jsconfig.json": return ("lang-typescript-duo", "curlybraces.square", C.blue)
        case "vite.config.js", "vite.config.ts", "vite.config.mjs": return ("vite", "bolt", C.purple)
        case "next.config.js", "next.config.mjs", "next.config.ts": return ("nextjs", "arrow.triangle.swap", C.neutral)
        case "tailwind.config.js", "tailwind.config.ts": return ("tailwind", "paintbrush", C.cyan)
        case ".prettierrc", ".prettierrc.json", ".prettierrc.yml", "prettier.config.js": return ("prettier", "wand.and.stars", C.steel)
        case ".eslintrc", ".eslintrc.json", ".eslintrc.js", "eslint.config.js": return ("eslint", "exclamationmark.triangle", C.purple)
        case "biome.json", "biome.jsonc": return ("biome", "sparkles", C.cyan)
        default: break
        }

        // Extensions
        switch url.pathExtension.lowercased() {
        case "swift": return ("lang-swift", "swift", C.swift)
        case "js", "mjs", "cjs": return ("lang-javascript-duo", "curlybraces", C.yellow)
        case "ts": return ("lang-typescript-duo", "curlybraces", C.blue)
        case "jsx": return ("react", "curlybraces", C.cyan)
        case "tsx": return ("react", "curlybraces", C.blue)
        case "vue": return ("vue", code, C.green)
        case "svelte": return ("svelte", code, C.amber)
        case "astro": return ("astro", code, C.pink)
        case "json", "jsonc": return ("braces", "curlybraces.square", C.amber)
        case "md", "markdown", "mdx": return ("lang-markdown", "text.alignleft", C.indigo)
        case "html", "htm": return ("lang-html-duo", code, C.pink)
        case "xml", "svg": return ("svg", code, C.mint)
        case "css": return ("lang-css-duo", "paintbrush", C.purple)
        case "scss", "sass", "less": return ("sass", "paintbrush", C.pink)
        case "py", "pyw": return ("lang-python", code, C.teal)
        case "go": return ("lang-go", code, C.cyan)
        case "dart": return ("code", code, C.cyan)
        case "rb": return ("lang-ruby", code, C.red)
        case "rs": return ("lang-rust", code, C.brown)
        case "zig": return ("zig", code, C.amber)
        case "c", "h": return ("lang-c", code, C.blue)
        case "cpp", "hpp", "cc", "cxx", "m", "mm": return ("lang-c", code, C.blue)
        case "sh", "zsh", "bash", "fish": return ("bash-duo", "terminal", C.green)
        case "yml", "yaml": return ("yml", "gearshape", C.steel)
        case "toml", "ini", "plist", "xcconfig", "env": return ("gear", "gearshape", C.steel)
        case "graphql", "gql": return ("graphql", "network", C.pink)
        case "tf", "terraform": return ("terraform", "square.stack.3d.up", C.purple)
        case "wasm": return ("wasm-duo", "cpu", C.indigo)
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "ico", "icns": return ("image-duo", "photo", C.mint)
        case "csv", "tsv", "xls", "xlsx": return ("file-table-duo", "tablecells", C.green)
        case "pdf": return ("file-text-duo", "doc.richtext", C.red)
        case "mp4", "mov", "m4v", "avi", "mkv", "webm", "mpg", "mpeg", "3gp": return ("file-duo", "film", C.purple)
        case "zip", "gz", "tar", "rar", "7z": return ("file-zip-duo", "archivebox", C.brown)
        case "diff", "patch", "rej": return ("code", "plusminus", C.green)
        case "lock", "resolved": return ("file-duo", "lock", C.neutral)
        case "txt", "log": return ("file-text-duo", "doc.plaintext", C.neutral)
        default: return ("file-duo", "doc", C.neutral)
        }
    }
}

/// In-memory cache for Pierre VS Code SVGs loaded directly from application resources.
@MainActor
final class PierreIconCache {
    static let shared = PierreIconCache()
    private var cache: [String: NSImage] = [:]

    func image(named name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        let possibleURLs: [URL?] = [
            Bundle.main.url(forResource: name, withExtension: "svg"),
            Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "Icons"),
            Bundle.main.resourceURL?.appendingPathComponent("\(name).svg"),
            Bundle.main.resourceURL?.appendingPathComponent("Icons/\(name).svg"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\(name).svg"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Icons/\(name).svg"),
            URL(fileURLWithPath: "Silica/Resources/Icons/\(name).svg")
        ]
        for url in possibleURLs.compactMap({ $0 }) {
            if let image = NSImage(contentsOf: url) {
                image.isTemplate = true
                cache[name] = image
                return image
            }
        }
        return nil
    }
}

/// Finder's icons for folders: custom icons, packages and the system's special
/// folders look as they do there. Kept until files change on disk.
@MainActor @Observable
final class FolderIcons {
    static let shared = FolderIcons()

    /// Read by every folder icon, so they are all fetched again after `reload()`.
    private var generation = 0
    @ObservationIgnored private var icons: [URL: NSImage] = [:]

    func icon(for url: URL) -> NSImage {
        _ = generation
        if let icon = icons[url] { return icon }
        let path = url.path(percentEncoded: false)
        // A folder still being named isn't on disk yet: the plain folder.
        let icon = FileManager.default.fileExists(atPath: path)
            ? NSWorkspace.shared.icon(forFile: path)
            : NSWorkspace.shared.icon(for: .folder)
        icons[url] = icon
        return icon
    }

    /// Forgets every icon; a folder's icon may have been changed in Finder.
    func reload() {
        guard !icons.isEmpty else { return }
        icons.removeAll()
        generation += 1
    }
}

/// Xcode-style icon colors: blue folders and orange Swift files, plus a hue per
/// file family, each with a deeper light-mode and a brighter dark-mode shade.
enum FileIconPalette {
    static let folder = dynamic(light: 0x3B8EEA, dark: 0x5AA5F5)
    static let swift = dynamic(light: 0xF05138, dark: 0xF4693F)

    static let blue = dynamic(light: 0x2F74C0, dark: 0x5E9BEA)
    static let cyan = dynamic(light: 0x0089AD, dark: 0x3EC3E6)
    static let teal = dynamic(light: 0x1F8A8A, dark: 0x4CC2C2)
    static let mint = dynamic(light: 0x2E9C78, dark: 0x5CC9A2)
    static let green = dynamic(light: 0x3A9150, dark: 0x63C27A)
    static let yellow = dynamic(light: 0xB88A00, dark: 0xEAC04A)
    static let amber = dynamic(light: 0xC26F0F, dark: 0xF09A45)
    static let red = dynamic(light: 0xCC3D3D, dark: 0xF06C66)
    static let pink = dynamic(light: 0xC2357F, dark: 0xF06AAE)
    static let purple = dynamic(light: 0x8A45C4, dark: 0xB582EE)
    static let indigo = dynamic(light: 0x5653C9, dark: 0x8784F5)
    static let brown = dynamic(light: 0x976236, dark: 0xC9976A)
    static let steel = dynamic(light: 0x5F7C9B, dark: 0x92ADC9)
    static let neutral = dynamic(light: 0x8A8D94, dark: 0xA2A5AC)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}
