import AppKit
import Foundation
import Observation
import SwiftUI

/// State for one open project window: the explorer tree and the open editor tabs.
@Observable
final class WorkspaceModel {
    let rootURL: URL
    let root: FileNode

    var selection: URL?
    /// The last file asked to be shown in the tree; `revealCount` changes on every
    /// request so the tree scrolls even when the same file is revealed twice.
    private(set) var revealedURL: URL?
    private(set) var revealCount = 0
    var isSidebarVisible = true
    /// What the sidebar shows: the file tree, Find in Project or the changed files.
    var sidebarMode: SidebarMode = .explorer
    let search: ProjectSearchModel
    /// The project's git status: the badges on the tree's rows and the Changes list.
    let git: GitModel
    /// A rename or new file/folder name being typed in the tree.
    var treeEdit: TreeEdit?

    /// Text in the explorer's filter field; the tree shows only matching names.
    var treeFilter = "" {
        didSet { if treeFilter != oldValue { scheduleTreeFilter() } }
    }
    /// Project-relative paths the filtered tree shows; `nil` when not filtering.
    private(set) var treeFilterResult: TreeFilter.Result?
    /// Bumped to put the cursor in the filter field (⌥⌘J).
    var treeFilterFocusRequest = 0
    @ObservationIgnored private var treeFilterItems: [QuickOpenItem]?
    @ObservationIgnored private var treeFilterTask: Task<Void, Never>?
    private(set) var isQuickOpenVisible = false
    let quickOpen: QuickOpenModel
    private(set) var openTabs: [URL] = [] {
        didSet { scheduleSessionSave() }
    }
    private(set) var activeTab: URL? {
        didSet { scheduleSessionSave() }
    }
    private(set) var buffers: [URL: EditorBuffer] = [:]

    /// The project's terminals, in the order of their tabs. They keep running while
    /// their card is hidden.
    private(set) var terminals: [TerminalSession] = []
    /// The terminal the card shows: one of `terminals`, as long as there are any.
    private(set) var terminal: TerminalSession?
    private(set) var isTerminalVisible = false

    /// The project's window, to bring forward when a file is opened in it from outside.
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var isAccessingScope: Bool
    @ObservationIgnored private var watcher: ProjectWatcher?
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored private var isRestoringSession = false
    @ObservationIgnored private var sessionSaveTask: Task<Void, Never>?

    var name: String { root.name }

    var activeBuffer: EditorBuffer? {
        activeTab.flatMap { buffers[$0] }
    }

    var hasUnsavedChanges: Bool {
        buffers.values.contains { $0.needsSaving }
    }

