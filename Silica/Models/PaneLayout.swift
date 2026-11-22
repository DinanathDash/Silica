import CoreGraphics
import Foundation

/// How the editor area is divided into panes: one pane, or a split whose two sides
/// are each a pane or a split again, as a terminal's panes are. Splitting a pane
/// puts a new one to its right or below it; closing one gives its room to what was
/// beside it.
struct PaneLayout: Equatable, Codable {
    typealias PaneID = Int
    typealias SplitID = Int

    enum Axis: String, Codable {
        /// Side by side, the second to the right of the first.
        case horizontal
        /// One above the other, the second below the first.
        case vertical
    }

    indirect enum Node: Equatable, Codable {
        case pane(PaneID)
        /// `fraction` is the first side's share of the split, each side counted
        /// with the gap that follows it.
        case split(id: SplitID, axis: Axis, fraction: Double, first: Node, second: Node)
    }

    private(set) var root: Node = .pane(0)
    /// Panes and splits are numbered from the same count, so no two share an ID.
    private var nextID = 1

    /// The panes in reading order: a split's first side before its second.
    var panes: [PaneID] { root.panes }

    var isSplit: Bool {
        if case .split = root { true } else { false }
    }

    func contains(_ pane: PaneID) -> Bool {
        panes.contains(pane)
    }

    /// The pane `offset` places along from `pane` in reading order, going round
    /// from either end to the other.
    func pane(from pane: PaneID, offsetBy offset: Int) -> PaneID? {
        let panes = panes
        guard let index = panes.firstIndex(of: pane) else { return nil }
        return panes[((index + offset) % panes.count + panes.count) % panes.count]
    }

    /// Which side of its split a pane is on, and which way the split runs; `nil`
    /// for the only pane. A new pane is always the second side.
    func side(of pane: PaneID) -> (axis: Axis, isSecond: Bool)? {
        root.side(of: pane)
    }

    // MARK: Changing

    /// Divides `pane` in two along `axis` and returns the new pane, which comes
    /// second: to the right or below. The panes in a row (or a column) of splits it
    /// joins all get the same share of it again.
    @discardableResult
    mutating func split(_ pane: PaneID, along axis: Axis) -> PaneID? {
        guard contains(pane) else { return nil }
        let split = nextID
        let new = nextID + 1
        nextID += 2
        root = root.replacing(pane: pane, with: .split(id: split, axis: axis, fraction: 0.5, first: .pane(pane), second: .pane(new)))
        balanceRun(endingAt: root.splits(above: new))
        return new
    }

    /// Takes `pane` away, giving its room to what was on the other side of its
    /// split. Returns the pane that is now where it was (the first, if that side
    /// is split itself), or `nil` if `pane` is the only one or isn't there.
    @discardableResult
    mutating func remove(_ pane: PaneID) -> PaneID? {
        let above = root.splits(above: pane)
        guard let parent = above.last, let (reduced, heir) = root.removing(pane: pane) else { return nil }
        root = reduced
        // Out of a row of three, the two that are left share it evenly again.
        let rest = Array(above.dropLast())
        if let grandparent = rest.last, grandparent.axis == parent.axis {
            balanceRun(endingAt: rest)
        }
        return heir
    }

    /// Moves a split's divider. The share is limited when the layout is arranged,
    /// to what leaves each side its minimum.
    mutating func setFraction(_ fraction: Double, of split: SplitID) {
        guard fraction.isFinite else { return }
        root = root.updating(split: split) { node in
            guard case .split(let id, let axis, _, let first, let second) = node else { return node }
            return .split(id: id, axis: axis, fraction: min(max(fraction, 0), 1), first: first, second: second)
        }
    }

    /// Evens out the run of same-axis splits at the end of `path` (the splits above
    /// some pane, outermost first), so that each pane in the row or column they
    /// make has the same share of it.
    private mutating func balanceRun(endingAt path: [(id: SplitID, axis: Axis)]) {
        guard let last = path.last else { return }
        var top = last
        for split in path.reversed() {
            guard split.axis == last.axis else { break }
            top = split
        }
        root = root.updating(split: top.id) { $0.balanced(along: last.axis) }
    }

