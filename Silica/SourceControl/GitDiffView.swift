import SwiftUI

/// Native unified Git diff viewer displaying additions in green, deletions in red,
/// hunk headers, line numbers, gutter stripes, and continuous diffs for multi-file commits or branch comparisons.
struct GitDiffView: View {
    let diff: WorkspaceModel.DiffPresentation
    let workspace: WorkspaceModel
    let model: SourceControlModel

    private var settings: EditorSettings { .shared }

    @State private var isLoading = true
    @State private var fileGroups: [DiffFileGroup] = []
    @State private var collapsedFileIDs: Set<String> = []
    @State private var totalAdditions = 0
    @State private var totalDeletions = 0
    @State private var liveUpdateTask: Task<Void, Never>?

    private var isWordWrapEnabled: Bool {
        settings.wrapsLines
    }

    struct DiffLine: Identifiable, Sendable {
        let id: Int
        enum Kind: Sendable {
            case header
            case hunkHeader(String)
            case addition(oldLine: Int?, newLine: Int?, text: String)
            case deletion(oldLine: Int?, newLine: Int?, text: String)
            case context(oldLine: Int?, newLine: Int?, text: String)
        }
        let kind: Kind
    }

    struct DiffFileGroup: Identifiable, Sendable {
        let id: String
        let relativePath: String
        let fileName: String
        let directoryPath: String
        let status: GitFileItem.Status
        let additions: Int
        let deletions: Int
        let lines: [DiffLine]
    }

    /// Flat row representation for LazyVStack virtualization to eliminate layout stalls and memory bloat
    enum DiffRowItem: Identifiable {
        case fileHeader(DiffFileGroup)
        case diffLine(DiffFileGroup, DiffLine)
        case fileFooter(DiffFileGroup)

        var id: String {
            switch self {
            case .fileHeader(let group):
                return "header_\(group.id)"
            case .diffLine(let group, let line):
                return "line_\(group.id)_\(line.id)"
            case .fileFooter(let group):
                return "footer_\(group.id)"
            }
        }
    }

    private var isMultiFile: Bool {
        fileGroups.count > 1 || diff.isFullDiff || diff.isBranchCompare
    }

