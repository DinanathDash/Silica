import SwiftUI

/// History tab in Source Control displaying the visual git timeline, compact commit messages, and commit details popover.
struct SourceControlHistoryView: View {
    @Bindable var model: SourceControlModel

    @State private var activePopoverCommitID: String?
    @State private var isMouseInsidePopover = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var dismissTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.commits.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text("No commit history")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ForEach(model.commits) { commit in
                    commitTimelineRow(commit: commit)
                }
            }
        }
        .onDisappear {
            hoverTask?.cancel()
            dismissTask?.cancel()
            activePopoverCommitID = nil
        }
    }

    private func commitTimelineRow(commit: GitCommitItem) -> some View {
        let isCurrentPopover = activePopoverCommitID == commit.id
        // Dynamic row width: sizes tightly to the maximum active lane in this specific row, eliminating dead space
        let rowCanvasWidth = CGFloat(commit.timelineNode.rowMaxLane + 1) * 11 + 4

        return HStack(spacing: 5) {
            // Visual Git timeline graph with natural Bézier physics
            GitTimelineCanvas(
                node: commit.timelineNode,
                isMerge: commit.isMerge
            )
            .frame(width: rowCanvasWidth, height: 26)

            // Commit summary with trailing dots for long messages
            Text(commit.summary)
                .font(.system(size: 11, weight: .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(Color.primary.opacity(isCurrentPopover ? 1.0 : 0.88))

            Spacer(minLength: 4)

            // Compact relative date
            Text(commit.compactRelativeDate)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 4)
        .frame(height: 26)
        .contentShape(Rectangle())
        .background {
            if isCurrentPopover {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
            }
        }
        .onHover { isHovering in
            if isHovering {
                dismissTask?.cancel()
                hoverTask?.cancel()
                hoverTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 160_000_000)
                    guard !Task.isCancelled else { return }
                    activePopoverCommitID = commit.id
                }
            } else {
                hoverTask?.cancel()
                dismissTask?.cancel()
                dismissTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 260_000_000)
                    guard !Task.isCancelled else { return }
                    if !isMouseInsidePopover && activePopoverCommitID == commit.id {
                        activePopoverCommitID = nil
                    }
                }
            }
        }
        .onTapGesture {
            dismissTask?.cancel()
            hoverTask?.cancel()
            activePopoverCommitID = commit.id
        }
        .popover(
            isPresented: Binding(
                get: { activePopoverCommitID == commit.id },
                set: { isPresent in
                    if !isPresent && activePopoverCommitID == commit.id {
                        activePopoverCommitID = nil
                    }
                }
            ),
            arrowEdge: .leading
        ) {
            CommitDetailsPopoverView(
                commit: commit,
                remoteHost: model.remoteHostType,
                onHoverChange: { isInside in
                    isMouseInsidePopover = isInside
                    if !isInside {
                        dismissTask?.cancel()
                        dismissTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            guard !Task.isCancelled else { return }
                            if activePopoverCommitID == commit.id {
                                activePopoverCommitID = nil
                            }
                        }
                    } else {
                        dismissTask?.cancel()
                    }
                }
            )
        }
    }
}

// MARK: - Git Timeline Components

enum GitTimelineColors {
    static let palette: [Color] = [
        Color(nsColor: .systemBlue),
        Color(nsColor: .systemPurple),
        Color(nsColor: .systemOrange),
        Color(nsColor: .systemTeal),
        Color(nsColor: .systemIndigo),
        Color(nsColor: .systemPink),
        Color(nsColor: .systemGreen)
    ]

    static func color(for lane: Int) -> Color {
        palette[abs(lane) % palette.count]
    }
}

/// Renders visual git graph branches, merges, and commit nodes with smooth Bézier curves and round caps.
struct GitTimelineCanvas: View {
    let node: GitTimelineNode
    let isMerge: Bool

    private func laneX(_ lane: Int) -> CGFloat {
        CGFloat(lane) * 11 + 6
    }

