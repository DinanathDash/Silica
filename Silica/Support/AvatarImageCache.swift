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

    /// Fast synchronous memory-only hit on MainActor to avoid disk stalling
    func cachedImage(for url: URL) -> NSImage? {
        let key = url.absoluteString as NSString
        return memoryCache.object(forKey: key)
    }

    /// Asynchronously returns the cached image (memory or disk), or downloads, compresses, and caches to disk.
    func image(for url: URL) async -> NSImage? {
        let key = url.absoluteString as NSString
        if let mem = memoryCache.object(forKey: key) {
            return mem
        }

        let urlString = url.absoluteString
        if let ongoing = inFlight[urlString] {
            return await ongoing.value
        }

        let task = Task<NSImage?, Never>.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return nil }
            let path = self.fileURL(for: url)
            if let data = try? Data(contentsOf: path), let img = NSImage(data: data) {
                return img
            }

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
            try? compressedData.write(to: path, options: .atomic)
            self.pruneDiskCacheIfNeeded()

            return NSImage(data: compressedData)
        }

        inFlight[urlString] = task
        defer { inFlight.removeValue(forKey: urlString) }
        let result = await task.value

        if let result {
            let cost = Int(result.size.width * result.size.height * 4)
            memoryCache.setObject(result, forKey: key, cost: cost)
        }
        return result
    }

    /// Fast synchronous memory-only hit for author avatar
    func cachedAuthorAvatar(email: String, name: String, remoteHost: RemoteHostType = .unknown) -> NSImage? {
        let key = authorKey(email: email, name: name, host: remoteHost) as NSString
        return memoryCache.object(forKey: key)
    }

    private func authorKey(email: String, name: String, host: RemoteHostType = .unknown) -> String {
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let id = cleanEmail.isEmpty ? cleanName : cleanEmail
        return "\(host.rawValue):\(id)"
    }

    /// Resolves author avatar from repository host platform (GitLab, GitHub, Bitbucket, Gravatar, etc.)
    func resolveAuthorAvatar(
        authorName: String,
        authorEmail: String,
        remoteHost: RemoteHostType,
        remoteOriginURL: String?
    ) async -> NSImage? {
        let key = authorKey(email: authorEmail, name: authorName, host: remoteHost)
        guard !key.isEmpty else { return nil }

        if let mem = memoryCache.object(forKey: key as NSString) {
            return mem
        }

        if let ongoing = inFlight[key] {
            return await ongoing.value
        }

        let task = Task<NSImage?, Never>.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return nil }
            let path = self.fileURL(for: key)
            if let data = try? Data(contentsOf: path), let img = NSImage(data: data) {
                return img
            }

            let candidates = await self.candidateAvatarURLs(
                name: authorName,
                email: authorEmail,
                remoteHost: remoteHost,
                remoteOriginURL: remoteOriginURL
            )

            for url in candidates {
                if let rawImg = await self.fetchAndProcessImage(from: url) {
                    let finalImg = self.compressAndDownscale(rawImage: rawImg)
                    if let finalData = finalImg {
                        try? finalData.write(to: path, options: .atomic)
                        self.pruneDiskCacheIfNeeded()
                        return NSImage(data: finalData)
                    }
                    return rawImg
                }
            }

            return nil
        }

        inFlight[key] = task
        defer { inFlight.removeValue(forKey: key) }
        let result = await task.value

        if let result {
            let cost = Int(result.size.width * result.size.height * 4)
            memoryCache.setObject(result, forKey: key as NSString, cost: cost)
        }
        return result
    }

    nonisolated private func parseHost(from remoteOrigin: String?) -> String? {
        guard let remote = remoteOrigin?.trimmingCharacters(in: .whitespacesAndNewlines), !remote.isEmpty else { return nil }
        if let atIdx = remote.firstIndex(of: "@"), let colonIdx = remote.firstIndex(of: ":"), atIdx < colonIdx {
            let hostPart = String(remote[remote.index(after: atIdx)..<colonIdx])
            if !hostPart.isEmpty { return hostPart.lowercased() }
        }
        if let url = URL(string: remote), let host = url.host {
            return host.lowercased()
        }
        return nil
    }

    nonisolated private func candidateAvatarURLs(
        name: String,
        email: String,
        remoteHost: RemoteHostType,
        remoteOriginURL: String?
    ) async -> [URL] {
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedHost = parseHost(from: remoteOriginURL)
        let host = parsedHost ?? (remoteHost == .gitlab ? "gitlab.com" : (remoteHost == .github ? "github.com" : nil))

        var candidates: [URL] = []

        let isGitLab = remoteHost == .gitlab || (host?.contains("gitlab") ?? false)
        let isGitHub = remoteHost == .github || (host?.contains("github") ?? false)
        let isBitbucket = (host?.contains("bitbucket") ?? false)

        if isGitLab {
            let gitlabHost = host ?? "gitlab.com"
            var glUsername: String?
            if cleanEmail.contains("noreply.gitlab.com") || cleanEmail.contains("gitlab") {
                let local = cleanEmail.components(separatedBy: "@").first ?? ""
                let parts = local.components(separatedBy: "-")
                glUsername = parts.count > 1 ? parts.last : local
            } else if !cleanName.isEmpty && !cleanName.contains(" ") {
                glUsername = cleanName
            }

            if let username = glUsername, !username.isEmpty,
               let apiURL = URL(string: "https://\(gitlabHost)/api/v4/users?username=\(username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? username)") {
                if let avatar = await fetchGitLabAvatarFromJSON(apiURL: apiURL) {
                    candidates.append(avatar)
                }
            }

            if !cleanEmail.isEmpty,
               let apiURL = URL(string: "https://\(gitlabHost)/api/v4/avatar?email=\(cleanEmail.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cleanEmail)&size=96") {
                if let avatar = await fetchGitLabAvatarFromJSON(apiURL: apiURL) {
                    candidates.append(avatar)
                }
            }

            if !cleanEmail.isEmpty {
                if let url = URL(string: "https://secure.gravatar.com/avatar/\(cleanEmail.md5Hash)?s=96&d=404") {
                    candidates.append(url)
                }
                if let url = URL(string: "https://seccdn.libravatar.org/avatar/\(cleanEmail.md5Hash)?s=96&d=404") {
                    candidates.append(url)
                }
            }
        } else if isGitHub {
            if cleanEmail.contains("noreply.github.com") {
                let local = cleanEmail.components(separatedBy: "@").first ?? ""
                let username = local.components(separatedBy: "+").last ?? local
                if !username.isEmpty, let url = URL(string: "https://github.com/\(username).png?size=96") {
                    candidates.append(url)
                }
            }
            if !cleanName.isEmpty && !cleanName.contains(" "),
               let url = URL(string: "https://github.com/\(cleanName).png?size=96") {
                candidates.append(url)
            }
            if !cleanEmail.isEmpty {
                if let url = URL(string: "https://www.gravatar.com/avatar/\(cleanEmail.md5Hash)?s=96&d=404") {
                    candidates.append(url)
                }
                if let url = URL(string: "https://seccdn.libravatar.org/avatar/\(cleanEmail.md5Hash)?s=96&d=404") {
                    candidates.append(url)
                }
            }
        } else if isBitbucket {
            if !cleanName.isEmpty && !cleanName.contains(" "),
               let url = URL(string: "https://bitbucket.org/account/\(cleanName)/avatar/96/") {
                candidates.append(url)
            }
            if !cleanEmail.isEmpty {
                if let url = URL(string: "https://www.gravatar.com/avatar/\(cleanEmail.md5Hash)?s=96&d=404") {
                    candidates.append(url)
                }
            }
        } else {
            // Self-hosted, Codeberg, Gitea, or generic git repo
            if let host, !host.isEmpty, !cleanEmail.isEmpty {
                if let url = URL(string: "https://\(host)/avatar/\(cleanEmail.md5Hash)?size=96") {
                    candidates.append(url)
                }
            }
            if !cleanEmail.isEmpty {
                if let url = URL(string: "https://www.gravatar.com/avatar/\(cleanEmail.md5Hash)?s=96&d=404") {
                    candidates.append(url)
                }
                if let url = URL(string: "https://seccdn.libravatar.org/avatar/\(cleanEmail.md5Hash)?s=96&d=404") {
                    candidates.append(url)
                }
            }
            if !cleanName.isEmpty && !cleanName.contains(" ") && cleanEmail.contains("github"),
               let url = URL(string: "https://github.com/\(cleanName).png?size=96") {
                candidates.append(url)
            }
        }

        return candidates
    }

    nonisolated private func fetchGitLabAvatarFromJSON(apiURL: URL) async -> URL? {
        var req = URLRequest(url: apiURL)
        req.timeoutInterval = 3
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }
        if let jsonDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let avatarStr = jsonDict["avatar_url"] as? String,
           let url = URL(string: avatarStr) {
            return url
        }
        if let jsonArr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           let first = jsonArr.first,
           let avatarStr = first["avatar_url"] as? String,
           let url = URL(string: avatarStr) {
            return url
        }
        return nil
    }

    nonisolated private func fetchAndProcessImage(from url: URL) async -> NSImage? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              http.statusCode == 200,
              let mime = http.mimeType?.lowercased(),
              mime.hasPrefix("image/"),
              let img = NSImage(data: data) else {
            return nil
        }
        return img
    }

    nonisolated private func fileURL(for url: URL) -> URL {
        fileURL(for: url.absoluteString)
    }

    nonisolated private func fileURL(for key: String) -> URL {
        let hash = Insecure.MD5.hash(data: Data(key.utf8)).map { String(format: "%02hhx", $0) }.joined()
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
