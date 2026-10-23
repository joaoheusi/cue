import AppKit
import CueKit
import SwiftUI

/// The Clipboard scope of the command window. ↩ pastes, ⇧↩ copies, ⌘P pins, ⌘⌫ deletes, ⌘[ and ⌘] switch pinboards.
struct ClipboardCommandView: View {
    let module: ClipboardModule
    @State private var query = ""
    @State private var selection: String?
    /// Nil shows all items.
    @State private var pinboard: String?

    private var results: [ClipItem] {
        ClipboardSearch.filter(module.items, query: query, pinboard: module.pinboards.contains { $0.id == pinboard } ? pinboard : nil)
    }

    private var current: ClipItem? { results.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            if module.accessDenied && module.captureEnabled {
                ErrorBanner(error: ClipboardModule.accessDeniedError, retryTitle: "Open Settings", retry: module.openPasteSettings)
                .padding(.horizontal, 12).padding(.bottom, 6)
            }
            content
        }
        .onAppear {
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
            EmptyStateView(symbol: "doc.on.clipboard", title: "Clipboard history is off",
                           message: "Turn it on to save text you copy and paste it again later. History is encrypted and stays on this Mac.",
                           actionTitle: "Turn On Clipboard History") { module.setCaptureEnabled(true) }
                .accessibilityIdentifier("clipboard.turnOn")
        case .ready:
            list
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            CommandList(query: $query, placeholder: "Search clipboard history", items: results, selection: $selection,
                        row: row, onSubmit: { item, alternate in Task { await module.use(item, paste: !alternate) } })
                .overlay { emptyMessage.padding(.top, 48) }
            if let status = module.commandStatus {
                StatusLine(text: status.text, success: status.success)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 6)
            }
            Divider()
            footer
        }
    }

    @ViewBuilder private var emptyMessage: some View {
        if results.isEmpty {
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                EmptyStateView(symbol: "magnifyingglass", title: "No matches", message: "Try different words, or choose All pinboards.")
            } else if pinboard != nil {
                EmptyStateView(symbol: "pin", title: "This pinboard is empty", message: "Select an item and press ⌘P to pin it.")
            } else {
                EmptyStateView(symbol: "doc.on.clipboard", title: "Nothing copied yet",
                               message: module.captureEnabled ? "Copy text in any app. It appears here." : "Clipboard history is off. Turn it on in Settings → Clipboard.")
            }
        }
    }

    private func row(_ item: ClipItem, _ selected: Bool) -> some View {
        let board = module.pinboards.first { $0.id == item.pinboardID }
        let when = item.lastUsedAt.formatted(.relative(presentation: .named))
        return CommandRow(title: item.preview, subtitle: item.source.map { "\(when) · \(module.appName($0))" } ?? when,
                          symbol: board == nil ? "doc.on.clipboard" : "pin.fill", selected: selected) {
            if let board { Text(board.name).font(.caption).lineLimit(1) }
        }
        .contextMenu {
            Button("Paste") { Task { await module.use(item, paste: true) } }
            Button("Copy") { Task { await module.use(item, paste: false) } }
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

    private var footer: some View {
        HStack(spacing: 8) {
            Picker("Pinboard", selection: $pinboard) {
                Text("All").tag(String?.none)
                ForEach(module.pinboards) { Text($0.name).tag(Optional($0.id)) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Show one pinboard (⌘[ and ⌘])")
            .accessibilityIdentifier("clipboard.pinboard")
            Button("Previous Pinboard", systemImage: "chevron.left") { cyclePinboard(-1) }
                .keyboardShortcut("[", modifiers: .command)
            Button("Next Pinboard", systemImage: "chevron.right") { cyclePinboard(1) }
                .keyboardShortcut("]", modifiers: .command)
            Spacer(minLength: 8)
            Text("↩ paste · ⇧↩ copy").font(.caption).foregroundStyle(.secondary)
            Button(current?.isPinned == true ? "Unpin" : "Pin", systemImage: current?.isPinned == true ? "pin.slash" : "pin") {
                if let current { Task { await module.togglePin(current) } }
            }
            .keyboardShortcut("p", modifiers: .command)
            .help("Pin or unpin (⌘P)")
            .disabled(current == nil)
            Button("Delete", systemImage: "trash") {
                if let current { Task { await module.delete(current) } }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .help("Delete (⌘⌫)")
            .disabled(current == nil)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func cyclePinboard(_ delta: Int) {
        let options: [String?] = [nil] + module.pinboards.map(\.id)
        let index = options.firstIndex(of: pinboard) ?? 0
        pinboard = options[(index + delta + options.count) % options.count]
    }
}

/// The Clipboard tab in Settings.
struct ClipboardSettingsView: View {
    let module: ClipboardModule
    @State private var newBundleID = ""
    @State private var newPinboard = ""

    var body: some View {
        Form {
            Section("Clipboard History") {
                Toggle("Save clipboard history", isOn: Binding(get: { module.captureEnabled }, set: { module.setCaptureEnabled($0) }))
                    .accessibilityIdentifier("clipboard.capture")
                Text("Cue saves plain text you copy, encrypted with a key in your Keychain. It skips passwords, concealed and temporary items, secure text fields, and the apps below. Nothing leaves this Mac.")
                    .font(.callout).foregroundStyle(.secondary)
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
                    ErrorBanner(error: ClipboardModule.accessDeniedError, retryTitle: "Try Again", retry: module.recheckAccess)
                    Button("Open Paste Settings…", action: module.openPasteSettings)
                }
            }

            Section("Expiration") {
                Picker("Delete unpinned items after", selection: setting(\.retention)) {
                    ForEach(Retention.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Keep at most", selection: setting(\.maxItems)) {
                    ForEach(ClipboardSettings.maxItemChoices, id: \.self) { Text("\($0) unpinned items").tag($0) }
                }
                Text("Pinned items never expire. Expired items are deleted from disk.").font(.callout).foregroundStyle(.secondary)
            }

            Section("Shortcut") {
                LabeledContent("Open clipboard history") {
                    ShortcutRecorder(value: module.settings.shortcut.flatMap(Shortcut.init), onChange: module.setShortcut)
                }
                if let error = module.hotKeyError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                }
            }

            Section("Excluded Apps") {
                Text("Cue never saves what you copy while one of these apps is in front.").font(.callout).foregroundStyle(.secondary)
                ForEach(module.settings.excludedApps, id: \.self) { bundleID in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(module.appName(bundleID))
                            Text(bundleID).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", systemImage: "minus.circle") { module.removeExcludedApp(bundleID) }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                            .help("Remove \(module.appName(bundleID))")
                    }
                }
                HStack {
                    TextField("Bundle ID", text: $newBundleID, prompt: Text("com.example.App"))
                        .onSubmit(addBundleID)
                    Button("Add", action: addBundleID).disabled(newBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
                    Menu("Add Running App") {
                        ForEach(runningApps, id: \.0) { bundleID, name in
                            Button(name) { _ = module.addExcludedApp(bundleID) }
                        }
                    }
                    .fixedSize()
                }
            }

            Section("Pinboards") {
                ForEach(module.pinboards) { PinboardRow(board: $0, module: module) }
                HStack {
                    TextField("New pinboard", text: $newPinboard, prompt: Text("Name"))
                        .onSubmit(addPinboard)
                    Button("Add Pinboard", action: addPinboard).disabled(newPinboard.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section("Data") {
                Text("Export saves your history, pinboards, and these settings as unencrypted JSON. Import replaces them.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Export…", action: module.exportHistory)
                    Button("Import…", action: module.importHistory)
                    Spacer()
                    Button("Clear History…", role: .destructive, action: module.clearHistory)
                }
                if let status = module.settingsStatus { StatusLine(text: status.text, success: status.success) }
            }
        }
        .formStyle(.grouped)
        .disabled(module.phase == .loading)
    }

    private func setting<Value>(_ path: WritableKeyPath<ClipboardSettings, Value>) -> Binding<Value> {
        Binding(get: { module.settings[keyPath: path] }, set: { value in module.update { $0[keyPath: path] = value } })
    }

    private var runningApps: [(String, String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
            .filter { id, _ in !module.settings.excludedApps.contains { $0.caseInsensitiveCompare(id) == .orderedSame } }
            .sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
    }

    private func addBundleID() {
        if module.addExcludedApp(newBundleID) { newBundleID = "" }
    }

    private func addPinboard() {
        let name = newPinboard
        Task { if await module.createPinboard(name) { newPinboard = "" } }
    }
}

/// Rename with Return. An invalid name reverts.
private struct PinboardRow: View {
    let board: Pinboard
    let module: ClipboardModule
    @State private var name = ""

    var body: some View {
        HStack {
            TextField("Pinboard name", text: $name)
                .labelsHidden()
                .onSubmit {
                    Task { if !(await module.renamePinboard(board, to: name)) { name = board.name } }
                }
            Button("Delete Pinboard", systemImage: "trash") { module.deletePinboard(board) }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .help("Delete pinboard")
        }
        .onAppear { name = board.name }
        .onChange(of: board.name) { _, new in name = new }
    }
}
