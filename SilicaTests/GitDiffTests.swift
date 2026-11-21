import Foundation
import Testing

// The diffs here are what `git diff --no-index -U1000000000` wrote for the
// texts they sit beside (with fewer lines of context where a test says so).

/// What git writes above the first hunk.
private let fileHeader = "diff --git a/old b/new\nindex 9405325..ff47ac7 100644\n--- a/old\n+++ b/new\n"

private func parse(_ hunks: String) -> [GitDiff.Line] {
    GitDiff.parse(Data((fileHeader + hunks).utf8))
}

/// Each line as its kind and its numbers in the old and the new text:
/// " 3/4" is kept, "-3/" removed, "+/4" added.
private func summary(_ lines: [GitDiff.Line]) -> [String] {
    lines.map { line in
        let kind = switch line.kind {
        case .context: " "
        case .removed: "-"
        case .added: "+"
        }
        return kind + (line.old.map(String.init) ?? "") + "/" + (line.new.map(String.init) ?? "")
    }
}

private func diff(old: String, new: String, _ hunks: String) -> GitDiff {
    GitDiff(lines: parse(hunks), oldText: old, newText: new)
}

@Suite("GitDiff.parse")
struct GitDiffParseTests {
    @Test func numbersKeptRemovedAndAddedLines() {
        let lines = parse("@@ -1,5 +1,6 @@\n a\n-b\n+B\n c\n d\n-e\n+E\n+f\n")
        #expect(summary(lines) == [" 1/1", "-2/", "+/2", " 3/3", " 4/4", "-5/", "+/5", "+/6"])
    }

    @Test func nothingAboveTheFirstHunkIsALine() {
        #expect(GitDiff.parse(Data(fileHeader.utf8)).isEmpty)
        #expect(GitDiff.parse(Data()).isEmpty)
    }

    @Test func eachHunkStartsFromItsOwnLineNumbers() {
        let lines = parse("@@ -1,3 +1,3 @@\n 1\n-2\n+TWO\n 3\n@@ -8,3 +8,4 @@\n 8\n-9\n+nine\n+nine and a half\n 10\n")
        #expect(summary(lines) == [" 1/1", "-2/", "+/2", " 3/3", " 8/8", "-9/", "+/9", "+/10", " 10/11"])
    }

    /// git names the function a hunk is in after the second "@@".
    @Test func aHunkHeaderMayNameASection() {
        let lines = parse("@@ -7,3 +7,3 @@ func a() {\n func b() {\n-  one\n+  two\n }\n")
        #expect(summary(lines) == [" 7/7", "-8/", "+/8", " 9/9"])
    }

    /// "@@ -1 +1 @@": a count of one is left out.
    @Test func aHunkOfOneLineHasNoCounts() {
        #expect(summary(parse("@@ -1 +1 @@\n-one\n+two\n")) == ["-1/", "+/1"])
    }

    @Test func aTextWithNothingBeforeIsAllAdded() {
        #expect(summary(parse("@@ -0,0 +1,2 @@\n+a\n+b\n")) == ["+/1", "+/2"])
    }

    @Test func aTextWithNothingAfterIsAllRemoved() {
        #expect(summary(parse("@@ -1,2 +0,0 @@\n-a\n-b\n")) == ["-1/", "-2/"])
    }

    @Test func theNoteAboutAMissingLastLineFeedIsNotALine() {
        let lines = parse(
            "@@ -1,4 +1,5 @@\n-x\n+X\n b\n c\n-last\n\\ No newline at end of file\n+last\n+more\n\\ No newline at end of file\n"
        )
        #expect(summary(lines) == ["-1/", "+/1", " 2/2", " 3/3", "-4/", "+/4", "+/5"])
    }

