import AppKit
import CueKit
import SwiftUI

enum PaletteFilter: String, CaseIterable {
    case all, apps, folders, files, actions

    var title: String { rawValue.capitalized }
}

enum PaletteCommand: String, CaseIterable {
    case newAction, openLibrary

    var title: String {
        switch self {
        case .newAction: "New Action"
        case .openLibrary: "Open Library"
        }
    }

    var symbol: String {
        switch self {
        case .newAction: "plus"
        case .openLibrary: "doc.text"
        }
    }

    var target: String? { self == .newAction ? "new" : nil }
}

enum PaletteItem: Identifiable {
    case action(Action), snippet(Snippet), script(Script), window(WindowCommand), file(FileHit), command(PaletteCommand)
    case showAll(PaletteFilter, Int)

    var id: String {
        switch self {
        case .action(let action): "action:\(action.id)"
        case .snippet(let snippet): "snippet:\(snippet.id)"
        case .script(let script): "script:\(script.id)"
        case .window(let command): command.owner
        case .file(let hit): "file:\(hit.id)"
        case .command(let command): "command:\(command.rawValue)"
        case .showAll(let filter, _): "all:\(filter.rawValue)"
        }
    }
}

private struct PaletteEntry: Identifiable {
    var item: PaletteItem
    var header: String?
    var id: String { item.id }
}

private struct PaletteResults {
    var actions: [PaletteItem] = []
    var apps: [PaletteItem] = []
    var folders: [PaletteItem] = []
    var files: [PaletteItem] = []

    var total: Int { actions.count + apps.count + folders.count + files.count }

    func count(_ filter: PaletteFilter) -> Int {
        switch filter {
        case .all: total
        case .apps: apps.count
        case .folders: folders.count
        case .files: files.count
        case .actions: actions.count
        }
    }
}

struct PaletteView: View {
    private struct Asking {
        var action: Action
        var questions: [String]
        var copyOnly: Bool
    }

    let model: PromptsModel
    let commands: CommandsModule
    let clipboard: ClipboardModule
    @State private var query = ""
    @State private var selection: String?
    @State private var filter = PaletteFilter.all
    @State private var busy = false
    @State private var error: CueError?
    @State private var recovering = false
    @State private var asking: Asking?
    @State private var frozenUsage: [String: String]

    init(model: PromptsModel, commands: CommandsModule, clipboard: ClipboardModule) {
        self.model = model
        self.commands = commands
        self.clipboard = clipboard
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
            if let run = model.run, run.surface == .palette {
                RunView(run: run, model: model).preference(key: HidesSwitcherKey.self, value: true)
            } else if let asking {
                AskView(title: asking.action.name, kind: asking.action.runsAs, questions: asking.questions, back: { self.asking = nil }) { answers in
                    self.asking = nil
                    launch(asking.action, copyOnly: asking.copyOnly, answers: answers)
                }
                .preference(key: HidesSwitcherKey.self, value: true)
            } else {
                palette(snapshot)
            }
        }
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    private func usage(_ script: Script, _ snapshot: LibrarySnapshot) -> String? {
        snapshot.settings.scriptUsage[script.url.lastPathComponent]
    }

