import AppKit
import SwiftUI

/// The integrated terminal: a glass card under the editor's, with a header that
/// names what's running, or has a tab for each terminal once there are several, and
/// the terminal that's showing below.
struct TerminalCard: View {
    let session: TerminalSession
    let workspace: WorkspaceModel

    var body: some View {
        // The same shape as the editor card: the bottom corners follow the window's.
        let shape = ConcentricRectangle(corners: .concentric(minimum: .fixed(WorkspaceLayout.cardCornerRadius)))
        VStack(spacing: 0) {
            header
            TerminalViewHost(view: session.view)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(shape)
        .glassEffect(.regular, in: shape)
    }

    private var header: some View {
        let hasTabs = workspace.terminals.count > 1
        return HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                if hasTabs {
                    // Kept in place under a link's destination, so the row is
                    // scrolled where it was once the pointer leaves the link.
                    TerminalTabBar(workspace: workspace)
                        .opacity(session.linkDestination == nil ? 1 : 0)
                        .allowsHitTesting(session.linkDestination == nil)
                }
                // A terminal by itself needs no tab, only its name. Over a link,
                // where it leads takes the place of either: the link's text needn't say.
                if let destination = session.linkDestination {
                    label("link", destination)
                } else if !hasTabs {
                    // Shells name the terminal after the folder or the command that's running.
                    label("terminal", session.name)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                workspace.newTerminal()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.titleBarIcon)
            .help("New Terminal (⌃⇧`)")
            Button {
                workspace.closeTerminal()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.titleBarIcon)
            .help("Kill Terminal")
            Button {
                workspace.hideTerminal()
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.titleBarIcon)
            .help("Hide Terminal (⌃`)")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .frame(height: 30)
    }

    private func label(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.caption)
            Text(text)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        // In line with the first tab's, which take its place.
        .padding(.leading, 8)
        .padding(.trailing, 2)
    }
}

/// The terminals' tabs, in the card's header once there's more than one. A smaller
/// relative of the editor's tab bar: the row scrolls when it has more tabs than fit,
/// and a middle click closes one.
private struct TerminalTabBar: View {
    let workspace: WorkspaceModel

    /// Each tab's laid-out width, to tell which tab a middle click is on.
    @State private var tabWidths: [TerminalSession.ID: CGFloat] = [:]
    @State private var scrollOffset: CGFloat = 0
    /// How much each end of the row is faded: fully once tabs are scrolled out past it.
    @State private var edgeFades = EdgeFades()

    private static let spacing: CGFloat = 2
    /// How far in from an end of the bar the row fades out.
    private static let fadeWidth: CGFloat = 12

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: Self.spacing - 2 * Self.fadeWidth) {
                    ForEach(workspace.terminals) { terminal in
                        TerminalTab(
                            session: terminal,
                            isSelected: terminal === workspace.terminal,
                            select: { workspace.selectTerminal(terminal) },
                            close: { workspace.closeTerminal(terminal) }
                        )
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tabWidths[terminal.id] = $0 }
                        // Room on either side that the row scrolls into view with the
                        // tab, so that it comes to rest clear of the faded ends of the
                        // bar. The row's spacing and padding take the same room back out.
                        .padding(.horizontal, Self.fadeWidth)
                        .id(terminal.id)
                    }
                }
                .padding(.horizontal, -Self.fadeWidth)
                // Room for the selected tab's glass, which reaches past its edges.
                .padding(.vertical, 4)
            }
            .scrollIndicators(.never)
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
            .mask { fadeMask }
            .background(WheelScrollsSideways())
            .background(
                MiddleClickClosesTab(tab: tab(at:)) { id in
                    if let terminal = workspace.terminals.first(where: { $0.id == id }) {
                        workspace.closeTerminal(terminal)
                    }
                }
            )
            .onAppear {
                if let selected = workspace.terminal { proxy.scrollTo(selected.id) }
            }
            .onChange(of: workspace.terminal?.id) { _, selected in
                if let selected {
                    withAnimation { proxy.scrollTo(selected) }
                }
            }
            .onChange(of: workspace.terminals.map(\.id)) { _, ids in
                tabWidths = tabWidths.filter { ids.contains($0.key) }
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

    /// The tab at a horizontal position in the bar, if there's one.
    private func tab(at x: CGFloat) -> TerminalSession.ID? {
        var leading = -scrollOffset
        for terminal in workspace.terminals {
            let width = tabWidths[terminal.id] ?? 0
            if x >= leading && x < leading + width { return terminal.id }
            leading += width + Self.spacing
        }
        return nil
    }
}

private struct TerminalTab: View {
    let session: TerminalSession
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.caption)
            Text(session.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        // A long title, such as a path, doesn't crowd the other tabs out.
        .frame(maxWidth: 180)
        .foregroundStyle(isSelected ? .primary : .secondary)
        // Under the pointer, a tab gets a fainter fill than the title bar's buttons do.
        .background(
            Color.primary.opacity(!isSelected && isHovering ? 0.05 : 0),
            in: .rect(cornerRadius: 6, style: .continuous)
        )
        // Only the selected tab sits on glass, like the editor's active tab;
        // `.identity` renders no effect.
        .glassEffect(isSelected ? .regular : .identity, in: .rect(cornerRadius: 6, style: .continuous))
        .contentShape(.rect(cornerRadius: 6, style: .continuous))
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
        .help(session.name)
        .contextMenu {
            Button("Kill Terminal", action: close)
        }
    }
}

/// Shows and hides the terminal from the title bar: the bottom card's counterpart to
/// the sidebar's toggle at the other end of the row.
struct TerminalToggleButton: View {
    let workspace: WorkspaceModel

    var body: some View {
        Button {
            // Unlike ⌃`, which goes to a terminal that's showing but doesn't have
            // the keyboard, a click on this always shows or hides.
            if workspace.isTerminalVisible { workspace.hideTerminal() } else { workspace.showTerminal() }
        } label: {
            Image(systemName: "terminal")
        }
        .buttonStyle(.titleBarIcon)
        // Tinted while it's on, like the Search button in the sidebar's header.
        .foregroundStyle(workspace.isTerminalVisible ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .help(workspace.isTerminalVisible ? "Hide Terminal (⌃`)" : "Show Terminal (⌃`)")
    }
}

/// Puts the session's own view in the card. The view outlives the card: hiding the
/// terminal takes the card away, and showing it again brings the same view back.
private struct TerminalViewHost: NSViewRepresentable {
    let view: TerminalView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if view.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            attach(to: container)
        }
    }

    private func attach(to container: NSView) {
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
    }
}
