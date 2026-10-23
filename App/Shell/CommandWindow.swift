import AppKit
import CueKit
import SwiftUI

final class CommandPanel: NSPanel {
    var onCancel: () -> Void = {}

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 680, height: 480),
                   styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
                   backing: .buffered, defer: true)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
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
        panel.contentViewController = NSHostingController(rootView: CommandRoot(state: state, content: content))
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
        if !panel.isVisible || !panel.isKeyWindow {
            context.invocation = Invocation(target: context.isUITesting ? .failure(PasteFailure.targetUnavailable.error) : context.paste.capture())
            state.openID = UUID()
            if !panel.isVisible { position() }
        }
        state.scope = scope
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
    let content: (CommandScope) -> AnyView

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(Array(CommandScope.allCases.enumerated()), id: \.element) { index, scope in
                    Button {
                        state.scope = scope
                    } label: {
                        Label(scope.title, systemImage: scope.symbol)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(state.scope == scope ? Color.accentColor.opacity(0.2) : .clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    .help("\(scope.title) (⌘\(index + 1))")
                    .accessibilityIdentifier("scope.\(scope.rawValue)")
                }
                Spacer()
                Text("⌘1–3 switch · ↩ use · ⎋ close").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)
            content(state.scope)
                .id("\(state.scope.rawValue)-\(state.openID)")
        }
        .frame(minWidth: 480, minHeight: 320)
        .background(.regularMaterial)
    }
}
