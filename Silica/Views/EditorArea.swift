import AVKit
import PDFKit
import SwiftUI

struct EditorArea: View {
    let workspace: WorkspaceModel

    @AppStorage("terminalHeight") private var terminalHeight: Double = 260
    @State private var dragStartTerminalHeight: Double?
    /// Height the editor's panes and the terminal card share, which limits the terminal's.
    @State private var cardsHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            // Each pane has its tab row over its card. The top row of them is the
            // title bar row, which the tabs share with the traffic lights.
            EditorPanes(workspace: workspace)
            if workspace.isTerminalVisible, let terminal = workspace.terminal {
                // The terminal's card sits under the editor's, the gap between
                // them being the handle that resizes it.
                VStack(spacing: 0) {
                    terminalResizeHandle
                    TerminalCard(session: terminal, workspace: workspace)
                        .frame(height: clampedTerminalHeight)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            cardsHeight = size.height
            workspace.editorAreaSize = size
        }
        .padding(.leading, workspace.isSidebarVisible ? 0 : WorkspaceLayout.cardInset)
        .padding([.trailing, .bottom], WorkspaceLayout.cardInset)
        .frame(minWidth: WorkspaceLayout.editorMinWidth)
    }

    /// The tallest the terminal can be: every pane keeps its tab row and a few
    /// lines however small the window gets.
    private var tallestTerminal: CGFloat {
        let range = WorkspaceLayout.terminalHeightRange
        let panes = workspace.layout.minimumSize(spacing: WorkspaceLayout.paneSpacing, minimum: WorkspaceLayout.paneMinimumSize)
        return min(max(cardsHeight - WorkspaceLayout.cardInset - panes.height, range.lowerBound), range.upperBound)
    }

    /// The stored height, kept within what the window has room for.
    private var clampedTerminalHeight: CGFloat {
        min(max(terminalHeight, WorkspaceLayout.terminalHeightRange.lowerBound), tallestTerminal)
    }

    /// Invisible strip between the two cards that resizes the terminal.
    private var terminalResizeHandle: some View {
        Color.clear
            .frame(height: WorkspaceLayout.cardInset)
            .contentShape(.rect)
            .pointerStyle(.frameResize(position: .top))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        // From the height on screen, which the window may have limited.
                        let start = dragStartTerminalHeight ?? clampedTerminalHeight
                        dragStartTerminalHeight = start
                        terminalHeight = min(max(start - value.translation.height, WorkspaceLayout.terminalHeightRange.lowerBound), tallestTerminal)
                    }
                    .onEnded { _ in dragStartTerminalHeight = nil }
            )
    }
}

// MARK: - Panes

/// The editor's panes, side by side and one above another as the layout has them,
/// with the dividers that resize them. Each pane keeps its views while the others
/// come, go and change size around it.
private struct EditorPanes: View {
    let workspace: WorkspaceModel

    /// The divider being dragged, and the share its first side had when the drag began.
    @State private var resizing: Resize?

    private struct Resize {
        let split: PaneLayout.SplitID
        let fraction: Double
    }

    /// The panes' own space, in which a tab dragged out of its bar is followed.
    static let space: NamedCoordinateSpace = .named("EditorPanes")
    /// How much of a tab row and of the card above it resizes the two.
    private static let rowHandleHeight: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            let arrangement = workspace.layout.arrangement(
                in: proxy.size, spacing: WorkspaceLayout.paneSpacing, minimum: WorkspaceLayout.paneMinimumSize
            )
            ZStack(alignment: .topLeading) {
                ForEach(workspace.layout.panes, id: \.self) { pane in
                    let frame = arrangement.panes[pane] ?? .zero
                    EditorPane(
                        pane: pane, workspace: workspace,
                        isTopLeading: frame.minY < 1 && frame.minX < 1,
                        isTopTrailing: frame.minY < 1 && frame.maxX > proxy.size.width - 1,
                        paneAt: { point in arrangement.panes.first { $0.value.contains(point) }?.key }
                    )
                    // The transition places the pane as well as bringing it in and out:
                    // it can only change the size of what it's given whole.
                    .transition(.modifier(
                        active: PanePlacement(frame: frame, edge: outerEdge(of: pane), presence: 0),
                        identity: PanePlacement(frame: frame, edge: outerEdge(of: pane), presence: 1)
                    ))
                }
                ForEach(arrangement.dividers) { divider in
                    handle(for: divider)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .coordinateSpace(Self.space)
        }
    }

    /// The edge of a pane that's away from the other side of its split: the one a
    /// new pane grows from as the pane it divided makes room, and the one a closing
    /// pane shrinks to as what was beside it takes its room.
    private func outerEdge(of pane: PaneLayout.PaneID) -> Edge? {
        guard let side = workspace.layout.side(of: pane) else { return nil }
        switch side.axis {
        case .horizontal: return side.isSecond ? .trailing : .leading
        case .vertical: return side.isSecond ? .bottom : .top
        }
    }

    /// Invisible strip between two panes that resizes them: the gap between two
    /// side by side, and the edge where the lower one's tab row meets the card
    /// above it. A double click evens the two out.
    private func handle(for divider: PaneLayout.Arrangement.Divider) -> some View {
        let isSideBySide = divider.axis == .horizontal
        let frame = isSideBySide ? divider.frame : divider.frame.insetBy(dx: 0, dy: -Self.rowHandleHeight / 2)
        let holder = "divider-\(divider.id)"
        return Color.clear
            .contentShape(.rect)
            .frame(width: frame.width, height: frame.height)
            .pointerStyle(.frameResize(position: isSideBySide ? .trailing : .top))
            .onTapGesture(count: 2) {
                withAnimation(WorkspaceLayout.paneAnimation) { workspace.setSplitFraction(0.5, of: divider.id) }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: Self.space)
                    .onChanged { value in
                        // From the share on screen, which the panes' minimums may have limited.
                        let start = resizing?.split == divider.id ? resizing?.fraction ?? divider.fraction : divider.fraction
                        if resizing?.split != divider.id { resizing = Resize(split: divider.id, fraction: start) }
                        guard divider.span > 0 else { return }
                        let travel = isSideBySide ? value.translation.width : value.translation.height
                        let fraction = start + Double(travel / divider.span)
                        workspace.setSplitFraction(
                            min(max(fraction, divider.fractions.lowerBound), divider.fractions.upperBound), of: divider.id
                        )
                    }
                    .onEnded { _ in resizing = nil }
            )
            // The part of it between two tab rows is in the title bar.
            .onHover { workspace.setWindowHeld($0, by: holder) }
            .onDisappear { workspace.setWindowHeld(false, by: holder) }
            .offset(x: frame.minX, y: frame.minY)
    }
}

/// Puts a pane where the layout has it, and has it grow from nothing when it's
/// opened and shrink back to nothing when it's closed, against the edge the panes
/// beside it don't reach: the pane changes size with them, rather than appear where
/// they left room.
private struct PanePlacement: ViewModifier, Animatable {
    let frame: CGRect
    /// The edge the pane keeps to; `nil` for the only pane, which has no room to grow into.
    let edge: Edge?
    /// How much of its size the pane has: 0 before it's opened and once it's closed,
    /// 1 while it's there. The animation runs it through the values between, and
    /// the pane is laid out afresh for each.
    var presence: CGFloat

