import AppKit
import SwiftUI

/// Owns an NSTextView on a buffer's text. Kept alive with its tab so undo history,
/// selection and scroll position survive switching tabs. A file open in several
/// panes has one of these for each, all on the same text: an edit in one shows in
/// the others, and they share one undo history.
final class TextController: NSObject, NSTextViewDelegate {
    /// What goes in the editor card: the scroll view, with the minimap beside it.
    let view: EditorContainerView
    let scrollView: NSScrollView
    let textView: EditorTextView
    weak var buffer: EditorBuffer?
    /// What the editors on one text have between them.
    private let shared: SharedText
    /// The editor the file was opened with, which the others were made from.
    private let isFirst: Bool
    private var lineNumbers: LineNumberRulerView?
    private var minimap: MinimapView!

    private final class SharedText {
        /// One history for the text, whichever editor an edit was made in. Without
        /// it each text view would use its window's, which every file there shares.
        let undoManager = UndoManager()
        /// Colors the text, which all the editors show.
        var highlighter: SyntaxHighlighter?
        let editors = NSHashTable<TextController>.weakObjects()
    }

    init(text: String, language: SyntaxLanguage?) {
        // Built by hand: `EditorTextView.scrollableTextView()` returned a TextKit 1 view,
        // and the gutter and indent guides draw through TextKit 2.
        scrollView = EditorScrollView()
        textView = EditorTextView(usingTextLayoutManager: true)
        view = EditorContainerView(scrollView: scrollView)
        shared = SharedText()
        isFirst = true
        super.init()

        configureViews()
        textView.textColor = .labelColor
        textView.string = text
        textView.language = language
        textView.lineEnding = Self.lineEnding(of: text)
        applyParagraphStyle(for: textView.font!)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        finishSetup()

        if let language {
            setHighlighter(for: language)
        }
    }

    /// Another editor on the text of `source`, for a second pane showing the file.
    /// It starts where `source` is: same selection, same lines at the top.
    init(sharing source: TextController) {
        scrollView = EditorScrollView()
        // A second layout of the same content, which is how TextKit 2 shows one
        // text in two views.
        let layoutManager = NSTextLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.textContainer = container
        source.textView.textContentStorage?.addTextLayoutManager(layoutManager)
        textView = EditorTextView(frame: .zero, textContainer: container)
        view = EditorContainerView(scrollView: scrollView)
        shared = source.shared
        isFirst = false
        buffer = source.buffer
        super.init()

        // The text has its colors already: setting the view's text color would
        // paint over them in every editor.
        configureViews()
        textView.language = source.textView.language
        textView.lineEnding = source.textView.lineEnding
        textView.typingAttributes[.paragraphStyle] = source.textView.defaultParagraphStyle
        textView.defaultParagraphStyle = source.textView.defaultParagraphStyle
        finishSetup()
        adoptPosition(of: source)
    }

    /// The view settings every editor has, before it has its text.
    private func configureViews() {
        let contentSize = scrollView.contentSize
        textView.frame = NSRect(origin: .zero, size: contentSize)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        scrollView.documentView = textView

        scrollView.drawsBackground = false
        // Trackpad and wheel scrolling still work; the bars are just never drawn.
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false

        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        let font = Self.font(ofSize: EditorSettings.shared.fontSize)
        if isFirst {
            textView.font = font
        } else {
            // The text has the font already; what's typed here takes it too.
            textView.typingAttributes[.font] = font
        }
        textView.textContainerInset = NSSize(width: 8, height: 12)
    }

