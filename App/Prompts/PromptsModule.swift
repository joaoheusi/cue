import AppKit
import CueKit
import SwiftUI

@MainActor final class PromptsModule {
    let model: PromptsModel
    private let nav = LibraryNavigation()
    private var window: NSWindow?
    var commands: CommandsModule!

    init(context: AppContext) {
        model = PromptsModel(context: context)
        nav.save = { [model] in await model.save($0, quiet: true) }
    }

    func start() async {
        await model.load()
        if case .loaded(let snapshot) = model.state, !snapshot.settings.onboarded, !model.context.isUITesting {
            openLibrary(nil)
        }
        if case .failed = model.state { openLibrary(nil) }
    }

    func stop() {}

    func settingsView() -> AnyView { AnyView(PaletteSettingsView(model: model)) }
    func generalSettingsView() -> AnyView { AnyView(GeneralSettingsView(model: model)) }

    func openLibrary(_ actionID: String?) {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: LibraryView(model: model, commands: commands, nav: nav)))
            window.title = "Cue"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 1160, height: 740))
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("CueLibrary")
            self.window = window
        }
        if let actionID, let snapshot = model.snapshot {
            nav.filter = .all
            nav.query = ""
            nav.select(actionID, in: snapshot)
        }
        NSApp.takeFocus(window)
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
