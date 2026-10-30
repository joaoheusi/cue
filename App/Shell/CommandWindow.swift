import AppKit
import CueKit
import SwiftUI

final class CommandPanel: NSPanel {
    var onCancel: () -> Void = {}

    init() {
        super.init(contentRect: .zero,
                   styleMask: [.nonactivatingPanel, .borderless, .resizable],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        minSize = NSSize(width: 480, height: 320)
        setAccessibilityIdentifier("command.window")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel() }
}

@MainActor @Observable final class CommandState {
    var scope: CommandScope = .prompts
    var openID = UUID()
}

@MainActor final class CommandWindowController: NSObject, NSWindowDelegate {
    let panel = CommandPanel()
    let state = CommandState()
    private let context: AppContext
    private var hiding = false

    init(context: AppContext, content: @escaping (CommandScope) -> AnyView) {
        self.context = context
        super.init()
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.hide(cancel: true) }
        let host = NSHostingController(rootView: CommandRoot(state: state, context: context, content: content))
        host.sizingOptions = [.minSize]
        panel.contentViewController = host
        panel.setContentSize(NSSize(width: 750, height: 475))
        host.view.layoutSubtreeIfNeeded()
    }

    var isVisible: Bool { panel.isVisible }

    func toggle(_ scope: CommandScope) {
        if panel.isVisible && state.scope == scope && panel.isKeyWindow {
            hide(cancel: true)
        } else {
            show(scope)
        }
    }

    func show(_ scope: CommandScope) {
        let opening = !panel.isVisible || !panel.isKeyWindow
        var invocation: Invocation?
        if opening {
            invocation = Invocation(target: .failure(PasteFailure.targetUnavailable.error), front: NSWorkspace.shared.frontmostApplication)
            context.invocation = invocation
            state.openID = UUID()
            if !panel.isVisible { position() }
        }
        state.scope = scope
        if let invocation, !context.isUITesting {
            panel.orderFrontRegardless()
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            CATransaction.flush()
            invocation.target = context.paste.capture()
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func showPassively() {
        panel.orderFrontRegardless()
    }

    func hide(cancel: Bool) {
        if cancel { context.invocation?.cancelled = true }
        hiding = true
        panel.orderOut(nil)
        hiding = false
    }

    func windowDidResignKey(_ notification: Notification) {
        if panel.isVisible && !hiding && NSApp.modalWindow == nil && !context.isUITesting { hide(cancel: true) }
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        let size = NSSize(width: min(panel.frame.width, area.width * 0.9), height: min(panel.frame.height, area.height * 0.9))
        panel.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2 + area.height * 0.1, width: size.width, height: size.height), display: false)
    }
}

private struct CommandRoot: View {
    @Bindable var state: CommandState
    let context: AppContext
    let content: (CommandScope) -> AnyView

    private var settingsTab: SettingsTab {
        switch state.scope {
        case .prompts: .prompts
        case .clipboard: .clipboard
        case .menuBar: .menuBar
        }
    }

    var body: some View {
        content(state.scope)
            .id("\(state.scope.rawValue)-\(state.openID)")
            .overlay(alignment: .topTrailing) { switcher }
            .background { shortcuts }
            .frame(minWidth: 480, minHeight: 320)
            .background(PanelBackground())
            .clipShape(RoundedRectangle(cornerRadius: PanelBackground.radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: PanelBackground.radius, style: .continuous).strokeBorder(.primary.opacity(0.1))
            }
    }

    private var shortcuts: some View {
        ZStack {
            Button("New Action") { context.openLibrary("new") }.keyboardShortcut("n", modifiers: .command)
            Button("Settings") { context.openSettings(settingsTab) }.keyboardShortcut(",", modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var switcher: some View {
        HStack(spacing: 2) {
            ForEach(Array(CommandScope.allCases.enumerated()), id: \.element) { index, scope in
                let selected = state.scope == scope
                Button {
                    state.scope = scope
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: scope.symbol)
                        if selected { Text(scope.title) }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(selected ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.primary.opacity(selected ? 0.1 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected ? .primary : .secondary)
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .help("\(scope.title) (⌘\(index + 1))")
                .accessibilityLabel(scope.title)
                .accessibilityIdentifier("scope.\(scope.rawValue)")
            }
        }
        .frame(height: CommandMetrics.searchHeight)
        .padding(.trailing, 12)
    }
}

private struct PanelBackground: NSViewRepresentable {
    static let radius: CGFloat = 16

    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = Self.radius
            return glass
        }
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        let size = Self.radius * 2 + 1
        let mask = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: Self.radius, yRadius: Self.radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: Self.radius, left: Self.radius, bottom: Self.radius, right: Self.radius)
        mask.resizingMode = .stretch
        view.maskImage = mask
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
