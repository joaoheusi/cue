import AppKit
import CueKit
import SwiftUI
import UniformTypeIdentifiers

/// Hides, reveals, and arranges menu-bar items with two separators and user-defined rules.
@MainActor @Observable final class MenuBarModule {
    struct Reveal {
        var cause: MenuBarReveal.Cause
        var all: Bool
        var at: Date
    }

    static let hotKeyOwner = "menuBar"
    static let accessReason = "To list and arrange menu-bar items, Cue reads their positions and moves them with a simulated ⌘-drag."

    @ObservationIgnored private let context: AppContext
    @ObservationIgnored private var separators: MenuBarSeparators?
    @ObservationIgnored private var rehideTask: Task<Void, Never>?
    @ObservationIgnored private var frontmostObserver: NSObjectProtocol?
    @ObservationIgnored private var lastArrangeCode = "none"

    private(set) var storage: LoadState<MenuBarStore> = .loading
    private(set) var settings = MenuBarSettings()
    private(set) var rules: [MenuBarRule] = []
    /// nil until listed, or when listing is not possible (feature off or no Accessibility).
    private(set) var items: LoadState<[ScannedItem]>?
    private(set) var reveal: Reveal?
    private(set) var accessGranted = false
    private(set) var arranging = false
    private(set) var hotKeyError: String?
    var status: (text: String, success: Bool)?

    init(context: AppContext) { self.context = context }

    private var store: MenuBarStore? {
        if case .loaded(let store) = storage { store } else { nil }
    }

    // MARK: Lifecycle