    @Test func anEmptyKeptLineIsALine() {
        // As git writes it, a space and nothing else; and with
        // `diff.suppressBlankEmpty`, nothing at all.
        #expect(summary(parse("@@ -1,3 +1,3 @@\n a\n \n-c\n+C\n")) == [" 1/1", " 2/2", "-3/", "+/3"])
        #expect(summary(parse("@@ -1,3 +1,3 @@\n a\n\n-c\n+C\n")) == [" 1/1", " 2/2", "-3/", "+/3"])
    }

    @Test func linesThatEndInCarriageReturnsAreCountedOnce() {
        let lines = parse("@@ -1,3 +1,4 @@\n a\r\n-b\r\n+B\r\n c\r\n+d\r\n")
        #expect(summary(lines) == [" 1/1", "-2/", "+/2", " 3/3", "+/4"])
    }

    /// A removed "-- note" is written "--- note": inside a hunk that is a line,
    /// not the header naming the old file. Likewise "+++" and "@@".
    @Test func linesThatLookLikeHeadersAreLinesInsideAHunk() {
        let lines = parse("@@ -1,4 +1,4 @@\n select 1;\n--- old note\n-@@ -1 +1 @@\n+++ new note\n+@@ -2 +2 @@\n select 2;\n")
        #expect(summary(lines) == [" 1/1", "-2/", "-3/", "+/2", "+/3", " 4/4"])
    }

    @Test func outputWithoutALastLineFeedIsReadToItsEnd() {
        #expect(summary(parse("@@ -1,2 +1,2 @@\n a\n-b\n+B")) == [" 1/1", "-2/", "+/2"])
    }
}

@Suite("GitDiff.changes")
struct GitDiffChangesTests {
    @Test func removedLinesAndTheOnesPutInTheirPlaceAreOneChange() {
        let diff = diff(old: "a\nb\nc\nd\ne\n", new: "a\nB\nc\nd\nE\nf\n", "@@ -1,5 +1,6 @@\n a\n-b\n+B\n c\n d\n-e\n+E\n+f\n")
        #expect(diff.changes == [1..<3, 5..<8])
        #expect(diff.hasChanges)
    }

    @Test func linesOnlyRemovedOrOnlyAddedAreChangesToo() {
        let diff = diff(
            old: "1\n2\n3\n4\n5\n6\n7\n", new: "1\n3\nfour\n5\n6\nsix and a half\n7\n",
            "@@ -1,7 +1,7 @@\n 1\n-2\n 3\n-4\n+four\n 5\n 6\n+six and a half\n 7\n"
        )
        #expect(diff.changes == [1..<2, 3..<5, 7..<8])
    }

    @Test func oneKeptLineIsEnoughToSeparateTwoChanges() {
        let diff = diff(old: "a\nb\nc\n", new: "A\nb\nC\n", "@@ -1,3 +1,3 @@\n-a\n+A\n b\n-c\n+C\n")
        #expect(diff.changes == [0..<2, 3..<5])
    }

    @Test func aChangeMayBeTheWholeDiff() {
        #expect(diff(old: "", new: "a\nb\n", "@@ -0,0 +1,2 @@\n+a\n+b\n").changes == [0..<2])
        #expect(diff(old: "a\nb\n", new: "", "@@ -1,2 +0,0 @@\n-a\n-b\n").changes == [0..<2])
        #expect(diff(old: "one\n", new: "two\n", "@@ -1 +1 @@\n-one\n+two\n").changes == [0..<2])
    }

    @Test func textsThatAreTheSameHaveNoChanges() {
        let same = GitDiff(
            lines: (1...3).map { GitDiff.Line(kind: .context, old: $0, new: $0) }, oldText: "a\nb\nc\n", newText: "a\nb\nc\n"
        )
        #expect(same.changes.isEmpty)
        #expect(!same.hasChanges)
        #expect(GitDiff(lines: [], oldText: "", newText: "").changes.isEmpty)
    }
}

