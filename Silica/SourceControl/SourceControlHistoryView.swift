import SwiftUI

/// History tab in Source Control displaying the visual git timeline, search filter, paging, and commit details popover.
struct SourceControlHistoryView: View {
    let workspace: WorkspaceModel
    @Bindable var model: SourceControlModel

    private var settings: EditorSettings { .shared }

    @State private var searchQuery = ""
    @State private var activePopoverCommitID: String?
    @State private var isMouseInsidePopover = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var dismissTask: Task<Void, Never>?
    @State private var expandedCommitID: String?
    @State private var commitFilesCache: [String: [CommitChangedFile]] = [:]
    @State private var loadingCommitHashes: Set<String> = []
    @State private var hoveredFileID: String?
    @State private var isShowingCreateBranchSheet = false
    @State private var branchCommitTarget: GitCommitItem?
    @State private var newBranchName = ""

    private var filteredCommits: [GitCommitItem] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return model.commits }
        return model.commits.filter { commit in
            commit.summary.localizedCaseInsensitiveContains(query) ||
            commit.body.localizedCaseInsensitiveContains(query) ||
            commit.authorName.localizedCaseInsensitiveContains(query) ||
            commit.authorEmail.localizedCaseInsensitiveContains(query) ||
            commit.shortHash.localizedCaseInsensitiveContains(query) ||
            commit.hash.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Search Input & Branch Selector
            HStack(spacing: 6) {
                searchBar

                Menu {
                    Button("All Branches (Graph)") {
                        Task { await model.setHistoryBranch(nil) }
                    }
                    Divider()
                    Button("Current (\(model.branchName ?? "HEAD"))") {
                        Task { await model.setHistoryBranch(model.branchName ?? "HEAD") }
                    }
                    if !model.branches.isEmpty {
                        Divider()
                        ForEach(model.branches) { branch in
                            if branch.name != (model.branchName ?? "HEAD") {
                                Button(branch.name) {
                                    Task { await model.setHistoryBranch(branch.name) }
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(model.historyBranch ?? "All Branches")
                            .font(.system(size: settings.sidebarFontSize))
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 32)
                    .frame(maxWidth: 145)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                            )
                    }
                }
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .liquidGlassTooltip("Select branch to inspect history")
            }
            .padding(.bottom, 2)

            if model.hasExtraCommits {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text("Showing \(model.commits.count) commits")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            model.pruneExtraCommits()
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 9))
                            Text("Close Extra")
                                .font(.system(size: 10, weight: .medium))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .liquidGlassTooltip("Free up extra older commits and return to latest 50")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }

            if model.commits.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text("No commit history")
                        .font(.system(size: settings.sidebarFontSize))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else if filteredCommits.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                    Text("No commits matching \"\(searchQuery)\"")
                        .font(.system(size: settings.sidebarFontSize, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                // Continuous Git Timeline Rows using LazyVStack for memory efficiency
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredCommits) { commit in
                        VStack(alignment: .leading, spacing: 0) {
                            commitTimelineRow(commit: commit)
                            if expandedCommitID == commit.id {
                                commitFilesList(commit: commit)
                            }
                        }
                        .onAppear {
                            if commit.id == filteredCommits.first?.id && model.hasExtraCommits {
                                model.scheduleAutoPrune(seconds: 30)
                            }
                        }
                    }
                }

                // Paging button: loads older commits or closes extra commits
                if searchQuery.isEmpty && (model.hasMoreCommits || model.hasExtraCommits) {
                    HStack(spacing: 8) {
                        if model.hasMoreCommits {
                            Button {
                                Task { await model.loadMoreCommits() }
                            } label: {
                                HStack(spacing: 6) {
                                    if model.isLoadingMoreCommits {
                                        ProgressView()
                                            .controlSize(.mini)
                                    } else {
                                        Image(systemName: "arrow.down.circle")
                                            .font(.system(size: 11))
                                    }
                                    Text(model.isLoadingMoreCommits ? "Loading older commits…" : "Load Older Commits")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                            }
                            .glassButtonStyle()
                            .controlSize(.small)
                        }

                        if model.hasExtraCommits {
                            Button {
                                withAnimation(.snappy(duration: 0.2)) {
                                    model.pruneExtraCommits()
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.up.to.line.compact")
                                        .font(.system(size: 10))
                                    Text("Close Extra")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .frame(maxWidth: model.hasMoreCommits ? nil : .infinity)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                            }
                            .glassButtonStyle()
                            .controlSize(.small)
                            .liquidGlassTooltip("Free up extra older commits and return to latest 50")
                        }
                    }
                    .padding(.top, 6)
                    .padding(.bottom, 12)
                }
            }
        }
        .onDisappear {
            hoverTask?.cancel()
            dismissTask?.cancel()
            activePopoverCommitID = nil
            model.pruneExtraCommits()
        }
        .onChange(of: model.commits.count) { _, _ in
            if let expanded = expandedCommitID, !model.commits.contains(where: { $0.id == expanded }) {
                expandedCommitID = nil
            }
            if let popover = activePopoverCommitID, !model.commits.contains(where: { $0.id == popover }) {
                activePopoverCommitID = nil
            }
        }
        .onChange(of: expandedCommitID) { _, newExpanded in
            if let newExpanded,
               let index = model.commits.firstIndex(where: { $0.id == newExpanded }),
               index >= model.initialCommitLimit {
                model.isInspectingOlderCommit = true
            } else {
                model.isInspectingOlderCommit = false
            }
        }
        .alert("Create Branch", isPresented: $isShowingCreateBranchSheet) {
            TextField("Branch name", text: $newBranchName)
            Button("Create") {
                let name = newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty, let target = branchCommitTarget {
                    Task {
                        _ = await model.createBranch(name: name, from: target.hash)
                    }
                }
                newBranchName = ""
                branchCommitTarget = nil
            }
            Button("Cancel", role: .cancel) {
                newBranchName = ""
                branchCommitTarget = nil
            }
        } message: {
            if let target = branchCommitTarget {
                Text("Create and switch to a new branch starting from commit \(target.shortHash) (“\(target.summary)”).")
            }
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: max(settings.sidebarFontSize - 1, 10)))
                .foregroundStyle(.secondary)

            TextField("Search history by message, author, hash…", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: settings.sidebarFontSize))

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: max(settings.sidebarFontSize - 1, 10)))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .liquidGlassTooltip("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                )
        }
    }

    // MARK: - Timeline Row

    private func timelineGutterWidth(for commit: GitCommitItem) -> CGFloat {
        let node = commit.timelineNode
        var lanes = [node.lane]
        lanes.append(contentsOf: node.passingLanes)
        lanes.append(contentsOf: node.incomingMergeLanes)
        lanes.append(contentsOf: node.outgoingConnections.map(\.toLane))
        lanes.append(contentsOf: node.outgoingConnections.map(\.fromLane))
        let maxRowLane = max(0, lanes.max() ?? node.lane)
        return CGFloat(maxRowLane + 1) * 14 + 8
    }

    private func commitTimelineRow(commit: GitCommitItem) -> some View {
        let isCurrentPopover = activePopoverCommitID == commit.id
        let rowHeight = max(24, settings.sidebarFontSize + 13)
        let gutterWidth = timelineGutterWidth(for: commit)

        return HStack(spacing: 5) {
            // Visual Git timeline graph with dynamic width as per the row's branches and graph lines
            GitTimelineCanvas(
                node: commit.timelineNode,
                isMerge: commit.isMerge,
                isUnpushed: commit.isUnpushed,
                isHead: commit.isHead
            )
            .frame(width: gutterWidth, height: rowHeight)

            // Commit summary with trailing dots for long messages
            Text(commit.summary)
                .font(.system(size: settings.sidebarFontSize, weight: .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(Color.primary.opacity(isCurrentPopover ? 1.0 : 0.88))

            if commit.isUnpushed {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 8, weight: .bold))
                    Text("Unpushed")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(Color.orange)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.orange.opacity(0.12), in: Capsule())
                .liquidGlassTooltip("Local commit not yet pushed to remote")
            }

            Spacer(minLength: 4)

            // Compact relative date
            Text(commit.compactRelativeDate)
                .font(.system(size: max(settings.sidebarFontSize - 1.5, 9)))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 4)
        .frame(height: rowHeight)
        .contentShape(Rectangle())
        .background {
            if isCurrentPopover || expandedCommitID == commit.id {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.accentColor.opacity(expandedCommitID == commit.id ? 0.16 : 0.12))
            }
        }
        .onHover { isHovering in
            if isHovering {
                dismissTask?.cancel()
                hoverTask?.cancel()
                hoverTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 160_000_000)
                    guard !Task.isCancelled else { return }
                    if expandedCommitID != commit.id {
                        activePopoverCommitID = commit.id
                    }
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
            activePopoverCommitID = nil
            withAnimation(.snappy(duration: 0.18)) {
                if expandedCommitID == commit.id {
                    expandedCommitID = nil
                } else {
                    expandedCommitID = commit.id
                }
            }
            if expandedCommitID == commit.id && commitFilesCache[commit.hash] == nil {
                loadingCommitHashes.insert(commit.hash)
                Task {
                    let files = await model.loadChangedFiles(for: commit.hash)
                    if commitFilesCache.count > 50 {
                        commitFilesCache.removeValue(forKey: commitFilesCache.keys.first!)
                    }
                    commitFilesCache[commit.hash] = files
                    loadingCommitHashes.remove(commit.hash)
                }
            }
        }
        .popover(
            isPresented: Binding(
                get: { activePopoverCommitID == commit.id && expandedCommitID != commit.id },
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
                remoteOriginURL: model.remoteOriginURL,
                commitWebURL: model.commitWebURL(for: commit.hash),
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
        .contextMenu {
            Button("View Full Diff") {
                workspace.openFullCommitDiff(commitHash: commit.hash, commitTitle: commit.summary)
            }

            Divider()

            Button("New Branch from this Commit…") {
                branchCommitTarget = commit
                newBranchName = ""
                isShowingCreateBranchSheet = true
            }

            Button("Checkout Commit (\(commit.shortHash))") {
                Task { await model.checkoutCommit(commit.hash) }
            }

            Button("Cherry-pick Commit") {
                Task { await model.cherryPick(commitHash: commit.hash) }
            }

            if model.isDetachedHead {
                Divider()
                Button("Return to Latest Commit (\(model.lastKnownBranch))") {
                    Task { _ = await model.returnToLatestBranch() }
                }
            }

            Divider()

            Button("Copy SHA (\(commit.shortHash))") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commit.hash, forType: .string)
            }

            Button("Copy Commit Message") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commit.summary, forType: .string)
            }
        }
    }

    // MARK: - Changed Files List

    private func continuingLanes(for commit: GitCommitItem) -> Set<Int> {
        var lanes = Set(commit.timelineNode.passingLanes)
        for conn in commit.timelineNode.outgoingConnections {
            lanes.insert(conn.toLane)
        }
        if lanes.isEmpty {
            lanes.insert(commit.timelineNode.lane)
        }
        return lanes
    }

    private func commitFilesList(commit: GitCommitItem) -> some View {
        let activeLanes = continuingLanes(for: commit)
        let rowCanvasWidth = timelineGutterWidth(for: commit)
        let fileRowHeight = max(22, settings.sidebarFontSize + 9)

        return VStack(alignment: .leading, spacing: 0) {
            if loadingCommitHashes.contains(commit.hash) {
                HStack(spacing: 5) {
                    TimelineContinuationTrack(lanes: activeLanes, width: rowCanvasWidth)
                        .frame(width: rowCanvasWidth, height: fileRowHeight)
                    ProgressView()
                        .controlSize(.mini)
                    Text("Loading changed files…")
                        .font(.system(size: max(settings.sidebarFontSize - 2, 9)))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 4)
                .frame(height: fileRowHeight)
            } else if let files = commitFilesCache[commit.hash] {
                if files.isEmpty {
                    HStack(spacing: 5) {
                        TimelineContinuationTrack(lanes: activeLanes, width: rowCanvasWidth)
                            .frame(width: rowCanvasWidth, height: fileRowHeight)
                        Text("No files changed in this commit")
                            .font(.system(size: max(settings.sidebarFontSize - 2, 9)))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 4)
                    .frame(height: fileRowHeight)
                } else {
                    ForEach(files) { file in
                        commitFileRow(
                            file: file,
                            commit: commit,
                            activeLanes: activeLanes,
                            rowCanvasWidth: rowCanvasWidth,
                            fileRowHeight: fileRowHeight
                        )
                    }
                }
            }
        }
    }

    private func commitFileRow(
        file: CommitChangedFile,
        commit: GitCommitItem,
        activeLanes: Set<Int>,
        rowCanvasWidth: CGFloat,
        fileRowHeight: CGFloat
    ) -> some View {
        let fileURL = workspace.rootURL.appending(path: file.relativePath)
        let isHovered = hoveredFileID == (commit.id + file.id)

        return HStack(spacing: 5) {
            // Unbroken timeline track continues through every file row at top z-axis
            TimelineContinuationTrack(lanes: activeLanes, width: rowCanvasWidth)
                .frame(width: rowCanvasWidth, height: fileRowHeight)

            // Extreme left: Git badge (M, A, D, etc.)
            let badgeTooltip: String = {
                if let old = file.originalPath, file.status == .renamed {
                    return "Renamed from \(old)"
                }
                return file.status.label
            }()
            Text(file.status.badgeLetter)
                .font(.system(size: max(settings.sidebarFontSize - 2, 8), weight: .bold, design: .monospaced))
                .foregroundStyle(file.status.badgeColor)
                .frame(width: 14)
                .liquidGlassTooltip(badgeTooltip)

            // File icon
            FileIcon(url: fileURL, width: settings.sidebarIconWidth)

            // File name
            Text(file.fileName)
                .font(.system(size: settings.sidebarFontSize))
                .foregroundStyle(.primary)
                .lineLimit(1)

            if let old = file.originalPath, file.status == .renamed {
                let oldName = old.split(separator: "/").last.map(String.init) ?? old
                Text("(from \(oldName))")
                    .font(.system(size: max(settings.sidebarFontSize - 2.5, 8)))
                    .foregroundStyle(.secondary.opacity(0.8))
                    .lineLimit(1)
            } else if !file.directoryPath.isEmpty {
                Text(file.directoryPath)
                    .font(.system(size: max(settings.sidebarFontSize - 2, 8)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            // Extreme right: Addition/deletion stats (+X -Y)
            if file.additions > 0 || file.deletions > 0 {
                HStack(spacing: 2) {
                    if file.additions > 0 {
                        Text("+\(file.additions)").foregroundStyle(.green)
                    }
                    if file.deletions > 0 {
                        Text("-\(file.deletions)").foregroundStyle(.red)
                    }
                }
                .font(.system(size: max(settings.sidebarFontSize - 2, 8), weight: .semibold, design: .monospaced))
            }
        }
        .padding(.horizontal, 4)
        .frame(height: fileRowHeight)
        .contentShape(Rectangle())
        .background {
            if isHovered {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            }
        }
        .onHover { isHovering in
            hoveredFileID = isHovering ? (commit.id + file.id) : nil
        }
        .onTapGesture {
            workspace.openCommitDiff(
                commitHash: commit.hash,
                commitTitle: commit.summary,
                relativePath: file.relativePath
            )
        }
    }
}

// MARK: - Git Ref Badge

/// Branch, HEAD, or tag badge displayed in commit detail popover.
struct GitRefBadgeView: View {
    let ref: GitRefDecoration

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .font(.system(size: 9.5, weight: .bold))
            Text(ref.displayName)
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(badgeColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 4.5, style: .continuous))
        .foregroundStyle(badgeColor)
        .overlay(
            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                .stroke(badgeColor.opacity(0.3), lineWidth: 0.5)
        )
        .liquidGlassTooltip(tooltipText)
    }

    private var iconName: String {
        switch ref.type {
        case .head: return "arrow.triangle.branch"
        case .detachedHead: return "circle.circle"
        case .localBranch: return "arrow.triangle.branch"
        case .remoteBranch: return "cloud"
        case .tag: return "tag.fill"
        }
    }

    private var badgeColor: Color {
        switch ref.type {
        case .head: return .green
        case .detachedHead: return .yellow
        case .localBranch: return Color(red: 0.35, green: 0.60, blue: 0.98)
        case .remoteBranch: return Color(red: 0.65, green: 0.45, blue: 0.95)
        case .tag: return Color(red: 0.95, green: 0.65, blue: 0.15)
        }
    }

    private var tooltipText: String {
        switch ref.type {
        case .head(let b): return "HEAD -> \(b)"
        case .detachedHead: return "HEAD (detached)"
        case .localBranch(let b): return "Branch: \(b)"
        case .remoteBranch(let b): return "Remote tracking: \(b)"
        case .tag(let t): return "Tag: \(t)"
        }
    }
}

