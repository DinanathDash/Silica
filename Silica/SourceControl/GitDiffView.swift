import SwiftUI

/// Native unified Git diff viewer displaying additions in green, deletions in red,
/// hunk headers, line numbers, and quick edit switching.
struct GitDiffView: View {
    let diff: WorkspaceModel.DiffPresentation
    let workspace: WorkspaceModel
    let model: SourceControlModel

    private var settings: EditorSettings { .shared }

    @State private var isLoading = true
    @State private var parsedLines: [DiffLine] = []
    @State private var totalAdditions = 0
    @State private var totalDeletions = 0
    @State private var maxVisibleLines = 3000
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

    private var visibleParsedLines: [DiffLine] {
        if parsedLines.count > maxVisibleLines {
            return Array(parsedLines.prefix(maxVisibleLines))
        }
        return parsedLines
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
            } else if parsedLines.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("No changes in this file")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    ScrollView(isWordWrapEnabled ? [.vertical] : [.horizontal, .vertical]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(visibleParsedLines) { line in
                                diffLineRow(line: line)
                                    .frame(minHeight: max(settings.fontSize + 5, 20))
                            }

                            if parsedLines.count > maxVisibleLines {
                                HStack(spacing: 8) {
                                    Text("Diff is very large (\(parsedLines.count) lines). Showing first \(maxVisibleLines) lines for smooth scrolling.")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                    Button("Show All Lines") {
                                        maxVisibleLines = parsedLines.count
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                                .padding(12)
                            }
                        }
                        .frame(minWidth: geometry.size.width, alignment: .leading)
                        .padding(.vertical, 8)
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
            liveUpdateTask?.cancel()
            liveUpdateTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                await loadDiff()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .fileDidSave)) { note in
            if let savedURL = note.object as? URL, savedURL == diff.fileURL {
                Task { await loadDiff() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSText.didChangeNotification)) { _ in
            guard diff.commitHash == nil && diff.compareBranch == nil else { return }
            liveUpdateTask?.cancel()
            liveUpdateTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                await loadDiff()
            }
        }
        .onDisappear {
            liveUpdateTask?.cancel()
            liveUpdateTask = nil
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 10) {
            FileIcon(url: diff.fileURL, width: 15)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(diff.fileURL.lastPathComponent)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)

