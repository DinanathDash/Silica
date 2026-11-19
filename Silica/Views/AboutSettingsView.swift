import AppKit
import SwiftUI

/// Settings › About: the app's name, version and copyright, and the licenses of
/// the open-source code it ships with.
struct AboutSettingsView: View {
    @State private var shownLicense: Acknowledgement?

    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.sectionSpacing) {
            ChromeCard {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(AppInfo.name)
                            .font(.system(.title3, weight: .semibold))
                            .foregroundStyle(Chrome.primaryText)
                        Text(verbatim: "Version \(AppInfo.version) (\(AppInfo.build))")
                            .font(.system(.callout))
                            .foregroundStyle(Chrome.secondaryText)
                            .textSelection(.enabled)
                    }
                    Spacer()
                }
                .padding(16)
                if let copyright = AppInfo.copyright {
                    ChromeRowDivider()
                    Text(copyright)
                        .font(.system(.callout))
                        .foregroundStyle(Chrome.secondaryText)
                        .padding(.leading, 16)
                        .padding(.trailing, Chrome.rowControlTrailingPadding)
                        .padding(.vertical, 11)
                }
            }

            ChromeSection(
                title: "Acknowledgements",
                footer: "Silica’s Markdown preview, terminal emulation and updates are built on these open-source projects."
            ) {
                ChromeCard {
                    ForEach(Array(Acknowledgement.all.enumerated()), id: \.element.id) { index, acknowledgement in
                        if index > 0 { ChromeRowDivider() }
                        ChromeRow(
                            title: acknowledgement.name,
                            detail: "\(acknowledgement.license) · \(acknowledgement.holder)"
                        ) {
                            Button("View License") { shownLicense = acknowledgement }
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
        .sheet(item: $shownLicense) { acknowledgement in
            LicenseSheet(acknowledgement: acknowledgement)
        }
    }
}

/// The full license text of one project, scrollable and selectable.
private struct LicenseSheet: View {
    let acknowledgement: Acknowledgement
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(acknowledgement.name)
                    .font(.headline)
                Spacer()
                Link("Website", destination: acknowledgement.website)
            }
            ScrollView {
                Text(acknowledgement.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.05)))
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
    }
}

/// An open-source project Silica includes, with its license files in
/// Resources/Licenses (copied as they are; the licenses require that).
struct Acknowledgement: Identifiable {
    let name: String
    let license: String
    let holder: String
    let website: URL
    /// Resource names (.txt) of its license and notice files, in order.
    let files: [String]

    var id: String { name }

    var text: String {
        files
            .compactMap { Bundle.main.url(forResource: $0, withExtension: "txt") }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n\n" + String(repeating: "─", count: 60) + "\n\n")
    }

    static let all: [Acknowledgement] = [
        Acknowledgement(
            name: "swift-markdown",
            license: "Apache License 2.0",
            holder: "Apple Inc. and the Swift project authors",
            website: URL(string: "https://github.com/swiftlang/swift-markdown")!,
            files: ["swift-markdown-LICENSE", "swift-markdown-NOTICE"]
        ),
        Acknowledgement(
            name: "swift-cmark (cmark-gfm)",
            license: "BSD 2-Clause and others",
            holder: "John MacFarlane, GitHub, Inc.",
            website: URL(string: "https://github.com/swiftlang/swift-cmark")!,
            files: ["swift-cmark-COPYING"]
        ),
        Acknowledgement(
            name: "Sparkle",
            license: "MIT License and others",
            holder: "Andy Matuschak and the Sparkle Project contributors",
            website: URL(string: "https://sparkle-project.org")!,
            files: ["Sparkle-LICENSE"]
        ),
        Acknowledgement(
            name: "libghostty-vt",
            license: "MIT License",
            holder: "Mitchell Hashimoto and the Ghostty contributors",
            website: URL(string: "https://ghostty.org")!,
            files: ["ghostty-LICENSE"]
        ),
    ]
}

/// Name, version and copyright from Info.plist.
enum AppInfo {
    private static func value(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }

    static var name: String { value("CFBundleName") ?? "Silica" }
    static var version: String { value("CFBundleShortVersionString") ?? "—" }
    static var build: String { value("CFBundleVersion") ?? "—" }
    static var copyright: String? { value("NSHumanReadableCopyright") }
}
