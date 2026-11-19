import AppKit
import SwiftUI

/// Shared UI tokens and styling building blocks adapted from Droppy Code's design system.
enum Chrome {
    // MARK: Layout & Radius
    static let windowCornerRadius: CGFloat = 20
    static let cardCornerRadius: CGFloat = 14
    static let rowCornerRadius: CGFloat = 8
    static let iconSize: CGFloat = 18
    static let rowHeight: CGFloat = 32
    static let sectionSpacing: CGFloat = 22
    static let sectionHeaderSpacing: CGFloat = 8
    static let rowControlTrailingPadding: CGFloat = 12

    // MARK: Colors & Materials
    static let primaryText = Color(nsColor: .labelColor)
    static let secondaryText = primaryText.opacity(0.68)
    static let accent = Color(nsColor: .controlAccentColor)

    static func overlay(_ opacity: Double) -> Color {
        primaryText.opacity(opacity)
    }

    // MARK: Animation & Physics
    static var hover: Animation { .easeOut(duration: 0.12) }

    static var panelSlide: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .easeOut(duration: 0.18)
            : .spring(response: 0.32, dampingFraction: 0.88)
    }

    static var softAppear: Animation { .smooth(duration: 0.28) }
}

// MARK: - Cards & Sections

/// A rounded, subtle card container matching Droppy Code's Settings cards.
struct ChromeCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Chrome.cardCornerRadius, style: .continuous)
                .fill(Chrome.overlay(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Chrome.cardCornerRadius, style: .continuous)
                .strokeBorder(Chrome.overlay(0.06), lineWidth: 0.5)
        )
    }
}

/// A titled section with optional accessory and trailing controls.
struct ChromeSection<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.sectionHeaderSpacing) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Chrome.secondaryText)
                .textCase(.uppercase)
                .tracking(0.5)
                .padding(.leading, 4)

            content

            if let footer, !footer.isEmpty {
                Text(footer)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Chrome.secondaryText.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 4)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A structured row with a title, optional detail subtitle, and trailing control.
struct ChromeRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Chrome.primaryText)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Chrome.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.leading, 16)
        .padding(.trailing, Chrome.rowControlTrailingPadding)
        .padding(.vertical, 10)
    }
}

/// A clean hairline divider inset to align with card text.
struct ChromeRowDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 16)
            .opacity(0.5)
    }
}
