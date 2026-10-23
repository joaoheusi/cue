import AppKit
import CueKit

/// Cue's two separator status items. A separator hides everything to its left by growing to
/// 10,000 points, which pushes those items off-screen. Its right edge stays where it is.
/// Neither item is ever removed: removal makes macOS forget a saved position.
@MainActor final class MenuBarSeparators: NSObject {
    enum Mode { case collapsed, revealed, revealedAll }

    private static let width: CGFloat = 24
    private static let expanded: CGFloat = 10_000

    private let hidden: NSStatusItem
    private let alwaysHidden: NSStatusItem
    private let chevron = NSImageView()
    private let marker = NSImageView()
    /// `option` is true for ⌥-click.
    var onClick: (_ option: Bool) -> Void = { _ in }
    private(set) var mode: Mode = .revealedAll

    /// Create after Cue's own icon. New status items appear to the left of existing ones.
    override init() {
        hidden = NSStatusBar.system.statusItem(withLength: Self.width)
        alwaysHidden = NSStatusBar.system.statusItem(withLength: Self.width)
        super.init()
        hidden.autosaveName = "cue.menuBar.hidden"
        alwaysHidden.autosaveName = "cue.menuBar.alwaysHidden"
        // `isVisible` is persisted by macOS, so set it on every launch.
        hidden.isVisible = true
        alwaysHidden.isVisible = true
        install(chevron, in: hidden, identifier: "menuBar.separator.hidden")
        install(marker, in: alwaysHidden, identifier: "menuBar.separator.alwaysHidden")
        marker.image = NSImage(systemSymbolName: "chevron.compact.left", accessibilityDescription: nil)
        alwaysHidden.button?.setAccessibilityLabel("Always-hidden menu bar items start left of here")
        apply(.revealedAll)
    }

    /// Pins the glyph to the trailing edge so it stays on-screen while the item is 10,000 points wide.
    private func install(_ view: NSImageView, in item: NSStatusItem, identifier: String) {
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp])
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
        // If the user dragged the always-hidden separator right of the chevron, collapsing it
        // would push the chevron off-screen. Keep it open so the chevron stays reachable.
        let misplaced = frames.map { $0.alwaysHidden.maxX > $0.hidden.maxX } ?? false
        hidden.length = mode == .collapsed ? Self.expanded : Self.width
        alwaysHidden.length = mode == .revealedAll || misplaced ? Self.width : Self.expanded
        marker.isHidden = alwaysHidden.length == Self.expanded
        let collapsed = mode == .collapsed
        chevron.image = NSImage(systemSymbolName: collapsed ? "chevron.left" : "chevron.right", accessibilityDescription: nil)
        hidden.button?.setAccessibilityLabel(collapsed ? "Show hidden menu bar items" : "Hide menu bar items")
    }

    /// Global frames, or nil before AppKit has placed the items.
    var frames: MenuBarSeparatorFrames? {
        guard let a = hidden.button?.window?.frame, let b = alwaysHidden.button?.window?.frame else { return nil }
        return MenuBarSeparatorFrames(hidden: MenuBarSpan(minX: a.minX, maxX: a.maxX), alwaysHidden: MenuBarSpan(minX: b.minX, maxX: b.maxX))
    }
}
