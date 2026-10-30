import AppKit
import Sparkle

@MainActor final class AppUpdater: NSObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController?
    private var pendingInstall: (() -> Void)?
    private var retry: Timer?
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

    func checkNow() {
        NSApp.takeFocus()
        controller?.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock: @escaping () -> Void) -> Bool {
        pendingInstall = immediateInstallationBlock
        installWhenIdle()
        return true
    }

    private func installWhenIdle() {
        retry?.invalidate()
        guard let install = pendingInstall else { return }
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
