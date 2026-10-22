import AppKit
import CueKit

/// The three areas of Cue. Each one has its own command-window scope, settings tab, and data file.
enum CommandScope: String, CaseIterable, Identifiable {
    case prompts, clipboard, menuBar
    var id: String { rawValue }
    var title: String {
        switch self {
        case .prompts: "Prompts"
        case .clipboard: "Clipboard"
        case .menuBar: "Menu Bar"
        }
    }
    var symbol: String {
        switch self {
        case .prompts: "text.cursor"
        case .clipboard: "doc.on.clipboard"
        case .menuBar: "menubar.rectangle"
        }
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, prompts, clipboard, menuBar, data
    var id: String { rawValue }
}

/// Services shared by every module. Created once by `AppDelegate`.
@MainActor final class AppContext {
    let dataDirectory: URL
    /// Set by UI tests: no global hotkeys, no permission prompts, temporary data.
    let isUITesting: Bool
    let hotKeys = HotKeyCenter()
    let paste = PasteService()
    let permissions = PermissionCoordinator()
    let log = DiagnosticsLog()

    /// The paste target captured just before the command window opened. Consumed by one delivery.
    var invocation: Invocation?

    // Window routing. `AppDelegate` installs these closures.
    var openCommand: (CommandScope) -> Void = { _ in }
    var closeCommand: () -> Void = {}
    var openLibrary: (_ actionID: String?) -> Void = { _ in }
    var openSettings: (SettingsTab) -> Void = { _ in }

    init() {
        let environment = ProcessInfo.processInfo.environment
        isUITesting = CommandLine.arguments.contains("--ui-testing")
        if let custom = environment["CUE_DATA_DIR"], custom.hasPrefix("/") {
            dataDirectory = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            #if DEBUG
            dataDirectory = support.appendingPathComponent("app.cue.launcher.dev", isDirectory: true)
            #else
            dataDirectory = support.appendingPathComponent("app.cue.launcher", isDirectory: true)
            #endif
        }
    }

    /// Keychain service that holds the clipboard-history key. Separate per data folder.
    var keychainService: String {
        let name = dataDirectory.lastPathComponent
        return name.hasPrefix("app.cue.launcher") ? "\(name).clipboard" : "app.cue.launcher.custom.\(name).clipboard"
    }

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}

/// One opening of the command window. Paste delivery is allowed once per invocation.
@MainActor final class Invocation {
    let id = UUID()
    let created = Date()
    let target: Result<PasteTarget, CueError>
    var consumed = false
    var cancelled = false

    init(target: Result<PasteTarget, CueError>) { self.target = target }

    var expired: Bool { consumed || cancelled || Date().timeIntervalSince(created) > 300 }
}

/// Keeps the last 200 error codes for the diagnostics export. Never stores user content.
@MainActor final class DiagnosticsLog {
    private(set) var entries: [String] = []

    func record(_ code: String, _ context: String) {
        entries.append("\(Timestamp.now()) \(context) \(code)")
        if entries.count > 200 { entries.removeFirst(entries.count - 200) }
    }

    func record(_ error: CueError, _ context: String) { record(error.code, context) }
}