/// Two texts, git's diff of them, and for each change in turn the text that
/// staging it alone, or unstaging it alone, should leave in the index.
nonisolated struct CompositionCase: Sendable, CustomTestStringConvertible {
    var name: String
    var old: String
    var new: String
    var hunks: String
    /// The old text with only that change made.
    var applied: [String]
    /// The new text with only that change taken back out.
    var reverted: [String]

    var testDescription: String { name }

    static let all: [CompositionCase] = [
        CompositionCase(
            name: "two replacements",
            old: "a\nb\nc\nd\ne\n", new: "a\nB\nc\nd\nE\nf\n",
            hunks: "@@ -1,5 +1,6 @@\n a\n-b\n+B\n c\n d\n-e\n+E\n+f\n",
            applied: ["a\nB\nc\nd\ne\n", "a\nb\nc\nd\nE\nf\n"],
            reverted: ["a\nb\nc\nd\nE\nf\n", "a\nB\nc\nd\ne\n"]
        ),
        CompositionCase(
            name: "a removal, a replacement and an addition",
            old: "1\n2\n3\n4\n5\n6\n7\n", new: "1\n3\nfour\n5\n6\nsix and a half\n7\n",
            hunks: "@@ -1,7 +1,7 @@\n 1\n-2\n 3\n-4\n+four\n 5\n 6\n+six and a half\n 7\n",
            applied: ["1\n3\n4\n5\n6\n7\n", "1\n2\n3\nfour\n5\n6\n7\n", "1\n2\n3\n4\n5\n6\nsix and a half\n7\n"],
            reverted: ["1\n2\n3\nfour\n5\n6\nsix and a half\n7\n", "1\n3\n4\n5\n6\nsix and a half\n7\n", "1\n3\nfour\n5\n6\n7\n"]
        ),
        CompositionCase(
            name: "changes at the first and the last line",
            old: "a\nb\nc\n", new: "A\nb\nC\n",
            hunks: "@@ -1,3 +1,3 @@\n-a\n+A\n b\n-c\n+C\n",
            applied: ["A\nb\nc\n", "a\nb\nC\n"],
            reverted: ["a\nb\nC\n", "A\nb\nc\n"]
        ),
        // Lines are taken by their numbers: which "a" is which doesn't matter.
        CompositionCase(
            name: "lines that repeat",
            old: "a\na\na\n", new: "a\nb\na\na\nc\n",
            hunks: "@@ -1,3 +1,5 @@\n a\n+b\n a\n a\n+c\n",
            applied: ["a\nb\na\na\n", "a\na\na\nc\n"],
            reverted: ["a\na\na\nc\n", "a\nb\na\na\n"]
        ),
        CompositionCase(
            name: "CRLF line endings",
            old: "a\r\nb\r\nc\r\n", new: "a\r\nB\r\nc\r\nd\r\n",
            hunks: "@@ -1,3 +1,4 @@\n a\r\n-b\r\n+B\r\n c\r\n+d\r\n",
            applied: ["a\r\nB\r\nc\r\n", "a\r\nb\r\nc\r\nd\r\n"],
            reverted: ["a\r\nb\r\nc\r\nd\r\n", "a\r\nB\r\nc\r\n"]
        ),
        CompositionCase(
            name: "no line feed after the last line, before or after",
            old: "x\nb\nc\nlast", new: "X\nb\nc\nlast\nmore",
            hunks: "@@ -1,4 +1,5 @@\n-x\n+X\n b\n c\n-last\n\\ No newline at end of file\n+last\n+more\n\\ No newline at end of file\n",
            applied: ["X\nb\nc\nlast", "x\nb\nc\nlast\nmore"],
            reverted: ["x\nb\nc\nlast\nmore", "X\nb\nc\nlast"]
        ),
        CompositionCase(
            name: "a last line that gains its line feed",
            old: "a\nb\nc", new: "A\nb\nc\n",
            hunks: "@@ -1,3 +1,3 @@\n-a\n+A\n b\n-c\n\\ No newline at end of file\n+c\n",
            applied: ["A\nb\nc", "a\nb\nc\n"],
            reverted: ["a\nb\nc\n", "A\nb\nc"]
        ),
        CompositionCase(
            name: "a last line that loses its line feed",
            old: "a\nb\nc\n", new: "A\nb\nc",
            hunks: "@@ -1,3 +1,3 @@\n-a\n+A\n b\n-c\n+c\n\\ No newline at end of file\n",
            applied: ["A\nb\nc\n", "a\nb\nc"],
            reverted: ["a\nb\nc", "A\nb\nc\n"]
        ),
        CompositionCase(
            name: "CRLF line endings and no line ending after the last line",
            old: "a\r\nb\r\nc", new: "A\r\nb\r\nc\r\nd",
            hunks: "@@ -1,3 +1,4 @@\n-a\r\n+A\r\n b\r\n-c\n\\ No newline at end of file\n+c\r\n+d\n\\ No newline at end of file\n",
            applied: ["A\r\nb\r\nc", "a\r\nb\r\nc\r\nd"],
            reverted: ["a\r\nb\r\nc\r\nd", "A\r\nb\r\nc"]
        ),
        // To git a line ends at a line feed and nowhere else: not at a lone
        // carriage return, nor at Unicode's line and paragraph separators.
        CompositionCase(
            name: "other characters that break lines elsewhere",
            old: "é\u{2028}x\ry\n🙂 b\n\u{2029}c\n", new: "é\u{2028}x\ry\n🙂 B\n\u{2029}c\nd\u{85}\n",
            hunks: "@@ -1,3 +1,4 @@\n é\u{2028}x\ry\n-🙂 b\n+🙂 B\n \u{2029}c\n+d\u{85}\n",
            applied: ["é\u{2028}x\ry\n🙂 B\n\u{2029}c\n", "é\u{2028}x\ry\n🙂 b\n\u{2029}c\nd\u{85}\n"],
            reverted: ["é\u{2028}x\ry\n🙂 b\n\u{2029}c\nd\u{85}\n", "é\u{2028}x\ry\n🙂 B\n\u{2029}c\n"]
        ),
        CompositionCase(
            name: "empty lines",
            old: "a\n\n\nb\n", new: "a\n\nnew\n\nb\n\n",
            hunks: "@@ -1,4 +1,6 @@\n a\n \n+new\n \n b\n+\n",
            applied: ["a\n\nnew\n\nb\n", "a\n\n\nb\n\n"],
            reverted: ["a\n\n\nb\n\n", "a\n\nnew\n\nb\n"]
        ),
        CompositionCase(
            name: "a text with nothing before",
            old: "", new: "a\nb\n",
            hunks: "@@ -0,0 +1,2 @@\n+a\n+b\n",
            applied: ["a\nb\n"],
            reverted: [""]
        ),
        CompositionCase(
            name: "a text with nothing after",
            old: "a\nb\n", new: "",
            hunks: "@@ -1,2 +0,0 @@\n-a\n-b\n",
            applied: [""],
            reverted: ["a\nb\n"]
        ),
        CompositionCase(
            name: "only the last line feed taken away",
            old: "a\nb\n", new: "a\nb",
            hunks: "@@ -1,2 +1,2 @@\n a\n-b\n+b\n\\ No newline at end of file\n",
            applied: ["a\nb"],
            reverted: ["a\nb\n"]
        ),
    ]
}

