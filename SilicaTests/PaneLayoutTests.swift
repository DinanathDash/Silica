import CoreGraphics
import Foundation
import Testing

private let spacing = PaneLayout.Spacing(horizontal: 6, vertical: 0)
private let minimum = CGSize(width: 200, height: 150)

private extension PaneLayout {
    /// `split`, for a pane that's known to be there.
    mutating func dividing(_ pane: PaneID, _ axis: Axis) throws -> PaneID {
        let new = split(pane, along: axis)
        return try #require(new)
    }
}

private func file(_ name: String) -> URL {
    URL(filePath: "/project/\(name)")
}

@Suite("Pane layout")
struct PaneLayoutTests {
    @Test func startsAsOnePane() {
        let layout = PaneLayout()
        #expect(layout.panes.count == 1)
        #expect(!layout.isSplit)
        let arrangement = layout.arrangement(in: CGSize(width: 900, height: 600), spacing: spacing, minimum: minimum)
        #expect(arrangement.panes[layout.panes[0]] == CGRect(x: 0, y: 0, width: 900, height: 600))
        #expect(arrangement.dividers.isEmpty)
    }

    @Test func splitPutsTheNewPaneAfter() throws {
        var layout = PaneLayout()
        let first = layout.panes[0]
        let right = try layout.dividing(first, .horizontal)
        #expect(layout.panes == [first, right])
        let below = try layout.dividing(first, .vertical)
        #expect(layout.panes == [first, below, right])
        #expect(layout.isConsistent)
        #expect(layout.split(99, along: .horizontal) == nil)
    }

    @Test func sideBySidePanesShareTheWidth() throws {
        var layout = PaneLayout()
        let first = layout.panes[0]
        let second = try layout.dividing(first, .horizontal)
        let arrangement = layout.arrangement(in: CGSize(width: 906, height: 600), spacing: spacing, minimum: minimum)
        #expect(arrangement.panes[first] == CGRect(x: 0, y: 0, width: 450, height: 600))
        #expect(arrangement.panes[second] == CGRect(x: 456, y: 0, width: 450, height: 600))
        #expect(arrangement.dividers.map(\.frame) == [CGRect(x: 450, y: 0, width: 6, height: 600)])
    }

    @Test func stackedPanesTouch() throws {
        var layout = PaneLayout()
        let first = layout.panes[0]
        let second = try layout.dividing(first, .vertical)
        let arrangement = layout.arrangement(in: CGSize(width: 900, height: 600), spacing: spacing, minimum: minimum)
        #expect(arrangement.panes[first] == CGRect(x: 0, y: 0, width: 900, height: 300))
        #expect(arrangement.panes[second] == CGRect(x: 0, y: 300, width: 900, height: 300))
    }

    @Test func aRowOfSplitsIsEvenedOut() throws {
        var layout = PaneLayout()
        let first = layout.panes[0]
        let second = try layout.dividing(first, .horizontal)
        let third = try layout.dividing(second, .horizontal)
        let arrangement = layout.arrangement(in: CGSize(width: 912, height: 600), spacing: spacing, minimum: minimum)
        #expect([first, second, third].map { arrangement.panes[$0]?.width } == [300, 300, 300])
        // Closing one of the three leaves the other two with half each.
        layout.remove(second)
        let rest = layout.arrangement(in: CGSize(width: 906, height: 600), spacing: spacing, minimum: minimum)
        #expect([first, third].map { rest.panes[$0]?.width } == [450, 450])
    }

    @Test func aSplitTheOtherWayKeepsItsShare() throws {
        var layout = PaneLayout()
        let first = layout.panes[0]
        let right = try layout.dividing(first, .horizontal)
        let split = try #require(layout.arrangement(in: CGSize(width: 906, height: 600), spacing: spacing, minimum: minimum).dividers.first)
        layout.setFraction(0.25, of: split.id)
        // Dividing the right pane downwards leaves the divider between left and right alone.
        let below = try layout.dividing(right, .vertical)
        let arrangement = layout.arrangement(in: CGSize(width: 906, height: 600), spacing: spacing, minimum: minimum)
        #expect(arrangement.panes[first]?.width == 222)
        #expect(arrangement.panes[right]?.height == 300)
        #expect(arrangement.panes[below]?.minY == 300)
    }

