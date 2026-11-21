import Foundation
import Observation

public struct GitAlertItem: Identifiable, Equatable {
    public let id = UUID()
    public let title: String
    public let message: String

    public init(title: String, message: String) {
        self.title = title
        self.message = message
    }
}

/// Coordinates git status, commits, branches, and worktree operations for a workspace.
@MainActor
@Observable
final class SourceControlModel {
    let rootURL: URL
    private let runner = GitRunner.shared

    private(set) var isGitRepository = false
    private(set) var branchName: String?
    private(set) var remoteHostType: RemoteHostType = .unknown
    private(set) var stagedFiles: [GitFileItem] = []
    private(set) var unstagedFiles: [GitFileItem] = []
    private(set) var commits: [GitCommitItem] = []
    private(set) var branches: [GitBranchItem] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var stashCount: Int = 0
    var activeAlert: GitAlertItem?
    var activeAlertError: String? {
        get { activeAlert?.message }
        set {
            if let newValue {
                activeAlert = GitAlertItem(title: "Git Alert", message: newValue)
            } else {
                activeAlert = nil
            }
        }
    }
    private var isRefreshing = false

    var commitMessage = ""

    var hasChanges: Bool {
        !stagedFiles.isEmpty || !unstagedFiles.isEmpty
    }

    var totalAdditions: Int {
        stagedFiles.reduce(0) { $0 + $1.additions } + unstagedFiles.reduce(0) { $0 + $1.additions }
    }

    var totalDeletions: Int {
        stagedFiles.reduce(0) { $0 + $1.deletions } + unstagedFiles.reduce(0) { $0 + $1.deletions }
    }

    var repositoryName: String {
        rootURL.lastPathComponent
    }

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    // MARK: - Refresh Lifecycle

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        isLoading = true
        defer { isLoading = false }

