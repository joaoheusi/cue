import AppKit
import CueKit
import SwiftUI

struct GeneralSettingsView: View {
    let model: PromptsModel
    @State private var launchOn = false
    @State private var launchError: String?
    @State private var autoCheck = false
    @State private var autoInstall = false
    @State private var legacyAgent = LaunchAtLogin.hasLegacyAgent
    @State private var granted = false

    private var updater: AppUpdater { model.context.updater }

    var body: some View {
        SettingsPage {
            if let settings = model.snapshot?.settings {
                SettingsSection("Appearance") {
                    SettingsRow("Theme") {
                        Picker("", selection: Binding(get: { settings.theme }, set: { theme in Task { await model.saveSettings { $0.theme = theme } } })) {
                            Text("System").tag(Theme.system)
                            Text("Light").tag(Theme.light)
                            Text("Dark").tag(Theme.dark)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }
            SettingsSection("Startup") {
                SettingsRow("Launch at login") {
                    SwitchToggle(isOn: Binding(get: { launchOn }, set: { setLaunch($0) }), label: "Launch at login")
                }
            }
            if let launchError { ErrorBanner(error: CueError("AUTOSTART_FAILED", launchError)) }
            if legacyAgent {
                ErrorBanner(error: CueError("LEGACY_LOGIN_ITEM", "An older Cue login item (~/Library/LaunchAgents/Cue.plist) also starts Cue. Remove it and use Launch at login instead."),
                            retryTitle: "Remove Old Login Item") {
                    do {
                        try LaunchAtLogin.removeLegacyAgent()
                    } catch {
                        launchError = error.cueError.message
                    }
                    legacyAgent = LaunchAtLogin.hasLegacyAgent
                }
            }
            SettingsSection("Updates") {
                if updater.isAvailable {
                    SettingsRow("Check automatically") {
                        Text("Hourly").foregroundStyle(.secondary)
                        SwitchToggle(isOn: Binding(get: { autoCheck }, set: { updater.automaticallyChecks = $0; autoCheck = $0 }), label: "Check automatically")
                    }
                    CardDivider()
                    SettingsRow("Install automatically") {
                        Text("When idle").foregroundStyle(.secondary)
                        SwitchToggle(isOn: Binding(get: { autoInstall }, set: { updater.automaticallyInstalls = $0; autoInstall = $0 }), label: "Install automatically")
                            .disabled(!autoCheck)
                    }
                    CardDivider()
                    HStack(spacing: 10) {
                        Text("Cue \(model.context.version)").fontWeight(.medium)
                        if updater.upToDate { Text("Up to date").font(.system(size: 12.5)).foregroundStyle(Cue.success) }
                        Spacer()
                        if let last = updater.lastCheck {
                            Text("Checked \(last.formatted(.relative(presentation: .named)))").foregroundStyle(.secondary)
                        }
                        Button("Check Now") { updater.checkNow() }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                } else {
                    SettingsRow("Cue \(model.context.version)", note: "Updates are off in debug builds.")
                }
            }
            SettingsSection("Permissions") {
                SettingsRow("Accessibility", note: "Paste, shortcuts") {
                    if granted {
                        StatusDot(color: Cue.success)
                        Text("Granted")
                    } else {
                        Button("Allow…") {
                            if model.context.permissions.explain(.accessibility(reason: PromptsModel.pasteReason)) {
                                model.context.paste.requestAccess()
                            }
                        }
                    }
                }
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func setLaunch(_ on: Bool) {
        do {
            try LaunchAtLogin.set(on)
            launchError = nil
        } catch {
            launchError = error.cueError.message
        }
        launchOn = LaunchAtLogin.isEnabled || LaunchAtLogin.needsApproval
    }

    private func refresh() {
        launchOn = LaunchAtLogin.isEnabled || LaunchAtLogin.needsApproval
        autoCheck = updater.automaticallyChecks
        autoInstall = updater.automaticallyInstalls
        granted = model.context.paste.canReadTarget && model.context.paste.canPostPaste
    }
}

struct ShortcutsSettingsView: View {
    let model: PromptsModel
    let commands: CommandsModule
    let clipboard: ClipboardModule
    let menuBar: MenuBarModule
    @State private var paused = false

    var body: some View {
        SettingsPage {
            if let snapshot = model.snapshot {
                CardList {
                    SettingsRow("Pause all Cue shortcuts", weight: .medium) {
                        SwitchToggle(isOn: Binding(get: { paused }, set: { value in
                            model.context.hotKeys.setPaused(value)
                            paused = model.context.hotKeys.paused
                        }), label: "Pause all Cue shortcuts")
                    }
                }
                SettingsSection("Global") {
                    row("Search", owner: "palette", value: Shortcut(snapshot.bindings["palette"] ?? snapshot.settings.paletteShortcut)) { value in
                        Task { await model.setPaletteShortcut(value) }
                    }
                    CardDivider()
                    row("Clipboard", value: clipboard.settings.shortcut.flatMap(Shortcut.init), failure: clipboard.hotKeyError) { clipboard.setShortcut($0) }
                    CardDivider()
                    row("Menu Bar Items", owner: PromptsModel.menuBarScopeOwner, value: Shortcut(snapshot.settings.menuBarScopeShortcut)) { value in
                        Task { await model.setMenuBarScopeShortcut(value) }
                    }
                    CardDivider()
                    row("Show / Hide Hidden Items", value: menuBar.settings.shortcut.flatMap(Shortcut.init), failure: menuBar.hotKeyError) { value in
                        Task { await menuBar.setShortcut(value) }
                    }
                }
                SettingsSection("Actions", trailing: {
                    Button("Open Library") { model.context.openLibrary(nil) }.buttonStyle(.link).font(.system(size: 12.5))
                }) {
                    ForEach(snapshot.actions.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { action in
                        actionRow(action, snapshot)
                        CardDivider()
                    }
                    ForEach(commands.scripts) { script in
                        rowContent(script.name, value: commands.shortcut(for: script), failure: commands.shortcutError(for: script)) {
                            Tile(.script, size: 18)
                        } change: { value in
                            Task { await commands.setShortcut(value, for: script) }
                        }
                        CardDivider()
                    }
                }
                SettingsSection("Windows") {
                    ForEach(Array(WindowCommand.allCases.enumerated()), id: \.element) { index, command in
                        if index > 0 { CardDivider() }
                        row(command.title, value: commands.shortcut(for: command), failure: commands.shortcutError(for: command)) { value in
                            Task { await commands.setShortcut(value, for: command) }
                        }
                    }
                }
                if let notice = model.notice { StatusLine(text: notice.text, success: notice.success) }
                if let status = commands.status { StatusLine(text: status.text, success: status.success) }
            } else {
                LoadingView()
            }
        }
        .onAppear { paused = model.context.hotKeys.paused }
        .task { await commands.reload() }
    }

    private func actionRow(_ action: Action, _ snapshot: LibrarySnapshot) -> some View {
        let owner = PromptsModel.owner(action)
        let value = snapshot.bindings[owner].flatMap(Shortcut.init)
        let failure = action.enabled ? model.context.hotKeys.statuses[owner]?.error : nil
        return rowContent(action.name, note: action.enabled ? nil : "Disabled", dimmed: !action.enabled, value: value, failure: failure) {
            Tile(action.runsAs, size: 18).opacity(action.enabled ? 1 : 0.5)
        } change: { shortcut in
            Task { await model.setShortcut(shortcut, for: action) }
        }
    }

    private func row(_ title: String, owner: String? = nil, value: Shortcut?, failure: String? = nil, change: @escaping (Shortcut?) -> Void) -> some View {
        rowContent(title, value: value, failure: failure ?? owner.flatMap { model.context.hotKeys.statuses[$0]?.error }, leading: { EmptyView() }, change: change)
    }

    private func rowContent<Leading: View>(_ title: String, note: String? = nil, dimmed: Bool = false, value: Shortcut?, failure: String? = nil,
                                           @ViewBuilder leading: () -> Leading, change: @escaping (Shortcut?) -> Void) -> some View {
        HStack(spacing: 10) {
            leading()
            Text(title).foregroundStyle(dimmed ? .secondary : .primary).lineLimit(1)
            if let note { Text(note).font(.system(size: 12)).foregroundStyle(.secondary) }
            Spacer(minLength: 8)
            if let failure { Text(failure).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(1) }
            ShortcutRecorder(value: value, dimmed: dimmed, onChange: change)
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
    }
}

struct PaletteSettingsView: View {
    let model: PromptsModel
    @State private var selectedLocation: String?

    var body: some View {
        SettingsPage {
            if let settings = model.snapshot?.settings {
                SettingsSection("Behavior") {
                    SettingsRow("Default result") {
                        Picker("", selection: Binding(get: { settings.defaultDelivery }, set: { value in
                            Task { await model.saveSettings { $0.defaultDelivery = value } }
                        })) {
                            Text("Paste into front app").tag(DeliveryMode.paste)
                            Text("Copy").tag(DeliveryMode.copy)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    CardDivider()
                    SettingsRow("Preview pane") {
                        SwitchToggle(isOn: Binding(get: { settings.previewPane }, set: { on in
                            Task { await model.saveSettings { $0.previewPane = on } }
                        }), label: "Preview pane")
                    }
                    CardDivider()
                    SettingsRow("Search in") {
                        ForEach(SearchSource.allCases, id: \.self) { source in
                            sourceButton(source, settings)
                        }
                    }
                }
                SettingsSection("File locations") {
                    ForEach(settings.fileLocations) { location in
                        locationRow(location, settings)
                        CardDivider()
                    }
                    PlusMinusBar(removeEnabled: selectedLocation != nil, remove: {
                        let path = selectedLocation
                        selectedLocation = nil
                        Task { await model.saveSettings { $0.fileLocations.removeAll { $0.path == path } } }
                    }) {
                        Button(action: addLocation) { Image(systemName: "plus").frame(width: 26, height: 26).contentShape(Rectangle()) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Add location")
                    }
                }
                SettingsSection("Skip folders named") {
                    TagField(tags: settings.skipFolders, monospaced: true) { tags in
                        Task { await model.saveSettings { $0.skipFolders = tags } }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                LoadingView()
            }
        }
    }

    private func sourceButton(_ source: SearchSource, _ settings: PromptSettings) -> some View {
        let on = settings.searchIn.contains(source)
        return Button {
            Task {
                await model.saveSettings { value in
                    if value.searchIn.contains(source) { value.searchIn.removeAll { $0 == source } } else { value.searchIn.append(source) }
                }
            }
        } label: {
            Text(source.rawValue.capitalized)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary.opacity(0.75)))
                .padding(.horizontal, 11)
                .frame(height: 24)
                .background(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Cue.fill), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func locationRow(_ location: FileLocation, _ settings: PromptSettings) -> some View {
        HStack(spacing: 10) {
            FileIcon(path: location.expanded, size: 18)
            Text(location.path).font(.system(size: 12, design: .monospaced)).lineLimit(1)
            Spacer()
            Picker("", selection: Binding(get: { location.depth }, set: { depth in
                Task {
                    await model.saveSettings { value in
                        if let index = value.fileLocations.firstIndex(of: location) { value.fileLocations[index].depth = depth }
                    }
                }
            })) {
                ForEach(FileLocation.depthChoices, id: \.self) { Text($0.map { "Depth \($0)" } ?? "All levels").tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(selectedLocation == location.path ? Cue.selection : .clear)
        .contentShape(Rectangle())
        .onTapGesture { selectedLocation = location.path }
    }

    private func addLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        NSApp.takeFocus()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = (url.path as NSString).abbreviatingWithTildeInPath
        Task {
            await model.saveSettings { value in
                if !value.fileLocations.contains(where: { $0.path == path }) { value.fileLocations.append(FileLocation(path: path, depth: nil)) }
            }
        }
    }
}

struct ActionsSettingsView: View {
    let module: CommandsModule
    let prompts: PromptsModel
    @State private var confirmClear = false

    var body: some View {
        SettingsPage {
            if let snapshot = prompts.snapshot {
                let settings = snapshot.settings
                SettingsSection("Claude") {
                    HStack(spacing: 10) {
                        Text("API key")
                        Text(module.keyPreview ?? "Not set").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        Spacer()
                        Button(module.hasKey ? "Replace…" : "Add…", action: module.replaceKey)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    CardDivider()
                    SettingsRow("Stored in") {
                        Picker("", selection: Binding(get: { settings.keyStorage }, set: { value in Task { await module.setKeyStorage(value) } })) {
                            Text(".env file").tag(KeyStorage.env)
                            Text("Keychain").tag(KeyStorage.keychain)
                        }
                        .labelsHidden()
                        .fixedSize()
                        if settings.keyStorage == .env { Button("Open .env", action: module.openEnv) }
                    }
                    CardDivider()
                    SettingsRow("Status") {
                        keyStatus
                        Button("Test") { Task { await module.testKey() } }.disabled(!module.hasKey || module.testingKey)
                    }
                }
                SettingsSection("Scripts") {
                    HStack(spacing: 10) {
                        Text("Folder")
                        Text(scriptsPath).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Reveal", action: module.showScripts)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    CardDivider()
                    SettingsRow("Found") { Text("\(module.scripts.count) script\(module.scripts.count == 1 ? "" : "s")").foregroundStyle(.secondary) }
                    CardDivider()
                    SettingsRow("Stop after") {
                        Picker("", selection: Binding(get: { settings.scriptTimeout }, set: { value in Task { await prompts.saveSettings { $0.scriptTimeout = value } } })) {
                            ForEach(timeoutChoices(settings), id: \.self) { Text("\($0) seconds").tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    CardDivider()
                    SettingsRow("Output") {
                        Picker("", selection: Binding(get: { settings.scriptOutput }, set: { value in Task { await prompts.saveSettings { $0.scriptOutput = value } } })) {
                            Text("Copy").tag(ScriptOutput.copy)
                            Text("Show").tag(ScriptOutput.show)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                SettingsSection("Library data") {
                    HStack(spacing: 10) {
                        Text(Snippets.fileName).font(.system(size: 12, design: .monospaced))
                        Text(module.snippets.count == 1 ? "1 entry" : "\(module.snippets.count) entries").font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Reveal", action: module.revealSnippets)
                        Button("Import into Library") { Task { await module.importSnippets() } }.disabled(module.snippets.isEmpty)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    CardDivider()
                    SettingsRow("Actions", note: "\(snapshot.actions.count)") {
                        Button("Import…") {
                            Task {
                                if let preview = await prompts.previewImport() {
                                    prompts.context.openLibrary(nil)
                                    prompts.pendingImport = preview
                                }
                            }
                        }
                        Button("Export…") { Task { await prompts.exportActions() } }
                    }
                    CardDivider()
                    SettingsRow("Usage history") {
                        Button("Clear…") { confirmClear = true }
                    }
                }
                if let error = module.snippetError { ErrorBanner(error: error) }
                if let notice = prompts.notice { StatusLine(text: notice.text, success: notice.success) }
                if let status = module.status { StatusLine(text: status.text, success: status.success) }
            } else {
                LoadingView()
            }
        }
        .task { await module.reload() }
        .confirmationDialog("Clear usage history?", isPresented: $confirmClear) {
            Button("Clear Usage", role: .destructive) { Task { await prompts.perform("Usage cleared.") { try await $0.clearUsage() } } }
        } message: {
            Text("This resets use counts and recent actions. All templates stay in your library.")
        }
    }

    private var scriptsPath: String {
        (module.context.dataDirectory.appendingPathComponent(Scripts.folderName).path as NSString).abbreviatingWithTildeInPath
    }

    private func timeoutChoices(_ settings: PromptSettings) -> [Int] {
        Scripts.timeoutChoices.contains(settings.scriptTimeout) ? Scripts.timeoutChoices : [settings.scriptTimeout] + Scripts.timeoutChoices
    }

    @ViewBuilder private var keyStatus: some View {
        if module.testingKey {
            ProgressView().controlSize(.small)
        } else if let test = module.keyTest {
            StatusDot(color: test.valid ? Cue.success : .red)
            Text(test.valid ? "Valid" : test.message ?? "Invalid").lineLimit(1)
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Text("· tested \(test.at.formatted(.relative(presentation: .named)))").foregroundStyle(.secondary)
            }
        } else {
            Text(module.hasKey ? "Not tested" : "No key").foregroundStyle(.secondary)
        }
    }
}
