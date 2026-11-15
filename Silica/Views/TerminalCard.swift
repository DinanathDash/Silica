import AppKit
import SwiftUI

/// The integrated terminal: a glass card under the editor's, with a header that
/// names what's running and the terminal itself below.
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
        HStack(spacing: 6) {
            Image(systemName: session.linkDestination == nil ? "terminal" : "link")
                .font(.caption)
            // Shells name the terminal after the folder or the command that's running.
            // Over a link, where it leads takes the name's place: the link's text
            // needn't say.
            Text(session.linkDestination ?? (session.title.isEmpty ? session.shellName : session.title))
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
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
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 30)
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
