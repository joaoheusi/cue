import AppKit
import CueKit
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let context = AppContext()
    private(set) lazy var prompts = PromptsModule(context: context)
    private(set) lazy var commands = CommandsModule(context: context, prompts: prompts.model)
    private(set) lazy var clipboard = ClipboardModule(context: context)
    private(set) lazy var menuBar = MenuBarModule(context: context)
    private var command: CommandWindowController!
    private var settings: SettingsWindowController!
    private var statusItem: NSStatusItem?
    private var statusBadge: NSView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !context.isUITesting, let running = others.first {
            running.activate()
            NSApp.terminate(nil)
            return
        }
        prompts.commands = commands
        command = CommandWindowController(context: context) { [unowned self] scope in
            switch scope {
            case .prompts: AnyView(PaletteView(model: prompts.model, commands: commands, clipboard: clipboard))
            case .clipboard: clipboard.commandView()
            case .menuBar: menuBar.commandView()
            }
        }
        settings = SettingsWindowController { [unowned self] in
            [
                (.general, prompts.generalSettingsView()),
                (.shortcuts, AnyView(ShortcutsSettingsView(model: prompts.model, commands: commands, clipboard: clipboard, menuBar: menuBar))),
                (.palette, prompts.settingsView()),
                (.clipboard, clipboard.settingsView()),
                (.menuBar, menuBar.settingsView()),
                (.actions, commands.settingsView()),
                (.privacy, AnyView(PrivacySettingsView(context: context, diagnostics: diagnosticsReport))),
            ]
        }
        context.openCommand = { [unowned self] in command.toggle($0) }
        context.closeCommand = { [unowned self] in command.hide(cancel: false) }
        context.showCommandPassively = { [unowned self] in command.showPassively() }
        context.commandVisible = { [unowned self] in command.isVisible }
        context.canQuit = { [unowned self] in prompts.canQuit() }
        context.hotKeys.onChange = { [weak self] in self?.refreshStatusIcon() }
        context.updater.onChange = { [weak self] in self?.refreshStatusIcon() }
        context.openSettings = { [unowned self] in
            command.hide(cancel: true)
            settings.show($0)
        }
        context.openLibrary = { [unowned self] in
            command.hide(cancel: true)
            prompts.openLibrary($0)
        }
        installMainMenu()
        context.updater.isIdle = { [unowned self] in
            !command.isVisible && !prompts.hasUnsavedChanges && !menuBar.arranging && NSApp.modalWindow == nil
        }
        installStatusItem()
        Task {
            await prompts.start()
            await commands.start()
            await clipboard.start()
            await menuBar.start()
            if context.isUITesting {
                NSApp.takeFocus()
                command.show(.prompts)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { prompts.openLibrary(nil) }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        context.quitApproved || prompts.canQuit() ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        context.invocation?.cancelled = true
        menuBar.stop()
        clipboard.stop()
        prompts.stop()
        context.hotKeys.unregisterAll()
    }

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

    private func installStatusItem() {
        NSStatusItem.seedPosition("cue.main", 0)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "cue.main"
        item.button?.image = Self.statusImage
        item.button?.setAccessibilityLabel("Cue")
        item.button?.setAccessibilityIdentifier("cue.statusItem")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        refreshStatusIcon()
    }

    private static let statusImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let center = NSPoint(x: 8.8, y: 9)
            let ring = NSBezierPath()
            ring.appendArc(withCenter: center, radius: 5.6, startAngle: 45, endAngle: 315)
            ring.lineWidth = 1.7
            ring.lineCapStyle = .round
            ring.stroke()
            NSBezierPath(ovalIn: NSRect(x: center.x + 5.6 - 1.3, y: center.y - 1.3, width: 2.6, height: 2.6)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()

    private func refreshStatusIcon() {
        guard let button = statusItem?.button else { return }
        button.appearsDisabled = context.hotKeys.paused
        if statusBadge == nil {
            let badge = NSView()
            badge.wantsLayer = true
            badge.layer?.backgroundColor = NSColor.systemBlue.cgColor
            badge.layer?.cornerRadius = 3
            button.addSubview(badge)
            statusBadge = badge
        }
        statusBadge?.frame = NSRect(x: button.bounds.maxX - 8, y: button.isFlipped ? 2 : button.bounds.maxY - 8, width: 6, height: 6)
        statusBadge?.isHidden = context.updater.readyVersion == nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        let paused = context.hotKeys.paused
        let update = context.updater.readyVersion
        if paused {
            let age = context.hotKeys.pausedAt.map { "Paused \(ShortAge.text($0))" } ?? "Paused"
            addStatus(menu, "Resume Shortcuts", detail: age, color: .systemOrange) { [unowned self] in context.hotKeys.setPaused(false) }
        }
        if let update {
            addStatus(menu, "Restart to Update", detail: update, color: .systemBlue) { [unowned self] in context.updater.restartToUpdate() }
        }
        if paused || update != nil { menu.addItem(.separator()) }
        add(menu, "Search", "magnifyingglass", shortcut: shortcut(.prompts), enabled: !paused) { [unowned self] in command.show(.prompts) }
        add(menu, "Clipboard", "clipboard", shortcut: shortcut(.clipboard), enabled: !paused) { [unowned self] in command.show(.clipboard) }
        add(menu, "Menu Bar Items", "menubar.rectangle", shortcut: shortcut(.menuBar), enabled: !paused) { [unowned self] in command.show(.menuBar) }
        menu.addItem(.separator())
        let hideShortcut = menuBar.settings.shortcut.flatMap(Shortcut.init)
        if menuBar.settings.enabled {
            let revealed = menuBar.isRevealed
            add(menu, revealed ? "Hide Items" : "Show Hidden Items", revealed ? "eye.slash" : "eye", shortcut: hideShortcut) { [unowned self] in menuBar.toggle() }
        } else {
            add(menu, "Turn On Menu Bar Hiding…", "eye") { [unowned self] in Task { await menuBar.setEnabled(true) } }
        }
        menu.addItem(.separator())
        add(menu, "Library…", "doc.text", key: "l") { [unowned self] in context.openLibrary(nil) }
        add(menu, "Settings…", "gearshape", key: ",") { [unowned self] in context.openSettings(.general) }
        menu.addItem(.separator())
        if !paused {
            add(menu, "Pause Shortcuts", "pause") { [unowned self] in context.hotKeys.setPaused(true) }
        }
        if context.updater.isAvailable, update == nil {
            add(menu, "Check for Updates…", "arrow.clockwise") { [unowned self] in context.updater.checkNow() }
        }
        if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
        add(menu, "Quit Cue", nil, key: "q") { NSApp.terminate(nil) }
    }

    private func shortcut(_ scope: CommandScope) -> Shortcut? {
        let snapshot = prompts.model.snapshot
        return switch scope {
        case .prompts: Shortcut(snapshot?.bindings["palette"] ?? snapshot?.settings.paletteShortcut ?? "")
        case .clipboard: clipboard.settings.shortcut.flatMap(Shortcut.init)
        case .menuBar: Shortcut(snapshot?.settings.menuBarScopeShortcut ?? "")
        }
    }

    private func add(_ menu: NSMenu, _ title: String, _ symbol: String?, key: String = "", shortcut: Shortcut? = nil, enabled: Bool = true,
                     action: @escaping @MainActor () -> Void) {
        menu.add(title, image: symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }, key: shortcut?.menuKey ?? key, action: action)
        guard let item = menu.items.last else { return }
        item.isEnabled = enabled
        if let shortcut {
            var mask: NSEvent.ModifierFlags = []
            if shortcut.command { mask.insert(.command) }
            if shortcut.control { mask.insert(.control) }
            if shortcut.option { mask.insert(.option) }
            if shortcut.shift { mask.insert(.shift) }
            item.keyEquivalentModifierMask = mask
        }
    }

    private func addStatus(_ menu: NSMenu, _ title: String, detail: String, color: NSColor, action: @escaping @MainActor () -> Void) {
        let dot = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 4, y: 4, width: 8, height: 8)).fill()
            return true
        }
        menu.add(title, image: dot, action: action)
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: 230)]
        let text = NSMutableAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0).withWeight(.semibold), .paragraphStyle: style])
        text.append(NSAttributedString(string: "\t\(detail)", attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]))
        menu.items.last?.attributedTitle = text
    }

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
            (owner, "\(status.requested?.description ?? "none") — \(status.active ? "active" : status.error ?? "inactive")")
        }))
        sections.append(("Updates", context.updater.diagnostics))
        sections.append(("Prompts", await prompts.diagnostics()))
        sections.append(("Commands", commands.diagnostics()))
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
