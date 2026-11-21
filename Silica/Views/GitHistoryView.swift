import SwiftUI

/// The current branch's commits at the end of the Changes list, newest first.
/// A commit opens to who made it and when, the rest of its message and the files
/// it changed; selecting a file shows what the commit did to it.
struct GitHistorySection: View {
    let workspace: WorkspaceModel
    @Bindable var git: GitModel
    /// The list's selection, for the rows to know a click on the selected one.
    let selection: String?

    var body: some View {
        Section(isExpanded: $git.isHistoryExpanded) {
            ForEach(git.history) { commit in
                GitCommitRow(commit: commit, git: git)
                    .tag(GitHistorySection.id(of: commit))
                if git.expandedCommits.contains(commit.hash) {
                    GitCommitDetails(commit: commit)
                    GitCommitFiles(commit: commit, workspace: workspace, selection: selection)
                }
            }
            if git.hasMoreHistory {
                Button("Show Older Commits") {
                    git.showMoreHistory()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 18)
            }
            if git.history.isEmpty, git.historyFile != nil {
                Text("No commits have changed this file")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            if let file = git.historyFile {
                // The commits that changed one file, until this is closed.
                HStack(spacing: 6) {
                    Text("History: \((file as NSString).lastPathComponent)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button {
                        git.historyFile = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 18, height: 16)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("Show the Branch’s History")
                    .accessibilityLabel("Show the Branch’s History")
                }
            } else {
                Text("History")
            }
        }
    }

    // MARK: Selection

    /// A commit row's tag in the list's selection, apart from the changed files'
    /// and from the tags of the files in it.
    static func id(of commit: GitCommit) -> String { "commit:" + commit.hash }

    /// Acts on a selection in the history; false if `id` isn't one of its rows.
    static func select(_ id: String, in workspace: WorkspaceModel) -> Bool {
        let git = workspace.git
        if id.hasPrefix("commit:") {
            if let commit = git.history.first(where: { Self.id(of: $0) == id }) { git.expand(commit) }
            return true
        }
        if id.hasPrefix("stash:") {
            if let stash = git.snapshot?.stashes.first(where: { GitStashSection.id(of: $0) == id }) {
                git.expand(stash.commit)
            }
            return true
        }
        guard id.hasPrefix("commit-file:") else { return false }
        let commits = git.history + (git.snapshot?.stashes.map(\.commit) ?? [])
        for commit in commits where id.hasPrefix("commit-file:" + commit.hash + ":") {
            if let file = git.commitFiles[commit.hash]?.first(where: { $0.id == id }) {
                workspace.openChanges(file, in: commit)
            }
        }
        return true
    }
}

/// The changes put aside with `git stash`, newest first, between the changes and
/// the history. A stash opens to the files it holds changes to, like a commit;
/// its buttons bring the changes back or delete them.
struct GitStashSection: View {
    let workspace: WorkspaceModel
    let git: GitModel
    let stashes: [GitStash]
    let selection: String?

    var body: some View {
        Section {
            ForEach(stashes) { stash in
                GitStashRow(stash: stash, workspace: workspace)
                    .tag(GitStashSection.id(of: stash))
                if git.expandedCommits.contains(stash.commit.hash) {
                    Text("\(stash.commit.date.formatted(date: .abbreviated, time: .shortened)) · \(stash.commit.shortHash)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 34)
                    GitCommitFiles(commit: stash.commit, workspace: workspace, selection: selection)
                }
            }
        } header: {
            Text("Stashes")
        }
    }

    static func id(of stash: GitStash) -> String { "stash:" + stash.commit.hash }
}

private struct GitStashRow: View {
    let stash: GitStash
    let workspace: WorkspaceModel
    @State private var isHovered = false

    private var git: GitModel { workspace.git }

