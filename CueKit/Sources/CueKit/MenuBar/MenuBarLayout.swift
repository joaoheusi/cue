import CoreGraphics
import Foundation

public enum MenuBarSection: String, Codable, CaseIterable, Sendable {
    case alwaysHidden, hidden, visible

    public var title: String {
        switch self {
        case .alwaysHidden: "Always Hidden"
        case .hidden: "Hidden"
        case .visible: "Visible"
        }
    }

    public func shifted(_ delta: Int) -> MenuBarSection {
        let all = Self.allCases
        let index = all.firstIndex(of: self)! + delta
        return all[max(0, min(all.count - 1, index))]
    }
}

public struct MenuBarSpan: Equatable, Sendable {
    public var minX: Double
    public var maxX: Double
    public var midX: Double { (minX + maxX) / 2 }

    public init(minX: Double, maxX: Double) {
        self.minX = minX
        self.maxX = maxX
    }
}

public struct MenuBarSeparatorFrames: Equatable, Sendable {
    public var hidden: MenuBarSpan
    public var alwaysHidden: MenuBarSpan

    public init(hidden: MenuBarSpan, alwaysHidden: MenuBarSpan) {
        self.hidden = hidden
        self.alwaysHidden = alwaysHidden
    }
}

public struct MenuBarItem: Equatable, Sendable, Identifiable {
    public var key: String
    public var bundleID: String
    public var appName: String
    public var label: String
    public var frame: MenuBarSpan
    public var movable: Bool
    public var id: String { key }

    public init(key: String, bundleID: String, appName: String, label: String, frame: MenuBarSpan, movable: Bool) {
        self.key = key
        self.bundleID = bundleID
        self.appName = appName
        self.label = label
        self.frame = frame
        self.movable = movable
    }
}

public struct MenuBarDisplay: Equatable, Sendable {
    public var frame: CGRect
    public var notch: ClosedRange<CGFloat>?

    public init(frame: CGRect, notch: ClosedRange<CGFloat>? = nil) {
        self.frame = frame
        self.notch = notch
    }
}

public struct MenuBarRule: Codable, Equatable, Sendable, Identifiable {
    public var key: String
    public var bundleID: String
    public var label: String
    public var section: MenuBarSection
    public var id: String { key }

    public init(key: String, bundleID: String, label: String, section: MenuBarSection) {
        self.key = key
        self.bundleID = bundleID
        self.label = label
        self.section = section
    }
}

public struct MenuBarSettings: Equatable, Sendable {
    public static let defaultShortcut = "Super+Alt+H"

    public var enabled = false
    public var autoRehideSeconds = 10
    public var revealApps: [String] = []
    public var shortcut: String? = defaultShortcut

    public init() {}
}

public struct MenuBarMove: Equatable, Sendable {
    public var key: String
    public var from: MenuBarSection
    public var to: MenuBarSection

    public init(key: String, from: MenuBarSection, to: MenuBarSection) {
        self.key = key
        self.from = from
        self.to = to
    }
}

public enum MenuBarLayout {
    public static func section(of item: MenuBarSpan, separators: MenuBarSeparatorFrames) -> MenuBarSection {
        if item.midX >= separators.hidden.maxX { return .visible }
        if item.midX >= separators.alwaysHidden.maxX { return .hidden }
        return .alwaysHidden
    }

    public static func plan(items: [MenuBarItem], separators: MenuBarSeparatorFrames, rules: [MenuBarRule]) -> [MenuBarMove] {
        let targets = Dictionary(rules.map { ($0.key, $0.section) }, uniquingKeysWith: { _, last in last })
        let pending: [(item: MenuBarItem, move: MenuBarMove)] = items.compactMap { item in
            guard item.movable, let target = targets[item.key] else { return nil }
            let current = section(of: item.frame, separators: separators)
            return current == target ? nil : (item, MenuBarMove(key: item.key, from: current, to: target))
        }
        let order = MenuBarSection.allCases
        return pending.sorted { a, b in
            if a.move.to != b.move.to { return order.firstIndex(of: a.move.to)! < order.firstIndex(of: b.move.to)! }
            return a.move.to == .visible ? a.item.frame.midX > b.item.frame.midX : a.item.frame.midX < b.item.frame.midX
        }.map(\.move)
    }