    @Test func removingGivesTheRoomToTheOtherSide() throws {
        var layout = PaneLayout()
        let first = layout.panes[0]
        let right = try layout.dividing(first, .horizontal)
        let below = try layout.dividing(right, .vertical)
        // The pane that was beside it takes its place and the focus.
        #expect(layout.remove(below) == right)
        #expect(layout.panes == [first, right])
        #expect(layout.remove(first) == right)
        #expect(layout.panes == [right])
        #expect(!layout.isSplit)
        // The last pane stays.
        #expect(layout.remove(right) == nil)
        #expect(layout.panes == [right])
    }

    @Test func removingAFirstSideHandsOverToTheNearestPane() throws {
        var layout = PaneLayout()
        let first = layout.panes[0]
        let right = try layout.dividing(first, .horizontal)
        let below = try layout.dividing(first, .vertical)
        // Left column: first over below. Closing the right pane goes to the pane nearest it.
        #expect(layout.remove(right) == below)
        #expect(layout.panes == [first, below])
    }

    @Test func dividersStopAtThePanesMinimums() throws {
        var layout = PaneLayout()
        let first = layout.panes[0]
        let second = try layout.dividing(first, .horizontal)
        let size = CGSize(width: 806, height: 600)
        let divider = try #require(layout.arrangement(in: size, spacing: spacing, minimum: minimum).dividers.first)
        // Each side with the gap after it, out of the width and a gap.
        #expect(divider.fractions == (206.0 / 812)...(606.0 / 812))
        layout.setFraction(0.01, of: divider.id)
        let arrangement = layout.arrangement(in: size, spacing: spacing, minimum: minimum)
        #expect(arrangement.panes[first]?.width == 200)
        #expect(arrangement.panes[second]?.width == 600)
        #expect(arrangement.dividers.first?.fraction == 206.0 / 812)
    }

    @Test func minimumSizeCountsEveryPaneAndGap() throws {
        var layout = PaneLayout()
        let first = layout.panes[0]
        let right = try layout.dividing(first, .horizontal)
        layout.split(right, along: .vertical)
        #expect(layout.minimumSize(spacing: spacing, minimum: minimum) == CGSize(width: 406, height: 300))
    }

    @Test func focusGoesRoundInReadingOrder() throws {
        var layout = PaneLayout()
        let first = layout.panes[0]
        let right = try layout.dividing(first, .horizontal)
        let below = try layout.dividing(first, .vertical)
        #expect(layout.pane(from: first, offsetBy: 1) == below)
        #expect(layout.pane(from: right, offsetBy: 1) == first)
        #expect(layout.pane(from: first, offsetBy: -1) == right)
        #expect(layout.pane(from: 99, offsetBy: 1) == nil)
    }

    @Test func aPaneKnowsItsSideOfItsSplit() throws {
        var layout = PaneLayout()
        let first = layout.panes[0]
        #expect(layout.side(of: first) == nil)
        let right = try layout.dividing(first, .horizontal)
        let below = try layout.dividing(right, .vertical)
        #expect(layout.side(of: first).map { [$0.axis == .horizontal, $0.isSecond] } == [true, false])
        #expect(layout.side(of: right).map { [$0.axis == .vertical, $0.isSecond] } == [true, false])
        // The new pane is the second side: it grows from the far edge.
        #expect(layout.side(of: below).map { [$0.axis == .vertical, $0.isSecond] } == [true, true])
        #expect(layout.side(of: 99) == nil)
    }

