import SwiftUI

extension View {
    /// Liquid Glass behind the view or, with the glass effect off in Settings or
    /// before macOS 26, which has none, a plain card: a solid fill with a shadow
    /// and a hairline border. `isOn` false draws neither, for a tab that isn't
    /// selected.
    func glassSurface(_ isOn: Bool = true, in shape: some Shape) -> some View {
        modifier(GlassSurface(isOn: isOn, shape: shape))
    }

    /// The glass button styles or, with the glass effect off in Settings or before
    /// macOS 26, the bordered ones.
    func glassButtonStyle(prominent: Bool = false) -> some View {
        modifier(GlassButtonStyle(isProminent: prominent))
    }

    /// Clips the view to the shape of the editor and terminal cards and puts the
    /// card's surface behind it. Corners next to the window's corners follow its
    /// radius minus the inset, and the others fall back to the minimum; before
    /// macOS 26 every corner has the minimum.
    @ViewBuilder
    func workspaceCard() -> some View {
        if #available(macOS 26.0, *) {
            let shape = ConcentricRectangle(corners: .concentric(minimum: .fixed(WorkspaceLayout.cardCornerRadius)))
            clipShape(shape).glassSurface(in: shape)
        } else {
            let shape = RoundedRectangle(cornerRadius: WorkspaceLayout.cardCornerRadius, style: .continuous)
            clipShape(shape).glassSurface(in: shape)
        }
    }

    /// Lets the glass shapes inside blend into each other. Before macOS 26 there's
    /// no glass to blend.
    @ViewBuilder
    func glassContainer(spacing: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }

    /// Fades what scrolls under the top and bottom edges, on macOS 26 and later.
    @ViewBuilder
    func softVerticalScrollEdges() -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .vertical)
        } else {
            self
        }
    }

    /// Native selector tabs picker style conforming to system version.
    @ViewBuilder
    func tabsPickerStyle() -> some View {
        if #available(macOS 27.0, *) {
            pickerStyle(.tabs)
                .buttonBorderShape(.capsule)
        } else {
            pickerStyle(.segmented)
        }
    }
}

private struct GlassSurface<S: Shape>: ViewModifier {
    let isOn: Bool
    let shape: S

    private var settings: EditorSettings { .shared }
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool {
        switch settings.appearance {
        case .dark: true
        case .light: false
        case .system: colorScheme == .dark
        }
    }

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), settings.usesGlassEffect, settings.windowBackground != .opaque {
            // `.identity` renders no effect.
            content.glassEffect(isOn ? .regular : .identity, in: shape)
        } else if settings.windowBackground == .translucent {
            content
                .background {
                    if isOn {
                        shape
                            .fill(.ultraThinMaterial)
                            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    }
                }
                .overlay {
                    if isOn {
                        let strokeColor = isDark ? Color.white.opacity(0.12) : Color.white.opacity(0.25)
                        shape
                            .stroke(strokeColor, lineWidth: 0.5)
                            .allowsHitTesting(false)
                    }
                }
        } else {
            content
                .background {
                    if isOn {
                        let fill: Color = isDark
                            ? Color(red: 0.095, green: 0.095, blue: 0.108)
                            : Color(nsColor: .textBackgroundColor)
                        shape
                            .fill(fill)
                            .shadow(color: .black.opacity(isDark ? 0.25 : 0.08), radius: 6, y: 2)
                    }
                }
                .overlay {
                    if isOn {
                        let strokeColor: Color = isDark
                            ? Color.white.opacity(0.08)
                            : Color.secondary.opacity(0.3)
                        shape
                            .stroke(strokeColor, lineWidth: 0.5)
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
        if #available(macOS 26.0, *), settings.usesGlassEffect, settings.windowBackground != .opaque {
            if isProminent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else if isProminent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

/// Liquid glass styled tooltip modifier with 1s delay
public struct LiquidGlassTooltipModifier: ViewModifier {
    let text: String
    var delay: Double = 1.0

    @State private var isVisible = false
    @State private var timerTask: Task<Void, Never>?

    public func body(content: Content) -> some View {
        if text.isEmpty {
            content
        } else {
            content
                .popover(isPresented: $isVisible, arrowEdge: .bottom) {
                    tooltipCard
                }
                .onHover { hovering in
                    timerTask?.cancel()
                    if hovering {
                        timerTask = Task {
                            do {
                                let delayNs = UInt64(max(0.1, delay) * 1_000_000_000)
                                try await Task.sleep(nanoseconds: delayNs)
                                guard !Task.isCancelled else { return }
                                isVisible = true
                            } catch { }
                        }
                    } else {
                        isVisible = false
                    }
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            timerTask?.cancel()
                            timerTask = nil
                            isVisible = false
                        }
                )
                .onDisappear {
                    timerTask?.cancel()
                    timerTask = nil
                    isVisible = false
                }
                .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
                    timerTask?.cancel()
                    timerTask = nil
                    isVisible = false
                }
        }
    }

    private var tooltipCard: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .fixedSize()
    }
}

extension View {
    /// Liquid glass tooltip with 1s delay
    public func liquidGlassTooltip(_ text: String, delay: Double = 1.0) -> some View {
        modifier(LiquidGlassTooltipModifier(text: text, delay: delay))
    }
}
