import SwiftUI

/// The branches to switch to, under the branch's name in the Changes panel: a
/// field that narrows them as you type, the local branches, then the remotes'
/// that aren't local yet. A local branch can also be merged into the current
/// one, renamed or deleted.
struct GitBranchPicker: View {
    let workspace: WorkspaceModel
    let snapshot: GitStatus.Snapshot
    /// Closes the popover.
    let dismiss: () -> Void
    /// New Branch…, with what has been typed as its name.
    let create: (String) -> Void

    @State private var filter = ""
    @FocusState private var isFieldFocused: Bool

    private var git: GitModel { workspace.git }
    private var query: String { filter.trimmingCharacters(in: .whitespaces) }

    private func matching(_ names: [String]) -> [String] {
        query.isEmpty ? names : names.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        let local = matching(snapshot.localBranches)
        let remote = matching(snapshot.remoteBranches)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Switch to a branch", text: $filter)
                    .textFieldStyle(.plain)
                    .focused($isFieldFocused)
                    .onSubmit {
                        // Return takes the branch typed, or failing that the first
                        // one listed. With nothing typed it does nothing: the first
                        // listed is only the one last committed to.
                        guard !query.isEmpty else { return }
                        if let name = local.first(where: { $0 == query }) {
                            choose(local: name)
                        } else if let name = remote.first(where: { $0 == query }) {
                            choose(remote: name)
                        } else if let name = local.first {
                            choose(local: name)
                        } else if let name = remote.first {
                            choose(remote: name)
                        }
                    }
                    .accessibilityLabel("Filter Branches")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(local, id: \.self) { name in
                        row(name, isCurrent: name == snapshot.branch.name, isLocal: true)
                    }
                    if !remote.isEmpty {
                        Text("On a remote")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.top, 8)
                            .padding(.bottom, 2)
                        ForEach(remote, id: \.self) { name in
                            row(name, isCurrent: false, isLocal: false)
                        }
                    }
                    if local.isEmpty, remote.isEmpty {
                        Text("No branch matches")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(10)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 280)
            Divider()
            Button {
                dismiss()
                create(snapshot.localBranches.contains(query) ? "" : query)
            } label: {
                Label(query.isEmpty || snapshot.localBranches.contains(query) ? "New Branch…" : "New Branch “\(query)”…", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(width: 280)
        .onAppear { isFieldFocused = true }
    }

    private func row(_ name: String, isCurrent: Bool, isLocal: Bool) -> some View {
        GitBranchRow(name: name, isCurrent: isCurrent) {
            if isLocal { choose(local: name) } else { choose(remote: name) }
        } actions: {
            if isLocal {
                if !isCurrent, let current = snapshot.branch.name {
                    Button("Merge into “\(current)”") {
                        dismiss()
                        git.merge(name)
                    }
                    Divider()
                }
                Button("Rename…") {
                    dismiss()
                    workspace.renameBranch(name)
                }
                if !isCurrent {
                    Button("Delete…") {
                        dismiss()
                        workspace.deleteBranch(name)
                    }
                }
            }
        }
    }

    private func choose(local name: String) {
        dismiss()
        git.switchTo(name)
    }

    private func choose(remote name: String) {
        dismiss()
        git.track(name)
    }
}

private struct GitBranchRow<Actions: View>: View {
    let name: String
    let isCurrent: Bool
    let choose: () -> Void
    @ViewBuilder let actions: () -> Actions
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: choose) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .opacity(isCurrent ? 1 : 0)
                    Text(name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCurrent ? "\(name), current branch" : "Switch to \(name)")
            Menu {
                actions()
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 18, height: 16)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Actions for \(name)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(isHovered ? Color.primary.opacity(0.07) : .clear)
        .onHover { isHovered = $0 }
        .contextMenu { actions() }
    }
}
