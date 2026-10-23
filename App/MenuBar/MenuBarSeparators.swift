import AppKit
import CueKit

@MainActor final class MenuBarSeparators: NSObject {
    enum Mode { case collapsed, revealed, revealedAll }

    private static let width: CGFloat = 24
    private static let expanded: CGFloat = 10_000

    private let hidden: NSStatusItem
    private let alwaysHidden: NSStatusItem
    private let chevron = NSImageView()
    private let marker = NSImageView()
    var onClick: (_ option: Bool) -> Void = { _ in }
    private(set) var mode: Mode = .revealedAll

    override init() {
        hidden = NSStatusBar.system.statusItem(withLength: Self.width)
        alwaysHidden = NSStatusBar.system.statusItem(withLength: Self.width)
        super.init()
        hidden.autosaveName = "cue.menuBar.hidden"
        alwaysHidden.autosaveName = "cue.menuBar.alwaysHidden"
        hidden.isVisible = true
        alwaysHidden.isVisible = true
        install(chevron, in: hidden, identifier: "menuBar.separator.hidden")
        install(marker, in: alwaysHidden, identifier: "menuBar.separator.alwaysHidden")
        hidden.button?.target = self
        hidden.button?.action = #selector(clicked)
        hidden.button?.sendAction(on: [.leftMouseUp])
        marker.image = NSImage(systemSymbolName: "chevron.compact.left", accessibilityDescription: nil)
        alwaysHidden.button?.setAccessibilityLabel("Always-hidden menu bar items start left of here")
        apply(.revealedAll)
    }

    private func install(_ view: NSImageView, in item: NSStatusItem, identifier: String) {
        guard let button = item.button else { return }
        button.setAccessibilityIdentifier(identifier)
        view.frame = NSRect(x: button.bounds.width - 20, y: 0, width: 16, height: button.bounds.height)
        view.autoresizingMask = [.minXMargin, .height]
        view.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        button.addSubview(view)
    }

    @objc private func clicked() {
        onClick(NSApp.currentEvent?.modifierFlags.contains(.option) ?? false)
    }

    func setVisible(_ visible: Bool) {
        if !visible { apply(.revealedAll) }
        hidden.isVisible = visible
        alwaysHidden.isVisible = visible
    }

    func apply(_ mode: Mode) {
        self.mode = mode
        let misplaced = frames.map { $0.alwaysHidden.maxX > $0.hidden.maxX } ?? false
        hidden.length = mode == .collapsed ? Self.expanded : Self.width
        alwaysHidden.length = mode == .revealedAll || misplaced ? Self.width : Self.expanded
        marker.isHidden = alwaysHidden.length == Self.expanded
        let collapsed = mode == .collapsed
        chevron.image = NSImage(systemSymbolName: collapsed ? "chevron.left" : "chevron.right", accessibilityDescription: nil)
        hidden.button?.setAccessibilityLabel(collapsed ? "Show hidden menu bar items" : "Hide menu bar items")
    }

    var frames: MenuBarSeparatorFrames? {
        guard let a = hidden.button?.window?.frame, let b = alwaysHidden.button?.window?.frame else { return nil }
        return MenuBarSeparatorFrames(hidden: MenuBarSpan(minX: a.minX, maxX: a.maxX), alwaysHidden: MenuBarSpan(minX: b.minX, maxX: b.maxX))
    }
}