/// Continuous vertical timeline track running through expanded commit file rows so the line never breaks.
struct TimelineContinuationTrack: View {
    let lanes: Set<Int>
    let width: CGFloat

    private func laneX(_ lane: Int) -> CGFloat {
        CGFloat(lane) * 14 + 10
    }

    var body: some View {
        Canvas { context, size in
            let rowHeight = size.height
            let solidStyle = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)

            for lane in lanes.sorted() {
                let x = laneX(lane)
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: rowHeight))
                context.stroke(path, with: .color(GitTimelineColors.color(for: lane)), style: solidStyle)
            }
        }
        .frame(width: width)
    }
}

// MARK: - Git Timeline Components

enum GitTimelineColors {
    // High-contrast timeline palette matching VS Code & modern Git graphs:
    static let palette: [Color] = [
        Color(red: 0.22, green: 0.58, blue: 0.98), // Lane 0: Dodger Blue (VS Code primary trunk)
        Color(red: 0.88, green: 0.24, blue: 0.56), // Lane 1: Hot Magenta / Pink
        Color(red: 0.96, green: 0.60, blue: 0.14), // Lane 2: Warm Amber / Gold
        Color(red: 0.12, green: 0.74, blue: 0.68), // Lane 3: Vibrant Teal / Cyan
        Color(red: 0.62, green: 0.40, blue: 0.92), // Lane 4: Purple / Violet
        Color(red: 0.24, green: 0.75, blue: 0.42), // Lane 5: Mint Green
        Color(red: 0.94, green: 0.35, blue: 0.35), // Lane 6: Crimson / Coral
        Color(red: 0.95, green: 0.75, blue: 0.20)  // Lane 7: Sunflower Yellow
    ]