    private var multiFileRows: [DiffRowItem] {
        var rows: [DiffRowItem] = []
        rows.reserveCapacity(fileGroups.reduce(0) { $0 + 1 + $1.lines.count })
        for group in fileGroups {
            rows.append(.fileHeader(group))
            if !collapsedFileIDs.contains(group.id) {
                for line in group.lines {
                    rows.append(.diffLine(group, line))
                }
                rows.append(.fileFooter(group))
            }
        }
        return rows
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            headerBar
                .frame(height: 38)
                .padding(.horizontal, 12)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.4))
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 1)
                }

            if isLoading {
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading diff…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if fileGroups.isEmpty || fileGroups.allSatisfy({ $0.lines.isEmpty }) {
                emptyStateView
            } else {
                GeometryReader { geometry in
                    ScrollView(isWordWrapEnabled ? [.vertical] : [.horizontal, .vertical]) {
                        if isMultiFile {
                            multiFileDiffContent(geometry: geometry)
                        } else {
                            singleFileDiffContent(geometry: geometry)
                        }
                    }
                }
                .font(.system(size: settings.fontSize, design: .monospaced))
                .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: diff.id) {
            await loadDiff()
        }
        .onChange(of: workspace.buffers[diff.fileURL]?.isDirty) { _, _ in
            scheduleLiveReload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .fileDidSave)) { note in
            if let savedURL = note.object as? URL, savedURL == diff.fileURL {
                scheduleLiveReload()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSText.didChangeNotification)) { _ in
            guard diff.commitHash == nil && diff.compareBranch == nil else { return }
            scheduleLiveReload()
        }
        .onChange(of: model.stagedFiles) { _, _ in
            scheduleLiveReload()
        }
        .onChange(of: model.unstagedFiles) { _, _ in
            scheduleLiveReload()
        }
        .onDisappear {
            liveUpdateTask?.cancel()
            liveUpdateTask = nil
        }
    }

    // MARK: - Empty State

    @ViewBuilder
    private var emptyStateView: some View {
        if diff.commitHash == nil && diff.compareBranch == nil {
            // Working tree changes that were committed in the background
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.green)
                VStack(spacing: 4) {
                    Text("All changes committed")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("No uncommitted changes in this file.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Button {
                    workspace.closeDiff()
                } label: {
                    Label("Return to Code Editor", systemImage: "square.and.pencil")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if diff.isBranchCompare {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("Branches are identical")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("No differences between \(diff.relativePath).")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("No changes in this commit")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 10) {
            if isMultiFile {
                SourceControlIcon(type: diff.isBranchCompare ? .compare : .commit, size: 14)
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(diff.relativePath)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)

                        Text(diff.isBranchCompare ? "Branch Compare" : "Full Diff")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())

                        Text("\(fileGroups.count) \(fileGroups.count == 1 ? "file" : "files") changed")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }

                    if let title = diff.commitTitle, !title.isEmpty, title != diff.relativePath {
                        Text(title)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } else {
                FileIcon(url: diff.fileURL, width: 15)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(diff.fileURL.lastPathComponent)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)

                        if diff.isCommitDiff {
                            Text(diff.commitHash?.prefix(7).description ?? "Commit")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                        } else {
                            Text("Working Changes")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.primary.opacity(0.06), in: Capsule())
                        }
                    }

                    if let title = diff.commitTitle, !title.isEmpty {
                        Text(title)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if !diff.relativePath.isEmpty {
                        Text(diff.relativePath)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            if isMultiFile && !fileGroups.isEmpty {
                Button {
                    if collapsedFileIDs.count == fileGroups.count {
                        collapsedFileIDs.removeAll()
                    } else {
                        collapsedFileIDs = Set(fileGroups.map(\.id))
                    }
                } label: {
                    SourceControlIcon(
                        type: collapsedFileIDs.count == fileGroups.count ? .expand : .collapse,
                        size: 13
                    )
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.titleBarIcon)
                .frame(width: 24, height: 24)
                .liquidGlassTooltip(collapsedFileIDs.count == fileGroups.count ? "Expand All Files" : "Collapse All Files")
            }

            if totalAdditions > 0 || totalDeletions > 0 {
                HStack(spacing: 5) {
                    if totalAdditions > 0 {
                        Text("+\(totalAdditions)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.green)
                    }
                    if totalDeletions > 0 {
                        Text("-\(totalDeletions)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
            }

            // Only show "Edit Code" button for single-file diffs. In full diff, the tab has a close button.
            if !isMultiFile {
                Button {
                    workspace.closeDiff()
                } label: {
                    Label("Edit Code", systemImage: "square.and.pencil")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .liquidGlassTooltip("Switch to live code editor")
            }
        }
    }

    // MARK: - Multi-File Diff Content (Virtualized flat list for extreme performance)

    private func multiFileDiffContent(geometry: GeometryProxy) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(multiFileRows) { row in
                switch row {
                case .fileHeader(let group):
                    fileSectionHeader(group: group)
                        .padding(.top, 10)
                        .padding(.horizontal, 10)

                case .diffLine(let group, let line):
                    let fileURL = workspace.rootURL.appending(path: group.relativePath)
                    let lang = SyntaxLanguage(url: fileURL)
                    diffLineRow(line: line, group: group, language: lang)
                        .frame(minHeight: max(settings.fontSize + 5, 20))
                        .padding(.horizontal, 10)

                case .fileFooter:
                    Spacer()
                        .frame(height: 6)
                }
            }
        }
        .frame(minWidth: geometry.size.width, alignment: .leading)
        .padding(.vertical, 6)
    }

    private func fileSectionHeader(group: DiffFileGroup) -> some View {
        let isCollapsed = collapsedFileIDs.contains(group.id)
        let fileURL = workspace.rootURL.appending(path: group.relativePath)

        return HStack(spacing: 8) {
            Button {
                if isCollapsed {
                    collapsedFileIDs.remove(group.id)
                } else {
                    collapsedFileIDs.insert(group.id)
                }
            } label: {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)

            FileIcon(url: fileURL, width: 14)

            Text(group.fileName)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.primary)

            if !group.directoryPath.isEmpty {
                Text(group.directoryPath)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Text(group.status.badgeLetter)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(group.status.badgeColor)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(group.status.badgeColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))

            Spacer()

            if group.additions > 0 || group.deletions > 0 {
                HStack(spacing: 4) {
                    if group.additions > 0 {
                        Text("+\(group.additions)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.green)
                    }
                    if group.deletions > 0 {
                        Text("-\(group.deletions)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 3))
            }

            // Open File button with custom SVG external icon, padding(.trailing, 8), and liquid glass tooltip
            Button {
                openFileFromGroup(group)
            } label: {
                SourceControlIcon(type: .external, size: 12)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            .liquidGlassTooltip("Open \(group.fileName)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            if isCollapsed {
                collapsedFileIDs.remove(group.id)
            } else {
                collapsedFileIDs.insert(group.id)
            }
        }
    }

    private func openFileFromGroup(_ group: DiffFileGroup) {
        let fileURL = workspace.rootURL.appending(path: group.relativePath)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            workspace.open(fileURL)
        } else if let hash = diff.commitHash {
            workspace.openCommitDiff(commitHash: hash, commitTitle: diff.commitTitle ?? "", relativePath: group.relativePath)
        }
    }

    // MARK: - Single-File Diff Content

    private func singleFileDiffContent(geometry: GeometryProxy) -> some View {
        let singleGroup = fileGroups.first
        let lang = SyntaxLanguage(url: diff.fileURL)

        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(singleGroup?.lines ?? []) { line in
                diffLineRow(line: line, group: singleGroup, language: lang)
                    .frame(minHeight: max(settings.fontSize + 5, 20))
            }
        }
        .frame(minWidth: geometry.size.width, alignment: .leading)
        .padding(.vertical, 8)
    }

    // MARK: - Row Rendering & Code Highlighting

    private func highlightedCodeText(_ text: String, language: SyntaxLanguage?) -> AttributedString {
        var attrStr = AttributedString(text)
        guard let language, text.count <= 1000 else { return attrStr }
        let theme = settings.syntaxTheme
        let tokens = language.tokenizer.tokenize(text as NSString)
        for token in tokens {
            guard let range = Range(token.range, in: attrStr) else { continue }
            attrStr[range].foregroundColor = Color(nsColor: theme.color(for: token.kind))
        }
        return attrStr
    }

    @ViewBuilder
    private func diffLineRow(line: DiffLine, group: DiffFileGroup?, language: SyntaxLanguage?) -> some View {
        switch line.kind {
        case .header:
            EmptyView()

        case .hunkHeader(let text):
            HStack(spacing: 0) {
                Text(text)
                    .font(.system(size: max(settings.fontSize - 1, 10), weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.accentColor.opacity(0.85))
                    .padding(.horizontal, 12)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: max(settings.fontSize + 5, 20))
            .background(Color.accentColor.opacity(0.08))

        case .addition(let oldL, let newL, let text):
            HStack(alignment: .top, spacing: 0) {
                lineNumberView(oldLine: oldL, newLine: newL, kind: line.kind) {
                    jumpToEditorLine(line: line, group: group)
                }
                Text("+")
                    .frame(width: 16)
                    .foregroundStyle(Color(red: 0.45, green: 0.79, blue: 0.57))
                    .fontWeight(.bold)
                Text(highlightedCodeText(text, language: language))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: !isWordWrapEnabled, vertical: false)
                Spacer(minLength: 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: max(settings.fontSize + 5, 20))
            .background(Color.green.opacity(0.12))

        case .deletion(let oldL, let newL, let text):
            HStack(alignment: .top, spacing: 0) {
                lineNumberView(oldLine: oldL, newLine: newL, kind: line.kind) {
                    jumpToEditorLine(line: line, group: group)
                }
                Text("-")
                    .frame(width: 16)
                    .foregroundStyle(Color(red: 0.89, green: 0.41, blue: 0.45))
                    .fontWeight(.bold)
                Text(highlightedCodeText(text, language: language))
                    .foregroundStyle(.primary.opacity(0.9))
                    .fixedSize(horizontal: !isWordWrapEnabled, vertical: false)
                Spacer(minLength: 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: max(settings.fontSize + 5, 20))
            .background(Color.red.opacity(0.12))

        case .context(let oldL, let newL, let text):
            HStack(alignment: .top, spacing: 0) {
                lineNumberView(oldLine: oldL, newLine: newL, kind: line.kind) {
                    jumpToEditorLine(line: line, group: group)
                }
                Text(" ")
                    .frame(width: 16)
                Text(highlightedCodeText(text, language: language))
                    .foregroundStyle(.primary.opacity(0.95))
                    .fixedSize(horizontal: !isWordWrapEnabled, vertical: false)
                Spacer(minLength: 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: max(settings.fontSize + 5, 20))
        }
    }

    private func lineNumberView(oldLine: Int?, newLine: Int?, kind: DiffLine.Kind, onJump: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(oldLine.map { "\($0)" } ?? "")
                .frame(width: 38, alignment: .trailing)
                .foregroundStyle(.secondary.opacity(0.6))
            Text(newLine.map { "\($0)" } ?? "")
                .frame(width: 38, alignment: .trailing)
                .foregroundStyle(.secondary.opacity(0.6))

            // 3px color-coded vertical stripe beside line numbers (Point 9)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(stripeColor(for: kind))
                .frame(width: 3, height: 16)
        }
        .font(.system(size: max(settings.fontSize - 2, 9), design: .monospaced))
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            onJump()
        }
        .liquidGlassTooltip("Click to jump to line in editor")
    }

    private func stripeColor(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .addition:
            return Color(red: 0.35, green: 0.82, blue: 0.45)
        case .deletion:
            return Color(red: 0.95, green: 0.36, blue: 0.38)
        case .context, .header, .hunkHeader:
            return Color.clear
        }
    }

    private func jumpToEditorLine(line: DiffLine, group: DiffFileGroup?) {
        let relativePath = group?.relativePath ?? diff.relativePath
        let fileURL = workspace.rootURL.appending(path: relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            if let hash = diff.commitHash {
                workspace.openCommitDiff(commitHash: hash, commitTitle: diff.commitTitle ?? "", relativePath: relativePath)
            }
            return
        }

        let targetLine: Int?
        switch line.kind {
        case .addition(_, let newL, _):
            targetLine = newL
        case .deletion(let oldL, _, _):
            targetLine = oldL
        case .context(let oldL, let newL, _):
            targetLine = newL ?? oldL
        case .header, .hunkHeader:
            targetLine = nil
        }

        workspace.open(fileURL)
        if let targetLine {
            workspace.goToLine(targetLine)
        }
    }

    // MARK: - Diff Loading & Parsing

    private func scheduleLiveReload() {
        liveUpdateTask?.cancel()
        liveUpdateTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await loadDiff()
        }
    }

    private func loadDiff() async {
        isLoading = true
        let raw: String
        if let targetBranch = diff.compareBranch {
            raw = await model.diffForBranchCompare(targetBranch: targetBranch)
        } else if diff.isFullDiff, let commitHash = diff.commitHash {
            raw = await model.diffForFullCommit(commitHash: commitHash)
        } else {
            raw = await model.diffForFile(in: diff.commitHash, relativePath: diff.relativePath)
        }

        let fallback = diff.relativePath
        let result = await Task.detached(priority: .userInitiated) { () -> (groups: [DiffFileGroup], adds: Int, dels: Int) in
            Self.parseUnifiedDiff(raw: raw, fallbackPath: fallback)
        }.value

        self.fileGroups = result.groups
        self.totalAdditions = result.adds
        self.totalDeletions = result.dels
        self.isLoading = false
    }

    nonisolated static func parseUnifiedDiff(raw: String, fallbackPath: String) -> (groups: [DiffFileGroup], adds: Int, dels: Int) {
        var groups: [DiffFileGroup] = []
        var totalAdds = 0
        var totalDels = 0

        var currentPath = fallbackPath
        var currentStatus: GitFileItem.Status = .modified
        var currentLines: [DiffLine] = []
        var currentAdds = 0
        var currentDels = 0
        var lineIndex = 0

        var oldLineCounter = 0
        var newLineCounter = 0
        var inHunk = false
        var hasSeenDiffHeader = false

        func flushCurrentGroup() {
            guard !currentLines.isEmpty || hasSeenDiffHeader else { return }
            let trimmedPath = currentPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPath.isEmpty else { return }
            let components = trimmedPath.split(separator: "/")
            let fileName = components.last.map(String.init) ?? trimmedPath
            let dirPath = components.dropLast().joined(separator: "/")

            groups.append(DiffFileGroup(
                id: trimmedPath + "_\(groups.count)",
                relativePath: trimmedPath,
                fileName: fileName,
                directoryPath: dirPath,
                status: currentStatus,
                additions: currentAdds,
                deletions: currentDels,
                lines: currentLines
            ))
            currentLines = []
            currentAdds = 0
            currentDels = 0
            oldLineCounter = 0
            newLineCounter = 0
            inHunk = false
        }

        raw.enumerateLines { line, stop in
            if groups.count >= 200 && line.hasPrefix("diff --git") {
                stop = true
                return
            }

            if line.hasPrefix("diff --git") {
                if hasSeenDiffHeader {
                    flushCurrentGroup()
                }
                hasSeenDiffHeader = true
                currentStatus = .modified
                // Parse "diff --git a/path b/path" robustly including spaces and quotes
                if let bRange = line.range(of: " b/") {
                    var newPart = String(line[bRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if newPart.hasPrefix("\"") && newPart.hasSuffix("\"") {
                        newPart = String(newPart.dropFirst().dropLast())
                    }
                    currentPath = newPart
                }
                return
            }

            if line.hasPrefix("new file mode") {
                currentStatus = .added
                return
            }
            if line.hasPrefix("deleted file mode") {
                currentStatus = .deleted
                return
            }
            if line.hasPrefix("similarity index") || line.hasPrefix("rename from") {
                currentStatus = .renamed
                return
            }
            if line.hasPrefix("--- ") {
                if line.contains("/dev/null") {
                    currentStatus = .added
                }
                return
            }
            if line.hasPrefix("+++ ") {
                if line.contains("/dev/null") {
                    currentStatus = .deleted
                } else if currentPath.isEmpty || currentPath == fallbackPath {
                    var path = line.replacingOccurrences(of: "+++ ", with: "").trimmingCharacters(in: .whitespaces)
                    if path.hasPrefix("b/") { path = String(path.dropFirst(2)) }
                    if path.hasPrefix("\"") && path.hasSuffix("\"") { path = String(path.dropFirst().dropLast()) }
                    currentPath = path
                }
                return
            }
            if line.hasPrefix("index ") || line.hasPrefix("commit ") ||
               line.hasPrefix("Author:") || line.hasPrefix("Date:") {
                return
            }

            if line.hasPrefix("@@") {
                inHunk = true
                currentLines.append(DiffLine(id: lineIndex, kind: .hunkHeader(line)))
                lineIndex += 1
                let components = line.split(separator: " ")
                if components.count >= 3 {
                    let oldPart = components[1].replacingOccurrences(of: "-", with: "")
                    let newPart = components[2].replacingOccurrences(of: "+", with: "")
                    let oldStart = Int(oldPart.split(separator: ",").first ?? "0") ?? 1
                    let newStart = Int(newPart.split(separator: ",").first ?? "0") ?? 1
                    oldLineCounter = oldStart
                    newLineCounter = newStart
                }
                return
            }

            guard inHunk else { return }

            if line.hasPrefix("+") {
                currentAdds += 1
                totalAdds += 1
                let content = String(line.dropFirst())
                currentLines.append(DiffLine(id: lineIndex, kind: .addition(oldLine: nil, newLine: newLineCounter, text: content)))
                lineIndex += 1
                newLineCounter += 1
            } else if line.hasPrefix("-") {
                currentDels += 1
                totalDels += 1
                let content = String(line.dropFirst())
                currentLines.append(DiffLine(id: lineIndex, kind: .deletion(oldLine: oldLineCounter, newLine: nil, text: content)))
                lineIndex += 1
                oldLineCounter += 1
            } else if line.hasPrefix(" ") {
                let content = String(line.dropFirst())
                currentLines.append(DiffLine(id: lineIndex, kind: .context(oldLine: oldLineCounter, newLine: newLineCounter, text: content)))
                lineIndex += 1
                oldLineCounter += 1
                newLineCounter += 1
            }
        }

        flushCurrentGroup()

        return (groups, totalAdds, totalDels)
    }
}
