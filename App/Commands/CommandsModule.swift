import AppKit
import CueKit
import SwiftUI

@MainActor @Observable final class CommandsModule {
    private(set) var snippets: [Snippet] = []
    private(set) var scripts: [Script] = []
    private(set) var apps: [FileHit] = []
    private(set) var snippetError: CueError?
    private(set) var hasKey = false
    var status: (text: String, success: Bool)?
    let files = FileSearch()

    @ObservationIgnored let context: AppContext
    @ObservationIgnored private let prompts: PromptsModel
    @ObservationIgnored private let windows = WindowManager()

    init(context: AppContext, prompts: PromptsModel) {
        self.context = context
        self.prompts = prompts
    }

    private var snippetsURL: URL { context.dataDirectory.appendingPathComponent(Snippets.fileName) }
    private var scriptsFolder: URL { context.dataDirectory.appendingPathComponent(Scripts.folderName, isDirectory: true) }
    private var envURL: URL { context.dataDirectory.appendingPathComponent(Assistant.fileName) }

    func start() async {
        await reload()
        restoreShortcuts()
    }

    func reload() async {
        let snippetsURL, scriptsFolder, directory: URL
        (snippetsURL, scriptsFolder, directory) = (self.snippetsURL, self.scriptsFolder, context.dataDirectory)
        let loaded = await Task.detached(priority: .userInitiated) {
            (snippets: Result { () throws(CueError) in try Snippets.load(snippetsURL) },
             scripts: Scripts.list(in: scriptsFolder),
             apps: InstalledApps.list(),
             hasKey: (try? Assistant.credentials(in: directory)) != nil)
        }.value
        scripts = loaded.scripts
        apps = loaded.apps
        hasKey = loaded.hasKey
        switch loaded.snippets {
        case .success(let list):
            snippets = list
            snippetError = nil
        case .failure(let error):
            snippetError = error
        }
    }

    func apply(_ command: WindowCommand, to app: NSRunningApplication?) -> CueError? {
        windows.apply(command, to: app)
    }

    func open(_ hit: FileHit, reveal: Bool) {
        context.closeCommand()
        if reveal {
            NSWorkspace.shared.activateFileViewerSelecting([hit.url])
        } else {
            NSWorkspace.shared.open(hit.url)
        }
    }

    func copy(_ text: String) async -> Delivery {
        await context.paste.deliver(text, paste: false, target: nil, generation: nil, isCancelled: { false }, hide: context.closeCommand)
    }

    func shortcut(for command: WindowCommand) -> Shortcut? {
        prompts.snapshot?.bindings[command.owner].flatMap(Shortcut.init)
    }

    func shortcutError(for command: WindowCommand) -> String? {
        context.hotKeys.statuses[command.owner]?.error
    }

    func setShortcut(_ shortcut: Shortcut?, for command: WindowCommand) async {
        if let shortcut, !register(command, shortcut) { return }
        if shortcut == nil { context.hotKeys.unregister(command.owner) }
        await prompts.perform { try await $0.saveBinding(owner: command.owner, chord: shortcut?.description ?? "") }
    }

    private func restoreShortcuts() {
        guard !context.isUITesting else { return }
        for command in WindowCommand.allCases {
            if let shortcut = shortcut(for: command) { _ = register(command, shortcut) }
        }
    }

    private func register(_ command: WindowCommand, _ shortcut: Shortcut) -> Bool {
        do {
            try context.hotKeys.register(command.owner, shortcut) { [weak self] in
                guard let self, let error = apply(command, to: NSWorkspace.shared.frontmostApplication) else { return }
                if error.code == "PERMISSION_REQUIRED" {
                    if context.permissions.explain(.accessibility(reason: WindowManager.accessReason)) { context.paste.requestAccess() }
                } else {
                    context.notifier.post(command.title, error.message) { self.context.log.record(error, "windows") }
                }
            }
            status = nil
            return true
        } catch {
            status = (error.message, false)
            context.hotKeys.markUnavailable(command.owner, shortcut, reason: error.message)
            return false
        }
    }

    func openEnv() {
        let manager = FileManager.default
        try? manager.createDirectory(at: context.dataDirectory, withIntermediateDirectories: true)
        if !manager.fileExists(atPath: envURL.path) {
            manager.createFile(atPath: envURL.path, contents: Data(Assistant.template.utf8), attributes: [.posixPermissions: 0o600])
        }
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envURL.path)
        openInEditor(envURL)
    }

    func openSnippets() {
        let manager = FileManager.default
        try? manager.createDirectory(at: context.dataDirectory, withIntermediateDirectories: true)
        if !manager.fileExists(atPath: snippetsURL.path) {
            manager.createFile(atPath: snippetsURL.path, contents: Data(Snippets.sample.utf8))
        }
        openInEditor(snippetsURL)
    }

    func showScripts() {
        try? FileManager.default.createDirectory(at: scriptsFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(scriptsFolder)
    }

    private func openInEditor(_ url: URL) {
        if NSWorkspace.shared.urlForApplication(toOpen: url) == nil,
           let editor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func settingsView() -> AnyView { AnyView(CommandsSettingsView(module: self)) }

    func diagnostics() -> [(String, String)] {
        [
            ("API key in .env", hasKey ? "yes" : "no"),
            ("Snippets", snippetError?.code ?? "\(snippets.count)"),
            ("Scripts", "\(scripts.count)"),
            ("Window shortcuts", "\(WindowCommand.allCases.filter { shortcut(for: $0) != nil }.count)"),
        ]
    }
}

struct CommandsSettingsView: View {
    let module: CommandsModule

    var body: some View {
        Form {
            Section("Claude") {
                LabeledContent("API key", value: module.hasKey ? "Found in .env" : "Not set")
                Text("Fix Grammar, Summarize, and Translate are actions in your library. Turn on Run through Claude for any other action. Cue sends text to Anthropic only when you run one of these actions, and nothing else leaves this Mac.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Open .env") { module.openEnv() }
            }
            Section("Snippets") {
                Text("Add { \"keyword\", \"expansion\" } entries to snippets.json. Search for a keyword in the command window. {date}, {time}, and {clipboard} are filled in when you use a snippet.")
                    .font(.callout).foregroundStyle(.secondary)
                if let error = module.snippetError { ErrorBanner(error: error) }
                LabeledContent("Saved", value: "\(module.snippets.count)")
                Button("Open snippets.json") { module.openSnippets() }
            }
            Section("Scripts") {
                Text("Each file in the commands folder appears in the command window by its name. Return copies its output. Shift-Return shows it. Cue stops a script after \(Int(Scripts.timeout)) seconds.")
                    .font(.callout).foregroundStyle(.secondary)
                LabeledContent("Found", value: "\(module.scripts.count)")
                Button("Show Commands Folder") { module.showScripts() }
            }
            Section("Window shortcuts") {
                ForEach(WindowCommand.allCases) { command in
                    LabeledContent(command.title) {
                        VStack(alignment: .trailing, spacing: 2) {
                            ShortcutRecorder(value: module.shortcut(for: command)) { shortcut in
                                Task { await module.setShortcut(shortcut, for: command) }
                            }
                            if let error = module.shortcutError(for: command) {
                                Text(error).font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                }
                if let status = module.status { StatusLine(text: status.text, success: status.success) }
            }
        }
        .formStyle(.grouped)
        .task { await module.reload() }
    }
}