    static func color(for lane: Int) -> Color {
        palette[abs(lane) % palette.count]
    }
}

/// Renders visual git graph branches, merges, and commit nodes matching VS Code's Source Control history graph.
struct GitTimelineCanvas: View {
    let node: GitTimelineNode
    let isMerge: Bool
    var isUnpushed: Bool = false
    var isHead: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    private var settings: EditorSettings { .shared }

    private func laneX(_ lane: Int) -> CGFloat {
        CGFloat(lane) * 14 + 10
    }

    var body: some View {
        Canvas { context, size in
            let isDark = switch settings.appearance {
            case .dark: true
            case .light: false
            case .system: colorScheme == .dark
            }
            let knockoutColor: Color = (settings.windowBackground == .opaque && isDark)
                ? Color(red: 0.095, green: 0.095, blue: 0.108)
                : Color(nsColor: .windowBackgroundColor)

            let rowHeight: CGFloat = size.height
            let centerY: CGFloat = rowHeight / 2.0
            let nodeX = laneX(node.lane)
            let solidStyle = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)

            // 1. Draw passing lines (continuous vertical tracks for active parallel branches)
            for passingLane in node.passingLanes {
                let px = laneX(passingLane)
                var path = Path()
                path.move(to: CGPoint(x: px, y: 0))
                path.addLine(to: CGPoint(x: px, y: rowHeight))
                context.stroke(path, with: .color(GitTimelineColors.color(for: passingLane)), style: solidStyle)
            }

            // 2. Incoming merge curves (branches joining into this node from top)
            for mergeLane in node.incomingMergeLanes {
                let fromX = laneX(mergeLane)
                var path = Path()
                path.move(to: CGPoint(x: fromX, y: 0))
                path.addCurve(
                    to: CGPoint(x: nodeX, y: centerY),
                    control1: CGPoint(x: fromX, y: centerY * 0.55),
                    control2: CGPoint(x: nodeX, y: centerY * 0.45)
                )
                context.stroke(path, with: .color(GitTimelineColors.color(for: mergeLane)), style: solidStyle)
            }

            // 3. Draw direct incoming line to node (solid vertical line from top of row to node center)
            if node.hasIncoming {
                var path = Path()
                path.move(to: CGPoint(x: nodeX, y: 0))
                path.addLine(to: CGPoint(x: nodeX, y: centerY))
                let lineColor = isUnpushed ? Color.orange : GitTimelineColors.color(for: node.lane)
                context.stroke(path, with: .color(lineColor), style: solidStyle)
            }

            // 4. Draw outgoing connections downward
            for conn in node.outgoingConnections {
                let fromX = laneX(conn.fromLane)
                let toX = laneX(conn.toLane)
                let connColor = GitTimelineColors.color(for: conn.colorLane)
                var path = Path()
                path.move(to: CGPoint(x: fromX, y: centerY))

                if conn.fromLane == conn.toLane {
                    // Straight track downward to parent
                    path.addLine(to: CGPoint(x: toX, y: rowHeight))
                    let lineColor = isUnpushed ? Color.orange : connColor
                    context.stroke(path, with: .color(lineColor), style: solidStyle)
                } else {
                    let dy = rowHeight - centerY
                    path.addCurve(
                        to: CGPoint(x: toX, y: rowHeight),
                        control1: CGPoint(x: fromX, y: centerY + dy * 0.55),
                        control2: CGPoint(x: toX, y: rowHeight - dy * 0.45)
                    )
                    context.stroke(path, with: .color(connColor), style: solidStyle)
                }
            }

            // 4. Draw commit node matching VS Code's design system
            let nodeColor = isUnpushed ? Color.orange : GitTimelineColors.color(for: node.lane)
            let center = CGPoint(x: nodeX, y: centerY)

            if isHead {
                // HEAD commit node (VS Code concentric target: outer ring + inner dot)
                let outerRect = CGRect(x: center.x - 5.5, y: center.y - 5.5, width: 11, height: 11)
                context.fill(Path(ellipseIn: outerRect.insetBy(dx: -1.0, dy: -1.0)), with: .color(knockoutColor))
                context.stroke(Path(ellipseIn: outerRect), with: .color(nodeColor), lineWidth: 1.5)
                let innerRect = CGRect(x: center.x - 2.25, y: center.y - 2.25, width: 4.5, height: 4.5)
                context.fill(Path(ellipseIn: innerRect), with: .color(nodeColor))
            } else if isMerge {
                // Merge commit node (VS Code concentric double ring)
                let outerRect = CGRect(x: center.x - 5.5, y: center.y - 5.5, width: 11, height: 11)
                context.fill(Path(ellipseIn: outerRect.insetBy(dx: -1.0, dy: -1.0)), with: .color(knockoutColor))
                context.stroke(Path(ellipseIn: outerRect), with: .color(nodeColor), lineWidth: 1.5)
                let innerRect = CGRect(x: center.x - 2.5, y: center.y - 2.5, width: 5.0, height: 5.0)
                context.fill(Path(ellipseIn: innerRect), with: .color(nodeColor))
            } else if isUnpushed {
                // Unpushed commit node (VS Code outgoing changes dashed outer circle + inner dot)
                let outerRing = CGRect(x: center.x - 5.5, y: center.y - 5.5, width: 11, height: 11)
                context.fill(Path(ellipseIn: outerRing.insetBy(dx: -1.0, dy: -1.0)), with: .color(knockoutColor))
                context.stroke(Path(ellipseIn: outerRing), with: .color(Color.orange.opacity(0.9)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                let dotRect = CGRect(x: center.x - 3.25, y: center.y - 3.25, width: 6.5, height: 6.5)
                context.fill(Path(ellipseIn: dotRect), with: .color(Color.orange))
            } else {
                // Normal commit node: solid circular node with clear background knockout halo
                let haloRect = CGRect(x: center.x - 4.75, y: center.y - 4.75, width: 9.5, height: 9.5)
                context.stroke(Path(ellipseIn: haloRect), with: .color(knockoutColor), lineWidth: 1.5)
                let dotRect = CGRect(x: center.x - 3.75, y: center.y - 3.75, width: 7.5, height: 7.5)
                context.fill(Path(ellipseIn: dotRect), with: .color(nodeColor))
            }
        }
    }
}

// MARK: - Avatar View

/// Displays author profile picture according to repository remote origin (GitHub, GitLab, Bitbucket, Gravatar) with fallback badge.
struct CommitAuthorAvatarView: View {
    let authorName: String
    let authorEmail: String
    let remoteHost: RemoteHostType
    var remoteOriginURL: String? = nil

