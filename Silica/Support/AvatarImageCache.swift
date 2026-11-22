import AppKit
import CryptoKit
import SwiftUI

/// App-wide avatar caching and compression service.
/// Compresses avatars to crisp 96x96 thumbnails and strictly caps persistent disk cache under 20MB.
@MainActor
final class AvatarImageCache {
    static let shared = AvatarImageCache()

    private let memoryCache = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    nonisolated private let diskCacheURL: URL
    private let maxDiskBytes: Int64 = 20 * 1024 * 1024 // 20 MB maximum disk cache
    private let maxPixelDimension: CGFloat = 96

    private init() {
        memoryCache.countLimit = 250
        memoryCache.totalCostLimit = 15 * 1024 * 1024

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskCacheURL = caches.appendingPathComponent("com.silica.avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
    }

    /// Fast synchronous memory or disk hit
    func cachedImage(for url: URL) -> NSImage? {
        let key = url.absoluteString as NSString
        if let mem = memoryCache.object(forKey: key) {
            return mem
        }
        let filePath = fileURL(for: url)
        if let data = try? Data(contentsOf: filePath), let img = NSImage(data: data) {
            let cost = Int(img.size.width * img.size.height * 4)
            memoryCache.setObject(img, forKey: key, cost: cost)
            return img
        }
        return nil
    }

    /// Asynchronously returns the cached image, or downloads, compresses, and caches to disk.
    func image(for url: URL) async -> NSImage? {
        if let existing = cachedImage(for: url) {
            return existing
        }

        let urlString = url.absoluteString
        if let ongoing = inFlight[urlString] {
            return await ongoing.value
        }

        let task = Task<NSImage?, Never>.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return nil }
            var request = URLRequest(url: url)
            request.timeoutInterval = 4
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let rawImage = NSImage(data: data) else {
                return nil
            }

            // Downscale to max 96x96 px and compress to JPEG
            guard let compressedData = self.compressAndDownscale(rawImage: rawImage) else {
                return rawImage
            }

            // Write to disk
            let path = self.fileURL(for: url)
            try? compressedData.write(to: path, options: .atomic)
            self.pruneDiskCacheIfNeeded()

            return NSImage(data: compressedData)
        }

        inFlight[urlString] = task
        let result = await task.value
        inFlight.removeValue(forKey: urlString)

        if let result {
            let key = url.absoluteString as NSString
            let cost = Int(result.size.width * result.size.height * 4)
            memoryCache.setObject(result, forKey: key, cost: cost)
        }
        return result
    }

    nonisolated private func fileURL(for url: URL) -> URL {
        let hash = Insecure.MD5.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02hhx", $0) }.joined()
        return diskCacheURL.appendingPathComponent("\(hash).jpg")
    }

    nonisolated private func compressAndDownscale(rawImage: NSImage) -> Data? {
        guard let cgImage = rawImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        guard width > 0 && height > 0 else { return nil }

        let scale = min(1.0, min(maxPixelDimension / width, maxPixelDimension / height))
        let targetWidth = max(16, Int(width * scale))
        let targetHeight = max(16, Int(height * scale))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let resizedCG = context.makeImage() else { return nil }

        let rep = NSBitmapImageRep(cgImage: resizedCG)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    nonisolated private func pruneDiskCacheIfNeeded() {
        let fileManager = FileManager.default
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("com.silica.avatars", isDirectory: true)
        guard let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }

        var totalSize: Int64 = 0
        var fileList: [(url: URL, size: Int64, date: Date)] = []
        for file in files {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize,
                  let date = values.contentModificationDate else { continue }
            totalSize += Int64(size)
            fileList.append((file, Int64(size), date))
        }

        let maxLimit: Int64 = 20 * 1024 * 1024 // 20 MB
        if totalSize > maxLimit {
            fileList.sort { $0.date < $1.date } // oldest first
            for item in fileList {
                try? fileManager.removeItem(at: item.url)
                totalSize -= item.size
                if totalSize < maxLimit * 3 / 4 { // prune down to 15MB
                    break
                }
            }
        }
    }
}

/// Generic avatar view that loads instantly from AvatarImageCache with initials badge fallback.
struct CachedAvatarView: View {
    let url: URL?
    let fallbackText: String
    var fallbackColor: Color = .accentColor

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
            } else {
                Circle()
                    .fill(fallbackColor.gradient)
                    .overlay {
                        Text(fallbackText)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 0.5))
            }
        }
        .onAppear {
            if let url, let cached = AvatarImageCache.shared.cachedImage(for: url) {
                self.image = cached
            }
        }
        .task(id: url) {
            guard let url else { return }
            if let cached = AvatarImageCache.shared.cachedImage(for: url) {
                self.image = cached
                return
            }
            self.image = await AvatarImageCache.shared.image(for: url)
        }
    }
}
