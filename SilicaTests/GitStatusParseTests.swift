import Foundation
import Testing

// What `git status --porcelain=v2 --branch --show-stash -z` writes, record by
// record. The shapes are git's own: see "Porcelain Format Version 2" in
// git-status(1).

private let hashA = String(repeating: "a", count: 40)
private let hashB = String(repeating: "b", count: 40)
private let hashC = String(repeating: "c", count: 40)

/// Each record ends in NUL, the headers too.
private func porcelain(_ records: [String]) -> Data {
    Data(records.map { $0 + "\0" }.joined().utf8)
}

/// A changed file that is neither renamed nor in conflict.
private func ordinary(_ xy: String, _ path: String) -> String {
    "1 \(xy) N... 100644 100644 100644 \(hashA) \(hashB) \(path)"
}

/// A renamed file: its record, then where it was as a record of its own.
private func renamed(_ xy: String, _ path: String, from original: String, score: String = "R100") -> [String] {
    ["2 \(xy) N... 100644 100644 100644 \(hashA) \(hashB) \(score) \(path)", original]
}

/// A file in conflict.
private func unmerged(_ xy: String, _ path: String) -> String {
    "u \(xy) N... 100644 100644 100644 100644 \(hashA) \(hashB) \(hashC) \(path)"
}

private func parse(_ records: [String], prefix: String = "") -> GitStatus.Report {
    GitStatus.parse(porcelain(records), prefix: prefix)
}

@Suite("GitStatus.parse: branch and stash headers")
struct GitStatusHeaderTests {
    @Test func readsBranchItsUpstreamAndHowFarApartTheyAre() {
        let report = parse([
            "# branch.oid \(hashA)",
            "# branch.head main",
            "# branch.upstream origin/main",
            "# branch.ab +2 -1",
        ])
        #expect(report.branch.name == "main")
        #expect(report.branch.hasCommits)
        #expect(report.branch.head == hashA)
        #expect(report.branch.upstream == "origin/main")
        #expect(report.branch.ahead == 2)
        #expect(report.branch.behind == 1)
        #expect(report.files.isEmpty)
    }

    @Test func aBranchLevelWithItsUpstreamIsNeitherAheadNorBehind() {
        let report = parse(["# branch.oid \(hashA)", "# branch.head main", "# branch.upstream origin/main", "# branch.ab +0 -0"])
        #expect(report.branch.ahead == 0)
        #expect(report.branch.behind == 0)
    }

    @Test func aNewRepositoryHasNoCommits() {
        let report = parse(["# branch.oid (initial)", "# branch.head main"])
        #expect(!report.branch.hasCommits)
        #expect(report.branch.head == nil)
        #expect(report.branch.name == "main")
    }

    @Test func aDetachedHeadHasNoBranchName() {
        let report = parse(["# branch.oid \(hashA)", "# branch.head (detached)"])
        #expect(report.branch.name == nil)
        #expect(report.branch.head == hashA)
        #expect(report.branch.hasCommits)
    }

    @Test func withoutAnUpstreamThereIsNothingToCount() {
        let report = parse(["# branch.oid \(hashA)", "# branch.head topic"])
        #expect(report.branch.upstream == nil)
        #expect(report.branch.ahead == nil)
        #expect(report.branch.behind == nil)
    }

    /// git leaves the "branch.ab" line out when the upstream branch was deleted.
    @Test func anUpstreamThatIsGoneIsNamedButNotCounted() {
        let report = parse(["# branch.oid \(hashA)", "# branch.head topic", "# branch.upstream origin/topic"])
        #expect(report.branch.upstream == "origin/topic")
        #expect(report.branch.ahead == nil)
        #expect(report.branch.behind == nil)
    }

    @Test func readsHowManyStashesThereAre() {
        #expect(parse(["# branch.oid \(hashA)", "# branch.head main", "# stash 3"]).stashCount == 3)
        #expect(parse(["# branch.oid \(hashA)", "# branch.head main"]).stashCount == 0)
    }

