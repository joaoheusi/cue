import AppKit
import CueKit
import SwiftUI

enum LoadState<Value> {
    case loading
    case failed(CueError)
    case loaded(Value)
}

struct EmptyStateView: View {
    var symbol: String
    var title: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            if let actionTitle, let action {
                Button(actionTitle, action: action).padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

struct LoadingView: View {
    var label = "Loading…"
    var body: some View {
        ProgressView(label).controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorBanner: View {
    var error: CueError
    var retryTitle = "Try Again"
    var retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(error.message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let retry { Button(retryTitle, action: retry).controlSize(.small) }
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

struct StatusLine: View {
    var text: String
    var success: Bool
    var body: some View {
        Label(text, systemImage: success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .font(.callout)
            .foregroundStyle(success ? .green : .orange)
            .accessibilityIdentifier("command.status")
    }
}

struct ShortcutRecorder: View {
    var value: Shortcut?
    var dimmed = false
    var onChange: (Shortcut?) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "Press keys…" : (value?.display ?? "Record"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: value == nil ? .regular : .medium))
            .foregroundStyle(value == nil || recording || dimmed ? .secondary : .primary)
            if value != nil && !recording {
                Button { onChange(nil) } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 18, height: 18).background(Cue.fill, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear shortcut")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(width: 118, height: 26)
        .background(value == nil ? Color.clear : Cue.card, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(recording ? Color.accentColor : Color.primary.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: value == nil && !recording ? [3, 3] : []))
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 0x35 { stop(); return nil }
            let flags = event.modifierFlags
            if let shortcut = Shortcut(keyCode: event.keyCode, command: flags.contains(.command), control: flags.contains(.control),
                                       option: flags.contains(.option), shift: flags.contains(.shift)) {
                onChange(shortcut)
                stop()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

struct CommandList<Item: Identifiable, Row: View, Bar: View, Detail: View>: View {
    @Binding var query: String
    var placeholder: String
    var items: [Item]
    @Binding var selection: Item.ID?
    var header: (Item) -> String? = { _ in nil }
    var listWidth: CGFloat = CommandMetrics.listWidth
    var showsDetail = false
    @ViewBuilder var row: (Item, Bool) -> Row
    @ViewBuilder var bar: () -> Bar
    @ViewBuilder var detail: () -> Detail
    var onSubmit: (Item, _ alternate: Bool) -> Void
    var onKeyPress: ((Item?, KeyPress) -> KeyPress.Result)?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundStyle(.secondary)
                TextField(placeholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 19))
                    .focused($focused)
                    .accessibilityIdentifier("command.search")
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.upArrow) { move(-1) }
                    .onKeyPress(.return, phases: .down) { press in
                        guard let item = current else { return .ignored }
                        onSubmit(item, !press.modifiers.isDisjoint(with: [.shift, .command]))
                        return .handled
                    }
                    .onKeyPress(phases: .down) { press in onKeyPress?(current, press) ?? .ignored }
            }
            .padding(.leading, 20)
            .padding(.trailing, CommandMetrics.switcherWidth)
            .frame(height: CommandMetrics.searchHeight)
            bar()
            Rectangle().fill(Cue.hairline).frame(height: 1)
            HStack(spacing: 0) {
                list
                    .frame(width: showsDetail ? listWidth : nil)
                    .frame(maxWidth: showsDetail ? nil : .infinity)
                if showsDetail {
                    Rectangle().fill(Cue.hairline).frame(width: 1)
                    detail().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(Color.primary.opacity(0.012))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .background {
            Button("Copy") { if let current { onSubmit(current, true) } }
                .keyboardShortcut(.return, modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onAppear {
            focused = true
            DispatchQueue.main.async { focused = true }
            if current == nil { selection = items.first?.id }
        }
        .onChange(of: items.map(\.id)) { _, ids in
            if selection == nil || !ids.contains(where: { $0 == selection }) { selection = ids.first }
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(items) { item in
                        if let title = header(item) {
                            SectionLabel(text: title)
                                .padding(.horizontal, 10)
                                .padding(.top, 8)
                                .padding(.bottom, 3)
                        }
                        row(item, item.id == selection)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { onSubmit(item, false) }
                            .onTapGesture { selection = item.id }
                            .id(item.id)
                            .accessibilityIdentifier("command.row")
                            .accessibilityAddTraits(item.id == selection ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .onChange(of: selection) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private var current: Item? { items.first { $0.id == selection } }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard !items.isEmpty else { return .handled }
        let index = items.firstIndex { $0.id == selection } ?? (delta > 0 ? -1 : 0)
        selection = items[(index + delta + items.count) % items.count].id
        return .handled
    }
}

enum CommandMetrics {
    static let searchHeight: CGFloat = 60
    static let switcherWidth: CGFloat = 340
    static let listWidth: CGFloat = 430
    static let panelSize = NSSize(width: 820, height: 540)
}

struct CommandRow<Leading: View, Accessory: View>: View {
    var title: String
    var subtitle: String?
    var selected: Bool
    var monospaced = false
    var match = ""
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 10) {
            leading()
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(AttributedString.highlighted(title, matching: match))
                    .font(monospaced ? .system(size: 12.5, design: .monospaced) : .system(size: 13.5, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                    .layoutPriority(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            accessory().font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(selected ? Cue.selection : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct CommandFooter<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 14) {
            leading()
            Spacer(minLength: 8)
            trailing()
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.leading, 20)
        .padding(.trailing, 14)
        .frame(height: 40)
        .overlay(alignment: .top) { Rectangle().fill(Cue.hairline).frame(height: 1) }
    }
}

struct KeyHint: View {
    var label: String
    var keys: String
    var primary = false
    var dimmed = false

    var body: some View {
        HStack(spacing: 6) {
            Text(label).fontWeight(primary ? .semibold : .regular).foregroundStyle(primary ? .primary : dimmed ? .tertiary : .secondary)
            Key(text: keys, dimmed: dimmed)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ActionsHint: View {
    var action: () -> Void

    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 16)
        Button(action: action) { KeyHint(label: "Actions", keys: "⌘K") }
            .buttonStyle(.plain)
            .keyboardShortcut("k", modifiers: .command)
    }
}

struct DetailRows: View {
    var rows: [(String, String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            ForEach(rows, id: \.0) { label, value in
                GridRow {
                    Text(label).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
                    Text(value).lineLimit(2).textSelection(.enabled)
                }
            }
        }
        .font(.system(size: 12))
    }
}
