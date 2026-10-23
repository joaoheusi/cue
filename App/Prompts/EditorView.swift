import AppKit
import CueKit
import SwiftUI

struct EditorView: View {
    let model: PromptsModel
    @Bindable var nav: LibraryNavigation
    let snapshot: LibrarySnapshot
    @State private var editor = TemplateEditorController()
    @State private var confirmDelete = false

    private static let sampleClipboard = "We should move the deploy to Thursday."

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
        let isNew = draft.revision == 0
        return Form {
            Section {
                TextField("Name", text: binding(\.name), prompt: Text("Resolve CI"))
                    .font(.title3)
                TextField("Description", text: binding(\.description), prompt: Text("What does this action do?"))
                HStack {
                    TextField("Category", text: Binding(get: { draft.category ?? "" }, set: { value in
                        nav.update { $0.category = value.isEmpty ? nil : value }
                    }), prompt: Text("No category"))
                    Menu("Choose") {
                        Button("No Category") { nav.update { $0.category = nil } }
                        ForEach(snapshot.categories, id: \.self) { name in
                            Button(name) { nav.update { $0.category = name } }
                        }
                    }
                    .fixedSize()
                }
                TextField("Aliases", text: Binding(get: { draft.aliases.joined(separator: ", ") }, set: { value in
                    nav.update { $0.aliases = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                }), prompt: Text("fix build, fix checks"))
            } header: {
                Text(isNew ? "New action · not saved" : (nav.isDirty ? "Unsaved changes" : "All changes saved"))
            }
            Section("Text") {
                TemplateEditor(text: binding(\.template), controller: editor)
                    .frame(minHeight: 180)
                HStack {
                    Menu("Add Variable") {
                        Button("Clipboard text — the clipboard when you run the action") { editor.insert("{{clipboard}}") }
                        Button("Date — the date when you run the action") { editor.insert("{{date}}") }
                        Button("Time — the time when you run the action") { editor.insert("{{time}}") }
                    }
                    .fixedSize()
                    Spacer()
                    Text("\(draft.template.utf8.count.formatted()) / 65,536 bytes").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("When used") {
                Picker("Delivery", selection: binding(\.deliveryMode)) {
                    Text("Default (\(snapshot.settings.defaultDelivery == .paste ? "Paste" : "Copy"))").tag(DeliveryMode.inherit)
                    Text("Copy").tag(DeliveryMode.copy)
                    Text("Paste").tag(DeliveryMode.paste)
                }
                Toggle("Favorite", isOn: binding(\.favorite))
                Toggle("Enabled", isOn: binding(\.enabled))
                LabeledContent("Shortcut") {
                    if isNew {
                        Text("Save the action to add a shortcut.").foregroundStyle(.secondary)
                    } else {
                        let owner = PromptsModel.owner(draft)
                        VStack(alignment: .trailing, spacing: 2) {
                            ShortcutRecorder(value: snapshot.bindings[owner].flatMap(Shortcut.init)) { shortcut in
                                Task { await model.setShortcut(shortcut, for: draft) }
                            }
                            if let error = model.context.hotKeys.statuses[owner]?.error {
                                Text(error).font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
            Section("Preview") {
                Text(preview(draft)).font(.callout.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Uses a sample in place of your clipboard. Your real clipboard is never read here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Revert") { nav.edit(nav.original) }.disabled(!nav.isDirty || isNew)
                Button("Copy") { Task { await model.copy(draft) } }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(isNew || nav.isDirty)
                    .help("Copy the rendered text (⇧⌘C)")
                Button("Duplicate") { Task { if let copy = await model.duplicate(draft) { nav.edit(copy) } } }.disabled(isNew)
                Button("Delete", role: .destructive) { confirmDelete = true }.disabled(isNew)
                Button("Save") { save() }
                    .keyboardShortcut("s")
                    .disabled(!nav.isDirty || validation != nil)
                    .help(validation?.message ?? "Save (⌘S)")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if nav.isDirty, let validation {
                ErrorBanner(error: validation).padding(8)
            }
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

    private func binding<T>(_ path: WritableKeyPath<Action, T>) -> Binding<T> {
        Binding(get: { nav.draft![keyPath: path] }, set: { value in nav.update { $0[keyPath: path] = value } })
    }

    private func preview(_ draft: Action) -> String {
        guard !draft.template.isEmpty else { return "Add text to preview this action." }
        do {
            return try Template.renderLocal(draft.template, clipboard: Self.sampleClipboard)
        } catch {
            return error.message
        }
    }

    private func save() {
        guard let draft = nav.draft else { return }
        Task {
            if let saved = await model.save(draft) { nav.edit(saved) }
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

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.string = text
        textView.delegate = context.coordinator
        textView.setAccessibilityIdentifier("editor.template")
        controller.textView = textView
        scroll.borderType = .bezelBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scroll.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