    /// The gutter, the minimap and what the editor listens for, once it has its text.
    private func finishSetup() {
        shared.editors.add(self)
        textView.delegate = self
        textView.isCovered = { [weak view] point in
            guard let view else { return false }
            return view.arrowCursorRect.contains(view.convert(point, from: nil))
        }

        let ruler = LineNumberRulerView(textView: textView, scrollView: scrollView, editorFontSize: EditorSettings.shared.fontSize)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = EditorSettings.shared.showsLineNumbers
        lineNumbers = ruler

        minimap = MinimapView(controller: self)
        view.minimap = minimap
        view.showsMinimap = EditorSettings.shared.showsMinimap

        applyWrapping()

        NotificationCenter.default.addObserver(
            self, selector: #selector(fontSizeDidChange),
            name: .editorFontSizeDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyWrapping),
            name: .editorWrapDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsDidChange),
            name: .editorSettingsDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(syntaxThemeDidChange),
            name: .syntaxThemeDidChange, object: nil
        )
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(updateGutterMask),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
        if let storage = textView.textStorage {
            // Before the storage fixes attributes, which widens what it reports as
            // edited to whole paragraphs: here it's still the characters that changed.
            NotificationCenter.default.addObserver(
                self, selector: #selector(storageWillProcessEditing),
                name: NSTextStorage.willProcessEditingNotification, object: storage
            )
        }
    }

    /// Colors the text for `language`, in every editor on it.
    private func setHighlighter(for language: SyntaxLanguage) {
        let highlighter = SyntaxHighlighter(textView: textView, language: language)
        // The text being composed may be in another pane's editor.
        highlighter.isComposing = { [weak shared] in
            shared?.editors.allObjects.contains { $0.textView.hasMarkedText() } ?? false
        }
        shared.highlighter = highlighter
        highlighter.highlightNow()
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        shared.undoManager
    }

    /// `\r\n` if the file's first line break is one, else `\n` (or `\r` for old Mac files).
    private static func lineEnding(of text: String) -> String {
        let string = text as NSString
        let newline = string.range(of: "\n")
        if newline.location != NSNotFound {
            return newline.location > 0 && string.character(at: newline.location - 1) == 0x0D ? "\r\n" : "\n"
        }
        return string.range(of: "\r").location != NSNotFound ? "\r" : "\n"
    }

    var lineEnding: String { textView.lineEnding }

    /// Switches highlighting and comment markers, e.g. after a rename changes the extension.
    func setLanguage(_ language: SyntaxLanguage?) {
        guard language != textView.language else { return }
        for editor in shared.editors.allObjects { editor.textView.language = language }
        if let language {
            setHighlighter(for: language)
        } else {
            shared.highlighter = nil
            if let storage = textView.textStorage {
                storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: storage.length))
            }
        }
    }

    // MARK: Wrapping

    /// Wraps lines to the view's width, or lets them run on and scroll sideways.
    @objc private func applyWrapping() {
        // The gutter floats over the scrolling area, so it isn't counted out of contentSize.
        let gutter = scrollView.rulersVisible ? (lineNumbers?.ruleThickness ?? 0) : 0
        let width = max(0, scrollView.contentSize.width - gutter)
        if EditorSettings.shared.wrapsLines {
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.textContainer?.widthTracksTextView = true
            textView.frame.size.width = width
            textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            // Back to the left edge if the view had scrolled sideways. (The text view's
            // own x = 0, which sits right of the gutter.)
            textView.scroll(NSPoint(x: 0, y: textView.visibleRect.minY))
        } else {
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = []
        }
        textView.sizeToFit()
        textView.needsDisplay = true
        lineNumbers?.setNeedsRedraw()
        // Keep the cursor in view; the layout under it just changed.
        if textView.window != nil {
            DispatchQueue.main.async { [textView] in
                textView.scrollRangeToVisible(textView.selectedRange())
            }
        }
    }

    /// The line-number gutter floats over the left edge of the scrolling area, so text
    /// scrolled sideways (wrapping off) would show through it; hide that strip.
    @objc private func updateGutterMask() {
        let gutter = scrollView.rulersVisible ? (lineNumbers?.ruleThickness ?? 0) : 0
        textView.maskOutGutter(startingAt: scrollView.contentView.bounds.minX + gutter)
    }

    // MARK: Restoring position

    /// A top line to scroll to once the view is on screen (from a restored session).
    private var pendingTopLine: Int?
    /// The top line when the view last left the screen (another tab was shown).
    private var lastTopLine: Int?

    /// Starts where another editor on the text is: its selection, and its lines at
    /// the top once this one is shown.
    func adoptPosition(of other: TextController) {
        guard other !== self else { return }
        textView.setSelectedRange(other.textView.selectedRange())
        pendingTopLine = other.savedTopLine
    }

    /// Puts back a saved cursor and scroll position; the scroll waits until the view
    /// is shown.
    func restorePosition(cursor: Int?, topLine: Int?) {
        if let cursor {
            let length = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: min(max(cursor, 0), length), length: 0))
        }
        pendingTopLine = topLine
    }

    /// Called when the editor appears in the card.
    func didAppear() {
        guard let line = pendingTopLine else { return }
        pendingTopLine = nil
        scroll(toLine: line)
    }

    /// Called just before another tab's editor replaces this one.
    func willDisappear() {
        lastTopLine = topVisibleLine()
    }

    /// The top line to save, whether or not the editor is on screen.
    var savedTopLine: Int {
        if let pendingTopLine { return pendingTopLine }
        if scrollView.window == nil { return lastTopLine ?? 1 }
        return topVisibleLine()
    }

    var cursorLocation: Int {
        textView.selectedRange().location
    }

    // MARK: Navigation

    /// Moves the cursor to the start of the 1-based `line`.
    func goToLine(_ line: Int) {
        guard let lineNumbers else { return }
        textView.placeCursor(at: lineNumbers.offset(ofLine: line))
        focus()
    }

    /// Selects `range` (a search match) and scrolls to it.
    func reveal(_ range: NSRange) {
        textView.reveal(range)
        focus()
    }

    var lineCount: Int { lineNumbers?.lineCount ?? 1 }

    /// The 1-based line containing the UTF-16 `offset`.
    func lineNumber(at offset: Int) -> Int { lineNumbers?.lineNumber(at: offset) ?? 1 }

    /// Where the 1-based `line` starts.
    func offset(ofLine line: Int) -> Int { lineNumbers?.offset(ofLine: line) ?? 0 }

    // MARK: Scrolling (for the minimap)

    var scrollY: CGFloat { scrollView.contentView.bounds.minY }

    var maxScrollY: CGFloat {
        max(0, textView.frame.height - scrollView.contentView.bounds.height)
    }

    /// 0 at the top, 1 scrolled to the bottom.
    var scrollFraction: CGFloat {
        maxScrollY > 0 ? min(max(scrollY / maxScrollY, 0), 1) : 0
    }

    /// Scrolls vertically, keeping any sideways scroll.
    func setScrollY(_ y: CGFloat) {
        let clipView = scrollView.contentView
        clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: min(max(y, 0), maxScrollY)))
        scrollView.reflectScrolledClipView(clipView)
    }

    /// The 1-based lines at least partly on screen.
    func visibleLineRange() -> ClosedRange<Int> {
        guard let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager else { return 1...1 }
        let origin = textView.textContainerOrigin
        let visible = textView.visibleRect
        let documentStart = layoutManager.documentRange.location
        func line(atY y: CGFloat) -> Int? {
            guard let fragment = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: max(0, y - origin.y))) else { return nil }
            // A layout fragment is one paragraph, so one logical line however it wraps.
            return lineNumber(at: contentManager.offset(from: documentStart, to: fragment.rangeInElement.location))
        }
        let first = line(atY: visible.minY + 1) ?? 1
        let last = line(atY: visible.maxY - 1) ?? lineCount
        return first...max(first, last)
    }

    /// Scrolls so the 1-based `line` is in the middle of the editor.
    func center(line: Int) {
        guard let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let location = contentManager.location(layoutManager.documentRange.location, offsetBy: offset(ofLine: line)),
              let range = NSTextRange(location: layoutManager.documentRange.location, end: location) else { return }
        layoutManager.ensureLayout(for: range)
        guard let fragment = layoutManager.textLayoutFragment(for: location) else { return }
        let frame = fragment.layoutFragmentFrame
        let midY = frame.minY + textView.textContainerOrigin.y + min(frame.height, 20) / 2
        setScrollY(midY - scrollView.contentView.bounds.height / 2)
    }

    private func focus() {
        textView.window?.makeFirstResponder(textView)
    }

    // MARK: Status

    private var isStatusUpdateScheduled = false

    /// Coalesced, so a burst of edits or selection changes updates the status bar once.
    private func scheduleStatusUpdate() {
        guard !isStatusUpdateScheduled else { return }
        isStatusUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.isStatusUpdateScheduled = false
            self?.updateStatus()
        }
    }

    func updateStatus() {
        // The status bar shows the editor of the pane in use.
        guard let buffer, let lineNumbers, buffer.textController === self else { return }
        let selection = textView.selectedRange()
        let status = EditorBuffer.CursorStatus(
            line: lineNumbers.lineNumber(at: selection.location),
            column: textView.visualColumn(at: selection.location) + 1,
            selectedLength: selection.length
        )
        if buffer.cursor != status { buffer.cursor = status }
        let indentation = textView.indentation
        if buffer.indentation != indentation { buffer.indentation = indentation }
    }

    private static func font(ofSize size: CGFloat) -> NSFont {
        EditorSettings.shared.editorFont(ofSize: size)
    }

    private static let lineHeightMultiple: CGFloat = 1.15

    /// How tall a line of text in `font` is in the editor, for views that show
    /// code beside it.
    static func lineHeight(of font: NSFont) -> CGFloat {
        NSLayoutManager().defaultLineHeight(for: font) * lineHeightMultiple
    }

    /// Line spacing, plus tab stops every `EditorTextView.tabWidth` columns of the
    /// monospaced font, so tabs line up with space indentation and the indent guides.
    private func applyParagraphStyle(for font: NSFont) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = Self.lineHeightMultiple
        paragraph.tabStops = []
        paragraph.defaultTabInterval = (" " as NSString).size(withAttributes: [.font: font]).width
            * CGFloat(EditorTextView.tabWidth)
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes[.paragraphStyle] = paragraph
        if let storage = textView.textStorage {
            // Directly on the storage, so it isn't an undoable edit.
            storage.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: storage.length))
        }
    }

    /// Restyles the text in place; this doesn't touch undo or mark the file dirty.
    @objc private func fontSizeDidChange() {
        let size = EditorSettings.shared.fontSize
        let font = Self.font(ofSize: size)
        textView.font = font
        textView.typingAttributes[.font] = font
        applyParagraphStyle(for: font)
        lineNumbers?.setEditorFontSize(size)
        textView.needsDisplay = true
    }

    /// Font family, tab width, line numbers or indent guides changed in Settings.
    @objc private func syntaxThemeDidChange() {
        // Once for the text, not once for each editor on it.
        if isFirst { shared.highlighter?.highlightNow() }
    }

    @objc private func settingsDidChange() {
        let settings = EditorSettings.shared
        fontSizeDidChange()
        textView.showsIndentGuides = settings.showsIndentGuides
        // A new tab width changes the width of tab indentation.
        textView.redetectIndentation()
        if scrollView.rulersVisible != settings.showsLineNumbers {
            scrollView.rulersVisible = settings.showsLineNumbers
            applyWrapping()
        }
        if view.showsMinimap != settings.showsMinimap {
            view.showsMinimap = settings.showsMinimap
            // The text's width changed; rewrap and keep the cursor in view.
            view.layoutSubtreeIfNeeded()
            applyWrapping()
        }
        minimap.needsDisplay = true
        updateGutterMask()
        scheduleStatusUpdate()
    }

    func textDidChange(_ notification: Notification) {
        isMakingEdit = false
        shared.highlighter?.textDidChange()
        // The file's other editors have the new text too.
        for editor in shared.editors.allObjects {
            editor.lineNumbers?.textDidChange()
            if editor !== self { editor.textView.needsDisplay = true }
        }
        buffer?.textRevision &+= 1
        if !isReplacingText, buffer?.isDirty == false {
            buffer?.isDirty = true
        }
        buffer?.textDidChange()
        scheduleStatusUpdate()
    }

    // MARK: Edits made in another editor

    /// Whether the edit being made to the text is this editor's own.
    private var isMakingEdit = false
    /// Where the selection goes once an edit made elsewhere is through.
    private var movedSelection: NSRange?

    func textView(_ textView: NSTextView, shouldChangeTextInRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        isMakingEdit = true
        // An edit is over within the event that makes it, whether or not it got as
        // far as `textDidChange`.
        DispatchQueue.main.async { [weak self] in self?.isMakingEdit = false }
        return true
    }

    /// The text changed under this editor: another pane's editor made the edit. The
    /// selection here stays on the text it was on, moving with what was put in or
    /// taken out before it.
    @objc private func storageWillProcessEditing(_ notification: Notification) {
        guard !isMakingEdit, let storage = notification.object as? NSTextStorage,
              storage.editedMask.contains(.editedCharacters) else { return }
        let edited = storage.editedRange
        let before = NSRange(location: edited.location, length: edited.length - storage.changeInLength)
        func moved(_ position: Int) -> Int {
            if position <= before.location { return position }
            if position >= NSMaxRange(before) { return position + storage.changeInLength }
            return NSMaxRange(edited)
        }
        let selection = movedSelection ?? textView.selectedRange()
        let start = moved(selection.location)
        let end = moved(NSMaxRange(selection))
        let isFirstEdit = movedSelection == nil
        movedSelection = NSRange(location: start, length: max(end - start, 0))
        guard isFirstEdit else { return }
        // After the edit, which the text view isn't ready to be asked about yet.
        DispatchQueue.main.async { [weak self] in
            guard let self, let selection = self.movedSelection else { return }
            self.movedSelection = nil
            let length = (self.textView.string as NSString).length
            let location = min(selection.location, length)
            let range = NSRange(location: location, length: min(selection.length, length - location))
            if self.textView.selectedRange() != range { self.textView.setSelectedRange(range) }
        }
    }

    private var isReplacingText = false

    /// Swaps in new text (the file as changed on disk) as one undoable edit that
    /// leaves the buffer clean. Only the differing middle is replaced, so the
    /// selection and scroll position stay put when the change is elsewhere.
    func replaceText(with newText: String) {
        let old = textView.string as NSString
        let new = newText as NSString
        let shared = min(old.length, new.length)
        var prefix = 0
        while prefix < shared, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        // Don't cut a surrogate pair in half.
        if prefix > 0, prefix < shared, UTF16.isLeadSurrogate(old.character(at: prefix - 1)) { prefix -= 1 }
        var suffix = 0
        while suffix < shared - prefix,
              old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
        if suffix > 0, suffix < shared - prefix, UTF16.isTrailSurrogate(old.character(at: old.length - suffix)) { suffix -= 1 }

        let range = NSRange(location: prefix, length: old.length - prefix - suffix)
        let replacement = new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix))
        guard range.length > 0 || !replacement.isEmpty else { return }

        isReplacingText = true
        defer { isReplacingText = false }
        for editor in self.shared.editors.allObjects { editor.textView.redetectIndentation() }
        if textView.shouldChangeText(in: range, replacementString: replacement) {
            textView.replaceCharacters(in: range, with: replacement)
            textView.didChangeText()
            textView.undoManager?.setActionName("Revert")
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        lineNumbers?.setNeedsRedraw()
        scheduleStatusUpdate()
    }

    // MARK: Lines (shared with the preview)

    /// The 1-based line shown at the top of the editor.
    func topVisibleLine() -> Int {
        guard let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager else { return 1 }
        // A point into the view, so pixel rounding at a line boundary doesn't pick the
        // line above.
        let y = max(0, textView.visibleRect.minY - textView.textContainerOrigin.y + 1)
        guard let fragment = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: y)) else { return 1 }
        let offset = contentManager.offset(from: layoutManager.documentRange.location, to: fragment.rangeInElement.location)
        let text = textView.string as NSString
        var line = 1
        var index = 0
        while index < min(offset, text.length) {
            let range = text.lineRange(for: NSRange(location: index, length: 0))
            guard NSMaxRange(range) <= offset else { break }
            line += 1
            index = NSMaxRange(range)
        }
        return line
    }

    /// Scrolls so `line` (1-based) is at the top.
    func scroll(toLine line: Int) {
        let text = textView.string as NSString
        var offset = 0
        var current = 1
        while current < line, offset < text.length {
            offset = NSMaxRange(text.lineRange(for: NSRange(location: offset, length: 0)))
            current += 1
        }
        guard let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let location = contentManager.location(layoutManager.documentRange.location, offsetBy: offset),
              let range = NSTextRange(location: layoutManager.documentRange.location, end: location) else { return }
        layoutManager.ensureLayout(for: range)
        if let fragment = layoutManager.textLayoutFragment(for: location) {
            // Fragment frames don't include the text container's inset; the view does.
            // Matches `topVisibleLine()`, so saving and restoring doesn't drift.
            textView.scroll(NSPoint(x: 0, y: fragment.layoutFragmentFrame.minY + textView.textContainerOrigin.y))
        }
    }
}

