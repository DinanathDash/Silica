import Foundation

/// A file as it is now against the last commit, or as one commit left it against
/// the commit before, line by line.
nonisolated struct GitDiff: Sendable {
    enum Kind: Sendable {
        case context, added, removed
    }

    struct Line: Sendable {
        let kind: Kind
        /// 1-based line numbers in the committed file and in the file now; a removed
        /// line has only the first and an added line only the second.
        let old: Int?
        let new: Int?
    }

    var lines: [Line]
    var oldText: String
    var newText: String
    /// Both texts were read as UTF-8 without loss, so text put together from
    /// their lines can be written back as the file.
    var canRewrite = false

    var hasChanges: Bool {
        lines.contains { $0.kind != .context }
    }

    /// The changes, each a stretch of `lines`: the lines one edit removed, then
    /// the ones it put in their place.
    var changes: [Range<Int>] {
        var changes: [Range<Int>] = []
        var index = 0
        while index < lines.count {
            guard lines[index].kind != .context else {
                index += 1
                continue
            }
            let start = index
            while index < lines.count, lines[index].kind == .removed { index += 1 }
            while index < lines.count, lines[index].kind == .added { index += 1 }
            changes.append(start..<index)
        }
        return changes
    }

    /// The old text with one change made to it and no other (`applying`), or the
    /// new text with one change taken back out: what the index should hold after
    /// staging or unstaging just that change.
    func text(applying: Bool, change number: Int) -> String {
        let changes = changes
        guard changes.indices.contains(number) else { return applying ? oldText : newText }
        let chosen = changes[number]
        let old = Self.rawLines(of: oldText), new = Self.rawLines(of: newText)
        var text = ""
        for (index, line) in lines.enumerated() {
            // From the new text: unchanged lines, and added ones where the change
            // is wanted. From the old: removed lines where it isn't.
            let takesChange = chosen.contains(index) ? applying : !applying
            switch line.kind {
            case .context:
                if let number = line.new, new.indices.contains(number - 1) { text += new[number - 1] }
            case .added:
                if takesChange, let number = line.new, new.indices.contains(number - 1) { text += new[number - 1] }
            case .removed:
                if !takesChange, let number = line.old, old.indices.contains(number - 1) { text += old[number - 1] }
            }
        }
        return text
    }

    /// The text's lines with their line feeds, so they join back into the text.
    private static func rawLines(of text: String) -> [Substring] {
        // By bytes: as a character, the line feed of a CRLF ending is part of
        // "\r\n" and wouldn't be found.
        var lines: [Substring] = []
        var start = text.startIndex
        let bytes = text.utf8
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let next = bytes.index(after: index)
            if bytes[index] == 0x0A {
                lines.append(text[start..<next])
                start = next
            }
            index = next
        }
        if start < text.endIndex { lines.append(text[start...]) }
        return lines
    }

    /// What to compare.
    struct Request: Sendable {
        /// The file as it is now.
        enum Current: Sendable {
            /// The editor's text, unsaved edits included.
            case text(String)
            /// Deleted: every committed line is gone.
            case missing
            /// An image or other file that isn't shown as text.
            case notText
        }

        var root: URL
        /// Path from the project root.
        var path: String
        /// Where the file was in the last commit, if it has been renamed since.
        var originalPath: String?
        /// `nil` for a file git reports no change to.
        var status: GitFileStatus?
        var current: Current
        /// For a committed file that isn't UTF-8: the encoding the editor read it in.
        var encoding: String.Encoding
        /// To see what one commit did to the file instead: its hash. `status` and
        /// `originalPath` are then the commit's, and `current` isn't looked at.
        var commit: String?
        var comparison = Comparison.all

        /// Which of the file's changes to show.
        enum Comparison: Sendable {
            /// Everything since the last commit.
            case all
            /// What isn't staged: the file now against the index. `status` is
            /// then the unstaged change's.
            case unstaged
            /// What is staged: the index against the last commit. `status` is
            /// then the staged change's.
            case staged
        }
    }

    enum Result: Sendable {
        case diff(GitDiff)
        /// One side isn't text.
        case notText
        /// The committed file couldn't be read.
        case unavailable
    }

    static func load(_ request: Request) -> Result {
        if let commit = request.commit { return load(request, in: commit) }
        var canRewrite = true

        let newText: String
        if request.comparison == .staged {
            // What is staged: the file as the index has it.
            if request.status == .deleted {
                newText = ""
            } else {
                guard let data = committedFile(at: request.path, root: request.root, revision: "") else { return .unavailable }
                guard let (text, isUTF8) = text(of: data, encoding: request.encoding) else { return .notText }
                newText = text
                canRewrite = canRewrite && isUTF8
            }
        } else {
            switch request.current {
            case .text(let text): newText = text
            case .missing: newText = ""
            case .notText: return .notText
            }
            canRewrite = canRewrite && request.encoding == .utf8
        }

        let oldText: String
        switch request.status {
        case .untracked, .added:
            // Not there before: every line is new.
            oldText = ""
        default:
            // Against the index for what isn't staged, else the last commit.
            let isFromIndex = request.comparison == .unstaged
            guard let data = committedFile(
                at: isFromIndex ? request.path : request.originalPath ?? request.path,
                root: request.root, revision: isFromIndex ? "" : "HEAD"
            ) else { return .unavailable }
            guard let (text, isUTF8) = text(of: data, encoding: request.encoding) else { return .notText }
            oldText = text
            canRewrite = canRewrite && isUTF8
        }

        guard let lines = compare(oldText, newText) else { return .unavailable }
        return .diff(GitDiff(lines: lines, oldText: oldText, newText: newText, canRewrite: canRewrite))
    }

    /// What `commit` did to the file: how it was in the commit before (for a
    /// merge, on the branch merged into) against how the commit left it.
    private static func load(_ request: Request, in commit: String) -> Result {
        var texts = ["", ""]
        let sides: [(revision: String, path: String, isAbsent: Bool)] = [
            (commit + "^", request.originalPath ?? request.path, request.status == .added),
            (commit, request.path, request.status == .deleted),
        ]
        for (index, side) in sides.enumerated() where !side.isAbsent {
            guard let data = committedFile(at: side.path, root: request.root, revision: side.revision) else {
                return .unavailable
            }
            guard let (text, _) = text(of: data, encoding: request.encoding) else { return .notText }
            texts[index] = text
        }
        guard let lines = compare(texts[0], texts[1]) else { return .unavailable }
        return .diff(GitDiff(lines: lines, oldText: texts[0], newText: texts[1]))
    }

    /// `nil` for what looks like a binary file. `isUTF8` when the text, written
    /// out as UTF-8, gives back exactly these bytes.
    private static func text(of data: Data, encoding: String.Encoding) -> (text: String, isUTF8: Bool)? {
        guard !data.prefix(8192).contains(0) else { return nil }
        if let text = String(data: data, encoding: .utf8) { return (text, Data(text.utf8) == data) }
        return String(data: data, encoding: encoding).map { ($0, false) }
    }

    /// The file in a commit, the last one unless another is named, or with "" for
    /// the revision, in the index; as a checkout
    /// would write it (line endings converted, filters applied), so it compares
    /// line for line with the file now.
    private static func committedFile(at path: String, root: URL, revision: String = "HEAD") -> Data? {
        guard let repository = GitRepository.locate(containing: root) else { return nil }
        return Git.run([
            "-C", root.path(percentEncoded: false),
            "cat-file", "--filters", revision + ":" + repository.prefix + path,
        ])
    }

    /// Has git compare the two texts, which it does well at any size, and reads
    /// which lines it kept, added and removed. `nil` if git couldn't be run.
    private static func compare(_ oldText: String, _ newText: String) -> [Line]? {
        if oldText == newText {
            let count = lineCount(of: newText)
            return count == 0 ? [] : (1...count).map { Line(kind: .context, old: $0, new: $0) }
        }
        let files = FileManager.default
        let folder = files.temporaryDirectory.appending(path: "silica-diff-" + UUID().uuidString)
        defer { try? files.removeItem(at: folder) }
        let old = folder.appending(path: "old"), new = folder.appending(path: "new")
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(oldText.utf8).write(to: old)
            try Data(newText.utf8).write(to: new)
        } catch {
            return nil
        }
        // With more context than any file has lines, the one hunk is the whole file.
        guard let output = Git.run([
            "diff", "--no-index", "--no-color", "--no-ext-diff", "--no-textconv", "-U1000000000", "--",
            old.path(percentEncoded: false), new.path(percentEncoded: false),
        ], success: 0...1) else { return nil }
        return parse(output)
    }

    private static func lineCount(of text: String) -> Int {
        var count = 0
        var endsInNewline = true
        for unit in text.utf8 {
            endsInNewline = unit == 0x0A
            if endsInNewline { count += 1 }
        }
        return endsInNewline ? count : count + 1
    }

    /// Reads the hunks of a unified diff: a header with each side's first line
    /// number, then lines that start with " " (kept), "-" (removed) or "+" (added).
    static func parse(_ output: Data) -> [Line] {
        var lines: [Line] = []
        var old = 0, new = 0
        var isInHunk = false
        var records = output.split(separator: 0x0A, omittingEmptySubsequences: false)
        if records.last?.isEmpty == true { records.removeLast() }
        for record in records {
            // An empty line is an empty kept line, with `diff.suppressBlankEmpty` on.
            let marker = record.first ?? 0x20
            if marker == UInt8(ascii: "@") {
                // @@ -12,7 +12,9 @@
                let fields = String(decoding: record, as: UTF8.self).split(separator: " ")
                guard fields.count >= 3,
                      let oldStart = Int(fields[1].dropFirst().prefix { $0 != "," }),
                      let newStart = Int(fields[2].dropFirst().prefix { $0 != "," }) else { continue }
                old = oldStart
                new = newStart
                isInHunk = true
                continue
            }
            guard isInHunk else { continue }
            switch marker {
            case UInt8(ascii: " "):
                lines.append(Line(kind: .context, old: old, new: new))
                old += 1
                new += 1
            case UInt8(ascii: "-"):
                lines.append(Line(kind: .removed, old: old, new: nil))
                old += 1
            case UInt8(ascii: "+"):
                lines.append(Line(kind: .added, old: nil, new: new))
                new += 1
            default:
                // "\ No newline at end of file"
                continue
            }
        }
        return lines
    }
}
