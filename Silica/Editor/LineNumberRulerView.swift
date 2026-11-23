import AppKit

/// A line-number gutter for a TextKit 2 `NSTextView`.
///
/// Numbers count logical lines (separated by `\n`, `\r\n` or `\r`), so a wrapped
/// line shows a single number. Only the visible layout fragments are drawn, and
/// no background is painted, so the editor card's glass shows through.
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?

    /// UTF-16 offset where each line starts; rebuilt lazily after edits.
    private var lineStarts: [Int] = [0]
    private var lineStartsAreStale = true

    enum LineDiffKind: Equatable {
        case added
        case modified
        case deleted
    }

    private var diffMarkers: [Int: LineDiffKind] = [:]
    var onDiffMarkerClicked: ((Int, NSRect) -> Void)?

    private var font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private let leadingPadding: CGFloat = 6
    private let trailingPadding: CGFloat = 6

    func updateGitDiff(markers: [Int: LineDiffKind]) {
        guard self.diffMarkers != markers else { return }
        self.diffMarkers = markers
        self.needsDisplay = true
    }

    init(textView: NSTextView, scrollView: NSScrollView, editorFontSize: CGFloat) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        font = Self.font(forEditorSize: editorFontSize)
        clientView = textView
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(setNeedsRedraw),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(setNeedsRedraw),
            name: NSView.frameDidChangeNotification, object: textView
        )

        rebuildLineStartsIfNeeded()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    /// Vibrant label colors blend with the glass behind the card and wash out in dark mode.
    override var allowsVibrancy: Bool { false }

    /// Numbers stay two points smaller than the editor text.
    private static func font(forEditorSize size: CGFloat) -> NSFont {
        .monospacedDigitSystemFont(ofSize: max(size - 2, 8), weight: .regular)
    }

    /// Call when the editor's font size changes.
    func setEditorFontSize(_ size: CGFloat) {
        font = Self.font(forEditorSize: size)
        updateThickness()
        needsDisplay = true
    }

    /// Call after the text changes.
    func textDidChange() {
        lineStartsAreStale = true
        rebuildLineStartsIfNeeded()
        needsDisplay = true
    }

    /// The 1-based line containing the UTF-16 `offset`.
    func lineNumber(at offset: Int) -> Int {
        rebuildLineStartsIfNeeded()
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }

    /// Where the 1-based `line` starts, clamped to the last line.
    func offset(ofLine line: Int) -> Int {
        rebuildLineStartsIfNeeded()
        return lineStarts[min(max(line, 1), lineStarts.count) - 1]
    }

    var lineCount: Int {
        rebuildLineStartsIfNeeded()
        return lineStarts.count
    }

    @objc func setNeedsRedraw() {
        needsDisplay = true
    }

    // MARK: Drawing

    /// Draws numbers only; skipping `super` keeps the ruler's default background off the glass.
    override func draw(_ dirtyRect: NSRect) {
        guard let textView,
              let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager else { return }
        rebuildLineStartsIfNeeded()

        let origin = textView.textContainerOrigin
        let visible = textView.visibleRect
        let top = CGPoint(x: 0, y: max(0, visible.minY - origin.y))
        let bottom = visible.maxY - origin.y
        let documentStart = layoutManager.documentRange.location
        let start = layoutManager.textLayoutFragment(for: top)?.rangeInElement.location ?? documentStart

        let currentLine = lineIndex(for: textView.selectedRange().location)
        let normal: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: SyntaxTheme.lineNumber]
        let current: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: SyntaxTheme.currentLineNumber]
        var lastDrawn = -1

        layoutManager.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout, .ensuresExtraLineFragment]) { fragment in
            let frame = fragment.layoutFragmentFrame
            guard frame.minY <= bottom else { return false }
            let fragmentOffset = contentManager.offset(from: documentStart, to: fragment.rangeInElement.location)

            for line in fragment.textLineFragments {
                let offset = fragmentOffset + line.characterRange.location
                let index = lineIndex(for: offset)
                // Wrapped continuations don't start a line; the extra fragment can repeat one.
                guard lineStarts[index] == offset, index != lastDrawn else { continue }
                lastDrawn = index

                let baseline = origin.y + frame.minY + line.typographicBounds.minY + line.glyphOrigin.y
                let y = convert(NSPoint(x: 0, y: baseline), from: textView).y - font.ascender
                let label = NSAttributedString(string: "\(index + 1)", attributes: index == currentLine ? current : normal)
                let x = bounds.width - trailingPadding - label.size().width
                label.draw(at: NSPoint(x: x, y: y))

                // Gutter Git Diff Indicator (VS Code style: 3pt vertical stripe on right edge; wedge triangle for deletion)
                if let diffKind = diffMarkers[index + 1] {
                    let markerHeight = max(line.typographicBounds.height, font.pointSize + 4)
                    let markerY = convert(NSPoint(x: 0, y: origin.y + frame.minY + line.typographicBounds.minY), from: textView).y
                    let rightX = bounds.width

                    switch diffKind {
                    case .added:
                        NSColor(red: 0.16, green: 0.65, blue: 0.27, alpha: 1.0).setFill()
                        let markerRect = NSRect(x: rightX - 3.0, y: markerY, width: 3.0, height: markerHeight)
                        let path = NSBezierPath(rect: markerRect)
                        path.fill()
                    case .modified:
                        NSColor(red: 0.13, green: 0.47, blue: 0.83, alpha: 1.0).setFill()
                        let markerRect = NSRect(x: rightX - 3.0, y: markerY, width: 3.0, height: markerHeight)
                        let path = NSBezierPath(rect: markerRect)
                        path.fill()
                    case .deleted:
                        // VS Code renders deleted lines as an arrow/wedge pointing into the editor
                        NSColor(red: 0.84, green: 0.23, blue: 0.29, alpha: 1.0).setFill()
                        let triangle = NSBezierPath()
                        let triSize: CGFloat = 5.0
                        let triY = markerY
                        triangle.move(to: NSPoint(x: rightX, y: triY))
                        triangle.line(to: NSPoint(x: rightX - triSize, y: triY))
                        triangle.line(to: NSPoint(x: rightX, y: triY + triSize))
                        triangle.close()
                        triangle.fill()
                    }
                }
            }
            return true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let line = lineForPoint(point), diffMarkers[line] != nil {
            let rect = rectForLine(line) ?? NSRect(x: bounds.width - 4, y: max(0, point.y - 10), width: 4, height: 20)
            onDiffMarkerClicked?(line, rect)
            return
        }
        super.mouseDown(with: event)
    }

    func rectForLine(_ targetLine: Int) -> NSRect? {
        guard let textView = textView, let layoutManager = textView.textLayoutManager else { return nil }
        guard targetLine >= 1 && targetLine <= lineStarts.count else { return nil }
        let offset = lineStarts[targetLine - 1]
        guard let contentManager = layoutManager.textContentManager,
              let location = contentManager.location(contentManager.documentRange.location, offsetBy: offset),
              let fragment = layoutManager.textLayoutFragment(for: location) else { return nil }
        let frame = fragment.layoutFragmentFrame
        let markerHeight = max(frame.height, font.pointSize + 4)
        let markerY = convert(NSPoint(x: 0, y: textView.textContainerOrigin.y + frame.minY), from: textView).y
        return NSRect(x: bounds.width - 3.0, y: markerY, width: 3.0, height: markerHeight)
    }

    private func lineForPoint(_ point: NSPoint) -> Int? {
        guard let textView = textView, let layoutManager = textView.textLayoutManager else { return nil }
        let textPoint = convert(point, to: textView)
        guard let fragment = layoutManager.textLayoutFragment(for: textPoint) else { return nil }
        guard let contentManager = layoutManager.textContentManager else { return nil }
        let docStart = contentManager.documentRange.location
        let offset = contentManager.offset(from: docStart, to: fragment.rangeInElement.location)
        let index = lineIndex(for: offset)
        return index + 1
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if !diffMarkers.isEmpty {
            let diffEdgeRect = NSRect(x: bounds.width - 12, y: 0, width: 12, height: bounds.height)
            addCursorRect(diffEdgeRect, cursor: .pointingHand)
        }
    }

    // MARK: Line index

    private func lineIndex(for offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }

    private func rebuildLineStartsIfNeeded() {
        guard lineStartsAreStale, let storage = textView?.textStorage else { return }
        lineStartsAreStale = false

        let text = storage.string as NSString
        let length = text.length
        var starts = [0]
        let chunk = 8192
        var buffer = [unichar](repeating: 0, count: chunk)
        var location = 0
        var previousWasCR = false

        while location < length {
            let count = min(chunk, length - location)
            text.getCharacters(&buffer, range: NSRange(location: location, length: count))
            for i in 0..<count {
                switch buffer[i] {
                case 0x0D: // \r
                    starts.append(location + i + 1)
                    previousWasCR = true
                case 0x0A: // \n, folded into a preceding \r
                    if previousWasCR {
                        starts[starts.count - 1] = location + i + 1
                    } else {
                        starts.append(location + i + 1)
                    }
                    previousWasCR = false
                default:
                    previousWasCR = false
                }
            }
            location += count
        }
        lineStarts = starts
        updateThickness()
    }

    /// Fits the widest line number, with room for at least three digits.
    private func updateThickness() {
        let digits = max(3, String(lineStarts.count).count)
        let digitWidth = NSAttributedString(string: "8", attributes: [.font: font]).size().width
        let thickness = ceil(leadingPadding + CGFloat(digits) * digitWidth + trailingPadding)
        if ruleThickness != thickness {
            ruleThickness = thickness
        }
    }
}
