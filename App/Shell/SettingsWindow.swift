import AppKit
import CueKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable final class SettingsSelection {
    var tab: SettingsTab = .general
}

/// The single settings screen. Each module contributes one tab.
@MainActor final class SettingsWindowController {
    private let selection = SettingsSelection()
    private var window: NSWindow?
    private let tabs: () -> [(SettingsTab, String, String, AnyView)]

    init(tabs: @escaping () -> [(SettingsTab, String, String, AnyView)]) {
        self.tabs = tabs
    }

    func show(_ tab: SettingsTab) {
        selection.tab = tab
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsRoot(selection: selection, tabs: tabs())))
            window.title = "Cue Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 640, height: 560))
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("CueSettings")
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SettingsRoot: View {
    @Bindable var selection: SettingsSelection
    let tabs: [(SettingsTab, String, String, AnyView)]

    var body: some View {
        TabView(selection: $selection.tab) {
            ForEach(tabs, id: \.0) { tab, title, symbol, view in
                view
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .tabItem { Label(title, systemImage: symbol) }
                    .tag(tab)
            }
        }
        .padding(12)
        .frame(minWidth: 560, minHeight: 460)
    }
}

/// Data location, diagnostics export, and uninstall steps. Shared by all modules.
struct DataSettingsView: View {
    let context: AppContext
    let diagnostics: () async -> String
    @State private var status: (String, Bool)?

    var body: some View {
        Form {
            Section("Local data") {
                LabeledContent("Folder") {
                    Text(context.dataDirectory.path).textSelection(.enabled).font(.caption.monospaced())
                }
                Text("Everything Cue stores stays in this folder and the macOS Keychain. Cue has no accounts, sync, telemetry, or analytics.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Show in Finder") {
                    try? FileManager.default.createDirectory(at: context.dataDirectory, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([context.dataDirectory])
                }
            }
            Section("Diagnostics") {
                Text("Exports versions, permission states, settings, item counts, and recent error codes. It never includes prompts, clipboard text, or menu-bar item names.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Export Diagnostics…") {
                    Task {
                        let report = await diagnostics()
                        do {
                            if try FileTransfer.save(Data(report.utf8), suggestedName: SafeFilename.make("Cue Diagnostics", ext: "txt", date: Date()), type: .plainText) {
                                status = ("Diagnostics exported.", true)
                            }
                        } catch {
                            status = (error.cueError.message, false)
                        }
                    }
                }
                if let status { StatusLine(text: status.0, success: status.1) }
            }
            Section("Uninstall") {
                Text(Self.uninstallNote).font(.callout).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }

    static let uninstallNote = """
    1. Choose Quit Cue from the menu bar.
    2. Turn off Launch at Login in General (or remove Cue in System Settings → General → Login Items).
    3. Remove Cue from System Settings → Privacy & Security → Accessibility and Paste.
    4. Delete Cue.app from Applications.
    5. Delete ~/Library/Application Support/app.cue.launcher (prompts, settings, clipboard history, backups).
    6. Delete the clipboard key: security delete-generic-password -s app.cue.launcher.clipboard
    """
}
