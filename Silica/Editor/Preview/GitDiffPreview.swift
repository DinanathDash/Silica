import AppKit
import SwiftUI
import WebKit

/// Turns a `GitDiff` into the HTML the changes view shows: the file's lines with
/// their old and new numbers, added lines on green and removed ones on red, and
/// long unchanged stretches folded away until they're clicked.
nonisolated enum GitDiffHTMLRenderer {
    /// Unchanged lines kept around each change.
    private static let contextLines = 3
    /// Unchanged lines worth folding; fewer are just shown.
    private static let smallestFold = 6
    /// Above this many UTF-16 units a side isn't syntax highlighted.
    private static let maxHighlightLength = 1_000_000

    /// How to lay the changes out and what to say when there are none.
    struct Options: Sendable {
        /// The old text on the left and the new on the right.
        var sideBySide = false
        /// What one commit changed, not what has changed since the last.
        var isCommit = false
        var comparison = GitDiff.Request.Comparison.all
        /// A link over each change, to stage or unstage just that one.
        var changeAction: String?
    }

    static func render(_ result: GitDiff.Result, language: SyntaxLanguage?, options: Options) -> String {
        switch result {
        case .notText:
            return note("This file isn’t text, so its changes can’t be shown.")
        case .unavailable:
            return note(options.isCommit ? "This file couldn’t be read from the commit." : "The last committed version of this file couldn’t be read.")
        case .diff(let diff):
            guard diff.hasChanges else {
                if options.isCommit { return note("The commit didn’t change this file’s text.") }
                let text = switch options.comparison {
                case .all: "No changes since the last commit."
                case .unstaged: "No unstaged changes in this file."
                case .staged: "Nothing staged in this file."
                }
                return note(text)
            }
            return rows(of: diff, language: language, options: options)
        }
    }

    private static func note(_ text: String) -> String {
        "<p class=\"note\">\(MarkdownHTMLRenderer.escape(text))</p>"
    }

    /// One row of the page: a line of the old text, of the new, or of both.
    private struct Row {
        var old: GitDiff.Line?
        var new: GitDiff.Line?
        var isContext = false
        /// On a change's first row: the change's number.
        var change: Int?
    }

    /// Side by side, the lines a change removed sit beside the ones it added,
    /// first with first; in one column, above them.
    private static func rows(pairing diff: GitDiff, sideBySide: Bool) -> [Row] {
        let lines = diff.lines
        var rows: [Row] = []
        var index = 0
        for (number, change) in diff.changes.enumerated() {
            rows += lines[index..<change.lowerBound].map { Row(old: $0, new: $0, isContext: true) }
            index = change.upperBound
            let removed = lines[change].filter { $0.kind == .removed }
            let added = lines[change].filter { $0.kind == .added }
            let first = rows.count
            if sideBySide {
                for place in 0..<max(removed.count, added.count) {
                    rows.append(Row(
                        old: place < removed.count ? removed[place] : nil,
                        new: place < added.count ? added[place] : nil
                    ))
                }
            } else {
                rows += removed.map { Row(old: $0) } + added.map { Row(new: $0) }
            }
            if first < rows.count { rows[first].change = number }
        }
        rows += lines[index...].map { Row(old: $0, new: $0, isContext: true) }
        return rows
    }

    private static func rows(of diff: GitDiff, language: SyntaxLanguage?, options: Options) -> String {
        let sideBySide = options.sideBySide
        let oldIndex = LineIndex(diff.oldText), newIndex = LineIndex(diff.newText)
        // Where a removed line has an added one in its place, what differs
        // between the two is marked within them.
        var oldMarks: [Int: Range<Int>] = [:], newMarks: [Int: Range<Int>] = [:]
        for change in diff.changes {
            let removed = diff.lines[change].compactMap { $0.kind == .removed ? $0.old : nil }
            let added = diff.lines[change].compactMap { $0.kind == .added ? $0.new : nil }
            for (old, new) in zip(removed, added) {
                guard let marks = marks(between: oldIndex.line(old - 1), and: newIndex.line(new - 1)) else { continue }
                oldMarks[old - 1] = marks.old
                newMarks[new - 1] = marks.new
            }
        }
        let oldLines = highlightedLines(of: oldIndex, text: diff.oldText, language: language, marks: oldMarks)
        let newLines = highlightedLines(of: newIndex, text: diff.newText, language: language, marks: newMarks)
        let rows = rows(pairing: diff, sideBySide: sideBySide)
        // Room for the longest line number, so the code starts in one column.
        let digits = max(String(max(oldLines.count, newLines.count)).count, 3)
        var html = "<div class=\"diff\(sideBySide ? " split" : "")\" style=\"--digits: \(digits)\">"
        let action = diff.canRewrite ? options.changeAction.map(MarkdownHTMLRenderer.escape) : nil

        func oldCode(_ line: GitDiff.Line) -> String {
            line.old.flatMap { oldLines.indices.contains($0 - 1) ? oldLines[$0 - 1] : nil } ?? ""
        }
        func newCode(_ line: GitDiff.Line) -> String {
            line.new.flatMap { newLines.indices.contains($0 - 1) ? newLines[$0 - 1] : nil } ?? ""
        }
        func number(_ value: Int?) -> String { value.map(String.init) ?? "" }

        /// One side of a row side by side: a line of the old text or of the new,
        /// or nothing where the other side has a line this one has no match for.
        func half(_ line: GitDiff.Line?, isOld: Bool, isContext: Bool) -> String {
            guard let line else { return "<div class=\"h e\"></div>" }
            let name = isContext ? "" : (isOld ? " d" : " a")
            let sign = isContext ? "" : (isOld ? "−" : "+")
            return "<div class=\"h\(name)\"><i>\(number(isOld ? line.old : line.new))</i><b>\(sign)</b><code>\(isOld ? oldCode(line) : newCode(line))</code></div>"
        }

        func append(_ row: Row) {
            if let action, let change = row.change {
                html += "<div class=\"act\"><a href=\"\(GitDiffPreview.changeScheme):\(change)\">\(action)</a></div>"
            }
            if sideBySide {
                html += "<div class=\"r\">\(half(row.old, isOld: true, isContext: row.isContext))\(half(row.new, isOld: false, isContext: row.isContext))</div>"
            } else if row.isContext, let line = row.new {
                html += "<div class=\"r\"><i>\(number(line.old))</i><i>\(number(line.new))</i><b></b><code>\(newCode(line))</code></div>"
            } else if let line = row.old {
                html += "<div class=\"r d\"><i>\(number(line.old))</i><i></i><b>−</b><code>\(oldCode(line))</code></div>"
            } else if let line = row.new {
                html += "<div class=\"r a\"><i></i><i>\(number(line.new))</i><b>+</b><code>\(newCode(line))</code></div>"
            }
        }

        var index = 0
        while index < rows.count {
            guard rows[index].isContext else {
                append(rows[index])
                index += 1
                continue
            }
            var end = index
            while end < rows.count, rows[end].isContext { end += 1 }
            // Context stays next to the changes: after the one above this stretch
            // and before the one below it, where there is one.
            let head = index == 0 ? 0 : contextLines
            let tail = end == rows.count ? 0 : contextLines
            let hidden = end - index - head - tail
            if hidden >= smallestFold {
                rows[index..<index + head].forEach(append)
                html += "<details><summary>\(hidden.formatted()) unchanged lines</summary>"
                rows[index + head..<end - tail].forEach(append)
                html += "</details>"
                rows[end - tail..<end].forEach(append)
            } else {
                rows[index..<end].forEach(append)
            }
            index = end
        }
        return html + "</div>"
    }

    /// A text as UTF-16 with where each of its lines is, without the line's ending.
    private struct LineIndex {
        let units: [UInt16]
        private(set) var bounds: [Range<Int>] = []

        init(_ text: String) {
            units = Array(text.utf16)
            var start = 0
            func add(to limit: Int) {
                // A CRLF file's lines end in a carriage return, which isn't shown.
                bounds.append(start..<(limit > start && units[limit - 1] == 0x0D ? limit - 1 : limit))
            }
            for (index, unit) in units.enumerated() where unit == 0x0A {
                add(to: index)
                start = index + 1
            }
            if start < units.count { add(to: units.count) }
        }

        func line(_ number: Int) -> ArraySlice<UInt16> {
            bounds.indices.contains(number) ? units[bounds[number]] : []
        }
    }

    /// What differs between a line and the line that replaced it: the part of
    /// each between what they start with in common and what they end with in
    /// common, as offsets into the line. `nil` when they share too little for
    /// that to say anything.
    private static func marks(
        between old: ArraySlice<UInt16>, and new: ArraySlice<UInt16>
    ) -> (old: Range<Int>, new: Range<Int>)? {
        let shorter = min(old.count, new.count)
        guard shorter > 0 else { return nil }
        func isTrailSurrogate(_ unit: UInt16) -> Bool { (0xDC00...0xDFFF).contains(unit) }
        var prefix = 0
        while prefix < shorter, old[old.startIndex + prefix] == new[new.startIndex + prefix] { prefix += 1 }
        guard prefix < old.count || prefix < new.count else { return nil }
        var suffix = 0
        while suffix < shorter - prefix, old[old.endIndex - 1 - suffix] == new[new.endIndex - 1 - suffix] { suffix += 1 }
        // Never between the two halves of a character outside the basic plane.
        if prefix > 0, prefix < old.count, isTrailSurrogate(old[old.startIndex + prefix]) { prefix -= 1 }
        if suffix > 0, isTrailSurrogate(old[old.endIndex - suffix]) { suffix -= 1 }
        // Indentation in common doesn't make two lines alike.
        let indent = old.prefix(prefix).prefix { $0 == 0x20 || $0 == 0x09 }.count
        guard prefix - indent + suffix >= 2 else { return nil }
        return (prefix..<(old.count - suffix), prefix..<(new.count - suffix))
    }

    /// The text's lines as HTML, colored as the editor colors them. The whole text
    /// is tokenized at once, so a comment or string that runs over several lines
    /// is colored on each. `marks` are the parts of lines to set off, by line.
    private static func highlightedLines(
        of index: LineIndex, text: String, language: SyntaxLanguage?, marks: [Int: Range<Int>]
    ) -> [String] {
        let units = index.units
        var kinds: [TokenKind?]?
        if let language, units.count <= maxHighlightLength {
            var found = [TokenKind?](repeating: nil, count: units.count)
            for token in language.tokenizer.tokenize(text as NSString) where NSMaxRange(token.range) <= units.count {
                for index in token.range.location..<NSMaxRange(token.range) { found[index] = token.kind }
            }
            kinds = found
        }

        return index.bounds.enumerated().map { number, bounds in
            let mark = marks[number].map { (bounds.lowerBound + $0.lowerBound)..<(bounds.lowerBound + $0.upperBound) }
            var html = ""
            var runStart = bounds.lowerBound
            while runStart < bounds.upperBound {
                // A run is of one color and wholly inside the mark or outside it.
                let isMarked = mark?.contains(runStart) ?? false
                var runEnd = runStart + 1
                while runEnd < bounds.upperBound,
                      kinds.map({ $0[runEnd] == $0[runStart] }) ?? true,
                      (mark?.contains(runEnd) ?? false) == isMarked { runEnd += 1 }
                var piece = MarkdownHTMLRenderer.escape(String(decoding: units[runStart..<runEnd], as: UTF16.self))
                if let kind = kinds?[runStart] { piece = "<span class=\"tok-\(kind)\">\(piece)</span>" }
                html += isMarked ? "<u>\(piece)</u>" : piece
                runStart = runEnd
            }
            return html
        }
    }
}