    init(rootURL: URL) {
        self.rootURL = rootURL
        self.isAccessingScope = rootURL.startAccessingSecurityScopedResource()
        self.root = FileNode(root: rootURL)
        self.quickOpen = QuickOpenModel(rootURL: rootURL)
        self.search = ProjectSearchModel(rootURL: rootURL)
        self.git = GitModel(rootURL: rootURL)
        root.isExpanded = true
        root.loadChildrenIfNeeded()
        search.unsavedTexts = { [weak self] in
            guard let self else { return [:] }
            var texts: [URL: String] = [:]
            for (url, buffer) in self.buffers where buffer.isDirty && !buffer.isUntitled {
                texts[url] = buffer.textController?.textView.string
            }
            return texts
        }
        // Keep the tree and open files in step with changes made by other apps.
        watcher = ProjectWatcher(url: rootURL) { [weak self] in
            self?.refresh()
        } onGitChange: { [weak self] in
            self?.git.refresh()
        }
        git.onChange = { [weak self] in
            guard let self else { return }
            self.refreshShownChanges()
            // The button that leaves the Changes list goes away with the repository.
            if !self.git.isRepository, self.sidebarMode == .changes { self.sidebarMode = .explorer }
        }
        git.onFailure = { [weak self] failure in
            self?.present(failure)
        }
        restoreSession()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveSession() }
        }
    }

    func close() {
        saveSession()
        // A video left playing would still be heard with its window gone.
        for buffer in buffers.values { buffer.pausePlayback() }
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
        watcher?.stop()
        watcher = nil
        git.stop()
        for terminal in terminals { terminal.close() }
        terminals = []
        terminal = nil
        if isAccessingScope {
            rootURL.stopAccessingSecurityScopedResource()
            isAccessingScope = false
        }
    }

    // MARK: Explorer

    func handleSelectionChange() {
        guard let url = selection else { return }
        if url.hasDirectoryPath {
            if let node = node(for: url) { toggleExpansion(of: node) }
        } else {
            open(url)
        }
    }

    func toggleExpansion(of node: FileNode) {
        withAnimation(.snappy(duration: 0.2)) { node.isExpanded.toggle() }
    }

    /// Expands or collapses the selected folder; returns `false` if nothing changed.
    func setSelectedFolderExpanded(_ expanded: Bool) -> Bool {
        guard let url = selection, url.hasDirectoryPath, let node = node(for: url),
              node.isExpanded != expanded else { return false }
        toggleExpansion(of: node)
        return true
    }

    func toggleSidebar() {
        withAnimation(.snappy) { isSidebarVisible.toggle() }
    }

    // MARK: Terminal

    /// ⌃`: shows the terminal and gives it the keyboard. From the terminal, hides it
    /// and goes back to the editor.
    func toggleTerminal() {
        if isTerminalVisible, terminal?.isFocused == true {
            hideTerminal()
        } else {
            showTerminal()
        }
    }

    func showTerminal() {
        let terminal = terminal ?? makeTerminal()
        if !isTerminalVisible {
            withAnimation(.snappy(duration: 0.2)) { isTerminalVisible = true }
        }
        terminal.view.focus()
    }

    /// Hides the card. The shells and whatever runs in them carry on.
    func hideTerminal() {
        guard isTerminalVisible else { return }
        let hadFocus = terminal?.isFocused == true
        withAnimation(.snappy(duration: 0.2)) { isTerminalVisible = false }
        if hadFocus { focusEditor() }
    }

    /// New Terminal (⌃⇧`): another shell, in a tab after the ones there are.
    func newTerminal() {
        makeTerminal()
        showTerminal()
    }

    /// Brings a terminal's tab forward and gives it the keyboard.
    func selectTerminal(_ terminal: TerminalSession) {
        guard terminals.contains(where: { $0 === terminal }) else { return }
        self.terminal = terminal
        showTerminal()
    }

    /// The terminal `offset` tabs along from the one that's showing, going round
    /// from either end to the other.
    func selectTerminal(offsetBy offset: Int) {
        let count = terminals.count
        guard count > 1, let index = terminals.firstIndex(where: { $0 === terminal }) else { return }
        selectTerminal(terminals[((index + offset) % count + count) % count])
    }

    /// Puts a terminal's tab at another place in the row (dragging it there).
    func moveTerminal(_ terminal: TerminalSession, to index: Int) {
        guard let current = terminals.firstIndex(where: { $0 === terminal }) else { return }
        let target = min(max(index, 0), terminals.count - 1)
        guard target != current else { return }
        var moved = terminals
        moved.remove(at: current)
        moved.insert(terminal, at: target)
        terminals = moved
    }

    /// Select Next Tab / Select Previous Tab: through the terminal's tabs when the
    /// terminal has the keyboard and others beside it, and the editor's otherwise.
    func selectTab(offsetBy offset: Int) {
        if terminals.count > 1, isTerminalVisible, terminal?.isFocused == true {
            selectTerminal(offsetBy: offset)
        } else {
            activateTab(offsetBy: offset)
        }
    }

    /// Whether Select Next Tab and Select Previous Tab have another tab to go to.
    var canSelectOtherTab: Bool {
        openTabs.count > 1 || (terminals.count > 1 && isTerminalVisible && terminal?.isFocused == true)
    }

    /// Ends a terminal's shell and closes its tab: the one that's showing, unless
    /// another is named. Its neighbor takes its place; without one the card goes,
    /// and the next ⌃` starts a new shell.
    func closeTerminal(_ closing: TerminalSession? = nil) {
        guard let closing = closing ?? terminal,
              let index = terminals.firstIndex(where: { $0 === closing }) else { return }
        let hadFocus = closing.isFocused
        terminals.remove(at: index)
        if closing === terminal {
            terminal = terminals.isEmpty ? nil : terminals[min(index, terminals.count - 1)]
            if let terminal {
                if hadFocus { terminal.view.focus() }
            } else {
                withAnimation(.snappy(duration: 0.2)) { isTerminalVisible = false }
                if hadFocus { focusEditor() }
            }
        }
        closing.close()
    }

    /// Starts a terminal in a new last tab, and makes it the one the card shows.
    @discardableResult
    private func makeTerminal() -> TerminalSession {
        let terminal = TerminalSession(directory: rootURL)
        // The shell was exited, with "exit" or ⌃D.
        terminal.onExit = { [weak self, weak terminal] in
            if let terminal { self?.closeTerminal(terminal) }
        }
        // Links to files open here, like Quick Open's results.
        terminal.onOpenFile = { [weak self] url, line in
            self?.open(url)
            self?.reveal(url)
            if let line { self?.goToLine(line) }
        }
        terminals.append(terminal)
        self.terminal = terminal
        return terminal
    }

    private func focusEditor() {
        if let textView = activeBuffer?.textController?.textView {
            textView.window?.makeFirstResponder(textView)
        }
    }

    // MARK: Sidebar modes

    enum SidebarMode {
        case explorer, search, changes
    }

    func showExplorer() {
        if !isSidebarVisible { toggleSidebar() }
        sidebarMode = .explorer
    }

    /// Source Control: shows the files git reports as changed.
    func showChanges() {
        guard git.isRepository else { return }
        if !isSidebarVisible { toggleSidebar() }
        sidebarMode = .changes
    }

    /// From the Changes list: opens the file showing what changed in it. A deleted
    /// file gets a tab too, with the lines it had.
    func openChanges(_ change: GitChange) {
        let url = url(forRelativePath: change.path)
        // A submodule is listed as a whole; there is no file to compare.
        if Self.isDirectory(url) { return }
        open(url)
        // A conflict is settled in the editor, where the conflict bar is, so
        // that's what selecting it shows: the text with git's markers.
        if change.status == .conflicted {
            guard let buffer = buffers[url] else { return }
            buffer.hideChanges()
            if buffer.isShowingPreview { buffer.setShowingPreview(false) }
            return
        }
        showChanges(in: url, comparison: change.isStaged ? .staged : .unstaged)
    }

    /// How many edited files in the project aren't saved: a commit takes files as
    /// they are on disk.
    var unsavedFileCount: Int {
        buffers.values.count { $0.isDirty && !$0.isUntitled }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    // MARK: Discarding changes

    /// From the Changes panel: asks, then undoes the unstaged changes. Edited and
    /// deleted files go back to how they are staged or were last committed, for
    /// good; untracked files, which git has no copy of, go to the Trash.
    func discardChanges(_ changes: [GitChange]) {
        let changes = changes.filter { change in
            guard !change.isStaged, change.status.isDiscardable else { return false }
            // A nested repository is listed as one untracked folder; that's more
            // than a file's changes to throw away.
            return change.status != .untracked || !Self.isDirectory(url(forRelativePath: change.path))
        }
        guard !changes.isEmpty, git.activity == nil else { return }
        let untracked = changes.filter { $0.status == .untracked }
        let tracked = changes.filter { $0.status != .untracked }

        let alert = NSAlert()
        alert.alertStyle = .warning
        let name = (changes[0].path as NSString).lastPathComponent
        var details: [String] = []
        if changes.count == 1 {
            alert.messageText = tracked.isEmpty ? "Move “\(name)” to the Trash?" : "Discard the changes in “\(name)”?"
        } else {
            alert.messageText = "Discard the changes in \(changes.count.formatted()) files?"
        }
        if !tracked.isEmpty {
            let files = changes.count == 1 ? "The file goes" : (tracked.count == 1 ? "1 file goes" : "\(tracked.count.formatted()) files go")
            details.append("\(files) back to how \(tracked.count == 1 ? "it was" : "they were") staged or last committed. This can’t be undone.")
        }
        if !untracked.isEmpty {
            let files = changes.count == 1 ? "It isn’t" : (untracked.count == 1 ? "1 file isn’t" : "\(untracked.count.formatted()) files aren’t")
            details.append("\(files) tracked by git, so \(untracked.count == 1 ? "it moves" : "they move") to the Trash.")
        }
        alert.informativeText = details.joined(separator: " ")
        let discard = alert.addButton(withTitle: tracked.isEmpty ? "Move to Trash" : "Discard Changes")
        discard.hasDestructiveAction = true
        // Not what Return does: this is the one thing here that can't be taken back.
        discard.keyEquivalent = ""
        alert.addButton(withTitle: "Cancel")

        let proceed: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.discard(tracked: tracked, untracked: untracked)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: proceed)
        } else {
            proceed(alert.runModal())
        }
    }

    private func discard(tracked: [GitChange], untracked: [GitChange]) {
        // All of it or none: not the untracked files to the Trash and then no
        // room for git to undo the rest, if something began while the sheet was up.
        guard git.isIdle else {
            git.reportBusy()
            return
        }
        var failure: Error?
        for change in untracked {
            let url = url(forRelativePath: change.path)
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                failure = failure ?? error
                continue
            }
            // As when a file is moved to the Trash in the tree: a tab with unsaved
            // edits stays, so nothing typed is lost.
            if buffers[url]?.isDirty != true { closeTab(url) }
            if selection == url { selection = nil }
        }
        if let failure { NSAlert(error: failure).runModal() }
        guard !tracked.isEmpty else {
            refresh()
            return
        }
        git.discard(tracked.map(\.path)) { [weak self] in
            guard let self else { return }
            // Unsaved edits to a file are changes to it too. An open file without
            // any is read again as the tree refreshes.
            for change in tracked {
                if let buffer = self.buffers[self.url(forRelativePath: change.path)], buffer.isDirty {
                    buffer.revertToDisk()
                }
            }
            self.refresh()
        }
    }

    /// Asks before something that can't be taken back, in a sheet on the window.
    /// Return doesn't choose it; it has to be clicked.
    private func confirm(_ title: String, _ text: String, button: String, then proceed: @escaping () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = text
        let action = alert.addButton(withTitle: button)
        action.hasDestructiveAction = true
        action.keyEquivalent = ""
        alert.addButton(withTitle: "Cancel")
        let respond: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn { proceed() }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }

    /// Lists the commits that changed a file, in the Changes panel's history.
    func showFileHistory(_ url: URL) {
        guard git.isRepository, !url.isUntitled else { return }
        git.historyFile = relativePath(of: url)
        git.isHistoryExpanded = true
        showChanges()
    }

    /// From the bar over a conflicted file: saves it and stages it, which is how
    /// git is told its conflicts are settled.
    func markResolved(_ buffer: EditorBuffer) {
        guard !buffer.isDirty || save(buffer) else { return }
        git.stage([GitChange(path: relativePath(of: buffer.url), status: .conflicted, isStaged: false)])
    }

    /// Stages a file from the Changes list. Staging a file in conflict tells git
    /// the conflict is settled, so one that still has git's markers in it is asked
    /// about first.
    func stage(_ change: GitChange) {
        let url = url(forRelativePath: change.path)
        // What's staged is the file on disk, and so is what's checked for
        // markers: a conflict settled in the tab but not saved yet is saved
        // first, as the conflict bar's own Save and Stage does.
        if change.status == .conflicted, let buffer = buffers[url], buffer.isDirty, !save(buffer) { return }
        guard change.status == .conflicted,
              let data = try? Data(contentsOf: url),
              !ConflictMarkers.regions(in: String(decoding: data, as: UTF8.self) as NSString).isEmpty else {
            git.stage([change])
            return
        }
        confirm(
            "“\(url.lastPathComponent)” still has conflict markers.",
            "Staging it tells git the conflict is settled, and the <<<<<<< and >>>>>>> lines would be committed as they are.",
            button: "Stage Anyway"
        ) { [weak self] in
            self?.git.stage([change])
        }
    }

    /// Whether git has the file down as in conflict.
    func isConflicted(_ buffer: EditorBuffer) -> Bool {
        !buffer.isUntitled && git.snapshot?.files[relativePath(of: buffer.url)] == .conflicted
    }

    // MARK: Branches

    /// From the branch picker: asks, then deletes a local branch.
    func deleteBranch(_ name: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete the branch “\(name)”?"
        alert.informativeText = "Only the branch here is deleted, not one of its name on a remote. git refuses if it has commits that aren’t merged anywhere, unless you tick the box."
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Delete it even with unmerged commits"
        let delete = alert.addButton(withTitle: "Delete Branch")
        delete.hasDestructiveAction = true
        delete.keyEquivalent = ""
        alert.addButton(withTitle: "Cancel")
        let respond: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.git.deleteBranch(name, force: alert.suppressionButton?.state == .on)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }

    /// From the branch picker: asks for the new name.
    func renameBranch(_ name: String) {
        let alert = NSAlert()
        alert.messageText = "Rename the branch “\(name)”"
        alert.informativeText = "A branch of this name on a remote keeps its name."
        let field = NSTextField(string: name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let respond: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.git.renameBranch(name, to: field.stringValue)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }

    /// Amend Last Commit and Undo Last Commit, from the Changes panel. Changing a
    /// commit that has been pushed is asked about first.
    func amendLastCommit() {
        rewritingLastCommit(named: "Amend") { [weak self] in self?.git.amend() }
    }

    func undoLastCommit() {
        rewritingLastCommit(named: "Undo") { [weak self] in self?.git.undoLastCommit() }
    }

    private func rewritingLastCommit(named name: String, _ proceed: @escaping () -> Void) {
        guard git.lastCommitIsPushed else {
            proceed()
            return
        }
        confirm(
            "\(name) a commit that has been pushed?",
            "The remote has this commit. After changing it here, the branch can only be pushed by forcing, which Silica doesn’t do.",
            button: "\(name) Commit", then: proceed
        )
    }

    /// From the Changes panel: asks, then calls off the merge or rebase in progress.
    func abortPendingOperation() {
        guard let pending = git.snapshot?.pending else { return }
        let name = pending.kind.command
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Abort the \(name)?"
        alert.informativeText = "The files go back to how they were before the \(name) began. Conflicts settled since are lost."
        let abort = alert.addButton(withTitle: "Abort \(name.prefix(1).uppercased() + name.dropFirst())")
        abort.hasDestructiveAction = true
        abort.keyEquivalent = ""
        alert.addButton(withTitle: "Cancel")
        let proceed: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.git.abortPending { [weak self] in self?.refresh() }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: proceed)
        } else {
            proceed(alert.runModal())
        }
    }

    /// From the Changes panel: asks, then deletes the stash and the changes in it.
    func dropStash(_ stash: GitStash) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Drop the stash “\(stash.commit.subject)”?"
        alert.informativeText = "The changes in it are deleted. This can’t be undone."
        let drop = alert.addButton(withTitle: "Drop Stash")
        drop.hasDestructiveAction = true
        drop.keyEquivalent = ""
        alert.addButton(withTitle: "Cancel")
        let proceed: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .alertFirstButtonReturn { self?.git.drop(stash) }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: proceed)
        } else {
            proceed(alert.runModal())
        }
    }

    /// git refused or failed at something the Changes panel asked for.
    private func present(_ failure: GitModel.Failure) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = failure.title
        // The end of what git and its hooks said, which is where the reason is.
        let details = failure.details.isEmpty ? "git gave no reason." : failure.details
        alert.informativeText = details.count > 1_200 ? "…" + details.suffix(1_200) : details
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// Whether the tab can switch to its changes: a file git reports as changed.
    func hasChanges(_ buffer: EditorBuffer) -> Bool {
        !buffer.isUntitled && git.snapshot?.files[relativePath(of: buffer.url)] != nil
    }

    /// Show Changes / Hide Changes, for the active tab.
    func toggleChanges() {
        guard let buffer = activeBuffer else { return }
        if buffer.isShowingChanges {
            buffer.hideChanges()
        } else if hasChanges(buffer) {
            showChanges(in: buffer.url, comparison: .all)
            // Asked for from the tab, the changes take the keyboard, as the editor
            // they replace had it: arrows scroll them, typing goes back to the text.
            buffer.changesPreview?.focus()
        }
    }

    /// Shows a file's changes, or brings them up to date: all of them, or with
    /// `comparison`, only the staged or the unstaged ones.
    private func showChanges(in url: URL, comparison: GitDiff.Request.Comparison) {
        let path = relativePath(of: url)
        let snapshot = git.snapshot
        // What git says of the file for that comparison; a rename is staged.
        let status: GitFileStatus? = switch comparison {
        case .all: snapshot?.files[path]
        case .unstaged: snapshot?.unstaged.first { $0.path == path }?.status
        case .staged: snapshot?.staged.first { $0.path == path }?.status
        }
        buffers[url]?.showChanges(
            path: path, status: status, originalPath: comparison == .unstaged ? nil : snapshot?.renamedFrom[path],
            comparison: comparison
        )
    }

    /// Compares again in the tabs that show their changes: the file or what git
    /// says of it has changed.
    private func refreshShownChanges() {
        // What a commit changed stays as it is.
        for (url, buffer) in buffers where buffer.isShowingChanges && buffer.shownCommit == nil {
            // A file that has come into conflict has no staged or unstaged
            // changes to show, only a conflict to settle, in the editor: as when
            // it's selected in the Changes list.
            if buffer.shownComparison != .all, git.snapshot?.files[relativePath(of: url)] == .conflicted {
                buffer.hideChanges()
                continue
            }
            showChanges(in: url, comparison: buffer.shownComparison)
        }
    }

    /// From the history: opens the file showing what the commit changed in it.
    /// A file that has since been deleted or moved gets a tab too.
    func openChanges(_ file: GitCommitFile, in commit: GitCommit) {
        let url = url(forRelativePath: file.path)
        if Self.isDirectory(url) { return }
        open(url)
        buffers[url]?.showChanges(
            path: file.path, status: file.status, originalPath: file.originalPath, commit: commit
        )
    }

    /// The file at `path` from the project root, as the tree's rows name it.
    func url(forRelativePath path: String) -> URL {
        let rootPath = rootURL.path(percentEncoded: false).trimmingTrailingSlash
        return URL(filePath: rootPath + "/" + path, directoryHint: .notDirectory)
    }

    /// Find in Project: shows the search sidebar and focuses its field.
    func showSearch() {
        if !isSidebarVisible { toggleSidebar() }
        sidebarMode = .search
        search.focusRequest += 1
    }

    /// Opens a search result with the match selected.
    func openSearchMatch(_ url: URL, range: NSRange) {
        open(url)
        guard let buffer = buffers[url] else { return }
        buffer.hideChanges()
        if buffer.isShowingPreview { buffer.setShowingPreview(false) }
        // Once the editor for the file is in the window.
        DispatchQueue.main.async {
            buffer.textController?.reveal(range)
        }
    }

    // MARK: Quick Open

    func toggleQuickOpen() {
        if isQuickOpenVisible {
            hideQuickOpen()
        } else {
            showQuickOpen(query: "")
        }
    }

    private func showQuickOpen(query: String) {
        quickOpen.prepareForPresentation(activeFile: activeTab, query: query)
        if !isQuickOpenVisible {
            withAnimation(.snappy(duration: 0.18)) { isQuickOpenVisible = true }
        }
    }
    
    func hideQuickOpen() {
        guard isQuickOpenVisible else { return }
        withAnimation(.snappy(duration: 0.18)) { isQuickOpenVisible = false }
        // Give typing focus back to the editor.
        if let textView = activeBuffer?.textController?.textView {
            textView.window?.makeFirstResponder(textView)
        }
    }
    
    /// Lines in the active file, for the Go to Line prompt.
    var activeLineCount: Int? {
        activeBuffer?.textController?.lineCount
    }

    func goToLineFromQuickOpen(_ line: Int) {
        hideQuickOpen()
        goToLine(line)
    }

    private func goToLine(_ line: Int) {
        guard let buffer = activeBuffer, let controller = buffer.textController else { return }
        buffer.hideChanges()
        if buffer.isShowingPreview { buffer.setShowingPreview(false) }
        DispatchQueue.main.async { controller.goToLine(line) }
    }

    /// Opens a Quick Open result; "name:42" also jumps to line 42.
    func openFromQuickOpen(_ url: URL, line: Int? = nil) {
        hideQuickOpen()
        open(url)
        reveal(url)
        if let line { goToLine(line) }
    }
    
    /// Go to Line (⌘L): Quick Open with ":" typed, as in VS Code.
    func showGoToLine() {
        guard activeBuffer?.textController != nil else { return }
        showQuickOpen(query: ":")
    }
    
    // MARK: Quick Jump
    
    func quickJumpToFile() {
        guard let selection else {
            return
        }
        revealInTree(selection)
    }
    
    /// Expands the folders above `url` so its row exists, selects it and asks the
    /// tree to scroll to it.
    func reveal(_ url: URL) {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.starts(with: rootComponents) else { return }
        var current = root
        for name in components.dropFirst(rootComponents.count).dropLast() {
            var next = current.children?.first { $0.name == name }
            if next == nil {
                // The folder may have appeared since the tree last read the disk.
                current.reload()
                next = current.children?.first { $0.name == name }
            }
            guard let folder = next, folder.isDirectory else { return }
            if !folder.isExpanded { folder.isExpanded = true }
            current = folder
        }
        if current.children?.contains(where: { $0.url == url }) == false {
            current.reload()
        }
        selection = url
        revealedURL = url
        revealCount += 1
    }

    /// Whether `url` is inside the project folder, where the tree can show it. A
    /// tab can be outside it after Save As.
    func contains(_ url: URL) -> Bool {
        url.isFileURL && url.standardizedFileURL.pathComponents.dropLast()
            .starts(with: rootURL.standardizedFileURL.pathComponents)
    }

    /// Reveal in Explorer, from a tab's menu: `reveal`, after bringing the tree
    /// into view and clearing a filter that hides the file.
    func revealInTree(_ url: URL) {
        // The tree's selection is the active tab, and the tree isn't there to
        // open what's selected in it while the sidebar is hidden.
        activate(url)
        showExplorer()
        if isFilteringTree, treeFilterResult?.visiblePaths.contains(relativePath(of: url)) != true {
            treeFilter = ""
        }
        reveal(url)
    }

    /// Re-reads the tree and checks open files against the disk.
    func refresh() {
        root.reload()
        FolderIcons.shared.reload()
        syncOpenFilesWithDisk()
        search.refresh()
        git.refresh()
        refreshShownChanges()
        // Files may have come or gone: filter a fresh list.
        treeFilterItems = nil
        if treeFilterResult != nil { scheduleTreeFilter(after: .milliseconds(300)) }
    }

    // MARK: Tree filter

    var isFilteringTree: Bool {
        !treeFilter.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Filter Files (⌥⌘J): shows the explorer and focuses its filter field.
    func focusTreeFilter() {
        showExplorer()
        treeFilterFocusRequest += 1
    }

    private func scheduleTreeFilter(after delay: Duration = .milliseconds(120)) {
        treeFilterTask?.cancel()
        let query = treeFilter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            treeFilterResult = nil
            return
        }
        let root = rootURL
        let cached = treeFilterItems
        treeFilterTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let (items, result) = await Task.detached(priority: .userInitiated) {
                let items = cached ?? ProjectFileIndex.scan(root: root)
                return (items, TreeFilter.filter(items, by: query))
            }.value
            guard let self, !Task.isCancelled else { return }
            self.treeFilterItems = items
            self.loadFolders(in: result.visiblePaths)
            self.treeFilterResult = result
        }
    }

    /// Reads the folders a filtered tree passes through, without expanding them, so
    /// clearing the filter brings back the tree as it was.
    private func loadFolders(in paths: Set<String>) {
        for path in paths.sorted(by: { $0.count < $1.count }) {
            var current = root
            for name in path.split(separator: "/") {
                current.loadChildrenIfNeeded()
                guard let next = current.children?.first(where: { $0.name == name }) else { break }
                current = next
            }
            if current.isDirectory { current.loadChildrenIfNeeded() }
        }
    }

    private func syncOpenFilesWithDisk() {
        for url in openTabs {
            guard let buffer = buffers[url], buffer.syncWithDisk() else { continue }
            // An image or other non-text file changed: read it again.
            buffers[url] = makeBuffer(for: url)
        }
    }

    func collapseAll() {
        root.collapseAll()
    }

    func relativePath(of url: URL) -> String {
        let rootPath = rootURL.path(percentEncoded: false).trimmingTrailingSlash
        let path = url.path(percentEncoded: false)
        guard path.hasPrefix(rootPath + "/") else { return path }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private func node(for url: URL) -> FileNode? {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.starts(with: rootComponents) else { return nil }
        var current = root
        for name in components.dropFirst(rootComponents.count) {
            guard let next = current.children?.first(where: { $0.name == name }) else { return nil }
            current = next
        }
        return current
    }

    // MARK: Tabs

    func open(_ url: URL) {
        if buffers[url] == nil {
            buffers[url] = makeBuffer(for: url)
        }
        if !openTabs.contains(url) {
            if let active = activeTab, let index = openTabs.firstIndex(of: active) {
                openTabs.insert(url, at: index + 1)
            } else {
                openTabs.append(url)
            }
        }
        activate(url)
    }

    private func makeBuffer(for url: URL) -> EditorBuffer {
        let buffer = EditorBuffer(url: url)
        buffer.projectURL = rootURL
        buffer.setIndexContent = { [weak self, weak buffer] path, content, savesFirst in
            guard let self, let buffer else { return }
            // The same save as ⌘S: it asks before writing over a file another app
            // has changed, and says so if it fails. No save, no staging.
            if savesFirst, buffer.isDirty, !self.save(buffer) { return }
            self.git.setIndexContent(of: path, to: content)
        }
        // Links in a preview open other project files here, like Quick Open.
        buffer.openFile = { [weak self] target in
            self?.open(target)
            self?.reveal(target)
        }
        return buffer
    }

    func activate(_ url: URL) {
        activeTab = url
        // An untitled file has no row in the tree or place in Quick Open.
        if url.isUntitled {
            selection = nil
            return
        }
        quickOpen.noteOpened(url)
        if selection != url {
            selection = url
        }
    }

    /// Select Next Tab / Select Previous Tab: the tab `offset` places along the bar from the
    /// active one, going round from either end to the other.
    func activateTab(offsetBy offset: Int) {
        let count = openTabs.count
        guard count > 1, let activeTab, let index = openTabs.firstIndex(of: activeTab) else { return }
        activate(openTabs[((index + offset) % count + count) % count])
    }

    /// New File (⌘N): an empty "Untitled-N" tab, saved somewhere only when asked.
    func newUntitledFile() {
        let taken = Set(openTabs.filter(\.isUntitled).map(\.lastPathComponent))
        var number = 1
        while taken.contains("Untitled-\(number)") { number += 1 }
        let buffer = EditorBuffer(untitledName: "Untitled-\(number)")
        buffers[buffer.url] = buffer
        if let active = activeTab, let index = openTabs.firstIndex(of: active) {
            openTabs.insert(buffer.url, at: index + 1)
        } else {
            openTabs.append(buffer.url)
        }
        activate(buffer.url)
    }

    /// Puts a tab at another place in the tab bar (dragging it there).
    func moveTab(_ url: URL, to index: Int) {
        guard let current = openTabs.firstIndex(of: url) else { return }
        let target = min(max(index, 0), openTabs.count - 1)
        guard target != current else { return }
        var tabs = openTabs
        tabs.remove(at: current)
        tabs.insert(url, at: target)
        openTabs = tabs
    }

    func closeActiveTab() {
        if let activeTab { closeTab(activeTab) }
    }

    func closeOtherTabs(than url: URL) {
        for other in openTabs where other != url {
            closeTab(other)
        }
    }

    func closeTab(_ url: URL) {
        guard let index = openTabs.firstIndex(of: url) else { return }
        if let buffer = buffers[url], buffer.needsSaving, !confirmDiscardOrSave(buffer) {
            return
        }

        openTabs.remove(at: index)
        buffers[url] = nil

        if activeTab == url {
            if openTabs.isEmpty {
                activeTab = nil
                selection = nil
            } else {
                activate(openTabs[min(index, openTabs.count - 1)])
            }
        }
    }

    // MARK: File operations

    enum TreeEdit: Equatable {
        case rename(URL)
        case create(in: URL, isDirectory: Bool)
    }

    /// Starts naming a new file or folder in the tree: inside the selected folder,
    /// next to the selected file, or at the top of the project.
    func beginNewItem(isDirectory: Bool, in folder: URL? = nil) {
        let target = folder ?? selection.map { $0.hasDirectoryPath ? $0 : $0.deletingLastPathComponent() } ?? rootURL
        let node = node(for: target) ?? root
        if !node.isExpanded { node.isExpanded = true }
        showExplorer()
        treeEdit = .create(in: node.url, isDirectory: isDirectory)
    }

    func beginRename(_ url: URL) {
        showExplorer()
        treeEdit = .rename(url)
    }

    func cancelTreeEdit() {
        treeEdit = nil
    }

    /// Creates the file or folder named in the tree. A name with slashes creates the
    /// folders in between, as in VS Code.
    func createItem(named rawName: String, in folder: URL, isDirectory: Bool) {
        treeEdit = nil
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let url = Self.normalized(folder.appending(path: name), isDirectory: isDirectory)
        guard !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            showAlert("“\(url.lastPathComponent)” already exists.", info: "Choose a different name.")
            return
        }
        do {
            let fileManager = FileManager.default
            if isDirectory {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: url, options: .withoutOverwriting)
            }
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        refresh()
        reveal(url)
        if !isDirectory { open(url) }
    }

    /// Renames in place; open tabs for the item (or anything inside a renamed folder)
    /// follow it, keeping their edits.
    func rename(_ url: URL, to rawName: String) {
        treeEdit = nil
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != url.lastPathComponent else { return }
        guard !name.contains("/"), !name.contains(":") else {
            showAlert("“\(name)” can’t be used as a name.", info: "Names can’t contain “/” or “:”.")
            return
        }
        let isDirectory = url.hasDirectoryPath
        let destination = Self.normalized(url.deletingLastPathComponent().appending(path: name), isDirectory: isDirectory)
        // A case-only change is the same file on a case-insensitive disk.
        let isCaseChange = name.lowercased() == url.lastPathComponent.lowercased()
        guard isCaseChange || !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) else {
            showAlert("“\(name)” already exists.", info: "Choose a different name.")
            return
        }
        do {
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        retargetBuffers(from: url, to: destination)
        refresh()
        reveal(destination)
    }

    /// Copies the item next to itself as "name copy", like Finder.
    func duplicate(_ url: URL) {
        let isDirectory = url.hasDirectoryPath
        let folder = url.deletingLastPathComponent()
        let ext = isDirectory ? "" : url.pathExtension
        let base = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        var copy: URL
        var number = 1
        repeat {
            let suffix = number == 1 ? " copy" : " copy \(number)"
            let name = base + suffix + (ext.isEmpty ? "" : "." + ext)
            copy = Self.normalized(folder.appending(path: name), isDirectory: isDirectory)
            number += 1
        } while FileManager.default.fileExists(atPath: copy.path(percentEncoded: false))
        do {
            try FileManager.default.copyItem(at: url, to: copy)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        refresh()
        reveal(copy)
    }

    /// Moves the item to the Trash. Unedited tabs for it close; edited ones stay
    /// open, marked as deleted, so nothing typed is lost.
    func moveToTrash(_ url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        for tab in openTabs where Self.url(tab, isInside: url) && buffers[tab]?.isDirty != true {
            closeTab(tab)
        }
        if let selection, Self.url(selection, isInside: url) { self.selection = nil }
        refresh()
    }

    /// Save As (⇧⌘S): writes the text to a new file, which takes the tab's place. The
    /// original file keeps what was last saved.
    func saveActiveAs() {
        guard let buffer = activeBuffer, buffer.textController != nil,
              let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let panel = savePanel(for: buffer)
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.save(buffer, as: url)
        }
    }

    /// Starts in the file's folder, or the project for an untitled file.
    private func savePanel(for buffer: EditorBuffer) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.directoryURL = buffer.isUntitled ? rootURL : buffer.url.deletingLastPathComponent()
        panel.nameFieldStringValue = buffer.name
        panel.canCreateDirectories = true
        return panel
    }

    /// The second half of Save As, once a destination is chosen. Returns `true` if
    /// the file was written.
    @discardableResult
    func save(_ buffer: EditorBuffer, as url: URL) -> Bool {
        let destination = Self.normalized(url, isDirectory: false)
        let source = buffer.url
        guard destination != source else {
            return save(buffer)
        }
        do {
            try buffer.write(to: destination)
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
        // A tab already open on the destination now shows stale text; drop it.
        if buffers[destination] != nil {
            openTabs.removeAll { $0 == destination }
            buffers[destination] = nil
        }
        buffers[source] = nil
        buffers[destination] = makeBuffer(for: destination)
        if let index = openTabs.firstIndex(of: source) {
            openTabs[index] = destination
        } else {
            openTabs.append(destination)
        }
        activate(destination)
        refresh()
        reveal(destination)
        return true
    }

    /// Points tabs at their new location after a rename.
    private func retargetBuffers(from old: URL, to new: URL) {
        let oldPath = old.path(percentEncoded: false).trimmingTrailingSlash
        let newPath = new.path(percentEncoded: false).trimmingTrailingSlash
        func moved(_ url: URL) -> URL? {
            let path = url.path(percentEncoded: false)
            guard path == oldPath || path.hasPrefix(oldPath + "/") else { return nil }
            return Self.normalized(URL(filePath: newPath + path.dropFirst(oldPath.count)), isDirectory: url.hasDirectoryPath)
        }
        for (url, buffer) in buffers {
            guard let target = moved(url) else { continue }
            buffers[url] = nil
            buffers[target] = buffer
            buffer.move(to: target)
        }
        openTabs = openTabs.map { moved($0) ?? $0 }
        if let activeTab, let target = moved(activeTab) { self.activeTab = target }
        if let selection, let target = moved(selection) { self.selection = target }
        quickOpen.noteMoved { moved($0) }
    }

    /// The tree's form of a URL: a plain file path, with a trailing slash for folders.
    private static func normalized(_ url: URL, isDirectory: Bool) -> URL {
        // Not `standardizedFileURL`: it turns /private/tmp into /tmp, and the tree keeps
        // paths as listed.
        URL(filePath: url.path(percentEncoded: false).trimmingTrailingSlash,
            directoryHint: isDirectory ? .isDirectory : .notDirectory)
    }

    private static func url(_ url: URL, isInside container: URL) -> Bool {
        let path = url.path(percentEncoded: false).trimmingTrailingSlash
        let containerPath = container.path(percentEncoded: false).trimmingTrailingSlash
        return path == containerPath || path.hasPrefix(containerPath + "/")
    }

    private func showAlert(_ message: String, info: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.runModal()
    }

    // MARK: Session

    /// Reopens the tabs the project had last time, with their cursor and scroll
    /// positions (unless turned off in Settings).
    private func restoreSession() {
        guard EditorSettings.shared.restoresTabs,
              let session = ProjectSessionStore.session(for: rootURL) else { return }
        isRestoringSession = true
        defer { isRestoringSession = false }

        isSidebarVisible = session.isSidebarVisible
        for tab in session.tabs {
            let url = sessionURL(for: tab.path)
            var isDirectory: ObjCBool = false
            guard !openTabs.contains(url),
                  FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            let buffer = makeBuffer(for: url)
            buffers[url] = buffer
            openTabs.append(url)
            buffer.textController?.restorePosition(cursor: tab.cursor, topLine: tab.topLine)
        }
        let active = session.activeTab.map(sessionURL(for:)).flatMap { openTabs.contains($0) ? $0 : nil } ?? openTabs.first
        if let active {
            activate(active)
            reveal(active)
        }
    }

    /// Remembers the open tabs; called on changes (batched), on close and on quit.
    func saveSession() {
        sessionSaveTask?.cancel()
        sessionSaveTask = nil
        // Untitled tabs have nothing on disk to reopen.
        let tabs = openTabs.filter { !$0.isUntitled }.map { url in
            let controller = buffers[url]?.textController
            return ProjectSession.Tab(
                path: relativePath(of: url),
                cursor: controller?.cursorLocation,
                topLine: controller?.savedTopLine
            )
        }
        let session = ProjectSession(
            tabs: tabs,
            activeTab: activeTab.flatMap { $0.isUntitled ? nil : relativePath(of: $0) },
            isSidebarVisible: isSidebarVisible,
            savedAt: .now
        )
        ProjectSessionStore.save(session, for: rootURL)
    }

    private func scheduleSessionSave() {
        guard !isRestoringSession else { return }
        sessionSaveTask?.cancel()
        sessionSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveSession()
        }
    }

    /// A saved path: relative to the project, or absolute.
    private func sessionURL(for path: String) -> URL {
        let absolute = path.hasPrefix("/") ? path : rootURL.path(percentEncoded: false).trimmingTrailingSlash + "/" + path
        return URL(filePath: absolute, directoryHint: .notDirectory)
    }

    // MARK: Saving

    func saveActive() {
        guard let buffer = activeBuffer else { return }
        if buffer.isUntitled {
            saveActiveAs()
        } else {
            save(buffer)
        }
    }

    /// Saves every edited file. Untitled ones are left for their own Save, since each
    /// needs a name.
    func saveAll() {
        for buffer in buffers.values where buffer.isDirty && !buffer.isUntitled {
            save(buffer)
        }
    }

    @discardableResult
    private func save(_ buffer: EditorBuffer) -> Bool {
        // Untitled: ask where, in a panel of its own (this runs inside other prompts).
        if buffer.isUntitled {
            let panel = savePanel(for: buffer)
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            return save(buffer, as: url)
        }
        if case .modified = buffer.diskChange(), !confirmOverwrite(buffer) {
            return false
        }
        do {
            try buffer.save()
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    /// The file changed on disk while it had unsaved edits here. Returns `true` to
    /// write Silica's version over it.
    private func confirmOverwrite(_ buffer: EditorBuffer) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(buffer.name)” was changed by another app."
        alert.informativeText = "Saving replaces those changes with yours. Revert discards your unsaved edits and shows the file as it is on disk (you can undo it)."
        alert.addButton(withTitle: "Save Anyway")
        alert.addButton(withTitle: "Revert")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return true
        case .alertSecondButtonReturn:
            buffer.revertToDisk()
            return false
        default:
            return false
        }
    }

    /// Returns `true` if the tab may be closed.
    private func confirmDiscardOrSave(_ buffer: EditorBuffer) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes you made to “\(buffer.name)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        addDontSaveButton(to: alert)
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save(buffer)
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    // MARK: Closing the window

    /// Edited files, in tab order.
    var unsavedBuffers: [EditorBuffer] {
        openTabs.compactMap { buffers[$0] }.filter(\.needsSaving)
    }

    /// Asks, in a sheet on `window`, whether to save edited files before the window
    /// closes or the app quits. `completion(true)` means go ahead: everything was
    /// saved, or the user chose not to save.
    func confirmClosing(in window: NSWindow, completion: @escaping (Bool) -> Void) {
        let unsaved = unsavedBuffers
        guard !unsaved.isEmpty else {
            completion(true)
            return
        }
        hideQuickOpen()

        let alert = NSAlert()
        if unsaved.count == 1 {
            alert.messageText = "Do you want to save the changes you made to “\(unsaved[0].name)”?"
            alert.informativeText = "Your changes will be lost if you don’t save them."
            alert.addButton(withTitle: "Save")
        } else {
            alert.messageText = "Do you want to save the changes you made to \(unsaved.count) files in “\(name)”?"
            let names = unsaved.prefix(5).map(\.name).formatted(.list(type: .and))
            let more = unsaved.count > 5 ? " and \(unsaved.count - 5) more" : ""
            alert.informativeText = "\(names)\(more)\n\nYour changes will be lost if you don’t save them."
            alert.addButton(withTitle: "Save All")
        }
        addDontSaveButton(to: alert)
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return completion(true) }
            switch response {
            case .alertFirstButtonReturn:
                // Stop at the first file that fails to save (or whose save is cancelled).
                let saved = unsaved.allSatisfy { !$0.needsSaving || self.save($0) }
                completion(saved)
            case .alertSecondButtonReturn:
                completion(true)
            default:
                completion(false)
            }
        }
    }

    private func addDontSaveButton(to alert: NSAlert) {
        let button = alert.addButton(withTitle: "Don’t Save")
        button.keyEquivalent = "d"
        button.keyEquivalentModifierMask = .command
    }
}
