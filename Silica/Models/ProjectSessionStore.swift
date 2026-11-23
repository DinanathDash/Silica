import Foundation

/// What a project window had open, so reopening the project puts it back.
struct ProjectSession: Codable {
    struct Tab: Codable {
        /// Path from the project root (absolute for a file outside it).
        var path: String
        /// Cursor offset (UTF-16).
        var cursor: Int?
        /// 1-based line at the top of the view.
        var topLine: Int?
    }

    /// One pane's tabs, by their paths, while the editor area is split.
    struct Pane: Codable {
        var id: PaneLayout.PaneID
        var tabs: [String]
        var activeTab: String?
    }

    /// How the editor area was divided, and which tabs each pane had.
    struct Split: Codable {
        var layout: PaneLayout
        var panes: [Pane]
        var focused: PaneLayout.PaneID
    }

    /// Every pane's tabs, pane by pane.
    var tabs: [Tab]
    /// The tab the focused pane showed.
    var activeTab: String?
    var isSidebarVisible: Bool
    /// `nil` with a single pane, and in sessions saved before there were panes.
    var split: Split?
    var savedAt: Date
}

/// Sessions for recently used projects, kept in UserDefaults by project path.
enum ProjectSessionStore {
    private static let key = "ProjectSessions"
    /// Projects whose sessions are kept; the least recently saved go first.
    private static let limit = 40

    static func session(for root: URL) -> ProjectSession? {
        all()[path(of: root)]
    }

    static func save(_ session: ProjectSession, for root: URL) {
        var sessions = all()
        sessions[path(of: root)] = session
        if sessions.count > limit {
            let oldest = sessions.sorted { $0.value.savedAt < $1.value.savedAt }.prefix(sessions.count - limit)
            for (path, _) in oldest { sessions[path] = nil }
        }
        if let data = try? JSONEncoder().encode(sessions) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func all() -> [String: ProjectSession] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: ProjectSession].self, from: data)) ?? [:]
    }

    private static func path(of root: URL) -> String {
        root.path(percentEncoded: false).trimmingTrailingSlash
    }
}