/// A file's changes since the last commit, shown in its tab in place of the editor
/// and kept with the tab. A web view like the Markdown preview's, on a transparent
/// background so the glass card shows through; nothing in the page runs or loads.
final class GitDiffPreview: NSObject, WKNavigationDelegate {
    let webView: PreviewWebView
    /// A character was typed; go back to the editor and insert it.
    var onType: ((String) -> Void)? {
        didSet { webView.onType = onType }
    }

    /// A change's "Stage Change" or "Unstage Change" link was clicked: which
    /// change, of which comparison.
    var onChangeAction: ((Int, GitDiff, GitDiff.Request) -> Void)?
    /// What the links over the changes point to: "silica-change:3".
    nonisolated static let changeScheme = "silica-change"
    /// The comparison the page shows, for the links over its changes.
    private var rendered: (diff: GitDiff, request: GitDiff.Request)?

    private var loadTask: Task<Void, Never>?
    /// What was last asked for, to lay out again when the layout setting changes.
    private var shown: (request: GitDiff.Request, language: SyntaxLanguage?)?
    /// The rows last asked for, so a refresh that changes nothing doesn't reload them.
    private var shownBody: String?
    /// The style sheet of the page last asked for.
    private var shownCSS: String?
    /// Where to scroll to once a refreshed page has loaded.
    private var pendingScroll: CGPoint?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = PreviewWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = .clear
        webView.setValue(false, forKey: "drawsBackground")
        // The page is styled from the editor's settings: font and size (⌘+ and ⌘−
        // work here too), tab width, wrapping and syntax colors.
        for name in [Notification.Name.editorFontSizeDidChange, .editorSettingsDidChange, .editorWrapDidChange, .syntaxThemeDidChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(restyle), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(layoutDidChange), name: .changesLayoutDidChange, object: nil
        )
    }

    /// Side by side or in one column: the same lines, placed differently.
    @objc private func layoutDidChange() {
        guard shown != nil else { return }
        render(afterWaiting: false, keepingScroll: true)
    }

    /// Swaps in the style sheet for the settings as they are now, without
    /// reloading, so the page stays where it was scrolled to.
    @objc private func restyle() {
        let css = Self.css
        guard shownBody != nil, css != shownCSS else { return }
        shownCSS = css
        guard let data = try? JSONEncoder().encode(css), let literal = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("{ const style = document.querySelector('head > style'); if (style) style.textContent = \(literal); }", in: nil, in: .defaultClient) { _ in }
    }

    /// Compares and renders off the main actor, then shows the result. A refresh
    /// (`isRefresh`) waits a moment first, as changes on disk come in bursts, and
    /// keeps the page where it was scrolled to.
    func show(_ request: GitDiff.Request, language: SyntaxLanguage?, isRefresh: Bool) {
        shown = (request, language)
        render(afterWaiting: isRefresh, keepingScroll: isRefresh)
    }

    private func render(afterWaiting waits: Bool, keepingScroll: Bool) {
        guard let (request, language) = shown else { return }
        var options = GitDiffHTMLRenderer.Options(
            sideBySide: EditorSettings.shared.showsChangesSideBySide, isCommit: request.commit != nil,
            comparison: request.comparison
        )
        // One change of an edited file can be staged by itself, or unstaged. A new
        // or deleted file is staged whole.
        if request.commit == nil, request.status == .modified {
            switch request.comparison {
            case .unstaged: options.changeAction = "Stage Change"
            case .staged: options.changeAction = "Unstage Change"
            case .all: break
            }
        }
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            if waits {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
            }
            let (body, diff) = await Task.detached(priority: .userInitiated) {
                let result = GitDiff.load(request)
                var diff: GitDiff?
                if case .diff(let found) = result { diff = found }
                return (GitDiffHTMLRenderer.render(result, language: language, options: options), diff)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.rendered = diff.map { ($0, request) }
            guard body != self.shownBody else { return }
            let isFirstPage = self.shownBody == nil
            self.shownBody = body
            // Something else to compare starts from the top.
            if isFirstPage || !keepingScroll {
                self.pendingScroll = nil
                self.load(body)
                return
            }
            self.webView.evaluateJavaScript("[window.scrollX, window.scrollY]", in: nil, in: .defaultClient) { [weak self] result in
                guard let self, self.shownBody == body else { return }
                let offset = (try? result.get()) as? [Double]
                self.pendingScroll = offset.flatMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
                self.load(body)
            }
        }
    }

    private func load(_ body: String) {
        let css = Self.css
        shownCSS = css
        webView.loadHTMLString("""
        <!doctype html>
        <html><head><meta charset="utf-8"><style>\(css)</style></head><body>\(body)</body></html>
        """, baseURL: nil)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A setting may have changed while the page was loading.
        if Self.css != shownCSS {
            shownCSS = nil
            restyle()
        }
        guard let scroll = pendingScroll else { return }
        pendingScroll = nil
        webView.evaluateJavaScript("window.scrollTo(\(scroll.x), \(scroll.y))", in: nil, in: .defaultClient) { _ in }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        // A link over a change: act on it, and stay on the page.
        if let url = navigationAction.request.url, url.scheme == Self.changeScheme,
           let number = Int(url.absoluteString.dropFirst(Self.changeScheme.count + 1)), let rendered {
            act(onChange: number, of: rendered.diff, request: rendered.request)
        }
        // Only the pages loaded here; the code shown may hold anything.
        decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel, preferences)
    }

    /// Staging or unstaging a change writes the index from the texts on the page,
    /// so the page has to be what the index and the file hold now: it's compared
    /// again first. If something has changed underneath (in a terminal, say), the
    /// page is brought up to date instead and nothing is written.
    private func act(onChange number: Int, of diff: GitDiff, request: GitDiff.Request) {
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { GitDiff.load(request) }.value
            guard let self, self.rendered?.diff.oldText == diff.oldText, self.rendered?.diff.newText == diff.newText else { return }
            if case .diff(let current) = result, current.oldText == diff.oldText, current.newText == diff.newText {
                self.onChangeAction?(number, current, request)
            } else {
                self.render(afterWaiting: false, keepingScroll: true)
            }
        }
    }

    /// Gives the changes the keyboard, where they were asked for from the tab:
    /// now if they're in the window, or else when they're put there, which
    /// happens a moment after they're asked for.
    func focus() {
        if let window = webView.window {
            window.makeFirstResponder(webView)
        } else {
            wantsFocus = true
        }
    }

    /// `focus()` was called before the web view was in a window.
    fileprivate var wantsFocus = false

    // MARK: Page

    /// The editor's font, size, line spacing, tab width and wrapping, and its
    /// syntax colors, so a line here looks as it does in the editor.
    private static var css: String {
        let settings = EditorSettings.shared
        let size = Int(settings.fontSize)
        let editorFont = settings.editorFont(ofSize: settings.fontSize)
        // To a hundredth of a point, written with a "." whatever the locale.
        let lineHeight = (TextController.lineHeight(of: editorFont) * 100).rounded() / 100
        // The editor's 12 points above the first line, plus the half of the line
        // spacing that the editor puts above a line and a page splits around it.
        let topPadding = 12 + ((lineHeight - NSLayoutManager().defaultLineHeight(for: editorFont)) * 50).rounded() / 100
        let font = settings.fontFamily.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\", " } ?? ""
        let tokens = DocumentPreview.tokenCSS
        let wrapping = settings.wrapsLines
            ? ".diff { width: 100%; } code { white-space: pre-wrap; overflow-wrap: anywhere; min-width: 0; }"
            : ".diff { width: max-content; min-width: 100%; } code { white-space: pre; }"
        return """
        :root { color-scheme: light dark; }
        html, body { background: transparent; margin: 0; }
        body {
          font: \(size)px/\(lineHeight)px \(font)ui-monospace, "SF Mono", Menlo, monospace;
          color: rgba(0, 0, 0, 0.86);
          -webkit-font-smoothing: antialiased;
          tab-size: \(settings.tabWidth);
          padding: \(topPadding)px 0 48px;
        }
        .r { display: flex; min-height: \(lineHeight)px; }
        /* Old and new line numbers, then the sign: not part of a selection, so
           copied lines are just the code. */
        .r > i, .r > b, .h > i, .h > b { flex: none; font-style: normal; font-weight: normal; -webkit-user-select: none; }
        /* In the font and size of the editor's line numbers. */
        .r > i, .h > i {
          min-width: calc(var(--digits, 3) * 1ch); padding-left: 10px; text-align: right; color: #9A9AA0;
          font-family: -apple-system, sans-serif; font-variant-numeric: tabular-nums;
          font-size: \(max(size - 2, 8))px;
        }
        .r > b, .h > b { width: 3ch; text-align: center; }
        code { flex: 1; font: inherit; padding-right: 32px; }
        \(wrapping)
        /* Side by side: each row is a line of the old text beside a line of the
           new. Long lines always wrap; half the width is little to scroll in. */
        .diff.split { width: 100%; min-width: 0; }
        .split .r { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); }
        .h { display: flex; min-width: 0; min-height: \(lineHeight)px; }
        .h + .h { border-left: 1px solid rgba(128, 128, 128, 0.22); }
        .h.e { background: rgba(128, 128, 128, 0.07); }
        .split code { white-space: pre-wrap; overflow-wrap: anywhere; min-width: 0; padding-right: 12px; }
        /* What differs within a line from the line it replaced. */
        u { text-decoration: none; border-radius: 2px; }
        .d u { background: rgba(255, 59, 48, 0.24); }
        .a u { background: rgba(52, 199, 89, 0.30); }
        /* Over a change: the link that stages or unstages just that change. */
        .act {
          display: flex; justify-content: flex-end; position: sticky; left: 0;
          padding: 3px 14px 1px; font: \(max(size - 2, 9))px/1.4 -apple-system, sans-serif;
          -webkit-user-select: none;
        }
        .act a { color: #0A6CFF; text-decoration: none; cursor: pointer; }
        .act a:hover { text-decoration: underline; }
        .a { background: rgba(52, 199, 89, 0.16); }
        .a > b { color: #248A3D; }
        .d { background: rgba(255, 59, 48, 0.13); }
        .d > b { color: #D70015; }
        summary {
          list-style: none; cursor: pointer; -webkit-user-select: none;
          margin: 4px 0; padding: 2px 16px;
          font: \(max(size - 2, 9))px/\(lineHeight)px -apple-system, sans-serif;
          color: rgba(0, 0, 0, 0.5); background: rgba(128, 128, 128, 0.10);
          position: sticky; left: 0;
        }
        summary::-webkit-details-marker { display: none; }
        summary::before { content: "⋯  "; }
        summary:hover { background: rgba(128, 128, 128, 0.18); }
        details[open] > summary { display: none; }
        .note { margin: 0; padding: 12px 24px; font: \(size + 1)px/1.6 -apple-system, sans-serif; color: rgba(0, 0, 0, 0.5); }
        /* No scroll bar, like the rest of Silica. */
        ::-webkit-scrollbar { display: none; }
        ::selection { background: rgba(64, 120, 242, 0.25); }
        \(tokens.light)
        @media (prefers-color-scheme: dark) {
          body { color: rgba(255, 255, 255, 0.88); }
          .r > i, .h > i { color: #9C9CA2; }
          .d u { background: rgba(255, 69, 58, 0.34); }
          .a u { background: rgba(48, 209, 88, 0.34); }
          .act a { color: #4C9BFF; }
          .a { background: rgba(48, 209, 88, 0.18); }
          .a > b { color: #30D158; }
          .d { background: rgba(255, 69, 58, 0.18); }
          .d > b { color: #FF6961; }
          summary, .note { color: rgba(255, 255, 255, 0.5); }
          \(tokens.dark)
        }
        """
    }
}

/// Hosts a tab's changes in the editor card.
struct GitDiffHost: NSViewRepresentable {
    let preview: GitDiffPreview

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if preview.webView.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            attach(to: container)
        }
    }

    private func attach(to container: NSView) {
        let webView = preview.webView
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        // The keyboard isn't taken unless it was asked for: the changes often
        // open from the Changes list, which needs it to go on to the next file
        // with the arrow keys.
        guard preview.wantsFocus else { return }
        preview.wantsFocus = false
        DispatchQueue.main.async {
            webView.window?.makeFirstResponder(webView)
        }
    }
}
