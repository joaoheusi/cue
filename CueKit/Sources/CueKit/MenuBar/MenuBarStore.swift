import Foundation

/// Menu-bar settings and placement rules in `menubar.sqlite3`. Every failure maps to a `CueError`.
public actor MenuBarStore {
    public static let version = 1
    private let db: SQLite

    public init(url: URL) throws(CueError) {
        do {
            let db = try SQLite(path: url)
            let current = try db.userVersion()
            guard current <= Self.version else {
                throw CueError("STORAGE_NEWER", "Menu bar data was saved by a newer version of Cue. Update Cue to use it. Your data has not been changed.")
            }
            if current < 1 {
                try db.transaction {
                    try db.executeScript("""
                    CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                    CREATE TABLE rules(key TEXT PRIMARY KEY, bundle_id TEXT NOT NULL, label TEXT NOT NULL,
                                       section TEXT NOT NULL, updated_at TEXT NOT NULL);
                    PRAGMA user_version = 1;
                    """)
                }
            }
            self.db = db
        } catch {
            throw error.cueError
        }
    }

    public func load() throws(CueError) -> (settings: MenuBarSettings, rules: [MenuBarRule]) {
        do {
            var values: [String: String] = [:]
            for row in try db.query("SELECT key, value FROM settings") {
                if let key = row[0].string, let value = row[1].string { values[key] = value }
            }
            // Unreadable values fall back to defaults instead of failing the whole load.
            var settings = MenuBarSettings()
            if let value = values["enabled"] { settings.enabled = value == "1" }
            if let value = values["auto_rehide_seconds"].flatMap(Int.init), (0...MenuBarValidation.maxRehideSeconds).contains(value) {
                settings.autoRehideSeconds = value
            }
            if let value = values["reveal_apps"], let apps = try? JSONDecoder().decode([String].self, from: Data(value.utf8)) {
                settings.revealApps = apps.filter(MenuBarValidation.isBundleID)
            }
            if let value = values["shortcut"] { settings.shortcut = value.isEmpty ? nil : value }
            let rules = try db.query("SELECT key, bundle_id, label, section FROM rules ORDER BY rowid").compactMap { row -> MenuBarRule? in
                guard let key = row[0].string, let bundleID = row[1].string, let label = row[2].string,
                      let section = row[3].string.flatMap(MenuBarSection.init(rawValue:)) else { return nil }
                return MenuBarRule(key: key, bundleID: bundleID, label: label, section: section)
            }
            return (settings, rules)
        } catch {
            throw error.cueError
        }
    }

    public func save(_ settings: MenuBarSettings) throws(CueError) {
        do {
            try db.transaction { try write(settings) }
        } catch {
            throw error.cueError
        }
    }

    public func upsert(_ rule: MenuBarRule) throws(CueError) {
        do {
            try write(rule)
        } catch {
            throw error.cueError
        }
    }

    public func deleteRule(key: String) throws(CueError) {
        do {
            try db.execute("DELETE FROM rules WHERE key = ?1", [.text(key)])
        } catch {
            throw error.cueError
        }
    }

    /// Merges imported rules (same key wins from the file) and settings in one transaction.
    /// Keeps `enabled` as it is.
    public func importConfig(settings imported: MenuBarTransfer.Settings, rules: [MenuBarRule]) throws(CueError) {
        do {
            try db.transaction {
                var settings = try load().settings
                settings.autoRehideSeconds = imported.autoRehideSeconds
                settings.revealApps = imported.revealApps
                settings.shortcut = imported.shortcut
                try write(settings)
                for rule in rules { try write(rule) }
            }
        } catch {
            throw error.cueError
        }
    }

    private func write(_ settings: MenuBarSettings) throws {
        let apps = String(decoding: try JSONEncoder().encode(settings.revealApps), as: UTF8.self)
        let pairs: [(String, String)] = [
            ("enabled", settings.enabled ? "1" : "0"),
            ("auto_rehide_seconds", String(settings.autoRehideSeconds)),
            ("reveal_apps", apps),
            ("shortcut", settings.shortcut ?? ""),
        ]
        for (key, value) in pairs {
            try db.execute("INSERT INTO settings(key, value) VALUES(?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           [.text(key), .text(value)])
        }
    }

    private func write(_ rule: MenuBarRule) throws {
        try db.execute("""
        INSERT INTO rules(key, bundle_id, label, section, updated_at) VALUES(?1, ?2, ?3, ?4, ?5)
        ON CONFLICT(key) DO UPDATE SET bundle_id = excluded.bundle_id, label = excluded.label,
            section = excluded.section, updated_at = excluded.updated_at
        """, [.text(rule.key), .text(rule.bundleID), .text(rule.label), .text(rule.section.rawValue), .text(Timestamp.now())])
    }
}