    @Test func theStashLineDoesNotDisturbTheBranch() {
        let report = parse(["# branch.oid \(hashA)", "# branch.head main", "# branch.upstream origin/main", "# branch.ab +1 -0", "# stash 1"])
        #expect(report.branch.name == "main")
        #expect(report.branch.upstream == "origin/main")
        #expect(report.branch.ahead == 1)
        #expect(report.stashCount == 1)
    }

    @Test func noOutputIsACleanReport() {
        let report = GitStatus.parse(Data(), prefix: "")
        #expect(report.files.isEmpty)
        #expect(report.staged.isEmpty)
        #expect(report.unstaged.isEmpty)
        #expect(report.renamedFrom.isEmpty)
        #expect(report.stashCount == 0)
        #expect(report.branch == GitBranch())
    }
}

/// One XY pair and what each side of it comes to.
nonisolated struct StatusCase: Sendable, CustomTestStringConvertible {
    var xy: String
    /// Against the last commit, as the explorer shows it.
    var file: GitFileStatus
    /// X, the change in the index, and Y, the one in the working tree.
    var staged: GitFileStatus?
    var unstaged: GitFileStatus?

    var testDescription: String { xy }
}

@Suite("GitStatus.parse: entries")
struct GitStatusEntryTests {
    @Test(arguments: [
        StatusCase(xy: ".M", file: .modified, staged: nil, unstaged: .modified),
        StatusCase(xy: "M.", file: .modified, staged: .modified, unstaged: nil),
        StatusCase(xy: "MM", file: .modified, staged: .modified, unstaged: .modified),
        StatusCase(xy: "A.", file: .added, staged: .added, unstaged: nil),
        StatusCase(xy: "AM", file: .added, staged: .added, unstaged: .modified),
        StatusCase(xy: "D.", file: .deleted, staged: .deleted, unstaged: nil),
        StatusCase(xy: ".D", file: .deleted, staged: nil, unstaged: .deleted),
        StatusCase(xy: "MD", file: .deleted, staged: .modified, unstaged: .deleted),
        StatusCase(xy: "AD", file: .deleted, staged: .added, unstaged: .deleted),
        // A change of type: a file that became a symlink, say.
        StatusCase(xy: ".T", file: .modified, staged: nil, unstaged: .modified),
        StatusCase(xy: "T.", file: .modified, staged: .modified, unstaged: nil),
    ])
    func ordinaryEntry(_ entry: StatusCase) {
        let report = parse([ordinary(entry.xy, "src/file.swift")])
        #expect(report.files == ["src/file.swift": entry.file])
        #expect(report.staged["src/file.swift"] == entry.staged)
        #expect(report.unstaged["src/file.swift"] == entry.unstaged)
        #expect(report.staged.count == (entry.staged == nil ? 0 : 1))
        #expect(report.unstaged.count == (entry.unstaged == nil ? 0 : 1))
        #expect(report.renamedFrom.isEmpty)
    }

    /// `git add --intent-to-add` gives ".A": a file the last commit doesn't
    /// have, with nothing of it staged. Were it reported as modified, its diff
    /// would look in the last commit for an old side that isn't there.
    @Test func aFileAddedWithIntentToAddIsUnstagedAndNew() {
        let report = parse([ordinary(".A", "src/new.swift")])
        #expect(report.files == ["src/new.swift": .added])
        #expect(report.staged.isEmpty)
        #expect(report.unstaged == ["src/new.swift": .added])
    }

    @Test(arguments: [
        StatusCase(xy: "R.", file: .renamed, staged: .renamed, unstaged: nil),
        StatusCase(xy: "RM", file: .renamed, staged: .renamed, unstaged: .modified),
        StatusCase(xy: "RD", file: .deleted, staged: .renamed, unstaged: .deleted),
        // A copy, which git only reports with `status.renames = copies`.
        StatusCase(xy: "C.", file: .renamed, staged: .renamed, unstaged: nil),
    ])
    func renamedEntry(_ entry: StatusCase) {
        let report = parse(renamed(entry.xy, "src/new name.swift", from: "old/old name.swift"))
        #expect(report.files == ["src/new name.swift": entry.file])
        #expect(report.staged == ["src/new name.swift": .renamed])
        #expect(report.unstaged["src/new name.swift"] == entry.unstaged)
        #expect(report.unstaged.count == (entry.unstaged == nil ? 0 : 1))
        #expect(report.renamedFrom == ["src/new name.swift": "old/old name.swift"])
    }

