import SwiftUI

/// Settings (⌘,), completely redesigned to match Droppy Code's architecture, typography,
/// metrics, native switch toggles, and centered detail content.
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
            case .general: "gearshape"
            case .fontsAndColors: "paintpalette"
            case .editor: "text.cursor"
            case .about: "info.circle"
            }
        }

        var keywords: [String] {
            switch self {
            case .general: ["appearance", "theme", "dark", "light", "background", "translucent", "opaque", "glass", "restore", "tabs", "command line", "silica", "update"]
            case .fontsAndColors: ["font", "size", "colors", "syntax", "theme", "sidebar", "family", "monospaced", "code"]
            case .editor: ["lines", "line numbers", "indent", "guides", "minimap", "wrap", "tab width", "spaces"]
            case .about: ["version", "build", "license", "acknowledgements", "copyright", "sparkle", "ghostty"]
            }
        }
    }

    var onClose: (() -> Void)? = nil
    @AppStorage(SettingsView.paneKey) private var pane: Pane = .general
    @State private var search = ""
    static let paneKey = "settingsTab"

    private var visiblePages: [Pane] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Pane.allCases }
        return Pane.allCases.filter { page in
            page.title.localizedCaseInsensitiveContains(query)
                || page.keywords.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar matching Droppy Code's SettingsSidebar
            VStack(alignment: .leading, spacing: 0) {
                // Room for window traffic lights
                Color.clear
                    .frame(height: WorkspaceLayout.titleBarHeight)

                if let onClose {
                    SettingsNavRow(title: "Back", isSelected: false, action: onClose) {
                        Image(systemName: "arrow.left")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .help("Back to your editor")
                    .padding(.horizontal, Chrome.listInset)
                    .padding(.top, 6)
                }

                SidebarSearchField(text: $search) {
                    if let first = visiblePages.first { pane = first }
                }
                .padding(.horizontal, Chrome.listInset)
                .padding(.top, onClose == nil ? 14 : 8)

                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(visiblePages) { item in
                            SettingsNavRow(
                                title: item.title,
                                isSelected: pane == item,
                                action: {
                                    withAnimation(Chrome.panelSlide) {
                                        pane = item
                                    }
                                }
                            ) {
                                Image(systemName: item.symbol)
                                    .resizable()
                                    .interpolation(.high)
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: Chrome.symbolSize, height: Chrome.symbolSize)
                                    .frame(width: Chrome.iconSize, height: Chrome.iconSize)
                            }
                            // Gap before About
                            .padding(.top, item == .about && search.isEmpty ? 14 : 0)
                        }

                        if visiblePages.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("No results")
                                    .font(.system(.body, weight: .semibold))
                                    .foregroundStyle(Chrome.primaryText.opacity(0.92))
                                Text("Try a setting or preference name.")
                                    .font(.system(.subheadline))
                                    .foregroundStyle(Chrome.secondaryText)
                            }
                            .padding(.horizontal, 8)
                            .padding(.top, 14)
                        }
                    }
                    .padding(.horizontal, Chrome.listInset)
                    .padding(.top, 12)
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.never)
            }
            .frame(width: 210)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.4))
            .onChange(of: visiblePages) { _, pages in
                guard !pages.isEmpty, !pages.contains(pane), let first = pages.first else { return }
                pane = first
            }

            Divider()
                .opacity(0.4)

            // Centered Settings Detail Pane matching Droppy Code's SettingsDetail
            ScrollView {
                VStack(alignment: .leading, spacing: Chrome.sectionSpacing) {
                    Text(verbatim: pane.title)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Chrome.primaryText)
                        .accessibilityAddTraits(.isHeader)

                    detail
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 4)),
                            removal: .opacity
                        ))
                }
                .frame(maxWidth: Chrome.pageMaxWidth, alignment: .leading)
                .padding(.horizontal, Chrome.pagePadding)
                .frame(maxWidth: .infinity)
                .padding(.top, 28)
                .padding(.bottom, 48)
            }
            .scrollIndicators(.never)
            .id(pane)
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

/// One row of the Settings page list matching Droppy Code's `SettingsNavRow`:
/// 8pt continuous corner radius, 32pt height, and smooth hover fill.
struct SettingsNavRow<Icon: View>: View {
    static var iconSize: CGFloat { 15 }