    var animatableData: CGFloat {
        get { presence }
        set { presence = newValue }
    }

    func body(content: Content) -> some View {
        let isSideways = edge == .leading || edge == .trailing
        let isUpright = edge == .top || edge == .bottom
        content
            .frame(
                width: isSideways ? frame.width * presence : frame.width,
                height: isUpright ? frame.height * presence : frame.height
            )
            // A tab row doesn't get narrower than its buttons, or lower than its
            // height: while the pane is smaller than that, it's cut off at the pane
            // instead of lying over the next one. With room left for the card's shadow.
            .clipShape(Rectangle().inset(by: -Self.shadowRoom))
            .frame(width: frame.width, height: frame.height, alignment: alignment)
            .offset(x: frame.minX, y: frame.minY)
    }

    private static let shadowRoom: CGFloat = 12

    private var alignment: Alignment {
        switch edge {
        case .leading: .leading
        case .trailing: .trailing
        case .top: .top
        case .bottom: .bottom
        case nil: .center
        }
    }
}

/// One pane: its tab row, and under it a card with the file its active tab shows.
private struct EditorPane: View {
    let pane: PaneLayout.PaneID
    let workspace: WorkspaceModel
    /// Whether the pane is in the window's top corner on that side, where its tab
    /// row has the traffic lights or the terminal's button for company.
    let isTopLeading: Bool
    let isTopTrailing: Bool
    /// The pane at a point in the panes' space, for a tab dragged over another pane.
    let paneAt: (CGPoint) -> PaneLayout.PaneID?

    var body: some View {
        let buffer = workspace.buffer(in: pane)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if isTopLeading, !workspace.isSidebarVisible {
                    Color.clear.frame(width: WorkspaceLayout.trafficLightsWidth - WorkspaceLayout.cardInset)
                    SidebarToggleButton(workspace: workspace)
                }
                EditorTabBar(workspace: workspace, pane: pane, paneAt: paneAt)
                Spacer(minLength: 0)
                if let buffer, workspace.showsChanges(buffer, in: pane) || workspace.hasChanges(buffer) {
                    ChangesToggle(buffer: buffer, workspace: workspace, pane: pane)
                }
                // The changes cover the source and the preview alike.
                if let buffer, let format = buffer.previewFormat, !workspace.showsChanges(buffer, in: pane) {
                    PreviewModeToggle(buffer: buffer, format: format, workspace: workspace, pane: pane)
                }
                // Last, so it stays in place whatever the tab has beside it.
                if isTopTrailing {
                    TerminalToggleButton(workspace: workspace)
                }
            }
            .padding(.trailing, 4)
            .frame(height: WorkspaceLayout.titleBarHeight)

            Group {
                if let buffer {
                    BufferView(buffer: buffer, workspace: workspace, pane: pane)
                } else if !workspace.layout.contains(pane) {
                    // Closed, and shrinking out of the layout: its tabs have gone to
                    // the pane beside it, and it isn't an empty pane to be filled.
                    Color.clear
                } else if workspace.layout.isSplit {
                    EmptyPaneView(pane: pane, workspace: workspace)
                } else {
                    EmptyEditorView(workspace: workspace)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                // Where a tab being dragged from another pane would land.
                if workspace.tabDropPane == pane {
                    Color.accentColor.opacity(0.14).allowsHitTesting(false)
                }
            }
            // Liquid Glass card, or a bordered one with the glass effect off. Corners
            // next to the window's corners follow its radius minus the inset; the
            // others (under the tab bar, beside another pane) fall back to the minimum.
            .workspaceCard()
        }
        .background(
            PaneClickTracker {
                // A click in Quick Open, which lies over the panes, isn't one in a pane.
                guard !workspace.isQuickOpenVisible else { return false }
                workspace.paneWasClicked(pane)
                return true
            } settle: {
                if workspace.focusedPane == pane { workspace.focusPaneContent() }
            }
        )
    }
}

/// Makes a pane the focused one when a click lands anywhere in it. Most of a pane
/// is an AppKit view (the editor, a preview) that takes its clicks before SwiftUI
/// sees them, so the pane watches for them.
private struct PaneClickTracker: NSViewRepresentable {
    /// Called as the click arrives, before the view under it gets it, so that what
    /// the click does (a button in the tab row, say) finds its pane focused.
    /// Returns whether the click counts.
    let clicked: () -> Bool
    /// Called after a click that left the keyboard in another pane (one on the tab
    /// row, or on a pane with nothing to type in).
    let settle: () -> Void

    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        nsView.clicked = clicked
        nsView.settle = settle
    }

    static func dismantleNSView(_ nsView: AnchorView, coordinator: ()) {
        nsView.stopWatching()
    }

    /// Marks where the pane is in its window, behind it.
    final class AnchorView: NSView {
        var clicked: () -> Bool = { false }
        var settle: () -> Void = {}

        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopWatching()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        func stopWatching() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) {
            // The monitor sees clicks before the window turns them away, so a sheet
            // or an alert has to rule them out here.
            guard let window, event.window === window, window.attachedSheet == nil, NSApp.modalWindow == nil,
                  bounds.contains(convert(event.locationInWindow, from: nil)), clicked() else { return }
            // Once the click has been through: it usually puts the keyboard in the
            // pane itself, on the editor it lands on.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                if let responder = window.firstResponder as? NSView, responder.window === window,
                   self.convert(self.bounds, to: nil).intersects(responder.convert(responder.bounds, to: nil)) { return }
                self.settle()
            }
        }
    }
}

/// What a pane with no tabs shows, while there are other panes.
private struct EmptyPaneView: View {
    let pane: PaneLayout.PaneID
    let workspace: WorkspaceModel

    var body: some View {
        ContentUnavailableView {
            Label("No File", systemImage: "rectangle.split.2x1")
        } description: {
            Text("Open a file to show it here, or drag a tab over from another pane.")
        } actions: {
            Button("Close Pane") { workspace.closePane(pane) }
                .help(KeybindSettings.shared.help("Close Pane", for: .closePane))
        }
    }
}

// MARK: - Tabs

/// One pane's tabs. A drag moves a tab along the bar or, dropped on another pane,
/// to the end of that pane's bar. A file can have a tab in several panes.
private struct EditorTabBar: View {
    let workspace: WorkspaceModel
    let pane: PaneLayout.PaneID
    /// The pane at a point in the panes' space.
    let paneAt: (CGPoint) -> PaneLayout.PaneID?

    /// Where the bar starts in the panes' space, which a drag is measured in.
    @State private var barOrigin: CGFloat = 0
    /// The tab being dragged to a new place, and how far the pointer has carried it.
    @State private var drag: TabDrag<URL>?
    /// Each tab's laid-out width, to tell which tabs a dragged one has passed.
    @State private var tabWidths: [URL: CGFloat] = [:]
    /// Width of the part of the row that shows, and how far the row is scrolled under it.
    @State private var barWidth: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0
    /// Scrolls the row during a drag; showing the active tab still goes through the reader.
    @State private var scrollPosition = ScrollPosition(idType: Never.self)
    /// How much each end of the row is faded: fully once tabs are scrolled out past it.
    @State private var edgeFades = EdgeFades()

