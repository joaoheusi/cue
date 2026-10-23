import CueKit
import SwiftUI

/// General tab: appearance, launch at login, update check, and shortcut pause.
struct GeneralSettingsView: View {
    let model: PromptsModel
    @State private var launchStatus = LaunchAtLogin.statusText
    @State private var launchError: String?
    @State private var update: UpdateChecker.Outcome?
    @State private var checking = false
    @State private var paused = false

    var body: some View {
        Form {
            if let settings = model.snapshot?.settings {
                Section("Appearance") {
                    Picker("Theme", selection: Binding(get: { settings.theme }, set: { theme in Task { await model.saveSettings { $0.theme = theme } } })) {
                        Text("System").tag(Theme.system)
                        Text("Light").tag(Theme.light)
                        Text("Dark").tag(Theme.dark)
                    }
                }
                Section("Startup") {
                    Toggle("Launch at login", isOn: Binding(get: { LaunchAtLogin.isEnabled || LaunchAtLogin.needsApproval }, set: { on in
                        do {
                            try LaunchAtLogin.set(on)
                            launchError = nil
                        } catch {
                            launchError = error.cueError.message
                        }
                        launchStatus = LaunchAtLogin.statusText
                    }))
                    Text("Status: \(launchStatus). Cue starts quietly in the menu bar.").font(.caption).foregroundStyle(.secondary)
                    if let launchError { ErrorBanner(error: CueError("AUTOSTART_FAILED", launchError)) }
                }
                Section("Updates") {
                    Toggle("Check for updates", isOn: Binding(get: { settings.updateCheck }, set: { on in Task { await model.saveSettings { $0.updateCheck = on } } }))
                    Text("Off by default. When on, Cue asks the release page for the latest version once a week and when you press Check Now. It sends no identifiers and never installs anything.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Check Now") { Task { await check() } }.disabled(checking || !settings.updateCheck)
                        if checking { ProgressView().controlSize(.small) }
                        updateStatus
                    }
                }
            }
            Section("Shortcuts") {
                Toggle("Pause all Cue shortcuts", isOn: Binding(get: { paused }, set: { value in
                    model.context.hotKeys.setPaused(value)
                    paused = model.context.hotKeys.paused
                }))
                Text("Use this while another app needs the same keys. The menu-bar icon still works.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            paused = model.context.hotKeys.paused
            launchStatus = LaunchAtLogin.statusText
        }
    }

    @ViewBuilder private var updateStatus: some View {
        switch update {
        case .upToDate: StatusLine(text: "Cue \(model.context.version) is up to date.", success: true)
        case .available(let release):
            HStack {
                StatusLine(text: "Cue \(release.version) is available.", success: true)
                Link("Open Release Page", destination: release.page)
            }
        case .notConfigured: StatusLine(text: "This build has no update address. Set CUE_UPDATE_URL in .env.", success: false)
        case .failed(let message): StatusLine(text: message, success: false)
        case nil: EmptyView()
        }
    }

    private func check() async {
        checking = true
        update = await UpdateChecker.check(currentVersion: model.context.version)
        checking = false
        await model.saveSettings { $0.lastUpdateCheck = Timestamp.now() }
    }
}

/// Prompts tab: palette shortcut, delivery, paste permission, direct shortcuts, and library data.
struct PromptsSettingsView: View {
    let model: PromptsModel
    @State private var confirmClear = false
    @State private var canRead = false
    @State private var canPost = false

    var body: some View {
        Form {
            if let snapshot = model.snapshot {
                Section("Palette") {
                    LabeledContent("Shortcut") {
                        VStack(alignment: .trailing, spacing: 2) {
                            ShortcutRecorder(value: Shortcut(snapshot.bindings["palette"] ?? snapshot.settings.paletteShortcut)) { shortcut in
                                guard let shortcut else { return }
                                Task { await model.setPaletteShortcut(shortcut) }
                            }
                            if let error = model.context.hotKeys.statuses["palette"]?.error {
                                Text(error).font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                    Picker("Default delivery", selection: Binding(get: { snapshot.settings.defaultDelivery }, set: { value in
                        Task { await model.saveSettings { $0.defaultDelivery = value } }
                    })) {
                        Text("Paste into the app you’re using").tag(DeliveryMode.paste)
                        Text("Copy").tag(DeliveryMode.copy)
                    }
                    Text("Actions can override this preference. Shift-Return always copies.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Show text preview in the palette", isOn: Binding(get: { snapshot.settings.preview }, set: { on in
                        Task { await model.saveSettings { $0.preview = on } }
                    }))
                }
                Section("Paste permission") {
                    LabeledContent("Status", value: canRead && canPost ? "Ready to paste" : "Accessibility access required")
                    Text("Cue returns to the window and text field you opened it from and sends one ⌘V. Secure fields and terminals are never pasted into.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !(canRead && canPost) {
                        Button("Allow Cue to Paste…") {
                            if model.context.permissions.explain(.accessibility(reason: PromptsModel.pasteReason)) {
                                model.context.paste.requestAccess()
                            }
                        }
                    }
                }
                Section("Direct action shortcuts") {
                    let bound = snapshot.actions.filter { snapshot.bindings[PromptsModel.owner($0)] != nil }
                    if bound.isEmpty {
                        Text("Set a shortcut in an action’s editor. Disabled actions never run.").foregroundStyle(.secondary)
                    }
                    ForEach(bound) { action in
                        let status = model.context.hotKeys.statuses[PromptsModel.owner(action)]
                        LabeledContent(action.name) {
                            Text("\(Shortcut(snapshot.bindings[PromptsModel.owner(action)] ?? "")?.display ?? "?") · \(status?.active == true ? "Active" : status?.error ?? "Inactive")")
                        }
                    }
                }
                Section("Library data") {
                    HStack {
                        Button("Import Actions…") {
                            Task {
                                if let preview = await model.previewImport() {
                                    model.context.openLibrary(nil)
                                    model.pendingImport = preview
                                }
                            }
                        }
                        Button("Export Actions…") { Task { await model.exportActions() } }
                    }
                    Button("Clear Usage History…") { confirmClear = true }
                    if let notice = model.notice { StatusLine(text: notice.text, success: notice.success) }
                }
            } else {
                LoadingView()
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshPermissions)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshPermissions() }
        .confirmationDialog("Clear usage history?", isPresented: $confirmClear) {
            Button("Clear Usage", role: .destructive) { Task { await model.perform("Usage cleared.") { try await $0.clearUsage() } } }
        } message: {
            Text("This resets use counts and recent actions. All templates stay in your library.")
        }
    }

    private func refreshPermissions() {
        canRead = model.context.paste.canReadTarget
        canPost = model.context.paste.canPostPaste
    }
}
