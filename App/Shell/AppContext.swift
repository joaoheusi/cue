import AppKit
import CueKit

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

@MainActor final class AppContext {
    let dataDirectory: URL
    let isUITesting: Bool
    let hotKeys = HotKeyCenter()
    let paste = PasteService()
    let permissions = PermissionCoordinator()
    let log = DiagnosticsLog()
    let updater: AppUpdater

    var invocation: Invocation?

    var openCommand: (CommandScope) -> Void = { _ in }
    var closeCommand: () -> Void = {}
    var showCommandPassively: () -> Void = {}
    var openLibrary: (_ actionID: String?) -> Void = { _ in }
    var openSettings: (SettingsTab) -> Void = { _ in }

    init() {
        let environment = ProcessInfo.processInfo.environment
        isUITesting = CommandLine.arguments.contains("--ui-testing")
        #if DEBUG
        updater = AppUpdater(enabled: false)
        #else
        updater = AppUpdater(enabled: !isUITesting)
        #endif
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

    var keychainService: String {
        let name = dataDirectory.lastPathComponent
        return name.hasPrefix("app.cue.launcher") ? "\(name).clipboard" : "app.cue.launcher.custom.\(name).clipboard"
    }

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}

@MainActor final class Invocation {
    let id = UUID()
    let created = Date()
    let target: Result<PasteTarget, CueError>
    var consumed = false
    var cancelled = false

    init(target: Result<PasteTarget, CueError>) { self.target = target }

    var expired: Bool { consumed || cancelled || Date().timeIntervalSince(created) > 300 }
}

@MainActor final class DiagnosticsLog {
    private(set) var entries: [String] = []

    func record(_ code: String, _ context: String) {
        entries.append("\(Timestamp.now()) \(context) \(code)")
        if entries.count > 200 { entries.removeFirst(entries.count - 200) }
    }

    func record(_ error: CueError, _ context: String) { record(error.code, context) }
}