    private static let spacing: CGFloat = 6
    private static let inset: CGFloat = 2
    private static let reorderAnimation = Animation.snappy(duration: 0.2)
    /// How far in from an end of the bar the row fades out.
    private static let fadeWidth: CGFloat = 20

    var body: some View {
        let offsets = drag?.reorder(in: layout)?.offsets ?? [:]
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: Self.spacing - 2 * Self.fadeWidth) {
                    ForEach(workspace.tabs(in: pane), id: \.self) { url in
                        let offset = offsets[url] ?? 0
                        let isDragged = drag?.tab == url
                        EditorTab(
                            url: url,
                            isActive: url == workspace.activeTab(in: pane),
                            isInFocusedPane: pane == workspace.focusedPane,
                            isDirty: workspace.buffers[url]?.isDirty == true,
                            isMissing: workspace.buffers[url]?.isMissingOnDisk == true,
                            select: { workspace.activate(url, in: pane) },
                            close: { withAnimation(.snappy) { workspace.closeTab(url, in: pane) } },
                            closeOthers: { withAnimation(.snappy) { workspace.closeOtherTabs(than: url, in: pane) } },
                            revealInTree: workspace.contains(url) ? { workspace.revealInTree(url) } : nil,
                            copyRelativePath: workspace.contains(url) ? { Finder.copyPath(workspace.relativePath(of: url)) } : nil,
                            split: { workspace.splitPane($0, from: pane, showing: url) },
                            closePane: workspace.layout.isSplit ? { workspace.closePane(pane) } : nil,
                            drag: { handleDrag($0, at: $1, of: url, proxy: proxy) }
                        )
                        // Over another pane, where dropping it would move it there.
                        .opacity(isDragged && workspace.tabDropPane != nil ? 0.4 : 1)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tabWidths[url] = $0 }
                        // Room on either side that the row scrolls into view with the tab,
                        // so that it comes to rest clear of the faded ends of the bar. The
                        // row's spacing and padding take the same room back out.
                        .padding(.horizontal, Self.fadeWidth)
                        .offset(x: offset)
                        .zIndex(isDragged ? 1 : 0)
                        // The dragged tab stays under the pointer; the others slide out of its way.
                        .animation(isDragged ? nil : Self.reorderAnimation, value: offset)
                        .id(url)
                    }
                }
                .padding(.horizontal, Self.inset - Self.fadeWidth)
                .padding(.vertical, 4)
                // The tabs sit in the title bar, where the window server moves the window
                // on any drag, whatever gesture or view is under the pointer. So the
                // window stops being movable while the pointer is over the tabs; a drag
                // on the empty part of the row still moves it, as on its background.
                .onHover { workspace.setWindowHeld($0, by: windowHolder) }
            }
            .scrollIndicators(.never)
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, offset in
                scrollOffset = offset
            }
            .onScrollGeometryChange(for: EdgeFades.self) { geometry in
                let offset = geometry.contentOffset.x
                let hiddenAfter = geometry.contentSize.width - geometry.containerSize.width - offset
                return EdgeFades(leading: offset, trailing: hiddenAfter, over: Self.fadeWidth)
            } action: { _, fades in
                edgeFades = fades
            }
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = $0 }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: EditorPanes.space).minX } action: { barOrigin = $0 }
            // A tab scrolled part of the way out fades away rather than ending in a cut.
            .mask { fadeMask }
            .background(WheelScrollsSideways())
            .background(
                MiddleClickClosesTab(tab: tab(at:)) { url in
                    withAnimation(.snappy) { workspace.closeTab(url, in: pane) }
                }
            )
            .onChange(of: workspace.activeTab(in: pane)) { _, active in
                if let active {
                    withAnimation { proxy.scrollTo(active) }
                }
            }
            // The row jumps back to its start when the bar changes width, which takes the
            // active tab out of view: resizing the window or the sidebar brings it back,
            // in step with the resize rather than animated behind it.
            .onChange(of: barWidth) {
                if drag == nil, let active = workspace.activeTab(in: pane) {
                    proxy.scrollTo(active)
                }
            }
            .onChange(of: workspace.tabs(in: pane)) { _, tabs in
                tabWidths = tabWidths.filter { tabs.contains($0.key) }
                // The dragged tab can close or be renamed mid-drag, which removes its view
                // before the gesture can end or cancel.
                if let drag, !tabs.contains(drag.tab) { endDrag() }
                // Closing the last tab leaves nothing for the pointer to move off.
                if tabs.isEmpty { workspace.setWindowHeld(false, by: windowHolder) }
            }
            .onDisappear {
                workspace.setWindowHeld(false, by: windowHolder)
                if drag != nil { workspace.tabDropPane = nil }
            }
            // A pointer resting near an end of the bar sends no events, so a timer keeps
            // the row scrolling under it for as long as the drag lasts.
            .task(id: drag?.tab) {
                guard drag != nil else { return }
                var last = Date.now
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(16))
                    let now = Date.now
                    autoscroll(elapsed: now.timeIntervalSince(last))
                    last = now
                }
            }
        }
    }

    /// Opaque across the bar, clearing towards an end that has tabs scrolled out past it.
    private var fadeMask: some View {
        HStack(spacing: 0) {
            LinearGradient(
                colors: [.black.opacity(1 - edgeFades.leading), .black],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: Self.fadeWidth)
            Color.black
            LinearGradient(
                colors: [.black, .black.opacity(1 - edgeFades.trailing)],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: Self.fadeWidth)
        }
    }

    private var windowHolder: String { "tabs-\(pane)" }

    /// The drag is over, wherever it went.
    private func endDrag() {
        drag = nil
        if workspace.tabDropPane != nil { workspace.tabDropPane = nil }
    }

    /// `point` is the pointer in the panes' space, which the drag is measured in.
    private func handleDrag(_ event: TabDragEvent, at point: CGPoint?, of url: URL, proxy: ScrollViewProxy) {
        switch event {
        case .moved(let translation, let location):
            // Along the bar, as the row's layout has it.
            let location = location - barOrigin
            // Held over another pane, the tab would move there.
            let target = point.flatMap(paneAt).flatMap { $0 == pane ? nil : $0 }
            if workspace.tabDropPane != target { workspace.tabDropPane = target }
            if let drag, drag.tab == url {
                self.drag = TabDrag(tab: url, translation: translation, location: location, startScrollOffset: drag.startScrollOffset)
            } else {
                // Dragging a tab brings it forward, as clicking it does.
                workspace.activate(url, in: pane)
                drag = TabDrag(tab: url, translation: translation, location: location, startScrollOffset: scrollOffset)
            }
        case .dropped(let translation):
            guard var dropped = drag, dropped.tab == url else { return }
            if let target = workspace.tabDropPane {
                endDrag()
                workspace.moveTab(url, from: pane, toPane: target)
                return
            }
            dropped.translation = translation
            let destination = dropped.reorder(in: layout)?.destination
            // The new order and the end of the drag go in one animation, so every tab
            // settles from where the drag left it instead of jumping to its new place.
            withAnimation(Self.reorderAnimation) {
                if let destination { workspace.moveTab(url, to: destination, in: pane) }
                drag = nil
            }
            // Its new place can reach past the end of the bar. Once the row is laid out
            // in its new order: asked in the same pass, the reader goes to where the
            // tab was, which a drag that scrolled the row has left far behind.
            DispatchQueue.main.async {
                withAnimation(Self.reorderAnimation) { proxy.scrollTo(url) }
            }
        case .cancelled:
            if drag?.tab == url {
                withAnimation(Self.reorderAnimation) { endDrag() }
            }
        }
    }

    /// The row as it's laid out now, for the drag to be worked out from.
    private var layout: TabBarLayout<URL> {
        TabBarLayout(
            tabs: workspace.tabs(in: pane), widths: tabWidths, spacing: Self.spacing, inset: Self.inset,
            barWidth: barWidth, scrollOffset: scrollOffset
        )
    }

    /// Scrolls the row while a tab is held near an end of the bar, so a tab can be
    /// taken past the ones that fit in the bar.
    private func autoscroll(elapsed: TimeInterval) {
        guard let target = drag?.autoscrollOffset(in: layout, elapsed: elapsed) else { return }
        scrollPosition.scrollTo(x: target)
        // Ahead of the scroll view reporting it, so the tab doesn't trail the row by a frame.
        scrollOffset = target
    }

    /// The tab at a horizontal position in the bar, if there's one: the gaps between
    /// tabs and the empty end of the row have none.
    private func tab(at x: CGFloat) -> URL? {
        // The tabs are out of their places during a drag.
        drag == nil ? layout.tab(at: x) : nil
    }
}

