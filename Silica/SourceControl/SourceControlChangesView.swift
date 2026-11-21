import SwiftUI

/// Changes tab in Source Control for staging, unstaging, discarding, and committing changes.
struct SourceControlChangesView: View {
    let workspace: WorkspaceModel
    @Bindable var model: SourceControlModel

    var body: some View {
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
}