@Suite("GitDiff.text(applying:change:)")
struct GitDiffCompositionTests {
    /// What staging one change puts in the index: the committed text with that
    /// change and no other.
    @Test(arguments: CompositionCase.all)
    func applyingOneChangeToTheOldText(_ example: CompositionCase) {
        let diff = diff(old: example.old, new: example.new, example.hunks)
        #expect(diff.changes.count == example.applied.count)
        for (number, expected) in example.applied.enumerated() {
            #expect(diff.text(applying: true, change: number) == expected, "change \(number)")
        }
    }

    /// What unstaging one change leaves in the index: the staged text without
    /// that change, and with every other.
    @Test(arguments: CompositionCase.all)
    func takingOneChangeOutOfTheNewText(_ example: CompositionCase) {
        let diff = diff(old: example.old, new: example.new, example.hunks)
        #expect(diff.changes.count == example.reverted.count)
        for (number, expected) in example.reverted.enumerated() {
            #expect(diff.text(applying: false, change: number) == expected, "change \(number)")
        }
    }

    /// The only change there is, applied, gives the new text; taken back out,
    /// the old.
    @Test(arguments: CompositionCase.all.filter { $0.applied.count == 1 })
    func theOnlyChangeIsTheWholeDifference(_ example: CompositionCase) {
        let diff = diff(old: example.old, new: example.new, example.hunks)
        #expect(diff.text(applying: true, change: 0) == example.new)
        #expect(diff.text(applying: false, change: 0) == example.old)
    }

