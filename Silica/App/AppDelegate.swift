import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        AppLogger.installCrashAndExceptionHandlers()
        AppLogger.info("App", "Silica launching on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        AppLogger.memory("App", "Startup memory")
        NSWindow.allowsAutomaticWindowTabbing = false
        // Before any window shows, so none flashes in the other appearance.
        EditorSettings.shared.applyAppearance()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLogger.info("App", "Silica did finish launching")
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let isActive = await MainActor.run { NSApp.isActive }
        if isActive {
            return []
        }
        return [.banner, .sound]
    }

    /// Files and folders from Finder's Open With, the Dock icon or `open -a`.
    func application(_ application: NSApplication, open urls: [URL]) {
        ExternalOpener.shared.open(urls)
    }

    /// Quitting asks about unsaved files in each project window first, in a sheet,
    /// so the answer comes back later.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard UnsavedChangesGuard.GuardView.hasUnsavedChanges else { return .terminateNow }
        UnsavedChangesGuard.GuardView.confirmQuitting { proceed in
            NSApp.reply(toApplicationShouldTerminate: proceed)
        }
        return .terminateLater
    }
}
