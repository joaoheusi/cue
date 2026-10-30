import AppKit
import CueKit
import UniformTypeIdentifiers

@MainActor @Observable final class PromptsModel {
    private(set) var state: LoadState<LibrarySnapshot> = .loading
    var notice: (text: String, success: Bool)?
    var pendingImport: ImportPreview?
    var pendingAsk: Action?
    private(set) var run: ActionRun?
    @ObservationIgnored private var store: PromptStore?
    @ObservationIgnored let context: AppContext

    static let pasteReason = "To paste a prompt into the app you were using, Cue reads which text field has focus and sends one ⌘V to it."

    init(context: AppContext) {
        self.context = context
        installRunHandling()
    }

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

    @discardableResult
    func saveSettings(_ change: (inout PromptSettings) -> Void) async -> Bool {
        guard let snapshot else { return false }
        var settings = snapshot.settings
        change(&settings)
        let saved = await perform { try await $0.saveSettings(settings, revision: snapshot.revision) } != nil
        applyTheme()
        return saved
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
        if let shortcut = Shortcut(snapshot.settings.menuBarScopeShortcut) {
            do {
                try context.hotKeys.register(Self.menuBarScopeOwner, shortcut) { [weak self] in self?.context.openCommand(.menuBar) }
            } catch {
                context.hotKeys.markUnavailable(Self.menuBarScopeOwner, shortcut, reason: error.message)
            }
        }
        for action in snapshot.actions {
            guard let chord = snapshot.bindings[Self.owner(action)] else { continue }
            activate(action, chord: chord)
        }
    }

    static let menuBarScopeOwner = "menuBarScope"

