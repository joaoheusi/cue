import AppKit
import CueKit
import SwiftUI

enum LibraryFilter: Hashable {
    case all, favorites, recent, disabled
    case runs(RunsAs)
    case category(String)
}

enum LibraryRow: Identifiable {
    case action(Action), script(Script)

    var id: String {
        switch self {
        case .action(let action): action.id
        case .script(let script): "script:\(script.id)"
        }
    }
}

@MainActor @Observable final class LibraryNavigation {
    var filter: LibraryFilter = .all
    var query = ""
    private(set) var draft: Action?
    private(set) var original: Action?
    private(set) var baseline: Action?
    private(set) var script: Script?
    var saving = false
    var pendingSelection: String??
    @ObservationIgnored var save: (Action) async -> Action? = { _ in nil }

    var isDirty: Bool { draft != nil && draft != original }

    func edit(_ action: Action?) {
        draft = action
        original = action
        baseline = action
        script = nil
    }

    func show(_ script: Script) {
        edit(nil)
        self.script = script
    }

    func newAction() {
        var action = Action()
        if case .category(let name) = filter { action.category = name }
        if case .runs(.claude) = filter { action.ai = true }
        edit(action)
    }

    func update(_ change: (inout Action) -> Void) {
        guard var value = draft else { return }
        change(&value)
        draft = value
    }

    func adopt(_ saved: Action, sent: Action) {
        original = saved
        if baseline?.revision == 0 { baseline = saved }
        guard var current = draft, current.id == saved.id else { return }
        if current == sent {
            draft = saved
            return
        }
        current.revision = saved.revision
        current.updatedAt = saved.updatedAt
        current.createdAt = saved.createdAt
        current.useCount = saved.useCount
        current.lastUsedAt = saved.lastUsedAt
        draft = current
    }

    func revert() {
        guard var value = baseline, let original else { return }
        value.revision = original.revision
        value.updatedAt = original.updatedAt
        value.useCount = original.useCount
        value.lastUsedAt = original.lastUsedAt
        draft = value
    }

    var canSave: Bool {
        guard var copy = draft else { return false }
        do {
            try ActionRules.validate(&copy)
            return true
        } catch {
            return false
        }
    }

    func flush() async {
        while saving { try? await Task.sleep(for: .milliseconds(20)) }
        guard isDirty, canSave, let sent = draft else { return }
        saving = true
        defer { saving = false }
        if let saved = await save(sent) { adopt(saved, sent: sent) }
    }

    func leave(then go: @escaping () -> Void, blocked: @escaping () -> Void) {
        guard isDirty else { return go() }
        Task {
            await flush()
            isDirty ? blocked() : go()
        }
    }

    func select(_ id: String?, in snapshot: LibrarySnapshot) {
        guard id != draft?.id else { return }
        leave(then: { self.apply(id, in: snapshot) }, blocked: { self.pendingSelection = .some(id) })
    }

    func apply(_ id: String?, in snapshot: LibrarySnapshot) {
        pendingSelection = nil
        if id == "new" { newAction() } else { edit(snapshot.actions.first { $0.id == id }) }
    }
}