    @Test func survivesBeingSaved() throws {
        var layout = PaneLayout()
        let right = try layout.dividing(layout.panes[0], .horizontal)
        layout.split(right, along: .vertical)
        var restored = try JSONDecoder().decode(PaneLayout.self, from: JSONEncoder().encode(layout))
        #expect(restored == layout)
        #expect(restored.isConsistent)
        // IDs carry on from where they were, so a new pane doesn't take an old one's.
        let new = try restored.dividing(right, .horizontal)
        #expect(!layout.panes.contains(new))
        #expect(restored.isConsistent)
    }

    @Test func aDamagedLayoutIsNotConsistent() throws {
        let twoOfOnePane = #"{"nextID":3,"root":{"split":{"id":1,"axis":"horizontal","fraction":0.5,"first":{"pane":{"_0":0}},"second":{"pane":{"_0":0}}}}}"#
        #expect(try !JSONDecoder().decode(PaneLayout.self, from: Data(twoOfOnePane.utf8)).isConsistent)
        let shareOutOfRange = #"{"nextID":3,"root":{"split":{"id":1,"axis":"horizontal","fraction":4,"first":{"pane":{"_0":0}},"second":{"pane":{"_0":2}}}}}"#
        #expect(try !JSONDecoder().decode(PaneLayout.self, from: Data(shareOutOfRange.utf8)).isConsistent)
    }
}

@Suite("Pane tabs")
struct PaneTabsTests {
    @Test func aNewTabGoesAfterTheActiveOne() {
        var tabs = PaneTabs(tabs: [file("a"), file("b")], active: file("a"))
        tabs.insert(file("c"))
        #expect(tabs.tabs == [file("a"), file("c"), file("b")])
        #expect(tabs.active == file("c"))
        // One that's there already is only shown.
        tabs.insert(file("b"))
        #expect(tabs.tabs == [file("a"), file("c"), file("b")])
        #expect(tabs.active == file("b"))
        tabs.insert(file("d"), at: .max)
        #expect(tabs.tabs.last == file("d"))
    }

    @Test func closingTheActiveTabShowsItsNeighbor() {
        var tabs = PaneTabs(tabs: [file("a"), file("b"), file("c")], active: file("b"))
        tabs.remove(file("b"))
        #expect(tabs.active == file("c"))
        tabs.remove(file("c"))
        #expect(tabs.active == file("a"))
        tabs.remove(file("a"))
        #expect(tabs.active == nil)
        #expect(tabs.isEmpty)
    }

    @Test func closingAnotherTabKeepsTheActiveOne() {
        var tabs = PaneTabs(tabs: [file("a"), file("b"), file("c")], active: file("c"))
        tabs.remove(file("a"))
        #expect(tabs.active == file("c"))
    }

    @Test func steppingGoesRound() {
        let tabs = PaneTabs(tabs: [file("a"), file("b"), file("c")], active: file("c"))
        #expect(tabs.tab(offsetBy: 1) == file("a"))
        #expect(tabs.tab(offsetBy: -1) == file("b"))
        #expect(PaneTabs(tabs: [file("a")]).tab(offsetBy: 1) == nil)
    }

    @Test func movingReorders() {
        var tabs = PaneTabs(tabs: [file("a"), file("b"), file("c")], active: file("a"))
        tabs.move(file("a"), to: 2)
        #expect(tabs.tabs == [file("b"), file("c"), file("a")])
        tabs.move(file("a"), to: -4)
        #expect(tabs.tabs == [file("a"), file("b"), file("c")])
    }

    @Test func aTabThatIsntThereCantBeActive() {
        #expect(PaneTabs(tabs: [file("a"), file("b")], active: file("z")).active == file("a"))
        #expect(PaneTabs(tabs: [file("a"), file("a")]).tabs == [file("a")])
    }

    @Test func retargetingFollowsARename() {
        var tabs = PaneTabs(tabs: [file("a"), file("b")], active: file("b"))
        tabs.retarget { $0 == file("b") ? file("c") : nil }
        #expect(tabs.tabs == [file("a"), file("c")])
        #expect(tabs.active == file("c"))
    }
}