    /// Opens storage, creates separators if enabled, and registers the hotkey. Never throws.
    func start() async {
        guard store == nil else { return }
        storage = .loading
        do {
            let store = try MenuBarStore(url: context.dataDirectory.appendingPathComponent("menubar.sqlite3"))
            let loaded = try await store.load()
            settings = loaded.settings
            rules = loaded.rules
            storage = .loaded(store)
        } catch {
            storage = .failed(error)
            context.log.record(error, "menuBar")
            return
        }
        refreshAccess()
        if frontmostObserver == nil {
            frontmostObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                MainActor.assumeIsolated { self?.frontmostChanged(bundleID) }
            }
        }
        if settings.enabled { activate() }
    }

    /// Called before quit. Opens both separators so nothing stays off-screen; quitting removes them.
    func stop() {
        rehideTask?.cancel()
        separators?.apply(.revealedAll)
        if let frontmostObserver { NSWorkspace.shared.notificationCenter.removeObserver(frontmostObserver) }
        frontmostObserver = nil
    }

    private func activate() {
        if separators == nil {
            let separators = MenuBarSeparators()
            separators.onClick = { [weak self] option in self?.clicked(option: option) }
            self.separators = separators
        }
        separators?.setVisible(true)
        hide()
        registerHotKey()
        frontmostChanged(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    private func deactivate() {
        rehideTask?.cancel()
        reveal = nil
        separators?.setVisible(false)
        context.hotKeys.unregister(Self.hotKeyOwner)
        hotKeyError = nil
        items = nil
    }

    // MARK: Hide and reveal

    var isRevealed: Bool { reveal != nil }

    func toggle() {
        isRevealed ? hide() : show(all: false, cause: .user)
    }

    func show(all: Bool, cause: MenuBarReveal.Cause) {
        guard let separators, settings.enabled, !arranging else { return }
        separators.apply(all ? .revealedAll : .revealed)
        reveal = Reveal(cause: cause, all: all, at: Date())
        rehideTask?.cancel()
        rehideTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let reveal = self.reveal else { return }
                if !self.arranging, MenuBarReveal.shouldRehide(now: Date(), revealedAt: reveal.at, seconds: self.settings.autoRehideSeconds,
                                                                cause: reveal.cause, pointerInMenuBar: Self.pointerInMenuBar) {
                    self.hide()
                    return
                }
            }
        }
    }

    func hide() {
        guard !arranging else { return }
        rehideTask?.cancel()
        reveal = nil
        separators?.apply(.collapsed)
    }

    private func clicked(option: Bool) {
        if option {
            reveal?.all == true ? hide() : show(all: true, cause: .user)
        } else {
            toggle()
        }
    }

    private func frontmostChanged(_ bundleID: String?) {
        guard settings.enabled, separators != nil, !arranging else { return }
        switch MenuBarReveal.onFrontmostChange(bundleID: bundleID, revealApps: settings.revealApps, revealedBy: reveal?.cause) {
        case true?: show(all: false, cause: .frontmostApp)
        case false?: hide()
        case nil: break
        }
    }

    private static var pointerInMenuBar: Bool {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.contains { $0.frame.contains(point) && point.y >= $0.frame.maxY - NSStatusBar.system.thickness }
    }

    // MARK: Hotkey

    private func registerHotKey() {
        let owner = Self.hotKeyOwner
        hotKeyError = nil
        guard settings.enabled, !context.isUITesting, let text = settings.shortcut else {
            context.hotKeys.unregister(owner)
            return
        }
        guard let shortcut = Shortcut(text) else {
            hotKeyError = "The saved shortcut is not valid. Record a new one."
            context.hotKeys.markUnavailable(owner, nil, reason: hotKeyError!)
            return
        }
        do {
            try context.hotKeys.register(owner, shortcut) { [weak self] in self?.toggle() }
        } catch {
            hotKeyError = error.message
            context.hotKeys.markUnavailable(owner, shortcut, reason: error.message)
            context.log.record(error, "menuBar")
        }
    }

    // MARK: Settings

    @discardableResult
    private func update(_ change: (inout MenuBarSettings) -> Void) async -> Bool {
        guard let store else { return false }
        var next = settings
        change(&next)
        do {
            try await store.save(next)
            settings = next
            return true
        } catch {
            report(error)
            return false
        }
    }

    func setEnabled(_ enabled: Bool) async {
        guard enabled != settings.enabled else { return }
        if enabled && !context.isUITesting {
            let alert = NSAlert()
            alert.messageText = "Hide menu bar items"
            alert.informativeText = """
            Cue adds a chevron (‹) to your menu bar. To hide an icon, hold ⌘ and drag it to the left of the chevron.

            Click the chevron or press \(settings.shortcut.flatMap(Shortcut.init)?.display ?? "the shortcut") to show hidden icons. ⌥-click the chevron to also show always-hidden icons.

            When you turn this off or quit Cue, every icon comes back.
            """
            alert.addButton(withTitle: "Turn On")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        guard await update({ $0.enabled = enabled }) else { return }
        enabled ? activate() : deactivate()
        status = nil
    }

    func setAutoRehide(_ text: String) async throws(CueError) {
        let seconds = try MenuBarValidation.rehideSeconds(text)
        await update { $0.autoRehideSeconds = seconds }
    }

    func addRevealApp(_ text: String) async throws(CueError) {
        let id = text.trimmingCharacters(in: .whitespaces)
        guard MenuBarValidation.isBundleID(id) else {
            throw .validation("Enter a bundle ID such as com.apple.Safari.")
        }
        guard !settings.revealApps.contains(id) else { return }
        guard settings.revealApps.count < MenuBarTransfer.maxRevealApps else {
            throw .validation("You can add up to \(MenuBarTransfer.maxRevealApps) apps.")
        }
        await update { $0.revealApps.append(id) }
    }

    func removeRevealApp(_ id: String) async {
        await update { $0.revealApps.removeAll { $0 == id } }
        frontmostChanged(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    func setShortcut(_ shortcut: Shortcut?) async {
        guard await update({ $0.shortcut = shortcut?.description }) else { return }
        registerHotKey()
    }

    // MARK: Rules

    func setRule(_ rule: MenuBarRule) async {
        guard let store else { return }
        do {
            try await store.upsert(rule)
            rules = MenuBarRules.upsert(rule, into: rules)
        } catch {
            report(error)
        }
    }

    func deleteRule(_ key: String) async {
        guard let store else { return }
        do {
            try await store.deleteRule(key: key)
            rules.removeAll { $0.key == key }
        } catch {
            report(error)
        }
    }

    /// Creates or updates the rule that puts `entry` in the next section left (-1) or right (+1), then applies it.
    func shift(_ entry: ScannedItem, by delta: Int) async {
        guard entry.item.movable else {
            status = ("macOS does not allow moving this item.", false)
            return
        }
        let target = entry.section.shifted(delta)
        guard target != entry.section else { return }
        let item = entry.item
        let label = item.label == item.appName ? item.appName : "\(item.appName) — \(item.label)"
        await setRule(MenuBarRule(key: item.key, bundleID: item.bundleID, label: label, section: target))
        await applyRules(only: [item.key])
    }

    // MARK: Accessibility

    func refreshAccess() {
        accessGranted = context.paste.canReadTarget
    }

    /// Explains why first, then shows the macOS prompt.
    func requestAccess() {
        guard !context.isUITesting else { return }
        if context.permissions.explain(.accessibility(reason: Self.accessReason)) {
            context.paste.requestAccess()
            status = ("After you allow Cue in System Settings, come back and try again.", true)
        }
    }

    func refreshItems() async {
        refreshAccess()
        guard settings.enabled, accessGranted, let separators else {
            items = nil
            return
        }
        if case .loaded = items {} else { items = .loading }
        let scanned = await MenuBarAccess.scan()
        guard let frames = separators.frames else {
            items = .failed(CueError("SEPARATOR_UNAVAILABLE", "The menu bar is not ready yet. Try again in a moment."))
            return
        }
        items = .loaded(scanned.map { entry in
            var entry = entry
            entry.section = MenuBarLayout.section(of: entry.item.frame, separators: frames)
            return entry
        }.sorted { a, b in
            a.section == b.section ? a.item.frame.minX > b.item.frame.minX
                : MenuBarSection.allCases.firstIndex(of: a.section)! > MenuBarSection.allCases.firstIndex(of: b.section)!
        })
    }

    /// Reveals the item's section, then opens its menu. Closes the command window first.
    func open(_ entry: ScannedItem) async {
        context.closeCommand()
        let needsReveal = switch entry.section {
        case .visible: false
        case .hidden: !isRevealed
        case .alwaysHidden: reveal?.all != true
        }
        if needsReveal {
            show(all: entry.section == .alwaysHidden, cause: .user)
            try? await Task.sleep(for: .milliseconds(300))
        }
        if !MenuBarAccess.press(entry) {
            report(CueError("ITEM_UNAVAILABLE", "Could not open that item. It may have closed. Open the list again."))
        }
    }

    /// Moves items to match the rules, one ⌘-drag at a time, verifying each move.
    /// Stops at the first failure. Restores the pointer and the previous reveal state.
    func applyRules(only keys: Set<String>? = nil) async {
        guard settings.enabled, let separators, !arranging else { return }
        refreshAccess()
        guard accessGranted, context.paste.canPostPaste else {
            requestAccess()
            return
        }
        let selected = keys.map { keys in rules.filter { keys.contains($0.key) } } ?? rules
        let previous = reveal
        arranging = true
        status = nil
        rehideTask?.cancel()
        separators.apply(.revealedAll)
        try? await Task.sleep(for: .milliseconds(300))

        var moved = 0
        var failure: CueError?
        var budget: Int?
        while failure == nil {
            guard let frames = separators.frames else {
                failure = CueError("SEPARATOR_UNAVAILABLE", "The menu bar is not ready yet. Try again in a moment.")
                break
            }
            let scanned = await MenuBarAccess.scan()
            let plan = MenuBarLayout.plan(items: scanned.map(\.item), separators: frames, rules: selected)
            // Each verified move removes one entry from the plan, so the first plan's size bounds the loop.
            if budget == nil { budget = plan.count }
            guard let move = plan.first, moved < budget!, let entry = scanned.first(where: { $0.item.key == move.key }) else { break }
            let start = CGPoint(x: entry.item.frame.midX, y: entry.midY)
            let end = CGPoint(x: MenuBarLayout.dropX(for: move.to, separators: frames), y: entry.midY)
            let posted = await MenuBarAccess.drag(from: start, to: end)
            try? await Task.sleep(for: .milliseconds(300))
            let after = await MenuBarAccess.scan().first { $0.item.key == move.key }
            if posted, let after, let frames = separators.frames, MenuBarLayout.section(of: after.item.frame, separators: frames) == move.to {
                moved += 1
            } else {
                failure = CueError("ARRANGE_FAILED", "Could not move “\(entry.item.label)” to \(move.to.title). Hold ⌘ and drag it there, then try again.")
            }
        }

        arranging = false
        if let previous { show(all: previous.all, cause: previous.cause) } else { hide() }
        lastArrangeCode = failure?.code ?? "OK"
        if let failure {
            report(failure)
        } else {
            status = (moved == 0 ? "Everything is already in place." : "Moved \(moved) item\(moved == 1 ? "" : "s").", true)
        }
        await refreshItems()
    }

    // MARK: Import and export

    func exportRules() {
        do {
            let data = try MenuBarTransfer.encode(settings: settings, rules: rules, exportedAt: Date())
            let name = SafeFilename.make("Cue Menu Bar Rules", ext: "json", date: Date())
            if try FileTransfer.save(data, suggestedName: name, type: .json) {
                status = ("Exported \(rules.count) rule\(rules.count == 1 ? "" : "s").", true)
            }
        } catch {
            report(error.cueError)
        }
    }

    /// Merges rules from a file. Never turns the feature on.
    func importRules() async {
        guard let store else { return }
        do {
            guard let data = try FileTransfer.open(type: .json, maxBytes: MenuBarTransfer.maxBytes) else { return }
            let decoded = try MenuBarTransfer.decode(data)
            try await store.importConfig(settings: decoded.settings, rules: decoded.rules)
            let loaded = try await store.load()
            settings = loaded.settings
            rules = loaded.rules
            registerHotKey()
            let count = decoded.rules.count
            status = ("Imported \(count) rule\(count == 1 ? "" : "s"). Choose Apply Rules Now to arrange the menu bar.", true)
        } catch {
            report(error.cueError)
        }
    }

    private func report(_ error: CueError) {
        context.log.record(error, "menuBar")
        status = (error.message, false)
    }

    // MARK: Views

    func commandView() -> AnyView { AnyView(MenuBarCommandView(module: self)) }

    func settingsView() -> AnyView { AnyView(MenuBarSettingsView(module: self)) }

    /// Counts and settings only. Never item names, labels, keys, or bundle IDs.
    func diagnostics() async -> [(String, String)] {
        var counts = "not listed"
        if case .loaded(let entries) = items {
            counts = MenuBarSection.allCases.map { section in "\(section.rawValue) \(entries.filter { $0.section == section }.count)" }.joined(separator: ", ")
        }
        let storageState = switch storage {
        case .loading: "loading"
        case .failed(let error): error.code
        case .loaded: "ok"
        }
        return [
            ("Enabled", settings.enabled ? "yes" : "no"),
            ("Storage", storageState),
            ("Accessibility (list items)", context.paste.canReadTarget ? "granted" : "not granted"),
            ("Accessibility (move items)", context.paste.canPostPaste ? "granted" : "not granted"),
            ("Items", counts),
            ("Rules", String(rules.count)),
            ("Auto-hide seconds", String(settings.autoRehideSeconds)),
            ("Reveal-while-frontmost apps", String(settings.revealApps.count)),
            ("Shortcut", settings.shortcut ?? "none"),
            ("Revealed", reveal.map { $0.all ? "all" : "hidden" } ?? "no"),
            ("Last arrange", lastArrangeCode),
        ]
    }
}