    func setMenuBarScopeShortcut(_ shortcut: Shortcut?) async {
        if let shortcut {
            do {
                try context.hotKeys.register(Self.menuBarScopeOwner, shortcut) { [weak self] in self?.context.openCommand(.menuBar) }
            } catch {
                notice = (error.message, false)
                return
            }
        } else {
            context.hotKeys.unregister(Self.menuBarScopeOwner)
        }
        await saveSettings { $0.menuBarScopeShortcut = shortcut?.description ?? "" }
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

    func setPaletteShortcut(_ shortcut: Shortcut?) async {
        if let shortcut {
            do {
                try context.hotKeys.register("palette", shortcut) { [weak self] in self?.context.openCommand(.prompts) }
            } catch {
                notice = (error.message, false)
                return
            }
        } else {
            context.hotKeys.unregister("palette")
        }
        let chord = shortcut?.description ?? ""
        await perform { try await $0.saveBinding(owner: "palette", chord: chord) }
        await saveSettings { $0.paletteShortcut = chord }
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
    func save(_ action: Action, quiet: Bool = false) async -> Action? {
        let saved = await perform(quiet ? nil : "Saved.") { try await $0.save(action) }
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

    func deliver(_ action: Action, copyOnly: Bool, answers: [String: String] = [:]) async -> Result<Delivery, CueError> {
        guard let invocation = context.invocation, !invocation.expired else {
            return .failure(CueError("INVOCATION_EXPIRED", "Reopen the palette to use this action."))
        }
        return await deliver(action, copyOnly: copyOnly, invocation: invocation, answers: answers)
    }

    func credentials() throws(CueError) -> Assistant.Credentials {
        let stored = snapshot?.settings.keyStorage == .keychain ? ClaudeKey.load(service: context.claudeKeyService) : nil
        return try Assistant.credentials(in: context.dataDirectory, storedKey: stored)
    }

    func setFavorite(_ action: Action, _ favorite: Bool) async {
        var changed = action
        changed.favorite = favorite
        await perform { try await $0.save(changed) }
    }

    func setEnabled(_ action: Action, _ enabled: Bool) async {
        var changed = action
        changed.enabled = enabled
        _ = await save(changed)
    }

    func startRun(_ requested: Action, copyOnly: Bool, answers: [String: String] = [:]) async -> CueError? {
        guard let invocation = context.invocation, !invocation.expired else {
            return CueError("INVOCATION_EXPIRED", "Reopen the palette to use this action.")
        }
        guard let store else { return CueError.storage() }
        let action: Action
        do {
            action = try await store.get(requested.id)
        } catch {
            return error.cueError
        }
        guard action.revision == requested.revision else { return CueError("REVISION_CONFLICT", "Action changed. Reload before continuing.") }
        guard action.enabled else { return CueError("ACTION_DISABLED", "Enable this action before using it.") }
        let paste = willPaste(action, copyOnly: copyOnly)
        switch prepare(action.template, paste: paste, assistant: true, invocation: invocation, answers: answers) {
        case .failure(let error):
            return error
        case .success(let prepared):
            if invocation.cancelled { return nil }
            invocation.consumed = true
            let next = ActionRun(title: action.name, kind: .claude, surface: .palette, prompt: prepared.output, input: prepared.input, inputName: prepared.inputName,
                                 action: action, invocation: invocation, target: prepared.target, targetName: invocation.front?.localizedName,
                                 generation: prepared.generation, finish: paste ? .paste : .copy)
            run = next
            begin(next)
            return nil
        }
    }

    func test(_ draft: Action) {
        let invocation = Invocation(target: .failure(PasteFailure.targetUnavailable.error))
        let claude = draft.ai == true
        switch prepare(draft.template, paste: false, assistant: claude, invocation: invocation, answers: [:], sampleSelection: "Selected text") {
        case .failure(let error):
            notice = (error.message, false)
        case .success(let prepared):
            let next = ActionRun(title: draft.name, kind: draft.runsAs, surface: .library, prompt: prepared.output, input: prepared.input,
                                 inputName: prepared.inputName, invocation: invocation, finish: .keep)
            run = next
            if claude {
                begin(next)
            } else {
                next.output = prepared.output
                next.phase = .finished
                next.ended = next.started
            }
        }
    }

    func showOutput(_ title: String, text: String, surface: ActionRun.Surface) {
        let next = ActionRun(title: title, kind: .script, surface: surface, invocation: context.invocation ?? Invocation(target: .failure(PasteFailure.targetUnavailable.error)), finish: .keep)
        next.output = text
        next.phase = .finished
        next.ended = next.started
        run = next
    }

    private func begin(_ run: ActionRun) {
        let credentials: Assistant.Credentials
        do {
            credentials = try self.credentials()
        } catch {
            run.phase = .failed(error)
            return
        }
        run.task?.cancel()
        run.output = ""
        run.message = nil
        run.phase = .running
        run.started = Date()
        run.ended = nil
        run.task = Task { [weak self, weak run] in
            do {
                for try await chunk in Assistant.stream(run?.prompt ?? "", credentials: credentials) {
                    run?.output += chunk
                }
                guard let run, !Task.isCancelled else { return }
                run.phase = .finished
                run.ended = Date()
                await self?.finished(run)
            } catch is CancellationError {
                return
            } catch {
                guard let run, !Task.isCancelled else { return }
                run.phase = .failed(error.cueError)
                run.ended = Date()
                self?.context.log.record(error.cueError, "ai")
                if self?.context.commandVisible() == false { self?.report(run.title, error.cueError) }
            }
        }
    }

    private func finished(_ run: ActionRun) async {
        if let action = run.action, let store {
            try? await store.recordUse(action.id)
            try? await reload()
        }
        switch run.finish {
        case .paste: await deliver(run, paste: true)
        case .copy: await deliver(run, paste: false)
        case .keep:
            if !context.commandVisible() { context.notifier.post(run.title, "Result ready. Open Cue to see it.") }
        }
    }

    func deliver(_ run: ActionRun, paste: Bool) async {
        let visible = context.commandVisible()
        let delivery = await context.paste.deliver(run.output, paste: paste && run.target != nil, target: run.target, generation: run.generation,
                                                   isCancelled: { run.invocation.cancelled }, hide: context.closeCommand)
        var failure: CueError?
        switch delivery {
        case .pasted, .copied:
            if !visible { context.notifier.post(run.title, delivery == .pasted ? "Result pasted." : "Result copied to the clipboard.") }
            if self.run === run { self.run = nil }
        case .cancelled:
            break
        case .failedBeforeCopy(let error) where error == PasteFailure.clipboardChanged.error:
            failure = CueError(error.code, "The clipboard changed while Claude was working, so Cue kept your new copy. Press ⌘↩ to copy this result.")
        case .copiedNotPasted(let error), .failedBeforeCopy(let error):
            failure = error
        }
        guard let failure else { return }
        context.log.record(failure, "ai")
        run.generation = nil
        if visible {
            run.message = failure.message
            self.run = run
            context.showCommandPassively()
        } else {
            report(run.title, failure)
        }
    }

    func stopRun() {
        guard let run, run.isRunning else { return }
        run.task?.cancel()
        run.phase = .stopped
        run.ended = Date()
    }

    func retryRun() {
        guard let run, run.kind == .claude else { return }
        run.generation = context.paste.changeCount
        begin(run)
    }

    func closeRun() {
        run?.task?.cancel()
        run?.invocation.consumed = false
        run = nil
    }

    func installRunHandling() {
        context.interceptCancel = { [weak self] in
            guard let self, let run, run.surface == .palette, run.isRunning else { return false }
            stopRun()
            return true
        }
        context.keepsRunning = { [weak self] in self?.run?.isRunning == true && self?.run?.surface == .palette }
        context.commandDidHide = { [weak self] in
            self?.pendingAsk = nil
            guard let self, let run, run.surface == .palette, !run.isRunning, run.message == nil else { return }
            self.run = nil
        }
    }

    func copy(_ action: Action) async {
        let result = await deliver(action, copyOnly: true, invocation: Invocation(target: .failure(PasteFailure.targetUnavailable.error)), answers: [:])
        switch result {
        case .success(let delivery): notice = (delivery.message, delivery.succeeded)
        case .failure(let error): notice = (error.message, false)
        }
    }

    private func runDirect(actionID: String) async {
        guard let action = snapshot?.actions.first(where: { $0.id == actionID }) else { return }
        if let uses = try? Template.uses(action.template), !uses.questions.isEmpty {
            pendingAsk = action
            context.openCommand(.prompts)
            return
        }
        let paste = willPaste(action, copyOnly: false)
        let invocation = Invocation(target: paste ? context.paste.capture() : .failure(PasteFailure.targetUnavailable.error), front: NSWorkspace.shared.frontmostApplication)
        let result = await deliver(action, copyOnly: false, invocation: invocation, answers: [:])
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

    private func deliver(_ requested: Action, copyOnly: Bool, invocation: Invocation, answers: [String: String]) async -> Result<Delivery, CueError> {
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
                                  assistant: action.ai == true ? action.name : nil, invocation: invocation, answers: answers)
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

    private struct Prepared {
        var output: String
        var input: String?
        var inputName = "clipboard"
        var target: PasteTarget?
        var generation: Int?
    }

    private func prepare(_ template: String, paste: Bool, assistant: Bool, invocation: Invocation, answers: [String: String],
                         sampleSelection: String? = nil) -> Result<Prepared, CueError> {
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
        let generation = paste || assistant ? context.paste.changeCount : nil
        do {
            let uses = try Template.uses(template)
            var inputs = Template.Inputs(answers: answers)
            if uses.clipboard {
                inputs.clipboard = try context.paste.readText()
                if inputs.clipboard.isEmpty { throw CueError("CLIPBOARD_EMPTY", "Copy source text before using this action.") }
                try Template.validateText(inputs.clipboard, maxBytes: Template.outputLimit)
            }
            if uses.selection {
                inputs.selection = sampleSelection ?? context.paste.selectedText(in: invocation.front) ?? ""
                if inputs.selection.isEmpty { throw CueError("SELECTION_EMPTY", "Select text before using this action.") }
                try Template.validateText(inputs.selection, maxBytes: Template.outputLimit)
            }
            let output = try Template.renderLocal(template, inputs: inputs)
            if assistant { _ = try credentials() }
            return .success(Prepared(output: output, input: uses.clipboard ? inputs.clipboard : uses.selection ? inputs.selection : nil,
                                     inputName: uses.clipboard ? "clipboard" : "selection", target: target, generation: generation))
        } catch {
            return .failure(error.cueError)
        }
    }

    private func render(_ template: String, paste: Bool, assistant: String?, invocation: Invocation, answers: [String: String] = [:]) async -> Result<Delivery, CueError> {
        let prepared: Prepared
        switch prepare(template, paste: paste, assistant: assistant != nil, invocation: invocation, answers: answers) {
        case .success(let value): prepared = value
        case .failure(let error): return .failure(error)
        }
        var output = prepared.output
        let target = prepared.target
        let generation = prepared.generation
        if invocation.cancelled { return .success(.cancelled) }
        invocation.consumed = true
        if let assistant {
            context.closeCommand()
            do {
                output = try await Assistant.complete(output, credentials: try credentials())
            } catch {
                report(assistant, error.cueError)
                return .success(.cancelled)
            }
        }
        let delivery = await context.paste.deliver(output, paste: paste, target: target, generation: generation,
                                                   isCancelled: { invocation.cancelled }, hide: assistant == nil ? context.closeCommand : {})
        if let assistant {
            switch delivery {
            case .copied: context.notifier.post(assistant, "Result copied to the clipboard.")
            case .pasted: context.notifier.post(assistant, "Result pasted.")
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

    func report(_ title: String, _ error: CueError) {
        context.log.record(error, "ai")
        context.notifier.post(title, error.message) { [weak self] in self?.show(error.message) }
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
            ("Settings", "theme=\(s.theme.rawValue) delivery=\(s.defaultDelivery.rawValue) onboarded=\(s.onboarded) previewPane=\(s.previewPane)"),
        ]
    }
}
