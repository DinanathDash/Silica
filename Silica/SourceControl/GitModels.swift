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

import CryptoKit

/// A git branch entry.
struct GitBranchItem: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let isCurrent: Bool
    let isRemote: Bool
}

/// Hosting platform of the remote origin repository.
enum RemoteHostType: Sendable {
    case github
    case gitlab
    case unknown
}

/// Visual timeline graph metadata for branch and merge layout in git history.
struct GitTimelineNode: Hashable, Sendable {
    struct Connection: Hashable, Sendable {
        let fromLane: Int
        let toLane: Int
    }

    let lane: Int
    let hasIncoming: Bool
    let outgoingConnections: [Connection]
    let passingLanes: [Int]
    let maxLanes: Int
    let rowMaxLane: Int
}

/// A git commit entry with timeline metadata and diff statistics.
struct GitCommitItem: Identifiable, Hashable, Sendable {
    var id: String { hash }
    let hash: String
    let shortHash: String
    let parentHashes: [String]
    let authorName: String
    let authorEmail: String
    let date: Date
    let summary: String
    let body: String
    let filesChanged: Int
    let additions: Int
    let deletions: Int
    var timelineNode: GitTimelineNode

    var isMerge: Bool { parentHashes.count > 1 }
    var isRoot: Bool { parentHashes.isEmpty }

    var compactRelativeDate: String {
        let seconds = -Int(date.timeIntervalSinceNow)
        if seconds < 60 {
            return "just now"
        } else if seconds < 3600 {
            return "\(seconds / 60)m"
        } else if seconds < 86400 {
            return "\(seconds / 3600)h"
        } else if seconds < 86400 * 7 {
            return "\(seconds / 86400)d"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return formatter.string(from: date)
        }
    }
}

extension String {
    var md5Hash: String {
        let digest = Insecure.MD5.hash(data: Data(self.utf8))
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }
}