    /// Of two changes, making the one is taking back the other.
    @Test(arguments: CompositionCase.all.filter { $0.applied.count == 2 })
    func ofTwoChangesApplyingOneIsRevertingTheOther(_ example: CompositionCase) {
        let diff = diff(old: example.old, new: example.new, example.hunks)
        #expect(diff.text(applying: true, change: 0) == diff.text(applying: false, change: 1))
        #expect(diff.text(applying: true, change: 1) == diff.text(applying: false, change: 0))
    }

    /// The bytes, not only the characters: "\r\n" is one character and must
    /// stay two bytes.
    @Test func lineEndingsAreKeptByteForByte() {
        let diff = diff(
            old: "a\r\nb\r\nc\r\n", new: "a\r\nB\r\nc\r\nd\r\n",
            "@@ -1,3 +1,4 @@\n a\r\n-b\r\n+B\r\n c\r\n+d\r\n"
        )
        #expect(Array(diff.text(applying: true, change: 0).utf8) == Array("a\r\nB\r\nc\r\n".utf8))
        #expect(Array(diff.text(applying: true, change: 1).utf8) == Array("a\r\nb\r\nc\r\nd\r\n".utf8))
        #expect(Array(diff.text(applying: false, change: 1).utf8) == Array("a\r\nB\r\nc\r\n".utf8))
    }

    /// A file that mixes endings keeps each line's own.
    @Test func mixedLineEndingsAreKeptLineByLine() {
        let diff = diff(
            old: "a\r\nb\nc\r\n", new: "a\r\nB\r\nc\r\nd\n",
            "@@ -1,3 +1,4 @@\n a\r\n-b\n+B\r\n c\r\n+d\n"
        )
        #expect(Array(diff.text(applying: true, change: 0).utf8) == Array("a\r\nB\r\nc\r\n".utf8))
        #expect(Array(diff.text(applying: true, change: 1).utf8) == Array("a\r\nb\nc\r\nd\n".utf8))
        #expect(Array(diff.text(applying: false, change: 0).utf8) == Array("a\r\nb\nc\r\nd\n".utf8))
        #expect(Array(diff.text(applying: false, change: 1).utf8) == Array("a\r\nB\r\nc\r\n".utf8))
    }

    @Test func aChangeThatIsNotThereChangesNothing() {
        let diff = diff(old: "a\nb\nc\n", new: "A\nb\nC\n", "@@ -1,3 +1,3 @@\n-a\n+A\n b\n-c\n+C\n")
        for number in [-1, 2, 100] {
            #expect(diff.text(applying: true, change: number) == "a\nb\nc\n")
            #expect(diff.text(applying: false, change: number) == "A\nb\nC\n")
        }
    }

    @Test func textsThatAreTheSameStayAsTheyAre() {
        let same = GitDiff(
            lines: (1...3).map { GitDiff.Line(kind: .context, old: $0, new: $0) }, oldText: "a\r\nb\nc", newText: "a\r\nb\nc"
        )
        #expect(same.text(applying: true, change: 0) == "a\r\nb\nc")
        #expect(same.text(applying: false, change: 0) == "a\r\nb\nc")
    }
}