    // MARK: Checking

    /// Whether the layout holds together: read from a saved session, it's used
    /// only if every ID is its own and no share is out of range.
    var isConsistent: Bool {
        let ids = root.ids
        return Set(ids).count == ids.count && ids.allSatisfy { $0 >= 0 && $0 < nextID } && root.hasValidFractions
    }

    // MARK: Arranging

    /// Where the panes and the dividers between them go.
    struct Arrangement: Equatable {
        struct Divider: Equatable, Identifiable {
            let id: SplitID
            let axis: Axis
            /// The line between the two sides: `spacing` thick across `axis`.
            let frame: CGRect
            /// What the shares are of: the split's length along the axis, and a gap.
            /// Moving the divider that far takes the first side from none to all of it.
            let span: CGFloat
            /// The first side's share as laid out.
            let fraction: Double
            /// The shares the first side can take while both keep their minimum.
            let fractions: ClosedRange<Double>
        }

        var panes: [PaneID: CGRect] = [:]
        var dividers: [Divider] = []
    }

    /// The gap left between two panes: `horizontal` between panes side by side,
    /// `vertical` between one above another.
    struct Spacing: Equatable {
        var horizontal: CGFloat
        var vertical: CGFloat

        func along(_ axis: Axis) -> CGFloat {
            axis == .horizontal ? horizontal : vertical
        }
    }

    /// Lays the panes out in `size`, with `spacing` between two of them, keeping
    /// each at `minimum` or more while there is room for that.
    func arrangement(in size: CGSize, spacing: Spacing, minimum: CGSize) -> Arrangement {
        var arrangement = Arrangement()
        root.arrange(in: CGRect(origin: .zero, size: size), spacing: spacing, minimum: minimum, into: &arrangement)
        return arrangement
    }

    /// The least room the layout needs for every pane to have `minimum`.
    func minimumSize(spacing: Spacing, minimum: CGSize) -> CGSize {
        root.minimumSize(spacing: spacing, minimum: minimum)
    }
}

private extension PaneLayout.Node {
    var panes: [PaneLayout.PaneID] {
        switch self {
        case .pane(let id): [id]
        case .split(_, _, _, let first, let second): first.panes + second.panes
        }
    }

    /// Every pane's and split's ID.
    var ids: [Int] {
        switch self {
        case .pane(let id): [id]
        case .split(let id, _, _, let first, let second): [id] + first.ids + second.ids
        }
    }

    var hasValidFractions: Bool {
        switch self {
        case .pane: true
        case .split(_, _, let fraction, let first, let second):
            fraction.isFinite && (0...1).contains(fraction) && first.hasValidFractions && second.hasValidFractions
        }
    }

    /// The splits `pane` is inside, outermost first; empty if it isn't here.
    func splits(above pane: PaneLayout.PaneID) -> [(id: PaneLayout.SplitID, axis: PaneLayout.Axis)] {
        guard case .split(let id, let axis, _, let first, let second) = self else { return [] }
        for side in [first, second] where side.panes.contains(pane) {
            return [(id, axis)] + side.splits(above: pane)
        }
        return []
    }

    func side(of pane: PaneLayout.PaneID) -> (axis: PaneLayout.Axis, isSecond: Bool)? {
        guard case .split(_, let axis, _, let first, let second) = self else { return nil }
        if case .pane(pane) = first { return (axis, false) }
        if case .pane(pane) = second { return (axis, true) }
        return first.side(of: pane) ?? second.side(of: pane)
    }

    func replacing(pane: PaneLayout.PaneID, with node: PaneLayout.Node) -> PaneLayout.Node {
        switch self {
        case .pane(let id):
            return id == pane ? node : self
        case .split(let id, let axis, let fraction, let first, let second):
            return .split(
                id: id, axis: axis, fraction: fraction,
                first: first.replacing(pane: pane, with: node), second: second.replacing(pane: pane, with: node)
            )
        }
    }

