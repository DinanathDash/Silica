import Foundation
import Testing

/// A conflict as text: all of it, and each side's lines.
private nonisolated struct Conflict: Equatable, CustomStringConvertible {
    var whole: String
    var current: String
    var incoming: String

    var description: String { "(whole: \(whole.debugDescription), current: \(current.debugDescription), incoming: \(incoming.debugDescription))" }
}

private func conflicts(in text: String) -> [Conflict] {
    let text = text as NSString
    return ConflictMarkers.regions(in: text).map {
        Conflict(whole: text.substring(with: $0.whole), current: text.substring(with: $0.current), incoming: text.substring(with: $0.incoming))
    }
}

/// The text with its first conflict settled one way.
private func resolving(_ text: String, taking choice: ConflictMarkers.Choice) -> String? {
    let string = text as NSString
    guard let region = ConflictMarkers.regions(in: string).first else { return nil }
    return string.replacingCharacters(in: region.whole, with: ConflictMarkers.resolution(of: region, in: string, taking: choice))
}

private let singleConflict = """
    first
    <<<<<<< HEAD
    ours 1
    ours 2
    =======
    theirs
    >>>>>>> feature
    last

    """

@Suite("ConflictMarkers.regions")
struct ConflictMarkersRegionTests {
    @Test func oneConflict() {
        #expect(conflicts(in: singleConflict) == [Conflict(
            whole: "<<<<<<< HEAD\nours 1\nours 2\n=======\ntheirs\n>>>>>>> feature\n",
            current: "ours 1\nours 2\n", incoming: "theirs\n"
        )])
    }

    @Test func rangesAreInTheTextsOwnUnits() {
        let regions = ConflictMarkers.regions(in: "a\n<<<<<<< HEAD\nb\n=======\nc\n>>>>>>> x\nd\n")
        #expect(regions == [ConflictMarkers.Region(
            whole: NSRange(location: 2, length: 35), current: NSRange(location: 15, length: 2), incoming: NSRange(location: 25, length: 2)
        )])
    }

    /// An emoji is two units of an `NSString` and one character of a `String`.
    @Test func textBeforeAConflictMayBeAnything() {
        let found = conflicts(in: "// 🙂 naïve 日本語\n<<<<<<< HEAD\nours 🙂\n=======\ntheirs 日本\n>>>>>>> feature\n")
        #expect(found == [Conflict(
            whole: "<<<<<<< HEAD\nours 🙂\n=======\ntheirs 日本\n>>>>>>> feature\n", current: "ours 🙂\n", incoming: "theirs 日本\n"
        )])
    }

    @Test func severalConflicts() {
        let text = """
            <<<<<<< HEAD
            a1
            =======
            a2
            >>>>>>> feature
            between
            <<<<<<< HEAD
            b1
            =======
            b2
            b3
            >>>>>>> feature
            <<<<<<< HEAD
            c1
            =======
            c2
            >>>>>>> feature

            """
        #expect(conflicts(in: text) == [
            Conflict(whole: "<<<<<<< HEAD\na1\n=======\na2\n>>>>>>> feature\n", current: "a1\n", incoming: "a2\n"),
            Conflict(whole: "<<<<<<< HEAD\nb1\n=======\nb2\nb3\n>>>>>>> feature\n", current: "b1\n", incoming: "b2\nb3\n"),
            Conflict(whole: "<<<<<<< HEAD\nc1\n=======\nc2\n>>>>>>> feature\n", current: "c1\n", incoming: "c2\n"),
        ])
    }

    /// With `merge.conflictStyle = diff3` (or zdiff3) git also writes the text
    /// both sides started from, which is neither side.
    @Test func theCommonAncestorIsNeitherSide() {
        let text = """
            <<<<<<< HEAD
            ours
            ||||||| 1a2b3c4
            base 1
            base 2
            =======
            theirs
            >>>>>>> feature

            """
        #expect(conflicts(in: text) == [Conflict(whole: text, current: "ours\n", incoming: "theirs\n")])
    }

    /// The current side ends at the first "|||||||": a second one, in the
    /// ancestor's text, moves nothing.
    @Test func aSecondAncestorMarkerChangesNothing() {
        let text = "<<<<<<< HEAD\nours\n||||||| base\nbase\n||||||| again\nmore base\n=======\ntheirs\n>>>>>>> feature\n"
        #expect(conflicts(in: text) == [Conflict(whole: text, current: "ours\n", incoming: "theirs\n")])
    }

    @Test func aSideMayBeEmpty() {
        #expect(conflicts(in: "<<<<<<< HEAD\n=======\ntheirs\n>>>>>>> feature\n") == [
            Conflict(whole: "<<<<<<< HEAD\n=======\ntheirs\n>>>>>>> feature\n", current: "", incoming: "theirs\n"),
        ])
        #expect(conflicts(in: "<<<<<<< HEAD\nours\n=======\n>>>>>>> feature\n") == [
            Conflict(whole: "<<<<<<< HEAD\nours\n=======\n>>>>>>> feature\n", current: "ours\n", incoming: ""),
        ])
        #expect(conflicts(in: "<<<<<<< HEAD\n=======\n>>>>>>> feature\n") == [
            Conflict(whole: "<<<<<<< HEAD\n=======\n>>>>>>> feature\n", current: "", incoming: ""),
        ])
    }

    @Test func markersNeedNoName() {
        #expect(conflicts(in: "<<<<<<<\nours\n=======\ntheirs\n>>>>>>>\n") == [
            Conflict(whole: "<<<<<<<\nours\n=======\ntheirs\n>>>>>>>\n", current: "ours\n", incoming: "theirs\n"),
        ])
    }

    @Test func theLastMarkerMayEndTheText() {
        #expect(conflicts(in: "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature") == [
            Conflict(whole: "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature", current: "ours\n", incoming: "theirs\n"),
        ])
        #expect(conflicts(in: "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>>") == [
            Conflict(whole: "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>>", current: "ours\n", incoming: "theirs\n"),
        ])
    }

    @Test func linesMayEndInCRLF() {
        let text = "first\r\n<<<<<<< HEAD\r\nours\r\n=======\r\ntheirs\r\n>>>>>>> feature\r\nlast\r\n"
        #expect(conflicts(in: text) == [Conflict(
            whole: "<<<<<<< HEAD\r\nours\r\n=======\r\ntheirs\r\n>>>>>>> feature\r\n", current: "ours\r\n", incoming: "theirs\r\n"
        )])
    }

    /// git writes a marker as exactly seven characters. A longer run is the
    /// file's own: the rule under a heading, a banner in a comment.
    @Test func aLongerRunIsNotAMarker() {
        let text = """
            Heading
            ==========
            <<<<<<< HEAD
            Ours
            ==========
            // ======== banner ========
            ========
            more of ours
            =======
            Theirs
            ==========
            >>>>>>> feature
            ==========

            """
        #expect(conflicts(in: text) == [Conflict(
            whole: """
                <<<<<<< HEAD
                Ours
                ==========
                // ======== banner ========
                ========
                more of ours
                =======
                Theirs
                ==========
                >>>>>>> feature

                """,
            current: "Ours\n==========\n// ======== banner ========\n========\nmore of ours\n",
            incoming: "Theirs\n==========\n"
        )])
    }

    @Test func longerRunsOfTheOtherMarkersAreNotMarkersEither() {
        // Eight of each, then the real ones.
        let text = "<<<<<<<< not a start\nplain\n<<<<<<< HEAD\nours\n|||||||| not a base\n=======\ntheirs\n>>>>>>>> not an end\n>>>>>>> feature\n"
        #expect(conflicts(in: text) == [Conflict(
            whole: "<<<<<<< HEAD\nours\n|||||||| not a base\n=======\ntheirs\n>>>>>>>> not an end\n>>>>>>> feature\n",
            current: "ours\n|||||||| not a base\n", incoming: "theirs\n>>>>>>>> not an end\n"
        )])
    }

    @Test func aMarkerStartsItsLine() {
        let text = "// ======= banner\n  <<<<<<< HEAD\nx = a <<<<<<< b\n\t=======\n >>>>>>> feature\n"
        #expect(conflicts(in: text).isEmpty)
    }

    /// After the seven characters comes the end of the line, or a space and a name.
    @Test func aMarkerIsFollowedByASpaceOrTheEndOfItsLine() {
        #expect(conflicts(in: "<<<<<<<HEAD\nours\n=======\ntheirs\n>>>>>>> feature\n").isEmpty)
        #expect(conflicts(in: "<<<<<<< HEAD\nours\n=======x\ntheirs\n>>>>>>> feature\n").isEmpty)
        #expect(conflicts(in: "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>>feature\n").isEmpty)
    }

    @Test func markersOutsideAConflictAreText() {
        let text = "=======\n>>>>>>> stray\n||||||| stray\ntext\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature\n=======\n>>>>>>> stray\n"
        #expect(conflicts(in: text) == [Conflict(
            whole: "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature\n", current: "ours\n", incoming: "theirs\n"
        )])
    }

    @Test func aConflictWithoutItsEndIsNotOne() {
        #expect(conflicts(in: "<<<<<<< HEAD\nours\n=======\ntheirs\n").isEmpty)
        #expect(conflicts(in: "<<<<<<< HEAD\nours\n>>>>>>> feature\n").isEmpty)
        #expect(conflicts(in: "<<<<<<< HEAD\nours\n").isEmpty)
        #expect(conflicts(in: "").isEmpty)
        #expect(conflicts(in: "no conflicts here\n").isEmpty)
    }

    /// A start with no end before the next start is left as text; the next
    /// conflict is read from its own start.
    @Test func aNewStartBeginsAgain() {
        let text = "<<<<<<< HEAD\nabandoned\n=======\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature\n"
        #expect(conflicts(in: text) == [Conflict(
            whole: "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature\n", current: "ours\n", incoming: "theirs\n"
        )])
    }

    /// The incoming side runs to the end marker: a separator in it is its text.
    @Test func aSecondSeparatorBelongsToTheIncomingSide() {
        let text = "<<<<<<< HEAD\nours\n=======\ntheirs\n=======\nmore\n>>>>>>> feature\n"
        #expect(conflicts(in: text) == [Conflict(whole: text, current: "ours\n", incoming: "theirs\n=======\nmore\n")])
    }
}