struct LibraryView: View {
    let model: PromptsModel
    let commands: CommandsModule
    @Bindable var nav: LibraryNavigation
    @State private var newCategory: String?
    @State private var renaming: (old: String, name: String)?
    @FocusState private var filterFocused: Bool

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                LoadingView(label: "Opening Cue…")
            case .failed(let error):
                VStack(spacing: 12) {
                    Text("Could not open your library").font(.title2)
                    ErrorBanner(error: error) { Task { await model.load() } }.frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let snapshot) where !snapshot.settings.onboarded:
                OnboardingView(model: model)
            case .loaded(let snapshot):
                content(snapshot)
            }
        }
        .frame(minWidth: 960, minHeight: 600)
        .overlay(alignment: .bottom) {
            if let notice = model.notice {
                StatusLine(text: notice.text, success: notice.success)
                    .padding(8).background(.regularMaterial, in: Capsule()).padding(12)
                    .task(id: notice.text) {
                        try? await Task.sleep(for: .seconds(4))
                        if model.notice?.text == notice.text { model.notice = nil }
                    }
            }
        }
        .sheet(item: Binding(get: { model.run?.surface == .library ? model.run : nil }, set: { if $0 == nil { model.closeRun() } })) { run in
            RunView(run: run, model: model).frame(width: 680, height: 460)
        }
    }

    private func content(_ snapshot: LibrarySnapshot) -> some View {
        HStack(spacing: 0) {
            sidebar(snapshot)
            Rectangle().fill(Cue.hairline).frame(width: 1)
            VStack(spacing: 0) {
                header(snapshot)
                Rectangle().fill(Cue.hairline).frame(height: 1)
                HStack(spacing: 0) {
                    list(snapshot).frame(width: 300)
                    Rectangle().fill(Cue.hairline).frame(width: 1)
                    detail(snapshot).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .ignoresSafeArea(.all, edges: .top)
        .task { await commands.reload() }
        .onChange(of: snapshot.actions) { _, actions in
            guard !nav.isDirty, !nav.saving, let current = nav.draft, let fresh = actions.first(where: { $0.id == current.id }), fresh != current else { return }
            nav.edit(fresh)
        }
        .confirmationDialog("Discard unsaved changes?", isPresented: Binding(get: { nav.pendingSelection != nil }, set: { if !$0 { nav.pendingSelection = nil } })) {
            Button("Discard Changes", role: .destructive) { nav.apply(nav.pendingSelection ?? nil, in: snapshot) }
            Button("Keep Editing", role: .cancel) { nav.pendingSelection = nil }
        } message: {
            Text("This action cannot be saved yet. Changes in this editor will be lost.")
        }
        .sheet(item: Binding(get: { model.pendingImport.map(IdentifiedPreview.init) }, set: { model.pendingImport = $0?.preview })) { item in
            ImportSheet(preview: item.preview) { update in
                model.pendingImport = nil
                if let update { Task { await model.commitImport(item.preview, update: update) } }
            }
        }
        .alert("New Category", isPresented: Binding(get: { newCategory != nil }, set: { if !$0 { newCategory = nil } })) {
            TextField("Name", text: Binding(get: { newCategory ?? "" }, set: { newCategory = $0 }))
            Button("Create") {
                let name = newCategory ?? ""
                Task { await model.perform { try await $0.category(old: nil, name: name, revision: snapshot.revision) } }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Category", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: Binding(get: { renaming?.name ?? "" }, set: { renaming?.name = $0 }))
            Button("Rename") {
                guard let renaming else { return }
                Task { await model.perform { try await $0.category(old: renaming.old, name: renaming.name, revision: snapshot.revision) } }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func sidebar(_ snapshot: LibrarySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 30)
            List(selection: Binding(get: { nav.filter }, set: { nav.filter = $0 ?? .all })) {
                Section("Library") {
                    entry("All Actions", "tray.full", .all, snapshot.actions.count + commands.scripts.count)
                    entry("Favorites", "star", .favorites, snapshot.actions.filter(\.favorite).count)
                    entry("Recent", "clock", .recent, nil)
                    entry("Disabled", "nosign", .disabled, snapshot.actions.filter { !$0.enabled }.count)
                }
                Section("Runs as") {
                    runsEntry(.claude, "Claude", snapshot.actions.filter { $0.runsAs == .claude }.count)
                    runsEntry(.text, "Text", snapshot.actions.filter { $0.runsAs == .text }.count)
                    runsEntry(.script, "Scripts", commands.scripts.count)
                }
                Section("Categories") {
                    ForEach(snapshot.categories, id: \.self) { name in
                        entry(name, "folder", .category(name), snapshot.actions.filter { $0.category == name }.count)
                            .contextMenu {
                                Button("Rename…") { renaming = (name, name) }
                                Button("Delete Category", role: .destructive) {
                                    Task { await model.perform { try await $0.category(old: name, name: "", revision: snapshot.revision) } }
                                }
                            }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            Button { newCategory = "" } label: {
                Label("New Category", systemImage: "plus").font(.system(size: 12.5))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(width: 220)
        .background(Color.primary.opacity(0.03))
    }

    private func entry(_ title: String, _ symbol: String, _ filter: LibraryFilter, _ count: Int?) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            if let count, count > 0 { Text("\(count)").font(.system(size: 11.5)).foregroundStyle(.secondary) }
        }
        .tag(filter)
    }

    private func runsEntry(_ kind: RunsAs, _ title: String, _ count: Int) -> some View {
        HStack(spacing: 8) {
            Tile(kind, size: 15)
            Text(title)
            Spacer()
            if count > 0 { Text("\(count)").font(.system(size: 11.5)).foregroundStyle(.secondary) }
        }
        .tag(LibraryFilter.runs(kind))
    }

    private var filterTitle: String {
        switch nav.filter {
        case .all: "All Actions"
        case .favorites: "Favorites"
        case .recent: "Recent"
        case .disabled: "Disabled"
        case .runs(let kind): kind == .script ? "Scripts" : kind.title
        case .category(let name): name
        }
    }

    private func header(_ snapshot: LibrarySnapshot) -> some View {
        HStack(spacing: 10) {
            Text(filterTitle).font(.system(size: 15, weight: .bold))
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("Filter", text: $nav.query).textFieldStyle(.plain).font(.system(size: 13)).focused($filterFocused)
                Key(text: "⌘F")
            }
            .padding(.horizontal, 10)
            .frame(width: 220, height: 28)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background {
                Button("Filter") { filterFocused = true }.keyboardShortcut("f").opacity(0).allowsHitTesting(false).accessibilityHidden(true)
            }
            Menu {
                Button("New Action") { nav.select("new", in: snapshot) }
                Divider()
                Button("Import Actions…") { Task { model.pendingImport = await model.previewImport() } }
                Button("Export Actions…") { Task { await model.exportActions() } }
                Divider()
                Button("Open Palette") { model.context.openCommand(.prompts) }
                Button("Settings…") { model.context.openSettings(.actions) }
            } label: {
                Label("New", systemImage: "plus")
            } primaryAction: {
                nav.select("new", in: snapshot)
            }
            .menuStyle(.button)
            .buttonStyle(.borderedProminent)
            .fixedSize()
            .accessibilityLabel("New action")
            .background {
                Button("New Action") { nav.select("new", in: snapshot) }.keyboardShortcut("n").opacity(0).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .frame(height: 52)
    }

    private func filtered(_ snapshot: LibrarySnapshot) -> [LibraryRow] {
        let base: [Action] = switch nav.filter {
        case .all: snapshot.actions
        case .favorites: snapshot.actions.filter(\.favorite)
        case .recent: snapshot.actions.filter { $0.lastUsedAt != nil }.sorted { ($0.lastUsedAt ?? "") > ($1.lastUsedAt ?? "") }
        case .disabled: snapshot.actions.filter { !$0.enabled }
        case .runs(.script): []
        case .runs(let kind): snapshot.actions.filter { $0.runsAs == kind }
        case .category(let name): snapshot.actions.filter { $0.category == name }
        }
        let actions = nav.filter == .recent && nav.query.isEmpty ? base : ActionSearch.search(base, query: nav.query, enabledOnly: false)
        var rows = actions.map(LibraryRow.action)
        switch nav.filter {
        case .all, .runs(.script):
            rows += commands.scripts.filter { ActionSearch.score(nav.query, name: $0.name) != nil }.map(LibraryRow.script)
        default:
            break
        }
        return rows
    }

    private func list(_ snapshot: LibrarySnapshot) -> some View {
        let rows = filtered(snapshot)
        return List(selection: Binding(get: { nav.script.map { LibraryRow.script($0).id } ?? nav.draft?.id }, set: { id in
            if let id, id.hasPrefix("script:"), case .script(let script)? = rows.first(where: { $0.id == id }) {
                nav.leave(then: { nav.show(script) }, blocked: { nav.pendingSelection = .some(nil) })
            } else {
                nav.select(id, in: snapshot)
            }
        })) {
            ForEach(rows) { row in
                listRow(row, snapshot).tag(row.id).listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .overlay {
            if rows.isEmpty {
                EmptyStateView(symbol: "magnifyingglass", title: nav.query.isEmpty ? "Nothing here yet" : "No matching actions",
                               message: nav.query.isEmpty ? "Create an action or choose another filter." : "Try another name or tag.")
            }
        }
    }

    @ViewBuilder private func listRow(_ row: LibraryRow, _ snapshot: LibrarySnapshot) -> some View {
        switch row {
        case .action(let action):
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("\(action.runsAs.title) · \(action.category ?? "No category")").font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if action.favorite { Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(.yellow) }
                if let shortcut = snapshot.bindings[PromptsModel.owner(action)].flatMap(Shortcut.init) { Key(text: shortcut.display) }
                if !action.enabled { Text("Off").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            .opacity(action.enabled ? 1 : 0.5)
            .padding(.vertical, 4)
        case .script(let script):
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(script.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("Script · \(script.url.lastPathComponent)").font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let shortcut = commands.shortcut(for: script) { Key(text: shortcut.display) }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder private func detail(_ snapshot: LibrarySnapshot) -> some View {
        if nav.draft != nil {
            EditorView(model: model, nav: nav, snapshot: snapshot)
        } else if let script = nav.script {
            ScriptEditorView(script: script, model: model, commands: commands).id(script.id)
        } else {
            EmptyStateView(symbol: "text.cursor", title: "Your next instruction starts here.",
                           message: "Select an action, or create one with ⌘N.", actionTitle: "New Action") { nav.select("new", in: snapshot) }
        }
    }
}

private struct IdentifiedPreview: Identifiable {
    let preview: ImportPreview
    var id: String { preview.token }
}

private struct ImportSheet: View {
    let preview: ImportPreview
    let finish: (Bool?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import \(preview.actions.count) actions").font(.title2)
            Text("\(preview.duplicateIDs) match existing IDs. \(preview.duplicateNames) match existing names. Names alone never overwrite.")
            if !preview.newCategories.isEmpty {
                Text("New categories: \(preview.newCategories.joined(separator: ", "))").foregroundStyle(.secondary)
            }
            Text("Imported actions use Copy delivery and have no shortcuts. Cue backs up your library first.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Cancel", role: .cancel) { finish(nil) }.keyboardShortcut(.cancelAction)
                Spacer()
                if preview.duplicateIDs > 0 { Button("Update Matching IDs") { finish(true) } }
                Button("Add as New Actions") { finish(false) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

struct OnboardingView: View {
    let model: PromptsModel
    @State private var starters = Starters.actions()
    @State private var chosen = Set(Starters.actions().indices)
    @State private var shortcut = Shortcut("Alt+Space")
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("YOUR PROMPTS, ON CUE.").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("Save the words you use again and again.").font(.largeTitle.weight(.semibold))
                Text("Cue lives in your menu bar. Press your shortcut in any app, pick an action, and Cue pastes it into the field you were typing in. Clipboard history and menu-bar tidying are off until you turn them on in Settings.")
                    .foregroundStyle(.secondary)
                GroupBox("Start with these useful actions") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(starters.enumerated()), id: \.offset) { index, action in
                            Toggle(isOn: Binding(get: { chosen.contains(index) }, set: { on in
                                if on { chosen.insert(index) } else { chosen.remove(index) }
                            })) {
                                VStack(alignment: .leading) {
                                    Text(action.name)
                                    Text(action.description).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Call it up") {
                    HStack {
                        Text("Palette shortcut")
                        Spacer()
                        ShortcutRecorder(value: shortcut) { shortcut = $0 }
                    }
                    .padding(6)
                }
                HStack {
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Button(chosen.isEmpty ? "Start with an Empty Library" : "Add Starter Actions") {
                        busy = true
                        Task {
                            await model.onboard(chosen.sorted().map { starters[$0] }, palette: shortcut)
                            busy = false
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy)
                }
            }
            .padding(32)
            .frame(maxWidth: 620)
        }
        .frame(maxWidth: .infinity)
    }
}