        // Check if root or parent is a git repository
        let revParse = await runner.run(arguments: ["rev-parse", "--is-inside-work-tree"], in: rootURL)
        guard revParse.isSuccess && revParse.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            isGitRepository = false
            stagedFiles = []
            unstagedFiles = []
            commits = []
            branches = []
            branchName = nil
            stashCount = 0
            return
        }

        isGitRepository = true
        currentCommitLimit = initialCommitLimit

        await loadStatus()
        await loadBranches()
        await loadCommits()
        await loadStashCount()
    }

    // MARK: - Status & Diff Stats

    private func loadStatus() async {
        let branchResult = await runner.run(arguments: ["branch", "--show-current"], in: rootURL)
        let rawBranch = branchResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        self.branchName = rawBranch.isEmpty ? "HEAD" : rawBranch

        let remoteResult = await runner.run(arguments: ["config", "--get", "remote.origin.url"], in: rootURL)
        let remoteStr = remoteResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if remoteStr.contains("github.com") {
            self.remoteHostType = .github
        } else if remoteStr.contains("gitlab") {
            self.remoteHostType = .gitlab
        } else {
            self.remoteHostType = .unknown
        }

        let statusResult = await runner.run(arguments: ["status", "--porcelain=v1", "-uall"], in: rootURL)
        guard statusResult.isSuccess else { return }

        // Fetch numstat for additions/deletions
        let numstatResult = await runner.run(arguments: ["diff", "--numstat"], in: rootURL)
        let cachedNumstatResult = await runner.run(arguments: ["diff", "--cached", "--numstat"], in: rootURL)

        var unstagedStats: [String: (add: Int, del: Int)] = [:]
        for line in numstatResult.stdout.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2)
            guard parts.count == 3 else { continue }
            let add = Int(parts[0]) ?? 0
            let del = Int(parts[1]) ?? 0
            let path = String(parts[2])
            unstagedStats[path] = (add, del)
        }

        var stagedStats: [String: (add: Int, del: Int)] = [:]
        for line in cachedNumstatResult.stdout.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2)
            guard parts.count == 3 else { continue }
            let add = Int(parts[0]) ?? 0
            let del = Int(parts[1]) ?? 0
            let path = String(parts[2])
            stagedStats[path] = (add, del)
        }

        var newStaged: [GitFileItem] = []
        var newUnstaged: [GitFileItem] = []

        let lines = statusResult.stdout.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines {
            guard line.count >= 3 else { continue }
            let indexCode = line[line.startIndex]
            let workTreeCode = line[line.index(after: line.startIndex)]
            let rawPath = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)

            // Normalize path (handle quotes if git quoted paths with spaces)
            let path = rawPath.hasPrefix("\"") && rawPath.hasSuffix("\"")
                ? String(rawPath.dropFirst().dropLast())
                : rawPath

            // Staged entry if index code is not blank or untracked
            if indexCode != " " && indexCode != "?" && indexCode != "!" {
                let status = mapStatus(code: indexCode)
                var stat = stagedStats[path] ?? (0, 0)
                if status == .added && stat == (0, 0) {
                    stat = (countFileLines(at: rootURL.appending(path: path)), 0)
                }
                newStaged.append(GitFileItem(
                    relativePath: path,
                    status: status,
                    isStaged: true,
                    additions: stat.add,
                    deletions: stat.del
                ))
            }

            // Unstaged entry if working tree code is modified or untracked
            if workTreeCode != " " {
                let status = mapStatus(code: workTreeCode)
                var stat = unstagedStats[path] ?? (0, 0)
                if (status == .untracked || status == .added) && stat == (0, 0) {
                    stat = (countFileLines(at: rootURL.appending(path: path)), 0)
                }
                newUnstaged.append(GitFileItem(
                    relativePath: path,
                    status: status,
                    isStaged: false,
                    additions: stat.add,
                    deletions: stat.del
                ))
            }
        }

        self.stagedFiles = newStaged
        self.unstagedFiles = newUnstaged
    }

    private func countFileLines(at url: URL) -> Int {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return 0
        }
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else {
            return 0
        }
        if content.isEmpty { return 0 }
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines.count
    }

    private func mapStatus(code: Character) -> GitFileItem.Status {
        switch code {
        case "M": .modified
        case "A": .added
        case "D": .deleted
        case "R": .renamed
        case "C": .copied
        case "?": .untracked
        case "!": .ignored
        case "U": .conflict
        default: .unknown
        }
    }

    // MARK: - Commit Files & Diff

    func loadChangedFiles(for commitHash: String) async -> [CommitChangedFile] {
        let numstatResult = await runner.run(arguments: ["show", "--numstat", "--format=", commitHash], in: rootURL)
        let nameStatusResult = await runner.run(arguments: ["show", "--name-status", "--format=", commitHash], in: rootURL)

        var statusMap: [String: GitFileItem.Status] = [:]
        for line in nameStatusResult.stdout.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: "\t", maxSplits: 2)
            guard parts.count >= 2 else { continue }
            let statusCode = parts[0].first ?? "M"
            let path = String(parts.last!)
            statusMap[path] = mapStatus(code: statusCode)
        }

        var files: [CommitChangedFile] = []
        for line in numstatResult.stdout.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2)
            guard parts.count == 3 else { continue }
            let add = Int(parts[0]) ?? 0
            let del = Int(parts[1]) ?? 0
            let rawPath = String(parts[2]).trimmingCharacters(in: .whitespaces)
            let path = rawPath.hasPrefix("\"") && rawPath.hasSuffix("\"")
                ? String(rawPath.dropFirst().dropLast())
                : rawPath
            let status = statusMap[path] ?? .modified
            files.append(CommitChangedFile(
                relativePath: path,
                status: status,
                additions: add,
                deletions: del
            ))
        }
        return files
    }

    func diffForFile(in commitHash: String?, relativePath: String) async -> String {
        if let commitHash {
            let res = await runner.run(arguments: ["show", commitHash, "--", relativePath], in: rootURL)
            return res.stdout
        } else {
            let res = await runner.run(arguments: ["diff", "HEAD", "--", relativePath], in: rootURL)
            if !res.stdout.isEmpty {
                return res.stdout
            }
            let fullURL = rootURL.appending(path: relativePath)
            if let content = try? String(contentsOf: fullURL, encoding: .utf8) {
                let lines = content.components(separatedBy: .newlines)
                return "--- /dev/null\n+++ b/\(relativePath)\n@@ -0,0 +1,\(lines.count) @@\n" + lines.map { "+" + $0 }.joined(separator: "\n")
            }
            return res.stdout
        }
    }

    func stageFolder(_ path: String) async {
        _ = await runner.run(arguments: ["add", "--", path], in: rootURL)
        await loadStatus()
    }

    func unstageFolder(_ path: String) async {
        _ = await runner.run(arguments: ["restore", "--staged", "--", path], in: rootURL)
        await loadStatus()
    }

    func discardFolderChanges(_ path: String) async {
        _ = await runner.run(arguments: ["restore", "--", path], in: rootURL)
        _ = await runner.run(arguments: ["clean", "-fd", "--", path], in: rootURL)
        await loadStatus()
    }

    private func loadBranches() async {
        let result = await runner.run(arguments: ["branch", "-a", "--format=%(HEAD) %(refname) %(refname:short)"], in: rootURL)
        guard result.isSuccess else { return }

        var list: [GitBranchItem] = []
        for line in result.stdout.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let isCurrent = trimmed.hasPrefix("*")
            let stripped = trimmed.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces)
            let tokens = stripped.split(separator: " ", maxSplits: 1)
            guard tokens.count == 2 else { continue }
            let refname = String(tokens[0])
            let shortName = String(tokens[1])

            // Skip symbolic remote HEAD refs like origin/HEAD
            if refname.hasSuffix("/HEAD") { continue }

            let isRemote = refname.hasPrefix("refs/remotes/")
            list.append(GitBranchItem(name: shortName, isCurrent: isCurrent, isRemote: isRemote))
        }
        self.branches = list
    }

    private let initialCommitLimit = 50
    private let commitPageStep = 20
    private(set) var currentCommitLimit = 50
    private(set) var hasMoreCommits = true
    private(set) var isLoadingMoreCommits = false

    var maxHistoryLanes: Int {
        commits.map { $0.timelineNode.lane + 1 }.max() ?? 1
    }

    private struct RawCommitData {
        let hash: String
        let shortHash: String
        let parentHashes: [String]
        let authorName: String
        let authorEmail: String
        let date: Date
        let summary: String
        let body: String
        let filesChanged: Int
        let additions: Int
        let deletions: Int
    }

    private(set) var historyBranch: String? = nil

    func setHistoryBranch(_ branchName: String?) async {
        guard historyBranch != branchName else { return }
        historyBranch = branchName
        currentCommitLimit = initialCommitLimit
        await loadCommits()
    }

    private func loadCommits() async {
        let fetchCount = currentCommitLimit + 1
        var args = [
            "log", "-n", "\(fetchCount)", "--diff-merges=1", "--shortstat",
            "--pretty=format:\u{1e}%H\u{1f}%h\u{1f}%P\u{1f}%an\u{1f}%ae\u{1f}%at\u{1f}%s\u{1f}%b\u{1f}"
        ]
        if let target = historyBranch, !target.isEmpty {
            args.insert(target, at: 1)
        }
        let result = await runner.run(arguments: args, in: rootURL)
        guard result.isSuccess else { return }

        var rawList: [RawCommitData] = []
        let records = result.stdout.split(separator: "\u{1e}", omittingEmptySubsequences: true)
        self.hasMoreCommits = records.count > currentCommitLimit

        for (index, record) in records.enumerated() {
            guard index < currentCommitLimit else { break }
            let fields = record.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard fields.count >= 8 else { continue }

            let hash = String(fields[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !hash.isEmpty else { continue }
            let shortHash = String(fields[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            let parentHashes = fields[2].split(separator: " ").map(String.init)
            let authorName = String(fields[3]).trimmingCharacters(in: .whitespacesAndNewlines)
            let authorEmail = String(fields[4]).trimmingCharacters(in: .whitespacesAndNewlines)
            let timestamp = Double(fields[5].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            let summary = String(fields[6]).trimmingCharacters(in: .whitespacesAndNewlines)
            let body = String(fields[7]).trimmingCharacters(in: .whitespacesAndNewlines)

            let statString = fields.count > 8 ? String(fields[8]) : ""
            let stats = parseDiffStats(statString)

            rawList.append(RawCommitData(
                hash: hash,
                shortHash: shortHash,
                parentHashes: parentHashes,
                authorName: authorName,
                authorEmail: authorEmail,
                date: Date(timeIntervalSince1970: timestamp),
                summary: summary.isEmpty ? "(no commit message)" : summary,
                body: body,
                filesChanged: stats.files,
                additions: stats.additions,
                deletions: stats.deletions
            ))
        }

        self.commits = computeTimeline(from: rawList)
    }

    func loadMoreCommits() async {
        guard !isLoadingMoreCommits && hasMoreCommits else { return }
        isLoadingMoreCommits = true
        defer { isLoadingMoreCommits = false }
        currentCommitLimit += commitPageStep
        await loadCommits()
    }

    func pruneExtraCommits() {
        guard currentCommitLimit > initialCommitLimit else { return }
        currentCommitLimit = initialCommitLimit
        hasMoreCommits = true
        if commits.count > initialCommitLimit {
            commits = Array(commits.prefix(initialCommitLimit))
        }
    }

    private func parseDiffStats(_ text: String) -> (files: Int, additions: Int, deletions: Int) {
        var files = 0
        var additions = 0
        var deletions = 0

        let parts = text.split(separator: ",")
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            let words = trimmed.split(separator: " ")
            guard let count = words.first.flatMap({ Int($0) }) else { continue }
            if trimmed.contains("file") {
                files = count
            } else if trimmed.contains("insertion") {
                additions = count
            } else if trimmed.contains("deletion") {
                deletions = count
            }
        }
        return (files, additions, deletions)
    }

    private func computeTimeline(from rawCommits: [RawCommitData]) -> [GitCommitItem] {
        let maxAllowedLanes = 4
        var activeLanes: [String?] = []
        var items: [GitCommitItem] = []

        for (index, raw) in rawCommits.enumerated() {
            let lane: Int
            let hadIncoming: Bool

            if let existingIndex = activeLanes.firstIndex(of: raw.hash) {
                lane = existingIndex
                hadIncoming = true
            } else {
                if let freeIndex = activeLanes.firstIndex(of: nil) {
                    lane = freeIndex
                } else {
                    lane = activeLanes.count
                    activeLanes.append(nil)
                }
                hadIncoming = index > 0 && lane < activeLanes.count
            }

            let clampedLane = min(lane, maxAllowedLanes - 1)

            var passingLanes: [Int] = []
            for (i, target) in activeLanes.enumerated() where i != lane && target != nil {
                passingLanes.append(min(i, maxAllowedLanes - 1))
            }

            var outgoing: [GitTimelineNode.Connection] = []

            if raw.parentHashes.isEmpty {
                activeLanes[lane] = nil
            } else if raw.parentHashes.count == 1 {
                let p0 = raw.parentHashes[0]
                if let targetLane = activeLanes.firstIndex(of: p0), targetLane != lane {
                    outgoing.append(.init(fromLane: clampedLane, toLane: min(targetLane, maxAllowedLanes - 1)))
                    activeLanes[lane] = nil
                } else {
                    activeLanes[lane] = p0
                    outgoing.append(.init(fromLane: clampedLane, toLane: clampedLane))
                }
            } else {
                // Merge commit with multiple parents
                let p0 = raw.parentHashes[0]
                if let targetLane = activeLanes.firstIndex(of: p0), targetLane != lane {
                    outgoing.append(.init(fromLane: clampedLane, toLane: min(targetLane, maxAllowedLanes - 1)))
                    activeLanes[lane] = nil
                } else {
                    activeLanes[lane] = p0
                    outgoing.append(.init(fromLane: clampedLane, toLane: clampedLane))
                }

                for pk in raw.parentHashes.dropFirst() {
                    if let targetLane = activeLanes.firstIndex(of: pk) {
                        outgoing.append(.init(fromLane: clampedLane, toLane: min(targetLane, maxAllowedLanes - 1)))
                    } else {
                        let newLane: Int
                        if let free = activeLanes.firstIndex(of: nil) {
                            newLane = free
                            activeLanes[free] = pk
                        } else {
                            newLane = activeLanes.count
                            activeLanes.append(pk)
                        }
                        outgoing.append(.init(fromLane: clampedLane, toLane: min(newLane, maxAllowedLanes - 1)))
                    }
                }
            }

            while activeLanes.last == Optional<String>.none {
                activeLanes.removeLast()
            }

            let allLanesInRow = [clampedLane] + passingLanes + outgoing.map(\.toLane) + outgoing.map(\.fromLane)
            let rowMaxLane = allLanesInRow.max() ?? clampedLane

            let node = GitTimelineNode(
                lane: clampedLane,
                hasIncoming: hadIncoming,
                outgoingConnections: outgoing,
                passingLanes: Array(Set(passingLanes)).sorted(),
                maxLanes: min(max(1, activeLanes.count), maxAllowedLanes),
                rowMaxLane: rowMaxLane
            )

            items.append(GitCommitItem(
                hash: raw.hash,
                shortHash: raw.shortHash,
                parentHashes: raw.parentHashes,
                authorName: raw.authorName,
                authorEmail: raw.authorEmail,
                date: raw.date,
                summary: raw.summary,
                body: raw.body,
                filesChanged: raw.filesChanged,
                additions: raw.additions,
                deletions: raw.deletions,
                timelineNode: node
            ))
        }

        return items
    }

    // MARK: - Actions

    func stageFile(_ file: GitFileItem) async {
        _ = await runner.run(arguments: ["add", "--", file.relativePath], in: rootURL)
        await loadStatus()
    }

    func unstageFile(_ file: GitFileItem) async {
        _ = await runner.run(arguments: ["restore", "--staged", "--", file.relativePath], in: rootURL)
        await loadStatus()
    }

    func stageAll() async {
        _ = await runner.run(arguments: ["add", "-A"], in: rootURL)
        await loadStatus()
    }

    func unstageAll() async {
        _ = await runner.run(arguments: ["restore", "--staged", "."], in: rootURL)
        await loadStatus()
    }

    func discardChanges(for file: GitFileItem) async {
        if file.status == .untracked {
            let fullURL = rootURL.appending(path: file.relativePath)
            try? FileManager.default.removeItem(at: fullURL)
        } else {
            _ = await runner.run(arguments: ["restore", "--", file.relativePath], in: rootURL)
        }
        await loadStatus()
    }

    func discardAllChanges() async {
        _ = await runner.run(arguments: ["restore", "."], in: rootURL)
        _ = await runner.run(arguments: ["clean", "-fd"], in: rootURL)
        await loadStatus()
    }

    func cleanErrorMessage(_ raw: String, fallback: String) -> String {
        var clean = raw
        let prefixesToRemove = ["error:", "fatal:", "warning:", "Aborting", "hint:"]
        for prefix in prefixesToRemove {
            clean = clean.replacingOccurrences(of: prefix, with: "", options: .caseInsensitive)
        }
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? fallback : clean
    }

    func parseGitError(_ raw: String, fallbackTitle: String, fallbackMessage: String) -> GitAlertItem {
        let lower = raw.lowercased()

        if lower.contains("authentication failed") ||
           lower.contains("invalid username or password") ||
           lower.contains("could not read username") ||
           lower.contains("permission denied (publickey)") ||
           lower.contains("returned error: 401") ||
           lower.contains("returned error: 403") {
            return GitAlertItem(
                title: "Authentication Failed",
                message: "Git couldn't verify your account credentials. Please check your username, personal access token, or SSH key for this repository."
            )
        }

        if lower.contains("no upstream branch") ||
           lower.contains("set-upstream") ||
           lower.contains("no tracking information") {
            return GitAlertItem(
                title: "No Remote Branch Linked",
                message: "This branch hasn't been connected to a remote branch yet. Push with tracking enabled or publish your branch to the remote repository."
            )
        }

        if lower.contains("updates were rejected") ||
           lower.contains("fetch first") ||
           lower.contains("non-fast-forward") ||
           lower.contains("failed to push some refs") {
            return GitAlertItem(
                title: "Remote Has Newer Changes",
                message: "The remote repository has new commits that you don't have on your computer yet. Pull the latest changes first to combine them before pushing."
            )
        }

        if lower.contains("would be overwritten by checkout") ||
           lower.contains("would be overwritten by merge") ||
           lower.contains("please commit your changes or stash them") {
            return GitAlertItem(
                title: "Uncommitted Changes Conflict",
                message: "You have local edits in your files that would be overwritten. Please commit your changes or stash them in the Changes tab before continuing."
            )
        }

        if lower.contains("automatic merge failed") ||
           lower.contains("merge conflict") ||
           lower.contains("conflict in") ||
           lower.contains("fix conflicts") {
            return GitAlertItem(
                title: "Merge Conflict",
                message: "Changes from both branches overlap in the same files. Open the affected files to resolve the conflicts, then stage and commit your changes."
            )
        }

        if lower.contains("already exists") {
            return GitAlertItem(
                title: "Branch Already Exists",
                message: "A branch with this name already exists in your repository. Please choose a different name or switch to the existing branch."
            )
        }

        if lower.contains("is not fully merged") {
            return GitAlertItem(
                title: "Branch Has Unmerged Work",
                message: "This branch contains commits that haven't been merged into your main branch. Delete it with force if you are sure you want to discard those changes."
            )
        }

        if lower.contains("could not resolve host") ||
           lower.contains("unable to access") ||
           lower.contains("failed to connect") ||
           lower.contains("connection refused") ||
           lower.contains("network is unreachable") ||
           lower.contains("timed out") {
            return GitAlertItem(
                title: "Connection Failed",
                message: "Git couldn't reach the server. Please check your internet connection and verify that the remote server address is reachable."
            )
        }

        if lower.contains("repository not found") ||
           lower.contains("does not appear to be a git repository") {
            return GitAlertItem(
                title: "Repository Not Found",
                message: "The remote repository could not be found. Make sure the URL is typed correctly and that your account has permission to access it."
            )
        }

        if lower.contains("protected branch") ||
           lower.contains("pre-receive hook declined") ||
           lower.contains("protected branch update failed") ||
           lower.contains("gh006") {
            return GitAlertItem(
                title: "Protected Branch",
                message: "This branch is protected by repository rules. You cannot push changes directly to it. Please create a new branch and open a pull request instead."
            )
        }

        if lower.contains("index.lock") ||
           lower.contains("another git process seems to be running") {
            return GitAlertItem(
                title: "Git Is Busy",
                message: "Another Git operation is currently running or a previous task was interrupted. Wait a few moments, or delete the '.git/index.lock' file if it stays locked."
            )
        }

        if lower.contains("nothing to commit") {
            return GitAlertItem(
                title: "Nothing to Commit",
                message: "There are no changes staged for this commit. Stage the files you want to include before committing."
            )
        }

        if lower.contains("no stash entries found") ||
           lower.contains("is not a valid reference") {
            return GitAlertItem(
                title: "No Stash Found",
                message: "There are no saved stashes to restore or delete in this repository."
            )
        }

        if lower.contains("cannot pull with rebase") ||
           lower.contains("cannot rebase: you have unstaged changes") {
            return GitAlertItem(
                title: "Unstaged Edits Detected",
                message: "Git cannot update while you have unstaged changes in your working tree. Please stash or commit your files before pulling."
            )
        }

        if lower.contains("not a valid branch name") ||
           lower.contains("is not a valid branch name") {
            return GitAlertItem(
                title: "Invalid Branch Name",
                message: "Branch names cannot contain spaces, colons, backslashes, or control characters. Please use letters, numbers, hyphens, and slashes."
            )
        }

        if lower.contains("not a git repository") {
            return GitAlertItem(
                title: "Not a Git Repository",
                message: "This directory is not a Git repository. Click 'Initialize Repository' to start tracking changes."
            )
        }

        if lower.contains("no such remote") ||
           lower.contains("no remote repository specified") {
            return GitAlertItem(
                title: "No Remote Configured",
                message: "This repository has no remote server linked. Add a remote origin before pushing or pulling."
            )
        }

        let cleaned = cleanErrorMessage(raw, fallback: fallbackMessage)
        return GitAlertItem(title: fallbackTitle, message: cleaned)
    }

    func commit() async -> Bool {
        let trimmed = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // If no staged changes exist but unstaged changes do, offer auto-staging or stage tracked
        if stagedFiles.isEmpty && !unstagedFiles.isEmpty {
            _ = await runner.run(arguments: ["add", "-u"], in: rootURL)
        }

        let result = await runner.run(arguments: ["commit", "-m", trimmed], in: rootURL)
        if result.isSuccess {
            commitMessage = ""
            errorMessage = nil
            await refresh()
            return true
        } else {
            let alert = parseGitError(result.stderr, fallbackTitle: "Commit Failed", fallbackMessage: "Could not create commit.")
            errorMessage = alert.message
            activeAlert = alert
            return false
        }
    }

    func push() async {
        let result = await runner.run(arguments: ["push"], in: rootURL)
        if result.isSuccess {
            errorMessage = nil
            await refresh()
        } else {
            let alert = parseGitError(result.stderr, fallbackTitle: "Push Failed", fallbackMessage: "Could not push commits to the remote repository.")
            errorMessage = alert.message
            activeAlert = alert
        }
    }

    func pull() async {
        let result = await runner.run(arguments: ["pull"], in: rootURL)
        if result.isSuccess {
            errorMessage = nil
            await refresh()
        } else {
            let alert = parseGitError(result.stderr, fallbackTitle: "Pull Failed", fallbackMessage: "Could not pull updates from the remote repository.")
            errorMessage = alert.message
            activeAlert = alert
        }
    }

    func fetch(prune: Bool = false) async {
        var args = ["fetch"]
        if prune {
            args.append("--prune")
        }
        let result = await runner.run(arguments: args, in: rootURL)
        if result.isSuccess {
            errorMessage = nil
            await refresh()
        } else {
            let alert = parseGitError(result.stderr, fallbackTitle: "Fetch Failed", fallbackMessage: "Could not fetch changes from the remote repository.")
            errorMessage = alert.message
            activeAlert = alert
        }
    }

    private func loadStashCount() async {
        let result = await runner.run(arguments: ["stash", "list"], in: rootURL)
        guard result.isSuccess else {
            stashCount = 0
            return
        }
        let lines = result.stdout.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        stashCount = lines.count
    }

    @discardableResult
    func stash(message: String? = nil) async -> Bool {
        var args = ["stash", "push", "-u"]
        if let msg = message?.trimmingCharacters(in: .whitespacesAndNewlines), !msg.isEmpty {
            args.append(contentsOf: ["-m", msg])
        }
        let result = await runner.run(arguments: args, in: rootURL)
        if result.isSuccess {
            errorMessage = nil
            await refresh()
            return true
        } else {
            let alert = parseGitError(result.stderr, fallbackTitle: "Stash Failed", fallbackMessage: "Could not stash working changes.")
            errorMessage = alert.message
            activeAlert = alert
            return false
        }
    }

    @discardableResult
    func popStash() async -> Bool {
        let result = await runner.run(arguments: ["stash", "pop"], in: rootURL)
        if result.isSuccess {
            errorMessage = nil
            await refresh()
            return true
        } else {
            let alert = parseGitError(result.stderr, fallbackTitle: "Pop Stash Failed", fallbackMessage: "Could not restore the latest stash.")
            errorMessage = alert.message
            activeAlert = alert
            return false
        }
    }

    @discardableResult
    func applyStash() async -> Bool {
        let result = await runner.run(arguments: ["stash", "apply"], in: rootURL)
        if result.isSuccess {
            errorMessage = nil
            await refresh()
            return true
        } else {
            let alert = parseGitError(result.stderr, fallbackTitle: "Apply Stash Failed", fallbackMessage: "Could not apply the latest stash.")
            errorMessage = alert.message
            activeAlert = alert
            return false
        }
    }

    @discardableResult
    func dropStash() async -> Bool {
        let result = await runner.run(arguments: ["stash", "drop"], in: rootURL)
        if result.isSuccess {
            errorMessage = nil
            await refresh()
            return true
        } else {
            let alert = parseGitError(result.stderr, fallbackTitle: "Drop Stash Failed", fallbackMessage: "Could not drop the latest stash.")
            errorMessage = alert.message
            activeAlert = alert
            return false
        }
    }

    @discardableResult
    func checkout(branch: GitBranchItem) async -> (success: Bool, error: String?) {
        let branchName = branch.isRemote ? String(branch.name.split(separator: "/").dropFirst().joined(separator: "/")) : branch.name
        let result = await runner.run(arguments: ["checkout", branchName], in: rootURL)
        if result.isSuccess {
            errorMessage = nil
            await refresh()
            return (true, nil)
        } else {
            let alert = parseGitError(result.stderr, fallbackTitle: "Checkout Failed", fallbackMessage: "Could not switch to branch “\(branchName)”.")
            errorMessage = alert.message
            return (false, result.stderr)
        }
    }

    func createBranch(name: String, from baseBranch: String? = nil) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var args = ["checkout", "-b", trimmed]
        if let base = baseBranch?.trimmingCharacters(in: .whitespacesAndNewlines), !base.isEmpty {
            args.append(base)
        }
        let result = await runner.run(arguments: args, in: rootURL)
        if result.isSuccess {
            errorMessage = nil
            await refresh()
            return true
        } else {
            let alert = parseGitError(result.stderr, fallbackTitle: "Create Branch Failed", fallbackMessage: "Failed to create branch “\(trimmed)”.")
            errorMessage = alert.message
            activeAlert = alert
            return false
        }
    }

    func deleteBranch(branch: GitBranchItem, force: Bool = true) async -> Bool {
        guard !branch.isCurrent else { return false }
        let result: GitRunner.Result
        if branch.isRemote {
            let parts = branch.name.split(separator: "/", maxSplits: 1)
            if parts.count == 2 {
                let remote = String(parts[0])
                let remoteBranch = String(parts[1])
                result = await runner.run(arguments: ["push", remote, "--delete", remoteBranch], in: rootURL)
            } else {
                result = await runner.run(arguments: ["branch", "-r", "-d", branch.name], in: rootURL)
            }
        } else {
            let safeResult = await runner.run(arguments: ["branch", "-d", branch.name], in: rootURL)
            if !safeResult.isSuccess && force {
                result = await runner.run(arguments: ["branch", "-D", branch.name], in: rootURL)
            } else {
                result = safeResult
            }
        }

        if result.isSuccess {
            errorMessage = nil
            await refresh()
            return true
        } else {
            let alert = parseGitError(result.stderr, fallbackTitle: "Delete Branch Failed", fallbackMessage: "Failed to delete branch “\(branch.name)”.")
            errorMessage = alert.message
            activeAlert = alert
            return false
        }
    }

    func initializeRepository() async {
        let result = await runner.run(arguments: ["init"], in: rootURL)
        if result.isSuccess {
            errorMessage = nil
            await refresh()
        } else {
            let alert = parseGitError(result.stderr, fallbackTitle: "Init Failed", fallbackMessage: "Failed to initialize repository.")
            errorMessage = alert.message
            activeAlert = alert
        }
    }
}