@Suite("ConflictMarkers.resolution")
struct ConflictMarkersResolutionTests {
    @Test func takingTheCurrentSide() {
        #expect(resolving(singleConflict, taking: .current) == "first\nours 1\nours 2\nlast\n")
    }

    @Test func takingTheIncomingSide() {
        #expect(resolving(singleConflict, taking: .incoming) == "first\ntheirs\nlast\n")
    }

    @Test func takingBothPutsTheCurrentSideFirst() {
        #expect(resolving(singleConflict, taking: .both) == "first\nours 1\nours 2\ntheirs\nlast\n")
    }

    @Test func theCommonAncestorIsLeftOutOfEveryChoice() {
        let text = "<<<<<<< HEAD\nours\n||||||| base\nbase\n=======\ntheirs\n>>>>>>> feature\nafter\n"
        #expect(resolving(text, taking: .current) == "ours\nafter\n")
        #expect(resolving(text, taking: .incoming) == "theirs\nafter\n")
        #expect(resolving(text, taking: .both) == "ours\ntheirs\nafter\n")
    }

    @Test func anEmptySideResolvesToNothing() {
        let text = "before\n<<<<<<< HEAD\n=======\ntheirs\n>>>>>>> feature\nafter\n"
        #expect(resolving(text, taking: .current) == "before\nafter\n")
        #expect(resolving(text, taking: .incoming) == "before\ntheirs\nafter\n")
        #expect(resolving(text, taking: .both) == "before\ntheirs\nafter\n")
    }

