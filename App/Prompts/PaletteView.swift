import AppKit
import CueKit
import SwiftUI

enum PaletteItem: Identifiable {
    case action(Action), snippet(Snippet), script(Script), window(WindowCommand), file(FileHit)

    var id: String {
        switch self {
        case .action(let action): "action:\(action.id)"
        case .snippet(let snippet): "snippet:\(snippet.id)"
        case .script(let script): "script:\(script.id)"
        case .window(let command): command.owner
        case .file(let hit): "file:\(hit.id)"
        }
    }
}

struct PaletteView: View {
    let model: PromptsModel
    let commands: CommandsModule
    @State private var query = ""
    @State private var selection: String?
    @State private var busy = false
    @State private var error: CueError?
    @State private var recovering = false
    @State private var output: (title: String, text: String)?
    @State private var frozenUsage: [String: String]

    init(model: PromptsModel, commands: CommandsModule) {
        self.model = model
        self.commands = commands
        var usage: [String: String] = [:]
        for action in model.snapshot?.actions ?? [] { usage[action.id] = action.lastUsedAt }
        _frozenUsage = State(initialValue: usage)
    }

    var body: some View {
        switch model.state {
        case .loading:
            LoadingView(label: "Opening your library…")
        case .failed(let error):
            VStack {
                ErrorBanner(error: error) { Task { await model.load() } }
                Spacer()
            }
            .padding([.horizontal, .bottom])
            .padding(.top, CommandMetrics.searchHeight)
        case .loaded(let snapshot):
            if let output {
                outputView(output)
            } else {
                palette(snapshot)
            }
        }
    }

    private func results(_ snapshot: LibrarySnapshot) -> [PaletteItem] {
        let actions = snapshot.actions.map { action in
            var copy = action
            copy.lastUsedAt = frozenUsage[action.id]
            return copy
        }
        let live = Dictionary(uniqueKeysWithValues: snapshot.actions.map { ($0.id, $0) })
        var ranked: [(item: PaletteItem, tier: Int, weight: Int)] = ActionSearch.scored(actions, query: query).compactMap { entry in
            live[entry.action.id].map { (.action($0), entry.tier, entry.weight) }
        }
        func add(_ item: PaletteItem, _ name: String) {
            if let score = ActionSearch.score(query, name: name) { ranked.append((item, score.tier, score.weight)) }
        }
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { commands.apps.forEach { add(.file($0), $0.title) } }
        commands.snippets.forEach { add(.snippet($0), $0.keyword) }
        commands.scripts.forEach { add(.script($0), $0.name) }
        WindowCommand.allCases.forEach { add(.window($0), $0.title) }
        let sorted = ranked.enumerated().sorted { a, b in
            (a.element.tier, a.element.weight, a.offset) < (b.element.tier, b.element.weight, b.offset)
        }
        return sorted.map(\.element.item) + commands.files.results.map(PaletteItem.file)
    }