    public static func dropX(for target: MenuBarSection, separators: MenuBarSeparatorFrames) -> Double {
        switch target {
        case .visible: separators.hidden.maxX + 2
        case .hidden: separators.hidden.minX + 2
        case .alwaysHidden: separators.alwaysHidden.minX + 2
        }
    }

    public static func clickPoint(for item: CGRect, displays: [MenuBarDisplay], barHeight: CGFloat) -> CGPoint? {
        let point = CGPoint(x: item.midX, y: item.midY)
        for display in displays where (display.frame.minX..<display.frame.maxX).contains(point.x) {
            guard (display.frame.minY..<display.frame.minY + barHeight).contains(point.y) else { continue }
            return display.notch?.contains(point.x) == true ? nil : point
        }
        return nil
    }

    public static func isExposed(_ section: MenuBarSection, separators: MenuBarSeparatorFrames) -> Bool {
        func collapsed(_ span: MenuBarSpan) -> Bool { span.maxX - span.minX < expandedSeparatorWidth }
        return switch section {
        case .visible: true
        case .hidden: collapsed(separators.hidden)
        case .alwaysHidden: collapsed(separators.hidden) && collapsed(separators.alwaysHidden)
        }
    }

    public static func isAnchored(_ window: CGRect, to item: CGPoint, barHeight: CGFloat) -> Bool {
        window.height > barHeight && window.minY <= item.y + barHeight && (window.minX...window.maxX).contains(item.x)
    }

    private static let expandedSeparatorWidth = 100.0

    public static func keys(for raw: [(bundleID: String, identifier: String?, title: String?, description: String?)]) -> [String] {
        var indexInApp: [String: Int] = [:]
        var seen: [String: Int] = [:]
        return raw.map { entry in
            let index = indexInApp[entry.bundleID, default: 0]
            indexInApp[entry.bundleID] = index + 1
            let suffix: String
            if let value = nonEmpty(entry.identifier) { suffix = "id:\(value)" }
            else if let value = nonEmpty(entry.title) { suffix = "title:\(value)" }
            else if let value = nonEmpty(entry.description) { suffix = "desc:\(value)" }
            else { suffix = "index:\(index)" }
            let base = "\(entry.bundleID)|\(suffix)"
            let count = seen[base, default: 0]
            seen[base] = count + 1
            return count == 0 ? base : "\(base)#\(count + 1)"
        }
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

public enum MenuBarRules {
    public static func upsert(_ rule: MenuBarRule, into rules: [MenuBarRule]) -> [MenuBarRule] {
        var result = rules
        if let index = result.firstIndex(where: { $0.key == rule.key }) { result[index] = rule } else { result.append(rule) }
        return result
    }

    public static func rule(for item: MenuBarItem, in rules: [MenuBarRule]) -> MenuBarRule? {
        rules.first { $0.key == item.key }
    }
}

public enum MenuBarReveal {
    public enum Cause: Sendable { case user, frontmostApp }

    public static func onFrontmostChange(bundleID: String?, revealApps: [String], revealedBy: Cause?) -> Bool? {
        if let bundleID, revealApps.contains(bundleID) { return revealedBy == nil ? true : nil }
        return revealedBy == .frontmostApp ? false : nil
    }

    public static func shouldRehide(now: Date, revealedAt: Date, seconds: Int, cause: Cause, pointerInMenuBar: Bool, itemOpen: Bool = false) -> Bool {
        guard seconds > 0, cause == .user, !pointerInMenuBar, !itemOpen else { return false }
        return now.timeIntervalSince(revealedAt) >= Double(seconds)
    }
}

public enum MenuBarValidation {
    public static let maxRehideSeconds = 3600

    public static func isBundleID(_ text: String) -> Bool {
        text.utf8.count <= 255 && text.wholeMatch(of: /[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+/) != nil
    }

    public static func rehideSeconds(_ text: String) throws(CueError) -> Int {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)), (0...maxRehideSeconds).contains(value) else {
            throw .validation("Enter a whole number of seconds from 0 to \(maxRehideSeconds). Use 0 to turn auto-hide off.")
        }
        return value
    }
}
