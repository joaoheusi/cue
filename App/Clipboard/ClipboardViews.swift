import AppKit
import CueKit
import SwiftUI
import UniformTypeIdentifiers

private enum ClipFilter: String, CaseIterable {
    case all, pinned, text, links, code, images, files

    var title: String { rawValue.capitalized }

    func matches(_ item: ClipItem) -> Bool {
        switch self {
        case .all: true
        case .pinned: item.isPinned
        case .text: item.kind == .text
        case .links: item.kind == .link
        case .code: item.kind == .code
        case .images: item.kind == .image
        case .files: item.kind == .file
        }
    }
}

private struct ClipResultsKey: Equatable {
    var revision: Int
    var query: String
    var filter: ClipFilter
    var app: String?
    var pinboard: String?
}

@MainActor private final class ClipResults {
    private var key: ClipResultsKey?
    private var items: [ClipItem] = []

    func value(for key: ClipResultsKey, compute: () -> [ClipItem]) -> [ClipItem] {
        if key != self.key {
            self.key = key
            items = compute()
        }
        return items
    }
}

private struct ClipEntry: Identifiable {
    var item: ClipItem
    var header: String?
    var id: String { item.id }
}

struct ClipboardCommandView: View {
    let module: ClipboardModule
    @State private var query = ""
    @State private var selection: String?
    @State private var filter = ClipFilter.all
    @State private var app: String?
    @State private var pinboard: String?
    @State private var memo = ClipResults()

    private var results: [ClipItem] {
        let board = filter == .pinned && module.pinboards.contains { $0.id == pinboard } ? pinboard : nil
        return memo.value(for: ClipResultsKey(revision: module.itemsRevision, query: query, filter: filter, app: app, pinboard: board)) {
            ClipboardSearch.filter(module.items, query: query, pinboard: board).filter { filter.matches($0) && (app == nil || $0.source == app) }
        }
    }

    private var entries: [ClipEntry] {
        let items = results
        guard query.trimmingCharacters(in: .whitespaces).isEmpty else { return items.map { ClipEntry(item: $0) } }
        let pinned = items.filter(\.isPinned)
        let calendar = Calendar.current
        func title(_ item: ClipItem) -> String {
            if calendar.isDateInToday(item.lastUsedAt) { return "Today" }
            return calendar.isDateInYesterday(item.lastUsedAt) ? "Yesterday" : "Earlier"
        }
        var output: [ClipEntry] = pinned.enumerated().map { ClipEntry(item: $0.element, header: $0.offset == 0 ? "Pinned" : nil) }
        var last: String?
        for item in items where !item.isPinned {
            let heading = title(item)
            output.append(ClipEntry(item: item, header: heading == last ? nil : heading))
            last = heading
        }
        return output
    }

    private var current: ClipItem? { results.first { $0.id == selection } }

    private var sources: [String] {
        Array(Set(module.items.compactMap(\.source))).sorted { module.appName($0).localizedStandardCompare(module.appName($1)) == .orderedAscending }
    }

    var body: some View {
        content.onAppear {
            module.commandStatus = nil
            module.recheckAccess()
        }
    }

