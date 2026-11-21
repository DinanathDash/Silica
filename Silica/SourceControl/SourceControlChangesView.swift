import SwiftUI

/// Changes tab in Source Control for staging, unstaging, discarding, and committing changes.
struct SourceControlChangesView: View {
    let workspace: WorkspaceModel
    @Bindable var model: SourceControlModel
    var onSelectBranchesTab: (() -> Void)? = nil

    private var settings: EditorSettings { .shared }

    @State private var searchQuery = ""

    private var displayedStagedFiles: [GitFileItem] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return model.stagedFiles }
        return model.stagedFiles.filter {
            $0.fileName.localizedCaseInsensitiveContains(query) ||
            $0.relativePath.localizedCaseInsensitiveContains(query)
        }
    }

    private var displayedUnstagedFiles: [GitFileItem] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return model.unstagedFiles }
        return model.unstagedFiles.filter {
            $0.fileName.localizedCaseInsensitiveContains(query) ||
            $0.relativePath.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Repo and Branch header
            if let branch = model.branchName {
                HStack(spacing: 5) {
                    Button {
                        onSelectBranchesTab?()
                    } label: {
                        HStack(spacing: 4) {
                            SourceControlIcon(type: .branch, size: 12)
                            Text(model.repositoryName)
                                .foregroundStyle(.secondary)
                            Text(":")
                                .foregroundStyle(.tertiary)
                            Text(branch)
                                .foregroundStyle(.primary)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(size: settings.sidebarFontSize, weight: .semibold))
                        .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help("Switch to Branches tab")

                    Spacer()

                    if model.totalAdditions > 0 || model.totalDeletions > 0 {
                        HStack(spacing: 4) {
                            Text("+\(model.totalAdditions)")
                                .foregroundStyle(.green)
                            Text("-\(model.totalDeletions)")
                                .foregroundStyle(.red)
                        }
                        .font(.system(size: max(settings.sidebarFontSize - 1.5, 9), weight: .semibold))
                    }
                }
            }

            // Commit Composer
            VStack(alignment: .leading, spacing: 8) {
                TextField("Commit message (⌘Enter to commit)", text: $model.commitMessage, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.plain)
                    .font(.system(size: settings.sidebarFontSize))
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

            // Search field before changes to filter edited files
            if model.hasChanges {
                searchBar
            }

            // Staged Files Section
            if !displayedStagedFiles.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Staged changes (\(displayedStagedFiles.count))")
                            .font(.system(size: max(settings.sidebarFontSize - 1.5, 9), weight: .semibold))
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

                    ForEach(displayedStagedFiles) { file in
                        fileRow(file: file)
                    }
                }
            }

            // Unstaged Changes Section
            if !displayedUnstagedFiles.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Changes (\(displayedUnstagedFiles.count))")
                            .font(.system(size: max(settings.sidebarFontSize - 1.5, 9), weight: .semibold))
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

                    ForEach(displayedUnstagedFiles) { file in
                        fileRow(file: file)
                    }
                }
            }

            if model.hasChanges && !searchQuery.isEmpty && displayedStagedFiles.isEmpty && displayedUnstagedFiles.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                    Text("No files matching \"\(searchQuery)\"")
                        .font(.system(size: settings.sidebarFontSize, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }

            if model.stagedFiles.isEmpty && model.unstagedFiles.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text("Working tree is clean")
                        .font(.system(size: settings.sidebarFontSize))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: max(settings.sidebarFontSize - 1, 10)))
                .foregroundStyle(.secondary)

            TextField("Search changes…", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: settings.sidebarFontSize))

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: max(settings.sidebarFontSize - 1, 10)))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                )
        }
    }

    private func fileRow(file: GitFileItem) -> some View {
        let fileURL = workspace.rootURL.appending(path: file.relativePath)
        return HStack(spacing: 6) {
            // File status badge
            Text(file.status.badgeLetter)
                .font(.system(size: max(settings.sidebarFontSize - 2, 8), weight: .bold, design: .monospaced))
                .foregroundStyle(file.status.badgeColor)
                .frame(width: 14)

            // Real file icon from Silica
            FileIcon(url: fileURL, width: settings.sidebarIconWidth)

            // File path and name
            VStack(alignment: .leading, spacing: 1) {
                Text(file.fileName)
                    .font(.system(size: settings.sidebarFontSize))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !file.directoryPath.isEmpty {
                    Text(file.directoryPath)
                        .font(.system(size: max(settings.sidebarFontSize - 1.5, 9)))
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
                .font(.system(size: max(settings.sidebarFontSize - 2, 8), weight: .semibold, design: .monospaced))
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
        .padding(.vertical, max(3, (settings.sidebarFontSize - 7) / 2))
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
}
