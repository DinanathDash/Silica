import AppKit
import Testing

private let plain = NSColor.labelColor
private let red = NSColor.systemRed
private let blue = NSColor.systemBlue

/// Text all in the plain color, then colored as `tokens` say.
private func text(_ string: String, colored tokens: [SyntaxColoring.Run] = []) -> NSMutableAttributedString {
    let text = NSMutableAttributedString(string: string, attributes: [.foregroundColor: plain])
    for token in tokens { text.addAttribute(.foregroundColor, value: token.color, range: token.range) }
    return text
}

private func run(_ location: Int, _ length: Int, _ color: NSColor) -> SyntaxColoring.Run {
    SyntaxColoring.Run(range: NSRange(location: location, length: length), color: color)
}

/// The changes as text, so a failure reads well.
private func changes(in text: NSAttributedString, tokens: [SyntaxColoring.Run]) -> [String] {
    SyntaxColoring.changes(in: text, tokens: tokens, plain: plain).map {
        let name = $0.color === plain ? "plain" : $0.color === red ? "red" : $0.color === blue ? "blue" : "other"
        return "\($0.range.location)+\($0.range.length) \(name)"
    }
}

@Suite("SyntaxColoring.changes") struct SyntaxColoringTests {
    @Test func textAlreadyColoredNeedsNothing() {
        let tokens = [run(0, 3, red), run(8, 2, blue)]
        #expect(changes(in: text("let x = 42 // n", colored: tokens), tokens: tokens) == [])
    }

    @Test func plainTextTakesItsTokens() {
        #expect(changes(in: text("let x = 42"), tokens: [run(0, 3, red), run(8, 2, blue)]) == ["0+3 red", "8+2 blue"])
    }

    @Test func onlyTheTokenThatChangedIsSet() {
        let before = [run(0, 3, red), run(8, 2, blue)]
        let after = [run(0, 3, red), run(8, 2, red)]
        #expect(changes(in: text("let x = 42", colored: before), tokens: after) == ["8+2 red"])
    }

    @Test func textThatLostItsTokenGoesPlain() {
        #expect(changes(in: text("let x = 42", colored: [run(0, 3, red)]), tokens: []) == ["0+3 plain"])
    }

    @Test func aTokenThatGrewSetsOnlyTheNewPart() {
        // "42" was a number; "421" is now.
        #expect(changes(in: text("x = 421", colored: [run(4, 2, blue)]), tokens: [run(4, 3, blue)]) == ["6+1 blue"])
    }

    @Test func laterTokensWinWhereTheyOverlap() {
        #expect(changes(in: text("abcdef"), tokens: [run(0, 6, red), run(2, 2, blue)]) == ["0+2 red", "2+2 blue", "4+2 red"])
    }

    @Test func aChangeAcrossSeveralColorsIsOneRange() {
        // A comment opened before text that had three colors.
        let before = [run(0, 3, red), run(8, 2, blue)]
        #expect(changes(in: text("let x = 42", colored: before), tokens: [run(0, 10, blue)]) == ["0+8 blue"])
    }

    @Test func tokensPastTheEndAreLeftOut() {
        #expect(changes(in: text("abc"), tokens: [run(1, 5, red), run(0, 1, blue)]) == ["0+1 blue"])
    }

    @Test func textWithNoColorIsSet() {
        let bare = NSMutableAttributedString(string: "abc")
        #expect(changes(in: bare, tokens: [run(1, 1, red)]) == ["0+1 plain", "1+1 red", "2+1 plain"])
    }

    @Test func emptyTextNeedsNothing() {
        #expect(changes(in: text(""), tokens: []) == [])
    }
}
