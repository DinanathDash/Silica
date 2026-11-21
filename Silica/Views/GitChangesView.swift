import SwiftUI

/// Source control in the sidebar: a message and a button to commit with, the
/// branch, which is a menu of branches to switch to, and buttons to fetch, pull
/// and push it, then the files git reports as changed, those staged for the
/// commit first, the stashes and the branch's history. Selecting a file opens
/// it showing its changes.
struct GitChangesView: View {
    let workspace: WorkspaceModel
    @Bindable var git: GitModel
    @State private var selection: String?
    @State private var isNamingBranch = false
    @State private var isPickingBranch = false
    @State private var newBranchName = ""
    @State private var isNamingStash = false
    @State private var stashMessage = ""

    var body: some View {
        let snapshot = git.snapshot ?? GitStatus.Snapshot()
        VStack(alignment: .leading, spacing: 8) {
            if let pending = snapshot.pending {
                pendingBox(pending, conflicts: snapshot.conflictCount)
                    .padding(.horizontal, 10)
            }
            commitBox(snapshot)
                .padding(.horizontal, 10)
            branchBox(snapshot)
                .padding(.horizontal, 10)
            list(snapshot)
        }
        .padding(.top, 2)
        // Whatever changes the selection, a click or the arrow keys, opens what
        // is selected. A click on the row already selected changes nothing, and
        // is the row's own to act on.
        .onChange(of: selection) { _, id in
            guard let id, !GitHistorySection.select(id, in: workspace),
                  let change = (snapshot.staged + snapshot.unstaged).first(where: { $0.id == id }) else { return }
            workspace.openChanges(change)
        }

    }

    // MARK: Merge or rebase in progress

