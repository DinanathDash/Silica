import Foundation
import Observation

/// Low-priority background directory and file size provider with caching.
/// Mimics asynchronous background calculation with concurrency limiting and time-based invalidation.
@MainActor @Observable
final class FileSizeCache {
    static let shared = FileSizeCache()

    private var cache: [URL: (size: Int64, date: Date)] = [:]
    private var inFlight: Set<URL> = []
    private let cacheLifetime: TimeInterval = 300 // 5 minutes cache

    func formattedSize(for node: FileNode, isHoveredOrSelected: Bool) -> String? {
        guard isHoveredOrSelected else { return nil }

        if !node.isDirectory {
            if let cached = cache[node.url], Date().timeIntervalSince(cached.date) < cacheLifetime {
                return ByteCountFormatter.string(fromByteCount: cached.size, countStyle: .file)
            }
            if let values = try? node.url.resourceValues(forKeys: [.fileSizeKey]),
               let size = values.fileSize {
                let size64 = Int64(size)
                pruneIfNeeded()
                cache[node.url] = (size64, Date())
                return ByteCountFormatter.string(fromByteCount: size64, countStyle: .file)
            }
            return nil
        }

        // For directories: return cached size if available
        if let cached = cache[node.url], Date().timeIntervalSince(cached.date) < cacheLifetime {
            return ByteCountFormatter.string(fromByteCount: cached.size, countStyle: .file)
        }

        // Calculate in background actor if not already computing
        requestDirectorySize(for: node.url)

        // Show immediate shallow items count as placeholder while background size calculates
        if let count = (try? FileManager.default.contentsOfDirectory(atPath: node.url.path(percentEncoded: false)))?.count {
            return "\(count) item\(count == 1 ? "" : "s")"
        }
        return nil
    }

    private func pruneIfNeeded() {
        guard cache.count > 500 else { return }
        let now = Date()
        cache = cache.filter { now.timeIntervalSince($0.value.date) < cacheLifetime }
        if cache.count > 1000 {
            let toKeep = cache.sorted { $0.value.date > $1.value.date }.prefix(500)
            cache = Dictionary(uniqueKeysWithValues: Array(toKeep))
        }
    }

    private func requestDirectorySize(for url: URL) {
        guard !inFlight.contains(url) else { return }
        inFlight.insert(url)

        Task.detached(priority: .utility) {
            let total = DirectorySizeScanner.computeSize(at: url)
            await MainActor.run {
                self.inFlight.remove(url)
                if let total {
                    self.pruneIfNeeded()
                    self.cache[url] = (total, Date())
                }
            }
        }
    }

    func invalidate(for url: URL) {
        cache.removeValue(forKey: url)
    }

    func clear() {
        cache.removeAll()
        inFlight.removeAll()
    }
}

nonisolated private enum DirectorySizeScanner {
    static func computeSize(at url: URL) -> Int64? {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        var total: Int64 = 0
        var itemsCount = 0

        for case let fileURL as URL in enumerator {
            itemsCount += 1
            // Prevent runaway processing in huge directories like node_modules
            if itemsCount > 2000 { break }

            if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
               values.isDirectory != true,
               let size = values.fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}
