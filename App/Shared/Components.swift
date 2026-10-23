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
    var onChange: (Shortcut?) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(recording ? "Press a shortcut…" : (value?.display ?? "Record Shortcut")) {
                recording ? stop() : start()
            }
            .frame(minWidth: 140)
            if value != nil && !recording {
                Button("Clear") { onChange(nil) }
            }
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

struct CommandList<Item: Identifiable, Row: View>: View {
    @Binding var query: String
    var placeholder: String
    var items: [Item]
    @Binding var selection: Item.ID?
    var row: (Item, Bool) -> Row
    var onSubmit: (Item, _ alternate: Bool) -> Void
    var onKeyPress: ((Item, KeyPress) -> KeyPress.Result)?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .padding(.leading, 18)
                .padding(.trailing, CommandMetrics.switcherWidth)
                .frame(height: CommandMetrics.searchHeight)
                .focused($focused)
                .accessibilityIdentifier("command.search")
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.return, phases: .down) { press in
                    guard let item = current else { return .ignored }
                    onSubmit(item, press.modifiers.contains(.shift))
                    return .handled
                }
                .onKeyPress(phases: .down) { press in
                    guard let item = current, let onKeyPress else { return .ignored }
                    return onKeyPress(item, press)
                }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            row(item, item.id == selection)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { onSubmit(item, false) }
                                .onTapGesture { selection = item.id }
                                .id(item.id)
                                .accessibilityIdentifier("command.row")
                                .accessibilityAddTraits(item.id == selection ? .isSelected : [])
                        }
                    }
                    .padding(8)
                }
                .onChange(of: selection) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
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

    private var current: Item? { items.first { $0.id == selection } }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard !items.isEmpty else { return .handled }
        let index = items.firstIndex { $0.id == selection } ?? (delta > 0 ? -1 : 0)
        selection = items[(index + delta + items.count) % items.count].id
        return .handled
    }
}

enum CommandMetrics {
    static let searchHeight: CGFloat = 56
    static let switcherWidth: CGFloat = 190
}

struct CommandRow<Accessory: View>: View {
    var title: String
    var subtitle: String?
    var symbol: String
    var selected: Bool
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(selected ? .primary : .secondary)
                .frame(width: 20)
            Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1).layoutPriority(1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            accessory().font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(selected ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(Color.primary.opacity(0.03))
        .overlay(alignment: .top) { Divider() }
    }
}

struct KeyHint: View {
    var label: String
    var keys: [String]

    var body: some View {
        HStack(spacing: 3) {
            Text(label).padding(.trailing, 3)
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 10, weight: .medium))
                    .frame(minWidth: 17, minHeight: 17)
                    .padding(.horizontal, 2)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.primary.opacity(0.08)) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
