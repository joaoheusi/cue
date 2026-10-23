import AppKit
import CueKit
import ServiceManagement
import UniformTypeIdentifiers

/// Explains each permission at the moment a feature needs it, before macOS shows its own prompt.
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

    /// Shows the explanation. Returns true when the user chooses to continue.
    func explain(_ kind: Kind, continueTitle: String = "Continue") -> Bool {
        let alert = NSAlert()
        alert.messageText = kind.title
        alert.informativeText = kind.explanation
        alert.addButton(withTitle: continueTitle)
        alert.addButton(withTitle: "Not Now")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    func openSettings(_ kind: Kind) {
        if !NSWorkspace.shared.open(kind.settingsURL) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!)
        }
    }
}

/// Launch at login through `SMAppService`. macOS may require approval in Login Items settings.
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

    /// The LaunchAgent written by the earlier Tauri version. It starts Cue a second way at login.
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
        case .notFound: "Unavailable for this copy of Cue. Move Cue to Applications."
        default: "Off"
        }
    }
}

/// Save and open panels with safe names, size limits, and atomic writes.
@MainActor enum FileTransfer {
    /// Returns false when the user cancels.
    static func save(_ data: Data, suggestedName: String, type: UTType) throws(CueError) -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw CueError("EXPORT_FAILED", "Could not write the file. Choose another folder and try again.")
        }
        return true
    }

    /// Returns nil when the user cancels.
    static func open(type: UTType, maxBytes: Int) throws(CueError) -> Data? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [type]
        panel.allowsMultipleSelection = false
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            return try BoundedFile.read(url, maxBytes: maxBytes)
        } catch {
            throw error.cueError.code == "OUTPUT_TOO_LARGE" ? error.cueError : CueError("IMPORT_FAILED", "Could not read the file.")
        }
    }
}