    @State private var loadedImage: NSImage?

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
        .onAppear {
            if let cached = AvatarImageCache.shared.cachedAuthorAvatar(email: authorEmail, name: authorName, remoteHost: remoteHost) {
                self.loadedImage = cached
            }
        }
        .task(id: "\(authorEmail)|\(authorName)|\(remoteHost.rawValue)|\(remoteOriginURL ?? "")") {
            if let cached = AvatarImageCache.shared.cachedAuthorAvatar(email: authorEmail, name: authorName, remoteHost: remoteHost) {
                self.loadedImage = cached
                return
            }
            loadedImage = await AvatarImageCache.shared.resolveAuthorAvatar(
                authorName: authorName,
                authorEmail: authorEmail,
                remoteHost: remoteHost,
                remoteOriginURL: remoteOriginURL
            )
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
    var remoteOriginURL: String? = nil
    var commitWebURL: URL? = nil
    var onHoverChange: (Bool) -> Void

    @State private var hasCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 1. Author and Date Header
            HStack(spacing: 9) {
                CommitAuthorAvatarView(
                    authorName: commit.authorName,
                    authorEmail: commit.authorEmail,
                    remoteHost: remoteHost,
                    remoteOriginURL: remoteOriginURL
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

                if commit.isUnpushed {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 8, weight: .bold))
                        Text("Unpushed")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.12), in: Capsule())
                }
            }

            // Ref badges (branches, tags, HEAD)
            if !commit.refDecorations.isEmpty {
                HStack(spacing: 5) {
                    ForEach(commit.refDecorations) { ref in
                        GitRefBadgeView(ref: ref)
                    }
                }
            }

            // 2. Commit Title and Description with Rich Markdown formatting
            VStack(alignment: .leading, spacing: 4) {
                Text(renderMarkdown(commit.summary))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if !commit.body.isEmpty {
                    ScrollView(.vertical) {
                        Text(renderMarkdown(commit.body))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
            }

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
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45))
            }

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
                .liquidGlassTooltip(commit.hash)

                Spacer()

                Button {
                    if let webURL = commitWebURL {
                        NSWorkspace.shared.open(webURL)
                    } else {
                        KeyWorkspace.shared.current?.openCommitDiff(
                            commitHash: commit.hash,
                            commitTitle: commit.summary,
                            relativePath: ""
                        )
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 9))
                        Text("Open")
                            .font(.system(size: 10, weight: .medium))
                    }
                }
                .glassButtonStyle()
                .controlSize(.small)
                .liquidGlassTooltip(commitWebURL != nil ? "Open commit in browser" : "Inspect commit diff")

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
                .glassButtonStyle()
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 320)
        .onHover { isInside in
            onHoverChange(isInside)
        }
    }

    private func renderMarkdown(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.allowsExtendedAttributes = true
        options.interpretedSyntax = .full
        if let attr = try? AttributedString(markdown: text, options: options) {
            return attr
        }
        return AttributedString(text)
    }
}
