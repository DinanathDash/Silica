import CoreServices
import Foundation

/// Reports changes anywhere under a project folder (FSEvents), batched over a
/// short delay so a `git checkout` or a build arrives as one callback.
final class ProjectWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void
    private let onGitChange: () -> Void
    /// The repository's folder when it's outside the project: the project is a
    /// linked worktree, or a folder inside a bigger repository.
    private let outsideGitDirectory: String?

    /// `onChange` is for changes to the project's files. `onGitChange` is for
    /// those that only touch the repository (a commit, staging a file), which leave
    /// the files alone but change their git status. Both run on the main queue.
    init(url: URL, onChange: @escaping () -> Void, onGitChange: @escaping () -> Void) {
        self.onChange = onChange
        self.onGitChange = onGitChange
        let root = url.path(percentEncoded: false)
        var watched = [root]
        if let directory = GitRepository.locate(containing: url)?.gitDirectory,
           !directory.hasPrefix(GitRepository.canonicalPath(root).trimmingTrailingSlash + "/") {
            watched.append(directory)
            outsideGitDirectory = directory
        } else {
            outsideGitDirectory = nil
        }

        var context = FSEventStreamContext(
            version: 0,
            // Released in `stop()`, so the stream never outlives its watcher.
            info: Unmanaged.passRetained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<ProjectWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            MainActor.assumeIsolated { watcher.handle(changed) }
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context,
            watched as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
        ) else {
            Unmanaged.passUnretained(self).release()
            return
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        Unmanaged.passUnretained(self).release()
    }

    private func handle(_ paths: [String]) {
        // Git rewrites its own files constantly (index, locks, logs); the working
        // tree changes a checkout makes arrive as their own events.
        let relevant = paths.contains { path in
            !path.contains("/.git/") && !path.hasSuffix("/.git") && !isInOutsideGitDirectory(path)
        }
        if relevant {
            onChange()
        } else if paths.contains(where: changesGitStatus) {
            onGitChange()
        }
    }

    private func isInOutsideGitDirectory(_ path: String) -> Bool {
        guard let outsideGitDirectory else { return false }
        return path.trimmingTrailingSlash == outsideGitDirectory || path.hasPrefix(outsideGitDirectory + "/")
    }

    /// Events name the folder that changed. The index and HEAD are at the top of
    /// the repository's folder and branches under `refs`; the rest (objects, logs)
    /// changes without the status changing.
    private func changesGitStatus(_ path: String) -> Bool {
        let folder = path.trimmingTrailingSlash
        if folder.hasSuffix("/.git") || folder.contains("/.git/refs") { return true }
        guard let outsideGitDirectory else { return false }
        return folder == outsideGitDirectory || folder.hasPrefix(outsideGitDirectory + "/refs")
    }
}