    var body: some View {
        Canvas { context, size in
            let rowHeight: CGFloat = size.height
            let centerY: CGFloat = rowHeight / 2.0
            let nodeX = laneX(node.lane)
            let strokeStyle = StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round)

            // 1. Draw passing lines
            for passingLane in node.passingLanes {
                let px = laneX(passingLane)
                var path = Path()
                path.move(to: CGPoint(x: px, y: 0))
                path.addLine(to: CGPoint(x: px, y: rowHeight))
                context.stroke(path, with: .color(GitTimelineColors.color(for: passingLane)), style: strokeStyle)
            }

            // 2. Draw incoming line to node
            if node.hasIncoming {
                var path = Path()
                path.move(to: CGPoint(x: nodeX, y: 0))
                path.addLine(to: CGPoint(x: nodeX, y: centerY))
                context.stroke(path, with: .color(GitTimelineColors.color(for: node.lane)), style: strokeStyle)
            }

            // 3. Draw outgoing connections (straight tracks and smooth sigmoid curves)
            for conn in node.outgoingConnections {
                let fromX = laneX(conn.fromLane)
                let toX = laneX(conn.toLane)
                var path = Path()
                path.move(to: CGPoint(x: fromX, y: centerY))

                if conn.fromLane == conn.toLane {
                    path.addLine(to: CGPoint(x: toX, y: rowHeight))
                } else {
                    let dy = rowHeight - centerY
                    // Smooth S-curve sigmoid transition with vertical tangents at both endpoints
                    path.addCurve(
                        to: CGPoint(x: toX, y: rowHeight),
                        control1: CGPoint(x: fromX, y: centerY + dy * 0.55),
                        control2: CGPoint(x: toX, y: rowHeight - dy * 0.45)
                    )
                }
                context.stroke(path, with: .color(GitTimelineColors.color(for: conn.toLane)), style: strokeStyle)
            }

            // 4. Draw commit node
            let nodeColor = GitTimelineColors.color(for: node.lane)
            let center = CGPoint(x: nodeX, y: centerY)

            if isMerge {
                // Merge commit node: stylish hollow ring with inner core
                let outerRect = CGRect(x: center.x - 4.25, y: center.y - 4.25, width: 8.5, height: 8.5)
                context.fill(Path(ellipseIn: outerRect.insetBy(dx: -1.0, dy: -1.0)), with: .color(Color(nsColor: .windowBackgroundColor)))
                context.stroke(Path(ellipseIn: outerRect), with: .color(nodeColor), lineWidth: 1.75)
                let innerRect = CGRect(x: center.x - 1.75, y: center.y - 1.75, width: 3.5, height: 3.5)
                context.fill(Path(ellipseIn: innerRect), with: .color(nodeColor))
            } else {
                // Normal commit node: solid dot with clear background knockout halo
                let haloRect = CGRect(x: center.x - 4.25, y: center.y - 4.25, width: 8.5, height: 8.5)
                context.stroke(Path(ellipseIn: haloRect), with: .color(Color(nsColor: .windowBackgroundColor)), lineWidth: 1.5)
                let dotRect = CGRect(x: center.x - 3.0, y: center.y - 3.0, width: 6.0, height: 6.0)
                context.fill(Path(ellipseIn: dotRect), with: .color(nodeColor))
            }
        }
    }
}

// MARK: - Caching & Avatar Service

/// In-memory and disk-backed image cache to prevent duplicate network calls and memory leaks.
@MainActor
final class AvatarImageCache {
    static let shared = AvatarImageCache()

    private let cache = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    private init() {
        cache.countLimit = 150
        cache.totalCostLimit = 30 * 1024 * 1024 // 30MB max memory footprint
    }

    func image(for url: URL) async -> NSImage? {
        let key = url.absoluteString as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        if let existing = inFlight[url.absoluteString] {
            return await existing.value
        }

        let task = Task<NSImage?, Never>.detached(priority: .userInitiated) {
            var request = URLRequest(url: url)
            request.timeoutInterval = 4
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let image = NSImage(data: data) else {
                return nil
            }
            return image
        }

        inFlight[url.absoluteString] = task
        let result = await task.value
        inFlight.removeValue(forKey: url.absoluteString)

        if let result {
            let cost = Int(result.size.width * result.size.height * 4)
            cache.setObject(result, forKey: key, cost: cost)
        }
        return result
    }
}

/// Displays author profile picture according to repository remote origin (GitHub vs GitLab) with fallback badge.
struct CommitAuthorAvatarView: View {
    let authorName: String
    let authorEmail: String
    let remoteHost: RemoteHostType

    @State private var loadedImage: NSImage?