    /// The old path is a record of its own, and whatever it looks like, it is
    /// not an entry.
    @Test func theOldPathOfARenameIsNotReadAsAnEntry() {
        let report = parse(
            renamed("R.", "b.txt", from: "? looks untracked.txt", score: "R087")
                + [ordinary(".M", "c.txt"), "? d.txt"]
        )
        #expect(report.files == ["b.txt": .renamed, "c.txt": .modified, "d.txt": .untracked])
        #expect(report.renamedFrom == ["b.txt": "? looks untracked.txt"])
        #expect(report.staged == ["b.txt": .renamed])
        #expect(report.unstaged == ["c.txt": .modified, "d.txt": .untracked])
    }

    @Test(arguments: ["UU", "AA", "DD", "AU", "UA", "DU", "UD"])
    func unmergedEntry(_ xy: String) {
        let report = parse([unmerged(xy, "src/file.swift")])
        #expect(report.files == ["src/file.swift": .conflicted])
        #expect(report.unstaged == ["src/file.swift": .conflicted])
        #expect(report.staged.isEmpty)
    }

    @Test func untrackedFilesAreUnstaged() {
        let report = parse(["? notes.txt", "? docs/draft.md"])
        #expect(report.files == ["notes.txt": .untracked, "docs/draft.md": .untracked])
        #expect(report.unstaged == ["notes.txt": .untracked, "docs/draft.md": .untracked])
        #expect(report.staged.isEmpty)
    }

    @Test func ignoredFilesAndUnknownRecordsAreLeftOut() {
        let report = parse(["! build/output.o", "x something else", ordinary(".M", "kept.txt")])
        #expect(report.files == ["kept.txt": .modified])
    }

    @Test func recordsCutShortAreLeftOut() {
        let report = parse([
            "1 .M N... 100644 100644 100644 \(hashA)",
            "u UU N... 100644 100644 100644 100644 \(hashA) \(hashB)",
            ordinary("M.", "kept.txt"),
        ])
        #expect(report.files == ["kept.txt": .modified])
        #expect(report.staged == ["kept.txt": .modified])
        #expect(report.unstaged.isEmpty)
    }