/// Hosts whichever buffer's scroll view is active.
struct TextViewHost: NSViewRepresentable {
    let controller: TextController
    /// Whether the editor takes the keyboard when it's put in the card. Not in a
    /// pane that isn't the focused one: its tabs change without the cursor leaving
    /// the pane being typed in.
    var takesFocus = true
    /// Whether this card is still the one showing the editor. A pane on its way
    /// out can be updated once more with the editor it had, after the pane that
    /// took the tab over has it: it mustn't take the view back.
    var isCurrent: () -> Bool = { true }
    /// Where something floats over the text (the status bar), in the card's own
    /// space: the pointer stays an arrow there, as over any button.
    var arrowCursorRect = CGRect.zero

    func makeNSView(context: Context) -> HostView {
        HostView()
    }

    func updateNSView(_ nsView: HostView, context: Context) {
        guard isCurrent() else { return }
        nsView.show(controller, takesFocus: takesFocus)
        controller.view.arrowCursorRect = arrowCursorRect
    }

    final class HostView: NSView {
        private weak var current: TextController?

        func show(_ controller: TextController, takesFocus: Bool) {
            // A tab moved to another pane takes its view along, and brings it back
            // if it returns: the view being elsewhere means it has to be put here.
            guard current !== controller || controller.view.superview !== self else { return }
            // Only a view that's still here is this host's to take out.
            if let current, current !== controller, current.view.superview === self {
                current.willDisappear()
                current.view.removeFromSuperview()
            }
            let editorView = controller.view
            editorView.frame = bounds
            editorView.autoresizingMask = [.width, .height]
            addSubview(editorView)
            current = controller
            DispatchQueue.main.async { [weak self] in
                if takesFocus { self?.focus(controller) }
                controller.didAppear()
            }
        }

