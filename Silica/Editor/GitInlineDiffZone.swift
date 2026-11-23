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

/// Matches VS Code's inline QuickDiff / DirtyDiff Zone Widget layout:
/// - Injected directly as a full-width block spanning the editor viewport at the change location.
/// - Top header bar with change breadcrumbs ("Line X (1 of 3 changes)"), Revert Change button, Previous/Next change chevrons, and Close.
/// - Stacked diff view displaying deleted/original lines in red (with line numbers and '-' prefix) followed by added/modified lines in green (with line numbers and '+' prefix).
@MainActor
final class GitInlineDiffZoneController {
    static let shared = GitInlineDiffZoneController()

    private var hostingView: NSHostingView<GitInlineDiffZoneView>?
    private weak var containerView: NSView?
    private var scrollObserver: NSObjectProtocol?
    private var windowResizeObserver: NSObjectProtocol?

    var isVisible: Bool {
        hostingView?.superview != nil
    }

    func show(
        hunk: GitHunk,
        allHunks: [GitHunk],
        currentIndex: Int,
        anchorRectInRuler: NSRect,
        ruler: NSRulerView,
        containerView: NSView,
        scrollView: NSScrollView,
        language: SyntaxLanguage?,
        onRevert: @escaping () -> Void,
        onNavigate: @escaping (GitHunk) -> Void
    ) {
        close()
        self.containerView = containerView

        let rootView = GitInlineDiffZoneView(
            hunk: hunk,
            allHunks: allHunks,
            currentIndex: currentIndex,
            language: language,
            onRevert: { [weak self] in
                self?.close()
                onRevert()
            },
            onNavigate: { [weak self] targetHunk in
                self?.close()
                onNavigate(targetHunk)
            },
            onClose: { [weak self] in
                self?.close()
            }
        )

        let hosting = NSHostingView(rootView: rootView)
        hosting.wantsLayer = true
        hosting.layer?.masksToBounds = false

        let totalLines = hunk.oldLines.count + hunk.newLines.count
        let estimatedContentHeight = CGFloat(32 + max(1, totalLines) * 20 + 8)
        let zoneHeight = min(360, max(76, estimatedContentHeight))

        let rulerWidth = ruler.bounds.width
        let xPos = rulerWidth
        let width = max(200, scrollView.bounds.width - rulerWidth)

        // anchorRectInRuler is in flipped ruler coordinates.
        let anchorInContainer = containerView.convert(anchorRectInRuler, from: ruler)
        let containerBounds = containerView.bounds

        // If placing below overflows the bottom of the container, position directly above the line.
        let yPos: CGFloat
        if anchorInContainer.maxY + zoneHeight <= containerBounds.height {
            yPos = anchorInContainer.maxY
        } else if anchorInContainer.minY - zoneHeight >= 0 {
            yPos = anchorInContainer.minY - zoneHeight
        } else {
            yPos = max(0, containerBounds.height - zoneHeight)
        }

        hosting.frame = NSRect(x: xPos, y: yPos, width: width, height: zoneHeight)
        hosting.autoresizingMask = [.width]

        containerView.addSubview(hosting)
        self.hostingView = hosting

        // Dismiss immediately if user scrolls the editor viewport
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.close()
        }

        if let window = containerView.window {
            windowResizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.close()
            }
        }
    }

    func close() {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
            self.scrollObserver = nil
        }
        if let windowResizeObserver {
            NotificationCenter.default.removeObserver(windowResizeObserver)
            self.windowResizeObserver = nil
        }
        hostingView?.removeFromSuperview()
        hostingView = nil
        containerView = nil
    }
}

private struct GitInlineDiffZoneView: View {
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
            // Header Bar (VS Code dirty diff peek toolbar)
            HStack(spacing: 8) {
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

                Spacer()

                HStack(spacing: 6) {
                    Button(action: onRevert) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Revert")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3.5)
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
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.96))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.4))
                    .frame(height: 1)
            }

            // Stacked Diff Content Body
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    // Deleted / Previous version lines (red)
                    ForEach(Array(hunk.oldLines.enumerated()), id: \.offset) { idx, line in
                        HStack(alignment: .top, spacing: 0) {
                            Text("\(hunk.oldStart + idx)")
                                .frame(width: 42, alignment: .trailing)
                                .foregroundStyle(Color.red.opacity(0.85))
                                .padding(.trailing, 8)

                            Text("-")
                                .frame(width: 14)
                                .foregroundStyle(Color.red)
                                .fontWeight(.bold)

                            Text(GitDiffView.highlightLine(line, language: language, theme: settings.syntaxTheme))
                                .foregroundStyle(.primary.opacity(0.9))

                            Spacer(minLength: 32)
                        }
                        .font(.system(size: 11.5, design: .monospaced))
                        .padding(.vertical, 2)
                        .padding(.horizontal, 8)
                        .background(Color.red.opacity(0.12))
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(Color.red)
                                .frame(width: 3)
                        }
                    }

                    // Added / Current version lines (green)
                    ForEach(Array(hunk.newLines.enumerated()), id: \.offset) { idx, line in
                        HStack(alignment: .top, spacing: 0) {
                            Text("\(hunk.newStart + idx)")
                                .frame(width: 42, alignment: .trailing)
                                .foregroundStyle(Color.green.opacity(0.85))
                                .padding(.trailing, 8)

                            Text("+")
                                .frame(width: 14)
                                .foregroundStyle(Color.green)
                                .fontWeight(.bold)

                            Text(GitDiffView.highlightLine(line, language: language, theme: settings.syntaxTheme))
                                .foregroundStyle(.primary)

                            Spacer(minLength: 32)
                        }
                        .font(.system(size: 11.5, design: .monospaced))
                        .padding(.vertical, 2)
                        .padding(.horizontal, 8)
                        .background(Color.green.opacity(0.12))
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(Color.green)
                                .frame(width: 3)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.98))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.accentColor)
                .frame(height: 2)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.accentColor.opacity(0.5))
                .frame(height: 1)
        }
        .shadow(color: Color.black.opacity(0.25), radius: 6, x: 0, y: 3)
    }
}
