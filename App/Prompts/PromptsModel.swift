import AppKit
import CueKit
import UniformTypeIdentifiers

@MainActor @Observable final class PromptsModel {
    private(set) var state: LoadState<LibrarySnapshot> = .loading
    var notice: (text: String, success: Bool)?
    var pendingImport: ImportPreview?
    @ObservationIgnored private var store: PromptStore?
    @ObservationIgnored let context: AppContext

    static let pasteReason = "To paste a prompt into the app you were using, Cue reads which text field has focus and sends one ⌘V to it."

    init(context: AppContext) { self.context = context }

    var snapshot: LibrarySnapshot? {
        if case .loaded(let snapshot) = state { snapshot } else { nil }
    }

    func load() async {
        do {
            if store == nil { store = try PromptStore(directory: context.dataDirectory) }
            try await reload()
            if context.isUITesting, let snapshot, !snapshot.settings.onboarded {
                var settings = snapshot.settings
                settings.paletteShortcut = ""
                try await store?.onboard(Starters.actions(), settings: settings, revision: snapshot.revision)
                try await reload()
            }
            applyTheme()
            restoreShortcuts()
        } catch {
            context.log.record(error.cueError, "prompts.load")
            state = .failed(error.cueError)
        }
    }

    func reload() async throws {
        guard let store else { throw CueError.storage() }
        state = .loaded(try await store.snapshot())
    }

    @discardableResult
    func perform<T: Sendable>(_ success: String? = nil, _ operation: (PromptStore) async throws -> T) async -> T? {
        guard let store else {
            notice = (CueError.storage().message, false)
            return nil
        }
        do {
            let value = try await operation(store)
            try await reload()
            if let success { notice = (success, true) }
            return value
        } catch {
            context.log.record(error.cueError, "prompts")
            notice = (error.cueError.message, false)
            try? await reload()
            return nil
        }
    }

