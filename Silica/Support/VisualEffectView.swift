import AppKit
import SwiftUI

/// AppKit frosted background. Unlike SwiftUI materials, this exposes the full set of
/// `NSVisualEffectView` materials and can stay frosted while the window is inactive.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var state: NSVisualEffectView.State

    init(
        _ material: NSVisualEffectView.Material = .menu,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        state: NSVisualEffectView.State = .active
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.state = state
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

/// The background of a project or welcome window: translucent or opaque, as chosen
/// in Settings, washed with the active theme. In performance mode, paints a solid
/// background to minimize GPU overhead.
struct WindowBackgroundView: View {
    private var settings: EditorSettings { .shared }

    var body: some View {
        if settings.performanceMode || settings.windowBackground == .opaque {
            Color(nsColor: .windowBackgroundColor)
        } else {
            ZStack {
                VisualEffectView(settings.windowBackground.material)
                ThemeManager.spec.surface
                    .opacity(0.12)
            }
        }
    }
}
