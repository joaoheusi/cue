import AppKit
import CueKit
import SwiftUI

struct HeaderButton<Label: View>: View {
    var action: () -> Void
    @ViewBuilder var label: () -> Label
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            label()
                .font(.system(size: 12.5))
                .foregroundStyle(enabled ? Cue.ink : Color(nsColor: .tertiaryLabelColor))
                .frame(minWidth: 28, minHeight: 28)
                .bordered(Cue.control)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct TestButton: View {
    var ready: Bool
    var action: () -> Void

    var body: some View {
        HeaderButton(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "play").font(.system(size: 10))
                Text("Test")
                if ready { Key(text: "⌘↵", compact: true) }
            }
            .fixedSize()
            .padding(.horizontal, 10)
        }
        .keyboardShortcut(.return, modifiers: .command)
        .accessibilityLabel("Test")
    }
}

private struct Property<Content: View>: View {
    var title: String
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct EditorView: View {
    let model: PromptsModel
    @Bindable var nav: LibraryNavigation
    let snapshot: LibrarySnapshot
    @State private var editor = TemplateEditorController()
    @State private var confirmDelete = false
    @FocusState private var nameFocused: Bool

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
        VStack(alignment: .leading, spacing: 14) {
            header(draft)
            if nav.isDirty, let validation { ErrorBanner(error: validation) }
            promptCard(draft)
            if let run = model.libraryRun { TestPanel(run: run, model: model) }
            properties(draft)
        }
        .padding(.top, 18)
        .padding(.horizontal, 24)
        .padding(.bottom, 22)
        .task(id: draft.id) {
            if draft.revision == 0 { nameFocused = true }
        }
        .task(id: nav.draft) {
            guard nav.isDirty, nav.canSave, !nav.saving else { return }
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { await nav.flush() }
        }
        .background {
            Button("Save") { Task { await nav.flush() } }.keyboardShortcut("s").disabled(!nav.isDirty || validation != nil)
                .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
            Button("Copy Text", action: copyText).keyboardShortcut("c", modifiers: [.command, .shift]).disabled(draft.revision == 0 || nav.isDirty)
                .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
        }
        .confirmationDialog("Delete “\(draft.name)”?", isPresented: $confirmDelete) {
            Button("Delete Action", role: .destructive) {
                guard let draft = nav.draft else { return }
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
        return HStack(spacing: 12) {
            Tile(draft.runsAs, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: binding(\.name), prompt: Text("Untitled"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 21, weight: .bold))
                    .focused($nameFocused)
                TextField("Description", text: binding(\.description), prompt: Text("Description"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Segmented(options: [
                .init(value: RunsAs.text, title: "Text"), .init(value: RunsAs.claude, title: "Claude", dot: Cue.claude),
            ], selection: draft.runsAs, selectedFill: Cue.segmentQuiet) { kind in
                nav.update { $0.ai = kind == .claude ? true : nil }
            }
            .fixedSize()
            TestButton(ready: validation == nil, action: test).disabled(validation != nil)
            HeaderButton(action: { nav.update { $0.favorite.toggle() } }) {
                Image(systemName: draft.favorite ? "star.fill" : "star").font(.system(size: 13))
                    .foregroundStyle(draft.favorite ? Cue.favorite : Cue.ink)
            }
            .accessibilityLabel("Favorite")
            Menu {
                Button("Copy Text", action: copyText)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(isNew || nav.isDirty)
                Button("Duplicate") { if let draft = nav.draft { Task { if let copy = await model.duplicate(draft) { nav.edit(copy) } } } }.disabled(isNew)
                Button("Revert Changes") { nav.revert() }.disabled(isNew || nav.baseline == nav.draft)
                Divider()
                Button("Delete…", role: .destructive) { confirmDelete = true }.disabled(isNew)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13)).frame(width: 28, height: 28).bordered(Cue.control)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More")
        }
        .frame(height: 52)
    }

    private func promptCard(_ draft: Action) -> some View {
        VStack(spacing: 0) {
            TemplateEditor(text: binding(\.template), controller: editor)
                .overlay(alignment: .topLeading) {
                    if draft.template.isEmpty {
                        Text("Text").font(.system(size: 13, design: .monospaced)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 18).padding(.vertical, 16).allowsHitTesting(false)
                    }
                }
            CardDivider()
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    Text("{ }").font(.system(size: 12, design: .monospaced))
                    Text("Insert")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(.trailing, 4)
                ForEach(Self.variables, id: \.0) { name, token in
                    Button { editor.insert(token) } label: {
                        Text(name)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Cue.keyText)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(Cue.subtle, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Insert \(name)")
                }
                Spacer(minLength: 8)
                Text(saveState).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(Cue.wellBar)
        }
        .frame(minHeight: 120, maxHeight: .infinity)
        .background(Cue.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Cue.hairline) }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var categories: [String] {
        guard let current = nav.draft?.category, !snapshot.categories.contains(current) else { return snapshot.categories }
        return snapshot.categories + [current]
    }

    private func deliveryTitle(_ mode: DeliveryMode) -> String {
        switch mode {
        case .inherit: snapshot.settings.defaultDelivery == .paste ? "Default (Paste)" : "Default (Copy)"
        case .paste: "Paste into front app"
        case .replace: "Replace selection"
        case .copy: "Copy"
        }
    }

    private func properties(_ draft: Action) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 14) {
            GridRow {
                Property("Result") {
                    PopMenu(title: deliveryTitle(draft.deliveryMode), selection: binding(\.deliveryMode),
                            options: [DeliveryMode.inherit, .paste, .replace, .copy].map { ($0, deliveryTitle($0)) })
                }
                Property("Category") {
                    PopMenu(title: draft.category ?? "None", dimmed: draft.category == nil, selection: binding(\.category),
                            options: [(String?.none, "None")] + categories.map { (Optional($0), $0) })
                }
                Property("Shortcut") {
                    if draft.revision == 0 {
                        ShortcutRecorder(value: nil, width: nil, height: 28) { _ in }.disabled(true)
                    } else {
                        let owner = PromptsModel.owner(draft)
                        ShortcutRecorder(value: snapshot.bindings[owner].flatMap(Shortcut.init), width: nil, height: 28) { shortcut in
                            Task { await model.setShortcut(shortcut, for: draft) }
                        }
                        if let error = model.context.hotKeys.statuses[owner]?.error {
                            Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2)
                        }
                    }
                }
            }
            GridRow {
                Property("Keywords") {
                    TagField(tags: draft.aliases, placeholder: "Add", compact: true) { tags in nav.update { $0.aliases = tags } }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                        .bordered(Cue.input)
                }
                .gridCellColumns(2)
                Property("Enabled") {
                    SwitchToggle(isOn: binding(\.enabled), label: "Enabled").frame(height: 28)
                }
            }
        }
    }

    private func binding<T>(_ path: WritableKeyPath<Action, T>) -> Binding<T> {
        Binding(get: { (nav.draft ?? Action())[keyPath: path] }, set: { value in nav.update { $0[keyPath: path] = value } })
    }

    private func test() {
        if let draft = nav.draft { Task { await model.test(draft) } }
    }

    private func copyText() {
        if let draft = nav.draft { Task { await model.copy(draft) } }
    }
}

struct ScriptEditorView: View {
    let script: Script
    let model: PromptsModel
    let commands: CommandsModule
    @State private var source = ""
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Tile(.script, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(script.name).font(.system(size: 21, weight: .bold)).lineLimit(1)
                    Text(script.url.lastPathComponent).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if running { ProgressView().controlSize(.small) }
                TestButton(ready: !running, action: test).disabled(running)
                HeaderButton(action: { NSWorkspace.shared.activateFileViewerSelecting([script.url]) }) {
                    Text("Reveal").padding(.horizontal, 10)
                }
            }
            .frame(height: 52)
            ScrollView {
                Text(source)
                    .font(.system(size: 13, design: .monospaced))
                    .lineSpacing(6)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
            }
            .frame(maxHeight: .infinity)
            .background(Cue.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Cue.hairline) }
            if let run = model.libraryRun { TestPanel(run: run, model: model) }
            Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 14) {
                GridRow {
                    Property("Result") {
                        Text(model.snapshot?.settings.scriptOutput == .show ? "Show output" : "Copy output")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                            .bordered(Cue.input)
                    }
                    Property("Shortcut") {
                        ShortcutRecorder(value: commands.shortcut(for: script), width: nil, height: 28) { shortcut in
                            Task { await commands.setShortcut(shortcut, for: script) }
                        }
                        if let error = commands.shortcutError(for: script) {
                            Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2)
                        }
                    }
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                }
            }
        }
        .padding(.top, 18)
        .padding(.horizontal, 24)
        .padding(.bottom, 22)
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
    private static let paragraph = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 6
        return style
    }()
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
        textView.textContainerInset = NSSize(width: 13, height: 16)
        textView.drawsBackground = false
        textView.string = text
        textView.delegate = context.coordinator
        textView.setAccessibilityIdentifier("editor.template")
        controller.textView = textView
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
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
        storage.setAttributes([.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph], range: whole)
        for match in token?.matches(in: storage.string, range: whole) ?? [] {
            storage.addAttributes([.backgroundColor: NSColor(Cue.tokenFill), .foregroundColor: NSColor(Cue.token)], range: match.range)
            for brace in [match.range(at: 1), match.range(at: 3)] {
                storage.addAttributes([.foregroundColor: NSColor.clear, .font: NSFont.monospacedSystemFont(ofSize: 1, weight: .regular)], range: brace)
            }
        }
        storage.endEditing()
        textView.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
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