    /// With `-z` a path is written as it is: spaces, even leading or doubled
    /// ones, are part of it and don't separate fields.
    @Test func pathsKeepTheirSpaces() {
        let report = parse(
            [ordinary(".M", " leading  and double.txt"), unmerged("UU", "my docs/a b.txt"), "? to do.txt", "?  two spaces.txt"]
                + renamed("R.", "new folder/a file.txt", from: "old folder/a file.txt")
        )
        #expect(report.files == [
            " leading  and double.txt": .modified,
            "my docs/a b.txt": .conflicted,
            "to do.txt": .untracked,
            " two spaces.txt": .untracked,
            "new folder/a file.txt": .renamed,
        ])
        #expect(report.renamedFrom == ["new folder/a file.txt": "old folder/a file.txt"])
    }

    @Test func pathsKeepWhatIsNotASCII() {
        let report = parse([ordinary(".M", "docs/日本語 ファイル.md"), "? café/naïve 🙂.txt", "? line\nbreak.txt"])
        #expect(report.files == [
            "docs/日本語 ファイル.md": .modified,
            "café/naïve 🙂.txt": .untracked,
            "line\nbreak.txt": .untracked,
        ])
    }

    /// A nested repository is listed as a folder, with a trailing slash.
    @Test func aNestedRepositoryIsListedUnderItsFoldersPath() {
        let report = parse(["? vendor/library/", ordinary(".M", "submodule")])
        #expect(report.files == ["vendor/library": .untracked, "submodule": .modified])
    }

    /// A file with both kinds of change is in both lists; the explorer has it once.
    @Test func everySideOfEveryEntryIsSortedIntoStagedAndUnstaged() {
        let report = parse(
            [
                "# branch.oid \(hashA)", "# branch.head main",
                ordinary("M.", "staged.txt"),
                ordinary(".M", "unstaged.txt"),
                ordinary("MM", "both.txt"),
                ordinary("A.", "new.txt"),
                ordinary("D.", "gone.txt"),
                ordinary(".D", "missing.txt"),
            ]
                + renamed("RM", "moved.txt", from: "was.txt")
                + [unmerged("UU", "conflict.txt"), "? untracked.txt"]
        )
        #expect(report.files == [
            "staged.txt": .modified, "unstaged.txt": .modified, "both.txt": .modified,
            "new.txt": .added, "gone.txt": .deleted, "missing.txt": .deleted,
            "moved.txt": .renamed, "conflict.txt": .conflicted, "untracked.txt": .untracked,
        ])
        #expect(report.staged == [
            "staged.txt": .modified, "both.txt": .modified, "new.txt": .added,
            "gone.txt": .deleted, "moved.txt": .renamed,
        ])
        #expect(report.unstaged == [
            "unstaged.txt": .modified, "both.txt": .modified, "missing.txt": .deleted,
            "moved.txt": .modified, "conflict.txt": .conflicted, "untracked.txt": .untracked,
        ])
        #expect(report.renamedFrom == ["moved.txt": "was.txt"])
    }
}

@Suite("GitStatus.parse: a project in a folder of its repository")
struct GitStatusPrefixTests {
    /// git names every path from the working tree's root, wherever it is run.
    @Test func pathsAreGivenFromTheProjectFolder() {
        let report = parse(
            [ordinary(".M", "app/src/main.swift"), ordinary("A.", "app/new.txt"), unmerged("UU", "app/conflict.txt"), "? app/notes/todo.txt"],
            prefix: "app/"
        )
        #expect(report.files == [
            "src/main.swift": .modified, "new.txt": .added, "conflict.txt": .conflicted, "notes/todo.txt": .untracked,
        ])
        #expect(report.staged == ["new.txt": .added])
        #expect(report.unstaged == ["src/main.swift": .modified, "conflict.txt": .conflicted, "notes/todo.txt": .untracked])
    }

    @Test func pathsOutsideTheProjectFolderAreDropped() {
        let report = parse(
            [
                ordinary(".M", "lib/outside.swift"),
                ordinary("M.", "README.md"),
                // Not in "app/", though its name starts the same way.
                ordinary(".M", "application/main.swift"),
                ordinary(".M", "app.swift"),
                unmerged("UU", "lib/conflict.txt"),
                "? other/untracked.txt",
                ordinary(".M", "app/inside.swift"),
            ]
                + renamed("R.", "lib/new.txt", from: "lib/old.txt"),
            prefix: "app/"
        )
        #expect(report.files == ["inside.swift": .modified])
        #expect(report.staged.isEmpty)
        #expect(report.unstaged == ["inside.swift": .modified])
        #expect(report.renamedFrom.isEmpty)
    }

    @Test func aDeeperPrefixIsRemovedWhole() {
        let report = parse(
            [ordinary(".M", "packages/editor/src/a.swift"), ordinary(".M", "packages/terminal/src/b.swift"), "? packages/editor/c.swift"],
            prefix: "packages/editor/"
        )
        #expect(report.files == ["src/a.swift": .modified, "c.swift": .untracked])
    }

    @Test func aRenameInsideTheProjectFolderKeepsBothPaths() {
        let report = parse(renamed("R.", "app/new/name.txt", from: "app/old/name.txt"), prefix: "app/")
        #expect(report.files == ["new/name.txt": .renamed])
        #expect(report.renamedFrom == ["new/name.txt": "old/name.txt"])
    }

    /// The file is the project's; where it came from is not, and has no path
    /// from the project folder to give.
    @Test func aRenameIntoTheProjectFolderHasNoOldPath() {
        let report = parse(renamed("R.", "app/moved.txt", from: "lib/moved.txt") + [ordinary(".M", "app/next.txt")], prefix: "app/")
        #expect(report.files == ["moved.txt": .renamed, "next.txt": .modified])
        #expect(report.staged == ["moved.txt": .renamed])
        #expect(report.renamedFrom.isEmpty)
    }

    /// Its old path, in the project folder, comes after it and is not an entry.
    @Test func aRenameOutOfTheProjectFolderIsDropped() {
        let report = parse(renamed("R.", "lib/moved.txt", from: "app/moved.txt") + [ordinary(".M", "app/next.txt")], prefix: "app/")
        #expect(report.files == ["next.txt": .modified])
        #expect(report.staged.isEmpty)
        #expect(report.renamedFrom.isEmpty)
    }

    @Test func aNestedRepositoryLosesThePrefixAndItsSlash() {
        let report = parse(["? app/vendor/library/"], prefix: "app/")
        #expect(report.files == ["vendor/library": .untracked])
    }

    /// The project folder as a whole (untracked, in a repository further up) is
    /// no file inside it.
    @Test func theProjectFolderItselfIsNotAnEntry() {
        let report = parse(["? app/"], prefix: "app/")
        #expect(report.files.isEmpty)
        #expect(report.unstaged.isEmpty)
    }

    @Test func headersAreReadWhateverThePrefix() {
        let report = parse(
            ["# branch.oid \(hashA)", "# branch.head main", "# branch.upstream origin/main", "# branch.ab +4 -5", "# stash 2", ordinary(".M", "lib/outside.swift")],
            prefix: "app/"
        )
        #expect(report.branch.name == "main")
        #expect(report.branch.ahead == 4)
        #expect(report.branch.behind == 5)
        #expect(report.stashCount == 2)
        #expect(report.files.isEmpty)
    }
}

