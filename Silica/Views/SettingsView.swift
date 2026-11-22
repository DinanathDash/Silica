import SwiftUI
import UniformTypeIdentifiers

/// Settings (⌘,), with sidebar layout, typography,
/// metrics, native switch toggles, and centered detail content.
struct SettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case general, fontsAndColors, editor, sourceControl, about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "General"
            case .fontsAndColors: "Fonts & Colors"
            case .editor: "Editor"
            case .sourceControl: "Git Controls"
            case .about: "About"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .fontsAndColors: "paintpalette"
            case .editor: "text.cursor"
            case .sourceControl: "arrow.triangle.branch"
            case .about: "info.circle"
            }
        }

        var keywords: [String] {
            switch self {
            case .general: ["appearance", "theme", "dark", "light", "background", "translucent", "opaque", "glass", "restore", "tabs", "command line", "silica", "update", "terminal", "notifications", "logs", "diagnostics"]
            case .fontsAndColors: ["font", "size", "colors", "syntax", "theme", "sidebar", "family", "monospaced", "code"]
            case .editor: ["lines", "line numbers", "indent", "guides", "minimap", "wrap", "tab width", "spaces"]
            case .sourceControl: ["git", "github", "commit", "messages", "pull request", "branch", "clone", "controls"]
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
            // Sidebar navigation
            VStack(alignment: .leading, spacing: 0) {
                // Room for window traffic lights
                Color.clear
                    .frame(height: WorkspaceLayout.titleBarHeight)

                if let onClose {
                    SettingsNavRow(title: "Back", isSelected: false, action: onClose) {
                        Image(systemName: "arrow.left")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .liquidGlassTooltip("Back to your editor")
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

            // Centered Settings Detail Pane
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
        case .sourceControl: GitControlsSettingsPane().id(Pane.sourceControl)
        case .about: AboutSettingsView().id(Pane.about)
        }
    }
}

/// One row of the Settings page list:
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
                            .glassButtonStyle()
                            .controlSize(.small)
                            .disabled(isInstallingCommand || CommandLineTool.unavailableReason != nil)
                        }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                commandPath = CommandLineTool.installedPath
            }

            ChromeSection(title: "Terminal & Notifications") {
                ChromeCard {
                    ChromeRow(
                        title: "Command notifications",
                        detail: "Show toast notifications when terminal commands finish or fail"
                    ) {
                        SettingsSwitch(isOn: $settings.terminalCommandNotifications)
                    }
                }
            }

            ChromeSection(
                title: "Diagnostics & Logs",
                footer: "Silica maintains low-overhead, rolling diagnostic logs automatically purged after 7 days."
            ) {
                ChromeCard {
                    ChromeRow(
                        title: "Reveal logs in Finder",
                        detail: "Inspect local application logs and crash traces"
                    ) {
                        Button("Reveal") {
                            AppLogger.revealLogInFinder()
                        }
                        .glassButtonStyle()
                        .controlSize(.small)
                    }
                    ChromeRowDivider()
                    ChromeRow(
                        title: "Export logs",
                        detail: "Save a snapshot of application diagnostics to a file"
                    ) {
                        Button("Export…") {
                            exportLogsPrompt()
                        }
                        .glassButtonStyle()
                        .controlSize(.small)
                    }
                }
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
                            .glassButtonStyle()
                            .controlSize(.small)
                            .disabled(!updater.canCheckForUpdates)
                    }
                }
            }
        }
    }

    private func exportLogsPrompt() {
        let savePanel = NSSavePanel()
        savePanel.title = "Export Silica Logs"
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        savePanel.nameFieldStringValue = "silica-\(timestamp).log"
        savePanel.canCreateDirectories = true
        savePanel.allowedContentTypes = [.plainText]

        guard savePanel.runModal() == .OK, let destinationURL = savePanel.url else { return }
        try? AppLogger.exportLogs(to: destinationURL)
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

            ChromeSection(title: "Saving") {
                ChromeCard {
                    ChromeRow(title: "Auto-save on edit", detail: "Automatically save files after typing changes") {
                        SettingsSwitch(isOn: $settings.autoSaveOnEdit)
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

/// Git Controls preferences: GitHub connection and git integration matching droppy-code.
private struct GitControlsSettingsPane: View {
    @Bindable private var settings = EditorSettings.shared
    private var gitHub = GitHubProfileCache.shared
    @State private var gitVersion: String = ""
    @State private var cloneDirectory: String = UserDefaults.standard.string(forKey: "GitHubCloneDirectory") ?? ("~/Documents/Projects" as NSString).expandingTildeInPath

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.sectionSpacing) {
            // 1. GitHub Section
            ChromeSection(title: "GitHub") {
                ChromeCard {
                    if let user = gitHub.user {
                        HStack(spacing: 12) {
                            CachedAvatarView(
                                url: gitHub.avatarURL ?? URL(string: "https://github.com/\(user).png?size=96"),
                                fallbackText: String(user.prefix(1)).uppercased(),
                                fallbackColor: .accentColor
                            )
                            .frame(width: 32, height: 32)


                            VStack(alignment: .leading, spacing: 2) {
                                Text(gitHub.displayName ?? user)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Chrome.primaryText)
                                Text("@\(user), using the GitHub CLI login")
                                    .font(.subheadline)
                                    .foregroundStyle(Chrome.secondaryText)
                            }

                            Spacer(minLength: 12)

                            Button("Refresh") {
                                Task { await gitHub.checkStatus(force: true) }
                            }
                            .glassButtonStyle()
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)

                        ChromeRowDivider()

                        ChromeRow(title: "Clone a repository", detail: "Clone one of your repositories and open in Silica.") {
                            Button("Clone…") {
                                showClonePrompt()
                            }
                            .glassButtonStyle()
                            .controlSize(.small)
                        }

                        ChromeRowDivider()

                        ChromeRow(title: "Clone into", detail: (cloneDirectory as NSString).abbreviatingWithTildeInPath) {
                            Button("Change…") {
                                chooseCloneDirectory()
                            }
                            .glassButtonStyle()
                            .controlSize(.small)
                        }
                    } else if gitHub.isChecking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Checking GitHub connection…").foregroundStyle(Chrome.secondaryText)
                        }
                        .padding(16)
                    } else {
                        ChromeRow(title: "Connect GitHub", detail: "Clone your repositories and let Silica push and open pull requests.") {
                            Button("Open GitHub") {
                                if let url = URL(string: "https://github.com") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .glassButtonStyle()
                            .controlSize(.small)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Log in with GitHub CLI in terminal: `gh auth login`")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Chrome.secondaryText)
                            Button("Check Status") {
                                Task { await gitHub.checkStatus(force: true) }
                            }
                            .glassButtonStyle()
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 11)
                    }
                }
            }

            // 2. Git Integration
            ChromeSection(title: "Git Integration") {
                ChromeCard {
                    ChromeRow(
                        title: "Git Version",
                        detail: gitVersion.isEmpty ? "Checking system git…" : gitVersion
                    ) {
                        EmptyView()
                    }
                    ChromeRowDivider()
                    ChromeRow(
                        title: "Pull requests",
                        detail: "Opened with GitHub CLI (gh) or GitLab CLI (glab) from your PATH."
                    ) {
                        EmptyView()
                    }
                }
            }
        }
        .task {
            loadGitVersion()
            await gitHub.checkStatus(force: false)
        }
    }

    private func loadGitVersion() {
        Task {
            let res = await GitRunner.shared.run(arguments: ["--version"], in: URL(filePath: NSHomeDirectory()))
            await MainActor.run {
                gitVersion = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    private func chooseCloneDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Select"
        panel.message = "Choose default folder to clone GitHub repositories into"
        if panel.runModal() == .OK, let url = panel.url {
            let path = url.path(percentEncoded: false)
            self.cloneDirectory = path
            UserDefaults.standard.set(path, forKey: "GitHubCloneDirectory")
        }
    }

    private func showClonePrompt() {
        let alert = NSAlert()
        alert.messageText = "Clone from GitHub"
        alert.informativeText = "Enter repository URL (e.g., https://github.com/owner/repo) or repository name (owner/repo):"
        alert.addButton(withTitle: "Clone")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.placeholderString = "owner/repo"
        alert.accessoryView = input

        if alert.runModal() == .alertFirstButtonReturn {
            let repoStr = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !repoStr.isEmpty else { return }
            let fullURL = repoStr.hasPrefix("https://") || repoStr.hasPrefix("git@")
                ? repoStr
                : "https://github.com/\(repoStr).git"
            let repoName = (repoStr as NSString).lastPathComponent.replacingOccurrences(of: ".git", with: "")
            let targetDir = URL(filePath: cloneDirectory).appendingPathComponent(repoName)

            Task {
                let res = await GitRunner.shared.run(arguments: ["clone", fullURL, targetDir.path(percentEncoded: false)], in: URL(filePath: cloneDirectory))
                await MainActor.run {
                    if res.isSuccess {
                        ProjectOpener(openWindow: openWindow).open(url: targetDir)
                    } else {
                        let errAlert = NSAlert()
                        errAlert.alertStyle = .warning
                        errAlert.messageText = "Clone Failed"
                        errAlert.informativeText = res.stderr.isEmpty ? "Could not clone repository." : res.stderr
                        errAlert.runModal()
                    }
                }
            }
        }
    }
}

/// In-memory and persistent cache for the authenticated GitHub user profile.
@MainActor @Observable
final class GitHubProfileCache {
    static let shared = GitHubProfileCache()

    var user: String? {
        didSet { UserDefaults.standard.set(user, forKey: "cachedGitHubUser") }
    }
    var displayName: String? {
        didSet { UserDefaults.standard.set(displayName, forKey: "cachedGitHubDisplayName") }
    }
    var avatarURL: URL? {
        didSet { UserDefaults.standard.set(avatarURL?.absoluteString, forKey: "cachedGitHubAvatarURL") }
    }
    var isChecking = false

    init() {
        self.user = UserDefaults.standard.string(forKey: "cachedGitHubUser")
        self.displayName = UserDefaults.standard.string(forKey: "cachedGitHubDisplayName")
        if let str = UserDefaults.standard.string(forKey: "cachedGitHubAvatarURL") {
            self.avatarURL = URL(string: str)
        }
    }

    func checkStatus(force: Bool = false) async {
        guard !isChecking else { return }
        if !force, user != nil { return }
        isChecking = true
        defer { isChecking = false }

        let res = await GitRunner.shared.runGH(arguments: ["auth", "status"], in: URL(filePath: NSHomeDirectory()))
        let output = res.stdout + res.stderr
        var foundUser: String?
        if let range = output.range(of: "account ") {
            let sub = output[range.upperBound...]
            let username = sub.split(separator: " ").first?.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if let username, !username.isEmpty {
                foundUser = username
            }
        }

        var foundAvatarURL: URL?
        var foundName: String?

        let apiRes = await GitRunner.shared.runGH(arguments: ["api", "user"], in: URL(filePath: NSHomeDirectory()))
        if apiRes.isSuccess, let data = apiRes.stdout.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let login = json["login"] as? String, !login.isEmpty {
                foundUser = login
            }
            if let name = json["name"] as? String, !name.isEmpty {
                foundName = name
            }
            if let avatarStr = json["avatar_url"] as? String, let url = URL(string: avatarStr) {
                foundAvatarURL = url
            }
        }

        if foundAvatarURL == nil, let user = foundUser {
            foundAvatarURL = URL(string: "https://github.com/\(user).png?size=96")
        }

        self.user = foundUser
        self.avatarURL = foundAvatarURL
        self.displayName = foundName
    }
}