/// Lets a mouse wheel scroll the tab row. A wheel only scrolls up and down, which a
/// row that scrolls sideways ignores unless Shift is held, so while the pointer is on
/// the bar the wheel's travel reaches the row as sideways travel. Trackpads and mice
/// that scroll both ways are left as they are.
struct WheelScrollsSideways: NSViewRepresentable {
    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ nsView: AnchorView, context: Context) {}

    static func dismantleNSView(_ nsView: AnchorView, coordinator: ()) {
        nsView.stopWatching()
    }

    /// Marks where the bar is in its window, behind the row.
    final class AnchorView: NSView {
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopWatching()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                // A wheel's events belong to no gesture, unlike a trackpad's.
                guard let self, event.window === window, event.phase.isEmpty, event.momentumPhase.isEmpty,
                      event.scrollingDeltaX == 0, event.scrollingDeltaY != 0,
                      bounds.contains(convert(event.locationInWindow, from: nil)) else { return event }
                return event.turnedSideways() ?? event
            }
        }

        func stopWatching() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

/// Closes the tab that the middle mouse button is clicked on, as browsers and other
/// editors do. SwiftUI has no gesture for that button, so the bar watches for it.
struct MiddleClickClosesTab<Tab: Hashable>: NSViewRepresentable {
    /// The tab at a horizontal position in the bar, if there's one.
    let tab: (CGFloat) -> Tab?
    let close: (Tab) -> Void

    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        nsView.tab = tab
        nsView.close = close
    }

    static func dismantleNSView(_ nsView: AnchorView, coordinator: ()) {
        nsView.stopWatching()
    }

    /// Marks where the bar is in its window, behind the row.
    final class AnchorView: NSView {
        var tab: (CGFloat) -> Tab? = { _ in nil }
        var close: (Tab) -> Void = { _ in }

        private var monitor: Any?
        /// The tab the button went down on: it closes if the button comes up on it too.
        private var pressed: Tab?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopWatching()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseUp]) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        func stopWatching() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            pressed = nil
        }

        private func handle(_ event: NSEvent) {
            // Button 2 is the middle one; a mouse's further buttons are left alone.
            guard event.buttonNumber == 2 else { return }
            let point = convert(event.locationInWindow, from: nil)
            // The view covers the part of the row that shows, so tabs scrolled out
            // of the bar can't be hit. The monitor sees clicks before the window turns
            // them away, so a sheet or an alert has to rule them out here.
            let isBlocked = window?.attachedSheet != nil || NSApp.modalWindow != nil
            let hit = event.window === window && !isBlocked && bounds.contains(point) ? tab(point.x) : nil
            if event.type == .otherMouseDown {
                pressed = hit
                return
            }
            defer { pressed = nil }
            guard let hit, hit == pressed else { return }
            // After the event is through: closing a tab with unsaved changes asks
            // about them in an alert, which shouldn't run inside the monitor.
            DispatchQueue.main.async { [weak self] in self?.close(hit) }
        }
    }
}

private extension NSEvent {
    /// A copy of a scroll event with its vertical travel made horizontal, as holding
    /// Shift does.
    func turnedSideways() -> NSEvent? {
        guard let copy = cgEvent?.copy() else { return nil }
        let lines = copy.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let fraction = copy.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let points = copy.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        // Whole lines first: setting them recomputes the finer amounts.
        copy.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
        copy.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: lines)
        copy.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
        copy.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: fraction)
        copy.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
        copy.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: points)
        return NSEvent(cgEvent: copy)
    }
}

/// How strongly each end of the tab row fades, from 0 (not at all) to 1.
struct EdgeFades: Equatable {
    var leading: CGFloat = 0
    var trailing: CGFloat = 0

    init() {}

    /// Each end fades in over the first `distance` points of row scrolled out past it.
    init(leading: CGFloat, trailing: CGFloat, over distance: CGFloat) {
        self.leading = min(max(leading / distance, 0), 1)
        self.trailing = min(max(trailing / distance, 0), 1)
    }
}

/// A tab bar's row as it's laid out, which a drag along it is worked out from.
struct TabBarLayout<Tab: Hashable> {
    let tabs: [Tab]
    /// Each tab's laid-out width.
    let widths: [Tab: CGFloat]
    /// The gap between two tabs, and the room before the first and after the last.
    let spacing: CGFloat
    let inset: CGFloat
    /// Width of the part of the row that shows, and how far the row is scrolled under it.
    let barWidth: CGFloat
    let scrollOffset: CGFloat

    /// The tab at a horizontal position in the bar, if there's one.
    func tab(at x: CGFloat) -> Tab? {
        var leading = inset - scrollOffset
        for tab in tabs {
            let width = widths[tab] ?? 0
            if x >= leading && x < leading + width { return tab }
            leading += width + spacing
        }
        return nil
    }
}

/// A tab being dragged to another place in its bar.
struct TabDrag<Tab: Hashable> {
    let tab: Tab
    /// Horizontal distance the pointer has moved since the drag began.
    var translation: CGFloat
    /// The pointer's horizontal position in the tab bar.
    var location: CGFloat
    /// How far the row was scrolled when the drag began.
    let startScrollOffset: CGFloat