    @ViewBuilder private func palette(_ snapshot: LibrarySnapshot) -> some View {
        let items = results(snapshot)
        let current = items.first { $0.id == selection }
        VStack(spacing: 0) {
            CommandList(query: $query, placeholder: "Search prompts, commands, and files", items: items, selection: $selection,
                        row: { item, selected in row(item, selected: selected, snapshot: snapshot) },
                        onSubmit: { item, alternate in submit(item, alternate: alternate) },
                        onKeyPress: { item, press in key(press, item: item) })
                .overlay {
                    if items.isEmpty {
                        EmptyStateView(symbol: "magnifyingglass", title: "No matches", message: "Try another name, alias, or tag. Press ⌘N to add a new action.")
                            .padding(.top, 60)
                    }
                }
            if snapshot.settings.preview, let text = preview(current) {
                Divider()
                ScrollView {
                    Text(text).font(.callout.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                .frame(maxHeight: 120)
            }
            footer(current, count: items.count)
        }
        .onChange(of: query) {
            error = nil
            commands.files.clear()
        }
        .task { await commands.reload() }
        .task(id: query) {
            guard !model.context.isUITesting else { return }
            try? await Task.sleep(for: .milliseconds(80))
            if !Task.isCancelled { commands.files.search(query) }
        }
        .onDisappear { commands.files.stop() }
    }

    private func preview(_ item: PaletteItem?) -> String? {
        switch item {
        case .action(let action)?: action.template
        case .snippet(let snippet)?: snippet.expansion
        default: nil
        }
    }

    @ViewBuilder private func row(_ item: PaletteItem, selected: Bool, snapshot: LibrarySnapshot) -> some View {
        switch item {
        case .action(let action):
            CommandRow(title: action.name, subtitle: action.description.isEmpty ? (action.category ?? "Text action") : action.description,
                       symbol: action.ai == true ? "sparkles" : action.category == "Writing" ? "text.alignleft" : "chevron.left.forwardslash.chevron.right", selected: selected) {
                HStack(spacing: 6) {
                    if action.favorite { Image(systemName: "star.fill").font(.caption) }
                    if action.template.contains("{{clipboard}}") { Image(systemName: "doc.on.clipboard").font(.caption) }
                    if let chord = snapshot.bindings[PromptsModel.owner(action)], let shortcut = Shortcut(chord) {
                        Text(shortcut.display).font(.caption.monospaced())
                    }
                }
            }
        case .snippet(let snippet):
            CommandRow(title: snippet.keyword, subtitle: ClipboardSearch.preview(snippet.expansion), symbol: "text.quote", selected: selected) { EmptyView() }
        case .script(let script):
            CommandRow(title: script.name, subtitle: "Script", symbol: "terminal", selected: selected) { EmptyView() }
        case .window(let command):
            CommandRow(title: command.title, subtitle: "Window", symbol: command.symbol, selected: selected) {
                if let shortcut = commands.shortcut(for: command) { Text(shortcut.display).font(.caption.monospaced()) }
            }
        case .file(let hit):
            CommandRow(title: hit.title, subtitle: hit.folder, symbol: hit.isApp ? "app" : "doc", selected: selected) { EmptyView() }
        }
    }

    @ViewBuilder private func footer(_ current: PaletteItem?, count: Int) -> some View {
        VStack(spacing: 0) {
            if let error {
                ErrorBanner(error: error, retryTitle: permissionError(error) ? "Allow Access…" : "Dismiss") {
                    if permissionError(error), model.context.permissions.explain(.accessibility(reason: reason(for: current))) {
                        model.context.paste.requestAccess()
                    }
                    self.error = nil
                    if recovering { model.context.closeCommand() }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            CommandFooter {
                if busy { ProgressView().controlSize(.small) }
                Text("\(count) results")
            } trailing: {
                hints(current)
                KeyHint(label: "New", keys: ["⌘", "N"])
            }
        }
    }

    @ViewBuilder private func hints(_ item: PaletteItem?) -> some View {
        switch item {
        case .action(let action):
            if action.ai == true {
                KeyHint(label: "Run", keys: ["↩"])
            } else if model.willPaste(action, copyOnly: false) {
                KeyHint(label: "Paste", keys: ["↩"])
                KeyHint(label: "Copy", keys: ["⇧", "↩"])
            } else {
                KeyHint(label: "Copy", keys: ["↩"])
            }
            KeyHint(label: "Edit", keys: ["⌘", "E"])
        case .snippet:
            if model.willPasteByDefault {
                KeyHint(label: "Paste", keys: ["↩"])
                KeyHint(label: "Copy", keys: ["⇧", "↩"])
            } else {
                KeyHint(label: "Copy", keys: ["↩"])
            }
        case .script:
            KeyHint(label: "Copy Output", keys: ["↩"])
            KeyHint(label: "Show", keys: ["⇧", "↩"])
        case .window:
            KeyHint(label: "Apply", keys: ["↩"])
        case .file:
            KeyHint(label: "Open", keys: ["↩"])
            KeyHint(label: "Reveal", keys: ["⇧", "↩"])
        case nil:
            EmptyView()
        }
    }

    private func outputView(_ output: (title: String, text: String)) -> some View {
        VStack(spacing: 0) {
            Text(output.title).font(.system(size: 16)).lineLimit(1)
                .padding(.leading, 18).padding(.trailing, CommandMetrics.switcherWidth)
                .frame(maxWidth: .infinity, minHeight: CommandMetrics.searchHeight, maxHeight: CommandMetrics.searchHeight, alignment: .leading)
            Divider()
            ScrollView {
                Text(output.text.isEmpty ? "No output." : output.text).font(.callout.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
            CommandFooter {
                Button("Back") { self.output = nil }.keyboardShortcut("[", modifiers: .command).help("Back (⌘[)")
            } trailing: {
                Button("Copy Output") { Task { _ = await commands.copy(output.text) } }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(output.text.isEmpty)
            }
            .buttonStyle(.borderless)
        }
    }

    private func permissionError(_ error: CueError) -> Bool {
        error.code == "PERMISSION_REQUIRED" || error.code == "PASTE_PERMISSION_REQUIRED"
    }

    private func reason(for item: PaletteItem?) -> String {
        if case .window = item { return WindowManager.accessReason }
        return PromptsModel.pasteReason
    }

    private func key(_ press: KeyPress, item: PaletteItem) -> KeyPress.Result {
        guard press.modifiers.subtracting(.capsLock) == .command, press.characters.lowercased() == "e",
              case .action(let action) = item else { return .ignored }
        model.context.openLibrary(action.id)
        return .handled
    }

    private func submit(_ item: PaletteItem, alternate: Bool) {
        switch item {
        case .action(let action):
            deliver { await model.deliver(action, copyOnly: alternate) }
        case .snippet(let snippet):
            deliver { await model.deliver(snippet, copyOnly: alternate) }
        case .script(let script):
            run(script, show: alternate)
        case .window(let command):
            if let failure = commands.apply(command, to: model.context.invocation?.front) {
                error = failure
            } else {
                model.context.closeCommand()
            }
        case .file(let hit):
            commands.open(hit, reveal: alternate)
        }
    }

    private func run(_ script: Script, show: Bool) {
        guard !busy else { return }
        busy = true
        error = nil
        let invocation = model.context.invocation
        Task {
            defer { busy = false }
            do {
                let text = try await Scripts.run(script)
                if invocation?.cancelled == true { return }
                if show {
                    output = (script.name, text)
                } else if text.isEmpty {
                    error = CueError("SCRIPT_EMPTY", "\(script.name) printed nothing to copy.")
                } else if case .failedBeforeCopy(let failure) = await commands.copy(text) {
                    error = failure
                }
            } catch {
                self.error = error.cueError
            }
        }
    }

    private func deliver(_ work: @escaping () async -> Result<Delivery, CueError>) {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            switch await work() {
            case .success(.copiedNotPasted(let failure)):
                error = CueError(failure.code, "Text copied, but not pasted. \(failure.message)")
                recovering = true
                model.context.showCommandPassively()
            case .success(.failedBeforeCopy(let failure)):
                error = failure
            case .success:
                break
            case .failure(let failure):
                error = failure
            }
        }
    }
}