    var body: some View {
        let isExpanded = git.expandedCommits.contains(stash.commit.hash)
        HStack(spacing: 4) {
            Button {
                git.toggleExpanded(stash.commit)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12, height: 16)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Hide Files" : "Show Files")
            Text(stash.commit.subject.isEmpty ? "(no message)" : stash.commit.subject)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 4)
            // The subject takes the room first, so the date has to refuse to
            // shrink or a long subject squeezes it down to a clipped digit.
            Text(stash.commit.date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            Button {
                git.apply(stash, keeping: false)
            } label: {
                Image(systemName: "tray.and.arrow.up")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 16)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .help("Pop Stash: bring the changes back and remove the stash")
            .accessibilityLabel("Pop Stash: \(stash.commit.subject)")
        }
        .font(.system(size: EditorSettings.shared.sidebarFontSize))
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .disabled(git.activity != nil)
        .contextMenu {
            Button("Pop Stash") { git.apply(stash, keeping: false) }
            Button("Apply Stash") { git.apply(stash, keeping: true) }
            Divider()
            Button("Drop Stash…") { workspace.dropStash(stash) }
        }
    }
}

/// The files of an opened commit or stash, once they've been read.
private struct GitCommitFiles: View {
    let commit: GitCommit
    let workspace: WorkspaceModel
    let selection: String?

    var body: some View {
        if let files = workspace.git.commitFiles[commit.hash] {
            if files.isEmpty {
                note("No files changed in this folder")
            }
            ForEach(files) { file in
                GitCommitFileRow(file: file, workspace: workspace, isSelected: selection == file.id)
                    .tag(file.id)
            }
        } else {
            note("Loading…")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 34)
    }
}

/// One line for a commit: a mark for whether it has been pushed, the first line
/// of its message, and how long ago it was made.
private struct GitCommitRow: View {
    let commit: GitCommit
    let git: GitModel

    var body: some View {
        let isExpanded = git.expandedCommits.contains(commit.hash)
        HStack(spacing: 4) {
            Button {
                git.toggleExpanded(commit)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12, height: 16)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Hide Details" : "Show Details")
            Circle()
                .fill(commit.isUnpushed ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .frame(width: 6, height: 6)
                .padding(.horizontal, 2)
                .help(commit.isUnpushed ? "Not pushed yet" : "")
                .accessibilityLabel(commit.isUnpushed ? "Not pushed yet" : "")
            Text(commit.subject.isEmpty ? "(no message)" : commit.subject)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 4)
            // As in the stash row: keep the date whole beside a long subject.
            Text(commit.date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .font(.system(size: EditorSettings.shared.sidebarFontSize))
        .contextMenu {
            Button("Copy Commit Hash") { Finder.copyPath(commit.hash) }
            Button("Copy Message") {
                Finder.copyPath(commit.body.isEmpty ? commit.subject : commit.subject + "\n\n" + commit.body)
            }
        }
    }
}

/// Under an opened commit: who and when, its short hash, and the rest of the message.
private struct GitCommitDetails: View {
    let commit: GitCommit

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(commit.author) · \(commit.date.formatted(date: .abbreviated, time: .shortened)) · \(commit.shortHash)")
                .lineLimit(2)
            if !commit.body.isEmpty {
                Text(commit.body)
                    .lineLimit(8)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        .padding(.leading, 34)
        .padding(.vertical, 1)
    }
}

private struct GitCommitFileRow: View {
    let file: GitCommitFile
    let workspace: WorkspaceModel
    let isSelected: Bool

    private var url: URL { workspace.url(forRelativePath: file.path) }

    var body: some View {
        HStack(spacing: 4) {
            FileIcon(url: url, width: EditorSettings.shared.sidebarIconWidth)
                .padding(.trailing, 2)
            Text(url.lastPathComponent)
                .strikethrough(file.status == .deleted)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            let folder = (file.path as NSString).deletingLastPathComponent
            if !folder.isEmpty {
                Text(folder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            GitStatusLetter(status: file.status)
        }
        .font(.system(size: EditorSettings.shared.sidebarFontSize))
        .padding(.leading, 30)
        .contentShape(.rect)
        // As in the list of changes: a click on the row already selected shows
        // it again; one that selects it is acted on as a selection.
        .simultaneousGesture(TapGesture().onEnded {
            if isSelected { _ = GitHistorySection.select(file.id, in: workspace) }
        })
        .contextMenu {
            Button("Show File History") { workspace.showFileHistory(url) }
            Button("Copy Relative Path") { Finder.copyPath(file.path) }
        }
    }
}
