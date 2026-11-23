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

private struct GitQuickDiffPopoverView: View {
    let hunk: GitHunk
    let allHunks: [GitHunk]
    let currentIndex: Int
    let onRevert: () -> Void
    let onNavigate: (GitHunk) -> Void
    let onClose: () -> Void

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
            // Header Bar
            HStack(spacing: 8) {
                SourceControlIcon(type: .diff, size: 12)
                    .foregroundStyle(Color.accentColor)

                Text(hunkRangeTitle)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary)

                if allHunks.count > 1 {
                    Text("(\(currentIndex + 1) of \(allHunks.count))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: onRevert) {
                    Label("Revert", systemImage: "arrow.uturn.backward")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Revert this change (Undo with ⌘Z)")

                Button {
                    if currentIndex > 0 {
                        onNavigate(allHunks[currentIndex - 1])
                    }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .disabled(currentIndex == 0)
                .help("Previous Change")

                Button {
                    if currentIndex < allHunks.count - 1 {
                        onNavigate(allHunks[currentIndex + 1])
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .disabled(currentIndex >= allHunks.count - 1)
                .help("Next Change")

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Close (Esc)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.85))

            Divider()

            // Content
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    // Deleted lines (red)
                    ForEach(Array(hunk.oldLines.enumerated()), id: \.offset) { idx, line in
                        HStack(alignment: .top, spacing: 0) {
                            Text("\(hunk.oldStart + idx)")
                                .frame(width: 32, alignment: .trailing)
                                .foregroundStyle(.secondary.opacity(0.6))
                                .padding(.trailing, 6)
                            Text("-")
                                .frame(width: 14)
                                .foregroundStyle(Color.red)
                                .fontWeight(.bold)
                            Text(line.isEmpty ? " " : line)
                                .foregroundStyle(.primary.opacity(0.9))
                            Spacer(minLength: 16)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.vertical, 1.5)
                        .padding(.horizontal, 6)
                        .background(Color.red.opacity(0.12))
                    }

                    // Added lines (green)
                    ForEach(Array(hunk.newLines.enumerated()), id: \.offset) { idx, line in
                        HStack(alignment: .top, spacing: 0) {
                            Text("\(hunk.newStart + idx)")
                                .frame(width: 32, alignment: .trailing)
                                .foregroundStyle(.secondary.opacity(0.6))
                                .padding(.trailing, 6)
                            Text("+")
                                .frame(width: 14)
                                .foregroundStyle(Color.green)
                                .fontWeight(.bold)
                            Text(line.isEmpty ? " " : line)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 16)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.vertical, 1.5)
                        .padding(.horizontal, 6)
                        .background(Color.green.opacity(0.12))
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 220)
        }
        .frame(minWidth: 320, maxWidth: 520)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
