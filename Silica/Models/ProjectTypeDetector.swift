import AppKit
import CryptoKit
import Foundation
import QuickLookThumbnailing
import SwiftUI

/// The mark a project wears: an emoji, the name of an SF Symbol, or an image file path.
/// Matches Droppy Code's storage and representations.
enum ProjectIcon: Hashable, Sendable, Codable {
    case emoji(String)
    case symbol(String)
    case image(String)

    /// The emoji, when the mark is one.
    var emoji: String? {
        if case .emoji(let value) = self { return value }
        return nil
    }

    /// The symbol's name, when the mark is one.
    var symbolName: String? {
        if case .symbol(let name) = self { return name }
        return nil
    }

    /// The image file path, when the mark is one.
    var imagePath: String? {
        if case .image(let path) = self { return path }
        return nil
    }

    /// The stored form: the kind, a colon, the value.
    var storage: String {
        switch self {
        case .emoji(let value): "emoji:\(value)"
        case .symbol(let name): "symbol:\(name)"
        case .image(let path): "image:\(path)"
        }
    }

    /// Reads the stored form.
    init?(storage: String) {
        guard !storage.isEmpty else { return nil }
        if storage.hasPrefix("emoji:") {
            self = .emoji(String(storage.dropFirst("emoji:".count)))
        } else if storage.hasPrefix("symbol:") {
            self = .symbol(String(storage.dropFirst("symbol:".count)))
        } else if storage.hasPrefix("image:") {
            self = .image(String(storage.dropFirst("image:".count)))
        } else {
            self = .symbol(storage)
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let icon = ProjectIcon(storage: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "An empty project icon"))
        }
        self = icon
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storage)
    }
}

/// Detects the repository or project logo image so that Silica can display
/// the real project logo (like Athas) instead of a generic folder mark.
/// If no logo image is found in the project, it returns nil so that the generic folder is used.
@MainActor
final class ProjectTypeDetector {
    private static var cache: [URL: ProjectIcon?] = [:]

    /// Resolves the logo image for a project root directory.
    /// Returns nil if no project logo image is found (falling back to generic folder).
    static func detectIcon(at directoryURL: URL) -> ProjectIcon? {
        let standardized = directoryURL.standardizedFileURL
        if let cached = cache[standardized] {
            return cached
        }

        let icon = resolveIcon(at: standardized)
        cache[standardized] = icon
        return icon
    }

    /// Clears the detection cache (e.g., if files in the workspace change).
    static func invalidateCache(for directoryURL: URL? = nil) {
        if let directoryURL {
            cache.removeValue(forKey: directoryURL.standardizedFileURL)
        } else {
            cache.removeAll()
        }
    }

    private static func resolveIcon(at url: URL) -> ProjectIcon? {
        let fm = FileManager.default
        let repoName = url.lastPathComponent.lowercased()

        // 1. Direct candidate logo/icon files in repository (including repo name and favicon variations)
        let directCandidates = [
            // Standard docs / github / brand paths
            "docs/icon.png",
            "docs/logo.png",
            "docs/droppy-logo.png",
            ".github/icon.png",
            ".github/logo.png",
            "icon.png",
            "logo.png",
            "assets/icon.png",
            "assets/logo.png",
            "assets/brand/icon.png",
            "assets/brand/logo.png",
            "public/icon.png",
            "public/logo.png",
            // Favicons
            "public/favicon.png",
            "public/favicon.ico",
            "public/favicon.svg",
            "favicon.png",
            "favicon.ico",
            "favicon.svg",
            // Repo-named images in root and common subfolders
            "\(repoName).png",
            "\(repoName)-logo.png",
            "\(repoName)_logo.png",
            "\(repoName)-icon.png",
            "\(repoName)_icon.png",
            "docs/\(repoName).png",
            "docs/\(repoName)-logo.png",
            "docs/\(repoName)_logo.png",
            "assets/\(repoName).png",
            "assets/\(repoName)-logo.png"
        ]
        for candidate in directCandidates {
            let candidateURL = url.appendingPathComponent(candidate)
            if fm.fileExists(atPath: candidateURL.path) {
                return .image(candidateURL.path)
            }
        }

        // 2. Fast search for Apple .icon bundles (Icon Composer), .appiconset, or .icns
        if let iconBundle = findIconBundle(at: url, fm: fm) {
            return .image(iconBundle)
        }

        // 3. Search for .appiconset, .icns, or logo imageset in xcassets
        if let iconAsset = findAppIconAsset(at: url, fm: fm) {
            return .image(iconAsset)
        }

        // No logo image found: return nil so generic folder icon is used
        return nil
    }

