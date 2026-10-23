import AppKit
import Sparkle

/// Sparkle auto-update for signed release builds. Debug builds and UI tests never update.
/// Sparkle verifies the EdDSA signature and that the new app has the same code-signing identity.
@MainActor final class AppUpdater: NSObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController?
    private var pendingInstall: (() -> Void)?
    private var retry: Timer?
    /// True when relaunching now cannot lose work or interrupt the user.
    var isIdle: () -> Bool = { true }

    init(enabled: Bool) {
        super.init()
        guard enabled else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    var isAvailable: Bool { controller != nil }
    private var updater: SPUUpdater? { controller?.updater }

    var automaticallyChecks: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyInstalls: Bool {
        get { updater?.automaticallyDownloadsUpdates ?? false }
        set { updater?.automaticallyDownloadsUpdates = newValue }
    }

    var lastCheck: Date? { updater?.lastUpdateCheckDate }

    /// Interactive check with Sparkle's own progress and release-notes window.
    func checkNow() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    // A menu-bar app rarely quits, so Sparkle's install-on-quit would never run.
    // Take over and install as soon as Cue is idle.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock: @escaping () -> Void) -> Bool {
        pendingInstall = immediateInstallationBlock
        installWhenIdle()
        return true
    }

    private func installWhenIdle() {
        retry?.invalidate()
        guard let install = pendingInstall else { return }
        // No keyboard or mouse input for a minute, plus the app's own checks.
        let quiet = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!) > 60
        if quiet && isIdle() {
            pendingInstall = nil
            install()
        } else {
            retry = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.installWhenIdle() }
            }
        }
    }

    var diagnostics: [(String, String)] {
        guard isAvailable else { return [("Auto-update", "disabled in this build")] }
        return [
            ("Auto-update checks", automaticallyChecks ? "on" : "off"),
            ("Auto-install", automaticallyInstalls ? "on" : "off"),
            ("Last check", lastCheck.map { $0.formatted(.iso8601) } ?? "never"),
            ("Update waiting for idle", pendingInstall == nil ? "no" : "yes"),
        ]
    }
}
