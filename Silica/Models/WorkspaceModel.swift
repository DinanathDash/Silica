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
    /// How the editor area is divided into panes. Each pane has its own tabs, and
    /// a text file can have a tab in several of them.
    private(set) var layout = PaneLayout() {
        didSet { scheduleSessionSave() }
    }
    private var paneTabs: [PaneLayout.PaneID: PaneTabs] = [:] {
        didSet {
            scheduleSessionSave()
            // A pane that lost a file's tab has no more use for its editor on it.
            for (url, buffer) in buffers { buffer.keepEditors(in: panes(holding: url)) }
        }
    }
    /// The pane that menu commands act on and files open in: the one last clicked
    /// or typed in. Starts as the layout's only pane.
    private(set) var focusedPane: PaneLayout.PaneID = 0 {
        didSet { scheduleSessionSave() }
    }
    /// The pane a tab being dragged would move to if dropped now.
    var tabDropPane: PaneLayout.PaneID?
    /// The room the panes and the terminal share, which the view reports: what
    /// there is to split.
    @ObservationIgnored var editorAreaSize: CGSize = .zero
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
    /// Where the last Save As put its file, for closing a tab that was saved on the way.
    @ObservationIgnored private var savedAsURL: URL?

    var name: String { root.name }

    /// The open files, pane by pane in reading order; one that several panes have
    /// a tab for is here once.
    var openTabs: [URL] {
        var seen = Set<URL>()
        return layout.panes.flatMap { tabs(in: $0) }.filter { seen.insert($0).inserted }
    }

    /// The tab the focused pane shows.
    var activeTab: URL? {
        paneTabs[focusedPane]?.active
    }

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
        tabs(in: focusedPane).count > 1 || (terminals.count > 1 && isTerminalVisible && terminal?.isFocused == true)
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

    /// Views in the title bar that take drags themselves (a tab, the divider
    /// between two panes). The window server moves the window on any drag there,
    /// whatever gesture or view is under the pointer, so the window stops being
    /// movable while the pointer is over one of them.
    @ObservationIgnored private var windowHolders = Set<String>()

    func setWindowHeld(_ isHeld: Bool, by holder: String) {
        if isHeld { windowHolders.insert(holder) } else { windowHolders.remove(holder) }
        window?.isMovable = windowHolders.isEmpty
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
            if let buffer = buffers[url] { showText(of: buffer) }
            return
        }
        buffers[url]?.setAuxiliaryPane(focusedPane)
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
        if showsChanges(buffer, in: focusedPane) {
            buffer.hideChanges()
        } else if hasChanges(buffer) {
            // In this pane, wherever they were showing.
            buffer.setAuxiliaryPane(focusedPane)
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
        buffers[url]?.setAuxiliaryPane(focusedPane)
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
        showText(of: buffer)
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

    /// Go to Line (⌘L): Quick Open with ":" typed, as in VS Code.
    func showGoToLine() {
        guard activeBuffer?.textController != nil else { return }
        showQuickOpen(query: ":")
    }

    private func showQuickOpen(query: String) {
        quickOpen.prepareForPresentation(activeFile: activeTab, query: query)
        if !isQuickOpenVisible {
            withAnimation(.snappy(duration: 0.18)) { isQuickOpenVisible = true }
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
        showText(of: buffer)
        DispatchQueue.main.async { controller.goToLine(line) }
    }

    func hideQuickOpen() {
        guard isQuickOpenVisible else { return }
        withAnimation(.snappy(duration: 0.18)) { isQuickOpenVisible = false }
        // Give typing focus back to the editor.
        if let textView = activeBuffer?.textController?.textView {
            textView.window?.makeFirstResponder(textView)
        }
    }

    /// Opens a Quick Open result; "name:42" also jumps to line 42.
    func openFromQuickOpen(_ url: URL, line: Int? = nil) {
        hideQuickOpen()
        open(url)
        reveal(url)
        if let line { goToLine(line) }
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

    func tabs(in pane: PaneLayout.PaneID) -> [URL] {
        paneTabs[pane]?.tabs ?? []
    }

    /// The tab a pane shows.
    func activeTab(in pane: PaneLayout.PaneID) -> URL? {
        paneTabs[pane]?.active
    }

    func buffer(in pane: PaneLayout.PaneID) -> EditorBuffer? {
        activeTab(in: pane).flatMap { buffers[$0] }
    }

    /// The panes that have a tab for the file, in reading order.
    func panes(holding url: URL) -> [PaneLayout.PaneID] {
        layout.panes.filter { paneTabs[$0]?.contains(url) == true }
    }

    /// The pane to go by for a file when none is named: the focused one if it has
    /// the file's tab, or else the first that does.
    private func pane(for url: URL) -> PaneLayout.PaneID? {
        paneTabs[focusedPane]?.contains(url) == true ? focusedPane : panes(holding: url).first
    }

    /// Opens a file in the focused pane, whichever other panes have it open. What
    /// has a single view (an image, a PDF, a video) is gone to in the pane it's in.
    func open(_ url: URL) {
        if buffers[url] == nil {
            buffers[url] = makeBuffer(for: url)
        }
        if paneTabs[focusedPane]?.contains(url) != true,
           buffers[url]?.allowsSeveralPanes == true || panes(holding: url).isEmpty {
            paneTabs[focusedPane, default: PaneTabs()].insert(url)
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

    /// Shows a file's tab in a pane, and goes to that pane: the pane named, or the
    /// focused one if it has the tab, or the first that does.
    func activate(_ url: URL, in pane: PaneLayout.PaneID? = nil) {
        guard let pane = pane ?? self.pane(for: url), paneTabs[pane]?.contains(url) == true else { return }
        if paneTabs[pane]?.active != url { paneTabs[pane]?.activate(url) }
        if pane != focusedPane {
            focusedPane = pane
            focusPaneContent()
        }
        noteActiveTab()
    }

    /// The tree's selection and Quick Open's recent files follow the tab the
    /// focused pane shows, and that file's commands go to the editor in this pane.
    private func noteActiveTab() {
        activeBuffer?.setCurrentPane(focusedPane)
        // An untitled file has no row in the tree or place in Quick Open.
        guard let url = activeTab, !url.isUntitled else {
            if selection != nil { selection = nil }
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
        if let url = paneTabs[focusedPane]?.tab(offsetBy: offset) { activate(url) }
    }

    /// New File (⌘N): an empty "Untitled-N" tab, saved somewhere only when asked.
    func newUntitledFile() {
        let taken = Set(openTabs.filter(\.isUntitled).map(\.lastPathComponent))
        var number = 1
        while taken.contains("Untitled-\(number)") { number += 1 }
        let buffer = EditorBuffer(untitledName: "Untitled-\(number)")
        buffers[buffer.url] = buffer
        paneTabs[focusedPane, default: PaneTabs()].insert(buffer.url)
        activate(buffer.url)
    }

    /// Puts a tab at another place in its pane's tab bar (dragging it there).
    func moveTab(_ url: URL, to index: Int, in pane: PaneLayout.PaneID) {
        paneTabs[pane]?.move(url, to: index)
    }

    func closeActiveTab() {
        if let activeTab { closeTab(activeTab, in: focusedPane) }
    }

    /// Closes the other tabs of a pane.
    func closeOtherTabs(than url: URL, in pane: PaneLayout.PaneID) {
        for other in tabs(in: pane) where other != url {
            closeTab(other, in: pane)
        }
    }

    /// Closes a file's tab in a pane or, with no pane named, in every pane that
    /// has one (the file is gone). Unsaved edits are asked about when the last of
    /// the file's tabs is closing: until then they're still open in another pane.
    func closeTab(_ url: URL, in pane: PaneLayout.PaneID? = nil) {
        let holders = panes(holding: url)
        guard !holders.isEmpty, pane.map(holders.contains) ?? true else { return }
        var closing = url
        if pane == nil || holders.count == 1, let buffer = buffers[url], buffer.needsSaving {
            savedAsURL = nil
            guard confirmDiscardOrSave(buffer) else { return }
            // Saving an untitled file gave its tab the new file, which is what closes.
            if panes(holding: url).isEmpty, let savedAsURL { closing = savedAsURL }
        }
        for holder in pane.map({ [$0] }) ?? panes(holding: closing) where paneTabs[holder]?.contains(closing) == true {
            removeTab(closing, from: holder)
        }
        if panes(holding: closing).isEmpty { buffers[closing] = nil }
    }

    /// Takes a tab off its pane. A pane left without tabs goes too, unless it's
    /// the only one.
    private func removeTab(_ url: URL, from pane: PaneLayout.PaneID) {
        paneTabs[pane]?.remove(url)
        if layout.isSplit, paneTabs[pane]?.isEmpty != false {
            closePane(pane)
        } else if pane == focusedPane {
            noteActiveTab()
        }
    }

    // MARK: Panes

    /// Whether there is room to divide the pane (the focused one, unless another
    /// is named) with every pane keeping its minimum size.
    func canSplit(_ pane: PaneLayout.PaneID? = nil, along axis: PaneLayout.Axis) -> Bool {
        var divided = layout
        guard divided.split(pane ?? focusedPane, along: axis) != nil else { return false }
        // Before the first layout pass there's no size to go by.
        guard editorAreaSize != .zero else { return true }
        let needed = divided.minimumSize(spacing: WorkspaceLayout.paneSpacing, minimum: WorkspaceLayout.paneMinimumSize)
        // The terminal gives up its height down to its own minimum.
        let terminal = isTerminalVisible ? WorkspaceLayout.terminalHeightRange.lowerBound + WorkspaceLayout.cardInset : 0
        return needed.width <= editorAreaSize.width && needed.height <= editorAreaSize.height - terminal
    }

    /// Split Right / Split Down: divides a pane (the focused one, unless another is
    /// named) and goes to the new one, which shows the same file: the pane's
    /// active tab, or the one named. A file that has a single view (an image, a
    /// PDF, a video) moves there instead when the pane has other tabs to keep, and
    /// otherwise stays, the new pane starting empty.
    func splitPane(_ axis: PaneLayout.Axis, from pane: PaneLayout.PaneID? = nil, showing url: URL? = nil) {
        let source = pane ?? focusedPane
        guard canSplit(source, along: axis) else {
            NSSound.beep()
            return
        }
        withAnimation(WorkspaceLayout.paneAnimation) {
            guard let new = layout.split(source, along: axis) else { return }
            var tabs = paneTabs
            var shown = PaneTabs()
            if let url = url ?? activeTab(in: source), tabs[source]?.contains(url) == true {
                if buffers[url]?.allowsSeveralPanes == true {
                    shown.insert(url)
                } else if self.tabs(in: source).count > 1 {
                    tabs[source]?.remove(url)
                    shown.insert(url)
                    buffers[url]?.movePane(from: source, to: new)
                }
            }
            tabs[new] = shown
            paneTabs = tabs
            focusedPane = new
        }
        noteActiveTab()
        focusPaneContent()
    }

    /// ⌥-click in the tree, Open in New Pane: opens a file in a new pane to the right
    /// of the focused one, which keeps what it shows. Without room for another
    /// pane, or with nothing open to keep, the file opens in the focused pane.
    func openInNewPane(_ url: URL) {
        guard !tabs(in: focusedPane).isEmpty, canSplit(along: .horizontal) else {
            open(url)
            return
        }
        withAnimation(WorkspaceLayout.paneAnimation) {
            guard let new = layout.split(focusedPane, along: .horizontal) else { return }
            paneTabs[new] = PaneTabs()
            focusedPane = new
        }
        // A file that has a single view (an image, a PDF, a video) comes over from
        // the pane it's open in.
        if buffers[url]?.allowsSeveralPanes == false, let holder = panes(holding: url).first {
            moveTab(url, from: holder, toPane: focusedPane)
        } else {
            open(url)
        }
        focusPaneContent()
    }

    /// Close Pane: the pane goes (the focused one, unless another is named) and its
    /// tabs join the pane that takes its room, so no file is closed.
    func closePane(_ pane: PaneLayout.PaneID? = nil) {
        let closing = pane ?? focusedPane
        guard layout.isSplit, layout.contains(closing) else { return }
        let moved = paneTabs[closing] ?? PaneTabs()
        let wasFocused = closing == focusedPane
        withAnimation(WorkspaceLayout.paneAnimation) {
            guard let heir = layout.remove(closing) else { return }
            var tabs = paneTabs
            tabs[closing] = nil
            let kept = tabs[heir] ?? PaneTabs()
            // A file both panes had open keeps the one tab; the others bring their
            // editors along.
            for url in moved.tabs {
                if kept.contains(url) {
                    buffers[url]?.moveAuxiliaryPane(from: closing, to: heir)
                } else {
                    buffers[url]?.movePane(from: closing, to: heir)
                }
            }
            // What was being looked at stays in view.
            let active = wasFocused ? (moved.active ?? kept.active) : kept.active
            tabs[heir] = PaneTabs(tabs: kept.tabs + moved.tabs, active: active)
            paneTabs = tabs
            if wasFocused { focusedPane = heir }
        }
        if tabDropPane == closing { tabDropPane = nil }
        if wasFocused {
            noteActiveTab()
            focusPaneContent()
        }
    }

    /// Close Other Panes: every pane but one goes (the focused one stays, unless
    /// another is named), and their tabs join it, so no file is closed. A file the
    /// pane has open already keeps the one tab.
    func closeOtherPanes(than pane: PaneLayout.PaneID? = nil) {
        let kept = pane ?? focusedPane
        guard layout.isSplit, layout.contains(kept) else { return }
        withAnimation(WorkspaceLayout.paneAnimation) {
            var tabs = paneTabs
            let own = tabs[kept] ?? PaneTabs()
            var joined = own.tabs
            for other in layout.panes where other != kept {
                for url in tabs[other]?.tabs ?? [] {
                    if joined.contains(url) {
                        buffers[url]?.moveAuxiliaryPane(from: other, to: kept)
                    } else {
                        // The first pane to bring a file brings its editor along.
                        buffers[url]?.movePane(from: other, to: kept)
                        joined.append(url)
                    }
                }
                tabs[other] = nil
                layout.remove(other)
            }
            // The pane goes on showing what it showed.
            tabs[kept] = PaneTabs(tabs: joined, active: own.active)
            paneTabs = tabs
            focusedPane = kept
        }
        tabDropPane = nil
        noteActiveTab()
        focusPaneContent()
    }

    /// Moves a tab from one pane to the end of another's bar (dragging it there)
    /// and shows it there. A pane left without tabs goes.
    func moveTab(_ url: URL, from source: PaneLayout.PaneID, toPane target: PaneLayout.PaneID) {
        guard source != target, layout.contains(target), paneTabs[source]?.contains(url) == true else { return }
        withAnimation(WorkspaceLayout.paneAnimation) {
            var tabs = paneTabs
            tabs[source]?.remove(url)
            if tabs[target]?.contains(url) == true {
                // The pane has the file open already, and goes on with its own editor.
                tabs[target]?.activate(url)
                buffers[url]?.moveAuxiliaryPane(from: source, to: target)
            } else {
                tabs[target, default: PaneTabs()].insert(url, at: .max)
                buffers[url]?.movePane(from: source, to: target)
            }
            paneTabs = tabs
            focusedPane = target
            if tabs[source]?.isEmpty != false { closePane(source) }
        }
        noteActiveTab()
        focusPaneContent()
    }

    /// Goes to a pane and gives what it shows the keyboard.
    func focusPane(_ pane: PaneLayout.PaneID) {
        guard layout.contains(pane) else { return }
        if pane != focusedPane {
            focusedPane = pane
            noteActiveTab()
        }
        focusPaneContent()
    }

    /// Focus Next Pane / Focus Previous Pane, in reading order and round again.
    func focusPane(offsetBy offset: Int) {
        guard let pane = layout.pane(from: focusedPane, offsetBy: offset), pane != focusedPane else { return }
        focusPane(pane)
    }

    /// A click landed in the pane: it's the focused one now. The click itself
    /// decides what gets the keyboard.
    func paneWasClicked(_ pane: PaneLayout.PaneID) {
        guard layout.contains(pane), pane != focusedPane else { return }
        focusedPane = pane
        noteActiveTab()
    }

    /// Dragging the divider between two panes.
    func setSplitFraction(_ fraction: Double, of split: PaneLayout.SplitID) {
        layout.setFraction(fraction, of: split)
    }

    /// Gives the keyboard to what the focused pane shows. A pane with nothing to
    /// type in takes it away from the others, so keys don't go on editing a pane
    /// that isn't the focused one.
    func focusPaneContent() {
        guard let window else { return }
        if let buffer = activeBuffer {
            if showsChanges(buffer, in: focusedPane), let changes = buffer.changesPreview {
                changes.focus()
                return
            }
            if showsPreview(buffer, in: focusedPane) {
                if let preview = buffer.preview, preview.webView.window === window {
                    window.makeFirstResponder(preview.webView)
                    return
                }
            } else if let textView = buffer.editor(in: focusedPane)?.textView, textView.window === window {
                window.makeFirstResponder(textView)
                return
            }
            if case .pdf(let file) = buffer.content, !file.isLocked, file.view.window === window {
                window.makeFirstResponder(file.view)
                return
            }
        }
        // A view that isn't in the window yet takes the keyboard when it gets there.
        window.makeFirstResponder(nil)
    }

    // MARK: Preview and changes in a pane

    /// Whether a pane is the one that shows a file's preview or changes. A file
    /// has one view of each, so it's in the pane that asked for it, and any other
    /// pane with the file open shows its text.
    func hostsAuxiliaryView(of buffer: EditorBuffer, in pane: PaneLayout.PaneID) -> Bool {
        let holders = panes(holding: buffer.url)
        if let owner = buffer.auxiliaryPane, holders.contains(owner) { return owner == pane }
        return holders.first == pane
    }

    func showsPreview(_ buffer: EditorBuffer, in pane: PaneLayout.PaneID) -> Bool {
        buffer.isShowingPreview && hostsAuxiliaryView(of: buffer, in: pane)
    }

    func showsChanges(_ buffer: EditorBuffer, in pane: PaneLayout.PaneID) -> Bool {
        buffer.isShowingChanges && hostsAuxiliaryView(of: buffer, in: pane)
    }

    /// Switches a pane between a file's source and its preview. A preview that's
    /// showing in another pane comes over to this one.
    func setShowingPreview(_ show: Bool, of buffer: EditorBuffer, in pane: PaneLayout.PaneID) {
        if show {
            let wasElsewhere = buffer.isShowingPreview && !hostsAuxiliaryView(of: buffer, in: pane)
            buffer.setAuxiliaryPane(pane)
            // The changes cover the preview.
            if wasElsewhere { buffer.hideChanges() } else { buffer.setShowingPreview(true) }
        } else if hostsAuxiliaryView(of: buffer, in: pane) {
            buffer.setShowingPreview(false)
        }
    }

    /// Show Preview / Show Markdown, for the focused pane's tab.
    func togglePreview() {
        guard let buffer = activeBuffer, buffer.previewFormat != nil else { return }
        setShowingPreview(!showsPreview(buffer, in: focusedPane), of: buffer, in: focusedPane)
    }

    /// Makes the focused pane show a file's text, if it's showing the file's
    /// preview or changes: a line or a match is about to be gone to.
    func showText(of buffer: EditorBuffer) {
        guard hostsAuxiliaryView(of: buffer, in: focusedPane) else { return }
        buffer.hideChanges()
        if buffer.isShowingPreview { buffer.setShowingPreview(false) }
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
            buffers[destination] = nil
            for pane in panes(holding: destination) { removeTab(destination, from: pane) }
        }
        buffers[source] = nil
        buffers[destination] = makeBuffer(for: destination)
        let holders = panes(holding: source)
        if holders.isEmpty {
            paneTabs[focusedPane, default: PaneTabs()].insert(destination)
        } else {
            var tabs = paneTabs
            for pane in holders { tabs[pane]?.retarget { $0 == source ? destination : nil } }
            paneTabs = tabs
        }
        savedAsURL = destination
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
        // In one go: a pane whose tabs still had the old name would lose its editors.
        var tabs = paneTabs
        for pane in layout.panes { tabs[pane]?.retarget(moved) }
        paneTabs = tabs
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
        // The files that are still there, by the path they were saved under.
        var reopened: [String: URL] = [:]
        var order: [URL] = []
        for tab in session.tabs {
            let url = sessionURL(for: tab.path)
            var isDirectory: ObjCBool = false
            guard buffers[url] == nil,
                  FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            let buffer = makeBuffer(for: url)
            buffers[url] = buffer
            reopened[tab.path] = url
            order.append(url)
            buffer.textController?.restorePosition(cursor: tab.cursor, topLine: tab.topLine)
        }

        var layout = PaneLayout()
        var tabs: [PaneLayout.PaneID: PaneTabs] = [:]
        var focused = layout.panes[0]
        if let split = session.split, split.layout.isSplit, split.layout.isConsistent {
            layout = split.layout
            var placed = Set<URL>()
            for pane in split.panes where layout.contains(pane.id) && tabs[pane.id] == nil {
                // Text can be open in several panes; an image, a PDF or a video in one.
                let urls = pane.tabs.compactMap { reopened[$0] }.filter {
                    placed.insert($0).inserted || buffers[$0]?.allowsSeveralPanes == true
                }
                tabs[pane.id] = PaneTabs(tabs: urls, active: pane.activeTab.flatMap { reopened[$0] })
            }
            // A pane none of whose files are left has nothing to come back with.
            for pane in layout.panes where tabs[pane]?.isEmpty != false {
                if layout.remove(pane) != nil { tabs[pane] = nil }
            }
            if layout.contains(split.focused) { focused = split.focused } else { focused = layout.panes[0] }
            // A tab no pane was saved with goes in the focused one.
            let rest = order.filter { !placed.contains($0) }
            if !rest.isEmpty {
                let kept = tabs[focused] ?? PaneTabs()
                tabs[focused] = PaneTabs(tabs: kept.tabs + rest, active: kept.active)
            }
        } else {
            tabs[focused] = PaneTabs(tabs: order, active: session.activeTab.map(sessionURL(for:)))
        }
        self.layout = layout
        paneTabs = tabs
        focusedPane = focused
        if let active = activeTab {
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
        func path(_ url: URL?) -> String? {
            url.flatMap { $0.isUntitled ? nil : relativePath(of: $0) }
        }
        // A single pane is saved as the tabs alone, as it was before there were panes.
        let split = layout.isSplit ? ProjectSession.Split(
            layout: layout,
            panes: layout.panes.map { pane in
                .init(id: pane, tabs: self.tabs(in: pane).compactMap { path($0) }, activeTab: path(activeTab(in: pane)))
            },
            focused: focusedPane
        ) : nil
        let session = ProjectSession(
            tabs: tabs,
            activeTab: path(activeTab),
            isSidebarVisible: isSidebarVisible,
            split: split,
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
