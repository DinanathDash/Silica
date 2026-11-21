import Foundation

/// A commit on the current branch, as the Changes panel's history lists it.
nonisolated struct GitCommit: Sendable, Equatable, Identifiable {
    let hash: String
    let shortHash: String
    let author: String
    let date: Date
    /// The message's first line, and the rest of it.
    let subject: String
    let body: String
    /// Not on the branch's upstream yet: a push would send it.
    var isUnpushed = false

    var id: String { hash }
}

/// Changes put aside with `git stash`, newest first at index 0.
nonisolated struct GitStash: Sendable, Equatable, Identifiable {
    /// Its place in the list, as in "stash@{2}". It moves when a newer stash is
    /// made or dropped, so `commit.hash` is what says which stash this is.
    let index: Int
    /// The commit git keeps the stash as. Its subject is the stash's message, or
    /// what git wrote for one ("WIP on main: …"); its files are the tracked files
    /// the stash holds changes to.
    let commit: GitCommit

    var id: String { commit.hash }
}

/// Who last changed a line of a file, and in which commit.
nonisolated struct GitBlameLine: Sendable, Equatable {
    let hash: String
    let author: String
    let date: Date
    let summary: String

    /// A line changed since the last commit: git blames it on a commit of zeros.
    var isUncommitted: Bool { hash.allSatisfy { $0 == "0" } }
}

/// A file a commit changed.
nonisolated struct GitCommitFile: Sendable, Equatable, Identifiable {
    /// The commit's hash.
    let commit: String
    /// Path from the project root.
    let path: String
    let status: GitFileStatus
    /// Where the file was before the commit, if the commit renamed it.
    let originalPath: String?

    /// Apart from the same file in another commit: the history lists both.
    var id: String { "commit-file:" + commit + ":" + path }
}

/// Reads the current branch's commits, newest first.
nonisolated enum GitHistory {
    /// Up to `limit` commits from HEAD back. `markingUnpushed` is for a branch
    /// that is ahead of its upstream.
    static func load(root: URL, limit: Int, markingUnpushed: Bool, file: String? = nil) -> [GitCommit] {
        let path = root.path(percentEncoded: false)
        // Fields end in a unit separator and commits in NUL: a message's body has
        // lines of its own. For one file: the commits that changed it, under
        // whatever name it had then.
        guard let output = Git.run([
            "--literal-pathspecs", "-C", path, "log", "-z", "-n", String(limit),
            "--format=%H%x1f%h%x1f%an%x1f%at%x1f%s%x1f%b",
        ] + (file.map { ["--follow", "--", $0] } ?? [])) else { return [] }
        var unpushed: Set<String> = []
        if markingUnpushed,
           let hashes = Git.run(["-C", path, "rev-list", "-n", String(limit), "@{upstream}..HEAD"]) {
            unpushed = Set(String(decoding: hashes, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init))
        }
        return output.split(separator: 0).compactMap { record in
            let fields = String(decoding: record, as: UTF8.self)
                .split(separator: "\u{1F}", maxSplits: 5, omittingEmptySubsequences: false)
            guard fields.count == 6, let seconds = TimeInterval(fields[3]) else { return nil }
            return GitCommit(
                hash: String(fields[0]), shortHash: String(fields[1]), author: String(fields[2]),
                date: Date(timeIntervalSince1970: seconds), subject: String(fields[4]),
                body: fields[5].trimmingCharacters(in: .whitespacesAndNewlines),
                isUnpushed: unpushed.contains(String(fields[0]))
            )
        }
    }

    /// Who last changed each line of the file as it is on disk, in order.
    static func blame(of file: String, root: URL) -> [GitBlameLine] {
        guard let output = Git.run([
            "--literal-pathspecs", "-C", root.path(percentEncoded: false), "blame", "--porcelain", "--", file,
        ]) else { return [] }
        struct Commit { var author = ""; var time: TimeInterval = 0; var summary = "" }
        var commits: [String: Commit] = [:]
        var lines: [GitBlameLine] = []
        var current = ""
        // For each line of the file: "<hash> <was line> <is line> …", then, the
        // first time a commit comes up, what's known of it, then a tab and the line.
        for record in output.split(separator: 0x0A, omittingEmptySubsequences: false) {
            if record.first == 0x09 {
                let commit = commits[current] ?? Commit()
                lines.append(GitBlameLine(
                    hash: current, author: commit.author,
                    date: Date(timeIntervalSince1970: commit.time), summary: commit.summary
                ))
                continue
            }
            let line = String(decoding: record, as: UTF8.self)
            let space = line.firstIndex(of: " ") ?? line.endIndex
            let key = line[..<space]
            let value = space < line.endIndex ? String(line[line.index(after: space)...]) : ""
            switch key {
            case "author": commits[current, default: Commit()].author = value
            case "author-time": commits[current, default: Commit()].time = TimeInterval(value) ?? 0
            case "summary": commits[current, default: Commit()].summary = value
            default:
                if key.count >= 40, key.allSatisfy(\.isHexDigit) { current = String(key) }
            }
        }
        return lines
    }

    /// Every stash, newest first.
    static func stashes(root: URL) -> [GitStash] {
        guard let output = Git.run([
            "-C", root.path(percentEncoded: false), "stash", "list", "-z",
            "--format=%H%x1f%h%x1f%gd%x1f%at%x1f%gs",
        ]) else { return [] }
        return output.split(separator: 0).compactMap { record in
            let fields = String(decoding: record, as: UTF8.self)
                .split(separator: "\u{1F}", maxSplits: 4, omittingEmptySubsequences: false)
            // stash@{2}
            guard fields.count == 5, let seconds = TimeInterval(fields[3]),
                  let index = Int(fields[2].drop { $0 != "{" }.dropFirst().prefix { $0 != "}" }) else { return nil }
            var message = fields[4].trimmingCharacters(in: .whitespacesAndNewlines)
            // "On main: the message given"; without one, "WIP on main: 1a2b3c4 the
            // last commit's subject", which says where the stash was made.
            if message.hasPrefix("On "), let colon = message.range(of: ": ") {
                message = String(message[colon.upperBound...])
            }
            return GitStash(index: index, commit: GitCommit(
                hash: String(fields[0]), shortHash: String(fields[1]), author: "",
                date: Date(timeIntervalSince1970: seconds), subject: message, body: ""
            ))
        }
    }

    /// The files in the project folder that the commit changed. For a merge,
    /// that's against the branch it was merged into.
    static func files(of hash: String, root: URL) -> [GitCommitFile] {
        // `--relative` leaves out what's outside the project folder and gives
        // paths from it.
        guard let output = Git.run([
            "-C", root.path(percentEncoded: false),
            "show", "--diff-merges=first-parent", "--format=", "--name-status", "-z", "-M", "--relative", hash,
        ]) else { return [] }
        var files: [GitCommitFile] = []
        var fields = output.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.makeIterator()
        while let code = fields.next()?.trimmingCharacters(in: .whitespacesAndNewlines) {
            guard let kind = code.first else { continue }
            // A rename or a copy (R100, C75) names the old path, then the new one.
            var original: String?
            if kind == "R" || kind == "C" { original = fields.next() }
            guard let path = fields.next() else { break }
            let status: GitFileStatus = switch kind {
            case "A", "C": .added
            case "D": .deleted
            case "R": .renamed
            default: .modified
            }
            files.append(GitCommitFile(commit: hash, path: path, status: status, originalPath: kind == "R" ? original : nil))
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
