import AppKit
import CueKit
import SwiftUI

@MainActor final class PromptsModule {
    let model: PromptsModel
    private let nav = LibraryNavigation()
    private var window: NSWindow?

    init(context: AppContext) { model = PromptsModel(context: context) }

    func start() async {
        await model.load()
        if case .loaded(let snapshot) = model.state, !snapshot.settings.onboarded, !model.context.isUITesting {
            openLibrary(nil)
        }
        if case .failed = model.state { openLibrary(nil) }
    }

    func stop() {}

    func commandView() -> AnyView { AnyView(PaletteView(model: model)) }
    func settingsView() -> AnyView { AnyView(PromptsSettingsView(model: model)) }
    func generalSettingsView() -> AnyView { AnyView(GeneralSettingsView(model: model)) }

    func openLibrary(_ actionID: String?) {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: LibraryView(model: model, nav: nav)))
            window.title = "Cue"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 1100, height: 780))
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("CueLibrary")
            self.window = window
        }
        if let actionID, let snapshot = model.snapshot { nav.select(actionID, in: snapshot) }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func canQuit() -> Bool {
        guard nav.isDirty else { return true }
        openLibrary(nil)
        let alert = NSAlert()
        alert.messageText = "Discard unsaved changes?"
        alert.informativeText = "Your saved action stays as it is. Changes in the editor will be lost."
        alert.addButton(withTitle: "Discard and Quit")
        alert.addButton(withTitle: "Keep Editing")
        return alert.runModal() == .alertFirstButtonReturn
    }

    var hasUnsavedChanges: Bool { nav.isDirty }

    func diagnostics() async -> [(String, String)] { model.diagnostics() }
}
