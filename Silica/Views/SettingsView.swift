import SwiftUI

/// Settings (⌘,), styled with Droppy Code's clean, modern chrome:
/// an inset navigation sidebar, smooth animated transitions, unified cards, and refined typography.
struct SettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case general, fontsAndColors, editor, about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "General"
            case .fontsAndColors: "Fonts & Colors"
            case .editor: "Editor"
            case .about: "About"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape.fill"
            case .fontsAndColors: "textformat"
            case .editor: "text.cursor"
            case .about: "info"
            }
        }

        var tint: Color {
            switch self {
            case .general: Color(red: 0.556, green: 0.557, blue: 0.576)
            case .fontsAndColors: Color(red: 0.040, green: 0.478, blue: 1.000)
            case .editor: Color(red: 1.000, green: 0.584, blue: 0.000)
            case .about: Color(red: 0.204, green: 0.780, blue: 0.349)
            }
        }
    }

    var onClose: (() -> Void)? = nil
    @AppStorage(SettingsView.paneKey) private var pane: Pane = .general
    static let paneKey = "settingsTab"

    private static let sections: [[Pane]] = [[.general, .fontsAndColors, .editor], [.about]]

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar matching Droppy Code's sidebar layout
            VStack(alignment: .leading, spacing: 0) {
                if let onClose {
                    Button(action: onClose) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.left")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Back")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(Chrome.secondaryText)
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Chrome.overlay(0.05))
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.top, 14)
                    .padding(.bottom, 6)
                }

                Text("Settings")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Chrome.secondaryText)
                    .padding(.horizontal, 16)
                    .padding(.top, onClose == nil ? 16 : 4)
                    .padding(.bottom, 10)

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(Self.sections.enumerated()), id: \.offset) { sectionIndex, group in
                        if sectionIndex > 0 {
                            Divider()
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .opacity(0.4)
                        }
                        ForEach(group) { item in
                            SettingsNavRow(
                                title: item.title,
                                symbol: item.symbol,
                                tint: item.tint,
                                isSelected: pane == item
                            ) {
                                withAnimation(Chrome.panelSlide) {
                                    pane = item
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)

                Spacer(minLength: 0)
            }
            .frame(width: 210)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.4))

            Divider()
                .opacity(0.5)

            // Detail content column
            ScrollView {
                VStack(alignment: .leading, spacing: Chrome.sectionSpacing) {
                    Text(pane.title)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Chrome.primaryText)
                        .padding(.top, 4)

                    detail
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 4)),
                            removal: .opacity
                        ))
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 28)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.2))
        }
        .frame(minWidth: 640, idealWidth: 760, maxWidth: .infinity,
               minHeight: 480, idealHeight: 560, maxHeight: .infinity)
    }

    @ViewBuilder
    private var detail: some View {
        switch pane {
        case .general: GeneralSettingsPane().id(Pane.general)
        case .fontsAndColors: FontsAndColorsSettingsPane().id(Pane.fontsAndColors)
        case .editor: EditorSettingsPane().id(Pane.editor)
        case .about: AboutSettingsView().id(Pane.about)
        }
    }
}

/// An interactive sidebar nav row mirroring Droppy Code's smooth hover & selection physics.
struct SettingsNavRow: View {
    let title: String
    let symbol: String
    let tint: Color
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Chrome.rowCornerRadius, style: .continuous)
        Button(action: action) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(tint.gradient)
                    .frame(width: 20, height: 20)
                    .overlay {
                        Image(systemName: symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected || isHovering ? Chrome.primaryText : Chrome.secondaryText)
                    .lineLimit(1)

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8)
            .frame(height: Chrome.rowHeight)
            .background { shape.fill(fill) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Chrome.hover) { isHovering = hovering }
        }
    }

    private var fill: Color {
        if isSelected { return Chrome.overlay(0.12) }
        if isHovering { return Chrome.overlay(0.06) }
        return .clear
    }
}

/// Appearance, how projects open and show their files, and update checks.
private struct GeneralSettingsPane: View {
    @Bindable private var settings = EditorSettings.shared
    @ObservedObject private var updater = AppUpdater.shared
    @State private var commandPath = CommandLineTool.installedPath
    @State private var isInstallingCommand = false

