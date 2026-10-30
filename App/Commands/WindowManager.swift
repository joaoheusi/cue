import AppKit
import ApplicationServices
import CueKit

@MainActor final class WindowManager {
    static let accessReason = "To move and resize windows, Cue changes the position and size of the front window."
    private static let maxHistory = 30

    private var history: [(window: AXUIElement, frame: CGRect)] = []

    func apply(_ command: WindowCommand, to app: NSRunningApplication?) -> CueError? {
        guard AXIsProcessTrusted() else { return CueError("PERMISSION_REQUIRED", "Cue needs Accessibility to move windows.") }
        guard let app, !app.isTerminated, app != .current else { return Self.unavailable }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.2)
        guard let window = Self.focusedWindow(application), let current = Self.frame(of: window) else { return Self.unavailable }
        let areas = Self.areas
        guard let index = WindowLayout.area(of: current, in: areas) else { return Self.unavailable }
        let next: CGRect?
        var restored: Int?
        switch command {
        case .restore:
            guard let entry = history.lastIndex(where: { CFEqual($0.window, window) }) else {
                return CueError("WINDOW_NO_HISTORY", "Cue has not moved this window yet.")
            }
            restored = entry
            next = history[entry].frame
        case .nextDisplay:
            guard areas.count > 1 else { return CueError("WINDOW_ONE_DISPLAY", "There is only one display.") }
            next = WindowLayout.moved(current, from: areas[index], to: areas[(index + 1) % areas.count])
        default:
            next = WindowLayout.frame(command, window: current, area: areas[index])
        }
        guard let next, Self.set(next, on: window, application: application) else { return Self.unavailable }
        if let restored {
            history.remove(at: restored)
        } else {
            history.append((window, current))
            if history.count > Self.maxHistory { history.removeFirst() }
        }
        return nil
    }

    private static let unavailable = CueError("WINDOW_UNAVAILABLE", "Cue could not move the front window. Full-screen windows and some system windows cannot be moved.")

    private static var areas: [CGRect] {
        guard let primary = NSScreen.screens.first else { return [] }
        return NSScreen.screens.map { screen in
            let area = screen.visibleFrame
            return CGRect(x: area.minX, y: primary.frame.maxY - area.maxY, width: area.width, height: area.height)
        }
    }

    private static func focusedWindow(_ application: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
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

    private static func set(_ frame: CGRect, on window: AXUIElement, application: AXUIElement) -> Bool {
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
        return sized && placed
    }
}
