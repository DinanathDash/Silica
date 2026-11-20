import SwiftUI

/// Right-side Source Control sidebar inspired by athas, rendered with Silica's Liquid Glass.
struct SourceControlView: View {
    @Bindable var workspace: WorkspaceModel
    @Bindable var model: SourceControlModel

    @State private var selectedTab: Tab = .changes
    @State private var isShowingNewBranchPrompt = false
    @State private var newBranchName = ""
    @State private var isShowingStashPrompt = false
    @State private var newStashMessage = ""

    enum Tab: String, CaseIterable, Identifiable {
        case changes = "Changes"
        case history = "History"
        case branches = "Branches"
        case stashes = "Stashes"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .changes: "arrow.triangle.branch"
            case .history: "clock.arrow.circlepath"
            case .branches: "point.topleft.down.to.point.bottomright.filled"
            case .stashes: "archivebox"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header bar aligning with title bar height
            headerBar
                .frame(height: WorkspaceLayout.titleBarHeight)
                .padding(.horizontal, 10)
                .zIndex(2)

            Divider().opacity(0.3)

            if !model.isGitRepository {
                notRepositoryView
            } else {
                tabSelector
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)

                Divider().opacity(0.2)

                // Main Tab Content
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        switch selectedTab {
                        case .changes:
                            changesTab
                        case .history:
                            historyTab
                        case .branches:
                            branchesTab
                        case .stashes:
                            stashesTab
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .scrollIndicators(.never)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // Liquid Glass backdrop matching Silica styling
            RoundedRectangle(cornerRadius: WorkspaceLayout.cardCornerRadius, style: .continuous)
                .glassSurface(true, in: RoundedRectangle(cornerRadius: WorkspaceLayout.cardCornerRadius, style: .continuous))
        }
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
                // Refresh
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.titleBarIcon)
                .help("Refresh Status")
                .disabled(model.isLoading)

                // Remotes actions menu (Pull, Push, Fetch)
                Menu {
                    Button {
                        Task { await model.pull() }
                    } label: {
                        Label("Pull", systemImage: "arrow.down")
                    }
                    Button {
                        Task { await model.push() }
                    } label: {
                        Label("Push", systemImage: "arrow.up")
                    }
                    Button {
                        Task { await model.fetch() }
                    } label: {
                        Label("Fetch", systemImage: "arrow.triangle.2.circlepath")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 11, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 20, height: 20)
                .help("Remote Actions")
            }

            // Close button
            Button {
                workspace.hideSourceControl()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.titleBarIcon)
            .help("Close Source Control")
        }
    }

    // MARK: - Tab Selector

    private var tabSelector: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 10, weight: .medium))
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: selectedTab == tab ? .semibold : .regular))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background {
                        if selectedTab == tab {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.12))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedTab == tab ? Color.primary : Color.secondary)
            }
            Spacer(minLength: 0)
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
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Changes Tab

    private var changesTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Commit composer box
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
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                            )
                    }
                    .onSubmit {
                        Task { _ = await model.commit() }
                    }

                HStack {
                    Button("Commit") {
                        Task { _ = await model.commit() }
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Spacer()

                    if !model.stagedFiles.isEmpty {
                        Button("Unstage All") {
                            Task { await model.unstageAll() }
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    } else if !model.unstagedFiles.isEmpty {
                        Button("Stage All") {
                            Task { await model.stageAll() }
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    }
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
        HStack(spacing: 6) {
            // File status badge
            Text(file.status.badgeLetter)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(file.status.badgeColor)
                .frame(width: 14)

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
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            let fileURL = workspace.rootURL.appending(path: file.relativePath)
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

    // MARK: - Stashes Tab

    private var stashesTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("STASHES")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    isShowingStashPrompt = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("Stash working changes")
            }

            if isShowingStashPrompt {
                HStack {
                    TextField("Stash message (optional)", text: $newStashMessage)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                    Button("Stash") {
                        Task {
                            await model.createStash(message: newStashMessage)
                            newStashMessage = ""
                            isShowingStashPrompt = false
                        }
                    }
                    .controlSize(.small)
                    Button("Cancel") {
                        isShowingStashPrompt = false
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 4)
            }

            if model.stashes.isEmpty {
                Text("No stashed changes")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                ForEach(model.stashes) { stash in
                    HStack(spacing: 8) {
                        Image(systemName: "archivebox")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(stash.index)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(stash.message)
                                .font(.system(size: 11))
                                .lineLimit(1)
                        }

                        Spacer()

                        Button("Pop") {
                            Task { await model.popStash(index: stash.index) }
                        }
                        .controlSize(.mini)

                        Button {
                            Task { await model.dropStash(index: stash.index) }
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .help("Drop stash")
                    }
                    .padding(6)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.3))
                    }
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
