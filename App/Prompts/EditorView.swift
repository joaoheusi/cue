import AppKit
import CueKit
import SwiftUI

private struct HeaderButton<Label: View>: View {
    var action: () -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .font(.system(size: 12.5, weight: .medium))
                .padding(.horizontal, 9)
                .frame(minWidth: 28, minHeight: 28)
                .background(Cue.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.12)) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PropertyRow<Content: View>: View {
    var title: String
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(title).frame(width: 120, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .frame(minHeight: 43)
    }
}

struct EditorView: View {
    let model: PromptsModel
    @Bindable var nav: LibraryNavigation
    let snapshot: LibrarySnapshot
    @State private var editor = TemplateEditorController()
    @State private var confirmDelete = false

    private static let variables: [(String, String)] = [
        ("clipboard", "{{clipboard}}"), ("selection", "{{selection}}"), ("date", "{{date}}"), ("time", "{{time}}"), ("ask…", "{{ask:Question}}"),
    ]

    var body: some View {
        if let draft = nav.draft {
            form(draft)
        }
    }

    private var validation: CueError? {
        guard var copy = nav.draft else { return nil }
        do {
            try ActionRules.validate(&copy)
            return nil
        } catch {
            return error
        }
    }

    private func form(_ draft: Action) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(draft)
                if nav.isDirty, let validation { ErrorBanner(error: validation) }
                promptCard(draft)
                properties(draft)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 20)
        }
        .background(Color.primary.opacity(0.012))
        .task(id: nav.draft) {
            guard nav.isDirty, nav.canSave, !nav.saving else { return }
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { await nav.flush() }
        }
        .background {
            Button("Save") { Task { await nav.flush() } }.keyboardShortcut("s").disabled(!nav.isDirty || validation != nil)
                .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
        }
        .confirmationDialog("Delete “\(draft.name)”?", isPresented: $confirmDelete) {
            Button("Delete Action", role: .destructive) {
                Task {
                    await model.delete(draft)
                    nav.edit(nil)
                }
            }
        } message: {
            Text("This removes the action and its direct shortcut. Export it first if you want to keep a copy.")
        }
    }

    private var saveState: String {
        if nav.draft?.revision == 0, !nav.isDirty || validation != nil { return "Not saved" }
        if validation != nil { return "Not saved" }
        if nav.saveFailed { return "Couldn’t save" }
        return nav.isDirty || nav.saving ? "Saving…" : "Saved"
    }

    private func header(_ draft: Action) -> some View {
        let isNew = draft.revision == 0
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Name", text: binding(\.name), prompt: Text("Action name"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .bold))
                TextField("Description", text: binding(\.description), prompt: Text("What does this action do?"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Text(saveState).font(.system(size: 11.5)).foregroundStyle(.secondary).padding(.top, 8)
            HeaderButton(action: test) {
                HStack(spacing: 6) {
                    Image(systemName: "play").font(.system(size: 10))
                    Text("Test")
                    Key(text: "⌘↵")
                }
                .fixedSize()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(validation != nil)
            HeaderButton(action: { nav.update { $0.favorite.toggle() } }) {
                Image(systemName: draft.favorite ? "star.fill" : "star").foregroundStyle(draft.favorite ? AnyShapeStyle(.yellow) : AnyShapeStyle(.primary))
            }
            .accessibilityLabel("Favorite")
            Menu {
                Button("Copy Text") { Task { await model.copy(draft) } }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(isNew || nav.isDirty)
                Button("Duplicate") { Task { if let copy = await model.duplicate(draft) { nav.edit(copy) } } }.disabled(isNew)
                Button("Revert Changes") { nav.revert() }.disabled(isNew || nav.baseline == nav.draft)
                Divider()
                Button("Delete…", role: .destructive) { confirmDelete = true }.disabled(isNew)
            } label: {
                Image(systemName: "ellipsis").frame(width: 28, height: 28)
                    .background(Cue.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.12)) }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More")
        }
    }

    private func promptCard(_ draft: Action) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Prompt").font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary.opacity(0.8)).padding(.trailing, 6)
                Text("Insert").font(.system(size: 11.5)).foregroundStyle(.secondary)
                ForEach(Self.variables, id: \.0) { name, token in
                    Button { editor.insert(token) } label: {
                        Chip(text: name, style: name == "clipboard" ? .claude : .neutral)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Insert \(name)")
                }
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(draft.template.utf8.count), countStyle: .memory))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(Color.primary.opacity(0.02))
            CardDivider()
            TemplateEditor(text: binding(\.template), controller: editor).frame(minHeight: 170)
        }
        .background(Cue.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Cue.hairline) }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var categories: [String] {
        guard let current = nav.draft?.category, !snapshot.categories.contains(current) else { return snapshot.categories }
        return snapshot.categories + [current]
    }

    private func properties(_ draft: Action) -> some View {
        CardList {
            PropertyRow("Runs as") {
                Segmented(options: [
                    .init(value: RunsAs.text, title: "Text"), .init(value: RunsAs.claude, title: "Claude"),
                    .init(value: RunsAs.script, title: "Script", enabled: false),
                ], selection: draft.runsAs) { kind in
                    nav.update { $0.ai = kind == .claude ? true : nil }
                }
            }
            CardDivider()
            PropertyRow("Result") {
                Picker("", selection: binding(\.deliveryMode)) {
                    Text("Default").tag(DeliveryMode.inherit)
                    Text("Paste into front app").tag(DeliveryMode.paste)
                    Text("Copy").tag(DeliveryMode.copy)
                }
                .labelsHidden()
                .fixedSize()
                if draft.deliveryMode == .inherit {
                    Text(snapshot.settings.defaultDelivery == .paste ? "Paste into front app" : "Copy").font(.system(size: 12)).foregroundStyle(.secondary).padding(.leading, 10)
                }
            }
            CardDivider()
            PropertyRow("Category") {
                Picker("", selection: binding(\.category)) {
                    Text("None").tag(String?.none)
                    ForEach(categories, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .labelsHidden()
                .fixedSize()
            }
            CardDivider()
            PropertyRow("Keywords") {
                TagField(tags: draft.aliases) { tags in nav.update { $0.aliases = tags } }.padding(.vertical, 8)
            }
            CardDivider()
            PropertyRow("Shortcut") {
                if draft.revision == 0 {
                    Text("Add a name and text first.").foregroundStyle(.secondary)
                } else {
                    let owner = PromptsModel.owner(draft)
                    ShortcutRecorder(value: snapshot.bindings[owner].flatMap(Shortcut.init)) { shortcut in
                        Task { await model.setShortcut(shortcut, for: draft) }
                    }
                    if let error = model.context.hotKeys.statuses[owner]?.error {
                        Text(error).font(.caption).foregroundStyle(.orange).padding(.leading, 10)
                    }
                }
            }
            CardDivider()
            PropertyRow("Enabled") {
                SwitchToggle(isOn: binding(\.enabled), label: "Enabled")
            }
        }
    }

    private func binding<T>(_ path: WritableKeyPath<Action, T>) -> Binding<T> {
        Binding(get: { nav.draft![keyPath: path] }, set: { value in nav.update { $0[keyPath: path] = value } })
    }

    private func test() {
        if let draft = nav.draft { model.test(draft) }
    }
}

struct ScriptEditorView: View {
    let script: Script
    let model: PromptsModel
    let commands: CommandsModule
    @State private var source = ""
    @State private var running = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(script.name).font(.system(size: 22, weight: .bold))
                        Text(script.url.lastPathComponent).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if running { ProgressView().controlSize(.small).padding(.top, 6) }
                    HeaderButton(action: test) {
                        HStack(spacing: 6) {
                            Image(systemName: "play").font(.system(size: 10))
                            Text("Test")
                            Key(text: "⌘↵")
                        }
                        .fixedSize()
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(running)
                    HeaderButton(action: { NSWorkspace.shared.activateFileViewerSelecting([script.url]) }) { Text("Reveal") }
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("Script").font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary.opacity(0.8))
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                        .background(Color.primary.opacity(0.02))
                    CardDivider()
                    Text(source)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
                        .padding(12)
                }
                .background(Cue.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Cue.hairline) }
                CardList {
                    PropertyRow("Runs as") {
                        Segmented(options: [
                            .init(value: RunsAs.text, title: "Text", enabled: false), .init(value: RunsAs.claude, title: "Claude", enabled: false),
                            .init(value: RunsAs.script, title: "Script"),
                        ], selection: RunsAs.script) { _ in }
                    }
                    CardDivider()
                    PropertyRow("Result") {
                        Text(model.snapshot?.settings.scriptOutput == .show ? "Show output" : "Copy output").foregroundStyle(.secondary)
                    }
                    CardDivider()
                    PropertyRow("Shortcut") {
                        ShortcutRecorder(value: commands.shortcut(for: script)) { shortcut in
                            Task { await commands.setShortcut(shortcut, for: script) }
                        }
                        if let error = commands.shortcutError(for: script) {
                            Text(error).font(.caption).foregroundStyle(.orange).padding(.leading, 10)
                        }
                    }
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 20)
        }
        .task {
            let url = script.url
            let text = await Task.detached { (try? BoundedFile.read(url, maxBytes: 64 * 1024)).map { String(decoding: $0, as: UTF8.self) } }.value
            source = text ?? "Could not read this file."
        }
    }

    private func test() {
        running = true
        Task {
            defer { running = false }
            do {
                model.showOutput(script.name, text: try await commands.run(script), surface: .library)
            } catch {
                model.notice = (error.cueError.message, false)
            }
        }
    }
}

