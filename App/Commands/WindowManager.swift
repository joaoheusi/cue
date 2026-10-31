import AppKit
import ApplicationServices
import CueKit

@MainActor final class WindowManager {
    static let accessReason = "To move and resize windows, Cue changes the position and size of the front window."
    private static let maxHistory = 30

    private var history: [(window: AXUIElement, frame: CGRect)] = []
    private var last: (window: AXUIElement, command: WindowCommand, frame: CGRect)?

    func apply(_ command: WindowCommand, to app: NSRunningApplication?) -> CueError? {
        guard AXIsProcessTrusted() else { return CueError("PERMISSION_REQUIRED", "Cue needs Accessibility to move windows.") }
        guard let app, !app.isTerminated, app != .current else { return Self.unavailable }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.2)
        let name = app.localizedName ?? "The front app"
        guard let window = Self.frontWindow(application) else { return CueError("WINDOW_NOT_FOUND", "\(name) has no window Cue can reach.") }
        let refused = CueError("WINDOW_REFUSED", "\(name) did not let Cue move its window. Full-screen windows and some system windows cannot be moved.")
        guard let current = Self.frame(of: window) else { return refused }
        let areas = Self.areas
        guard let index = WindowLayout.area(of: current, in: areas) else { return Self.unavailable }
        let next: CGRect?
        var landed = command
        var restored: Int?
        switch command {
        case .restore:
            guard let entry = history.lastIndex(where: { CFEqual($0.window, window) }) else {
                return CueError("WINDOW_NO_HISTORY", "Cue has not moved this window yet.")
            }
            restored = entry
            next = history[entry].frame
        case .nextDisplay, .previousDisplay:
            guard areas.count > 1 else { return CueError("WINDOW_ONE_DISPLAY", "There is only one display.") }
            let step = command == .nextDisplay ? 1 : areas.count - 1
            next = WindowLayout.moved(current, from: areas[index], to: areas[(index + step) % areas.count])
        default:
            var area = areas[index]
            if let across = command.repeatsAcrossDisplays, areas.count > 1, let last, last.command == command,
               last.frame == current, CFEqual(last.window, window) {
                landed = across.command
                area = areas[(index + across.step + areas.count) % areas.count]
            }
            next = WindowLayout.frame(landed, window: current, area: area)
        }
        guard let next, next == current || Self.set(next, on: window, from: current, application: application) else { return refused }
        if let restored {
            history.remove(at: restored)
        } else if next != current {
            history.append((window, current))
            if history.count > Self.maxHistory { history.removeFirst() }
        }
        last = (window, landed, Self.frame(of: window) ?? next)
        return nil
    }

    private static let unavailable = CueError("WINDOW_UNAVAILABLE", "Cue could not find a window to move.")

    private static var areas: [CGRect] {
        guard let primary = NSScreen.screens.first else { return [] }
        return NSScreen.screens.map { screen in
            let area = screen.visibleFrame
            return CGRect(x: area.minX, y: primary.frame.maxY - area.maxY, width: area.width, height: area.height)
        }.sorted { ($0.minX, $0.minY) < ($1.minX, $1.minY) }
    }

    private static func frontWindow(_ application: AXUIElement) -> AXUIElement? {
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(application, attribute as CFString, &value) == .success,
               let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                return (value as! AXUIElement)
            }
        }
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windows) == .success else { return nil }
        return (windows as? [AXUIElement])?.first
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    private static func set(_ frame: CGRect, on window: AXUIElement, from current: CGRect, application: AXUIElement) -> Bool {
        let enhanced = "AXEnhancedUserInterface" as CFString
        var value: CFTypeRef?
        let wasEnhanced = AXUIElementCopyAttributeValue(application, enhanced, &value) == .success && (value as? Bool) == true
        if wasEnhanced { AXUIElementSetAttributeValue(application, enhanced, kCFBooleanFalse) }
        defer { if wasEnhanced { AXUIElementSetAttributeValue(application, enhanced, kCFBooleanTrue) } }
        var origin = frame.origin, size = frame.size
        guard let position = AXValueCreate(.cgPoint, &origin), let extent = AXValueCreate(.cgSize, &size) else { return false }
        _ = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        let sized = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, extent) == .success
        let placed = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position) == .success
        // Fixed-size windows reject the size, and some apps report an error after applying a change.
        return sized || placed || (Self.frame(of: window) ?? current) != current
    }
}
