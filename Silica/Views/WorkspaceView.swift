import AppKit
import SwiftUI

/// Window root for a workspace: resolves the project bookmark, then shows the editor.
struct WorkspaceWindow: View {
    let projectID: RecentProject.ID?

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.dismiss) private var dismiss
    @State private var workspace: WorkspaceModel?
    @State private var errorMessage: String?

    @MainActor private static var openCount = 0

    var body: some View {
        Group {
            if let workspace {
                WorkspaceView(workspace: workspace)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Can’t Open Project", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Open Project…") { ProjectOpener(openWindow: openWindow).chooseAndOpen() }
                        .glassButtonStyle(prominent: true)
                }
                .frame(minWidth: 500, minHeight: 360)
            } else {
                // Must be a real view: onAppear doesn't fire on an empty Group.
                ProgressView()
                    .frame(minWidth: 500, minHeight: 360)
            }
        }
        .onAppear {
            ExternalOpener.shared.openWindow = openWindow
            Self.openCount += 1
            dismissWindow(id: WindowID.welcome)
            load()
        }
        .onDisappear {
            if let workspace, KeyWorkspace.shared.current === workspace {
                KeyWorkspace.shared.current = nil
            }
            if let workspace { ExternalOpener.shared.workspaceDidClose(workspace) }
            workspace?.close()
            Self.openCount -= 1
            if Self.openCount == 0 {
                openWindow(id: WindowID.welcome)
            }
        }
    }

    private func load() {
        guard workspace == nil else { return }
        guard let projectID else {
            // e.g. a restored window that never had a project: just close it.
            dismiss()
            return
        }
        do {
            let url = try RecentProjectsStore.shared.resolveURL(for: projectID)
            let workspace = WorkspaceModel(rootURL: url)
            self.workspace = workspace
            ExternalOpener.shared.workspaceDidOpen(workspace, projectID: projectID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

enum WorkspaceLayout {
    /// Height of the title bar row that holds the traffic lights and the tabs.
    static let titleBarHeight: CGFloat = 36
    /// Room for the traffic lights when the sidebar is hidden.
    static let trafficLightsWidth: CGFloat = 78
    /// Smallest corner radius of the editor card; corners near the window's are concentric with it.
    static let cardCornerRadius: CGFloat = 10
    static let cardInset: CGFloat = 6
    /// How much of the sidebar list's built-in top inset to hide.
    static let sidebarListTopTrim: CGFloat = 8
    static let sidebarWidthRange: ClosedRange<Double> = 220...480
    static let sourceControlWidthRange: ClosedRange<Double> = 290...540
    static let sourceControlCollapseThreshold: Double = 290
    static let sourceControlDefaultWidth: Double = 310
    static let editorMinWidth: CGFloat = 420
    /// Fits the narrowest sidebar beside the narrowest editor.
    static let windowMinWidth: CGFloat = sidebarWidthRange.lowerBound + editorMinWidth
    static let terminalHeightRange: ClosedRange<Double> = 100...1200
    /// What the terminal card leaves of the editor card at the least.
    static let minimumEditorHeight: CGFloat = 120
}

struct WorkspaceView: View {
    @Bindable var workspace: WorkspaceModel
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 260
    @AppStorage("sourceControlWidth") private var sourceControlWidth: Double = WorkspaceLayout.sourceControlDefaultWidth
    @State private var dragStartWidth: Double?
    @State private var dragStartSourceControlWidth: Double?
    @State private var windowWidth: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            if workspace.isSidebarVisible {
                FileTreeView(workspace: workspace)
                    .frame(width: shownSidebarWidth)
                    .overlay(alignment: .trailing) { resizeHandle }
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            EditorArea(workspace: workspace)
            if workspace.isSourceControlVisible {
                HStack(spacing: 0) {
                    sourceControlResizeHandle
                    SourceControlView(workspace: workspace, model: workspace.sourceControl)
                        .padding(.top, 4)
                        .padding(.trailing, max(0, WorkspaceLayout.cardInset - 2))
                        .padding(.bottom, WorkspaceLayout.cardInset)
                        .frame(width: shownSourceControlWidth)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .opacity(workspace.isSettingsVisible ? 0 : 1)
        .allowsHitTesting(!workspace.isSettingsVisible)
        .accessibilityHidden(workspace.isSettingsVisible)
        .overlay {
            if workspace.isSettingsVisible {
                SettingsView(onClose: { workspace.hideSettings() })
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.98).combined(with: .opacity),
                        removal: .scale(scale: 0.98).combined(with: .opacity)
                    ))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .animation(Chrome.panelSlide, value: workspace.isSettingsVisible)
        .ignoresSafeArea(.container, edges: .top)
        .overlay {
            if workspace.isQuickOpenVisible {
                QuickOpenOverlay(workspace: workspace)
            }
        }
        .frame(minWidth: WorkspaceLayout.windowMinWidth, minHeight: 400)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { newWidth in
            windowWidth = newWidth
            if workspace.isSourceControlVisible && newWidth > 0 {
                let maxAvailable = newWidth - WorkspaceLayout.editorMinWidth - (workspace.isSidebarVisible ? shownSidebarWidth : 0)
                if maxAvailable < WorkspaceLayout.sourceControlCollapseThreshold {
                    workspace.hideSourceControl()
                }
            }
        }
        .containerBackground(for: .window) {
            WindowBackgroundView()
        }
        .navigationTitle(workspace.name)
        .background(KeyWindowTracker(workspace: workspace))
        .background(UnsavedChangesGuard(workspace: workspace, hasUnsavedChanges: workspace.hasUnsavedChanges))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            workspace.refresh()
        }
    }

    /// The widest the sidebar can be while the editor keeps its minimum width.
    private var widestSidebar: Double {
        let range = WorkspaceLayout.sidebarWidthRange
        // Before the first layout pass there's no width to go by.
        guard windowWidth > 0 else { return range.upperBound }
        return min(max(windowWidth - WorkspaceLayout.editorMinWidth, range.lowerBound), range.upperBound)
    }

    /// The stored width, narrowed while the window is too small for it. The stored
    /// width is kept, so the sidebar grows back when the window does.
    private var shownSidebarWidth: Double {
        min(max(sidebarWidth, WorkspaceLayout.sidebarWidthRange.lowerBound), widestSidebar)
    }

    /// Invisible strip on the sidebar's trailing edge that resizes it.
    private var resizeHandle: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(.rect)
            .offset(x: 4)
            .pointerStyle(.frameResize(position: .trailing))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartWidth ?? shownSidebarWidth
                        dragStartWidth = start
                        let proposed = start + value.translation.width
                        if proposed < WorkspaceLayout.sidebarWidthRange.lowerBound - 40 {
                            workspace.toggleSidebar()
                            dragStartWidth = nil
                            sidebarWidth = max(start, WorkspaceLayout.sidebarWidthRange.lowerBound)
                            return
                        }
                        sidebarWidth = min(max(proposed, WorkspaceLayout.sidebarWidthRange.lowerBound), widestSidebar)
                    }
                    .onEnded { value in
                        if let start = dragStartWidth {
                            let proposed = start + value.translation.width
                            if proposed < WorkspaceLayout.sidebarWidthRange.lowerBound - 40 {
                                workspace.toggleSidebar()
                                sidebarWidth = max(start, WorkspaceLayout.sidebarWidthRange.lowerBound)
                            }
                        }
                        dragStartWidth = nil
                    }
            )
    }

    /// The clamped width of the right-side source control sidebar.
    private var shownSourceControlWidth: Double {
        let range = WorkspaceLayout.sourceControlWidthRange
        guard windowWidth > 0 else { return max(sourceControlWidth, range.lowerBound) }
        let maxAvailable = max(windowWidth - WorkspaceLayout.editorMinWidth - (workspace.isSidebarVisible ? shownSidebarWidth : 0), range.lowerBound)
        return min(max(sourceControlWidth, range.lowerBound), min(maxAvailable, range.upperBound))
    }

    /// Resize handle for the source control sidebar on its leading edge.
    private var sourceControlResizeHandle: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(.rect)
            .offset(x: -4)
            .pointerStyle(.frameResize(position: .leading))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartSourceControlWidth ?? shownSourceControlWidth
                        dragStartSourceControlWidth = start
                        let proposed = start - value.translation.width
                        if proposed < WorkspaceLayout.sourceControlCollapseThreshold {
                            workspace.hideSourceControl()
                            dragStartSourceControlWidth = nil
                            sourceControlWidth = max(start, WorkspaceLayout.sourceControlDefaultWidth)
                            return
                        }
                        sourceControlWidth = min(max(proposed, WorkspaceLayout.sourceControlWidthRange.lowerBound), WorkspaceLayout.sourceControlWidthRange.upperBound)
                    }
                    .onEnded { value in
                        if let start = dragStartSourceControlWidth {
                            let proposed = start - value.translation.width
                            if proposed < WorkspaceLayout.sourceControlCollapseThreshold {
                                workspace.hideSourceControl()
                                sourceControlWidth = max(start, WorkspaceLayout.sourceControlDefaultWidth)
                            }
                        }
                        dragStartSourceControlWidth = nil
                    }
            )
    }
}

