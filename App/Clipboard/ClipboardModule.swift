import CueKit
import SwiftUI

/// Encrypted clipboard history. Placeholder until the module is implemented.
@MainActor final class ClipboardModule {
    private let context: AppContext

    init(context: AppContext) { self.context = context }

    /// Opens storage and registers the hotkey. Failures become visible state; this never throws.
    func start() async {}

    /// Called before quit. Stops capture and flushes pending writes.
    func stop() {}

    func commandView() -> AnyView {
        AnyView(EmptyStateView(symbol: "doc.on.clipboard", title: "Clipboard history", message: "Not implemented yet."))
    }

    func settingsView() -> AnyView { AnyView(Text("Clipboard settings")) }

    /// Counts and settings only. Never clipboard content.
    func diagnostics() async -> [(String, String)] { [] }
}
