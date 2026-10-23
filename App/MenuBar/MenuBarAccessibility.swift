import AppKit
import ApplicationServices
import CueKit

struct ScannedItem: @unchecked Sendable, Identifiable {
    let element: AXUIElement
    var item: MenuBarItem
    let midY: Double
    var section: MenuBarSection = .visible
    var id: String { item.key }
}

@MainActor enum MenuBarAccess {
    private struct App: Sendable {
        let pid: pid_t
        let bundleID: String
        let name: String
    }

    private nonisolated static let fixedOwners: Set = ["com.apple.controlcenter", "com.apple.systemuiserver"]

    static func scan() async -> [ScannedItem] {
        let own = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> App? in
            guard app.processIdentifier != own, let id = app.bundleIdentifier else { return nil }
            return App(pid: app.processIdentifier, bundleID: id, name: app.localizedName ?? id)
        }
        return await Task.detached(priority: .userInitiated) { read(apps) }.value
    }

    private nonisolated static func read(_ apps: [App]) -> [ScannedItem] {
        var found: [(app: App, element: AXUIElement, frame: CGRect, identifier: String?, title: String?, description: String?)] = []
        for app in apps {
            let application = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(application, 0.1)
            guard let bar = element(application, "AXExtrasMenuBar") else { continue }
            AXUIElementSetMessagingTimeout(bar, 0.1)
            for child in attribute(bar, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                AXUIElementSetMessagingTimeout(child, 0.1)
                guard let frame = frame(child) else { continue }
                found.append((app, child, frame, attribute(child, "AXIdentifier") as? String,
                              attribute(child, kAXTitleAttribute) as? String, attribute(child, kAXDescriptionAttribute) as? String))
            }
        }
        let keys = MenuBarLayout.keys(for: found.map { ($0.app.bundleID, $0.identifier, $0.title, $0.description) })
        return zip(found, keys).map { entry, key in
            let label = [entry.title, entry.description].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
            let item = MenuBarItem(key: key, bundleID: entry.app.bundleID, appName: entry.app.name, label: label ?? entry.app.name,
                                   frame: MenuBarSpan(minX: entry.frame.minX, maxX: entry.frame.maxX),
                                   movable: !fixedOwners.contains(entry.app.bundleID))
            return ScannedItem(element: entry.element, item: item, midY: entry.frame.midY)
        }
    }

    static func press(_ item: ScannedItem) -> Bool {
        AXUIElementPerformAction(item.element, kAXPressAction as CFString) == .success
    }

    static func drag(from start: CGPoint, to end: CGPoint) async -> Bool {
        let saved = CGEvent(source: nil)?.location
        defer { if let saved { CGWarpMouseCursorPosition(saved) } }
        let source = CGEventSource(stateID: .hidSystemState)
        func post(_ type: CGEventType, _ point: CGPoint) -> Bool {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return false }
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
            return true
        }
        guard post(.mouseMoved, start) else { return false }
        try? await Task.sleep(for: .milliseconds(50))
        guard post(.leftMouseDown, start) else { return false }
        try? await Task.sleep(for: .milliseconds(150))
        for step in 1...12 {
            let t = Double(step) / 12
            _ = post(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y))
            try? await Task.sleep(for: .milliseconds(20))
        }
        try? await Task.sleep(for: .milliseconds(100))
        return post(.leftMouseUp, end)
    }

    private nonisolated static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private nonisolated static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private nonisolated static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent),
              extent.width > 0 else { return nil }
        return CGRect(origin: point, size: extent)
    }
}