    /// Where the dragged tab would land if dropped now, and how far each tab sits from
    /// its place in the row meanwhile: the dragged one follows the pointer, and the
    /// tabs it has passed step aside by its width. The order itself changes on drop.
    func reorder(in bar: TabBarLayout<Tab>) -> (destination: Int, offsets: [Tab: CGFloat])? {
        let tabs = bar.tabs
        guard let source = tabs.firstIndex(of: tab) else { return nil }
        let widths = tabs.map { bar.widths[$0] ?? 0 }
        // How far along the row a tab pushes the ones after it.
        let strides = widths.map { $0 + bar.spacing }
        let before = strides[..<source].reduce(0, +)
        let after = strides[(source + 1)...].reduce(0, +)

        // The pointer's travel, plus the row's as it scrolled under the pointer.
        var offset = translation + bar.scrollOffset - startScrollOffset
        // The tab stays in view when the pointer leaves the bar, which scrolls it...
        if bar.barWidth > 0 {
            let leading = bar.scrollOffset - (bar.inset + before)
            offset = max(min(offset, leading + bar.barWidth - widths[source]), leading)
        }
        // ...and stops at the ends of the row.
        offset = min(max(offset, -before), after)

        // A neighbor is passed once the dragged tab's leading or trailing edge crosses its middle.
        let neighbors = offset > 0 ? Array((source + 1)..<tabs.count) : Array((0..<source).reversed())
        var destination = source
        var passed: CGFloat = 0
        for index in neighbors {
            guard abs(offset) > passed + bar.spacing + widths[index] / 2 else { break }
            passed += strides[index]
            destination = index
        }

        var offsets = [tab: offset]
        let slot = destination > source ? -strides[source] : strides[source]
        for index in min(source, destination)...max(source, destination) where index != source {
            offsets[tabs[index]] = slot
        }
        return (destination, offsets)
    }

    /// Where the row should be scrolled to after `elapsed` seconds of the tab being
    /// held near an end of the bar, faster the further the pointer goes; `nil` when
    /// the row has no need to move.
    func autoscrollOffset(in bar: TabBarLayout<Tab>, elapsed: TimeInterval) -> CGFloat? {
        guard bar.barWidth > 0 else { return nil }
        // How close to an end of the bar the pointer starts scrolling it.
        let zone: CGFloat = 40
        // Scrolling speed, in points per second for each point the pointer is into the zone.
        let rate: CGFloat = 10
        // Only towards the side the tab has been dragged to: picking up a tab that
        // sits at an end of the bar shouldn't scroll it straight away.
        var depth: CGFloat = 0
        if translation > 0 {
            depth = max(location - (bar.barWidth - zone), 0)
        } else if translation < 0 {
            depth = min(location - zone, 0)
        }
        let speed = min(max(depth, -2 * zone), 2 * zone) * rate

        let rowWidth = bar.tabs.reduce(2 * bar.inset - bar.spacing) { $0 + (bar.widths[$1] ?? 0) + bar.spacing }
        let target = min(max(bar.scrollOffset + speed * CGFloat(elapsed), 0), max(rowWidth - bar.barWidth, 0))
        return target == bar.scrollOffset ? nil : target
    }
}

enum TabDragEvent {
    /// The pointer's travel since the drag began, and its position in the tab bar.
    case moved(translation: CGFloat, location: CGFloat)
    case dropped(translation: CGFloat)
    /// The drag stopped without a drop.
    case cancelled
}

private struct EditorTab: View {
    let url: URL
    /// The tab its pane shows.
    let isActive: Bool
    /// Whether its pane is the focused one: the active tab of another pane is drawn quieter.
    let isInFocusedPane: Bool
    let isDirty: Bool
    /// Deleted or moved on disk since it was opened.
    let isMissing: Bool
    let select: () -> Void
    let close: () -> Void
    let closeOthers: () -> Void
    /// Shows the file in the tree; `nil` for a file the tree doesn't have.
    let revealInTree: (() -> Void)?
    /// Copies the path from the workspace root; `nil` for a file outside the workspace.
    let copyRelativePath: (() -> Void)?
    /// Divides the tab's pane, the new one showing the tab's file too.
    let split: (PaneLayout.Axis) -> Void
    /// Closes the tab's pane, keeping its tabs; `nil` when it's the only pane.
    let closePane: (() -> Void)?
    /// Reports a drag, with the pointer's place among the panes: along the tab bar
    /// it moves the tab to another place in it, and onto another pane, to that pane.
    let drag: (TabDragEvent, CGPoint?) -> Void

    @State private var isHovering = false
    @GestureState private var isDragging = false

    var body: some View {
        HStack(spacing: 6) {
            FileIcon(url: url)
                .font(.caption)
            Text(url.lastPathComponent)
                .font(.callout)
                .lineLimit(1)
                .strikethrough(isMissing)
                .help(isMissing ? "Deleted from disk. Save to write it again." : "")

            ZStack {
                if isDirty && !isHovering {
                    Circle()
                        .fill(.primary.opacity(0.7))
                        .frame(width: 7, height: 7)
                } else {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .opacity(isActive || isHovering ? 1 : 0)
                    .help("Close")
                }
            }
            .frame(width: 16, height: 16)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .foregroundStyle(isActive && isInFocusedPane ? .primary : .secondary)
        // Only the active tab sits on glass.
        .glassSurface(isActive, in: .rect(cornerRadius: 8, style: .continuous))
        .contentShape(.rect(cornerRadius: 8, style: .continuous))
        .onTapGesture(perform: select)
        // Measured among the panes, which stay put as the tab moves with the drag and
        // which it can be dragged across. The tab bar keeps the drag from moving the
        // window as well.
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: EditorPanes.space)
                .updating($isDragging) { _, state, _ in state = true }
                .onChanged { drag(.moved(translation: $0.translation.width, location: $0.location.x), $0.location) }
                .onEnded { drag(.dropped(translation: $0.translation.width), $0.location) }
        )
        // A cancelled gesture resets its state without calling `onEnded`.
        .onChange(of: isDragging) { _, isDragging in
            if !isDragging { drag(.cancelled, nil) }
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Close", action: close)
            Button("Close Others", action: closeOthers)
            Divider()
            Button("Split Right") { split(.horizontal) }
            Button("Split Down") { split(.vertical) }
            if let closePane {
                Button("Close Pane", action: closePane)
            }
            if !url.isUntitled {
                Divider()
                if let revealInTree {
                    Button("Reveal in Explorer", action: revealInTree)
                }
                Button("Show in Finder") { Finder.reveal(url) }
                Button("Copy Path") { Finder.copyPath(url) }
                if let copyRelativePath {
                    Button("Copy Relative Path", action: copyRelativePath)
                }
            }
        }
    }
}

// MARK: - Buffer

private struct BufferView: View {
    let buffer: EditorBuffer
    let workspace: WorkspaceModel
    let pane: PaneLayout.PaneID

    /// Whether its pane is the focused one. What another pane shows doesn't take
    /// the keyboard when it changes, and has no status bar.
    private var isFocused: Bool { workspace.focusedPane == pane }

    /// Whether the pane still shows this buffer, for the AppKit views a tab takes
    /// along to another pane; see `TextViewHost`.
    private var isCurrent: () -> Bool {
        { [workspace, buffer, pane] in workspace.buffer(in: pane) === buffer }
    }