    private let commandHint = "Open a project from the terminal with “silica .”, or a file with “silica <file>”."

    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.sectionSpacing) {
            ChromeSection(title: "Appearance") {
                ChromeCard {
                    ChromeRow(title: "Appearance", detail: "Overall color scheme of the application") {
                        Picker("Appearance", selection: $settings.appearance) {
                            Text("System").tag(EditorSettings.Appearance.system)
                            Text("Light").tag(EditorSettings.Appearance.light)
                            Text("Dark").tag(EditorSettings.Appearance.dark)
                        }
                        .labelsHidden()
                        .tabsPickerStyle()
                        .fixedSize()
                    }
                    ChromeRowDivider()
                    ChromeRow(title: "Window Background", detail: "Translucent vibrancy or solid backdrop") {
                        Picker("Background", selection: $settings.windowBackground) {
                            Text("Translucent").tag(EditorSettings.WindowBackground.translucent)
                            Text("Opaque").tag(EditorSettings.WindowBackground.opaque)
                        }
                        .labelsHidden()
                        .tabsPickerStyle()
                        .fixedSize()
                    }
                    if #available(macOS 26.0, *) {
                        ChromeRowDivider()
                        ChromeRow(title: "Glass Effect", detail: "Enable Liquid Glass surfaces") {
                            Toggle("Glass effect", isOn: $settings.usesGlassEffect)
                                .labelsHidden()
                        }
                    }
                }
            }

            ChromeSection(title: "Projects") {
                ChromeCard {
                    ChromeRow(title: "Restore Tabs", detail: "Reopen a project’s tabs where you left them") {
                        Toggle("Restore Tabs", isOn: $settings.restoresTabs)
                            .labelsHidden()
                    }
                    ChromeRowDivider()
                    ChromeRow(title: "Pin Parent Folders", detail: "Keep parent folders in view while scrolling the file tree") {
                        Toggle("Pin Folders", isOn: $settings.pinsParentFolders)
                            .labelsHidden()
                    }
                }
            }

            ChromeSection(
                title: "Command Line",
                footer: commandPath == nil ? CommandLineTool.unavailableReason ?? commandHint : commandHint
            ) {
                ChromeCard {
                    ChromeRow(title: "“\(CommandLineTool.name)” Command") {
                        if let commandPath {
                            Text("Installed in \((commandPath as NSString).deletingLastPathComponent)")
                                .font(.system(size: 12))
                                .foregroundStyle(Chrome.secondaryText)
                        } else {
                            Button("Install") {
                                isInstallingCommand = true
                                Task {
                                    await CommandLineTool.install()
                                    commandPath = CommandLineTool.installedPath
                                    isInstallingCommand = false
                                }
                            }
                            .controlSize(.small)
                            .disabled(isInstallingCommand || CommandLineTool.unavailableReason != nil)
                        }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                commandPath = CommandLineTool.installedPath
            }

            ChromeSection(title: "Updates") {
                ChromeCard {
                    ChromeRow(title: "Automatic Updates", detail: "Check for new versions automatically") {
                        Toggle("Check for updates", isOn: $updater.automaticallyChecksForUpdates)
                            .labelsHidden()
                    }
                    ChromeRowDivider()
                    ChromeRow(
                        title: "Current Version",
                        detail: "Version \(AppInfo.version) (\(AppInfo.build))"
                    ) {
                        Button("Check Now") { updater.checkForUpdates() }
                            .controlSize(.small)
                            .disabled(!updater.canCheckForUpdates)
                    }
                }
            }
        }
    }
}

