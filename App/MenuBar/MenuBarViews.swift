import AppKit
import CueKit
import SwiftUI

private extension MenuBarSection {
    var symbol: String {
        switch self {
        case .visible: "eye"
        case .hidden: "eye.slash"
        case .alwaysHidden: "eye.slash.circle"
        }
    }
}

private enum MenuBarRow: Identifiable {
    case toggle(revealed: Bool), revealAll, apply, item(ScannedItem)

    var id: String {
        switch self {
        case .toggle: "toggle"
        case .revealAll: "revealAll"
        case .apply: "apply"
        case .item(let entry): "item:\(entry.id)"
        }
    }

    var title: String {
        switch self {
        case .toggle(let revealed): revealed ? "Hide items" : "Reveal hidden items"
        case .revealAll: "Reveal all"
        case .apply: "Apply rules now"
        case .item(let entry): entry.item.label
        }
    }
}

struct MenuBarCommandView: View {
    let module: MenuBarModule
    @State private var query = ""
    @State private var selection: String?

    var body: some View {
        Group {
            switch module.storage {
            case .loading:
                LoadingView()
            case .failed(let error):
                ErrorBanner(error: error) { Task { await module.start() } }
                    .padding([.horizontal, .bottom], 16).padding(.top, CommandMetrics.searchHeight)
                    .frame(maxHeight: .infinity, alignment: .top)
            case .loaded where !module.settings.enabled:
                EmptyStateView(symbol: "menubar.rectangle", title: "Menu bar hiding is off",
                               message: "Turn it on to hide menu-bar icons behind a chevron and reveal them with a shortcut.",
                               actionTitle: "Turn On") { Task { await module.setEnabled(true) } }
            case .loaded:
                VStack(spacing: 0) {
                    CommandList(query: $query, placeholder: "Search menu-bar items", items: rows, selection: $selection,
                                row: row, onSubmit: { row, _ in submit(row) }, onKeyPress: keyPress)
                    notices
                    CommandFooter {
                        EmptyView()
                    } trailing: {
                        if case .item(let entry)? = rows.first(where: { $0.id == selection }) {
                            KeyHint(label: "Open", keys: ["↩"])
                            if entry.item.movable { KeyHint(label: "Move", keys: ["⌥", "←", "→"]) }
                        } else {
                            KeyHint(label: "Run", keys: ["↩"])
                        }
                    }
                }
            }
        }
        .task { await module.refreshItems() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if (note.object as? NSWindow)?.accessibilityIdentifier() == "command.window" {
                Task { await module.refreshItems() }
            }
        }
    }

    private var rows: [MenuBarRow] {
        let text = query.trimmingCharacters(in: .whitespaces)
        var rows: [MenuBarRow] = [.toggle(revealed: module.isRevealed), .revealAll, .apply]
        if case .loaded(let entries) = module.items { rows += entries.map(MenuBarRow.item) }
        guard !text.isEmpty else { return rows }
        return rows.filter { row in
            if case .item(let entry) = row {
                return entry.item.appName.localizedCaseInsensitiveContains(text) || entry.item.label.localizedCaseInsensitiveContains(text)
            }
            return row.title.localizedCaseInsensitiveContains(text)
        }
    }

    @ViewBuilder private func row(_ row: MenuBarRow, _ selected: Bool) -> some View {
        switch row {
        case .item(let entry):
            CommandRow(title: entry.item.label, subtitle: "\(entry.section.title) · \(entry.item.appName)", symbol: entry.section.symbol, selected: selected) {
                if selected && !entry.item.movable { Text("Fixed by macOS") }
            }
        case .toggle(let revealed):
            CommandRow(title: row.title, subtitle: module.settings.shortcut.flatMap(Shortcut.init)?.display, symbol: revealed ? "chevron.right" : "chevron.left", selected: selected) { EmptyView() }
        case .revealAll:
            CommandRow(title: row.title, subtitle: "Includes always-hidden items", symbol: "chevron.left.2", selected: selected) { EmptyView() }
        case .apply:
            CommandRow(title: row.title, subtitle: "\(module.rules.count) rule\(module.rules.count == 1 ? "" : "s")", symbol: "arrow.left.arrow.right", selected: selected) {
                if module.arranging { ProgressView().controlSize(.small) }
            }
        }
    }

    private func submit(_ row: MenuBarRow) {
        switch row {
        case .toggle:
            module.toggle()
        case .revealAll:
            module.show(all: true, cause: .user)
        case .apply:
            Task { await module.applyRules() }
        case .item(let entry):
            Task { await module.open(entry) }
        }
    }

    private func keyPress(_ row: MenuBarRow, _ press: KeyPress) -> KeyPress.Result {
        guard case .item(let entry) = row, press.modifiers.contains(.option),
              press.key == .leftArrow || press.key == .rightArrow else { return .ignored }
        Task { await module.shift(entry, by: press.key == .rightArrow ? 1 : -1) }
        return .handled
    }

