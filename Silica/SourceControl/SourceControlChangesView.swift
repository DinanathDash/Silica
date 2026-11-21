import SwiftUI

/// Node representing a directory or file in the hierarchical changes tree.
struct ChangeTreeNode: Identifiable {
    let id: String
    let name: String
    let relativePath: String
    let isDirectory: Bool
    let file: GitFileItem?
    let children: [ChangeTreeNode]

    var allFiles: [GitFileItem] {
        if let file { return [file] }
        return children.flatMap { $0.allFiles }
    }
}

/// A flattened row in the changes tree for non-recursive rendering.
struct FlatChangeRow: Identifiable {
    let id: String
    let node: ChangeTreeNode
    let depth: Int
    let isStaged: Bool
}

/// Changes tab in Source Control for staging, unstaging, discarding, and committing changes.
struct SourceControlChangesView: View {
    let workspace: WorkspaceModel
    @Bindable var model: SourceControlModel
    var onSelectBranchesTab: (() -> Void)? = nil

    private var settings: EditorSettings { .shared }

    @State private var searchQuery = ""
    @State private var collapsedNodes: Set<String> = []
    @State private var hoveredNodeID: String? = nil

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
                    .liquidGlassTooltip("Switch to Branches tab")

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
                TextField("Commit message", text: $model.commitMessage, axis: .vertical)
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
                VStack(alignment: .leading, spacing: 2) {
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
                        .liquidGlassTooltip("Unstage all changes")
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 2)

