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
/// in Settings. Open windows follow the setting as it changes.
struct WindowBackgroundView: View {
    private var settings: EditorSettings { .shared }
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool {
        switch settings.appearance {
        case .dark: true
        case .light: false
        case .system: colorScheme == .dark
        }
    }

    var body: some View {
        if settings.windowBackground == .opaque {
            (isDark ? Color(red: 0.071, green: 0.071, blue: 0.082) : Color(nsColor: .windowBackgroundColor))
                .ignoresSafeArea()
        } else {
            VisualEffectView(settings.windowBackground.material)
        }
    }
}
