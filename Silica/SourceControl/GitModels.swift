import Foundation
import SwiftUI

/// Represents a file tracked or modified in Git working tree.
struct GitFileItem: Identifiable, Hashable, Sendable {
    enum Status: String, Sendable {
        case modified = "M"
        case added = "A"
        case deleted = "D"
        case renamed = "R"
        case copied = "C"
        case untracked = "?"
        case ignored = "!"
        case conflict = "U"
        case unknown = " "

        var label: String {
            switch self {
            case .modified: "Modified"
            case .added: "Added"
            case .deleted: "Deleted"
            case .renamed: "Renamed"
            case .copied: "Copied"
            case .untracked: "Untracked"
            case .ignored: "Ignored"
            case .conflict: "Conflict"
            case .unknown: "Unknown"
            }
        }

        var badgeLetter: String {
            switch self {
            case .modified: "M"
            case .added: "A"
            case .deleted: "D"
            case .renamed: "R"
            case .copied: "C"
            case .untracked: "U"
            case .ignored: "I"
            case .conflict: "!"
            case .unknown: "?"
            }
        }

        var badgeColor: Color {
            switch self {
            case .modified: .blue
            case .added, .untracked: .green
            case .deleted: .red
            case .renamed, .copied: .purple
            case .conflict: .orange
            case .ignored, .unknown: .secondary
            }
        }
    }

    let id: String
    let relativePath: String
    let fileName: String
    let directoryPath: String
    let status: Status
    let isStaged: Bool
    var additions: Int = 0
    var deletions: Int = 0

    init(relativePath: String, status: Status, isStaged: Bool, additions: Int = 0, deletions: Int = 0) {
        self.id = "\(isStaged ? "staged" : "unstaged"):\(relativePath)"
        self.relativePath = relativePath
        self.status = status
        self.isStaged = isStaged
        self.additions = additions
        self.deletions = deletions

        let components = relativePath.split(separator: "/")
        if let last = components.last {
            self.fileName = String(last)
            self.directoryPath = components.dropLast().joined(separator: "/")
        } else {
            self.fileName = relativePath
            self.directoryPath = ""
        }
    }
}

/// A git branch entry.
struct GitBranchItem: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let isCurrent: Bool
    let isRemote: Bool
}

/// A git commit entry.
struct GitCommitItem: Identifiable, Hashable, Sendable {
    var id: String { hash }
    let hash: String
    let shortHash: String
    let authorName: String
    let date: Date
    let summary: String
}

/// A git stash item.
struct GitStashItem: Identifiable, Hashable, Sendable {
    var id: String { index }
    let index: String
    let message: String
}