    @ViewBuilder private var notices: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !module.accessGranted {
                HStack {
                    Text("To list and arrange items, Cue needs Accessibility. Hiding and revealing work without it.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Grant Access") { module.requestAccess() }
                }
            } else {
                switch module.items {
                case .loading?:
                    ProgressView("Reading menu-bar items…").controlSize(.small)
                case .failed(let error)?:
                    ErrorBanner(error: error) { Task { await module.refreshItems() } }
                case .loaded(let entries)? where entries.isEmpty:
                    Text("No menu-bar items found. Apps that hide their own icons do not appear here.")
                        .font(.callout).foregroundStyle(.secondary)
                default:
                    EmptyView()
                }
            }
            if let status = module.status { StatusLine(text: status.text, success: status.success) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, module.accessGranted && module.status == nil ? 0 : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MenuBarSettingsView: View {
    let module: MenuBarModule
    @State private var rehideText = ""
    @State private var rehideError: String?
    @State private var newApp = ""
    @State private var appError: String?

    var body: some View {
        switch module.storage {
        case .loading:
            LoadingView()
        case .failed(let error):
            Form { ErrorBanner(error: error) { Task { await module.start() } } }.formStyle(.grouped)
        case .loaded:
            form
        }
    }

    private var form: some View {
        Form {
            Section {
                Toggle("Hide menu bar items", isOn: Binding(get: { module.settings.enabled }, set: { value in Task { await module.setEnabled(value) } }))
                    .accessibilityIdentifier("menuBar.enabled")
                Text("Hold ⌘ and drag icons to the left of the ‹ chevron to hide them. Click the chevron or press the shortcut to show them. ⌥-click the chevron to also show always-hidden icons.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Behavior") {
                LabeledContent("Hide again after") {
                    HStack {
                        TextField("Seconds", text: $rehideText).labelsHidden().frame(width: 60).multilineTextAlignment(.trailing)
                            .onSubmit(saveRehide)
                        Text("seconds")
                        Button("Save", action: saveRehide).disabled(rehideText == String(module.settings.autoRehideSeconds))
                    }
                }
                Text("0 keeps items shown until you hide them.").font(.caption).foregroundStyle(.secondary)
                if let rehideError { StatusLine(text: rehideError, success: false) }
                LabeledContent("Reveal shortcut") {
                    ShortcutRecorder(value: module.settings.shortcut.flatMap(Shortcut.init)) { value in
                        Task { await module.setShortcut(value) }
                    }
                }
                if let error = module.hotKeyError { StatusLine(text: error, success: false) }
            }
            Section("Keep hidden items shown while these apps are in front") {
                if module.settings.revealApps.isEmpty {
                    Text("No apps.").foregroundStyle(.secondary)
                }
                ForEach(module.settings.revealApps, id: \.self) { id in
                    HStack {
                        Text(Self.appName(id)).lineLimit(1)
                        Text(id).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button("Remove") { Task { await module.removeRevealApp(id) } }
                    }
                }
                HStack {
                    TextField("Bundle ID, for example com.apple.Safari", text: $newApp).onSubmit { add(newApp) }
                    Button("Add") { add(newApp) }.disabled(newApp.trimmingCharacters(in: .whitespaces).isEmpty)
                    Menu("Running App") {
                        ForEach(Self.runningApps, id: \.id) { app in
                            Button(app.name) { add(app.id) }
                        }
                    }
                    .fixedSize()
                }
                if let appError { StatusLine(text: appError, success: false) }
            }
            Section("Rules") {
                if module.rules.isEmpty {
                    Text("No rules yet. In the command window, select an item and press ⌥← or ⌥→ to choose its section.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(module.rules) { rule in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.label).lineLimit(1)
                            Text(rule.bundleID).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Picker("Section", selection: Binding(get: { rule.section }, set: { section in
                            var changed = rule
                            changed.section = section
                            Task { await module.setRule(changed) }
                        })) {
                            ForEach(MenuBarSection.allCases.reversed(), id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button {
                            Task { await module.deleteRule(rule.key) }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Delete rule")
                        .accessibilityLabel("Delete rule")
                    }
                }
                HStack {
                    Button("Apply Rules Now") { Task { await module.applyRules() } }
                        .disabled(!module.settings.enabled || module.rules.isEmpty || module.arranging)
                    if module.arranging { ProgressView().controlSize(.small) }
                }
                if !module.settings.enabled {
                    Text("Turn on menu bar hiding to apply rules.").font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Accessibility") {
                    if module.accessGranted {
                        Text("Allowed")
                    } else {
                        Button("Grant Access") { module.requestAccess() }
                    }
                }
                Text("Cue needs Accessibility to list items and move them with a simulated ⌘-drag. It reads only item positions and names, and stores names only on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Import and export") {
                HStack {
                    Button("Export Rules…") { module.exportRules() }
                    Button("Import Rules…") { Task { await module.importRules() } }
                }
                Text("Exports rules and settings as JSON. Importing merges rules by item and never turns menu bar hiding on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let status = module.status {
                Section { StatusLine(text: status.text, success: status.success) }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            module.refreshAccess()
            rehideText = String(module.settings.autoRehideSeconds)
        }
        .onChange(of: module.settings.autoRehideSeconds) { _, value in rehideText = String(value) }
    }

    private func saveRehide() {
        Task {
            do {
                try await module.setAutoRehide(rehideText)
                rehideError = nil
            } catch {
                rehideError = error.cueError.message
            }
        }
    }

    private func add(_ text: String) {
        Task {
            do {
                try await module.addRevealApp(text)
                newApp = ""
                appError = nil
            } catch {
                appError = error.cueError.message
            }
        }
    }

    private static func appName(_ bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID
    }

    private static var runningApps: [(id: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
