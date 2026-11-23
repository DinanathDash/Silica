import SwiftUI
import AppKit

struct GitHunk: Identifiable, Sendable {
    let id = UUID()
    let oldStart: Int
    let oldLength: Int
    let newStart: Int
    let newLength: Int
    let oldLines: [String]
    let newLines: [String]
}

@MainActor
final class GitQuickDiffPopoverController {
    static let shared = GitQuickDiffPopoverController()

    private var popover: NSPopover?

    func show(
        hunk: GitHunk,
        allHunks: [GitHunk],
        currentIndex: Int,
        relativeTo rect: NSRect,
        of view: NSView,
        language: SyntaxLanguage?,
        onRevert: @escaping () -> Void,
        onNavigate: @escaping (GitHunk) -> Void
    ) {
        close()

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true

        let rootView = GitQuickDiffPopoverView(
            hunk: hunk,
            allHunks: allHunks,
            currentIndex: currentIndex,
            language: language,
            onRevert: { [weak self] in
                self?.close()
                onRevert()
            },
            onNavigate: { targetHunk in
                onNavigate(targetHunk)
            },
            onClose: { [weak self] in
                self?.close()
            }
        )

        let hostingController = NSHostingController(rootView: rootView)
        popover.contentViewController = hostingController
        self.popover = popover

        popover.show(relativeTo: rect, of: view, preferredEdge: .maxX)
    }

    var isVisible: Bool {
        popover?.isShown == true
    }

    func close() {
        popover?.performClose(nil)
        popover = nil
    }
}

/// Matches VS Code's QuickDiff / DirtyDiff Peek Widget:
/// - Distinct Peek View top toolbar with change index, diff line range, Previous/Next navigation, Revert, and Close.
/// - Integrated side-by-side or stacked diff view with syntax highlighting, gutter line numbering, and soft change tinting.
private struct GitQuickDiffPopoverView: View {
    let hunk: GitHunk
    let allHunks: [GitHunk]
    let currentIndex: Int
    let language: SyntaxLanguage?
    let onRevert: () -> Void
    let onNavigate: (GitHunk) -> Void
    let onClose: () -> Void

    private var settings: EditorSettings { .shared }

    private var hunkRangeTitle: String {
        if hunk.newLength > 1 {
            return "Lines \(hunk.newStart)–\(hunk.newStart + hunk.newLength - 1)"
        } else if hunk.newLength == 1 {
            return "Line \(hunk.newStart)"
        } else {
            return "Line \(hunk.newStart) (Deleted)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Peek Widget Title / Action Bar (styled like VS Code peekViewTitle)
            HStack(spacing: 8) {
                // Provider & Diff Title
                HStack(spacing: 6) {
                    SourceControlIcon(type: .diff, size: 12)
                        .foregroundStyle(Color.accentColor)

                    Text(hunkRangeTitle)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.primary)

                    if allHunks.count > 1 {
                        Text("\(currentIndex + 1) of \(allHunks.count) changes")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Actions toolbar
                HStack(spacing: 4) {
                    Button(action: onRevert) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Revert")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("Revert this change (Undo with ⌘Z)")

                    Divider()
                        .frame(height: 12)
                        .padding(.horizontal, 2)

                    Button {
                        if currentIndex > 0 {
                            onNavigate(allHunks[currentIndex - 1])
                        }
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(currentIndex == 0)
                    .opacity(currentIndex == 0 ? 0.35 : 1.0)
                    .help("Previous Change (⌥F3)")

                    Button {
                        if currentIndex < allHunks.count - 1 {
                            onNavigate(allHunks[currentIndex + 1])
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(currentIndex >= allHunks.count - 1)
                    .opacity(currentIndex >= allHunks.count - 1 ? 0.35 : 1.0)
                    .help("Next Change (Shift+⌥F3)")

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Close (Esc)")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.95))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: 1)
            }

            // Peek Diff Body (VS Code peekViewEditor styling)
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    // Original / Deleted lines
                    ForEach(Array(hunk.oldLines.enumerated()), id: \.offset) { idx, line in
                        HStack(alignment: .top, spacing: 0) {
                            Text("\(hunk.oldStart + idx)")
                                .frame(width: 38, alignment: .trailing)
                                .foregroundStyle(Color.red.opacity(0.8))
                                .padding(.trailing, 6)

                            Text("-")
                                .frame(width: 14)
                                .foregroundStyle(Color.red)
                                .fontWeight(.bold)

                            Text(GitDiffView.highlightLine(line, language: language, theme: settings.syntaxTheme))
                                .foregroundStyle(.primary.opacity(0.9))

                            Spacer(minLength: 24)
                        }
                        .font(.system(size: 11.5, design: .monospaced))
                        .padding(.vertical, 1.5)
                        .padding(.horizontal, 8)
                        .background(Color.red.opacity(0.14))
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(Color.red)
                                .frame(width: 3)
                        }
                    }

                    // Modified / Added lines
                    ForEach(Array(hunk.newLines.enumerated()), id: \.offset) { idx, line in
                        HStack(alignment: .top, spacing: 0) {
                            Text("\(hunk.newStart + idx)")
                                .frame(width: 38, alignment: .trailing)
                                .foregroundStyle(Color.green.opacity(0.8))
                                .padding(.trailing, 6)

                            Text("+")
                                .frame(width: 14)
                                .foregroundStyle(Color.green)
                                .fontWeight(.bold)

                            Text(GitDiffView.highlightLine(line, language: language, theme: settings.syntaxTheme))
                                .foregroundStyle(.primary)

                            Spacer(minLength: 24)
                        }
                        .font(.system(size: 11.5, design: .monospaced))
                        .padding(.vertical, 1.5)
                        .padding(.horizontal, 8)
                        .background(Color.green.opacity(0.14))
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(Color.green)
                                .frame(width: 3)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 260)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.98))
        }
        .frame(minWidth: 400, maxWidth: 640)
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
        }
    }
}