    @Test func lineEndingsAreKept() {
        let text = "first\r\n<<<<<<< HEAD\r\nours\r\n=======\r\ntheirs\r\n>>>>>>> feature\r\nlast\r\n"
        #expect(resolving(text, taking: .current).map { Array($0.utf8) } == Array("first\r\nours\r\nlast\r\n".utf8))
        #expect(resolving(text, taking: .incoming).map { Array($0.utf8) } == Array("first\r\ntheirs\r\nlast\r\n".utf8))
        #expect(resolving(text, taking: .both).map { Array($0.utf8) } == Array("first\r\nours\r\ntheirs\r\nlast\r\n".utf8))
    }

    /// Settling one conflict leaves the others to be found again in what's left.
    @Test func settlingConflictsOneAfterAnother() throws {
        var text = "<<<<<<< HEAD\na1\n=======\na2\n>>>>>>> x\nbetween\n<<<<<<< HEAD\nb1\n=======\nb2\n>>>>>>> x\nend\n"
        text = try #require(resolving(text, taking: .incoming))
        #expect(text == "a2\nbetween\n<<<<<<< HEAD\nb1\n=======\nb2\n>>>>>>> x\nend\n")
        text = try #require(resolving(text, taking: .both))
        #expect(text == "a2\nbetween\nb1\nb2\nend\n")
        #expect(resolving(text, taking: .current) == nil)
    }

    /// Any conflict can be the one settled, not only the first.
    @Test func eachRegionResolvesFromItsOwnRanges() {
        let text = "<<<<<<< HEAD\na1\n=======\na2\n>>>>>>> x\nbetween 🙂\n<<<<<<< HEAD\nb1\n=======\nb2\n>>>>>>> x\n" as NSString
        let regions = ConflictMarkers.regions(in: text)
        #expect(regions.count == 2)
        guard regions.count == 2 else { return }
        #expect(ConflictMarkers.resolution(of: regions[0], in: text, taking: .current) == "a1\n")
        #expect(ConflictMarkers.resolution(of: regions[1], in: text, taking: .current) == "b1\n")
        #expect(ConflictMarkers.resolution(of: regions[1], in: text, taking: .incoming) == "b2\n")
        #expect(ConflictMarkers.resolution(of: regions[1], in: text, taking: .both) == "b1\nb2\n")
    }
}
