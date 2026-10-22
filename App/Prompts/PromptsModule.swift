import CueKit
import SwiftUI

/// The prompt library: palette, library window, editor, and paste delivery.
@MainActor final class PromptsModule {
    private let context: AppContext

    init(context: AppContext) { self.context = context }

    func start() async {}
    func stop() {}
    func commandView() -> AnyView { AnyView(EmptyStateView(symbol: "text.cursor", title: "Prompts", message: "Loading")) }
    func settingsView() -> AnyView { AnyView(Text("Prompts settings")) }
    func generalSettingsView() -> AnyView { AnyView(Text("General")) }
    func openLibrary(_ actionID: String?) {}
    /// Returns false when unsaved edits need a decision first.
    func canQuit() -> Bool { true }
    func diagnostics() async -> [(String, String)] { [] }
}
