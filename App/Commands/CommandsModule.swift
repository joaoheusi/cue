import AppKit
import CueKit
import SwiftUI

@MainActor @Observable final class CommandsModule {
    private(set) var snippets: [Snippet] = []
    private(set) var scripts: [Script] = []
    private(set) var apps: [FileHit] = []
    private(set) var snippetError: CueError?
    private(set) var hasKey = false
    private(set) var keyPreview: String?
    private(set) var keyTest: (valid: Bool, at: Date, message: String?)?
    private(set) var testingKey = false
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
        let service = prompts.snapshot?.settings.keyStorage == .keychain ? context.claudeKeyService : nil
        let loaded = await Task.detached(priority: .userInitiated) {
            (snippets: Result { () throws(CueError) in try Snippets.load(snippetsURL) },
             scripts: Scripts.list(in: scriptsFolder),
             apps: InstalledApps.list(),
             key: (try? Assistant.credentials(in: directory, storedKey: service.flatMap { ClaudeKey.load(service: $0) }))?.key)
        }.value
        scripts = loaded.scripts
        apps = loaded.apps
        hasKey = loaded.key != nil
        keyPreview = loaded.key.map(SensitiveText.mask)
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

    func copyPath(_ hit: FileHit) {
        context.closeCommand()
        Task { _ = await context.paste.deliver(hit.url.path, paste: false, target: nil, generation: nil, isCancelled: { false }, hide: {}) }
    }

    func run(_ script: Script) async throws(CueError) -> String {
        let timeout = TimeInterval(prompts.snapshot?.settings.scriptTimeout ?? Int(Scripts.timeout))
        let text = try await Scripts.run(script, timeout: timeout)
        let name = script.url.lastPathComponent
        await prompts.perform { try await $0.recordScriptUse(name) }
        return text
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
        for script in scripts {
            if let shortcut = shortcut(for: script) { _ = register(script, shortcut) }
        }
    }

    static func owner(_ script: Script) -> String { "script:\(script.url.lastPathComponent)" }

    func shortcut(for script: Script) -> Shortcut? {
        prompts.snapshot?.bindings[Self.owner(script)].flatMap(Shortcut.init)
    }

    func shortcutError(for script: Script) -> String? {
        context.hotKeys.statuses[Self.owner(script)]?.error
    }

    func setShortcut(_ shortcut: Shortcut?, for script: Script) async {
        let owner = Self.owner(script)
        if let shortcut, !register(script, shortcut) { return }
        if shortcut == nil { context.hotKeys.unregister(owner) }
        await prompts.perform { try await $0.saveBinding(owner: owner, chord: shortcut?.description ?? "") }
    }

    private func register(_ script: Script, _ shortcut: Shortcut) -> Bool {
        do {
            try context.hotKeys.register(Self.owner(script), shortcut) { [weak self] in
                guard let self else { return }
                Task {
                    do {
                        let text = try await self.run(script)
                        if case .failedBeforeCopy(let failure) = await self.copy(text) { self.prompts.report(script.name, failure) } else {
                            self.context.notifier.post(script.name, "Output copied to the clipboard.")
                        }
                    } catch {
                        self.prompts.report(script.name, error.cueError)
                    }
                }
            }
            status = nil
            return true
        } catch {
            status = (error.message, false)
            return false
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
            if context.hotKeys.statuses[command.owner]?.requested == nil {
                context.hotKeys.markUnavailable(command.owner, shortcut, reason: error.message)
            }
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

    var snippetsFile: URL { snippetsURL }

    func revealSnippets() {
        if !FileManager.default.fileExists(atPath: snippetsURL.path) { return openSnippets() }
        NSWorkspace.shared.activateFileViewerSelecting([snippetsURL])
    }

    func importSnippets() async {
        guard let existing = prompts.snapshot?.actions else { return }
        let actions = Snippets.actions(snippets, existing: existing)
        for action in actions {
            guard await prompts.perform(nil, { try await $0.save(action) }) != nil else { return }
        }
        let manager = FileManager.default
        let done = context.dataDirectory.appendingPathComponent("snippets.imported.json")
        try? manager.removeItem(at: done)
        try? manager.moveItem(at: snippetsURL, to: done)
        status = ("Added \(actions.count) action\(actions.count == 1 ? "" : "s") to the Library. The old file is now snippets.imported.json.", true)
        await reload()
    }

    private var storage: KeyStorage { prompts.snapshot?.settings.keyStorage ?? .env }

    private func writeKey(_ key: String?, to storage: KeyStorage) throws(CueError) {
        switch storage {
        case .keychain:
            if let key { try ClaudeKey.save(key, service: context.claudeKeyService) } else { ClaudeKey.delete(service: context.claudeKeyService) }
        case .env:
            let manager = FileManager.default
            try? manager.createDirectory(at: context.dataDirectory, withIntermediateDirectories: true)
            let current = (try? BoundedFile.read(envURL, maxBytes: 64 * 1024)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            do {
                try Data(DotEnv.setting(Assistant.keyName, to: key, in: current).utf8).write(to: envURL, options: .atomic)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envURL.path)
            } catch {
                throw CueError("KEY_SAVE_FAILED", "Cue could not write the .env file.")
            }
        }
    }

    func replaceKey() {
        let alert = NSAlert()
        alert.messageText = hasKey ? "Replace API key" : "Add API key"
        alert.informativeText = storage == .keychain ? "Cue saves the key in your Keychain." : "Cue saves the key in the .env file in its data folder."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "sk-ant-…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.takeFocus()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try writeKey(key, to: storage)
            keyTest = nil
            status = nil
        } catch {
            status = (error.message, false)
        }
        Task { await reload() }
    }

    func setKeyStorage(_ target: KeyStorage) async {
        let source = storage
        guard target != source else { return }
        let key = (try? prompts.credentials())?.key
        do {
            if let key { try writeKey(key, to: target) }
        } catch {
            status = (error.message, false)
            return
        }
        guard await prompts.saveSettings({ $0.keyStorage = target }) else {
            if key != nil { try? writeKey(nil, to: target) }
            status = ("Cue could not save this setting, so your key stayed where it was. Try again.", false)
            return
        }
        if key != nil {
            do {
                try writeKey(nil, to: source)
            } catch {
                status = ("Your key moved, but the old copy could not be removed. \(error.message)", false)
            }
        }
        await reload()
    }

    func testKey() async {
        testingKey = true
        defer { testingKey = false }
        do {
            try await Assistant.verify(try prompts.credentials())
            keyTest = (true, Date(), nil)
        } catch {
            keyTest = (false, Date(), error.cueError.message)
        }
    }

    func settingsView() -> AnyView { AnyView(ActionsSettingsView(module: self, prompts: prompts)) }

    func diagnostics() -> [(String, String)] {
        [
            ("API key", hasKey ? "yes (\(storage.rawValue))" : "no"),
            ("Snippets", snippetError?.code ?? "\(snippets.count)"),
            ("Scripts", "\(scripts.count)"),
            ("Window shortcuts", "\(WindowCommand.allCases.filter { shortcut(for: $0) != nil }.count)"),
        ]
    }
}