    /// Says what git stopped in the middle of and what it's waiting for, with
    /// the two ways out.
    private func pendingBox(_ pending: GitPendingOperation, conflicts: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(pendingTitle(pending), systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .symbolRenderingMode(.multicolor)
                .lineLimit(2)
            Text(pendingNote(pending, conflicts: conflicts))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button {
                    workspace.abortPendingOperation()
                } label: {
                    Text("Abort").frame(maxWidth: .infinity)
                }
                .glassButtonStyle()
                .disabled(git.activity != nil)
                .help("Put the files back as they were before the \(pending.kind.command)")
                Button {
                    git.continuePending()
                } label: {
                    HStack(spacing: 4) {
                        if git.activity == .continuing {
                            ProgressView().controlSize(.mini)
                        }
                        Text("Continue")
                    }
                    .frame(maxWidth: .infinity)
                }
                .glassButtonStyle(prominent: true)
                .disabled(!git.canContinuePending)
                .help(conflicts > 0 ? "Settle and stage the conflicts first" : "Go on with the \(pending.kind.command)")
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.orange.opacity(0.12)))
        .accessibilityElement(children: .contain)
    }

    private func pendingTitle(_ pending: GitPendingOperation) -> String {
        switch pending.kind {
        case .merge: return "Merge in progress"
        case .cherryPick: return "Cherry-pick in progress"
        case .revert: return "Revert in progress"
        case .rebase:
            var title = pending.branch.map { "Rebasing \($0)" } ?? "Rebase in progress"
            if let step = pending.step, let count = pending.stepCount { title += " (\(step) of \(count))" }
            return title
        }
    }

    private func pendingNote(_ pending: GitPendingOperation, conflicts: Int) -> String {
        switch conflicts {
        case 0: "No conflicts left. Continue to finish, or abort to go back."
        case 1: "1 file has conflicts. Fix it and stage it, then continue."
        default: "\(conflicts.formatted()) files have conflicts. Fix them and stage them, then continue."
        }
    }

    // MARK: Commit

    private func commitBox(_ snapshot: GitStatus.Snapshot) -> some View {
        // With nothing staged, a commit takes every change, as in VS Code.
        let commitsAll = git.commitsAllChanges && !snapshot.unstaged.isEmpty && snapshot.conflictCount == 0
        return VStack(alignment: .leading, spacing: 6) {
            TextField("Message", text: $git.commitMessage, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .onKeyPress(keys: [.return], phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    git.commit()
                    return .handled
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.primary.opacity(0.07)))
                .accessibilityLabel("Commit message")
            HStack(spacing: 6) {
                Button {
                    git.commit()
                } label: {
                    HStack(spacing: 6) {
                        if git.activity == .committing {
                            ProgressView().controlSize(.small)
                        }
                        Text(commitsAll ? "Commit All" : "Commit")
                    }
                    .frame(maxWidth: .infinity)
                }
                .glassButtonStyle(prominent: true)
                .disabled(!git.canCommit)
                .help(
                    snapshot.conflictCount > 0 ? "Settle the conflicts and stage those files first"
                        : commitsAll ? "Stage every change and commit (⌘↩)" : "Commit the staged changes (⌘↩)"
                )
                // The other thing to do with the changes: put them aside.
                Button {
                    stashMessage = ""
                    isNamingStash = true
                } label: {
                    Image(systemName: "tray.and.arrow.down")
                }
                .glassButtonStyle()
                .disabled(!git.canStash)
                .help("Stash Changes…")
                .accessibilityLabel("Stash Changes")
                .alert("Stash Changes", isPresented: $isNamingStash) {
                    TextField("Message (optional)", text: $stashMessage)
                    Button("Stash") { git.stash(message: stashMessage) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(stashNote)
                }
                Menu {
                    Button("Amend Last Commit") { workspace.amendLastCommit() }
                        .disabled(!git.canAmend)
                    Button("Undo Last Commit") { workspace.undoLastCommit() }
                        .disabled(!git.canUndoCommit)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .glassButtonStyle()
                .fixedSize()
                .help("Amend adds what’s staged to the last commit, with the message here if there is one. Undo takes the last commit back and keeps its changes staged.")
                .accessibilityLabel("More Commit Actions")
            }
            notes(snapshot)
        }
    }

    private var stashNote: String {
        let note = "Puts every change aside, untracked files included, and leaves the files as last committed. Bring them back from Stashes."
        let unsaved = workspace.unsavedFileCount
        guard unsaved > 0 else { return note }
        return note + (unsaved == 1 ? " 1 file has unsaved edits, which stay in its tab." : " \(unsaved.formatted()) files have unsaved edits, which stay in their tabs.")
    }

    /// What a commit made now would take or leave that the lists don't show.
    @ViewBuilder
    private func notes(_ snapshot: GitStatus.Snapshot) -> some View {
        let unsaved = workspace.unsavedFileCount
        let elsewhere = snapshot.stagedElsewhere
        if unsaved > 0 || elsewhere > 0 {
            VStack(alignment: .leading, spacing: 2) {
                if unsaved > 0 {
                    Text(unsaved == 1 ? "1 file has unsaved edits, which a commit leaves out." : "\(unsaved.formatted()) files have unsaved edits, which a commit leaves out.")
                }
                if elsewhere > 0 {
                    Text(elsewhere == 1 ? "1 file staged outside this folder is committed too." : "\(elsewhere.formatted()) files staged outside this folder are committed too.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
        }
    }

    // MARK: Branch

    /// The branch, then what can be done with its remote: Fetch, and Pull and
    /// Push with how many commits each would move, or Publish Branch for a
    /// branch the remote doesn't have yet.
    private func branchBox(_ snapshot: GitStatus.Snapshot) -> some View {
        let branch = snapshot.branch
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                branchMenu(snapshot)
                if git.activity == .switching {
                    ProgressView().controlSize(.mini)
                }
                Spacer(minLength: 0)
                // A connection that has died would otherwise keep the panel
                // busy until Silica quits.
                if git.canCancel {
                    Button("Cancel") { git.cancelActivity() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .help("Stop the push, pull or fetch that’s under way")
                }
                // Why Fetch, Pull and Push are waiting, when nobody pressed anything.
                if git.isFetchingQuietly {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("Fetching…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .help("Checking the remote for new commits, as Silica does every few minutes. Fetch, Pull and Push are available again when it’s done.")
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Fetching in the background")
                }
            }
            .padding(.horizontal, 4)
            if branch.canFetch {
                HStack(spacing: 6) {
                    remoteButton("Fetch", while: .fetching, isEnabled: git.canFetch, help: "Check the remote for new commits") {
                        git.fetch()
                    }
                    if let upstream = branch.upstream {
                        remoteButton(
                            "Pull" + count(branch.behind, "↓"), while: .pulling, isEnabled: git.canPull,
                            help: "Bring in the commits on \(upstream)"
                        ) {
                            git.pull()
                        }
                        remoteButton(
                            "Push" + count(branch.ahead, "↑"), while: .pushing, isEnabled: git.canPush,
                            help: "Send your commits to \(upstream)"
                        ) {
                            git.push()
                        }
                    } else if branch.name != nil {
                        remoteButton(
                            "Publish Branch", while: .pushing, isEnabled: git.canPush,
                            help: "Push to \(branch.remote ?? "the remote") and track it there"
                        ) {
                            git.push()
                        }
                    }
                }
            }
        }
    }

    /// The branch's name, which opens the picker of branches to switch to.
    private func branchMenu(_ snapshot: GitStatus.Snapshot) -> some View {
        let branch = snapshot.branch
        return Button {
            isPickingBranch = true
        } label: {
            HStack(spacing: 4) {
                Label(branch.name ?? "Detached HEAD", systemImage: "arrow.triangle.branch")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(git.activity != nil)
        .help((branch.upstream.map { "Tracks \($0). " } ?? "") + "Click to switch branches.")
        .accessibilityLabel("Branch: \(branch.name ?? "Detached HEAD")")
        .popover(isPresented: $isPickingBranch, arrowEdge: .bottom) {
            GitBranchPicker(workspace: workspace, snapshot: snapshot, dismiss: { isPickingBranch = false }) { name in
                newBranchName = name
                isNamingBranch = true
            }
        }
        .alert("New Branch", isPresented: $isNamingBranch) {
            TextField("Name", text: $newBranchName)
            Button("Create") { git.createBranch(newBranchName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Starts from \(branch.name.map { "“\($0)”" } ?? "the current commit") and switches to it. Uncommitted changes come along.")
        }
    }

    /// " ↓2" after a button's name, when there are commits for it to move.
    private func count(_ commits: Int?, _ arrow: String) -> String {
        guard let commits, commits > 0 else { return "" }
        return " \(arrow)\(commits.formatted())"
    }

    private func remoteButton(
        _ title: String, while activity: GitModel.Activity, isEnabled: Bool, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if git.activity == activity {
                    ProgressView().controlSize(.mini)
                }
                Text(title)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .glassButtonStyle()
        .controlSize(.small)
        .disabled(!isEnabled)
        .help(help)
    }

    // MARK: Files


    private func list(_ snapshot: GitStatus.Snapshot) -> some View {
        List(selection: $selection) {
            if snapshot.staged.isEmpty, snapshot.unstaged.isEmpty {
                Text("No changes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !snapshot.staged.isEmpty {
                Section {
                    rows(snapshot.staged)
                } header: {
                    GitSectionHeader(title: "Staged Changes", count: snapshot.staged.count, actions: [
                        .init(symbol: "minus", name: "Unstage All Changes") { git.unstage(snapshot.staged) },
                    ])
                }
            }
            if !snapshot.unstaged.isEmpty {
                Section {
                    rows(snapshot.unstaged)
                } header: {
                    GitSectionHeader(title: "Changes", count: snapshot.unstaged.count, actions: [
                        .init(symbol: "arrow.uturn.backward", name: "Discard All Changes…") {
                            workspace.discardChanges(snapshot.unstaged)
                        },
                        // Not the files in conflict: staging one says it's settled,
                        // which is for each to be told on its own row.
                        .init(symbol: "plus", name: "Stage All Changes") {
                            git.stage(snapshot.unstaged.filter { $0.status != .conflicted })
                        },
                    ])
                }
            }
            if !snapshot.stashes.isEmpty {
                GitStashSection(workspace: workspace, git: git, stashes: snapshot.stashes, selection: selection)
            }
            if !git.history.isEmpty || git.historyFile != nil {
                GitHistorySection(workspace: workspace, git: git, selection: selection)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
        .environment(\.sidebarRowSize, .small)
        .environment(\.defaultMinListRowHeight, EditorSettings.shared.sidebarFontSize + 11)
        .disabled(git.activity == .committing)
        .environment(\.gitIsBusy, git.activity != nil)
    }

    private func rows(_ changes: [GitChange]) -> some View {
        ForEach(changes) { change in
            GitChangeRow(change: change, workspace: workspace, isSelected: selection == change.id)
                .tag(change.id)
        }
    }
}

extension EnvironmentValues {
    /// git is doing something the panel asked for, so its buttons that would
    /// start something else wait.
    @Entry var gitIsBusy = false
}

/// "Staged Changes" or "Changes", how many, and buttons that act on them all.
private struct GitSectionHeader: View {
    @Environment(\.gitIsBusy) private var isBusy

    struct Action {
        let symbol: String
        let name: String
        let perform: () -> Void
    }

    let title: String
    let count: Int
    let actions: [Action]

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Text(count.formatted())
                .font(.caption2.monospacedDigit())
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(.primary.opacity(0.08)))
            Spacer(minLength: 4)
            ForEach(actions, id: \.name) { action in
                Button(action: action.perform) {
                    Image(systemName: action.symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 18, height: 16)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .help(action.name)
                .accessibilityLabel(action.name)
            }
        }
    }
}

private struct GitChangeRow: View {
    let change: GitChange
    let workspace: WorkspaceModel
    /// Whether this is the list's selected row, as of before a click on it.
    let isSelected: Bool
    @State private var isHovered = false
    @Environment(\.gitIsBusy) private var isBusy

    private var url: URL { workspace.url(forRelativePath: change.path) }
    private var stagingAction: String { change.isStaged ? "Unstage Changes" : "Stage Changes" }
    private var canDiscard: Bool { !change.isStaged && change.status.isDiscardable }
    /// An untracked file has no changes to discard, only itself.
    private var discardAction: String { change.status == .untracked ? "Move to Trash…" : "Discard Changes…" }

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 4) {
                FileIcon(url: url, width: EditorSettings.shared.sidebarIconWidth)
                    .padding(.trailing, 2)
                Text(url.lastPathComponent)
                    .strikethrough(change.status == .deleted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                let folder = (change.path as NSString).deletingLastPathComponent
                if !folder.isEmpty {
                    Text(folder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 4)
            }
            .contentShape(.rect)
            // A click on the row that's already selected changes no selection, so
            // it's the click itself that shows the changes again. Only then: a
            // click that selects the row is acted on once, as a selection. The
            // click is seen here before the selection changes.
            .simultaneousGesture(TapGesture().onEnded {
                if isSelected { workspace.openChanges(change) }
            })
            // Always there, faint until the pointer is on the row: a button shown
            // only under the pointer can't be reached from the keyboard or VoiceOver.
            if canDiscard {
                Button {
                    workspace.discardChanges([change])
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 18, height: 16)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .disabled(isBusy)
                .help(discardAction)
                .accessibilityLabel("\(discardAction): \(url.lastPathComponent)")
            }
            Button(action: toggleStaged) {
                Image(systemName: change.isStaged ? "minus" : "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 16)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .disabled(isBusy)
            .help(stagingAction)
            .accessibilityLabel("\(stagingAction): \(url.lastPathComponent)")
            GitStatusLetter(status: change.status)
        }
        .opacity(change.status == .deleted ? 0.6 : 1)
        .font(.system(size: EditorSettings.shared.sidebarFontSize))
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(stagingAction, action: toggleStaged)
            if canDiscard {
                Button(discardAction) { workspace.discardChanges([change]) }
            }
            Divider()
            Button("Show Changes") { workspace.openChanges(change) }
            Button("Show File History") { workspace.showFileHistory(url) }
            if change.status != .deleted {
                Button("Open File") {
                    workspace.open(url)
                    workspace.buffers[url]?.hideChanges()
                }
                Button("Reveal in Explorer") { workspace.revealInTree(url) }
                Divider()
                Button("Show in Finder") { Finder.reveal(url) }
                Button("Copy Path") { Finder.copyPath(url) }
            }
            Button("Copy Relative Path") { Finder.copyPath(change.path) }
        }
    }

    private func toggleStaged() {
        if change.isStaged {
            workspace.git.unstage([change])
        } else {
            workspace.stage(change)
        }
    }
}

/// A file's git status as a colored letter, on the trailing edge of its row.
struct GitStatusLetter: View {
    let status: GitFileStatus

    var body: some View {
        Text(status.letter)
            .font(.system(size: EditorSettings.shared.sidebarFontSize - 1, weight: .semibold, design: .rounded))
            .foregroundStyle(status.color)
            .frame(minWidth: 12)
            .help(status.label)
            .accessibilityLabel(status.label)
    }
}

extension GitFileStatus {
    /// The letters VS Code and Cursor use.
    var letter: String {
        switch self {
        case .modified: "M"
        case .added: "A"
        case .renamed: "R"
        case .untracked: "U"
        case .deleted: "D"
        case .conflicted: "!"
        }
    }

    var label: String {
        switch self {
        case .modified: "Modified"
        case .added: "Added"
        case .renamed: "Renamed"
        case .untracked: "Untracked"
        case .deleted: "Deleted"
        case .conflicted: "Merge conflict"
        }
    }

    var color: Color {
        switch self {
        case .modified: .orange
        case .added, .renamed, .untracked: .green
        case .deleted, .conflicted: .red
        }
    }
}