        /// The editor that takes the keyboard once this view is in a window: a new
        /// pane's host is asked to show its editor before it gets there.
        private weak var awaitingFocus: TextController?

        private func focus(_ controller: TextController) {
            if let window {
                window.makeFirstResponder(controller.textView)
            } else {
                awaitingFocus = controller
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let controller = awaitingFocus else { return }
            awaitingFocus = nil
            // Only if it's still the editor this host shows.
            if controller === current, controller.view.superview === self {
                window.makeFirstResponder(controller.textView)
            }
        }
    }
}

/// The editor's scroll view. The find bar floats over the top of the text and insets
/// it, but AppKit leaves the scroll position alone, so opening the bar at the top of a
/// file would cover the first line. Text within a bar's height of the top moves with
/// the bar instead; further down, the view stays where it is.
final class EditorScrollView: NSScrollView {
    /// Runs `change`, which shows, hides or resizes the find bar.
    private func keepingTopLinesInView(_ change: () -> Void) {
        let oldInset = contentView.contentInsets.top
        let distanceFromTop = contentView.bounds.minY + oldInset
        change()
        let newInset = contentView.contentInsets.top
        guard newInset != oldInset, distanceFromTop < max(oldInset, newInset) else { return }
        let y = distanceFromTop - newInset
        guard contentView.bounds.minY != y else { return }
        contentView.scroll(to: NSPoint(x: contentView.bounds.minX, y: y))
        reflectScrolledClipView(contentView)
    }