    let title: String
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let icon: Icon

    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let text = isSelected || isHovering ? Chrome.primaryText : Chrome.secondaryText
        Button(action: action) {
            HStack(spacing: 8) {
                icon
                    .frame(width: Chrome.iconSize, height: Chrome.iconSize)
                Text(verbatim: title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
            }
            .foregroundStyle(text)
            .padding(.horizontal, 8)
            .frame(minHeight: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { shape.fill(fill) }
            .contentShape(shape)
            .animation(Chrome.hover, value: isSelected)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Chrome.hover) { isHovering = hovering }
        }
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
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
                    ChromeRow(title: "Window background", detail: "Translucent vibrancy or solid backdrop") {
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
                        ChromeRow(title: "Glass effect", detail: "Liquid Glass behind cards, tabs and buttons") {
                            SettingsSwitch(isOn: $settings.usesGlassEffect)
                        }
                    }
                }
            }

            ChromeSection(title: "Projects") {
                ChromeCard {
                    ChromeRow(title: "Restore open tabs", detail: "Reopen a project’s tabs where you left them") {
                        SettingsSwitch(isOn: $settings.restoresTabs)
                    }
                    ChromeRowDivider()
                    ChromeRow(title: "Pin parent folders", detail: "Keep parent folders in view while scrolling the file tree") {
                        SettingsSwitch(isOn: $settings.pinsParentFolders)
                    }
                }
            }

            ChromeSection(
                title: "Command line",
                footer: commandPath == nil ? CommandLineTool.unavailableReason ?? commandHint : commandHint
            ) {
                ChromeCard {
                    ChromeRow(title: "“\(CommandLineTool.name)” command") {
                        if let commandPath {
                            Text(verbatim: "Installed in \((commandPath as NSString).deletingLastPathComponent)")
                                .font(.system(.subheadline))
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
                    ChromeRow(title: "Check for updates automatically", detail: "Check for new versions once a day") {
                        SettingsSwitch(isOn: $updater.automaticallyChecksForUpdates)
                    }
                    ChromeRowDivider()
                    ChromeRow(
                        title: "Current version",
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

                    ChromeRow(title: "Font family") {
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
                            Text(verbatim: "\(Int(settings.fontSize)) pt")
                                .monospacedDigit()
                                .font(.system(.body))
                                .foregroundStyle(Chrome.secondaryText)
                            Stepper("Size", value: fontSize, in: EditorSettings.fontSizeRange, step: 1)
                                .labelsHidden()
                        }
                    }
                }
            }

            ChromeSection(title: "Sidebar") {
                ChromeCard {
                    ChromeRow(title: "Font size") {
                        HStack(spacing: 8) {
                            Text(verbatim: "\(Int(settings.sidebarFontSize)) pt")
                                .monospacedDigit()
                                .font(.system(.body))
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
                    ChromeRow(title: "Syntax colors") {
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
                    ChromeRow(title: "Show line numbers", detail: "Display line numbers in the editor gutter") {
                        SettingsSwitch(isOn: $settings.showsLineNumbers)
                    }
                    ChromeRowDivider()
                    ChromeRow(title: "Show indent guides", detail: "Draw vertical indentation guide lines") {
                        SettingsSwitch(isOn: $settings.showsIndentGuides)
                    }
                    ChromeRowDivider()
                    ChromeRow(title: "Show minimap", detail: "High-level file overview down the editor’s right edge") {
                        SettingsSwitch(isOn: $settings.showsMinimap)
                    }
                    ChromeRowDivider()
                    ChromeRow(title: "Wrap long lines", detail: "Wrap lines to editor width instead of scrolling sideways") {
                        SettingsSwitch(isOn: $settings.wrapsLines)
                    }
                }
            }

            ChromeSection(title: "Indentation", footer: "Files that are already indented keep their own style.") {
                ChromeCard {
                    ChromeRow(title: "Tab width") {
                        Picker("Tab width", selection: $settings.tabWidth) {
                            ForEach(EditorSettings.tabWidths, id: \.self) { width in
                                Text("\(width) spaces").tag(width)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    ChromeRowDivider()
                    ChromeRow(title: "Indent new files with") {
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
