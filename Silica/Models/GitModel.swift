import AppKit
import Observation

/// A project's repository as the sidebar shows it: its status, kept up to date
/// for the explorer tree's badges and the Changes panel, and the panel's staging,
/// commits, pushes, fetches, pulls and branch switches.
@Observable
final class GitModel {
    enum Activity {
        case staging
        case committing
        case pushing
        case fetching
        case pulling
        case switching
        case discarding
        case stashing
        case continuing
        case aborting
    }

    /// An operation git refused or failed at, with what it said.
    struct Failure {
        let title: String
        let details: String
    }

    /// `nil` when the project isn't in a git repository (or git isn't installed).
    private(set) var snapshot: GitStatus.Snapshot?
    /// What the panel is doing to the repository; one thing at a time.
    private(set) var activity: Activity?
    /// The message for the next commit. Kept here so it's still there after the
    /// sidebar has shown something else.
    var commitMessage = ""
    /// The current branch's latest commits, newest first.
    private(set) var history: [GitCommit] = []
    /// The commit HEAD is at and the one before it, whatever `history` lists: with
    /// one file's history shown, that isn't the branch's last commits.
    private(set) var lastCommits: [GitCommit] = []
    /// The files of the commits that have been opened in the history, by hash.
    private(set) var commitFiles: [String: [GitCommitFile]] = [:]
    /// To list only the commits that changed one file: its path in the project.
    var historyFile: String? {
        didSet {
            guard historyFile != oldValue else { return }
            historyLimit = Self.historyPage
            reloadHistoryIfNeeded()
        }
    }
    /// What the history shows opened, kept while the sidebar shows something else.
    var isHistoryExpanded = true
    var expandedCommits: Set<String> = []
    /// Called after `snapshot` changes.
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onFailure: ((Failure) -> Void)?

    @ObservationIgnored private let rootURL: URL
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// The project changed again while git was running.
    @ObservationIgnored private var isStale = false

    /// What the history depends on: it's read again when any of this changes.
    private struct HistoryKey: Equatable {
        var head: String?
        var upstream: String?
        var ahead: Int?
        var limit: Int
        var file: String?
    }

    private static let historyPage = 50
    @ObservationIgnored private var historyLimit = GitModel.historyPage
    @ObservationIgnored private var historyKey: HistoryKey?
    @ObservationIgnored private var historyTask: Task<Void, Never>?

    var isRepository: Bool { snapshot != nil }

    init(rootURL: URL) {
        self.rootURL = rootURL
        refresh()
        fetchTask = Task { [weak self] in
            // Soon after the project opens, then every few minutes.
            var wait = Duration.seconds(15)
            while !Task.isCancelled {
                // Cancelling ends the sleep at once, and a fetch mustn't follow it:
                // the window this was for has closed.
                try? await Task.sleep(for: wait)
                wait = .seconds(300)
                guard !Task.isCancelled, let self else { return }
                self.fetchQuietly()
            }
        }
    }

    /// When the project's window closes.
    func stop() {
        fetchTask?.cancel()
        fetchTask = nil
        // git doesn't go on pushing or fetching for a window that's gone. Only
        // that: a commit waiting on its hook, a stash or a rebase step was asked
        // for and is left to finish, not cut off halfway.
        if canCancel { cancellation?.cancel() }
        quietFetchCancellation?.cancel()
    }

    /// For the operation under way, and for the periodic fetch.
    @ObservationIgnored private var cancellation: GitCancellation?
    @ObservationIgnored private var quietFetchCancellation: GitCancellation?

    /// Whether what git is doing can be called off: talking to a remote, which
    /// can take long or never end on a connection that has died.
    var canCancel: Bool {
        activity == .pushing || activity == .pulling || activity == .fetching
    }

    /// Stops the push, pull or fetch under way. Nothing is said of its failing.
    func cancelActivity() {
        guard canCancel else { return }
        cancellation?.cancel()
    }

    @ObservationIgnored private var fetchTask: Task<Void, Never>?

    /// The periodic fetch: only while Silica is in front and nothing else is
    /// going on, and without a word if the remote can't be reached.
    /// It isn't an `activity`: a fetch nobody asked for mustn't be why a click
    /// on Stage or a confirmed Discard does nothing. It only changes what is known
    /// of the remote, so the panel's other work can go on beside it; Fetch, Pull
    /// and Push, which do the same, wait for it.
    private func fetchQuietly() {
        guard EditorSettings.shared.fetchesAutomatically, NSApp.isActive, canFetch,
              snapshot?.pending == nil, let branch = snapshot?.branch else { return }
        isFetchingQuietly = true
        let root = rootURL
        let remote = branch.upstream == nil ? branch.remote : nil
        let cancellation = GitCancellation()
        quietFetchCancellation = cancellation
        Task { [weak self] in
            // Given up on after a minute: Fetch, Pull and Push wait for this.
            _ = await Task.detached(priority: .utility) {
                GitCancellation.$current.withValue(cancellation) {
                    Git.perform(["fetch"] + (remote.map { [$0] } ?? []), in: root, timeout: Self.quietFetchTimeout)
                }
            }.value
            self?.quietFetchCancellation = nil
            self?.isFetchingQuietly = false
            self?.refresh()
        }
    }

