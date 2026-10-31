import AppKit
import CueKit
import SwiftUI

private struct MenuBarEntry: Identifiable {
    var item: ScannedItem
    var header: String?
    var id: String { item.id }
}

private let sections: [MenuBarSection] = [.visible, .hidden, .alwaysHidden]

private func sectionOptions(_ movable: Bool) -> [Segmented<MenuBarSection>.Option] {
    sections.map { .init(value: $0, title: $0.title, enabled: movable) }
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
                    CommandList(query: $query, placeholder: "Search menu bar items", items: entries, selection: $selection,
                                header: { $0.header },
                                row: { entry, selected in row(entry.item, selected) },
                                bar: { toolbar },
                                detail: { EmptyView() },
                                onSubmit: { entry, _ in Task { await module.open(entry.item) } },
                                onKeyPress: keyPress)
                    notices
                    footer
                }
                .background { shortcuts }
            }
        }
        .task { await module.refreshItems() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if (note.object as? NSWindow)?.accessibilityIdentifier() == "command.window" {
                Task { await module.refreshItems() }
            }
        }
    }

    private var all: [ScannedItem] {
        if case .loaded(let items) = module.items { items } else { [] }
    }

    private var filtered: [ScannedItem] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return all }
        return all.filter { $0.item.appName.localizedCaseInsensitiveContains(text) || $0.item.label.localizedCaseInsensitiveContains(text) }
    }

    private var entries: [MenuBarEntry] {
        sections.flatMap { section -> [MenuBarEntry] in
            let items = filtered.filter { $0.section == section }
            return items.enumerated().map { MenuBarEntry(item: $0.element, header: $0.offset == 0 ? "\(section.title)  \(items.count)" : nil) }
        }
    }

    private var current: ScannedItem? { filtered.first { $0.id == selection } }

    private var toolbar: some View {
        HStack(spacing: 8) {
            barButton(module.isRevealed ? "Hide Items" : "Show Hidden", symbol: module.isRevealed ? "eye.slash" : "eye", keys: "⌘H", action: module.toggle)
            barButton("Show All", keys: "⌘⇧H") { module.show(all: true, cause: .user) }
            Spacer()
            Button { Task { await module.applyRules() } } label: {
                HStack(spacing: 6) {
                    if module.arranging { ProgressView().controlSize(.mini) }
                    Text("Apply Rules")
                    Text("\(module.rules.count)").foregroundStyle(.tertiary)
                }
                .font(.system(size: 12.5))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(module.rules.isEmpty || module.arranging)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private func barButton(_ title: String, symbol: String? = nil, keys: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let symbol { Image(systemName: symbol).font(.system(size: 12)) }
                Text(title).font(.system(size: 12.5, weight: .medium))
                Key(text: keys)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.12)) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(_ entry: ScannedItem, _ selected: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                if let icon = MenuBarModule.icon(entry) {
                    Image(nsImage: icon).resizable().padding(3)
                } else {
                    Image(systemName: "app").font(.system(size: 11))
                }
            }
            .frame(width: 22, height: 22)
            .background(Cue.fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(entry.item.label).font(.system(size: 13.5, weight: selected ? .semibold : .medium)).lineLimit(1)
                .frame(width: 202, alignment: .leading)
            Text(entry.item.appName).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            if selected {
                if entry.item.movable {
                    Segmented(options: sectionOptions(true), selection: entry.section, height: 22) { target in
                        Task { await module.move(entry, to: target) }
                    }
                    .disabled(module.arranging)
                } else {
                    Text("Fixed by macOS").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 33)
        .background(selected ? Cue.selection : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var footer: some View {
        CommandFooter {
            let hidden = all.filter { $0.section != .visible }.count
            Text("\(all.count) items · \(hidden) hidden")
        } trailing: {
            KeyHint(label: "Click item", keys: "↵", primary: true)
            KeyHint(label: "Change state", keys: "← →")
            if let current { ActionsHint(target: current.id) { showMenu(current) } }
        }
    }

    private var shortcuts: some View {
        ZStack {
            Button("Show Hidden", action: module.toggle).keyboardShortcut("h", modifiers: .command)
            Button("Show All") { module.show(all: true, cause: .user) }.keyboardShortcut("h", modifiers: [.command, .shift])
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func showMenu(_ entry: ScannedItem) {
        PanelMenu.show { menu in
            menu.add("Click Item") { Task { await module.open(entry) } }
            if entry.item.movable {
                menu.addItem(.separator())
                for section in sections where section != entry.section {
                    menu.add("Move to \(section.title)") { Task { await module.move(entry, to: section) } }
                }
            }
            menu.addItem(.separator())
            menu.add("Show Hidden", key: "h") { module.toggle() }
            menu.add("Show All", key: "H") { module.show(all: true, cause: .user) }
            menu.add("Apply Rules Now") { Task { await module.applyRules() } }
            menu.add("Settings…", key: ",") { module.openSettings() }
        }
    }

    private func keyPress(_ entry: MenuBarEntry?, _ press: KeyPress) -> KeyPress.Result {
        guard let entry, press.key == .leftArrow || press.key == .rightArrow,
              query.isEmpty || press.modifiers.contains(.option) else { return .ignored }
        Task { await module.shift(entry.item, by: press.key == .rightArrow ? 1 : -1) }
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
    private enum RuleRow: Hashable {
        case item(String)
        case app(String)
    }

    let module: MenuBarModule
    @State private var selectedRule: RuleRow?
    @State private var failure: String?

    private static let rehideChoices = [5, 10, 30, 60, 0]

    var body: some View {
        switch module.storage {
        case .loading:
            LoadingView()
        case .failed(let error):
            SettingsPage { ErrorBanner(error: error) { Task { await module.start() } } }
        case .loaded:
            page
        }
    }

    private var page: some View {
        SettingsPage {
            SettingsSection {
                SettingsRow("Hide menu bar items", weight: .medium) {
                    SwitchToggle(isOn: Binding(get: { module.settings.enabled }, set: { value in Task { await module.setEnabled(value) } }), label: "Hide menu bar items")
                        .accessibilityIdentifier("menuBar.enabled")
                }
                CardDivider()
                SettingsRow("Hide again after") {
                    Picker("", selection: Binding(get: { module.settings.autoRehideSeconds }, set: { saveRehide($0) })) {
                        ForEach(rehideOptions, id: \.self) { Text($0 == 0 ? "Never" : "\($0) seconds").tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            SettingsNote(text: "Click the chevron or press the shortcut to show hidden icons. ⌥-click it to also show always-hidden icons. Right-click it to pick a hidden icon from a list.")
            SettingsSection("Layout") { layout }
            SettingsSection("Rules", trailing: {
                Button("Apply Now") { Task { await module.applyRules() } }
                    .disabled(!module.settings.enabled || module.rules.isEmpty || module.arranging)
            }) { rules }
            SettingsSection("Rules file") {
                SettingsRow("Rules and settings", note: "Importing never turns hiding on.") {
                    Button("Import…") { Task { await module.importRules() } }
                    Button("Export…") { module.exportRules() }
                }
            }
            if let failure { StatusLine(text: failure, success: false) }
            if let status = module.status { StatusLine(text: status.text, success: status.success) }
        }
        .onAppear(perform: module.refreshAccess)
        .task { await module.refreshItems() }
    }

    private var rehideOptions: [Int] {
        Self.rehideChoices.contains(module.settings.autoRehideSeconds) ? Self.rehideChoices : [module.settings.autoRehideSeconds] + Self.rehideChoices
    }

    private func entries(_ section: MenuBarSection) -> [ScannedItem] {
        if case .loaded(let items) = module.items { items.filter { $0.section == section } } else { [] }
    }

    @ViewBuilder private var layout: some View {
        if !module.settings.enabled {
            SettingsRow("Turn on menu bar hiding to arrange items.")
        } else if !module.accessGranted {
            SettingsRow("Cue needs Accessibility to list and move items.") { Button("Grant Access") { module.requestAccess() } }
        } else {
            ForEach(Array(sections.enumerated()), id: \.element) { index, section in
                if index > 0 { CardDivider() }
                HStack(alignment: .top, spacing: 0) {
                    Text(section.title).fontWeight(.medium).frame(width: 112, alignment: .leading).padding(.top, 5)
                    FlowLayout {
                        ForEach(entries(section)) { entry in
                            chip(entry)
                        }
                        if entries(section).isEmpty { Text("Drop items here").foregroundStyle(.tertiary).frame(height: 28) }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { keys, _ in
                    guard let key = keys.first, case .loaded(let items) = module.items,
                          let entry = items.first(where: { $0.id == key }) else { return false }
                    Task { await module.move(entry, to: section) }
                    return true
                }
            }
        }
    }

    private func chip(_ entry: ScannedItem) -> some View {
        HStack(spacing: 6) {
            if let icon = MenuBarModule.icon(entry) { Image(nsImage: icon).resizable().frame(width: 13, height: 13) }
            Text(entry.item.label).font(.system(size: 12.5)).lineLimit(1)
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Cue.fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Cue.hairline) }
        .opacity(entry.item.movable ? 1 : 0.6)
        .draggable(entry.id)
        .help(entry.item.movable ? entry.item.appName : "Fixed by macOS")
    }

    @ViewBuilder private var rules: some View {
        HStack(spacing: 0) {
            ruleColumns(Text("When"), Text("Item"), Text("Set to"))
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 30)
        CardDivider()
        if module.rules.isEmpty && module.settings.revealApps.isEmpty {
            Text("No rules").foregroundStyle(.secondary).frame(maxWidth: .infinity).frame(height: 56)
            CardDivider()
        }
        ForEach(module.rules) { rule in
            ruleRow(.item(rule.key)) {
                ruleColumns(Text("Always"), Text(rule.label).lineLimit(1), sectionPicker(rule))
            }
        }
        ForEach(module.settings.revealApps, id: \.self) { id in
            ruleRow(.app(id)) {
                ruleColumns(Text("\(Self.appName(id)) in front").lineLimit(1), Text("Hidden items"), Text("Shown"))
            }
        }
        PlusMinusBar(removeEnabled: selectedRule != nil, remove: removeRule) {
            Menu {
                Menu("Item") {
                    if case .loaded(let items) = module.items {
                        ForEach(items.filter(\.item.movable)) { entry in
                            Button(entry.item.label) { addRule(entry) }
                        }
                    }
                }
                Menu("Show Hidden Items While App Is in Front") {
                    ForEach(Self.runningApps, id: \.id) { app in
                        Button(app.name) { addApp(app.id) }
                    }
                }
            } label: { Image(systemName: "plus") }
        }
    }

    private func ruleColumns<A: View, B: View, C: View>(_ when: A, _ item: B, _ target: C) -> some View {
        HStack(spacing: 0) {
            when.frame(width: 200, alignment: .leading)
            item.frame(width: 200, alignment: .leading)
            target.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func ruleRow<Content: View>(_ id: RuleRow, @ViewBuilder content: () -> Content) -> some View {
        let content = content()
        return Button { selectedRule = id } label: {
            content
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(selectedRule == id ? Cue.selection : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { CardDivider() }
    }

    private func sectionPicker(_ rule: MenuBarRule) -> some View {
        Picker("Set to", selection: Binding(get: { rule.section }, set: { section in
            var changed = rule
            changed.section = section
            Task { await module.setRule(changed) }
        })) {
            ForEach(sections, id: \.self) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        .controlSize(.small)
    }

    private func removeRule() {
        switch selectedRule {
        case .item(let key): Task { await module.deleteRule(key) }
        case .app(let id): Task { await module.removeRevealApp(id) }
        case nil: break
        }
        selectedRule = nil
    }

    private func addRule(_ entry: ScannedItem) {
        let item = entry.item
        let label = item.label == item.appName ? item.appName : "\(item.appName) — \(item.label)"
        Task { await module.setRule(MenuBarRule(key: item.key, bundleID: item.bundleID, label: label, section: entry.section)) }
    }

    private func addApp(_ id: String) {
        Task {
            do {
                try await module.addRevealApp(id)
                failure = nil
            } catch {
                failure = error.cueError.message
            }
        }
    }

    private func saveRehide(_ seconds: Int) {
        Task {
            do {
                try await module.setAutoRehide(String(seconds))
                failure = nil
            } catch {
                failure = error.cueError.message
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