    /// The same, for the preview and the changes, which only one of the panes
    /// with the file open shows.
    private var isAuxiliaryHost: () -> Bool {
        { [workspace, buffer, pane] in
            workspace.buffer(in: pane) === buffer && workspace.hostsAuxiliaryView(of: buffer, in: pane)
        }
    }

    /// Where the status bar is over the editor, which keeps the pointer an arrow there.
    @State private var statusBarFrame = CGRect.zero
    private static let editorSpace: NamedCoordinateSpace = .named("Editor")

    var body: some View {
        if workspace.showsChanges(buffer, in: pane), let changes = buffer.changesPreview {
            GitDiffHost(preview: changes, isCurrent: isAuxiliaryHost)
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch buffer.content {
        case .text(let first):
            if workspace.showsPreview(buffer, in: pane), let preview = buffer.preview {
                PreviewHost(preview: preview, takesFocus: isFocused, isCurrent: isAuxiliaryHost)
            } else {
                // The pane's own editor on the text, which other panes may show too.
                let controller = buffer.editor(in: pane) ?? first
                // The status bar floats over the text's bottom corner rather than
                // taking a strip of the card, left of the minimap when it's shown.
                VStack(spacing: 0) {
                    if workspace.isConflicted(buffer) {
                        ConflictBar(buffer: buffer, workspace: workspace)
                    }
                    TextViewHost(
                        controller: controller, takesFocus: isFocused, isCurrent: isCurrent,
                        arrowCursorRect: isFocused ? statusBarFrame : .zero
                    )
                    .overlay(alignment: .bottomTrailing) {
                        if isFocused {
                            StatusBar(buffer: buffer, workspace: workspace)
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: Self.editorSpace) } action: { statusBarFrame = $0 }
                                .padding(4)
                                .padding(.trailing, EditorSettings.shared.showsMinimap ? MinimapView.width : 0)
                        }
                    }
                    .coordinateSpace(Self.editorSpace)
                }
            }
        case .image(let file):
            ImagePreview(file: file)
        case .pdf(let file):
            PDFPreview(file: file, name: buffer.name, takesFocus: isFocused, isCurrent: isCurrent)
        case .video(let file):
            VideoPreview(file: file, name: buffer.name, takesFocus: isFocused)
        case .binary:
            ContentUnavailableView(
                "Binary File",
                systemImage: "doc.questionmark",
                description: Text("“\(buffer.name)” isn’t a text file, so it can’t be shown in the editor.")
            )
        case .tooLarge(let size):
            ContentUnavailableView(
                "File Too Large",
                systemImage: "externaldrive.badge.exclamationmark",
                description: Text("“\(buffer.name)” is \(size.formatted(.byteCount(style: .file))), which is too large to open here.")
            )
        case .unreadable(let message):
            ContentUnavailableView(
                "Can’t Read File",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        }
    }
}

// MARK: - Conflicts

/// Over a file git couldn't merge: how many conflicts are left in it, buttons to
/// step through them and to settle the one at the cursor with the text on the
/// current branch, the text coming in, or both; then to mark the file resolved.
private struct ConflictBar: View {
    let buffer: EditorBuffer
    let workspace: WorkspaceModel

    var body: some View {
        // Follows the text as it's edited, not the cursor as it moves.
        let count = buffer.conflicts.count
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
            if count == 0 {
                Text("No conflicts left in this file.")
                Spacer(minLength: 8)
                Button("Save and Stage") { workspace.markResolved(buffer) }
                    .disabled(!workspace.git.isIdle)
                    .help("Tells git this file’s conflicts are settled")
            } else {
                Text(count == 1 ? "1 conflict" : "\(count.formatted()) conflicts")
                Button { buffer.showConflict(offsetBy: -1) } label: { Image(systemName: "chevron.up") }
                    .help("Previous Conflict")
                    .accessibilityLabel("Previous Conflict")
                Button { buffer.showConflict(offsetBy: 1) } label: { Image(systemName: "chevron.down") }
                    .help("Next Conflict")
                    .accessibilityLabel("Next Conflict")
                Spacer(minLength: 8)
                // In a rebase the sides are the other way round from a merge: above
                // the ======= line is the commit being rebased onto, and below it
                // the user's own commit being applied again. "Current" would then
                // name the side that isn't theirs, so the buttons say whose each is.
                let isRebase = workspace.git.snapshot?.pending?.kind == .rebase
                Button(isRebase ? "Accept Upstream" : "Accept Current") { buffer.resolveConflict(taking: .current) }
                    .help(isRebase
                        ? "Keep the text above the ======= line: the commit you’re rebasing onto"
                        : "Keep the text above the ======= line: what the current branch has")
                Button(isRebase ? "Accept My Commit" : "Accept Incoming") { buffer.resolveConflict(taking: .incoming) }
                    .help(isRebase
                        ? "Keep the text below the ======= line: your own commit, being applied again"
                        : "Keep the text below the ======= line: what is being merged in")
                Button("Accept Both") { buffer.resolveConflict(taking: .both) }
                    .help("Keep both, the text above the ======= line first")
            }
        }
        .font(.caption)
        .controlSize(.small)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.orange.opacity(0.12))
    }
}

// MARK: - Status bar

/// Cursor position, indentation, encoding, line endings and language, in a small
/// line over the bottom-right corner of the editor.
private struct StatusBar: View {
    let buffer: EditorBuffer
    let workspace: WorkspaceModel

    /// How much the bar says. A narrow pane has room for less of it.
    private enum Detail {
        case full
        /// Without the branch, the blame, the encoding and the line endings.
        case brief
        /// The cursor's position alone.
        case position
    }

    var body: some View {
        // The bar is as wide as what's in it, and floats on the text: in a pane
        // too narrow for all of it, it says less rather than run off the card.
        ViewThatFits(in: .horizontal) {
            bar(.full)
            bar(.brief)
            bar(.position)
        }
    }