    private var avatarURL: URL? {
        let cleanEmail = authorEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanName = authorName.trimmingCharacters(in: .whitespacesAndNewlines)

        switch remoteHost {
        case .github:
            // Noreply GitHub emails: e.g. 12345+username@users.noreply.github.com
            if cleanEmail.contains("noreply.github.com") {
                let local = cleanEmail.components(separatedBy: "@").first ?? ""
                let username = local.components(separatedBy: "+").last ?? local
                if !username.isEmpty {
                    return URL(string: "https://github.com/\(username).png?size=96")
                }
            }
            // If authorName is single word, query GitHub directly
            if !cleanName.isEmpty && !cleanName.contains(" ") {
                return URL(string: "https://github.com/\(cleanName).png?size=96")
            }
            // Gravatar with 404 fallback so initials badge triggers if no match
            return URL(string: "https://www.gravatar.com/avatar/\(cleanEmail.md5Hash)?s=96&d=404")

        case .gitlab:
            // GitLab remote origin: load from GitLab or GitLab's Gravatar service
            if !cleanName.isEmpty && !cleanName.contains(" ") {
                return URL(string: "https://gitlab.com/\(cleanName).png")
            }
            return URL(string: "https://secure.gravatar.com/avatar/\(cleanEmail.md5Hash)?s=96&d=identicon")

        case .unknown:
            if !cleanName.isEmpty && !cleanName.contains(" ") {
                return URL(string: "https://github.com/\(cleanName).png?size=96")
            }
            return URL(string: "https://www.gravatar.com/avatar/\(cleanEmail.md5Hash)?s=96&d=identicon")
        }
    }

    private var initials: String {
        let trimmed = authorName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "?" }
        let parts = trimmed.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
        if parts.count >= 2, let f = parts.first?.first, let l = parts.last?.first {
            return "\(f)\(l)".uppercased()
        }
        let uppers = trimmed.filter { $0.isUppercase }
        if uppers.count >= 2 {
            return String(uppers.prefix(2))
        }
        return String(trimmed.prefix(1)).uppercased()
    }

    private var fallbackColor: Color {
        let hash = abs(authorName.hashValue ^ authorEmail.hashValue)
        let colors: [Color] = [.blue, .purple, .orange, .pink, .teal, .indigo, .mint, .cyan]
        return colors[hash % colors.count]
    }

    var body: some View {
        Group {
            if let loadedImage {
                Image(nsImage: loadedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
            } else {
                initialsBadge
            }
        }
        .task(id: avatarURL) {
            guard let url = avatarURL else { return }
            loadedImage = await AvatarImageCache.shared.image(for: url)
        }
    }

    private var initialsBadge: some View {
        Circle()
            .fill(fallbackColor.gradient)
            .overlay {
                Text(initials)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
            .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 0.5))
    }
}

/// Popover card displaying commit title, description, diff stats, author with dp, and copyable hash.
struct CommitDetailsPopoverView: View {
    let commit: GitCommitItem
    let remoteHost: RemoteHostType
    var onHoverChange: (Bool) -> Void

    @State private var hasCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 1. Author and Date Header
            HStack(spacing: 9) {
                CommitAuthorAvatarView(
                    authorName: commit.authorName,
                    authorEmail: commit.authorEmail,
                    remoteHost: remoteHost
                )
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(commit.authorName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if !commit.authorEmail.isEmpty {
                        Text(commit.authorEmail)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Text(commit.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }

            Divider()

            // 2. Commit Title and Description
            VStack(alignment: .leading, spacing: 4) {
                Text(commit.summary)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if !commit.body.isEmpty {
                    ScrollView(.vertical) {
                        Text(commit.body)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxHeight: 100)
                }
            }

            Divider()

            // 3. Diff statistics: files changed, additions, deletions
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text("\(commit.filesChanged) \(commit.filesChanged == 1 ? "file" : "files") changed")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if commit.additions > 0 || commit.deletions > 0 {
                    HStack(spacing: 5) {
                        if commit.additions > 0 {
                            Text("+\(commit.additions)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.green)
                        }
                        if commit.deletions > 0 {
                            Text("-\(commit.deletions)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45))
            }

            Divider()

            // 4. Commit hash and copy button
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "number")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(commit.shortHash)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                }
                .help(commit.hash)

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(commit.hash, forType: .string)
                    hasCopied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        hasCopied = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: hasCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9))
                        Text(hasCopied ? "Copied" : "Copy Hash")
                            .font(.system(size: 10, weight: .medium))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .frame(width: 270)
        .onHover { isInside in
            onHoverChange(isInside)
        }
    }
}
