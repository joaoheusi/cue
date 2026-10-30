import AppKit
import CueKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class SettingsWindowController {
    private var window: NSWindow?
    private var tabsController: NSTabViewController?
    private let pages: () -> [(SettingsTab, AnyView)]

    init(pages: @escaping () -> [(SettingsTab, AnyView)]) {
        self.pages = pages
    }

    func show(_ tab: SettingsTab) {
        if window == nil {
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            tabs.transitionOptions = []
            for (tab, view) in pages() {
                let host = NSHostingController(rootView: view)
                host.sizingOptions = []
                host.preferredContentSize = NSSize(width: 680, height: 640)
                host.title = tab.title
                let item = NSTabViewItem(viewController: host)
                item.label = tab.title
                item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
                item.identifier = tab.rawValue
                tabs.addTabViewItem(item)
            }
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.toolbarStyle = .preference
            window.contentMinSize = NSSize(width: 680, height: 420)
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("CueSettings")
            self.window = window
            tabsController = tabs
        }
        if let index = SettingsTab.allCases.firstIndex(of: tab) { tabsController?.selectedTabViewItemIndex = index }
        NSApp.takeFocus(window)
    }
}

struct PrivacySettingsView: View {
    let context: AppContext
    let diagnostics: () async -> String
    @State private var status: (String, Bool)?

    private let network: [(String, String, String)] = [
        ("api.anthropic.com", "Claude actions and key tests", "Action text"),
        ("github.com", "Update check, hourly", "Nothing"),
        ("Your scripts", "When run", "Their own"),
    ]

    var body: some View {
        SettingsPage {
            SettingsSection("Network") {
                columns(Text("Destination"), Text("When"), Text("Sends"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(height: 30)
                ForEach(network, id: \.0) { row in
                    CardDivider()
                    columns(Text(row.0).fontWeight(.medium), Text(row.1), Text(row.2)).frame(height: 37)
                }
                CardDivider()
                columns(Text("Accounts · sync · telemetry"), Text("None"), Text("")).foregroundStyle(.secondary).frame(height: 37)
            }
            SettingsSection("Local data") {
                HStack(spacing: 10) {
                    Text("Folder")
                    Text((context.dataDirectory.path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: context.dataDirectory, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([context.dataDirectory])
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                CardDivider()
                SettingsRow("Keychain", note: "Clipboard encryption key")
                CardDivider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Diagnostics")
                        Text("Versions, permissions, settings, counts, error codes").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Export…", action: exportDiagnostics)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            if let status { StatusLine(text: status.0, success: status.1) }
            CardList {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Uninstall Cue")
                        Text("Login item, LaunchAgent, Keychain keys, data folder, app").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Uninstall…", role: .destructive) { Uninstaller.run(context: context) }.foregroundStyle(.red)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
    }

    private func columns<A: View, B: View, C: View>(_ first: A, _ second: B, _ third: C) -> some View {
        HStack(spacing: 8) {
            first.frame(width: 170, alignment: .leading)
            second.frame(maxWidth: .infinity, alignment: .leading)
            third.frame(width: 110, alignment: .leading)
        }
        .padding(.horizontal, 14)
    }

    private func exportDiagnostics() {
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
}