/// Editor font and syntax colors, with a live sample, and the sidebar's font size.
private struct FontsAndColorsSettingsPane: View {
    @Bindable private var settings = EditorSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.sectionSpacing) {
            ChromeSection(title: "Font") {
                ChromeCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(highlightedSample)
                            .font(Font(settings.editorFont(ofSize: settings.fontSize)))
                            .lineLimit(5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.8))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Chrome.overlay(0.08), lineWidth: 0.5)
                            )
                    }
                    .padding(14)

                    ChromeRowDivider()

                    ChromeRow(title: "Font Family") {
                        Picker("Font", selection: fontFamily) {
                            Text("SF Mono (System)").tag("")
                            Divider()
                            ForEach(EditorSettings.monospacedFamilies, id: \.self) { family in
                                Text(family).tag(family)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }

                    ChromeRowDivider()

                    ChromeRow(title: "Size") {
                        HStack(spacing: 8) {
                            Text("\(Int(settings.fontSize)) pt")
                                .monospacedDigit()
                                .font(.system(size: 13))
                                .foregroundStyle(Chrome.secondaryText)
                            Stepper("Size", value: fontSize, in: EditorSettings.fontSizeRange, step: 1)
                                .labelsHidden()
                        }
                    }
                }
            }

            ChromeSection(title: "Sidebar") {
                ChromeCard {
                    ChromeRow(title: "Font Size") {
                        HStack(spacing: 8) {
                            Text("\(Int(settings.sidebarFontSize)) pt")
                                .monospacedDigit()
                                .font(.system(size: 13))
                                .foregroundStyle(Chrome.secondaryText)
                            Stepper("Sidebar size", value: $settings.sidebarFontSize,
                                    in: EditorSettings.sidebarFontSizeRange, step: 1)
                                .labelsHidden()
                        }
                    }
                }
            }

            ChromeSection(title: "Colors") {
                ChromeCard {
                    ChromeRow(title: "Syntax Theme") {
                        Picker("Syntax colors", selection: $settings.syntaxTheme) {
                            ForEach(SyntaxTheme.allCases) { theme in
                                Text(theme.name).tag(theme)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }
        }
    }

    private var sample: String {
        let indent = String(repeating: " ", count: settings.tabWidth)
        return "// Says hello.\nfunc greet(_ name: String) -> String {\n"
            + indent + "let count = 2\n"
            + indent + "return \"Hello, \\(name)!\"\n}"
    }

    private var highlightedSample: AttributedString {
        let text = sample
        var result = AttributedString(text)
        let theme = settings.syntaxTheme
        for token in SyntaxLanguage.swift.tokenizer.tokenize(text as NSString) {
            guard let range = Range(token.range, in: result) else { continue }
            result[range].foregroundColor = Color(nsColor: theme.color(for: token.kind))
        }
        return result
    }

    private var fontFamily: Binding<String> {
        Binding(
            get: { settings.fontFamily ?? "" },
            set: { settings.fontFamily = $0.isEmpty ? nil : $0 }
        )
    }

    private var fontSize: Binding<CGFloat> {
        Binding(
            get: { settings.fontSize },
            set: { settings.setFontSize($0) }
        )
    }
}

/// What the editor shows beside the text, and indentation for new files.
private struct EditorSettingsPane: View {
    @Bindable private var settings = EditorSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.sectionSpacing) {
            ChromeSection(title: "Display") {
                ChromeCard {
                    ChromeRow(title: "Line Numbers", detail: "Display line numbers in gutter") {
                        Toggle("Line Numbers", isOn: $settings.showsLineNumbers)
                            .labelsHidden()
                    }
                    ChromeRowDivider()
                    ChromeRow(title: "Indent Guides", detail: "Draw vertical indentation lines") {
                        Toggle("Indent Guides", isOn: $settings.showsIndentGuides)
                            .labelsHidden()
                    }
                    ChromeRowDivider()
                    ChromeRow(title: "Minimap", detail: "Show high-level document preview on the right") {
                        Toggle("Minimap", isOn: $settings.showsMinimap)
                            .labelsHidden()
                    }
                    ChromeRowDivider()
                    ChromeRow(title: "Wrap Lines", detail: "Soft-wrap long lines to fit the view") {
                        Toggle("Wrap Lines", isOn: $settings.wrapsLines)
                            .labelsHidden()
                    }
                }
            }

            ChromeSection(title: "Indentation", footer: "Files that are already indented keep their own style.") {
                ChromeCard {
                    ChromeRow(title: "Tab Width") {
                        Picker("Tab width", selection: $settings.tabWidth) {
                            ForEach(EditorSettings.tabWidths, id: \.self) { width in
                                Text("\(width) spaces").tag(width)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    ChromeRowDivider()
                    ChromeRow(title: "Indent New Files With") {
                        Picker("Indent new files with", selection: $settings.indentsWithTabs) {
                            Text("Spaces").tag(false)
                            Text("Tabs").tag(true)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }
        }
    }
}

private extension View {
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