    private func bar(_ detail: Detail) -> some View {
        HStack(spacing: 12) {
            if detail == .full, let branch = workspace.git.snapshot?.branch {
                Button(action: workspace.showChanges) {
                    // A branch's name can be any length, and the bar is as wide
                    // as what's in it: it mustn't grow over the text it floats on.
                    Label(branch.name ?? "Detached", systemImage: "arrow.triangle.branch")
                        .labelStyle(.titleAndIcon)
                        .truncationMode(.middle)
                        .frame(maxWidth: 160)
                }
                .buttonStyle(.plain)
                .help((branch.name.map { "\($0) · " } ?? "") + KeybindSettings.shared.help("Source Control", for: .sourceControl))
                .accessibilityLabel("Branch: \(branch.name ?? "Detached")")
            }
            Button(action: workspace.showGoToLine) {
                Text(position)
            }
            .buttonStyle(.plain)
            .help(KeybindSettings.shared.help("Go to Line", for: .goToLine))
            if detail == .full, EditorSettings.shared.showsLineBlame, workspace.git.isRepository, !buffer.isUntitled {
                blame
            }
            if detail != .position {
                Text(buffer.indentation.usesTabs ? "Tabs" : "Spaces: \(buffer.indentation.width)")
            }
            if detail == .full {
                Text(buffer.encodingName)
                Text(buffer.lineEndingName)
            }
            if detail != .position {
                Text(buffer.language?.displayName ?? "Plain Text")
            }
            // Last, and at every width: where a new pane is asked for with the pointer.
            HStack(spacing: 2) {
                splitButton("rectangle.split.2x1", "Split Right", .splitRight, along: .horizontal)
                splitButton("rectangle.split.1x2", "Split Down", .splitDown, along: .vertical)
            }
            // The fill under the pointer is taller than the text and wider than the
            // icon: the bar keeps its height, and the icons their place at its end.
            .padding(.vertical, -3)
            .padding(.horizontal, -4)
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .glassSurface(in: .capsule)
        .fixedSize()
    }

    /// Divides the pane the bar is in, which is the focused one, the new pane
    /// showing the same file.
    private func splitButton(
        _ symbol: String, _ title: String, _ command: ConfigKeyCommand, along axis: PaneLayout.Axis
    ) -> some View {
        Button {
            workspace.splitPane(axis)
        } label: {
            Image(systemName: symbol)
                // A little larger than the text beside it, which the outlines look small next to.
                .imageScale(.large)
        }
        // Lit under the pointer, like the buttons over the file tree.
        .buttonStyle(.statusBarIcon)
        .help(KeybindSettings.shared.help(title, for: command))
        .accessibilityLabel(title)
    }

    /// Who last changed the line the cursor is on. Read again when the file
    /// changes on disk or the branch moves; with unsaved edits the lines no longer match
    /// the file that was blamed, so nothing is said.
    @ViewBuilder
    private var blame: some View {
        let line = buffer.isDirty ? nil : buffer.blame.flatMap { $0.indices.contains(buffer.cursor.line - 1) ? $0[buffer.cursor.line - 1] : nil }
        Button {
            workspace.showFileHistory(buffer.url)
        } label: {
            Group {
                if let line {
                    Text(line.isUncommitted ? "Not committed yet" : "\(line.author), \(line.date.formatted(.relative(presentation: .named)))")
                } else {
                    Text(buffer.isDirty ? "Save to see blame" : "Blame…")
                }
            }
            // An author's name has no length limit either.
            .truncationMode(.middle)
            .frame(maxWidth: 200)
        }
        .buttonStyle(.plain)
        .help(line.map { $0.isUncommitted ? "This line has changed since the last commit" : "\($0.hash.prefix(7)) · \($0.summary)" } ?? "Show File History")
        .accessibilityLabel("Blame")
        .task(id: BlameKey(
            url: buffer.url, head: workspace.git.snapshot?.branch.head, isDirty: buffer.isDirty,
            diskRevision: buffer.diskRevision
        )) {
            guard !buffer.isDirty else { return }
            buffer.blame = await workspace.git.blame(of: workspace.relativePath(of: buffer.url))
        }
    }

    /// What the blame read depends on. The file can change with HEAD where it
    /// was: a discard, a stash, a checkout of the file in a terminal.
    private struct BlameKey: Equatable {
        var url: URL
        var head: String?
        var isDirty: Bool
        var diskRevision: Int
    }

    private var position: String {
        let cursor = buffer.cursor
        let base = "Ln \(cursor.line), Col \(cursor.column)"
        return cursor.selectedLength > 0 ? base + " (\(cursor.selectedLength) selected)" : base
    }
}

// MARK: - Preview

/// Source / Preview switch for Markdown, CSV and HTML tabs, in the quiet icon style of the
/// other title bar buttons; the current mode is drawn in the primary color on a soft fill.
private struct PreviewModeToggle: View {
    let buffer: EditorBuffer
    let format: PreviewFormat
    let workspace: WorkspaceModel
    let pane: PaneLayout.PaneID

    var body: some View {
        // What this pane shows: the preview may be in another pane with the file open.
        let isShowingPreview = workspace.showsPreview(buffer, in: pane)
        HStack(spacing: 2) {
            option("doc.plaintext", help: KeybindSettings.shared.help("Show \(format.sourceName)", for: .togglePreview), isOn: !isShowingPreview) {
                workspace.setShowingPreview(false, of: buffer, in: pane)
            }
            option("eye", help: KeybindSettings.shared.help("Show Preview", for: .togglePreview), isOn: isShowingPreview) {
                workspace.setShowingPreview(true, of: buffer, in: pane)
            }
        }
    }

    private func option(_ symbol: String, help: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 26, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(isOn ? .primary : .secondary)
        .background {
            if isOn {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.primary.opacity(0.08))
            }
        }
        .help(help)
    }
}

/// Switches a changed file's tab between the file and what changed in it since
/// the last commit, in the style of the Source / Preview switch.
private struct ChangesToggle: View {
    let buffer: EditorBuffer
    let workspace: WorkspaceModel
    let pane: PaneLayout.PaneID

    var body: some View {
        // What this pane shows: the changes may be in another pane with the file open.
        let isShowingChanges = workspace.showsChanges(buffer, in: pane)
        HStack(spacing: 6) {
            // Whose changes these are, when they aren't the ones since the last commit.
            if isShowingChanges, buffer.shownCommit == nil, buffer.shownComparison != .all {
                Text(buffer.shownComparison == .staged ? "Staged" : "Unstaged")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(buffer.shownComparison == .staged ? "Showing what is staged in this file" : "Showing what isn’t staged in this file")
            }
            if isShowingChanges, let commit = buffer.shownCommit {
                Text(commit.shortHash)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("Showing what “\(commit.subject)” changed in this file")
            }
            if isShowingChanges {
                let settings = EditorSettings.shared
                Button {
                    settings.showsChangesSideBySide.toggle()
                } label: {
                    Image(systemName: "rectangle.split.2x1")
                        .frame(width: 26, height: 22)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(settings.showsChangesSideBySide ? .primary : .secondary)
                .background {
                    if settings.showsChangesSideBySide {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.primary.opacity(0.08))
                    }
                }
                .help(settings.showsChangesSideBySide ? "Show Changes in One Column" : "Show Changes Side by Side")
                .accessibilityLabel("Side by Side")
            }
            Button(action: workspace.toggleChanges) {
                Image(systemName: "plus.forwardslash.minus")
                    .frame(width: 26, height: 22)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(isShowingChanges ? .primary : .secondary)
            .background {
                if isShowingChanges {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.primary.opacity(0.08))
                }
            }
            .help(isShowingChanges ? "Hide Changes" : "Show Changes")
            .accessibilityLabel("Changes")
        }
    }
}

// MARK: - Image

/// Shows an image file fitted to the editor card, never enlarged past one image
/// pixel per point (VS Code's and Preview's 100%), over a checkerboard so
/// transparent areas are visible. A GIF or other animated image plays.
private struct ImagePreview: View {
    let file: EditorBuffer.ImageFile

