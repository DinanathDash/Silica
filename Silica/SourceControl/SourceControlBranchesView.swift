import SwiftUI

/// Branches tab in Source Control for searching, viewing, creating, and switching Git branches.
struct SourceControlBranchesView: View {
    let workspace: WorkspaceModel
    @Bindable var model: SourceControlModel

    private var settings: EditorSettings { .shared }

    @State private var searchQuery = ""
    @State private var isShowingCreateBranchDialog = false
    @State private var baseBranchForNewBranch: GitBranchItem? = nil
    @State private var branchToDelete: GitBranchItem? = nil
    @State private var isShowingDeleteConfirmation = false
    @State private var hoveredBranchID: String? = nil

    // Branch switching with uncommitted changes & conflict warnings
    @State private var pendingBranchToSwitch: GitBranchItem? = nil
    @State private var isShowingDirtySwitchAlert = false
    @State private var checkoutAlertData: CheckoutAlertData? = nil
    @State private var isShowingCheckoutErrorAlert = false

    struct CheckoutAlertData: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private var filteredBranches: [GitBranchItem] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return model.branches }
        return model.branches.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Search bar & New Branch button (no "BRANCHES" text header)
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: max(settings.sidebarFontSize - 1, 10)))
                        .foregroundStyle(.secondary)

                    TextField("Search branches…", text: $searchQuery)
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

                Button {
                    baseBranchForNewBranch = nil
                    isShowingCreateBranchDialog = true
                } label: {
                    SourceControlIcon(type: .branchPlus, size: 14)
                }
                .buttonStyle(.titleBarIcon)
                .frame(width: 26, height: 26)
                .liquidGlassTooltip("Create new branch")
            }

            if model.branches.isEmpty {
                VStack(spacing: 8) {
                    SourceControlIcon(type: .branch, size: 28)
                        .foregroundStyle(.secondary)
                    Text("No branches found")
                        .font(.system(size: settings.sidebarFontSize))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else if filteredBranches.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                    Text("No branches matching \"\(searchQuery)\"")
                        .font(.system(size: settings.sidebarFontSize, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(filteredBranches) { branch in
                        branchRow(branch: branch)
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingCreateBranchDialog) {
            CreateBranchDialog(
                model: model,
                isPresented: $isShowingCreateBranchDialog,
                baseBranch: baseBranchForNewBranch
            )
        }
        .alert(
            "Delete Branch",
            isPresented: $isShowingDeleteConfirmation,
            presenting: branchToDelete
        ) { branch in
            Button("Delete Branch", role: .destructive) {
                Task {
                    _ = await model.deleteBranch(branch: branch, force: true)
                }
            }
            Button("Cancel", role: .cancel) {
                branchToDelete = nil
            }
        } message: { branch in
            Text("Are you sure you want to delete branch “\(branch.name)”? This action cannot be undone.")
        }
        // Uncommitted changes confirmation dialog when switching branches
        .alert(
            "Uncommitted Changes on “\(model.branchName ?? "Current Branch")”",
            isPresented: $isShowingDirtySwitchAlert,
            presenting: pendingBranchToSwitch
        ) { branch in
            Button("Stash & Switch") {
                stashAndCheckout(branch: branch)
            }
            Button("Switch Anyway") {
                performCheckout(branch: branch)
            }
            Button("Cancel", role: .cancel) {
                pendingBranchToSwitch = nil
            }
        } message: { branch in
            Text("You have unsaved or uncommitted changes in your workspace. Switching to “\(branch.name)” may conflict with your work or carry edits over.\n\nWe recommend committing or stashing your changes in the Changes tab before switching.")
        }
        // Formatted layman git conflict error dialog
        .alert(
            checkoutAlertData?.title ?? "Cannot Switch Branch",
            isPresented: $isShowingCheckoutErrorAlert,
            presenting: checkoutAlertData
        ) { _ in
            Button("OK", role: .cancel) {
                checkoutAlertData = nil
            }
        } message: { data in
            Text(data.message)
        }
    }

    // MARK: - Branch Row

    private func branchRow(branch: GitBranchItem) -> some View {
        let isHovered = hoveredBranchID == branch.id

        return HStack(spacing: 8) {
            // Real Lucide vector SVG icon based on branch type and name
            SourceControlIcon(type: branchIconType(for: branch), size: max(12, settings.sidebarIconWidth * 0.85))
                .foregroundStyle(branch.isCurrent ? Color.accentColor : Color.secondary)
                .frame(width: 14)

            // Branch name
            Text(branch.name)
                .font(.system(size: settings.sidebarFontSize, weight: branch.isCurrent ? .semibold : .regular))
                .foregroundStyle(branch.isCurrent ? Color.accentColor : Color.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .liquidGlassTooltip(branch.name)

            if branch.isCurrent {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.accentColor)
            }

            Spacer(minLength: 4)

            // Hover action buttons: only rendered for the hovered row to prevent memory and focus overhead
            if isHovered {
                HStack(spacing: 2) {
                    // New branch from this
                    Button {
                        baseBranchForNewBranch = branch
                        isShowingCreateBranchDialog = true
                    } label: {
                        SourceControlIcon(type: .fork, size: 12)
                    }
                    .buttonStyle(.titleBarIcon)
                    .frame(width: 20, height: 20)
                    .focusable(false)
                    .liquidGlassTooltip("New branch from “\(branch.name)”")

                    // Compare with current branch
                    if !branch.isCurrent {
                        Button {
                            workspace.openBranchCompare(targetBranch: branch.name)
                        } label: {
                            SourceControlIcon(type: .compare, size: 12)
                        }
                        .buttonStyle(.titleBarIcon)
                        .frame(width: 20, height: 20)
                        .focusable(false)
                        .liquidGlassTooltip("Compare “\(branch.name)” with current branch")
                    }

                    // Delete branch (omitted completely for current branch so buttons sit flush to the right)
                    if !branch.isCurrent {
                        Button {
                            branchToDelete = branch
                            isShowingDeleteConfirmation = true
                        } label: {
                            SourceControlIcon(type: .trash, size: 12)
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.titleBarIcon)
                        .frame(width: 20, height: 20)
                        .focusable(false)
                        .liquidGlassTooltip("Delete branch “\(branch.name)”")
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: max(26, settings.sidebarFontSize + 14)) // Dynamic height scales with sidebar font size
        .background {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(branch.isCurrent ? Color.accentColor.opacity(0.1) : (isHovered ? Color.primary.opacity(0.06) : Color.clear))
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                hoveredBranchID = branch.id
            } else if hoveredBranchID == branch.id {
                hoveredBranchID = nil
            }
        }
        .onTapGesture {
            requestCheckout(branch: branch)
        }
    }

    // MARK: - Checkout Operations

    private func requestCheckout(branch: GitBranchItem) {
        guard !branch.isCurrent else { return }
        if model.hasChanges {
            pendingBranchToSwitch = branch
            isShowingDirtySwitchAlert = true
        } else {
            performCheckout(branch: branch)
        }
    }

    private func performCheckout(branch: GitBranchItem) {
        Task {
            let result = await model.checkout(branch: branch)
            if !result.success, let err = result.error {
                let formatted = parseCheckoutError(err, targetBranch: branch.name)
                checkoutAlertData = CheckoutAlertData(title: formatted.title, message: formatted.message)
                isShowingCheckoutErrorAlert = true
            }
        }
    }

    private func stashAndCheckout(branch: GitBranchItem) {
        Task {
            let stashed = await model.stash(message: "Auto-stash before switching to \(branch.name)")
            if stashed {
                performCheckout(branch: branch)
            }
        }
    }

    private func parseCheckoutError(_ rawError: String, targetBranch: String) -> (title: String, message: String) {
        if rawError.contains("would be overwritten by checkout") {
            var conflictingFiles: [String] = []
            let lines = rawError.components(separatedBy: .newlines)
            var capturing = false
            for line in lines {
                if line.contains("would be overwritten by checkout:") {
                    capturing = true
                    continue
                }
                if capturing {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix("Please commit") || trimmed.hasPrefix("Aborting") || trimmed.isEmpty {
                        break
                    }
                    conflictingFiles.append(trimmed)
                }
            }

            let fileList = conflictingFiles.isEmpty
                ? "One or more files have uncommitted changes."
                : conflictingFiles.prefix(6).map { "• \($0)" }.joined(separator: "\n")
            let extra = conflictingFiles.count > 6 ? "\n• ...and \(conflictingFiles.count - 6) more" : ""

            return (
                title: "Cannot Switch Branch",
                message: "Git stopped the switch because your local edits in these files would be overwritten by “\(targetBranch)”:\n\n\(fileList)\(extra)\n\nPlease commit or discard these files in the Changes tab before switching."
            )
        } else {
            let alert = model.parseGitError(rawError, fallbackTitle: "Cannot Switch to “\(targetBranch)”", fallbackMessage: "Git encountered an unexpected issue while switching branches.")
            return (title: alert.title, message: alert.message)
        }
    }

    // MARK: - Branch Icon Selection

    private func branchIconType(for branch: GitBranchItem) -> SourceControlIconType {
        let lower = branch.name.lowercased()
        if branch.isRemote {
            return .cloud
        }
        if lower.hasPrefix("feature/") || lower.hasPrefix("feat/") {
            return .sparkles
        }
        if lower.hasPrefix("bugfix/") || lower.hasPrefix("fix/") {
            return .bug
        }
        if lower.hasPrefix("hotfix/") {
            return .flame
        }
        if lower.hasPrefix("release/") || lower.hasPrefix("releases/") || lower.hasPrefix("v") {
            return .tag
        }
        return .branch
    }
}

/// Native alert dialog for entering a new branch name with validation, Esc to cancel, and Cmd+Enter to submit.
struct CreateBranchDialog: View {
    @Bindable var model: SourceControlModel
    @Binding var isPresented: Bool
    var baseBranch: GitBranchItem? = nil

    @State private var branchName = ""
    @FocusState private var isFieldFocused: Bool

    private var trimmedName: String {
        branchName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isDuplicate: Bool {
        guard !trimmedName.isEmpty else { return false }
        return model.branches.contains {
            $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame ||
            $0.name.caseInsensitiveCompare("origin/\(trimmedName)") == .orderedSame
        }
    }

    private var isValid: Bool {
        !trimmedName.isEmpty && !isDuplicate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                SourceControlIcon(type: .branchPlus, size: 28)
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 4) {
                    Text(baseBranch == nil ? "Create New Branch" : "New Branch from “\(baseBranch!.name)”")
                        .font(.headline)

                    Text(baseBranch == nil
                         ? "Enter a name for the new branch."
                         : "A new branch will be created based on “\(baseBranch!.name)”.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                TextField("Branch name", text: $branchName)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFieldFocused)
                    .onKeyPress(.escape) {
                        isPresented = false
                        return .handled
                    }
                    .onSubmit {
                        if isValid {
                            submit()
                        }
                    }

                if isDuplicate {
                    Text("A branch named “\(trimmedName)” already exists.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            HStack(spacing: 8) {
                Spacer()

                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.regular)

                Button("Create") {
                    submit()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .keyboardShortcut(.return, modifiers: .command)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            isFieldFocused = true
        }
    }

    private func submit() {
        guard isValid else { return }
        Task {
            let success: Bool
            if let base = baseBranch {
                success = await model.createBranch(name: trimmedName, from: base.name)
            } else {
                success = await model.createBranch(name: trimmedName)
            }
            if success {
                isPresented = false
            }
        }
    }
}
