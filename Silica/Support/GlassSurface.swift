import SwiftUI

extension View {
    /// Liquid Glass behind the view or, with the glass effect off in Settings, a
    /// plain card: a solid fill with a shadow and a hairline border. `isOn` false
    /// draws neither, for a tab that isn't selected.
    func glassSurface(_ isOn: Bool = true, in shape: some Shape) -> some View {
        modifier(GlassSurface(isOn: isOn, shape: shape))
    }

    /// The glass button styles or, with the glass effect off in Settings, the
    /// bordered ones.
    func glassButtonStyle(prominent: Bool = false) -> some View {
        modifier(GlassButtonStyle(isProminent: prominent))
    }
}

private struct GlassSurface<S: Shape>: ViewModifier {
    let isOn: Bool
    let shape: S

    private var settings: EditorSettings { .shared }

    func body(content: Content) -> some View {
        if settings.usesGlassEffect {
            // `.identity` renders no effect.
            content.glassEffect(isOn ? .regular : .identity, in: shape)
        } else {
            content
                .background {
                    if isOn {
                        shape
                            .fill(Color(nsColor: .textBackgroundColor))
                            .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
                    }
                }
                .overlay {
                    if isOn {
                        shape
                            .stroke(Color.secondary.opacity(0.5), lineWidth: 0.5)
                            .allowsHitTesting(false)
                    }
                }
        }
    }
}

private struct GlassButtonStyle: ViewModifier {
    let isProminent: Bool

    private var settings: EditorSettings { .shared }

    func body(content: Content) -> some View {
        switch (settings.usesGlassEffect, isProminent) {
        case (true, true): content.buttonStyle(.glassProminent)
        case (true, false): content.buttonStyle(.glass)
        case (false, true): content.buttonStyle(.borderedProminent)
        case (false, false): content.buttonStyle(.bordered)
        }
    }
}
