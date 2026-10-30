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
        minSize = NSSize(width: 700, height: 420)
        setAccessibilityIdentifier("command.window")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel() }
}

@MainActor @Observable final class CommandState {
    var scope: CommandScope = .prompts
    var openID = UUID()
    var hidesSwitcher = false
}

struct HidesSwitcherKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
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
        panel.onCancel = { [weak self] in
            guard let self, !context.interceptCancel() else { return }
            hide(cancel: true)
        }
        let host = NSHostingController(rootView: CommandRoot(state: state, context: context, content: content))
        host.sizingOptions = [.minSize]
        panel.contentViewController = host
        panel.setContentSize(CommandMetrics.panelSize)
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
        if cancel, !context.keepsRunning() { context.invocation?.cancelled = true }
        hiding = true
        panel.orderOut(nil)
        hiding = false
        context.commandDidHide()
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
        case .prompts: .palette
        case .clipboard: .clipboard
        case .menuBar: .menuBar
        }
    }

    var body: some View {
        content(state.scope)
            .id("\(state.scope.rawValue)-\(state.openID)")
            .overlay(alignment: .topTrailing) { switcher }
            .onPreferenceChange(HidesSwitcherKey.self) { value in MainActor.assumeIsolated { state.hidesSwitcher = value } }
            .background { shortcuts }
            .frame(minWidth: 700, minHeight: 420)
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
        let options = CommandScope.allCases.enumerated().map { index, scope in
            Segmented<CommandScope>.Option(value: scope, title: scope.title, symbol: scope.symbol, key: "⌘\(index + 1)", identifier: "scope.\(scope.rawValue)")
        }
        return Segmented(options: options, selection: state.scope, height: 28) { state.scope = $0 }
            .background {
                ForEach(Array(CommandScope.allCases.enumerated()), id: \.element) { index, scope in
                    Button(scope.title) { state.scope = scope }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                        .opacity(0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: CommandMetrics.searchHeight)
            .padding(.trailing, 14)
            .opacity(state.hidesSwitcher ? 0 : 1)
            .allowsHitTesting(!state.hidesSwitcher)
            .accessibilityHidden(state.hidesSwitcher)
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