struct SidebarToggleButton: View {
    let workspace: WorkspaceModel

    var body: some View {
        Button {
            workspace.toggleSidebar()
        } label: {
            Image(systemName: "sidebar.left")
        }
        // Same icon style as the Collapse and Search buttons in the sidebar header.
        .buttonStyle(.titleBarIcon)
        .foregroundStyle(.secondary)
        .help(workspace.isSidebarVisible ? "Hide Sidebar (⌃⌘S)" : "Show Sidebar (⌃⌘S)")
    }
}

/// A plain icon button for the title bar row that shows a soft rounded fill under
/// the pointer, darker while pressed, like the toolbar buttons of system apps.
struct TitleBarIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconLabel(configuration: configuration)
    }

    private struct IconLabel: View {
        let configuration: Configuration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .frame(width: 26, height: 22)
                .background(
                    Color.primary.opacity(configuration.isPressed ? 0.14 : isHovering ? 0.08 : 0),
                    in: .rect(cornerRadius: 6, style: .continuous)
                )
                .contentShape(.rect(cornerRadius: 6, style: .continuous))
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovering)
        }
    }
}

extension ButtonStyle where Self == TitleBarIconButtonStyle {
    static var titleBarIcon: TitleBarIconButtonStyle { TitleBarIconButtonStyle() }
}
