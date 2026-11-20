import Foundation
import Observation

/// Coordinates git status, commits, branches, and worktree operations for a workspace.
@Observable
final class SourceControlModel {
    let rootURL: URL
    private let runner = GitRunner.shared

    private(set) var isGitRepository = false
    private(set) var branchName: String?
    private(set) var stagedFiles: [GitFileItem] = []
    private(set) var unstagedFiles: [GitFileItem] = []
    private(set) var commits: [GitCommitItem] = []
    private(set) var branches: [GitBranchItem] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

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

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    // MARK: - Refresh Lifecycle

    func refresh() async {
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
            return
        }

        isGitRepository = true

        async let statusTask = loadStatus()
        async let branchesTask = loadBranches()
        async let commitsTask = loadCommits()

        _ = await (statusTask, branchesTask, commitsTask)
    }

    // MARK: - Status & Diff Stats

    private func loadStatus() async {
        let branchResult = await runner.run(arguments: ["branch", "--show-current"], in: rootURL)
        let rawBranch = branchResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        self.branchName = rawBranch.isEmpty ? "HEAD" : rawBranch

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
                let stat = stagedStats[path] ?? (0, 0)
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
                let stat = unstagedStats[path] ?? (0, 0)
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

    private func loadBranches() async {
        let result = await runner.run(arguments: ["branch", "-a", "--format=%(HEAD) %(refname:short)"], in: rootURL)
        guard result.isSuccess else { return }

        var list: [GitBranchItem] = []
        for line in result.stdout.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let isCurrent = trimmed.hasPrefix("*")
            let name = trimmed.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces)
            let isRemote = name.contains("/")
            list.append(GitBranchItem(name: name, isCurrent: isCurrent, isRemote: isRemote))
        }
        self.branches = list
    }

    private func loadCommits() async {
        let result = await runner.run(arguments: [
            "log", "-n", "30", "--pretty=format:%H%x00%h%x00%an%x00%at%x00%s"
        ], in: rootURL)
        guard result.isSuccess else { return }

        var list: [GitCommitItem] = []
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(separator: "\0", maxSplits: 4, omittingEmptySubsequences: false)
            guard parts.count == 5 else { continue }
            let hash = String(parts[0])
            let shortHash = String(parts[1])
            let author = String(parts[2])
            let timestamp = Double(parts[3]) ?? 0
            let summary = String(parts[4])

            list.append(GitCommitItem(
                hash: hash,
                shortHash: shortHash,
                authorName: author,
                date: Date(timeIntervalSince1970: timestamp),
                summary: summary
            ))
        }
        self.commits = list
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
            errorMessage = result.stderr.isEmpty ? "Commit failed" : result.stderr
            return false
        }
    }

    func push() async {
        let result = await runner.run(arguments: ["push"], in: rootURL)
        if result.isSuccess {
            errorMessage = nil
            await refresh()
        } else {
            errorMessage = result.stderr
        }
    }

    func pull() async {
        let result = await runner.run(arguments: ["pull"], in: rootURL)
        if result.isSuccess {
            errorMessage = nil
            await refresh()
        } else {
            errorMessage = result.stderr
        }
    }

    func fetch() async {
        let result = await runner.run(arguments: ["fetch"], in: rootURL)
        if result.isSuccess {
            errorMessage = nil
            await refresh()
        } else {
            errorMessage = result.stderr
        }
    }

    func checkout(branch: GitBranchItem) async {
        let branchName = branch.isRemote ? String(branch.name.split(separator: "/").dropFirst().joined(separator: "/")) : branch.name
        let result = await runner.run(arguments: ["checkout", branchName], in: rootURL)
        if result.isSuccess {
            errorMessage = nil
            await refresh()
        } else {
            errorMessage = result.stderr
        }
    }

    func createBranch(name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let result = await runner.run(arguments: ["checkout", "-b", trimmed], in: rootURL)
        if result.isSuccess {
            errorMessage = nil
            await refresh()
            return true
        } else {
            errorMessage = result.stderr
            return false
        }
    }

    func initializeRepository() async {
        let result = await runner.run(arguments: ["init"], in: rootURL)
        if result.isSuccess {
            errorMessage = nil
            await refresh()
        } else {
            errorMessage = result.stderr
        }
    }
}