    func applyTheme() {
        guard let theme = snapshot?.settings.theme else { return }
        NSApp.appearance = switch theme {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    func saveSettings(_ change: (inout PromptSettings) -> Void) async {
        guard let snapshot else { return }
        var settings = snapshot.settings
        change(&settings)
        await perform { try await $0.saveSettings(settings, revision: snapshot.revision) }
        applyTheme()
    }

    static func owner(_ action: Action) -> String { "action:\(action.id)" }

    func restoreShortcuts() {
        guard !context.isUITesting, let snapshot else { return }
        let palette = snapshot.bindings["palette"] ?? snapshot.settings.paletteShortcut
        if let shortcut = Shortcut(palette) {
            do {
                try context.hotKeys.register("palette", shortcut) { [weak self] in self?.context.openCommand(.prompts) }
            } catch {
                context.hotKeys.markUnavailable("palette", shortcut, reason: error.message)
            }
        }
        for action in snapshot.actions {
            guard let chord = snapshot.bindings[Self.owner(action)] else { continue }
            activate(action, chord: chord)
        }
    }

    private func activate(_ action: Action, chord: String) {
        let owner = Self.owner(action)
        guard let shortcut = Shortcut(chord) else {
            context.hotKeys.markUnavailable(owner, nil, reason: "Invalid shortcut")
            return
        }
        guard action.enabled else {
            context.hotKeys.markUnavailable(owner, shortcut, reason: "Action disabled")
            return
        }
        do {
            try context.hotKeys.register(owner, shortcut) { [weak self] in
                Task { await self?.runDirect(actionID: action.id) }
            }
        } catch {
            context.hotKeys.markUnavailable(owner, shortcut, reason: error.message)
        }
    }

    func setPaletteShortcut(_ shortcut: Shortcut) async {
        do {
            try context.hotKeys.register("palette", shortcut) { [weak self] in self?.context.openCommand(.prompts) }
        } catch {
            notice = (error.message, false)
            return
        }
        await perform("Shortcut saved.") { try await $0.saveBinding(owner: "palette", chord: shortcut.description) }
        await saveSettings { $0.paletteShortcut = shortcut.description }
    }

    func setShortcut(_ shortcut: Shortcut?, for action: Action) async {
        let owner = Self.owner(action)
        if let shortcut {
            if context.hotKeys.statuses.contains(where: { $0.key != owner && $0.value.requested == shortcut }) {
                notice = ("This shortcut is already used in Cue. Choose another.", false)
                return
            }
            await perform { try await $0.saveBinding(owner: owner, chord: shortcut.description) }
            activate(action, chord: shortcut.description)
        } else {
            await perform { try await $0.saveBinding(owner: owner, chord: "") }
            context.hotKeys.unregister(owner)
        }
    }

    @discardableResult
    func save(_ action: Action) async -> Action? {
        let saved = await perform("Saved.") { try await $0.save(action) }
        if let saved, let chord = snapshot?.bindings[Self.owner(saved)] { activate(saved, chord: chord) }
        return saved
    }

    func delete(_ action: Action) async {
        await perform("Deleted.") { try await $0.delete(action.id, revision: action.revision) }
        context.hotKeys.unregister(Self.owner(action))
    }

    func duplicate(_ action: Action) async -> Action? {
        await perform("Duplicated.") { try await $0.duplicate(action.id, revision: action.revision) }
    }

    func onboard(_ actions: [Action], palette: Shortcut?) async {
        guard let snapshot else { return }
        var settings = snapshot.settings
        if let palette { settings.paletteShortcut = palette.description }
        await perform { try await $0.onboard(actions, settings: settings, revision: snapshot.revision) }
        if let palette { await perform { try await $0.saveBinding(owner: "palette", chord: palette.description) } }
        restoreShortcuts()
    }

    func exportActions() async {
        guard let store else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(try await store.exportFile())
            if try FileTransfer.save(data, suggestedName: SafeFilename.make("Cue Prompts", ext: "json", date: Date()), type: .json) {
                notice = ("Exported.", true)
            }
        } catch {
            notice = (error.cueError.message, false)
        }
    }

    func previewImport() async -> ImportPreview? {
        do {
            guard let data = try FileTransfer.open(type: .json, maxBytes: 10 * 1024 * 1024) else { return nil }
            return await perform { try await $0.preview(data) }
        } catch {
            notice = (error.message, false)
            return nil
        }
    }

    func commitImport(_ preview: ImportPreview, update: Bool) async {
        await perform("Imported.") { try await $0.commitImport(token: preview.token, update: update) }
        for owner in context.hotKeys.statuses.keys where owner.hasPrefix("action:") { context.hotKeys.unregister(owner) }
        restoreShortcuts()
    }

    func deliver(_ action: Action, copyOnly: Bool) async -> Result<Delivery, CueError> {
        guard let invocation = context.invocation, !invocation.expired else {
            return .failure(CueError("INVOCATION_EXPIRED", "Reopen the palette to use this action."))
        }
        return await deliver(action, copyOnly: copyOnly, invocation: invocation)
    }

    func copy(_ action: Action) async {
        let result = await deliver(action, copyOnly: true, invocation: Invocation(target: .failure(PasteFailure.targetUnavailable.error)))
        switch result {
        case .success(let delivery): notice = (delivery.message, delivery.succeeded)
        case .failure(let error): notice = (error.message, false)
        }
    }

    private func runDirect(actionID: String) async {
        guard let action = snapshot?.actions.first(where: { $0.id == actionID }) else { return }
        let paste = willPaste(action, copyOnly: false)
        let invocation = Invocation(target: paste ? context.paste.capture() : .failure(PasteFailure.targetUnavailable.error))
        let result = await deliver(action, copyOnly: false, invocation: invocation)
        switch result {
        case .success(let delivery) where delivery.succeeded || delivery == .cancelled: break
        case .success(let delivery): show(delivery.message)
        case .failure(let error): show(error.message)
        }
    }

    private func show(_ message: String) {
        notice = (message, false)
        context.openLibrary(nil)
    }

    func willPaste(_ action: Action, copyOnly: Bool) -> Bool {
        !copyOnly && (action.deliveryMode == .paste || (action.deliveryMode == .inherit && snapshot?.settings.defaultDelivery == .paste))
    }

    var willPasteByDefault: Bool { snapshot?.settings.defaultDelivery == .paste }

    func deliver(_ snippet: Snippet, copyOnly: Bool) async -> Result<Delivery, CueError> {
        guard let invocation = context.invocation, !invocation.expired else {
            return .failure(CueError("INVOCATION_EXPIRED", "Reopen the palette to use this snippet."))
        }
        return await render(snippet.template, paste: !copyOnly && willPasteByDefault, assistant: nil, invocation: invocation)
    }

    private func deliver(_ requested: Action, copyOnly: Bool, invocation: Invocation) async -> Result<Delivery, CueError> {
        guard let store else { return .failure(CueError.storage()) }
        let action: Action
        do {
            action = try await store.get(requested.id)
        } catch {
            return .failure(error.cueError)
        }
        guard action.revision == requested.revision else {
            return .failure(CueError("REVISION_CONFLICT", "Action changed. Reload before continuing."))
        }
        guard action.enabled else { return .failure(CueError("ACTION_DISABLED", "Enable this action before using it.")) }
        let result = await render(action.template, paste: willPaste(action, copyOnly: copyOnly),
                                  assistant: action.ai == true ? action.name : nil, invocation: invocation)
        guard case .success(let delivery) = result else { return result }
        switch delivery {
        case .pasted, .copied, .copiedNotPasted:
            if (try? await store.recordUse(action.id)) == nil { notice = ("Copied. Usage could not be saved.", true) }
        default: break
        }
        if case .copiedNotPasted(let error) = delivery { context.log.record(error, "prompts.paste") }
        try? await reload()
        return result
    }

    private func render(_ template: String, paste: Bool, assistant: String?, invocation: Invocation) async -> Result<Delivery, CueError> {
        var target: PasteTarget?
        if paste {
            switch invocation.target {
            case .success(let captured):
                if let error = context.paste.check(captured) { return .failure(error) }
                target = captured
            case .failure(let error):
                return .failure(error)
            }
        }
        let generation = paste || assistant != nil ? context.paste.changeCount : nil
        var output: String
        var credentials: Assistant.Credentials?
        do {
            var clipboard = ""
            if try Template.needsClipboard(template) {
                clipboard = try context.paste.readText()
                if clipboard.isEmpty { throw CueError("CLIPBOARD_EMPTY", "Copy source text before using this action.") }
                try Template.validateText(clipboard, maxBytes: Template.outputLimit)
            }
            output = try Template.renderLocal(template, clipboard: clipboard)
            if assistant != nil { credentials = try Assistant.credentials(in: context.dataDirectory) }
        } catch {
            return .failure(error.cueError)
        }
        if invocation.cancelled { return .success(.cancelled) }
        invocation.consumed = true
        if let assistant, let credentials {
            context.closeCommand()
            do {
                output = try await Assistant.complete(output, credentials: credentials)
            } catch {
                report(assistant, error)
                return .success(.cancelled)
            }
        }
        let delivery = await context.paste.deliver(output, paste: paste, target: target, generation: generation,
                                                   isCancelled: { invocation.cancelled }, hide: assistant == nil ? context.closeCommand : {})
        if let assistant {
            switch delivery {
            case .copied: notify(assistant, "Result copied to the clipboard.")
            case .pasted: notify(assistant, "Result pasted.")
            case .cancelled: break
            case .failedBeforeCopy(let error) where error == PasteFailure.clipboardChanged.error:
                report(assistant, CueError(error.code, "The clipboard changed while Claude was working, so Cue kept your new copy. Run it again."))
                return .success(.cancelled)
            case .copiedNotPasted(let error), .failedBeforeCopy(let error):
                report(assistant, error)
                return .success(.cancelled)
            }
        }
        return .success(delivery)
    }

    private func report(_ title: String, _ error: CueError) {
        context.log.record(error, "ai")
        notify(title, error.message)
    }

    private func notify(_ title: String, _ body: String) {
        context.notifier.post(title, body) { [weak self] in self?.show(body) }
    }

    func diagnostics() -> [(String, String)] {
        guard let snapshot else {
            if case .failed(let error) = state { return [("State", "failed \(error.code)")] }
            return [("State", "loading")]
        }
        let s = snapshot.settings
        return [
            ("Actions", "\(snapshot.actions.count) (\(snapshot.actions.filter(\.enabled).count) enabled, \(snapshot.actions.filter(\.favorite).count) favorites)"),
            ("Categories", "\(snapshot.categories.count)"),
            ("Direct shortcuts", "\(snapshot.bindings.keys.filter { $0.hasPrefix("action:") }.count)"),
            ("Library revision", "\(snapshot.revision)"),
            ("Settings", "theme=\(s.theme.rawValue) delivery=\(s.defaultDelivery.rawValue) onboarded=\(s.onboarded) preview=\(s.preview)"),
        ]
    }
}
