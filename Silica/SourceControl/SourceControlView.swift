import SwiftUI

/// Right-side Source Control sidebar matching Silica appearance settings and liquid glass layout.
struct SourceControlView: View {
    @Bindable var workspace: WorkspaceModel
    @Bindable var model: SourceControlModel

    @State private var selectedTab: Tab = .changes
    @State private var refreshRotationAngle: Double = 0

    enum Tab: String, CaseIterable, Identifiable {
        case changes = "Changes"
        case history = "History"
        case branches = "Branches"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .changes: "arrow.triangle.branch"
            case .history: "clock.arrow.circlepath"
            case .branches: "arrow.triangle.pull"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header bar aligning with title bar height
            headerBar
                .frame(height: WorkspaceLayout.titleBarHeight)
                .padding(.leading, 12)
                .padding(.trailing, 6)
                .zIndex(2)

            if !model.isGitRepository {
                notRepositoryView
            } else {
                // Native segmented tabs selector matching appearance picker
                Picker("Section", selection: $selectedTab) {
                    ForEach(Tab.allCases) { tab in
                        Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                    }
                }
                .labelsHidden()
                .tabsPickerStyle()
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 6)

                // Scrollable tab content delegating to dedicated subviews
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        switch selectedTab {
                        case .changes:
                            SourceControlChangesView(workspace: workspace, model: model)
                        case .history:
                            SourceControlHistoryView(model: model)
                        case .branches:
                            SourceControlBranchesView(model: model)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                }
                .scrollIndicators(.never)
                .softVerticalScrollEdges()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .workspaceCard()
        .task {
            await model.refresh()
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                SourceControlIcon(type: .branch, size: 14)
                    .foregroundStyle(Color.accentColor)

                Text("Source Control")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if model.isGitRepository {
                Button {
                    withAnimation(.easeInOut(duration: 0.6)) {
                        refreshRotationAngle += 360
                    }
                    Task {
                        await model.refresh()
                    }
                } label: {
                    ZStack {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                            .rotationEffect(.degrees(refreshRotationAngle))
                    }
                    .frame(width: 16, height: 16)
                }
                .buttonStyle(.titleBarIcon)
                .frame(width: 26, height: 22)
                .help("Refresh Status")
            }

            Button {
                workspace.hideSourceControl()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.titleBarIcon)
            .frame(width: 26, height: 22)
            .help("Close Source Control")
        }
    }

    // MARK: - Not a Git Repository

    private var notRepositoryView: some View {
        VStack(spacing: 12) {
            Spacer()
            SourceControlIcon(type: .branch, size: 36)
                .foregroundStyle(.secondary)
            Text("No Git Repository Found")
                .font(.system(size: 14, weight: .medium))
            Text("The folder is not initialized with Git.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Button("Initialize Repository") {
                Task { await model.initializeRepository() }
            }
            .controlSize(.small)
            .glassButtonStyle(prominent: true)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }
}

/// Toggle icon button positioned on the top right next to TerminalToggleButton.
struct SourceControlToggleButton: View {
    let workspace: WorkspaceModel

    var body: some View {
        Button {
            workspace.toggleSourceControl()
        } label: {
            SourceControlIcon(type: .branch, size: 13)
        }
        .buttonStyle(.titleBarIcon)
        .foregroundStyle(workspace.isSourceControlVisible ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .help(workspace.isSourceControlVisible ? "Hide Source Control (⌃⇧G)" : "Show Source Control (⌃⇧G)")
    }
}
