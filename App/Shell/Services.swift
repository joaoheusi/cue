import AppKit
import CueKit
import ServiceManagement
import UniformTypeIdentifiers
import UserNotifications

extension NSApplication {
    func takeFocus(_ window: NSWindow? = nil) {
        activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}

@MainActor final class MenuAction: NSObject {
    let action: @MainActor () -> Void
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    @objc func run() { action() }
}

extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: pointSize, weight: weight)
    }
}

extension NSMenu {
    @MainActor func add(_ title: String, image: NSImage? = nil, key: String = "", action: @escaping @MainActor () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: key)
        let target = MenuAction(action)
        item.target = target
        item.representedObject = target
        item.image = image
        addItem(item)
    }
}

@MainActor final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    func post(_ title: String, _ body: String, unavailable: @escaping @MainActor () -> Void = {}) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            let granted = (try? await center.requestAuthorization(options: [.alert])) ?? false
            guard granted, await center.notificationSettings().alertStyle != .none else { return unavailable() }
            do {
                try await center.add(request)
            } catch {
                unavailable()
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner]
    }
}

@MainActor final class PermissionCoordinator {
    enum Kind {
        case accessibility(reason: String)
        case clipboard

        var title: String {
            switch self {
            case .accessibility: "Allow Cue to use Accessibility"
            case .clipboard: "Allow Cue to read the clipboard"
            }
        }

        var explanation: String {
            switch self {
            case .accessibility(let reason):
                "\(reason)\n\nmacOS lists this under Privacy & Security → Accessibility. Cue uses it only for the action you start. Cue never records keystrokes or screen content.\n\nAfter you turn Cue on, quit and reopen Cue if it still reports no access."
            case .clipboard:
                "Clipboard history saves text you copy so you can search and paste it later. macOS asks before Cue reads the clipboard. Choose “Always Allow” to keep history working.\n\nCue skips passwords, concealed or transient items, and apps you exclude. History is encrypted and stays on this Mac."
            }
        }

        var settingsURL: URL {
            switch self {
            case .accessibility: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            case .clipboard: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")!
            }
        }
    }

    func explain(_ kind: Kind, continueTitle: String = "Continue") -> Bool {
        let alert = NSAlert()
        alert.messageText = kind.title
        alert.informativeText = kind.explanation
        alert.addButton(withTitle: continueTitle)
        alert.addButton(withTitle: "Not Now")
        NSApp.takeFocus()
        return alert.runModal() == .alertFirstButtonReturn
    }

    func openSettings(_ kind: Kind) {
        if !NSWorkspace.shared.open(kind.settingsURL) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!)
        }
    }
}

@MainActor enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ enabled: Bool) throws(CueError) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            throw CueError("AUTOSTART_FAILED", "Could not change launch at login. Check System Settings → General → Login Items.")
        }
        if enabled && needsApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    static let legacyAgent = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/Cue.plist")
    static var hasLegacyAgent: Bool { FileManager.default.fileExists(atPath: legacyAgent.path) }

    static func removeLegacyAgent() throws(CueError) {
        do {
            try FileManager.default.removeItem(at: legacyAgent)
        } catch {
            throw CueError("AUTOSTART_FAILED", "Could not remove the old login item. Delete ~/Library/LaunchAgents/Cue.plist yourself.")
        }
    }

    static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: "On"
        case .requiresApproval: "Waiting for approval in Login Items"
        case .notFound: "Unavailable for this copy of Cue. Move Cue to Applications"
        default: "Off"
        }
    }
}

@MainActor enum Uninstaller {
    static func run(context: AppContext) {
        let alert = NSAlert()
        alert.messageText = "Uninstall Cue?"
        alert.informativeText = "Cue removes its login item, deletes its Keychain keys, and moves its data folder and app to the Trash. Saved clipboard history cannot be read after the key is gone. Cue then quits."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        NSApp.takeFocus()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? LaunchAtLogin.set(false)
        if LaunchAtLogin.hasLegacyAgent { try? LaunchAtLogin.removeLegacyAgent() }
        ClipboardKeychain.delete(service: context.keychainService)
        ClaudeKey.delete(service: context.claudeKeyService)
        let manager = FileManager.default
        try? manager.trashItem(at: context.dataDirectory, resultingItemURL: nil)
        #if !DEBUG
        try? manager.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)
        #endif
        NSApp.terminate(nil)
    }
}

@MainActor enum FileTransfer {
    static func save(_ data: Data, suggestedName: String, type: UTType) throws(CueError) -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        NSApp.takeFocus()
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw CueError("EXPORT_FAILED", "Could not write the file. Choose another folder and try again.")
        }
        return true
    }

    static func open(type: UTType, maxBytes: Int) throws(CueError) -> Data? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [type]
        panel.allowsMultipleSelection = false
        NSApp.takeFocus()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            return try BoundedFile.read(url, maxBytes: maxBytes)
        } catch {
            throw error.cueError.code == "OUTPUT_TOO_LARGE" ? error.cueError : CueError("IMPORT_FAILED", "Could not read the file.")
        }
    }
}