    @ViewBuilder private var content: some View {
        switch module.phase {
        case .loading:
            LoadingView()
        case .failed(let error) where error == ClipboardStore.keyUnavailable:
            VStack(spacing: 0) {
                EmptyStateView(symbol: "key.slash", title: "Clipboard history is locked", message: error.message,
                               actionTitle: "Try Again", action: module.retry)
                Button("Reset History…", role: .destructive, action: module.resetHistory)
                    .accessibilityIdentifier("clipboard.reset")
                    .padding(.bottom, 24)
            }
        case .failed(let error):
            EmptyStateView(symbol: "exclamationmark.triangle", title: "Clipboard history is unavailable", message: error.message,
                           actionTitle: "Try Again", action: module.retry)
        case .ready where !module.captureEnabled && module.items.isEmpty:
            EmptyStateView(symbol: "clipboard", title: "Clipboard history is off",
                           message: "Turn it on to save the text, images, and files you copy and paste them again later. History is encrypted and stays on this Mac.",
                           actionTitle: "Turn On Clipboard History") { module.setCaptureEnabled(true) }
                .accessibilityIdentifier("clipboard.turnOn")
        case .ready:
            list
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            CommandList(query: $query, placeholder: "Search clipboard", items: entries, selection: $selection,
                        header: { $0.header }, showsDetail: current != nil,
                        row: { entry, selected in row(entry.item, selected) },
                        bar: { bar },
                        detail: { if let current { ClipDetail(item: current, module: module) } },
                        onSubmit: { entry, alternate in Task { await module.use(entry.item, paste: !alternate) } })
                .overlay { emptyMessage.padding(.top, 96) }
            if module.accessDenied && module.captureEnabled {
                ErrorBanner(error: ClipboardModule.accessDeniedError, retryTitle: "Open Settings", retry: module.openPasteSettings)
                    .padding(.horizontal, 12).padding(.vertical, 6)
            }
            if let error = module.readerError {
                ErrorBanner(error: error).padding(.horizontal, 12).padding(.vertical, 6)
            }
            if let status = module.commandStatus {
                StatusLine(text: status.text, success: status.success)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 6)
            }
            footer
        }
        .background { shortcuts }
    }

    private var bar: some View {
        HStack(spacing: 6) {
            ForEach(ClipFilter.allCases, id: \.self) { option in
                FilterChip(title: option.title, selected: filter == option) { filter = option }
            }
            if filter == .pinned, module.pinboards.count > 1 {
                Picker("Pinboard", selection: $pinboard) {
                    Text("All pinboards").tag(String?.none)
                    ForEach(module.pinboards) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                .accessibilityIdentifier("clipboard.pinboard")
            }
            Spacer()
            Menu(app.map(module.appName) ?? "Any app") {
                Button("Any app") { app = nil }
                ForEach(sources, id: \.self) { id in
                    Button(module.appName(id)) { app = id }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.system(size: 12))
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var emptyMessage: some View {
        if results.isEmpty {
            if !query.trimmingCharacters(in: .whitespaces).isEmpty || app != nil || (filter != .all && filter != .pinned) {
                EmptyStateView(symbol: "magnifyingglass", title: "No matches", message: "Try different words, or choose All and Any app.")
            } else if filter == .pinned {
                EmptyStateView(symbol: "pin", title: "Nothing pinned yet", message: "Select an item and press ⌘P to pin it.")
            } else {
                EmptyStateView(symbol: "clipboard", title: "Nothing copied yet",
                               message: module.captureEnabled ? "Copy text, an image, or a file in any app. It appears here." : "Clipboard history is off. Turn it on in Settings → Clipboard.")
            }
        }
    }

    private func symbol(_ item: ClipItem) -> (String, Color) {
        if item.sensitive { return ("lock", Cue.warning) }
        if item.isPinned { return ("pin", Cue.claudeAccent) }
        switch item.kind {
        case .link: return ("link", Cue.link)
        case .code: return ("chevron.left.forwardslash.chevron.right", .secondary)
        case .text: return ("text.alignleft", .secondary)
        case .image: return ("photo", .secondary)
        case .file: return ("doc", .secondary)
        }
    }

    @ViewBuilder private func meta(_ item: ClipItem) -> some View {
        if let expires = item.expiresAt {
            TimelineView(.periodic(from: .now, by: 15)) { _ in
                Text("Deletes in \(ShortAge.until(expires))").foregroundStyle(Cue.warning)
            }
        } else if item.isPinned {
            Text(item.source.map(module.appName) ?? "")
        } else {
            Text(([item.source.map(module.appName), ShortAge.text(item.lastUsedAt)] as [String?]).compactMap { $0 }.joined(separator: " · "))
        }
    }

    @ViewBuilder private func leading(_ item: ClipItem) -> some View {
        let (name, color) = symbol(item)
        let icon = Image(systemName: name).font(.system(size: 13)).foregroundStyle(color)
        switch item.content {
        case .image: ClipThumbnail(item: item, module: module, placeholder: icon)
        case .files(let paths): ClipFileIcon(path: paths.first ?? "")
        case .plain, .rich: icon
        }
    }

    private func row(_ item: ClipItem, _ selected: Bool) -> some View {
        CommandRow(title: item.preview, selected: selected, monospaced: item.sensitive, match: query.trimmingCharacters(in: .whitespacesAndNewlines)) {
            leading(item).frame(width: 16)
        } accessory: {
            meta(item)
        }
        .background(item.sensitive && !selected ? Cue.warningFill : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contextMenu {
            Button("Paste") { Task { await module.use(item, paste: true) } }
            Button("Copy") { Task { await module.use(item, paste: false) } }
            if item.content == .rich { Button("Paste as Text") { Task { await module.use(item, paste: true, plain: true) } } }
            if item.linkURL != nil { Button("Go to Link") { module.goToLink(item) } }
            Menu("Pin To") {
                ForEach(module.pinboards) { board in
                    Button(board.name) { Task { await module.pin(item, to: board.id) } }.disabled(board.id == item.pinboardID)
                }
            }
            if item.isPinned { Button("Unpin") { Task { await module.pin(item, to: nil) } } }
            Divider()
            Button("Delete", role: .destructive) { Task { await module.delete(item) } }
        }
    }

    private var pasteLabel: String {
        module.frontName.map { "Paste into \($0)" } ?? "Paste"
    }

    private var footer: some View {
        CommandFooter {
            Text("\(module.items.count) items")
        } trailing: {
            KeyHint(label: pasteLabel, keys: "↵", primary: true)
            KeyHint(label: "Copy", keys: "⌘↵")
            KeyHint(label: current?.isPinned == true ? "Unpin" : "Pin", keys: "⌘P")
            KeyHint(label: "Delete", keys: "⌘⌫")
            if let current { ActionsHint(target: current.id) { showMenu(current) } }
        }
    }

    private var shortcuts: some View {
        ZStack {
            Button("Pin") { if let current { Task { await module.togglePin(current) } } }
                .keyboardShortcut("p", modifiers: .command)
            Button("Delete") { if let current { Task { await module.delete(current) } } }
                .keyboardShortcut(.delete, modifiers: .command)
            Button("Go to Link") { if let current { module.goToLink(current) } }
                .keyboardShortcut("o", modifiers: .command)
            Button("Paste as Text") { if let current, current.content.isText { Task { await module.use(current, paste: true, plain: true) } } }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            Button("Previous Pinboard") { cyclePinboard(-1) }.keyboardShortcut("[", modifiers: .command)
            Button("Next Pinboard") { cyclePinboard(1) }.keyboardShortcut("]", modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func showMenu(_ item: ClipItem) {
        PanelMenu.show { menu in
            menu.add(pasteLabel) { Task { await module.use(item, paste: true) } }
            menu.add("Copy") { Task { await module.use(item, paste: false) } }
            if item.content == .rich { menu.add("Paste as Text", key: "V") { Task { await module.use(item, paste: true, plain: true) } } }
            if item.linkURL != nil { menu.add("Go to Link", key: "o") { module.goToLink(item) } }
            menu.addItem(.separator())
            for board in module.pinboards where board.id != item.pinboardID {
                menu.add("Pin to \(board.name)") { Task { await module.pin(item, to: board.id) } }
            }
            if item.isPinned { menu.add("Unpin") { Task { await module.pin(item, to: nil) } } }
            menu.addItem(.separator())
            menu.add("Delete") { Task { await module.delete(item) } }
            let recent = NSMenu()
            for range in RecentRange.allCases {
                recent.add(range.title) { module.deleteRecent(range, from: .command) }
            }
            let delete = NSMenuItem(title: "Delete Recent", action: nil, keyEquivalent: "")
            delete.submenu = recent
            menu.addItem(delete)
            menu.add("Settings…") { module.openSettings() }
        }
    }

    private func cyclePinboard(_ delta: Int) {
        let options: [String?] = [nil] + module.pinboards.map(\.id)
        let index = options.firstIndex(of: pinboard) ?? 0
        filter = .pinned
        pinboard = options[(index + delta + options.count) % options.count]
    }
}

private struct ClipThumbnail<Placeholder: View>: View {
    let item: ClipItem
    let module: ClipboardModule
    let placeholder: Placeholder
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            } else {
                placeholder
            }
        }
        .task(id: item.id) { image = await module.thumbnail(of: item) }
    }
}

private struct ClipFileIcon: View {
    let path: String
    var size: CGFloat = 20

    var body: some View {
        let type = path.hasSuffix("/") ? UTType.folder : UTType(filenameExtension: (path as NSString).pathExtension) ?? .data
        Image(nsImage: NSWorkspace.shared.icon(for: type)).resizable().frame(width: size, height: size)
    }
}

private struct ClipDetail: View {
    let item: ClipItem
    let module: ClipboardModule
    @State private var files: ClipFileCheck?

    private var rows: [(String, String)] {
        var rows = [
            ("Source", item.source.map(module.appName) ?? "Unknown"),
            ("Copied", ShortAge.stamp(item.createdAt)),
            ("Content", item.summary),
        ]
        if item.content == .rich { rows.append(("Format", "Rich text")) }
        if let status = files?.error?.message ?? files?.warning { rows.append(("Status", status)) }
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            card
                .background(Cue.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Cue.hairline) }
            DetailRows(rows: rows)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .task(id: item.id) {
            files = nil
            guard case .files(let paths) = item.content else { return }
            let check = await module.checkFiles(paths)
            if !Task.isCancelled { files = check }
        }
    }

    @ViewBuilder private var card: some View {
        switch item.content {
        case .image:
            ClipImagePreview(item: item, module: module)
        case .files(let paths):
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(paths, id: \.self) { path in
                        HStack(spacing: 8) {
                            ClipFileIcon(path: path)
                            Text((path as NSString).abbreviatingWithTildeInPath)
                                .font(.system(size: 12.5))
                                .foregroundStyle(files?.missing.contains(path) == true ? Cue.warning : Cue.ink)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        case .plain, .rich:
            ScrollView {
                Text(item.display)
                    .font(item.sensitive ? .system(size: 12.5, design: .monospaced) : .system(size: 13.5))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            }
        }
    }
}

private struct ClipImagePreview: View {
    let item: ClipItem
    let module: ClipboardModule
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                    .padding(10)
            } else if failed {
                Text(ClipboardStore.dataMissing.message).font(.system(size: 12.5)).foregroundStyle(Cue.warning).multilineTextAlignment(.center).padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item.id) {
            image = nil
            failed = false
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let loaded = await module.preview(of: item, maxPixelSize: 1024)
            guard !Task.isCancelled else { return }
            image = loaded
            failed = loaded == nil
        }
    }
}

struct ClipboardSettingsView: View {
    let module: ClipboardModule
    @State private var selectedApp: String?
    @State private var newPinboard = ""

    var body: some View {
        SettingsPage {
            SettingsSection("History") {
                SettingsRow("Save clipboard history", weight: .medium) {
                    SwitchToggle(isOn: Binding(get: { module.captureEnabled }, set: { module.setCaptureEnabled($0) }), label: "Save clipboard history")
                        .accessibilityIdentifier("clipboard.capture")
                }
                CardDivider()
                SettingsRow("Keep unpinned items for") {
                    picker(\.retention, Retention.allCases) { $0.title }
                }
                CardDivider()
                SettingsRow("Keep at most") {
                    picker(\.maxItems, ClipboardSettings.maxItemChoices) { "\($0) items" }
                }
                CardDivider()
                SettingsRow("Storage limit", note: "Pinned items do not count toward this limit.") {
                    picker(\.maxStorage, ClipboardSettings.maxStorageChoices) { ClipboardSettings.storageTitle($0) }
                }
                CardDivider()
                SettingsRow("Stored", note: stored) {
                    Menu("Delete Recent") {
                        ForEach(RecentRange.allCases, id: \.self) { range in
                            Button(range.title) { module.deleteRecent(range, from: .settings) }
                        }
                    }
                    .fixedSize()
                    Button("Clear History…", role: .destructive, action: module.clearHistory).foregroundStyle(Cue.danger)
                }
                CardDivider()
                SettingsRow("Clear history on quit", note: "Deletes unpinned items. Pinned items stay.") {
                    toggle(\.clearOnQuit, "Clear history on quit")
                }
                CardDivider()
                SettingsRow("Also clear the system clipboard", note: "With Clear History, Delete Recent, and clear on quit.") {
                    toggle(\.clearSystemClipboard, "Also clear the system clipboard")
                }
            }
            problems
            SettingsSection("Sensitive content") {
                SettingsRow("API keys and tokens") {
                    picker(\.sensitive, SensitiveHandling.allCases) { $0.title }
                }
                CardDivider()
                SettingsRow("Passwords, concealed and transient items") { Text("Never saved").foregroundStyle(.secondary) }
                CardDivider()
                SettingsRow("Secure text fields") { Text("Never saved").foregroundStyle(.secondary) }
            }
            SettingsSection("Ignore while in front") {
                ForEach(module.settings.excludedApps, id: \.self) { id in
                    Button { selectedApp = id } label: {
                        HStack(spacing: 10) {
                            appIcon(id)
                            Text(module.appName(id))
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background(selectedApp == id ? Cue.selection : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    CardDivider()
                }
                PlusMinusBar(removeEnabled: selectedApp != nil, remove: {
                    if let selectedApp { module.removeExcludedApp(selectedApp) }
                    selectedApp = nil
                }) {
                    Menu {
                        ForEach(runningApps, id: \.0) { id, name in
                            Button(name) { _ = module.addExcludedApp(id) }
                        }
                        Divider()
                        Button("Choose App…", action: chooseApp)
                    } label: { Image(systemName: "plus") }
                }
            }
            SettingsSection("Pinboards") {
                ForEach(module.pinboards) { board in
                    PinboardRow(board: board, module: module)
                    CardDivider()
                }
                HStack {
                    TextField("New pinboard", text: $newPinboard).textFieldStyle(.plain).onSubmit(addPinboard)
                    Button("Add", action: addPinboard).disabled(newPinboard.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
            }
            SettingsSection("Data") {
                SettingsRow("History file", note: "Unencrypted JSON with text only. Import replaces history.") {
                    Button("Import…", action: module.importHistory)
                    Button("Export…", action: module.exportHistory)
                }
            }
            if let status = module.settingsStatus { StatusLine(text: status.text, success: status.success) }
        }
        .disabled(module.phase == .loading)
    }

    private var stored: String {
        let pinned = module.items.filter(\.isPinned).count
        let bytes = module.items.reduce(0) { $0 + $1.byteSize }
        return "\(module.items.count) items · \(pinned) pinned · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) · encrypted"
    }

    @ViewBuilder private var problems: some View {
        switch module.phase {
        case .failed(let error) where error == ClipboardStore.keyUnavailable:
            ErrorBanner(error: error, retryTitle: "Try Again", retry: module.retry)
            Button("Reset History…", role: .destructive, action: module.resetHistory)
        case .failed(let error):
            ErrorBanner(error: error, retryTitle: "Try Again", retry: module.retry)
        default:
            EmptyView()
        }
        if module.accessDenied && module.captureEnabled {
            ErrorBanner(error: ClipboardModule.accessDeniedError, retryTitle: "Open Paste Settings", retry: module.openPasteSettings)
        }
        if let error = module.readerError { ErrorBanner(error: error) }
    }

    private func picker<Value: Hashable>(_ path: WritableKeyPath<ClipboardSettings, Value>, _ options: [Value], title: @escaping (Value) -> String) -> some View {
        Picker("", selection: Binding(get: { module.settings[keyPath: path] }, set: { value in module.update { $0[keyPath: path] = value } })) {
            ForEach(options, id: \.self) { Text(title($0)).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }

    private func toggle(_ path: WritableKeyPath<ClipboardSettings, Bool>, _ label: String) -> some View {
        SwitchToggle(isOn: Binding(get: { module.settings[keyPath: path] }, set: { value in module.update { $0[keyPath: path] = value } }), label: label)
    }

    @ViewBuilder private func appIcon(_ id: String) -> some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            FileIcon(path: url.path, size: 20)
        } else {
            Tile(symbol: "app", color: Cue.text, size: 20)
        }
    }

    private var runningApps: [(String, String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
            .filter { id, _ in !module.settings.excludedApps.contains { $0.caseInsensitiveCompare(id) == .orderedSame } }
            .sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        NSApp.takeFocus()
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        _ = module.addExcludedApp(id)
    }

    private func addPinboard() {
        let name = newPinboard
        Task { if await module.createPinboard(name) { newPinboard = "" } }
    }
}

private struct PinboardRow: View {
    let board: Pinboard
    let module: ClipboardModule
    @State private var name = ""

    var body: some View {
        HStack {
            TextField("Pinboard name", text: $name)
                .textFieldStyle(.plain)
                .labelsHidden()
                .onSubmit {
                    Task { if !(await module.renamePinboard(board, to: name)) { name = board.name } }
                }
            Button("Delete Pinboard", systemImage: "trash") { module.deletePinboard(board) }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .help("Delete pinboard")
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .onAppear { name = board.name }
        .onChange(of: board.name) { _, new in name = new }
    }
}
