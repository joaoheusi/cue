import CueKit
import SwiftUI

/// The Prompts scope of the command window. ↩ uses the default delivery, ⇧↩ copies,
/// ⌘E edits, ⌘N creates, ⌘, opens settings.
struct PaletteView: View {
    let model: PromptsModel
    @State private var query = ""
    @State private var selection: String?
    @State private var busy = false
    @State private var error: CueError?
    /// True while the window is shown passively after a failed paste.
    @State private var recovering = false
    /// Ranking uses the usage order from when the window opened, so rows never jump mid-search.
    @State private var frozenUsage: [String: String]

    init(model: PromptsModel) {
        self.model = model
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
            .padding()
        case .loaded(let snapshot):
            if !snapshot.actions.contains(where: \.enabled) {
                EmptyStateView(symbol: "text.badge.plus", title: "No actions yet", message: "Add your first reusable instruction.",
                               actionTitle: "Open Library") { model.context.openLibrary("new") }
            } else {
                palette(snapshot)
            }
        }
    }

    private func results(_ snapshot: LibrarySnapshot) -> [Action] {
        let actions = snapshot.actions.map { action in
            var copy = action
            copy.lastUsedAt = frozenUsage[action.id]
            return copy
        }
        // Rank with frozen usage, then return the live actions so revisions stay current.
        let live = Dictionary(uniqueKeysWithValues: snapshot.actions.map { ($0.id, $0) })
        return ActionSearch.search(actions, query: query).compactMap { live[$0.id] }
    }

    @ViewBuilder private func palette(_ snapshot: LibrarySnapshot) -> some View {
        let items = results(snapshot)
        let current = items.first { $0.id == selection }
        VStack(spacing: 0) {
            CommandList(query: $query, placeholder: "What do you need to do?", items: items, selection: $selection,
                        row: { action, selected in row(action, selected: selected, snapshot: snapshot) },
                        onSubmit: { action, copy in run(action, copyOnly: copy) },
                        onKeyPress: { action, press in key(press, action: action) })
                .overlay {
                    if items.isEmpty {
                        EmptyStateView(symbol: "magnifyingglass", title: "No matching actions", message: "Try another name, alias, or tag.")
                            .padding(.top, 60)
                    }
                }
            if snapshot.settings.preview, let current {
                Divider()
                ScrollView {
                    Text(current.template).font(.callout.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                .frame(maxHeight: 120)
            }
            Divider()
            footer(current, snapshot: snapshot)
        }
        .onChange(of: query) { error = nil }
    }

    private func row(_ action: Action, selected: Bool, snapshot: LibrarySnapshot) -> some View {
        CommandRow(title: action.name, subtitle: action.description.isEmpty ? (action.category ?? "Text action") : action.description,
                   symbol: action.category == "Writing" ? "text.alignleft" : "chevron.left.forwardslash.chevron.right", selected: selected) {
            HStack(spacing: 6) {
                if action.favorite { Image(systemName: "star.fill").font(.caption) }
                if action.template.contains("{{clipboard}}") { Image(systemName: "doc.on.clipboard").font(.caption) }
                if let chord = snapshot.bindings[PromptsModel.owner(action)], let shortcut = Shortcut(chord) {
                    Text(shortcut.display).font(.caption.monospaced())
                }
            }
        }
    }

    @ViewBuilder private func footer(_ current: Action?, snapshot: LibrarySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error {
                ErrorBanner(error: error, retryTitle: permissionError(error) ? "Allow Paste…" : "Dismiss") {
                    if permissionError(error), model.context.permissions.explain(.accessibility(reason: PromptsModel.pasteReason)) {
                        model.context.paste.requestAccess()
                    }
                    self.error = nil
                    if recovering { model.context.closeCommand() }
                }
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                let paste = current.map { model.willPaste($0, copyOnly: false) } ?? false
                Text(paste ? "↩ Paste  ⇧↩ Copy  ⌘E Edit  ⌘N New" : "↩ Copy  ⌘E Edit  ⌘N New")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(snapshot.actions.filter(\.enabled).count) actions").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func permissionError(_ error: CueError) -> Bool {
        error.code == "PERMISSION_REQUIRED" || error.code == "PASTE_PERMISSION_REQUIRED"
    }

    private func key(_ press: KeyPress, action: Action) -> KeyPress.Result {
        guard press.modifiers == .command else { return .ignored }
        switch press.characters {
        case "e": model.context.openLibrary(action.id)
        case "n": model.context.openLibrary("new")
        case ",": model.context.openSettings(.prompts)
        default: return .ignored
        }
        return .handled
    }

    private func run(_ action: Action, copyOnly: Bool) {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            switch await model.deliver(action, copyOnly: copyOnly) {
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
