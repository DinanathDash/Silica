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
            case .modified:
                // VS Code gitDecoration.modifiedResourceForeground: #E2C08D
                Color(red: 0.89, green: 0.75, blue: 0.55)
            case .added, .untracked:
                // VS Code gitDecoration.untrackedResourceForeground / addedResourceForeground: #73C991
                Color(red: 0.45, green: 0.79, blue: 0.57)
            case .deleted:
                // VS Code gitDecoration.deletedResourceForeground: #C74E39
                Color(red: 0.78, green: 0.31, blue: 0.22)
            case .renamed, .copied:
                Color(red: 0.45, green: 0.79, blue: 0.57)
            case .conflict:
                // VS Code gitDecoration.conflictingResourceForeground: #E46873
                Color(red: 0.89, green: 0.41, blue: 0.45)
            case .ignored:
                Color(white: 0.55)
            case .unknown:
                Color(white: 0.65)
            }
        }

        var priority: Int {
            switch self {
            case .conflict: 100
            case .modified: 90
            case .added: 80
            case .untracked: 70
            case .deleted: 60
            case .renamed: 50
            case .copied: 40
            case .ignored: 20
            case .unknown: 10
            }
        }
    }

    let id: String
    let relativePath: String
    let originalPath: String?
    let fileName: String
    let directoryPath: String
    let status: Status
    let isStaged: Bool
    var additions: Int = 0
    var deletions: Int = 0

    init(relativePath: String, originalPath: String? = nil, status: Status, isStaged: Bool, additions: Int = 0, deletions: Int = 0) {
        self.id = "\(isStaged ? "staged" : "unstaged"):\(relativePath)"
        self.relativePath = relativePath
        self.originalPath = originalPath
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

/// A file modified, added, or deleted in a specific git commit.
struct CommitChangedFile: Identifiable, Hashable, Sendable {
    var id: String { relativePath }
    let relativePath: String
    let originalPath: String?
    let fileName: String
    let directoryPath: String
    let status: GitFileItem.Status
    let additions: Int
    let deletions: Int

    init(relativePath: String, originalPath: String? = nil, status: GitFileItem.Status, additions: Int = 0, deletions: Int = 0) {
        self.relativePath = relativePath
        self.originalPath = originalPath
        self.status = status
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
enum RemoteHostType: String, Sendable {
    case github
    case gitlab
    case unknown
}

/// Git ref decoration representing a branch, HEAD, or tag pointing to a commit.
struct GitRefDecoration: Hashable, Identifiable, Sendable {
    enum RefType: Hashable, Sendable {
        case head(branch: String)
        case detachedHead
        case localBranch(name: String)
        case remoteBranch(name: String)
        case tag(name: String)
    }

    var id: String { rawName }
    let rawName: String
    let displayName: String
    let type: RefType

    static func parse(_ raw: String) -> [GitRefDecoration] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var result: [GitRefDecoration] = []
        let parts = trimmed.components(separatedBy: ", ")
        for part in parts {
            let t = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if t.contains("droppy-code") || t.contains("refs/notes") || t.contains("refs/stash") || t.contains("refs/original") {
                continue
            }
            if t.hasPrefix("HEAD -> ") {
                let name = String(t.dropFirst("HEAD -> ".count))
                result.append(GitRefDecoration(rawName: t, displayName: name, type: .head(branch: name)))
            } else if t == "HEAD" {
                result.append(GitRefDecoration(rawName: t, displayName: "HEAD", type: .detachedHead))
            } else if t.hasPrefix("tag: ") {
                let tag = String(t.dropFirst("tag: ".count))
                result.append(GitRefDecoration(rawName: t, displayName: tag, type: .tag(name: tag)))
            } else if t.contains("/") {
                result.append(GitRefDecoration(rawName: t, displayName: t, type: .remoteBranch(name: t)))
            } else {
                result.append(GitRefDecoration(rawName: t, displayName: t, type: .localBranch(name: t)))
            }
        }
        return result
    }
}

/// Visual timeline graph metadata for branch and merge layout in git history.
struct GitTimelineNode: Hashable, Sendable {
    struct Connection: Hashable, Sendable {
        let fromLane: Int
        let toLane: Int
        var colorLane: Int
    }

    let lane: Int
    let hasIncoming: Bool
    let incomingMergeLanes: [Int]
    let outgoingConnections: [Connection]
    let passingLanes: [Int]
    let maxLanes: Int
}

/// A git commit entry with timeline metadata and diff statistics.
struct GitCommitItem: Identifiable, Hashable, Sendable {
    var id: String { hash }
    let hash: String
    let shortHash: String
    let parentHashes: [String]
    let refDecorations: [GitRefDecoration]
    let authorName: String
    let authorEmail: String
    let date: Date
    let summary: String
    let body: String
    let filesChanged: Int
    let additions: Int
    let deletions: Int
    var timelineNode: GitTimelineNode
    var isUnpushed: Bool = false
    var isHead: Bool = false

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

    var sha256Hash: String {
        let digest = SHA256.hash(data: Data(self.utf8))
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }
}

/// Who last changed a line of a file, and in which commit.
struct GitBlameLine: Sendable, Equatable {
    let hash: String
    let author: String
    let date: Date
    let summary: String

    /// A line changed since the last commit: git blames it on a commit of zeros.
    var isUncommitted: Bool { hash.allSatisfy { $0 == "0" } }
}
