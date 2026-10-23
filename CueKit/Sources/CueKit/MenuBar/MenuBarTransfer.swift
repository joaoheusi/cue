import Foundation

/// The rules export file. `enabled` is not exported: importing must never change the menu bar by itself.
public enum MenuBarTransfer {
    public static let schemaVersion = 1
    public static let maxBytes = 1 << 20
    public static let maxRules = 2000
    public static let maxRevealApps = 100
    public static let maxLabelLength = 256
    public static let maxKeyLength = 1024

    public struct Settings: Codable, Equatable, Sendable {
        public var autoRehideSeconds: Int
        public var revealApps: [String]
        public var shortcut: String?
    }

    struct Document: Codable {
        var schemaVersion: Int
        var exportedAt: String
        var settings: Settings
        var rules: [MenuBarRule]
    }

    public static func encode(settings: MenuBarSettings, rules: [MenuBarRule], exportedAt: Date) throws -> Data {
        let document = Document(schemaVersion: schemaVersion, exportedAt: Timestamp.iso(exportedAt),
                                settings: Settings(autoRehideSeconds: settings.autoRehideSeconds, revealApps: settings.revealApps, shortcut: settings.shortcut),
                                rules: rules)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    /// Parses and validates an export. Throws a user-facing error naming the first problem.
    public static func decode(_ data: Data) throws(CueError) -> (settings: Settings, rules: [MenuBarRule]) {
        guard data.count <= maxBytes else { throw CueError("OUTPUT_TOO_LARGE", "The file is larger than 1 MB.") }
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            throw CueError("IMPORT_INVALID", "This file is not a Cue menu-bar rules export.")
        }
        guard document.schemaVersion == schemaVersion else {
            throw CueError("IMPORT_UNSUPPORTED", "This file uses a format this version of Cue cannot read.")
        }
        let settings = document.settings
        guard (0...MenuBarValidation.maxRehideSeconds).contains(settings.autoRehideSeconds) else {
            throw .validation("Auto-hide must be from 0 to \(MenuBarValidation.maxRehideSeconds) seconds.")
        }
        guard settings.revealApps.count <= maxRevealApps, settings.revealApps.allSatisfy(MenuBarValidation.isBundleID),
              Set(settings.revealApps).count == settings.revealApps.count else {
            throw .validation("The app list contains an invalid or repeated bundle ID.")
        }
        if let shortcut = settings.shortcut, Shortcut(shortcut) == nil {
            throw .validation("The shortcut in this file is not valid.")
        }
        guard document.rules.count <= maxRules else { throw .validation("The file has more than \(maxRules) rules.") }
        var keys = Set<String>()
        for (index, rule) in document.rules.enumerated() {
            let position = "Rule \(index + 1)"
            guard MenuBarValidation.isBundleID(rule.bundleID) else { throw .validation("\(position) has an invalid bundle ID.") }
            guard rule.key.count <= maxKeyLength, rule.key.hasPrefix("\(rule.bundleID)|"), rule.key.count > rule.bundleID.count + 1,
                  TextLimits.firstInvalidControl(in: rule.key) == nil else {
                throw .validation("\(position) has an invalid item key.")
            }
            guard rule.label.count <= maxLabelLength, TextLimits.firstInvalidControl(in: rule.label) == nil else {
                throw .validation("\(position) has an invalid label.")
            }
            guard keys.insert(rule.key).inserted else { throw .validation("\(position) repeats an item that appears earlier.") }
        }
        return (settings, document.rules)
    }
}
