import AppKit
import SwiftUI

/// Shared UI tokens and styling building blocks for the application chrome.
enum Chrome {
    // MARK: Layout & Radius
    static let windowCornerRadius: CGFloat = 26
    static let cardCornerRadius: CGFloat = 16
    static let rowCornerRadius: CGFloat = 8
    static let iconSize: CGFloat = 16
    static let symbolSize: CGFloat = 14
    static let rowHeight: CGFloat = 32
    static let sectionSpacing: CGFloat = 20
    static let sectionHeaderSpacing: CGFloat = 10
    static let rowControlTrailingPadding: CGFloat = 10
    static let listInset: CGFloat = 10
    static let pageMaxWidth: CGFloat = 680
    static let pagePadding: CGFloat = 40

    // MARK: Colors & Materials
    static let primaryText = Color(nsColor: .labelColor)
    static let secondaryText = primaryText.opacity(0.70)
    static let accent = Color(nsColor: .controlAccentColor)

    static func overlay(_ opacity: Double) -> Color {
        primaryText.opacity(opacity)
    }

    // MARK: Animation & Physics
    static var hover: Animation { .easeOut(duration: 0.1) }

    static var panelSlide: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .easeOut(duration: 0.18)
            : .spring(response: 0.32, dampingFraction: 0.9)
    }

    static var softAppear: Animation { .smooth(duration: 0.32) }
}

// MARK: - Cards & Sections

/// A rounded, subtle card container for settings rows.
struct ChromeCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Chrome.cardCornerRadius, style: .continuous)
                .fill(Chrome.overlay(0.03))
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
            Text(verbatim: title)
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(Chrome.secondaryText)
                .padding(.leading, 4)

            content

            if let footer, !footer.isEmpty {
                Text(verbatim: footer)
                    .font(.system(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
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
                Text(verbatim: title)
                    .font(.system(.body))
                    .foregroundStyle(Chrome.primaryText)
                if let detail, !detail.isEmpty {
                    Text(verbatim: detail)
                        .font(.system(.subheadline))
                        .foregroundStyle(Chrome.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.leading, 16)
        .padding(.trailing, Chrome.rowControlTrailingPadding)
        .padding(.vertical, 11)
    }
}

/// A clean hairline divider inset to align with card text.
struct ChromeRowDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 16)
    }
}

/// A native macOS switch toggle.
struct SettingsSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
    }
}

/// A search field capsule for sidebar navigation.
struct SidebarSearchField: View {
    @Binding var text: String
    var prompt = "Search"
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(.callout, weight: .medium))
                .foregroundStyle(Chrome.secondaryText.opacity(0.85))
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(.body))
                .frame(maxWidth: .infinity)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(.callout))
                        .foregroundStyle(Chrome.secondaryText.opacity(0.75))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background {
            Capsule(style: .continuous).fill(Chrome.overlay(0.07))
        }
        .contentShape(Capsule(style: .continuous))
        .onExitCommand { text = "" }
    }
}
