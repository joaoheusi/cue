import AppKit
import Carbon.HIToolbox
import CryptoKit
import CueKit
import SwiftUI
import UniformTypeIdentifiers

struct ClipboardStatus: Equatable {
    var text: String
    var success: Bool
}

@MainActor @Observable final class ClipboardModule {
    enum Phase: Equatable {
        case loading, ready
        case failed(CueError)
    }

    private(set) var phase = Phase.loading
    private(set) var items: [ClipItem] = []
    private(set) var pinboards: [Pinboard] = []
    private(set) var settings = ClipboardSettings()
    private(set) var captureEnabled = false
    private(set) var capturePaused = false
    private(set) var accessDenied = false
    private(set) var hotKeyError: String?
    private(set) var reader = ClipboardReaderState()
    var commandStatus: ClipboardStatus?
    var settingsStatus: ClipboardStatus?

    @ObservationIgnored private let context: AppContext
    @ObservationIgnored private var store: ClipboardStore?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var purgeTask: Task<Void, Never>?
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var lastChangeCount = 0
    @ObservationIgnored private var capturedChangeCount: Int?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var skipCounts: [SkipReason: Int] = [:]
    @ObservationIgnored private var capturedCount = 0
    @ObservationIgnored private var keychainKind: ClipboardKeychain.Kind?
    @ObservationIgnored private var appNames: [String: String] = [:]
    @ObservationIgnored private var launchClearDone = false

    private static let owner = "clipboard"
    static let accessDeniedError = CueError(
        "CLIPBOARD_ACCESS_DENIED",
        "macOS is blocking Cue from reading the clipboard, so new copies are not saved. Allow Cue in System Settings → Privacy & Security → Paste.")
    static let readerFailedError = CueError(
        "CLIPBOARD_READ_FAILED",
        "Cue could not read your last few copies, so they were not saved. Copy again to try once more. If this keeps happening, quit and reopen Cue.")

    init(context: AppContext) { self.context = context }

