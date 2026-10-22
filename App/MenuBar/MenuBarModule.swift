import CueKit
import SwiftUI

/// Hides, reveals, and arranges menu-bar items. Placeholder until the module is implemented.
@MainActor final class MenuBarModule {
    private let context: AppContext

    init(context: AppContext) { self.context = context }

    /// Opens storage, creates separators if enabled, and registers the hotkey. Never throws.
    func start() async {}

    /// Called before quit. Reveals hidden items so nothing stays off-screen after Cue exits.
    func stop() {}

    func commandView() -> AnyView {
        AnyView(EmptyStateView(symbol: "menubar.rectangle", title: "Menu bar items", message: "Not implemented yet."))
    }

    func settingsView() -> AnyView { AnyView(Text("Menu bar settings")) }

    /// Counts and settings only. Never window titles or other app content.
    func diagnostics() async -> [(String, String)] { [] }
}