    private func home(_ snapshot: LibrarySnapshot) -> [PaletteEntry] {
        let enabled = snapshot.actions.filter(\.enabled)
        let favorites = enabled.filter(\.favorite).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var recent: [(item: PaletteItem, used: String)] = enabled.filter { !$0.favorite }.compactMap { action in
            frozenUsage[action.id].map { (.action(action), $0) }
        }
        recent += commands.scripts.compactMap { script in usage(script, snapshot).map { (.script(script), $0) } }
        recent.sort { $0.used > $1.used }
        recent = Array(recent.prefix(5))
        let shown = Set(recent.map(\.item.id))
        let rest = enabled.filter { !$0.favorite && !shown.contains(PaletteItem.action($0).id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return section("Favorites", favorites.map(PaletteItem.action)) + section("Recent", recent.map(\.item))
            + section("Actions", rest.map(PaletteItem.action))
            + section("Scripts", commands.scripts.filter { !shown.contains(PaletteItem.script($0).id) }.map(PaletteItem.script))
            + section("Snippets", commands.snippets.map(PaletteItem.snippet))
            + section("Window", WindowCommand.allCases.map(PaletteItem.window))
    }

    private func section(_ title: String, _ items: [PaletteItem]) -> [PaletteEntry] {
        items.enumerated().map { PaletteEntry(item: $0.element, header: $0.offset == 0 ? title : nil) }
    }

    private func results(_ snapshot: LibrarySnapshot) -> PaletteResults {
        var results = PaletteResults()
        let sources = Set(snapshot.settings.searchIn)
        if sources.contains(.actions) {
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
            commands.snippets.forEach { add(.snippet($0), $0.keyword) }
            commands.scripts.forEach { add(.script($0), $0.name) }
            WindowCommand.allCases.forEach { add(.window($0), $0.title) }
            PaletteCommand.allCases.forEach { add(.command($0), $0.title) }
            results.actions = ranked.enumerated().sorted { a, b in
                (a.element.tier, a.element.weight, a.offset) < (b.element.tier, b.element.weight, b.offset)
            }.map(\.element.item)
        }
        if sources.contains(.apps) {
            results.apps = commands.apps.compactMap { hit in ActionSearch.score(query, name: hit.title).map { (hit, $0.tier, $0.weight) } }
                .sorted { ($0.1, $0.2) < ($1.1, $1.2) }.map { .file($0.0) }
        }
        if sources.contains(.folders) { results.folders = commands.files.results.filter(\.isFolder).map(PaletteItem.file) }
        if sources.contains(.files) { results.files = commands.files.results.filter { !$0.isFolder }.map(PaletteItem.file) }
        return results
    }

    private func capped(_ items: [PaletteItem], _ limit: Int, _ kind: PaletteFilter) -> [PaletteItem] {
        items.count <= limit ? items : Array(items.prefix(limit)) + [.showAll(kind, items.count)]
    }

    private func entries(_ results: PaletteResults) -> [PaletteEntry] {
        switch filter {
        case .all:
            section("Actions", results.actions) + section("Apps", capped(results.apps, 5, .apps))
                + section("Folders", capped(results.folders, 3, .folders)) + section("Files", capped(results.files, 3, .files))
        case .apps: section("Apps", results.apps)
        case .folders: section("Folders", results.folders)
        case .files: section("Files", results.files)
        case .actions: section("Actions", results.actions)
        }
    }

    @ViewBuilder private func palette(_ snapshot: LibrarySnapshot) -> some View {
        let found = results(snapshot)
        let list = trimmed.isEmpty ? home(snapshot) : entries(found)
        let current = list.first { $0.id == selection }?.item
        VStack(spacing: 0) {
            CommandList(query: $query, placeholder: "Search actions, apps, files", items: list, selection: $selection,
                        header: { $0.header },
                        listWidth: trimmed.isEmpty ? CommandMetrics.listWidth : 470,
                        showsDetail: snapshot.settings.previewPane && !list.isEmpty,
                        row: { entry, selected in row(entry.item, selected: selected, snapshot: snapshot) },
                        bar: { if !trimmed.isEmpty { chips(found) } },
                        detail: { detail(current, snapshot) },
                        onSubmit: { entry, alternate in submit(entry.item, alternate: alternate) },
                        onKeyPress: { _, press in key(press) })
                .overlay {
                    if list.isEmpty {
                        EmptyStateView(symbol: "magnifyingglass", title: "No matches", message: "Try another name, alias, or tag. Press ⌘N to add a new action.")
                            .padding(.top, 60)
                    }
                }
            footer(current, count: trimmed.isEmpty ? snapshot.actions.filter(\.enabled).count + commands.scripts.count : found.count(filter), searching: !trimmed.isEmpty)
        }
        .onAppear(perform: takePendingAsk)
        .onChange(of: model.pendingAsk?.id) { takePendingAsk() }
        .onChange(of: query) {
            error = nil
            commands.files.clear()
            if trimmed.isEmpty { filter = .all }
        }
        .task { await commands.reload() }
        .task(id: query) {
            guard !model.context.isUITesting else { return }
            try? await Task.sleep(for: .milliseconds(80))
            if !Task.isCancelled { commands.files.search(query, scope: FileScope(locations: snapshot.settings.fileLocations, skip: snapshot.settings.skipFolders)) }
        }
        .onDisappear { commands.files.stop() }
    }

    private func takePendingAsk() {
        guard let action = model.pendingAsk else { return }
        model.pendingAsk = nil
        submit(.action(action), alternate: false)
    }

    private func chips(_ found: PaletteResults) -> some View {
        HStack(spacing: 6) {
            ForEach(PaletteFilter.allCases, id: \.self) { option in
                FilterChip(title: option.title, count: found.count(option), selected: filter == option) { filter = option }
            }
            Spacer()
            HStack(spacing: 6) {
                Key(text: "⇥")
                Text("Next filter")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    @ViewBuilder private func detail(_ item: PaletteItem?, _ snapshot: LibrarySnapshot) -> some View {
        switch item {
        case .action(let action)?: ActionDetail(action: action, model: model, clipboard: clipboard).id(action.id)
        case .snippet(let snippet)?: SnippetDetail(snippet: snippet)
        case .script(let script)?: ScriptDetail(script: script, timeout: snapshot.settings.scriptTimeout)
        case .window(let command)?: WindowDetail(command: command, shortcut: commands.shortcut(for: command))
        case .file(let hit)?: FileDetail(hit: hit).id(hit.id)
        default: EmptyView()
        }
    }

    private func age(_ stamp: String?) -> String? {
        stamp.flatMap(Timestamp.parse).map { ShortAge.text($0) }
    }

    @ViewBuilder private func row(_ item: PaletteItem, selected: Bool, snapshot: LibrarySnapshot) -> some View {
        switch item {
        case .action(let action):
            CommandRow(title: action.name, subtitle: action.ai == true ? "AI" : action.category ?? "Text", selected: selected, match: trimmed) {
                Tile(action.runsAs)
            } accessory: {
                if let chord = snapshot.bindings[PromptsModel.owner(action)], let shortcut = Shortcut(chord) {
                    Key(text: shortcut.display)
                } else if let age = age(frozenUsage[action.id]), trimmed.isEmpty, !action.favorite {
                    Text(age)
                }
            }
        case .snippet(let snippet):
            CommandRow(title: snippet.keyword, subtitle: ClipboardSearch.preview(snippet.expansion), selected: selected, match: trimmed) {
                Tile(symbol: "text.quote", color: Cue.text)
            } accessory: { EmptyView() }
        case .script(let script):
            CommandRow(title: script.name, subtitle: "Script", selected: selected, match: trimmed) {
                Tile(.script)
            } accessory: {
                if let age = age(usage(script, snapshot)), trimmed.isEmpty { Text(age) }
            }
        case .window(let command):
            CommandRow(title: command.title, subtitle: "Window", selected: selected, match: trimmed) {
                Tile(symbol: command.symbol, color: Cue.text)
            } accessory: {
                if let shortcut = commands.shortcut(for: command) { Key(text: shortcut.display) }
            }
        case .file(let hit):
            CommandRow(title: hit.title, subtitle: hit.isApp ? nil : shortened(hit.folder), selected: selected, match: trimmed) {
                FileIcon(path: hit.url.path)
            } accessory: {
                if hit.isApp { Text("Application") }
            }
        case .command(let command):
            CommandRow(title: command.title, subtitle: "Library", selected: selected, match: trimmed) {
                Tile(symbol: command.symbol, color: Cue.text)
            } accessory: { EmptyView() }
        case .showAll(let kind, let count):
            HStack {
                Text("Show all \(count) \(kind.rawValue)").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.accentColor)
                Spacer()
            }
            .padding(.leading, 46)
            .frame(height: 34)
            .background(selected ? Cue.selection : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func shortened(_ folder: String) -> String {
        let parts = folder.split(separator: "/")
        return parts.count > 3 ? ".../" + parts.suffix(2).joined(separator: "/") : folder
    }

    @ViewBuilder private func footer(_ current: PaletteItem?, count: Int, searching: Bool) -> some View {
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
                Text("\(count) \(searching ? "results" : "actions")")
            } trailing: {
                hints(current)
                if let current { ActionsHint(target: current.id) { showMenu(current) } }
            }
        }
    }

    @ViewBuilder private func hints(_ item: PaletteItem?) -> some View {
        switch item {
        case .action(let action):
            if action.ai == true {
                KeyHint(label: "Run", keys: "↵", primary: true)
                KeyHint(label: "Copy result", keys: "⌘↵")
            } else if model.willPaste(action, copyOnly: false) {
                KeyHint(label: "Paste", keys: "↵", primary: true)
                KeyHint(label: "Copy", keys: "⌘↵")
            } else {
                KeyHint(label: "Copy", keys: "↵", primary: true)
            }
            ShortcutHint(label: "Edit", keys: "⌘E", key: "e", target: action.id) { model.context.openLibrary(action.id) }
        case .snippet:
            if model.willPasteByDefault {
                KeyHint(label: "Paste", keys: "↵", primary: true)
                KeyHint(label: "Copy", keys: "⌘↵")
            } else {
                KeyHint(label: "Copy", keys: "↵", primary: true)
            }
        case .script:
            let shows = model.snapshot?.settings.scriptOutput == .show
            KeyHint(label: shows ? "Show Output" : "Copy Output", keys: "↵", primary: true)
            KeyHint(label: shows ? "Copy Output" : "Show Output", keys: "⌘↵")
        case .window:
            KeyHint(label: "Apply", keys: "↵", primary: true)
        case .file(let hit):
            KeyHint(label: "Open", keys: "↵", primary: true)
            KeyHint(label: "Show in Finder", keys: "⌘↵")
            ShortcutHint(label: "Copy Path", keys: "⌘⇧C", key: "c", modifiers: [.command, .shift], target: hit.id) { commands.copyPath(hit) }
        case .command:
            KeyHint(label: "Open", keys: "↵", primary: true)
        case .showAll:
            KeyHint(label: "Show", keys: "↵", primary: true)
        case nil:
            EmptyView()
        }
    }

    private func showMenu(_ item: PaletteItem) {
        PanelMenu.show { menu in
            switch item {
            case .action(let action):
                menu.add(action.ai == true ? "Run" : "Use") { submit(item, alternate: false) }
                menu.add(action.ai == true ? "Copy Result" : "Copy") { submit(item, alternate: true) }
                menu.add("Edit in Library") { model.context.openLibrary(action.id) }
                menu.addItem(.separator())
                menu.add(action.favorite ? "Remove from Favorites" : "Add to Favorites") { Task { await model.setFavorite(action, !action.favorite) } }
                menu.add("Disable") { Task { await model.setEnabled(action, false) } }
            case .snippet:
                menu.add("Use") { submit(item, alternate: false) }
                menu.add("Copy") { submit(item, alternate: true) }
            case .script(let script):
                menu.add("Run") { submit(item, alternate: false) }
                menu.add("Run Other Way") { submit(item, alternate: true) }
                menu.add("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([script.url]) }
            case .window:
                menu.add("Apply") { submit(item, alternate: false) }
            case .file(let hit):
                menu.add("Open") { commands.open(hit, reveal: false) }
                menu.add("Show in Finder") { commands.open(hit, reveal: true) }
                menu.add("Copy Path") { commands.copyPath(hit) }
            case .command:
                menu.add("Open") { submit(item, alternate: false) }
            case .showAll:
                break
            }
            menu.addItem(.separator())
            menu.add("New Action") { model.context.openLibrary("new") }
            menu.add("Settings…") { model.context.openSettings(.palette) }
        }
    }

    private func permissionError(_ error: CueError) -> Bool {
        error.code == "PERMISSION_REQUIRED" || error.code == "PASTE_PERMISSION_REQUIRED"
    }

    private func reason(for item: PaletteItem?) -> String {
        if case .window = item { return WindowManager.accessReason }
        return PromptsModel.pasteReason
    }

    private func key(_ press: KeyPress) -> KeyPress.Result {
        guard press.key == .tab, !trimmed.isEmpty else { return .ignored }
        let all = PaletteFilter.allCases
        let index = all.firstIndex(of: filter) ?? 0
        filter = all[(index + (press.modifiers.contains(.shift) ? all.count - 1 : 1)) % all.count]
        return .handled
    }

    private func submit(_ item: PaletteItem, alternate: Bool) {
        switch item {
        case .action(let action):
            let questions = (try? Template.uses(action.template).questions) ?? []
            if questions.isEmpty {
                launch(action, copyOnly: alternate, answers: [:])
            } else {
                asking = Asking(action: action, questions: questions, copyOnly: alternate)
            }
        case .snippet(let snippet):
            deliver { await model.deliver(snippet, copyOnly: alternate) }
        case .script(let script):
            run(script, show: (model.snapshot?.settings.scriptOutput == .show) != alternate)
        case .window(let command):
            if let failure = commands.apply(command, to: model.context.invocation?.front) {
                error = failure
            } else {
                model.context.closeCommand()
            }
        case .file(let hit):
            commands.open(hit, reveal: alternate)
        case .command(let command):
            model.context.openLibrary(command.target)
        case .showAll(let kind, _):
            filter = kind
        }
    }

    private func launch(_ action: Action, copyOnly: Bool, answers: [String: String]) {
        if action.ai == true {
            guard !busy else { return }
            busy = true
            error = nil
            Task {
                defer { busy = false }
                error = await model.startRun(action, copyOnly: copyOnly, answers: answers)
            }
        } else {
            deliver { await model.deliver(action, copyOnly: copyOnly, answers: answers) }
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
                let text = try await commands.run(script)
                if invocation?.cancelled == true { return }
                if show {
                    model.showOutput(script.name, text: text, surface: .palette)
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