    /// Without `pane`: the other side of its split stands where the split was.
    /// Also gives the pane now in its place; `nil` if `pane` isn't in a split here.
    func removing(pane: PaneLayout.PaneID) -> (node: PaneLayout.Node, heir: PaneLayout.PaneID)? {
        guard case .split(let id, let axis, let fraction, let first, let second) = self else { return nil }
        if case .pane(pane) = first, let heir = second.panes.first { return (second, heir) }
        if case .pane(pane) = second, let heir = first.panes.last { return (first, heir) }
        if let (reduced, heir) = first.removing(pane: pane) {
            return (.split(id: id, axis: axis, fraction: fraction, first: reduced, second: second), heir)
        }
        if let (reduced, heir) = second.removing(pane: pane) {
            return (.split(id: id, axis: axis, fraction: fraction, first: first, second: reduced), heir)
        }
        return nil
    }

    func updating(split: PaneLayout.SplitID, _ change: (PaneLayout.Node) -> PaneLayout.Node) -> PaneLayout.Node {
        guard case .split(let id, let axis, let fraction, let first, let second) = self else { return self }
        if id == split { return change(self) }
        return .split(
            id: id, axis: axis, fraction: fraction,
            first: first.updating(split: split, change), second: second.updating(split: split, change)
        )
    }

    /// How many panes share the room along `axis`: a split the other way counts as one.
    private func weight(along axis: PaneLayout.Axis) -> Int {
        guard case .split(_, axis, _, let first, let second) = self else { return 1 }
        return first.weight(along: axis) + second.weight(along: axis)
    }

    /// With the splits along `axis` from here down set so their panes are all the same size.
    func balanced(along axis: PaneLayout.Axis) -> PaneLayout.Node {
        guard case .split(let id, axis, _, let first, let second) = self else { return self }
        let weights = (first.weight(along: axis), second.weight(along: axis))
        return .split(
            id: id, axis: axis, fraction: Double(weights.0) / Double(weights.0 + weights.1),
            first: first.balanced(along: axis), second: second.balanced(along: axis)
        )
    }

    func minimumSize(spacing: PaneLayout.Spacing, minimum: CGSize) -> CGSize {
        guard case .split(_, let axis, _, let first, let second) = self else { return minimum }
        let a = first.minimumSize(spacing: spacing, minimum: minimum)
        let b = second.minimumSize(spacing: spacing, minimum: minimum)
        switch axis {
        case .horizontal: return CGSize(width: a.width + spacing.horizontal + b.width, height: max(a.height, b.height))
        case .vertical: return CGSize(width: max(a.width, b.width), height: a.height + spacing.vertical + b.height)
        }
    }

