import AppKit
import CueKit
import SwiftUI

private struct DetailCard: View {
    var content: AttributedString
    var monospaced = false

    var body: some View {
        Text(content)
            .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 12.5))
            .lineSpacing(4)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Cue.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Cue.hairline) }
    }
}

private struct DetailPage<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) { content() }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ActionDetail: View {
    let action: Action
    let model: PromptsModel
    let clipboard: ClipboardModule

    private var delivery: String {
        guard model.willPaste(action, copyOnly: false) else { return "Copy" }
        return model.context.invocation?.front?.localizedName.map { "Paste → \($0)" } ?? "Paste"
    }

    var body: some View {
        DetailPage {
            VStack(alignment: .leading, spacing: 8) {
                Text(action.name).font(.system(size: 16, weight: .semibold))
                FlowLayout {
                    if action.ai == true { Chip(text: "Claude", style: .claude) }
                    Chip(text: delivery)
                    if let category = action.category { Chip(text: category) }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Prompt")
                DetailCard(content: .template(action.template), monospaced: true)
            }
            if (try? Template.needsClipboard(action.template)) == true, let item = clipboard.latest {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        SectionLabel(text: "clipboard")
                        Spacer()
                        Text(([item.source.map(clipboard.appName), ShortAge.text(item.lastUsedAt), item.sizeLabel] as [String?]).compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    DetailCard(content: AttributedString(String(item.display.prefix(600))))
                }
            }
        }
    }
}

struct SnippetDetail: View {
    let snippet: Snippet

    var body: some View {
        DetailPage {
            Text(snippet.keyword).font(.system(size: 16, weight: .semibold))
            Chip(text: "Snippet")
            DetailCard(content: .template(snippet.template), monospaced: true)
        }
    }
}

struct ScriptDetail: View {
    let script: Script
    let timeout: Int

    var body: some View {
        DetailPage {
            Text(script.name).font(.system(size: 16, weight: .semibold))
            Chip(text: "Script")
            DetailRows(rows: [
                ("File", script.url.lastPathComponent),
                ("Folder", (script.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath),
                ("Stops after", "\(timeout) seconds"),
            ])
        }
    }
}

struct WindowDetail: View {
    let command: WindowCommand
    let shortcut: Shortcut?

    var body: some View {
        DetailPage {
            Text(command.title).font(.system(size: 16, weight: .semibold))
            Chip(text: "Window")
            DetailRows(rows: [("Applies to", "The window in front"), ("Shortcut", shortcut?.display ?? "None")])
        }
    }
}

struct FileDetail: View {
    let hit: FileHit
    @State private var details: FileDetails?

    private var running: Bool {
        guard hit.isApp, let id = Bundle(url: hit.url)?.bundleIdentifier else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
    }

    var body: some View {
        DetailPage {
            HStack(spacing: 14) {
                FileIcon(path: hit.url.path, size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(hit.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                    Text(details?.kind ?? " ").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            CardDivider()
            if let details {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    row("Location", details.location, monospaced: true)
                    if let version = details.version { row("Version", version) }
                    if let size = details.size { row("Size", size) }
                    if let opened = details.lastOpened { row("Last opened", opened.formatted(.relative(presentation: .named))) }
                    if hit.isApp {
                        GridRow {
                            label("Running")
                            HStack(spacing: 6) {
                                StatusDot(color: running ? Cue.success : Color.primary.opacity(0.2))
                                Text(running ? "Yes" : "No")
                            }
                        }
                    }
                }
                .font(.system(size: 12))
            }
        }
        .task(id: hit.id) {
            details = nil
            let loaded = await FileInfo.load(hit)
            if !Task.isCancelled { details = loaded }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
    }

    private func row(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        GridRow {
            label(title)
            Text(value).font(monospaced ? .system(size: 12, design: .monospaced) : nil).lineLimit(2).textSelection(.enabled)
        }
    }
}
