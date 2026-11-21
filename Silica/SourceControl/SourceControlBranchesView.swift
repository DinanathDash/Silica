import SwiftUI

/// Branches tab in Source Control for viewing, creating, and switching Git branches.
struct SourceControlBranchesView: View {
    @Bindable var model: SourceControlModel

    @State private var isShowingNewBranchPrompt = false
    @State private var newBranchName = ""

    var body: some View {
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