    override var isFindBarVisible: Bool {
        get { super.isFindBarVisible }
        set { keepingTopLinesInView { super.isFindBarVisible = newValue } }
    }

    /// Showing the replace field makes the bar taller.
    override func findBarViewDidChangeHeight() {
        keepingTopLinesInView { super.findBarViewDidChangeHeight() }
    }
}

/// The scroll view, and the minimap in a strip down its right side when shown.
/// The text wraps short of the minimap rather than running under it.
final class EditorContainerView: NSView {
    let scrollView: NSScrollView

    var minimap: MinimapView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let minimap { addSubview(minimap) }
            needsLayout = true
        }
    }

    var showsMinimap = true {
        didSet { needsLayout = true }
    }

    /// Where a SwiftUI view floats over the text, from the top left of this view.
    /// The text view under it would otherwise show its I-beam there.
    var arrowCursorRect = CGRect.zero

    init(scrollView: NSScrollView) {
        self.scrollView = scrollView
        super.init(frame: .zero)
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let minimapWidth = showsMinimap && minimap != nil ? MinimapView.width : 0
        scrollView.frame = NSRect(x: 0, y: 0, width: max(0, bounds.width - minimapWidth), height: bounds.height)
        minimap?.isHidden = minimapWidth == 0
        minimap?.frame = NSRect(x: bounds.width - minimapWidth, y: 0, width: minimapWidth, height: bounds.height)
    }
}
