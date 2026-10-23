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

/// A recoverable error with an optional retry. Never shows raw system errors.
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

/// A short success or failure line at the bottom of a view.
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

/// Records a global shortcut. Escape cancels. The recorded chord must include ⌘, ⌃, or ⌥.
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

/// The keyboard-first list used by every command-window scope.
/// ↑/↓ move, Return submits, Shift-Return submits the alternate action, Escape closes the window.
struct CommandList<Item: Identifiable, Row: View>: View {
    @Binding var query: String
    var placeholder: String
    var items: [Item]
    @Binding var selection: Item.ID?
    var row: (Item, Bool) -> Row
    var onSubmit: (Item, _ alternate: Bool) -> Void
    /// Extra keys handled by the scope, for example ⌘P to pin.
    var onKeyPress: ((Item, KeyPress) -> KeyPress.Result)?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 20))
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
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
                    LazyVStack(spacing: 2) {
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
                    .padding(6)
                }
                .onChange(of: selection) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
        .onAppear {
            // Focus requested before the panel is key is ignored, so ask again on the next turn.
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
        // Wraps around, like the original palette.
        let index = items.firstIndex { $0.id == selection } ?? (delta > 0 ? -1 : 0)
        selection = items[(index + delta + items.count) % items.count].id
        return .handled
    }
}

/// Standard row styling for command lists.
struct CommandRow<Accessory: View>: View {
    var title: String
    var subtitle: String?
    var symbol: String
    var selected: Bool
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(selected ? .white : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).lineLimit(1).foregroundStyle(selected ? .white.opacity(0.8) : .secondary)
                }
            }
            Spacer(minLength: 8)
            accessory()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(selected ? .white : .primary)
        .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
    }
}