@Suite("GitStatus.parse: output captured from git")
struct GitStatusCapturedOutputTests {
    /// From git 2.x, mid-merge in a repository with a stash, one commit ahead
    /// of its upstream; NULs written here as line breaks.
    private static let captured = """
    # branch.oid 412be6ef647196d72bfcbfad718d0ce1e0cd274c
    # branch.head main
    # branch.upstream origin/main
    # branch.ab +1 -0
    # stash 1
    1 .M N... 100644 100644 100644 587be6b4c3f93f93c489c0111bba5596147a26cb 587be6b4c3f93f93c489c0111bba5596147a26cb app/ a  b.txt
    1 A. N... 000000 100644 100644 0000000000000000000000000000000000000000 8ba3a16384aacc37d01564b28401755ce8053f51 app/new.txt
    1 MM N... 100644 100644 100644 587be6b4c3f93f93c489c0111bba5596147a26cb b77b4eb1d946f923f61785536da9ca5af6909f06 app/src/both.txt
    1 D. N... 100644 000000 000000 587be6b4c3f93f93c489c0111bba5596147a26cb 0000000000000000000000000000000000000000 app/src/deleted.txt
    1 .M N... 100644 100644 100644 5626abf0f72e58d7a153368ba57db4c673c0e171 5626abf0f72e58d7a153368ba57db4c673c0e171 app/src/kept.txt
    2 R. N... 100644 100644 100644 71ac1b5791204c80666ab1a4f9886b79e982739c 71ac1b5791204c80666ab1a4f9886b79e982739c R100 app/src/renamed-to.txt
    app/src/renamed-from.txt
    1 M. N... 100644 100644 100644 587be6b4c3f93f93c489c0111bba5596147a26cb b77b4eb1d946f923f61785536da9ca5af6909f06 app/src/staged-mod.txt
    1 .M N... 100644 100644 100644 587be6b4c3f93f93c489c0111bba5596147a26cb 587be6b4c3f93f93c489c0111bba5596147a26cb lib/outside.txt
    u UU N... 100644 100644 100644 100644 df967b96a579e45a18b8251732d16804b2e56a55 b19a1e93bec1317dc6097229e12afaffbfa74dc2 950b81b7eee953d050aa05a641f8e056c85dd1bd app/conflict.txt
    ? app/untracked.txt
    """

