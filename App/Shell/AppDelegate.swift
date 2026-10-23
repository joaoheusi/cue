import AppKit
import CueKit
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let context = AppContext()
    private(set) lazy var prompts = PromptsModule(context: context)
    private(set) lazy var clipboard = ClipboardModule(context: context)
    private(set) lazy var menuBar = MenuBarModule(context: context)
    private var command: CommandWindowController!
    private var settings: SettingsWindowController!
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        command = CommandWindowController(context: context) { [unowned self] scope in
            switch scope {
            case .prompts: prompts.commandView()
            case .clipboard: clipboard.commandView()
            case .menuBar: menuBar.commandView()
            }
        }
        settings = SettingsWindowController { [unowned self] in
            [
                (.general, "General", "gearshape", prompts.generalSettingsView()),
                (.prompts, "Prompts", CommandScope.prompts.symbol, prompts.settingsView()),
                (.clipboard, "Clipboard", CommandScope.clipboard.symbol, clipboard.settingsView()),
                (.menuBar, "Menu Bar", CommandScope.menuBar.symbol, menuBar.settingsView()),
                (.data, "Data & Privacy", "lock.shield", AnyView(DataSettingsView(context: context, diagnostics: diagnosticsReport))),
            ]
        }
        // Hotkeys and menu items toggle: pressing the same shortcut again closes the window.
        context.openCommand = { [unowned self] in command.toggle($0) }
        context.closeCommand = { [unowned self] in command.hide(cancel: false) }
        context.showCommandPassively = { [unowned self] in command.showPassively() }
        context.openSettings = { [unowned self] in
            command.hide(cancel: true)
            settings.show($0)
        }
        context.openLibrary = { [unowned self] in
            command.hide(cancel: true)
            prompts.openLibrary($0)
        }
        installMainMenu()
        // Create Cue's own item first so it sits right of the menu-bar module's separators.
        installStatusItem()
        Task {
            await prompts.start()
            await clipboard.start()
            await menuBar.start()
            if context.isUITesting {
                // The test runner launches Cue in the background; take focus so typing reaches the panel.
                NSApp.activate()
                command.show(.prompts)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { prompts.openLibrary(nil) }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        prompts.canQuit() ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        context.invocation?.cancelled = true
        menuBar.stop()
        clipboard.stop()
        prompts.stop()
        context.hotKeys.unregisterAll()
    }

    /// Menu-bar apps show no main menu, but text fields still need its key equivalents (⌘A, ⌘C, ⌘V, ⌘Z…).
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu(title: "Cue")
        appItem.submenu?.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        appItem.submenu?.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appItem.submenu?.addItem(withTitle: "Quit Cue", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.items = [appItem, editItem]
        NSApp.mainMenu = main
    }

    @objc private func showSettings() { context.openSettings(.general) }

    // MARK: Menu bar icon

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "cue.main"
        item.button?.image = NSImage(systemSymbolName: "text.cursor", accessibilityDescription: "Cue")
        item.button?.setAccessibilityIdentifier("cue.statusItem")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let release = prompts.availableUpdate {
            add(menu, "Cue \(release.version) Available…", "arrow.down.circle") { NSWorkspace.shared.open(release.page) }
            menu.addItem(.separator())
        }
        for scope in CommandScope.allCases {
            add(menu, "Open \(scope.title)", scope.symbol) { [unowned self] in command.show(scope) }
        }
        menu.addItem(.separator())
        add(menu, "Manage Prompts…", "list.bullet.rectangle") { [unowned self] in context.openLibrary(nil) }
        add(menu, "Settings…", "gearshape", key: ",") { [unowned self] in context.openSettings(.general) }
        let paused = context.hotKeys.paused
        add(menu, paused ? "Resume Shortcuts" : "Pause Shortcuts", paused ? "play.circle" : "pause.circle") { [unowned self] in
            context.hotKeys.setPaused(!paused)
        }
        menu.addItem(.separator())
        add(menu, "Quit Cue", "power", key: "q") { NSApp.terminate(nil) }
    }

    private func add(_ menu: NSMenu, _ title: String, _ symbol: String, key: String = "", action: @escaping @MainActor () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: key)
        let target = MenuAction(action)
        item.target = target
        item.representedObject = target // keeps the target alive
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        menu.addItem(item)
    }

    // MARK: Diagnostics

    private func diagnosticsReport() async -> String {
        var sections: [(String, [(String, String)])] = []
        let info = ProcessInfo.processInfo
        sections.append(("Cue", [
            ("Version", "\(context.version) (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))"),
            ("Bundle", Bundle.main.bundleIdentifier ?? "?"),
            ("macOS", info.operatingSystemVersionString),
            ("Architecture", Self.architecture),
            ("Data folder", context.dataDirectory.path),
            ("Launch at login", LaunchAtLogin.statusText),
        ]))
        sections.append(("Permissions", [
            ("Accessibility (read target)", context.paste.canReadTarget ? "granted" : "not granted"),
            ("Accessibility (post paste)", context.paste.canPostPaste ? "granted" : "not granted"),
        ]))
        sections.append(("Shortcuts", context.hotKeys.statuses.sorted { $0.key < $1.key }.map { owner, status in
            // Action shortcuts are listed by ID only, never by name.
            (owner, "\(status.requested?.description ?? "none") — \(status.active ? "active" : status.error ?? "inactive")")
        }))
        sections.append(("Prompts", await prompts.diagnostics()))
        sections.append(("Clipboard", await clipboard.diagnostics()))
        sections.append(("Menu Bar", await menuBar.diagnostics()))
        sections.append(("Recent errors", context.log.entries.suffix(50).map { ("", $0) }))
        var text = "Cue diagnostics — \(Timestamp.now())\nThis report contains no prompts, clipboard text, or menu-bar item names.\n"
        for (title, entries) in sections {
            text += "\n## \(title)\n"
            text += entries.isEmpty ? "(none)\n" : entries.map { $0.0.isEmpty ? "\($0.1)\n" : "\($0.0): \($0.1)\n" }.joined()
        }
        return text
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }
}

@MainActor private final class MenuAction: NSObject {
    let action: @MainActor () -> Void
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    @objc func run() { action() }
}