    var body: some View {
        VStack(spacing: 12) {
            picture
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .background(Checkerboard())
                .overlay(Rectangle().strokeBorder(.separator, lineWidth: 1))
                .frame(maxWidth: file.pixelSize.width, maxHeight: file.pixelSize.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text(details)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(24)
        // An animation plays only while its tab is the one shown.
        .onAppear { file.animation?.start() }
        .onDisappear { file.animation?.stop() }
        // Appears anew for each animated image, so going from one such tab to
        // another stops the first and starts the second.
        .id(file.animation.map(ObjectIdentifier.init))
    }

    /// The animation's current frame, or the still image.
    private var picture: Image {
        if let frame = file.animation?.frame {
            Image(decorative: frame, scale: 1)
        } else {
            Image(nsImage: file.image)
        }
    }

    private var details: String {
        let size = "\(Int(file.pixelSize.width)) × \(Int(file.pixelSize.height)) px"
        var parts = [size, file.format]
        if let animation = file.animation { parts.append("\(animation.frameCount) frames") }
        parts.append(file.byteCount.formatted(.byteCount(style: .file)))
        return parts.joined(separator: "  ·  ")
    }
}

/// Light and dark squares behind transparent pixels, as image editors draw them.
private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let square: CGFloat = 8
            for row in 0..<Int((size.height / square).rounded(.up)) {
                for column in 0..<Int((size.width / square).rounded(.up)) where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(x: CGFloat(column) * square, y: CGFloat(row) * square, width: square, height: square)
                    context.fill(Path(rect), with: .color(.primary.opacity(0.06)))
                }
            }
        }
    }
}

// MARK: - PDF

/// Shows a PDF's pages in the editor card, with its page count and size over the
/// corner where text files have their status bar. A password-protected PDF asks
/// for its password first.
private struct PDFPreview: View {
    let file: EditorBuffer.PDFFile
    let name: String
    /// Whether the pages take the keyboard when they're put in the card.
    var takesFocus = true
    /// Whether this card is still the one showing the PDF; see `TextViewHost`.
    var isCurrent: () -> Bool = { true }

    var body: some View {
        if file.isLocked {
            PDFPasswordPrompt(file: file, name: name)
                // Each locked tab keeps its own half-typed password.
                .id(ObjectIdentifier(file))
        } else {
            PDFViewHost(pdfView: file.view, takesFocus: takesFocus, isCurrent: isCurrent)
                .overlay(alignment: .bottomTrailing) {
                    Text(details)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .glassSurface(in: .capsule)
                        .fixedSize()
                        .padding(4)
                }
        }
    }

    private var details: String {
        let pages = file.pageCount == 1 ? "1 page" : "\(file.pageCount) pages"
        return [pages, file.byteCount.formatted(.byteCount(style: .file))].joined(separator: "  ·  ")
    }
}

/// Stands in for a protected PDF's pages until the right password is entered.
private struct PDFPasswordPrompt: View {
    let file: EditorBuffer.PDFFile
    let name: String

    @State private var password = ""
    @State private var wasRejected = false
    @FocusState private var isFocused: Bool

    var body: some View {
        ContentUnavailableView {
            Label("Password Required", systemImage: "lock.doc")
        } description: {
            Text(wasRejected ? "That password didn’t unlock “\(name)”." : "“\(name)” is password-protected.")
        } actions: {
            HStack {
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .focused($isFocused)
                    .onSubmit(unlock)
                Button("Unlock", action: unlock)
                    .disabled(password.isEmpty)
            }
        }
        .onAppear { isFocused = true }
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        wasRejected = !file.unlock(with: password)
        if wasRejected { password = "" }
    }
}

/// Hosts whichever PDF tab's view is active.
private struct PDFViewHost: NSViewRepresentable {
    let pdfView: PDFView
    let takesFocus: Bool
    let isCurrent: () -> Bool

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if pdfView.superview !== container, isCurrent() {
            container.subviews.forEach { $0.removeFromSuperview() }
            attach(to: container)
        }
    }

    private func attach(to container: NSView) {
        pdfView.removeFromSuperview()
        pdfView.frame = container.bounds
        pdfView.autoresizingMask = [.width, .height]
        container.addSubview(pdfView)
        guard takesFocus else { return }
        // So the arrow keys, Page Up and Page Down scroll it straight away.
        DispatchQueue.main.async { [pdfView] in
            pdfView.window?.makeFirstResponder(pdfView)
        }
    }
}

// MARK: - Video

/// Plays a video file fitted to the editor card, with its size, length and file
/// size beneath it as images have.
private struct VideoPreview: View {
    let file: EditorBuffer.VideoFile
    let name: String
    /// Whether the player takes the keyboard when it's put in the card.
    var takesFocus = true

    var body: some View {
        switch file.state {
        case .loading:
            Color.clear
        case .unplayable:
            ContentUnavailableView(
                "Can’t Play Video",
                systemImage: "video.slash",
                description: Text("“\(name)” is in a format Silica can’t play, or the file is damaged.")
            )
        case .ready:
            VStack(spacing: 12) {
                VideoPlayerHost(player: file.player, takesFocus: takesFocus)
                    // The picture's own shape, so no black bars are drawn around it.
                    .aspectRatio(file.pixelSize.map { $0.width / $0.height }, contentMode: .fit)
                    .overlay(Rectangle().strokeBorder(.separator, lineWidth: 1))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Text(details)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }

    private var details: String {
        var parts: [String] = []
        if let size = file.pixelSize {
            parts.append("\(Int(size.width)) × \(Int(size.height)) px")
        }
        if let duration = file.duration {
            parts.append(Duration.seconds(duration.rounded()).formatted(.time(pattern: duration >= 3600 ? .hourMinuteSecond : .minuteSecond)))
        }
        parts.append(file.byteCount.formatted(.byteCount(style: .file)))
        return parts.joined(separator: "  ·  ")
    }
}

/// AVKit's player view, playing whichever video tab is active.
private struct VideoPlayerHost: NSViewRepresentable {
    let player: AVPlayer
    let takesFocus: Bool

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.player = player
        focus(view)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        guard view.player !== player else { return }
        // Another video tab took the card: the one left behind stops playing.
        view.player?.pause()
        view.player = player
        focus(view)
    }

    /// A tab that isn't shown doesn't keep playing.
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }

    private func focus(_ view: AVPlayerView) {
        guard takesFocus else { return }
        // So Space plays and pauses, and the arrow keys step, straight away.
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
    }
}

// MARK: - Empty state

private struct EmptyEditorView: View {
    let workspace: WorkspaceModel
    private var keybinds: KeybindSettings { .shared }

    var body: some View {
        VStack(spacing: 24) {
            // The app icon, as on the welcome window; it carries its own margin.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 112, height: 112)

            VStack(spacing: 6) {
                Text(workspace.name)
                    .font(.title2.weight(.semibold))
                Text("Select a file in the sidebar to start editing.")
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                shortcut("Quick Open", keys: keybinds.keybind(for: ConfigKeyCommand.quickOpen).displayName)
                shortcut("Open Another Project", keys: keybinds.keybind(for: FixedKeyCommand.open).displayName)
                shortcut("Toggle Sidebar", keys: keybinds.keybind(for: ConfigKeyCommand.toggleSidebar).displayName)
            }
            .font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func shortcut(_ title: String, keys: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(keys)
                .monospaced()
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .glassSurface(in: .capsule)
        }
    }
}