    func start() async {
        await openStore()
        activateSavedHotKey()
        Task { await loadHistory() }
        purgeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(600))
                await self?.purge()
            }
        }
    }

    func stop() {
        stopCapture()
        purgeTask?.cancel()
        expiryTask?.cancel()
    }

    var frontName: String? { context.invocation?.front?.localizedName }

    var readerError: CueError? { captureEnabled && reader.failing ? Self.readerFailedError : nil }

    func openSettings() { context.openSettings(.clipboard) }

    var latest: ClipItem? {
        capturedChangeCount == NSPasteboard.general.changeCount ? items.max { $0.lastUsedAt < $1.lastUsedAt } : nil
    }

    func commandView() -> AnyView { AnyView(ClipboardCommandView(module: self)) }

    func settingsView() -> AnyView { AnyView(ClipboardSettingsView(module: self)) }

    func diagnostics() async -> [(String, String)] {
        var rows: [(String, String)] = []
        switch phase {
        case .loading: rows.append(("State", "loading"))
        case .ready: rows.append(("State", "ready"))
        case .failed(let error): rows.append(("State", error.code))
        }
        if let store, let counts = try? await store.counts() {
            rows.append(("Items", "\(counts.items) (\(items.count) readable)"))
            rows.append(("Pinned items", "\(counts.pinned)"))
        }
        rows += [
            ("Pinboards", "\(pinboards.count)"),
            ("Capture", captureEnabled ? (pollTask != nil ? "on" : "on, paused") : "off"),
            ("Pasteboard access behavior", ClipboardReader.access.rawValue),
            ("Keychain", keychainKind?.rawValue ?? "not used"),
            ("Retention", settings.retention.rawValue),
            ("Max unpinned items", "\(settings.maxItems)"),
            ("Excluded apps", "\(settings.excludedApps.count)"),
            ("Shortcut", settings.shortcut ?? "none"),
            ("Captured this session", "\(capturedCount)"),
        ]
        rows += reader.diagnostics
        rows += SkipReason.allCases.map { ("Skipped: \($0.rawValue)", "\(skipCounts[$0, default: 0])") }
        return rows
    }

    private func openStore() async {
        let url = context.dataDirectory.appendingPathComponent(ClipboardStore.fileName)
        do {
            let store = try await Task.detached { try ClipboardStore(url: url) }.value
            self.store = store
            settings = await store.settings
            captureEnabled = await store.captureEnabled
            capturePaused = await store.capturePaused
            pinboards = await store.pinboards
        } catch {
            fail(error)
        }
    }

    private func loadHistory() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        if store == nil { await openStore() }
        guard let store else { return }
        phase = .loading
        do {
            if !launchClearDone {
                if settings.clearOnQuit { try await store.clear(keepPinned: true) }
                launchClearDone = true
            }
            try await store.purge(now: Date())
            let needsKey = try await captureEnabled ? true : store.itemCount() > 0
            if needsKey, !(await store.isUnlocked) { try await unlock(store) }
            await refresh()
            phase = .ready
            if captureEnabled { startCapture() }
        } catch {
            fail(error)
        }
    }

    private func unlock(_ store: ClipboardStore) async throws {
        let create = try await store.itemCount() == 0
        let service = context.keychainService
        let loaded = try await Task.detached { try ClipboardKeychain.load(service: service, create: create) }.value
        guard let (key, kind) = loaded else { throw ClipboardStore.keyUnavailable }
        keychainKind = kind
        try await store.unlock(key)
    }

    private func refresh() async {
        guard let store else { return }
        items = await store.items()
        pinboards = await store.pinboards
        settings = await store.settings
        scheduleExpiry()
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        guard let next = items.compactMap(\.expiresAt).min() else { return }
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow + 0.5)))
            if !Task.isCancelled { await self?.purge() }
        }
    }

    private func purge() async {
        guard let store else { return }
        do {
            if try await store.purge(now: Date()) > 0 { await refresh() }
        } catch {
            context.log.record(error.cueError, "clipboard")
        }
    }

    func retry() {
        Task { await loadHistory() }
    }

    private func fail(_ error: Error) {
        stopCapture()
        context.log.record(error.cueError, "clipboard")
        phase = .failed(error.cueError)
    }

    func setCaptureEnabled(_ enabled: Bool) {
        guard let store, enabled != captureEnabled else { return }
        if enabled, !capturePaused, !context.permissions.explain(.clipboard, continueTitle: "Turn On") { return }
        Task {
            do {
                if enabled, !(await store.isUnlocked) { try await unlock(store) }
                try await store.setCaptureEnabled(enabled)
                captureEnabled = enabled
                capturePaused = !enabled
                if enabled {
                    await refresh()
                    phase = .ready
                    startCapture()
                } else {
                    stopCapture()
                }
            } catch {
                error.cueError == ClipboardStore.keyUnavailable ? fail(error) : report(error, .settings)
            }
        }
    }

    private func startCapture() {
        pollTask?.cancel()
        pollTask = nil
        accessDenied = Self.pasteboardDenied
        guard !accessDenied else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                if !Task.isCancelled { self?.poll() }
            }
        }
    }

    private func stopCapture() {
        pollTask?.cancel()
        pollTask = nil
        cancelRead()
    }

    private func cancelRead() {
        readTask?.cancel()
        readTask = nil
    }

    func recheckAccess() {
        if captureEnabled, phase == .ready, pollTask == nil { startCapture() }
    }

    func openPasteSettings() { context.permissions.openSettings(.clipboard) }

    private func poll() {
        let board = NSPasteboard.general
        let count = board.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        readTask?.cancel()
        if Self.pasteboardDenied {
            stopCapture()
            accessDenied = true
            return
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let types = board.types?.map(\.rawValue) ?? []
        if let reason = CaptureFilter.screen(types: types, ownType: PasteService.originType.rawValue, secureInput: IsSecureEventInputEnabled(),
                                             frontmostApp: frontmost, excludedApps: settings.excludedApps) {
            skipCounts[reason, default: 0] += 1
            return
        }
        guard reader.usesChild else { return finish(readOnMainThread(types), count: count, source: frontmost) }
        let request = ClipboardChild.Request(changeCount: count, access: ClipboardReader.access)
        readTask = Task { [weak self] in
            let start = ContinuousClock.now
            let outcome = await ClipboardChild.read(executable: Bundle.main.executableURL, arguments: request.arguments)
            let elapsed = start.duration(to: .now) / .milliseconds(1)
            self?.finishRead(Task.isCancelled ? .cancelled : outcome, milliseconds: elapsed, types: types, count: count, source: frontmost)
        }
    }

    private func finishRead(_ outcome: ClipboardReadOutcome, milliseconds: Double, types: [String], count: Int, source: String?) {
        let wasFailing = reader.failing
        let step = reader.record(outcome, milliseconds: milliseconds)
        if reader.failing, !wasFailing {
            context.log.record(Self.readerFailedError, "clipboard")
            context.notifier.post("Clipboard History", Self.readerFailedError.message)
        }
        switch step {
        case .finish(let decision):
            finish(decision, count: count, source: source)
        case .readOnMainThread:
            finish(NSPasteboard.general.changeCount == count ? readOnMainThread(types) : .skip(.stale), count: count, source: source)
        }
    }

    private func readOnMainThread(_ types: [String]) -> CaptureDecision {
        CaptureFilter.readText(types: types) { NSPasteboard.general.string(forType: .string) }
    }

    private func finish(_ decision: CaptureDecision, count: Int, source: String?) {
        switch CaptureFilter.review(decision, sensitive: settings.sensitive) {
        case .skip(let reason):
            skipCounts[reason, default: 0] += 1
        case .capture(let clip):
            capturedChangeCount = count
            Task { await save(clip, source: source) }
        }
    }

    private func save(_ clip: ClipCapture, source: String?) async {
        guard let store else { return }
        do {
            try await store.capture(clip, source: source, now: Date())
            capturedCount += 1
            try await store.purge(now: Date())
            await refresh()
        } catch {
            report(error, .command)
        }
    }

    private static var pasteboardDenied: Bool { ClipboardReader.access == .alwaysDeny }

    func use(_ item: ClipItem, paste: Bool) async {
        commandStatus = nil
        let invocation = context.invocation
        var target: PasteTarget?
        var reason: String?
        if paste {
            if let invocation, !invocation.expired {
                invocation.consumed = true
                switch invocation.target {
                case .success(let captured):
                    if let error = context.paste.check(captured) { reason = error.message } else { target = captured }
                case .failure(let error):
                    reason = error.message
                }
            } else {
                reason = PasteFailure.targetUnavailable.error.message
            }
        }
        let fallback = paste && target == nil
        let delivery = await context.paste.deliver(
            item.text, paste: target != nil, target: target, generation: context.paste.changeCount,
            isCancelled: { invocation?.cancelled ?? false }, hide: context.closeCommand)
        switch delivery {
        case .pasted, .copied:
            commandStatus = fallback ? ClipboardStatus(text: "Copied, not pasted. \(reason ?? "") Press ⌘V to paste.", success: false)
                                     : ClipboardStatus(text: delivery.message, success: true)
            if fallback { context.showCommandPassively() }
            await run(.command) { try await $0.markUsed(item.id, now: Date()) }
        case .copiedNotPasted(let error):
            context.log.record(error, "clipboard")
            commandStatus = ClipboardStatus(text: delivery.message, success: false)
            context.showCommandPassively()
            await run(.command) { try await $0.markUsed(item.id, now: Date()) }
        case .failedBeforeCopy(let error):
            report(error, .command)
        case .cancelled:
            break
        }
    }

    func togglePin(_ item: ClipItem) async {
        await run(.command) { store in
            try await store.setPinboard(item.id, item.isPinned ? nil : store.defaultPinboard().id)
        }
    }

    func pin(_ item: ClipItem, to pinboardID: String?) async {
        await run(.command) { try await $0.setPinboard(item.id, pinboardID) }
    }

    func delete(_ item: ClipItem) async {
        await run(.command) { try await $0.delete(item.id) }
    }

    func goToLink(_ item: ClipItem) {
        guard let url = item.linkURL else { return }
        guard NSWorkspace.shared.open(url) else {
            commandStatus = ClipboardStatus(text: "Could not open this link.", success: false)
            return
        }
        context.closeCommand()
    }

    func deleteRecent(_ range: RecentRange, from surface: Surface) {
        guard let store else { return }
        let window = range.window(endingAt: Date())
        let label = range.title.lowercased()
        Task {
            let count: Int
            do {
                count = try await store.recentCount(in: window)
            } catch {
                return report(error, surface)
            }
            guard count > 0 else {
                return show(ClipboardStatus(text: "Nothing saved in the \(label).", success: true), on: surface)
            }
            guard confirm("Delete \(Self.itemCount(count)) from the \(label)?",
                          "Pinned items stay. This cannot be undone.\(settings.clearSystemClipboard ? " The system clipboard is also cleared." : "")",
                          "Delete") else { return }
            var deleted = 0
            cancelRead()
            guard await run(surface, { deleted = try await $0.deleteRecent(in: window) }) else { return }
            historyDeleted()
            show(ClipboardStatus(text: "Deleted \(Self.itemCount(deleted)).", success: true), on: surface)
        }
    }

    private static func itemCount(_ count: Int) -> String { count == 1 ? "1 item" : "\(count) items" }

    private func historyDeleted() {
        capturedChangeCount = nil
        clearSystemClipboard()
    }

    private func clearSystemClipboard() {
        if settings.clearSystemClipboard { lastChangeCount = context.paste.clear() }
    }

    var clearsOnQuit: Bool { store != nil && settings.clearOnQuit }

    func clearForQuit() async {
        stopCapture()
        clearSystemClipboard()
        do {
            try await store?.clear(keepPinned: true)
        } catch {
            context.log.record(error.cueError, "clipboard")
        }
    }

    func update(_ edit: (inout ClipboardSettings) -> Void) {
        var next = settings
        edit(&next)
        guard next != settings else { return }
        Task {
            await run(.settings) { store in
                try await store.save(next)
                try await store.purge(now: Date())
            }
        }
    }

    func setShortcut(_ shortcut: Shortcut?) {
        if registerHotKey(shortcut) { update { $0.shortcut = shortcut?.description } }
    }

    private func activateSavedHotKey() {
        let shortcut = settings.shortcut.flatMap(Shortcut.init)
        if !registerHotKey(shortcut), let shortcut {
            context.hotKeys.markUnavailable(Self.owner, shortcut, reason: hotKeyError ?? "Unavailable")
        }
    }

    @discardableResult
    private func registerHotKey(_ shortcut: Shortcut?) -> Bool {
        hotKeyError = nil
        guard !context.isUITesting else { return true }
        guard let shortcut else {
            context.hotKeys.unregister(Self.owner)
            return true
        }
        do {
            try context.hotKeys.register(Self.owner, shortcut) { [weak self] in self?.context.openCommand(.clipboard) }
            return true
        } catch {
            hotKeyError = error.message
            return false
        }
    }

    func addExcludedApp(_ bundleID: String) -> Bool {
        let value = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ClipboardSettings.isValidBundleID(value) else {
            settingsStatus = ClipboardStatus(text: "Enter a bundle ID such as com.example.App.", success: false)
            return false
        }
        guard !settings.excludedApps.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else {
            settingsStatus = ClipboardStatus(text: "\(appName(value)) is already excluded.", success: false)
            return false
        }
        update { $0.excludedApps.append(value) }
        return true
    }

    func removeExcludedApp(_ bundleID: String) {
        update { $0.excludedApps.removeAll { $0 == bundleID } }
    }

    func createPinboard(_ name: String) async -> Bool {
        await run(.settings) { _ = try await $0.createPinboard(name) }
    }

    func renamePinboard(_ board: Pinboard, to name: String) async -> Bool {
        await run(.settings) { try await $0.renamePinboard(board.id, to: name) }
    }

    func deletePinboard(_ board: Pinboard) {
        let count = items.filter { $0.pinboardID == board.id }.count
        guard confirm("Delete the pinboard “\(board.name)”?",
                      "\(count == 1 ? "Its 1 item" : "Its \(count) items") will be unpinned and can expire.", "Delete Pinboard") else { return }
        Task { await run(.settings) { try await $0.deletePinboard(board.id); try await $0.purge(now: Date()) } }
    }

    func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear clipboard history?"
        alert.informativeText = "This permanently deletes saved clipboard items from this Mac.\(settings.clearSystemClipboard ? " The system clipboard is also cleared." : "")"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Keep pinned items"
        alert.suppressionButton?.state = .on
        NSApp.takeFocus()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let keepPinned = alert.suppressionButton?.state == .on
        cancelRead()
        Task {
            if await run(.settings, { try await $0.clear(keepPinned: keepPinned) }) {
                historyDeleted()
                settingsStatus = ClipboardStatus(text: keepPinned ? "History cleared. Pinned items were kept." : "History cleared.", success: true)
            }
        }
    }

    func resetHistory() {
        guard let store,
              confirm("Reset clipboard history?",
                      "Cue cannot unlock the saved items. Resetting permanently deletes them and creates a new key. Pinboards and settings stay.",
                      "Reset History") else { return }
        let service = context.keychainService
        cancelRead()
        Task {
            do {
                try await store.resetHistory()
                await Task.detached { ClipboardKeychain.delete(service: service) }.value
                keychainKind = nil
            } catch {
                return fail(error)
            }
            await loadHistory()
        }
    }

    func exportHistory() {
        guard let store,
              confirm("Export clipboard history as plain text?",
                      "The file is not encrypted. Anyone who can open it can read every saved item. Store it somewhere safe and delete it when you no longer need it.",
                      "Export…") else { return }
        Task {
            do {
                let data = try await store.exportData(now: Date())
                if try FileTransfer.save(data, suggestedName: SafeFilename.make("Cue Clipboard Export", ext: "json", date: Date()), type: .json) {
                    settingsStatus = ClipboardStatus(text: "Exported \(items.count == 1 ? "1 item" : "\(items.count) items").", success: true)
                }
            } catch {
                report(error, .settings)
            }
        }
    }

    func importHistory() {
        guard let store else { return }
        Task {
            do {
                guard let data = try FileTransfer.open(type: .json, maxBytes: ClipboardExport.maxBytes) else { return }
                let file = try await Task.detached { try ClipboardExport.decode(data) }.value
                guard confirm("Replace clipboard history?",
                              "Import \(file.items.count) items and \(file.pinboards.count) pinboards. This replaces your current clipboard history, pinboards, and clipboard settings. It cannot be undone.",
                              "Replace") else { return }
                if !file.items.isEmpty, !(await store.isUnlocked) { try await unlock(store) }
                cancelRead()
                try await store.importData(data)
                try await store.purge(now: Date())
                await refresh()
                phase = .ready
                activateSavedHotKey()
                settingsStatus = ClipboardStatus(text: "Imported \(items.count == 1 ? "1 item" : "\(items.count) items").", success: true)
            } catch {
                report(error, .settings)
            }
        }
    }

    func appName(_ bundleID: String) -> String {
        if let name = appNames[bundleID] { return name }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path) }
            .map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 } ?? bundleID
        appNames[bundleID] = name
        return name
    }

    enum Surface { case command, settings }

    @discardableResult
    private func run(_ surface: Surface, _ body: (ClipboardStore) async throws -> Void) async -> Bool {
        guard let store else { return false }
        do {
            try await body(store)
            await refresh()
            return true
        } catch {
            await refresh()
            report(error, surface)
            return false
        }
    }

    private func report(_ error: Error, _ surface: Surface) {
        let error = error.cueError
        if error.code != "VALIDATION" { context.log.record(error, "clipboard") }
        show(ClipboardStatus(text: error.message, success: false), on: surface)
    }

    private func show(_ status: ClipboardStatus, on surface: Surface) {
        switch surface {
        case .command: commandStatus = status
        case .settings: settingsStatus = status
        }
    }

    private func confirm(_ title: String, _ message: String, _ button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        NSApp.takeFocus()
        return alert.runModal() == .alertFirstButtonReturn
    }
}