    private static func findIconBundle(at rootURL: URL, fm: FileManager) -> String? {
        let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        while let fileURL = enumerator?.nextObject() as? URL {
            let relativePath = fileURL.path.replacingOccurrences(of: rootURL.path, with: "")
            let components = relativePath.split(separator: "/")
            if components.count > 5 {
                enumerator?.skipDescendants()
                continue
            }
            if components.contains(".git") || components.contains("build.noindex") || components.contains(".build") || components.contains("node_modules") {
                enumerator?.skipDescendants()
                continue
            }

            if fileURL.pathExtension == "icon" {
                enumerator?.skipDescendants()
                if let rendered = renderedThumbnailPath(for: fileURL) {
                    return rendered
                }
                let assetsURL = fileURL.appendingPathComponent("Assets")
                if let assetFiles = try? fm.contentsOfDirectory(atPath: assetsURL.path) {
                    let candidates = assetFiles.filter {
                        !$0.lowercased().contains("shadow") && ($0.hasSuffix(".png") || $0.hasSuffix(".svg"))
                    }
                    if let mascot = candidates.first(where: { $0.lowercased().contains("mascot") || $0.lowercased().contains("logo") || $0.lowercased().contains("icon") }) {
                        return assetsURL.appendingPathComponent(mascot).path
                    }
                    if let first = candidates.first {
                        return assetsURL.appendingPathComponent(first).path
                    }
                }
            }
        }
        return nil
    }

    /// Renders an Apple Icon Composer (.icon) bundle to a cached high-resolution PNG using QuickLook.
    private static func renderedThumbnailPath(for iconBundleURL: URL) -> String? {
        guard let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.silica.project-icons", isDirectory: true) else {
            return nil
        }
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let hash = Insecure.MD5.hash(data: Data(iconBundleURL.path.utf8)).map { String(format: "%02hhx", $0) }.joined()
        let cachedFile = cacheDir.appendingPathComponent("\(hash).png")
        if FileManager.default.fileExists(atPath: cachedFile.path) {
            return cachedFile.path
        }
        let req = QLThumbnailGenerator.Request(fileAt: iconBundleURL, size: CGSize(width: 256, height: 256), scale: 2.0, representationTypes: .thumbnail)
        let sema = DispatchSemaphore(value: 0)
        var generatedImage: NSImage?
        QLThumbnailGenerator.shared.generateRepresentations(for: req) { rep, _, _ in
            if let rep { generatedImage = rep.nsImage }
            sema.signal()
        }
        _ = sema.wait(timeout: .now() + 0.8)
        if let generatedImage,
           let tiff = generatedImage.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: cachedFile)
            return cachedFile.path
        }
        return nil
    }

    private static func findAppIconAsset(at rootURL: URL, fm: FileManager) -> String? {
        let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        while let fileURL = enumerator?.nextObject() as? URL {
            let relativePath = fileURL.path.replacingOccurrences(of: rootURL.path, with: "")
            let components = relativePath.split(separator: "/")
            if components.count > 5 {
                enumerator?.skipDescendants()
                continue
            }
            if components.contains(".git") || components.contains("build.noindex") || components.contains(".build") || components.contains("node_modules") {
                enumerator?.skipDescendants()
                continue
            }

            if fileURL.pathExtension == "icns" {
                return fileURL.path
            }

            if fileURL.pathExtension == "appiconset" {
                enumerator?.skipDescendants()
                if let pngs = try? fm.contentsOfDirectory(atPath: fileURL.path) {
                    let images = pngs.filter { $0.hasSuffix(".png") }
                    if let best = images.sorted(by: { $0.count > $1.count }).first {
                        return fileURL.appendingPathComponent(best).path
                    }
                }
            }

            if fileURL.lastPathComponent.contains("logo") && fileURL.pathExtension == "imageset" {
                enumerator?.skipDescendants()
                if let pngs = try? fm.contentsOfDirectory(atPath: fileURL.path) {
                    if let png = pngs.first(where: { $0.hasSuffix(".png") }) {
                        return fileURL.appendingPathComponent(png).path
                    }
                }
            }
        }
        return nil
    }
}

extension RecentProject {
    /// The project's effective mark: detected repo logo image if present,
    /// otherwise nil (which falls back to the generic folder mark).
    @MainActor
    var effectiveIcon: ProjectIcon? {
        ProjectTypeDetector.detectIcon(at: URL(filePath: path))
    }
}

extension WorkspaceModel {
    /// The project's effective mark: detected repo logo image if present,
    /// otherwise nil (which falls back to the generic folder mark).
    @MainActor
    var effectiveIcon: ProjectIcon? {
        ProjectTypeDetector.detectIcon(at: rootURL)
    }
}

/// A project's mark: draws the detected repo logo image, emoji or symbol, or falls back to
/// the Finder folder icon with uniform square sizing across all project items.
struct ProjectIconMark: View {
    let icon: ProjectIcon?
    var fallbackURL: URL? = nil
    var size: CGFloat = 13

    var body: some View {
        Group {
            if let emoji = icon?.emoji {
                Text(verbatim: emoji)
                    .font(.system(size: size * 0.82))
                    .frame(width: size, height: size, alignment: .center)
            } else if let path = icon?.imagePath, let nsImage = NSImage(contentsOfFile: path) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size, alignment: .center)
                    .clipShape(RoundedRectangle(cornerRadius: max(2, size * 0.22), style: .continuous))
            } else if let fallbackURL {
                FileIcon(url: fallbackURL, isDirectory: true, width: size)
                    .frame(width: size, height: size, alignment: .center)
            } else {
                Image(systemName: icon?.symbolName ?? "folder.fill")
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size * 0.75, height: size * 0.75, alignment: .center)
                    .frame(width: size, height: size, alignment: .center)
            }
        }
        .frame(width: size, height: size, alignment: .center)
    }
}