                    ForEach(visibleRows(for: displayedStagedFiles, isStaged: true)) { row in
                        changeRow(for: row)
                    }
                }
            }

            // Unstaged Changes Section
            if !displayedUnstagedFiles.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
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
                        .liquidGlassTooltip("Stage all changes")

                        Button {
                            Task { await model.discardAllChanges() }
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .liquidGlassTooltip("Discard all changes")
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 2)

                    ForEach(visibleRows(for: displayedUnstagedFiles, isStaged: false)) { row in
                        changeRow(for: row)
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
                .liquidGlassTooltip("Clear search")
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

    // MARK: - Tree Row Rendering

    private func visibleRows(for files: [GitFileItem], isStaged: Bool) -> [FlatChangeRow] {
        let tree = buildChangeTree(from: files)
        return flatten(nodes: tree, depth: 0, isStaged: isStaged)
    }

    private func nodeKey(for node: ChangeTreeNode, isStaged: Bool) -> String {
        (isStaged ? "staged:" : "unstaged:") + node.id
    }

    private func flatten(nodes: [ChangeTreeNode], depth: Int, isStaged: Bool) -> [FlatChangeRow] {
        var rows: [FlatChangeRow] = []
        for node in nodes {
            let key = nodeKey(for: node, isStaged: isStaged)
            let rowId = (isStaged ? "staged_" : "unstaged_") + node.id
            rows.append(FlatChangeRow(id: rowId, node: node, depth: depth, isStaged: isStaged))
            if node.isDirectory && !collapsedNodes.contains(key) {
                rows.append(contentsOf: flatten(nodes: node.children, depth: depth + 1, isStaged: isStaged))
            }
        }
        return rows
    }

    @ViewBuilder
    private func changeRow(for row: FlatChangeRow) -> some View {
        if row.node.isDirectory {
            folderRow(node: row.node, depth: row.depth, isStaged: row.isStaged)
        } else if let file = row.node.file {
            fileRow(file: file, depth: row.depth)
        }
    }

    private func folderRow(node: ChangeTreeNode, depth: Int, isStaged: Bool) -> some View {
        let key = nodeKey(for: node, isStaged: isStaged)
        let isCollapsed = collapsedNodes.contains(key)
        let isHovered = hoveredNodeID == key
        let folderURL = workspace.rootURL.appending(path: node.relativePath)

        return HStack(spacing: 5) {
            if depth > 0 {
                Spacer().frame(width: CGFloat(depth * 12))
            }

            Button {
                withAnimation(.snappy(duration: 0.15)) {
                    if isCollapsed {
                        collapsedNodes.remove(key)
                    } else {
                        collapsedNodes.insert(key)
                    }
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: 12, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            FileIcon(url: folderURL, isDirectory: true, isExpanded: !isCollapsed, width: settings.sidebarIconWidth)

            Text(node.name)
                .font(.system(size: settings.sidebarFontSize, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 4)

            if isHovered {
                if isStaged {
                    Button {
                        Task { await model.unstageFolder(node.relativePath) }
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .liquidGlassTooltip("Unstage folder")
                } else {
                    Button {
                        Task { await model.stageFolder(node.relativePath) }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .liquidGlassTooltip("Stage folder")

                    Button {
                        Task { await model.discardFolderChanges(node.relativePath) }
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .liquidGlassTooltip("Discard folder changes")
                }
            }

            Text("\(node.allFiles.count)")
                .font(.system(size: max(settings.sidebarFontSize - 2.5, 8), weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary.opacity(0.8))
                .padding(.trailing, 2)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, max(3, (settings.sidebarFontSize - 7) / 2))
        .background {
            if isHovered {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering in
            hoveredNodeID = isHovering ? key : (hoveredNodeID == key ? nil : hoveredNodeID)
        }
        .onTapGesture {
            withAnimation(.snappy(duration: 0.15)) {
                if isCollapsed {
                    collapsedNodes.remove(key)
                } else {
                    collapsedNodes.insert(key)
                }
            }
        }
    }

    private func fileRow(file: GitFileItem, depth: Int) -> some View {
        let fileURL = workspace.rootURL.appending(path: file.relativePath)
        let isHovered = hoveredNodeID == file.id

        return HStack(spacing: 5) {
            if depth > 0 {
                Spacer().frame(width: CGFloat(depth * 12))
            }

            Color.clear
                .frame(width: 12, height: 16)

            FileIcon(url: fileURL, width: settings.sidebarIconWidth)

            Text(file.fileName)
                .font(.system(size: settings.sidebarFontSize))
                .foregroundStyle(file.status.badgeColor)
                .lineLimit(1)

            Spacer(minLength: 4)

            if isHovered {
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
                .liquidGlassTooltip(file.isStaged ? "Unstage changes" : "Stage changes")

                if !file.isStaged {
                    Button {
                        Task { await model.discardChanges(for: file) }
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .liquidGlassTooltip("Discard changes")
                }
            }

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

            // Extreme right: Git change badge (M, U, A, D)
            Text(file.status.badgeLetter)
                .font(.system(size: max(settings.sidebarFontSize - 2, 8), weight: .bold, design: .monospaced))
                .foregroundStyle(file.status.badgeColor)
                .frame(width: 14)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, max(3, (settings.sidebarFontSize - 7) / 2))
        .background {
            if isHovered {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering in
            hoveredNodeID = isHovering ? file.id : (hoveredNodeID == file.id ? nil : hoveredNodeID)
        }
        .onTapGesture {
            workspace.openDiff(for: fileURL)
        }
        .contextMenu {
            Button("Open Diff") { workspace.openDiff(for: fileURL) }
            Button("Open File") {
                workspace.open(fileURL)
                workspace.reveal(fileURL)
            }
            Divider()
            if file.isStaged {
                Button("Unstage Changes") { Task { await model.unstageFile(file) } }
            } else {
                Button("Stage Changes") { Task { await model.stageFile(file) } }
                Button("Discard Changes") { Task { await model.discardChanges(for: file) } }
            }
            Divider()
            Button("Show in Finder") { Finder.reveal(fileURL) }
            Button("Copy Path") { Finder.copyPath(fileURL) }
            Button("Copy Relative Path") { Finder.copyPath(file.relativePath) }
        }
    }

    // MARK: - Tree Construction

    private func buildChangeTree(from files: [GitFileItem]) -> [ChangeTreeNode] {
        class MutableNode {
            let name: String
            let relativePath: String
            let isDirectory: Bool
            var file: GitFileItem?
            var childrenMap: [String: MutableNode] = [:]

            init(name: String, relativePath: String, isDirectory: Bool, file: GitFileItem? = nil) {
                self.name = name
                self.relativePath = relativePath
                self.isDirectory = isDirectory
                self.file = file
            }

            func toImmutable() -> ChangeTreeNode {
                let sortedChildren = childrenMap.values.map { $0.toImmutable() }.sorted { a, b in
                    if a.isDirectory != b.isDirectory {
                        return a.isDirectory && !b.isDirectory
                    }
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
                return ChangeTreeNode(
                    id: relativePath,
                    name: name,
                    relativePath: relativePath,
                    isDirectory: isDirectory,
                    file: file,
                    children: sortedChildren
                )
            }
        }

        let root = MutableNode(name: "", relativePath: "", isDirectory: true)

        for item in files {
            let components = item.relativePath.split(separator: "/").map(String.init)
            var current = root
            var currentPath = ""
            for (index, comp) in components.enumerated() {
                currentPath = currentPath.isEmpty ? comp : "\(currentPath)/\(comp)"
                let isLast = index == components.count - 1
                if let existing = current.childrenMap[comp] {
                    if isLast {
                        existing.file = item
                    }
                    current = existing
                } else {
                    let newNode = MutableNode(
                        name: comp,
                        relativePath: currentPath,
                        isDirectory: !isLast,
                        file: isLast ? item : nil
                    )
                    current.childrenMap[comp] = newNode
                    current = newNode
                }
            }
        }

        return root.childrenMap.values.map { $0.toImmutable() }.sorted { a, b in
            if a.isDirectory != b.isDirectory {
                return a.isDirectory && !b.isDirectory
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