    func arrange(in rect: CGRect, spacing: PaneLayout.Spacing, minimum: CGSize, into arrangement: inout PaneLayout.Arrangement) {
        guard case .split(let id, let axis, let fraction, let first, let second) = self else {
            if case .pane(let pane) = self { arrangement.panes[pane] = rect }
            return
        }
        let gap = spacing.along(axis)
        let isHorizontal = axis == .horizontal
        let extent = isHorizontal ? rect.width : rect.height
        // What the two sides have between them, and what the shares are of: each
        // side is counted with a gap after it, so that panes with the same share of
        // a row come out the same width however the row's splits nest.
        let room = max(extent - gap, 0)
        let span = extent + gap
        let firstMinimum = first.minimumSize(spacing: spacing, minimum: minimum)
        let secondMinimum = second.minimumSize(spacing: spacing, minimum: minimum)
        let least = isHorizontal ? firstMinimum.width : firstMinimum.height
        let most = room - (isHorizontal ? secondMinimum.width : secondMinimum.height)

        var fractions = 0.0...1.0
        var firstLength = room / 2
        if span > 0, least <= most {
            fractions = Double((least + gap) / span)...Double((most + gap) / span)
            let share = min(max(fraction, fractions.lowerBound), fractions.upperBound)
            // Whole points, so the text in neither pane sits between pixels.
            firstLength = min(max((span * share - gap).rounded(), least), most)
        } else if least + room - most > 0 {
            // Without room for both minimums, each side is short by the same proportion.
            firstLength = (room * least / (least + room - most)).rounded()
        }
        let share = span > 0 ? Double((firstLength + gap) / span) : fraction
        if least > most { fractions = share...share }

        let firstRect: CGRect
        let secondRect: CGRect
        let dividerRect: CGRect
        if isHorizontal {
            firstRect = CGRect(x: rect.minX, y: rect.minY, width: firstLength, height: rect.height)
            dividerRect = CGRect(x: firstRect.maxX, y: rect.minY, width: gap, height: rect.height)
            secondRect = CGRect(x: dividerRect.maxX, y: rect.minY, width: room - firstLength, height: rect.height)
        } else {
            firstRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstLength)
            dividerRect = CGRect(x: rect.minX, y: firstRect.maxY, width: rect.width, height: gap)
            secondRect = CGRect(x: rect.minX, y: dividerRect.maxY, width: rect.width, height: room - firstLength)
        }
        arrangement.dividers.append(.init(
            id: id, axis: axis, frame: dividerRect, span: span, fraction: share, fractions: fractions
        ))
        first.arrange(in: firstRect, spacing: spacing, minimum: minimum, into: &arrangement)
        second.arrange(in: secondRect, spacing: spacing, minimum: minimum, into: &arrangement)
    }
}

/// The tabs of one pane, in the order of its tab bar, and the one it shows.
struct PaneTabs: Equatable {
    private(set) var tabs: [URL] = []
    /// One of `tabs`, as long as there are any.
    private(set) var active: URL?

    init(tabs: [URL] = [], active: URL? = nil) {
        var seen = Set<URL>()
        self.tabs = tabs.filter { seen.insert($0).inserted }
        self.active = active.flatMap { seen.contains($0) ? $0 : nil } ?? self.tabs.first
    }

    var isEmpty: Bool { tabs.isEmpty }

    func contains(_ url: URL) -> Bool {
        tabs.contains(url)
    }

    /// Adds a tab after the active one, or at `index`, and shows it. A tab that's
    /// already here is only shown.
    mutating func insert(_ url: URL, at index: Int? = nil) {
        if !tabs.contains(url) {
            if let index {
                tabs.insert(url, at: min(max(index, 0), tabs.count))
            } else if let active, let activeIndex = tabs.firstIndex(of: active) {
                tabs.insert(url, at: activeIndex + 1)
            } else {
                tabs.append(url)
            }
        }
        active = url
    }

    mutating func activate(_ url: URL) {
        if tabs.contains(url) { active = url }
    }

    /// Takes a tab out. If it was the one showing, the tab after it takes its
    /// place, or the one before it when it was the last.
    mutating func remove(_ url: URL) {
        guard let index = tabs.firstIndex(of: url) else { return }
        tabs.remove(at: index)
        if active == url {
            active = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)]
        }
    }

    /// Puts a tab at another place in the bar.
    mutating func move(_ url: URL, to index: Int) {
        guard let current = tabs.firstIndex(of: url) else { return }
        let target = min(max(index, 0), tabs.count - 1)
        guard target != current else { return }
        tabs.remove(at: current)
        tabs.insert(url, at: target)
    }

    /// The tab `offset` places along the bar from the active one, going round from
    /// either end to the other.
    func tab(offsetBy offset: Int) -> URL? {
        guard tabs.count > 1, let active, let index = tabs.firstIndex(of: active) else { return nil }
        return tabs[((index + offset) % tabs.count + tabs.count) % tabs.count]
    }

    /// Points the tabs at new locations (a rename, a Save As); `nil` leaves one as
    /// it is. Two tabs that come to the same file become one.
    mutating func retarget(_ moved: (URL) -> URL?) {
        self = PaneTabs(tabs: tabs.map { moved($0) ?? $0 }, active: active.map { moved($0) ?? $0 })
    }
}