    private static var output: Data {
        porcelain(captured.split(separator: "\n").map(String.init))
    }

    @Test func fromTheRepositorysRoot() {
        let report = GitStatus.parse(Self.output, prefix: "")
        #expect(report.branch.name == "main")
        #expect(report.branch.head == "412be6ef647196d72bfcbfad718d0ce1e0cd274c")
        #expect(report.branch.upstream == "origin/main")
        #expect(report.branch.ahead == 1)
        #expect(report.branch.behind == 0)
        #expect(report.stashCount == 1)
        #expect(report.files == [
            "app/ a  b.txt": .modified,
            "app/new.txt": .added,
            "app/src/both.txt": .modified,
            "app/src/deleted.txt": .deleted,
            "app/src/kept.txt": .modified,
            "app/src/renamed-to.txt": .renamed,
            "app/src/staged-mod.txt": .modified,
            "lib/outside.txt": .modified,
            "app/conflict.txt": .conflicted,
            "app/untracked.txt": .untracked,
        ])
        #expect(report.renamedFrom == ["app/src/renamed-to.txt": "app/src/renamed-from.txt"])
    }

    @Test func fromAFolderOfTheRepository() {
        let report = GitStatus.parse(Self.output, prefix: "app/")
        #expect(report.files == [
            " a  b.txt": .modified,
            "new.txt": .added,
            "src/both.txt": .modified,
            "src/deleted.txt": .deleted,
            "src/kept.txt": .modified,
            "src/renamed-to.txt": .renamed,
            "src/staged-mod.txt": .modified,
            "conflict.txt": .conflicted,
            "untracked.txt": .untracked,
        ])
        #expect(report.staged == [
            "new.txt": .added,
            "src/both.txt": .modified,
            "src/deleted.txt": .deleted,
            "src/renamed-to.txt": .renamed,
            "src/staged-mod.txt": .modified,
        ])
        #expect(report.unstaged == [
            " a  b.txt": .modified,
            "src/both.txt": .modified,
            "src/kept.txt": .modified,
            "conflict.txt": .conflicted,
            "untracked.txt": .untracked,
        ])
        #expect(report.renamedFrom == ["src/renamed-to.txt": "src/renamed-from.txt"])
    }
}

@Suite("GitBranch: what can be done with it")
struct GitBranchTests {
    @Test func pushesWhenAheadOfItsUpstream() {
        #expect(GitBranch(name: "main", upstream: "origin/main", ahead: 1, behind: 0).canPush)
        #expect(!GitBranch(name: "main", upstream: "origin/main", ahead: 0, behind: 3).canPush)
    }

    /// The upstream is gone: pushing puts it back.
    @Test func pushesWhenItsUpstreamIsGone() {
        #expect(GitBranch(name: "topic", upstream: "origin/topic").canPush)
    }

    @Test func publishesToARemoteWhenItHasNoUpstream() {
        #expect(GitBranch(name: "topic", remote: "origin").canPush)
        #expect(!GitBranch(name: "topic").canPush)
    }

    @Test func doesNotPushWithoutABranchOrACommit() {
        #expect(!GitBranch(name: nil, upstream: "origin/main", ahead: 1).canPush)
        #expect(!GitBranch(name: "main", hasCommits: false, remote: "origin").canPush)
    }

    @Test func fetchesFromAnUpstreamOrARemote() {
        #expect(GitBranch(name: "main", upstream: "origin/main").canFetch)
        #expect(GitBranch(name: "main", remote: "origin").canFetch)
        #expect(!GitBranch(name: "main").canFetch)
    }

    @Test func pullsOnlyOnABranchWithAnUpstream() {
        #expect(GitBranch(name: "main", upstream: "origin/main").canPull)
        #expect(!GitBranch(name: "main", remote: "origin").canPull)
        #expect(!GitBranch(name: nil, upstream: "origin/main").canPull)
    }
}
