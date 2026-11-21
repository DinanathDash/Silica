import SwiftUI

/// Native unified Git diff viewer displaying additions in green, deletions in red,
/// hunk headers, line numbers, and quick edit switching.
struct GitDiffView: View {
    let diff: WorkspaceModel.DiffPresentation
    let workspace: WorkspaceModel
    let model: SourceControlModel

    private var settings: EditorSettings { .shared }

    @State private var diffText: String = ""
    @State private var isLoading = true
    @State private var parsedLines: [DiffLine] = []
    @State private var totalAdditions = 0
    @State private var totalDeletions = 0

    struct DiffLine: Identifiable {
        let id = UUID()
        enum Kind {
            case header
            case hunkHeader(String)
            case addition(oldLine: Int?, newLine: Int?, text: String)
            case deletion(oldLine: Int?, newLine: Int?, text: String)
            case context(oldLine: Int?, newLine: Int?, text: String)
        }
        let kind: Kind
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
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(parsedLines) { line in
                            diffLineRow(line: line)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .font(.system(size: settings.fontSize, design: .monospaced))
                .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: diff.id) {
            await loadDiff()
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
            .help("Switch to live code editor")

            Button {
                workspace.closeDiff()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Close Diff")
        }
    }

    // MARK: - Row Rendering

    private func diffLineRow(line: DiffLine) -> some View {
        HStack(spacing: 0) {
            switch line.kind {
            case .header:
                EmptyView()

            case .hunkHeader(let text):
                HStack {
                    Text(text)
                        .font(.system(size: max(settings.fontSize - 1, 10), weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.accentColor.opacity(0.85))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.08))

            case .addition(let oldL, let newL, let text):
                HStack(spacing: 0) {
                    lineNumberView(oldLine: oldL, newLine: newL)
                    Text("+")
                        .frame(width: 16)
                        .foregroundStyle(.green)
                        .fontWeight(.bold)
                    Text(text)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 16)
                }
                .padding(.vertical, 1)
                .background(Color.green.opacity(0.12))

            case .deletion(let oldL, let newL, let text):
                HStack(spacing: 0) {
                    lineNumberView(oldLine: oldL, newLine: newL)
                    Text("-")
                        .frame(width: 16)
                        .foregroundStyle(.red)
                        .fontWeight(.bold)
                    Text(text)
                        .foregroundStyle(.primary.opacity(0.85))
                    Spacer(minLength: 16)
                }
                .padding(.vertical, 1)
                .background(Color.red.opacity(0.12))

            case .context(let oldL, let newL, let text):
                HStack(spacing: 0) {
                    lineNumberView(oldLine: oldL, newLine: newL)
                    Text(" ")
                        .frame(width: 16)
                    Text(text)
                        .foregroundStyle(.primary.opacity(0.9))
                    Spacer(minLength: 16)
                }
                .padding(.vertical, 1)
            }
        }
        .frame(minWidth: 400, alignment: .leading)
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
        let raw = await model.diffForFile(in: diff.commitHash, relativePath: diff.relativePath)
        self.diffText = raw
        parseUnifiedDiff(raw)
        isLoading = false
    }

    private func parseUnifiedDiff(_ raw: String) {
        var lines: [DiffLine] = []
        var adds = 0
        var dels = 0

        var oldLineCounter = 0
        var newLineCounter = 0
        var inHunk = false

        for line in raw.components(separatedBy: .newlines) {
            if line.hasPrefix("diff --git") || line.hasPrefix("index ") ||
               line.hasPrefix("--- ") || line.hasPrefix("+++ ") ||
               line.hasPrefix("commit ") || line.hasPrefix("Author:") ||
               line.hasPrefix("Date:") {
                // Header lines, omit or keep clean
                continue
            }

            if line.hasPrefix("@@") {
                inHunk = true
                lines.append(DiffLine(kind: .hunkHeader(line)))
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
                continue
            }

            guard inHunk else { continue }

            if line.hasPrefix("+") {
                adds += 1
                let content = String(line.dropFirst())
                lines.append(DiffLine(kind: .addition(oldLine: nil, newLine: newLineCounter, text: content)))
                newLineCounter += 1
            } else if line.hasPrefix("-") {
                dels += 1
                let content = String(line.dropFirst())
                lines.append(DiffLine(kind: .deletion(oldLine: oldLineCounter, newLine: nil, text: content)))
                oldLineCounter += 1
            } else if line.hasPrefix(" ") {
                let content = String(line.dropFirst())
                lines.append(DiffLine(kind: .context(oldLine: oldLineCounter, newLine: newLineCounter, text: content)))
                oldLineCounter += 1
                newLineCounter += 1
            } else if line.hasPrefix("\\ No newline at end of file") {
                // Skip git marker
                continue
            }
        }

        self.parsedLines = lines
        self.totalAdditions = adds
        self.totalDeletions = dels
    }
}
