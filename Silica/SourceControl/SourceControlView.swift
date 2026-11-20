import SwiftUI

/// Right-side Source Control sidebar matching Silica appearance settings and liquid glass layout.
struct SourceControlView: View {
    @Bindable var workspace: WorkspaceModel
    @Bindable var model: SourceControlModel

    @State private var selectedTab: Tab = .changes
    @State private var isShowingNewBranchPrompt = false
    @State private var newBranchName = ""
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

                // Scrollable tab content
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        switch selectedTab {
                        case .changes:
                            changesTab
                        case .history:
                            historyTab
                        case .branches:
                            branchesTab
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
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 13, weight: .semibold))
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
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 32))
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

    // MARK: - Changes Tab

    private var changesTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Commit Composer card
            VStack(alignment: .leading, spacing: 8) {
                if let branch = model.branchName {
                    HStack(spacing: 4) {
                        Image(systemName: "point.topleft.down.to.point.bottomright.filled")
                            .font(.system(size: 10))
                        Text(branch)
                            .font(.system(size: 11, weight: .semibold))
                        Spacer()
                        if model.totalAdditions > 0 || model.totalDeletions > 0 {
                            HStack(spacing: 4) {
                                Text("+\(model.totalAdditions)")
                                    .foregroundStyle(.green)
                                Text("-\(model.totalDeletions)")
                                    .foregroundStyle(.red)
                            }
                            .font(.system(size: 10, weight: .semibold))
                        }
                    }
                    .foregroundStyle(.secondary)
                }

                TextField("Commit message (⌘Enter to commit)", text: $model.commitMessage, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(8)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                            )
                    }
                    .onSubmit {
                        Task { _ = await model.commit() }
                    }

                HStack {
                    if !model.stagedFiles.isEmpty {
                        Button("Unstage All") {
                            Task { await model.unstageAll() }
                        }
                        .controlSize(.small)
                        .glassButtonStyle()
                    } else if !model.unstagedFiles.isEmpty {
                        Button("Stage All") {
                            Task { await model.stageAll() }
                        }
                        .controlSize(.small)
                        .glassButtonStyle()
                    }

                    Spacer()

                    Button("Commit") {
                        Task { _ = await model.commit() }
                    }
                    .controlSize(.small)
                    .glassButtonStyle(prominent: true)
                    .disabled(model.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.3))
            }

            if let error = model.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(6)
            }

            // Staged Files Section
            if !model.stagedFiles.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("STAGED CHANGES (\(model.stagedFiles.count))")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            Task { await model.unstageAll() }
                        } label: {
                            Image(systemName: "minus")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .help("Unstage all changes")
                    }

                    ForEach(model.stagedFiles) { file in
                        fileRow(file: file)
                    }
                }
            }

            // Unstaged Changes Section
            if !model.unstagedFiles.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("CHANGES (\(model.unstagedFiles.count))")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            Task { await model.stageAll() }
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .help("Stage all changes")

                        Button {
                            Task { await model.discardAllChanges() }
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .help("Discard all changes")
                    }

                    ForEach(model.unstagedFiles) { file in
                        fileRow(file: file)
                    }
                }
            }

            if model.stagedFiles.isEmpty && model.unstagedFiles.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text("Working tree is clean")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }
        }
    }

    private func fileRow(file: GitFileItem) -> some View {
        let fileURL = workspace.rootURL.appending(path: file.relativePath)
        return HStack(spacing: 6) {
            // File status badge
            Text(file.status.badgeLetter)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(file.status.badgeColor)
                .frame(width: 14)

            // Real file icon from Silica
            FileIcon(url: fileURL, width: 14)

            // File path and name
            VStack(alignment: .leading, spacing: 1) {
                Text(file.fileName)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !file.directoryPath.isEmpty {
                    Text(file.directoryPath)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            // Additions / Deletions
            if file.additions > 0 || file.deletions > 0 {
                HStack(spacing: 2) {
                    if file.additions > 0 {
                        Text("+\(file.additions)").foregroundStyle(.green)
                    }
                    if file.deletions > 0 {
                        Text("-\(file.deletions)").foregroundStyle(.red)
                    }
                }
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
            }

            // Quick stage/unstage button
            Button {
                Task {
                    if file.isStaged {
                        await model.unstageFile(file)
                    } else {
                        await model.stageFile(file)
                    }
                }
            } label: {
                Image(systemName: file.isStaged ? "minus" : "plus")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .help(file.isStaged ? "Unstage changes" : "Stage changes")

            // Discard button for unstaged changes
            if !file.isStaged {
                Button {
                    Task { await model.discardChanges(for: file) }
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help("Discard changes")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            workspace.open(fileURL)
            workspace.reveal(fileURL)
        }
    }

    // MARK: - History Tab

    private var historyTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.commits) { commit in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(commit.shortHash)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.accentColor)
                        Spacer()
                        Text(commit.date.formatted(.relative(presentation: .named)))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Text(commit.summary)
                        .font(.system(size: 12))
                        .lineLimit(2)
                    Text(commit.authorName)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.3))
                }
            }
        }
    }

    // MARK: - Branches Tab

    private var branchesTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("BRANCHES")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    isShowingNewBranchPrompt = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("Create new branch")
            }

            if isShowingNewBranchPrompt {
                HStack {
                    TextField("Branch name", text: $newBranchName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                    Button("Create") {
                        Task {
                            if await model.createBranch(name: newBranchName) {
                                newBranchName = ""
                                isShowingNewBranchPrompt = false
                            }
                        }
                    }
                    .controlSize(.small)
                    Button("Cancel") {
                        isShowingNewBranchPrompt = false
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 4)
            }

            ForEach(model.branches) { branch in
                HStack(spacing: 8) {
                    Image(systemName: branch.isCurrent ? "checkmark" : (branch.isRemote ? "globe" : "point.topleft.down.to.point.bottomright.filled"))
                        .font(.system(size: 10, weight: branch.isCurrent ? .bold : .regular))
                        .foregroundStyle(branch.isCurrent ? Color.accentColor : Color.secondary)
                        .frame(width: 14)

                    Text(branch.name)
                        .font(.system(size: 12, weight: branch.isCurrent ? .semibold : .regular))
                        .foregroundStyle(branch.isCurrent ? Color.accentColor : Color.primary)
                        .lineLimit(1)

                    Spacer()

                    if !branch.isCurrent {
                        Button("Checkout") {
                            Task { await model.checkout(branch: branch) }
                        }
                        .controlSize(.mini)
                        .glassButtonStyle()
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(branch.isCurrent ? Color.accentColor.opacity(0.1) : Color.clear)
                }
            }
        }
    }
}

/// Toggle icon button positioned on the top right next to TerminalToggleButton.
struct SourceControlToggleButton: View {
    let workspace: WorkspaceModel

    var body: some View {
        Button {
            workspace.toggleSourceControl()
        } label: {
            Image(systemName: "arrow.triangle.branch")
        }
        .buttonStyle(.titleBarIcon)
        .foregroundStyle(workspace.isSourceControlVisible ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .help(workspace.isSourceControlVisible ? "Hide Source Control (⌃⇧G)" : "Show Source Control (⌃⇧G)")
    }
}