@MainActor final class TemplateEditorController {
    weak var textView: NSTextView?

    func insert(_ text: String) {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        textView.insertText(text, replacementRange: textView.selectedRange())
    }
}

struct TemplateEditor: NSViewRepresentable {
    @Binding var text: String
    let controller: TemplateEditorController

    private static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private static let token = try? NSRegularExpression(pattern: #"(\{\{)(clipboard|selection|date|time|ask(?::[^}]*)?)(\}\})"#)

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = Self.font
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.drawsBackground = false
        textView.string = text
        textView.delegate = context.coordinator
        textView.setAccessibilityIdentifier("editor.template")
        controller.textView = textView
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        Self.style(textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scroll.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
        Self.style(textView)
    }

    static func style(_ textView: NSTextView) {
        guard let storage = textView.textStorage, !textView.hasMarkedText() else { return }
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: NSColor.labelColor], range: whole)
        for match in token?.matches(in: storage.string, range: whole) ?? [] {
            storage.addAttributes([.backgroundColor: NSColor(Cue.tokenFill), .foregroundColor: NSColor(Cue.token)], range: match.range)
            for brace in [match.range(at: 1), match.range(at: 3)] {
                storage.addAttributes([.foregroundColor: NSColor.clear, .font: NSFont.monospacedSystemFont(ofSize: 1, weight: .regular)], range: brace)
            }
        }
        storage.endEditing()
        textView.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            MainActor.assumeIsolated { TemplateEditor.style(textView) }
        }
    }
}