    /// The periodic fetch is under way.
    private(set) var isFetchingQuietly = false
    private nonisolated static let quietFetchTimeout: TimeInterval = 60

    /// Nothing the panel asked git for is still running.
    var isIdle: Bool { activity == nil }

    /// Says that what was just asked for can't start yet.
    func reportBusy() {
        onFailure?(Failure(
            title: "git is still busy.",
            details: "Another git operation hasn’t finished. Try again when it has."
        ))
    }

    /// Asks git again, after a short wait so a burst of changes (a build, a
    /// checkout) costs one run. Only one git runs at a time; changes that arrive
    /// meanwhile are picked up by a second run after it.
    func refresh() {
        guard refreshTask == nil else {
            isStale = true
            return
        }
        let root = rootURL
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            while true {
                self?.isStale = false
                let snapshot = await Task.detached(priority: .utility) { GitStatus.load(root: root) }.value
                guard let self else { return }
                self.apply(snapshot)
                if !self.isStale { break }
            }
            self?.refreshTask = nil
        }
    }

    /// Returns whether the snapshot changed, in which case `onChange` was called.
    @discardableResult
    private func apply(_ snapshot: GitStatus.Snapshot?) -> Bool {
        guard snapshot != self.snapshot else { return false }
        self.snapshot = snapshot
        reloadHistoryIfNeeded()
        onChange?()
        return true
    }

    // MARK: History

    /// Reads who last changed each line of a file, off the main actor.
    func blame(of path: String) async -> [GitBlameLine] {
        let root = rootURL
        return await Task.detached(priority: .utility) { GitHistory.blame(of: path, root: root) }.value
    }

    /// Whether there may be commits older than those listed.
    var hasMoreHistory: Bool { history.count >= historyLimit }

    func showMoreHistory() {
        historyLimit += Self.historyPage
        reloadHistoryIfNeeded()
    }

    /// Opens or closes a commit in the history, reading its files the first time.
    func toggleExpanded(_ commit: GitCommit) {
        if expandedCommits.contains(commit.hash) {
            expandedCommits.remove(commit.hash)
        } else {
            expand(commit)
        }
    }

    func expand(_ commit: GitCommit) {
        expandedCommits.insert(commit.hash)
        guard commitFiles[commit.hash] == nil else { return }
        let root = rootURL
        let hash = commit.hash
        Task { [weak self] in
            let files = await Task.detached(priority: .userInitiated) { GitHistory.files(of: hash, root: root) }.value
            self?.commitFiles[hash] = files
        }
    }

    /// The commits only change when HEAD moves, and which of them are unpushed
    /// when the branch gets further ahead of its upstream or less far.
    private func reloadHistoryIfNeeded() {
        let branch = snapshot?.branch
        let key = HistoryKey(
            head: branch?.head, upstream: branch?.upstream, ahead: branch?.ahead, limit: historyLimit, file: historyFile
        )
        guard key != historyKey else { return }
        historyKey = key
        historyTask?.cancel()
        guard key.head != nil else {
            history = []
            lastCommits = []
            return
        }
        let root = rootURL
        let limit = historyLimit
        let isAhead = (key.ahead ?? 0) > 0
        let file = historyFile
        historyTask = Task { [weak self] in
            let (commits, last) = await Task.detached(priority: .utility) {
                let commits = GitHistory.load(root: root, limit: limit, markingUnpushed: isAhead, file: file)
                // One file's commits say nothing of where the branch is.
                let last = file == nil ? Array(commits.prefix(2))
                    : GitHistory.load(root: root, limit: 2, markingUnpushed: isAhead)
                return (commits, last)
            }.value
            guard let self, !Task.isCancelled, self.historyKey == key else { return }
            if last != self.lastCommits { self.lastCommits = last }
            if commits != self.history { self.history = commits }
        }
    }

    // MARK: Staging

    func stage(_ changes: [GitChange]) {
        guard !changes.isEmpty else { return }
        perform(.stage(changes.map(\.path)), as: .staging, failure: "Couldn’t stage the changes.")
    }

    func unstage(_ changes: [GitChange]) {
        guard !changes.isEmpty, let snapshot else { return }
        // A renamed file is two changes in the index: one at each path.
        let paths = changes.flatMap { change in
            [change.path] + (change.status == .renamed ? [snapshot.renamedFrom[change.path]].compactMap(\.self) : [])
        }
        perform(
            .unstage(paths, hasCommits: snapshot.branch.hasCommits),
            as: .staging, failure: "Couldn’t unstage the changes."
        )
    }

    /// Stages or unstages one change in a file: `content` is what the index is to
    /// hold for it afterwards.
    func setIndexContent(of path: String, to content: Data) {
        perform(.setIndexContent(path: path, content: content), as: .staging, failure: "Couldn’t stage the change.")
    }

    /// Undoes the unstaged edits to, and deletions of, tracked files. There is no
    /// getting them back, so the caller asks first.
    func discard(_ paths: [String], onSuccess: @escaping () -> Void) {
        guard !paths.isEmpty else { return }
        perform(.discard(paths), as: .discarding, failure: "Couldn’t discard the changes.", onSuccess: onSuccess)
    }

    // MARK: Merge or rebase in progress

    /// Whether a merge or rebase can go on: its conflicts are settled and staged.
    var canContinuePending: Bool {
        guard let snapshot, activity == nil, snapshot.pending != nil else { return false }
        return snapshot.conflictCount == 0
    }

    /// Finishes the merge, or takes the rebase to its next stop or its end.
    func continuePending() {
        guard canContinuePending, let kind = snapshot?.pending?.kind else { return }
        perform(.continuePending(kind), as: .continuing, failure: "Couldn’t finish the \(kind.command).")
    }

    /// Calls it off. What was settled so far is lost, so the caller asks first.
    func abortPending(onSuccess: @escaping () -> Void) {
        guard activity == nil, let kind = snapshot?.pending?.kind else { return }
        perform(.abortPending(kind), as: .aborting, failure: "Couldn’t abort the \(kind.command).", onSuccess: onSuccess)
    }

    // MARK: Stashes

    var canStash: Bool {
        guard let snapshot, activity == nil, snapshot.branch.hasCommits else { return false }
        return !snapshot.staged.isEmpty || !snapshot.unstaged.isEmpty
    }

    /// Puts every change aside, under `message` if there is one.
    func stash(message: String) {
        guard canStash else { return }
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        perform(.stash(message: message.isEmpty ? nil : message), as: .stashing, failure: "Couldn’t stash the changes.")
    }

    /// Brings a stash's changes back. `keeping` leaves the stash in the list.
    func apply(_ stash: GitStash, keeping: Bool) {
        perform(
            keeping ? .applyStash(hash: stash.commit.hash) : .popStash(stash),
            as: .stashing, failure: "Couldn’t apply the stash."
        )
    }

    /// Deletes a stash for good, so the caller asks first.
    func drop(_ stash: GitStash) {
        perform(.dropStash(stash), as: .stashing, failure: "Couldn’t drop the stash.")
    }

    // MARK: Commit

    /// Whether `commit()` takes every change in the project: nothing is staged, as
    /// when the index is left alone.
    var commitsAllChanges: Bool {
        guard let snapshot else { return false }
        return snapshot.staged.isEmpty && snapshot.stagedElsewhere == 0
    }

    /// Not while a file is in conflict: committing everything would stage it as
    /// it is, markers and all, and git would take the conflict as settled.
    var canCommit: Bool {
        guard let snapshot, activity == nil, snapshot.conflictCount == 0 else { return false }
        let hasChanges = !snapshot.staged.isEmpty || !snapshot.unstaged.isEmpty || snapshot.stagedElsewhere > 0
        return hasChanges && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Commits what is staged, or every change when nothing is.
    func commit() {
        guard canCommit else { return }
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        perform(
            .commit(message: message, stagingAll: commitsAllChanges),
            as: .committing, failure: "Couldn’t commit."
        ) { [weak self] in
            // Unless a new message was begun while the hooks ran.
            if self?.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines) == message {
                self?.commitMessage = ""
            }
        }
    }

    /// Whether the last commit is already on the branch's upstream: changing it
    /// then leaves a branch that can't be pushed without forcing.
    var lastCommitIsPushed: Bool {
        snapshot?.branch.upstream != nil && lastCommits.first?.isUnpushed == false
    }

    var canAmend: Bool {
        guard let snapshot, activity == nil, snapshot.pending == nil, !lastCommits.isEmpty else { return false }
        return !snapshot.staged.isEmpty || !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Adds what is staged to the last commit, and gives it the message in the
    /// field if there is one.
    func amend() {
        guard canAmend else { return }
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        perform(.amend(message: message.isEmpty ? nil : message), as: .committing, failure: "Couldn’t amend the commit.") { [weak self] in
            if self?.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines) == message { self?.commitMessage = "" }
        }
    }

    /// The first commit of a repository has nothing before it to go back to.
    var canUndoCommit: Bool {
        activity == nil && snapshot?.pending == nil && lastCommits.count >= 2
    }

    /// Takes the last commit back: its changes are staged again, and its message
    /// is in the field unless another has been begun.
    func undoLastCommit() {
        guard canUndoCommit, let commit = lastCommits.first else { return }
        perform(.undoLastCommit, as: .committing, failure: "Couldn’t undo the commit.") { [weak self] in
            guard let self, self.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            self.commitMessage = commit.body.isEmpty ? commit.subject : commit.subject + "\n\n" + commit.body
        }
    }

    // MARK: Push

    var canPush: Bool { activity == nil && !isFetchingQuietly && snapshot?.branch.canPush == true }

    func push() {
        guard canPush, let branch = snapshot?.branch, let name = branch.name else { return }
        var publishing: (remote: String, branch: String)?
        if branch.upstream == nil {
            guard let remote = branch.remote else { return }
            publishing = (remote, name)
        }
        perform(.push(publishing: publishing), as: .pushing, failure: "Couldn’t push “\(name)”.")
    }

    // MARK: Fetch and pull

    var canFetch: Bool { activity == nil && !isFetchingQuietly && snapshot?.branch.canFetch == true }

    /// Asks the remote what's new, which is what tells how far behind the branch is.
    func fetch() {
        guard canFetch, let branch = snapshot?.branch else { return }
        perform(.fetch(remote: branch.upstream == nil ? branch.remote : nil), as: .fetching, failure: "Couldn’t fetch.")
    }

    var canPull: Bool { activity == nil && !isFetchingQuietly && snapshot?.branch.canPull == true }

    func pull() {
        guard canPull, let name = snapshot?.branch.name else { return }
        perform(.pull, as: .pulling, failure: "Couldn’t pull “\(name)”.")
    }

    // MARK: Branches

    /// Checks out a local branch. git refuses when that would overwrite
    /// uncommitted changes, and says which.
    func switchTo(_ branch: String) {
        guard branch != snapshot?.branch.name else { return }
        perform(.switchTo(branch), as: .switching, failure: "Couldn’t switch to “\(branch)”.")
    }

    /// Checks out a remote's branch ("origin/topic") as a new local one that tracks it.
    func track(_ remoteBranch: String) {
        perform(.track(remoteBranch), as: .switching, failure: "Couldn’t switch to “\(remoteBranch)”.")
    }

    /// Starts a branch here and switches to it.
    func createBranch(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        perform(.create(name), as: .switching, failure: "Couldn’t create the branch “\(name)”.")
    }

    /// Deletes a local branch, which the caller asks about first. Without `force`,
    /// git refuses one whose commits aren't merged anywhere.
    func deleteBranch(_ name: String, force: Bool) {
        perform(.deleteBranch(name, force: force), as: .switching, failure: "Couldn’t delete the branch “\(name)”.")
    }

    func renameBranch(_ name: String, to newName: String) {
        let newName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != name else { return }
        perform(.renameBranch(name, to: newName), as: .switching, failure: "Couldn’t rename the branch “\(name)”.")
    }

    /// Merges a branch into the current one. Conflicts leave the merge in
    /// progress, for the panel's banner to continue or abort.
    func merge(_ name: String) {
        perform(.merge(name), as: .switching, failure: "Couldn’t finish merging “\(name)”.")
    }

    /// Runs `operation` off the main actor and then reads the status again, so the
    /// panel shows the result as soon as it's no longer busy.
    private func perform(
        _ operation: GitOperation, as activity: Activity, failure title: String, reportsFailure: Bool = true,
        onSuccess: (() -> Void)? = nil
    ) {
        guard self.activity == nil else {
            // Not dropped without a word: this was asked for, perhaps in a sheet
            // that was up while something else began.
            if reportsFailure { reportBusy() }
            return
        }
        self.activity = activity
        let root = rootURL
        let cancellation = GitCancellation()
        self.cancellation = cancellation
        Task { [weak self] in
            let (outcome, snapshot) = await Task.detached(priority: .userInitiated) {
                let outcome = GitCancellation.$current.withValue(cancellation) { operation.run(in: root) }
                return (outcome, GitStatus.load(root: root))
            }.value
            guard let self else { return }
            self.cancellation = nil
            // The snapshot can come out the same after a real change: a file that
            // was partly staged still is with more of it staged. Whoever shows
            // what's in the index has to look again all the same.
            if !self.apply(snapshot) { self.onChange?() }
            self.activity = nil
            if outcome.succeeded {
                onSuccess?()
            } else if reportsFailure, !cancellation.isCancelled {
                // Called off, it didn't fail: there's nothing to tell.
                self.onFailure?(Failure(title: title, details: outcome.output))
            }
            // What a refresh already under way read may be from before this.
            self.refresh()
        }
    }
}
