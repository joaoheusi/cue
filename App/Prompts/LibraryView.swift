import AppKit
import CueKit
import SwiftUI

enum LibraryFilter: Hashable {
    case all, favorites, recent, disabled
    case category(String)
}

/// Selection and the unsaved editor draft. Survives closing the window, so closing never loses edits.
@MainActor @Observable final class LibraryNavigation {
    var filter: LibraryFilter = .all
    var query = ""
    private(set) var draft: Action?
    private(set) var original: Action?
    var pendingSelection: String??

    var isDirty: Bool { draft != nil && draft != original }

    func edit(_ action: Action?) {
        draft = action
        original = action
    }

    func newAction() {
        var action = Action()
        if case .category(let name) = filter { action.category = name }
        edit(action)
    }

    func update(_ change: (inout Action) -> Void) {
        guard var value = draft else { return }
        change(&value)
        draft = value
    }

    /// Selects an action unless that would discard edits; then it asks first.
    func select(_ id: String?, in snapshot: LibrarySnapshot) {
        guard id != draft?.id else { return }
        if isDirty {
            pendingSelection = .some(id)
            return
        }
        apply(id, in: snapshot)
    }

    func apply(_ id: String?, in snapshot: LibrarySnapshot) {
        pendingSelection = nil
        if id == "new" { newAction() } else { edit(snapshot.actions.first { $0.id == id }) }
    }
}

struct LibraryView: View {
    let model: PromptsModel
    @Bindable var nav: LibraryNavigation
    @State private var newCategory: String?
    @State private var renaming: (old: String, name: String)?

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
                split(snapshot)
            }
        }
        .frame(minWidth: 760, minHeight: 540)
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
    }

    private func split(_ snapshot: LibrarySnapshot) -> some View {
        NavigationSplitView {
            sidebar(snapshot)
        } content: {
            list(snapshot)
        } detail: {
            if nav.draft != nil {
                EditorView(model: model, nav: nav, snapshot: snapshot)
            } else {
                EmptyStateView(symbol: "text.cursor", title: "Your next instruction starts here.",
                               message: "Select an action, or create one with ⌘N.", actionTitle: "New Action") { nav.select("new", in: snapshot) }
            }
        }
        .confirmationDialog("Discard unsaved changes?", isPresented: Binding(get: { nav.pendingSelection != nil }, set: { if !$0 { nav.pendingSelection = nil } })) {
            Button("Discard Changes", role: .destructive) { nav.apply(nav.pendingSelection ?? nil, in: snapshot) }
            Button("Keep Editing", role: .cancel) { nav.pendingSelection = nil }
        } message: {
            Text("Your saved action stays as it is. Changes in this editor will be lost.")
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
        List(selection: Binding(get: { nav.filter }, set: { nav.filter = $0 ?? .all })) {
            Section("Library") {
                Label("All actions", systemImage: "tray.full").tag(LibraryFilter.all)
                Label("Favorites", systemImage: "star").tag(LibraryFilter.favorites)
                Label("Recent", systemImage: "clock").tag(LibraryFilter.recent)
                Label("Disabled", systemImage: "nosign").tag(LibraryFilter.disabled)
            }
            Section("Categories") {
                ForEach(snapshot.categories, id: \.self) { name in
                    Label(name, systemImage: "folder").tag(LibraryFilter.category(name))
                        .contextMenu {
                            Button("Rename…") { renaming = (name, name) }
                            Button("Delete Category", role: .destructive) {
                                // Its actions stay in the library without a category.
                                Task { await model.perform { try await $0.category(old: name, name: "", revision: snapshot.revision) } }
                            }
                        }
                }
                Button { newCategory = "" } label: { Label("New Category…", systemImage: "plus") }.buttonStyle(.borderless)
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 200)
    }

    private func filtered(_ snapshot: LibrarySnapshot) -> [Action] {
        let base: [Action] = switch nav.filter {
        case .all: snapshot.actions
        case .favorites: snapshot.actions.filter(\.favorite)
        case .recent: snapshot.actions.filter { $0.lastUsedAt != nil }.sorted { ($0.lastUsedAt ?? "") > ($1.lastUsedAt ?? "") }
        case .disabled: snapshot.actions.filter { !$0.enabled }
        case .category(let name): snapshot.actions.filter { $0.category == name }
        }
        if nav.filter == .recent && nav.query.isEmpty { return base }
        return ActionSearch.search(base, query: nav.query, enabledOnly: false)
    }

    private func list(_ snapshot: LibrarySnapshot) -> some View {
        let actions = filtered(snapshot)
        return List(selection: Binding(get: { nav.draft?.id }, set: { nav.select($0, in: snapshot) })) {
            ForEach(actions) { action in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(action.name).lineLimit(1)
                        if action.favorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
                        if !action.enabled { Text("Disabled").font(.caption).foregroundStyle(.secondary) }
                    }
                    Text(action.description.isEmpty ? (action.category ?? "Text action") : action.description)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .tag(action.id)
            }
        }
        .overlay {
            if actions.isEmpty {
                EmptyStateView(symbol: "magnifyingglass", title: nav.query.isEmpty ? "Nothing here yet" : "No matching actions",
                               message: nav.query.isEmpty ? "Create an action or choose another filter." : "Try another name or tag.")
            }
        }
        .searchable(text: $nav.query, placement: .sidebar, prompt: "Filter actions")
        .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        .toolbar {
            ToolbarItemGroup {
                Button { nav.select("new", in: snapshot) } label: { Label("New Action", systemImage: "plus") }
                    .keyboardShortcut("n")
                Menu {
                    Button("Import Actions…") { Task { model.pendingImport = await model.previewImport() } }
                    Button("Export Actions…") { Task { await model.exportActions() } }
                    Divider()
                    Button("Open Palette") { model.context.openCommand(.prompts) }
                    Button("Settings…") { model.context.openSettings(.prompts) }
                } label: { Label("More", systemImage: "ellipsis.circle") }
            }
        }
    }
}

private struct IdentifiedPreview: Identifiable {
    let preview: ImportPreview
    var id: String { preview.token }
}

private struct ImportSheet: View {
    let preview: ImportPreview
    /// nil cancels. false adds everything as new; true updates matching IDs.
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

/// First run: optional starter actions and the palette shortcut. Saved in one transaction.
struct OnboardingView: View {
    let model: PromptsModel
    @State private var starters = Starters.actions()
    @State private var chosen = Set(Starters.actions().indices)
    @State private var shortcut = Shortcut("Super+Shift+Space")
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("YOUR PROMPTS, ON CUE.").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("Save the words you use again and again.").font(.largeTitle.weight(.semibold))
                Text("Cue lives in your menu bar. Press your shortcut in any app, pick an action, and Cue pastes it into the field you were typing in. Clipboard history and menu-bar tidying are off until you turn them on in Settings.")
                    .foregroundStyle(.secondary)
                GroupBox("Start with six useful actions") {
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