                    if diff.isBranchCompare {
                        Text("Branch Compare")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    } else if diff.isCommitDiff {
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

            Spacer()

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

            // Button to return to normal live code editor
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

    // MARK: - Row Rendering

    private var diffLanguage: SyntaxLanguage? {
        SyntaxLanguage(url: diff.fileURL)
    }

    private func highlightedCodeText(_ text: String) -> AttributedString {
        var attrStr = AttributedString(text)
        guard let language = diffLanguage else { return attrStr }
        let theme = settings.syntaxTheme
        let tokens = language.tokenizer.tokenize(text as NSString)
        for token in tokens {
            guard let range = Range(token.range, in: attrStr) else { continue }
            attrStr[range].foregroundColor = Color(nsColor: theme.color(for: token.kind))
        }
        return attrStr
    }

    @ViewBuilder
    private func diffLineRow(line: DiffLine) -> some View {
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
                lineNumberView(oldLine: oldL, newLine: newL)
                Text("+")
                    .frame(width: 16)
                    .foregroundStyle(Color(red: 0.45, green: 0.79, blue: 0.57))
                    .fontWeight(.bold)
                Text(highlightedCodeText(text))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: !isWordWrapEnabled, vertical: false)
                Spacer(minLength: 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: max(settings.fontSize + 5, 20))
            .background(Color.green.opacity(0.12))

        case .deletion(let oldL, let newL, let text):
            HStack(alignment: .top, spacing: 0) {
                lineNumberView(oldLine: oldL, newLine: newL)
                Text("-")
                    .frame(width: 16)
                    .foregroundStyle(Color(red: 0.89, green: 0.41, blue: 0.45))
                    .fontWeight(.bold)
                Text(highlightedCodeText(text))
                    .foregroundStyle(.primary.opacity(0.9))
                    .fixedSize(horizontal: !isWordWrapEnabled, vertical: false)
                Spacer(minLength: 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: max(settings.fontSize + 5, 20))
            .background(Color.red.opacity(0.12))

        case .context(let oldL, let newL, let text):
            HStack(alignment: .top, spacing: 0) {
                lineNumberView(oldLine: oldL, newLine: newL)
                Text(" ")
                    .frame(width: 16)
                Text(highlightedCodeText(text))
                    .foregroundStyle(.primary.opacity(0.95))
                    .fixedSize(horizontal: !isWordWrapEnabled, vertical: false)
                Spacer(minLength: 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: max(settings.fontSize + 5, 20))
        }
    }

    private func lineNumberView(oldLine: Int?, newLine: Int?) -> some View {
        HStack(spacing: 4) {
            Text(oldLine.map { "\($0)" } ?? "")
                .frame(width: 38, alignment: .trailing)
                .foregroundStyle(.secondary.opacity(0.6))
            Text(newLine.map { "\($0)" } ?? "")
                .frame(width: 38, alignment: .trailing)
                .foregroundStyle(.secondary.opacity(0.6))
        }
        .font(.system(size: max(settings.fontSize - 2, 9), design: .monospaced))
        .padding(.leading, 8)
        .padding(.trailing, 6)
    }

    // MARK: - Diff Loading & Parsing

    private func loadDiff() async {
        isLoading = true
        let raw: String
        if let targetBranch = diff.compareBranch {
            raw = await model.diffForBranchCompare(targetBranch: targetBranch)
        } else {
            raw = await model.diffForFile(in: diff.commitHash, relativePath: diff.relativePath)
        }

        let result = await Task.detached(priority: .userInitiated) { () -> (lines: [DiffLine], adds: Int, dels: Int) in
            Self.parseUnifiedDiffLines(raw)
        }.value

        self.parsedLines = result.lines
        self.totalAdditions = result.adds
        self.totalDeletions = result.dels
        self.isLoading = false
    }

    nonisolated static func parseUnifiedDiffLines(_ raw: String) -> (lines: [DiffLine], adds: Int, dels: Int) {
        var lines: [DiffLine] = []
        lines.reserveCapacity(min(raw.count / 40, 5000))
        var adds = 0
        var dels = 0
        var lineIndex = 0

        var oldLineCounter = 0
        var newLineCounter = 0
        var inHunk = false

        raw.enumerateLines { line, stop in
            if lines.count >= 10_000 {
                stop = true
                return
            }
            if line.hasPrefix("diff --git") || line.hasPrefix("index ") ||
               line.hasPrefix("--- ") || line.hasPrefix("+++ ") ||
               line.hasPrefix("commit ") || line.hasPrefix("Author:") ||
               line.hasPrefix("Date:") {
                return
            }

            if line.hasPrefix("@@") {
                inHunk = true
                lines.append(DiffLine(id: lineIndex, kind: .hunkHeader(line)))
                lineIndex += 1
                // Parse @@ -oldStart,oldCount +newStart,newCount @@
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
                adds += 1
                let content = String(line.dropFirst())
                lines.append(DiffLine(id: lineIndex, kind: .addition(oldLine: nil, newLine: newLineCounter, text: content)))
                lineIndex += 1
                newLineCounter += 1
            } else if line.hasPrefix("-") {
                dels += 1
                let content = String(line.dropFirst())
                lines.append(DiffLine(id: lineIndex, kind: .deletion(oldLine: oldLineCounter, newLine: nil, text: content)))
                lineIndex += 1
                oldLineCounter += 1
            } else if line.hasPrefix(" ") {
                let content = String(line.dropFirst())
                lines.append(DiffLine(id: lineIndex, kind: .context(oldLine: oldLineCounter, newLine: newLineCounter, text: content)))
                lineIndex += 1
                oldLineCounter += 1
                newLineCounter += 1
            }
        }

        return (lines, adds, dels)
    }
}
