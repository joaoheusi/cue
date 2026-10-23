import Foundation

public struct LibrarySnapshot: Sendable, Equatable {
    public var actions: [Action]
    public var categories: [String]
    public var settings: PromptSettings
    public var revision: Int
    /// Shortcut owner (`palette` or `action:<id>`) → stored chord.
    public var bindings: [String: String]
}

public struct ImportPreview: Sendable, Equatable {
    public var token: String
    public var actions: [ExportAction]
    public var duplicateIDs: Int
    public var duplicateNames: Int
    public var newCategories: [String]
    public var revision: Int
}

/// The prompt library in `cue.sqlite3`. Reads and writes the schema created by earlier Cue versions.
/// Every write is one transaction and bumps the library revision, which guards against stale edits.
public actor PromptStore {
    private let db: SQLite
    private let directory: URL
    private var pending: (token: String, revision: Int, created: Date, actions: [ExportAction])?

    public init(directory: URL) throws {
        self.directory = directory
        let db = try SQLite(path: directory.appendingPathComponent("cue.sqlite3"))
        let version = try db.userVersion()
        if version > 3 {
            throw CueError("STORAGE_FAILURE", "This library was created by a newer Cue. Update Cue to open it.")
        }
        let backups = directory.appendingPathComponent("backups")
        if version == 0 {
            if try db.scalar("SELECT COUNT(*) FROM sqlite_master WHERE type='table'")?.int ?? 0 > 0 {
                try db.backup(into: backups, prefix: "cue")
            }
            let defaults = String(decoding: try JSONEncoder().encode(PromptSettings()), as: UTF8.self)
            try db.transaction {
                try db.executeScript(Self.initialSchema)
                try db.execute("INSERT INTO settings VALUES(1,?1)", [.text(defaults)])
            }
        } else if version < 3 {
            // One backup before upgrading a library written by an earlier Cue.
            try db.backup(into: backups, prefix: "cue")
        }
        if version < 2 {
            try db.transaction {
                try db.executeScript("""
                    UPDATE settings SET data=json_set(data, '$.defaultDelivery', 'paste', '$.keepRunning', json('true'));
                    INSERT OR IGNORE INTO schema_migrations VALUES(2, strftime('%Y-%m-%dT%H:%M:%SZ','now'));
                    PRAGMA user_version=2;
                    """)
            }
        }
        if version < 3 {
            // Version 3 marks libraries written by the Swift app. The Tauri app then reports
            // "created by a newer Cue" instead of editing data it was not written for.
            try db.transaction {
                try db.executeScript("""
                    INSERT OR IGNORE INTO schema_migrations VALUES(3, strftime('%Y-%m-%dT%H:%M:%SZ','now'));
                    PRAGMA user_version=3;
                    """)
            }
        }
        try db.executeScript("PRAGMA journal_mode=WAL")
        self.db = db
    }

    static let initialSchema = """
        CREATE TABLE actions(id TEXT PRIMARY KEY, revision INTEGER NOT NULL CHECK(revision>0), data TEXT NOT NULL CHECK(json_valid(data)));
        CREATE TABLE categories(name TEXT NOT NULL, normalized TEXT PRIMARY KEY);
        CREATE TABLE settings(id INTEGER PRIMARY KEY CHECK(id=1), data TEXT NOT NULL CHECK(json_valid(data)));
        CREATE TABLE library_state(id INTEGER PRIMARY KEY CHECK(id=1),revision INTEGER NOT NULL);
        INSERT INTO library_state VALUES(1,1);
        CREATE TABLE shortcuts(owner TEXT PRIMARY KEY, accelerator TEXT NOT NULL);
        CREATE TABLE schema_migrations(version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL);
        INSERT INTO schema_migrations VALUES(1, strftime('%Y-%m-%dT%H:%M:%SZ','now'));
        PRAGMA user_version=1;
        """

    // MARK: Reads

    public func revision() throws -> Int {
        guard let value = try db.scalar("SELECT revision FROM library_state WHERE id=1")?.int else { throw CueError.storage() }
        return value
    }

    public func get(_ id: String) throws -> Action {
        guard let data = try db.scalar("SELECT data FROM actions WHERE id=?1", [.text(id)])?.data else {
            throw CueError("NOT_FOUND", "This action no longer exists.")
        }
        return try JSONDecoder().decode(Action.self, from: data)
    }

    public func settings() throws -> PromptSettings {
        guard let data = try db.scalar("SELECT data FROM settings WHERE id=1")?.data else { throw CueError.storage() }
        return try JSONDecoder().decode(PromptSettings.self, from: data)
    }

    public func snapshot() throws -> LibrarySnapshot {
        let decoder = JSONDecoder()
        let actions = try db.query("SELECT data FROM actions ORDER BY id").map { try decoder.decode(Action.self, from: $0[0].data ?? Data()) }
        let categories = try db.query("SELECT name FROM categories ORDER BY normalized").compactMap { $0[0].string }
        var bindings: [String: String] = [:]
        for row in try db.query("SELECT owner, accelerator FROM shortcuts") {
            if let owner = row[0].string, let chord = row[1].string { bindings[owner] = chord }
        }
        return LibrarySnapshot(actions: actions, categories: categories, settings: try settings(), revision: try revision(), bindings: bindings)
    }

    public func exportFile() throws -> ExportFile {
        ExportFile(actions: try snapshot().actions.map(\.export))
    }

    // MARK: Writes

    private func bump() throws { try db.execute("UPDATE library_state SET revision=revision+1") }

    private func encode(_ action: Action) throws -> SQLValue {
        .text(String(decoding: try JSONEncoder().encode(action), as: UTF8.self))
    }

    private func checkRevision(_ expected: Int, _ message: String = "The library changed. Reload and try again.") throws {
        if try revision() != expected { throw CueError("REVISION_CONFLICT", message) }
    }

    /// Uses the existing spelling of a category with the same key, or registers a new one.
    private func canonicalCategory(_ name: String?) throws -> String? {
        guard let name else { return nil }
        let normalized = ActionRules.key(name)
        if let existing = try db.scalar("SELECT name FROM categories WHERE normalized=?1", [.text(normalized)])?.string { return existing }
        try db.execute("INSERT INTO categories VALUES(?1,?2)", [.text(name), .text(normalized)])
        return name
    }

    /// Creates (revision 0) or updates (matching revision) an action. Usage counters are preserved.
    @discardableResult
    public func save(_ input: Action) throws -> Action {
        var a = input
        try ActionRules.validate(&a)
        let existing = try db.scalar("SELECT revision FROM actions WHERE id=?1", [.text(a.id)])?.int
        if existing != (a.revision == 0 ? nil : a.revision) {
            throw CueError("REVISION_CONFLICT", "This action changed in another window. Reload before saving.")
        }
        if existing == nil, try db.scalar("SELECT COUNT(*) FROM actions")?.int ?? 0 >= ActionRules.libraryLimit {
            throw CueError.validation("The library is limited to 5,000 actions.")
        }
        if existing != nil {
            let old = try get(a.id)
            a.useCount = old.useCount
            a.lastUsedAt = old.lastUsedAt
            a.createdAt = old.createdAt
        } else {
            a.useCount = 0
            a.lastUsedAt = nil
            a.createdAt = Timestamp.now()
        }
        a.revision += 1
        a.updatedAt = Timestamp.now()
        let saved = a
        return try db.transaction {
            var stored = saved
            stored.category = try canonicalCategory(saved.category)
            try db.execute("INSERT INTO actions VALUES(?1,?2,?3) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,data=excluded.data",
                           [.text(stored.id), SQLValue(stored.revision), try encode(stored)])
            try bump()
            return stored
        }
    }

    public func recordUse(_ id: String) throws {
        var a = try get(id)
        a.useCount += 1
        a.lastUsedAt = Timestamp.now()
        let used = a
        try db.transaction {
            try db.execute("UPDATE actions SET data=?1 WHERE id=?2", [try encode(used), .text(id)])
            try bump()
        }
    }

    /// First-run setup. Saves starter actions and settings atomically and runs once.
    public func onboard(_ actions: [Action], settings input: PromptSettings, revision: Int) throws {
        if try settings().onboarded { return }
        try checkRevision(revision, "The library changed. Try setup again.")
        var settings = input
        settings.onboarded = true
        settings.defaultDelivery = .paste
        settings.launchAtLogin = false
        settings.keepRunning = true
        if try snapshot().actions.count + actions.count > ActionRules.libraryLimit {
            throw CueError.validation("The library is limited to 5,000 actions.")
        }
        var validated: [Action] = []
        for var action in actions {
            try ActionRules.validate(&action)
            validated.append(action)
        }
        let settingsJSON = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        try db.transaction {
            for var a in validated {
                a.revision = 1
                a.useCount = 0
                a.lastUsedAt = nil
                a.createdAt = Timestamp.now()
                a.updatedAt = a.createdAt
                if let c = a.category {
                    try db.execute("INSERT OR IGNORE INTO categories VALUES(?1,?2)", [.text(c), .text(ActionRules.key(c))])
                }
                try db.execute("INSERT INTO actions VALUES(?1,?2,?3)", [.text(a.id), SQLValue(a.revision), try encode(a)])
            }
            try db.execute("UPDATE settings SET data=?1 WHERE id=1", [.text(settingsJSON)])
            try bump()
        }
    }

    public func duplicate(_ id: String, revision: Int) throws -> Action {
        var a = try get(id)
        guard a.revision == revision else { throw CueError("REVISION_CONFLICT", "Action changed. Reload before continuing.") }
        a.id = UUID().uuidString.lowercased()
        a.name = String(String.UnicodeScalarView(a.name.unicodeScalars.prefix(95))) + " copy"
        a.revision = 0
        return try save(a)
    }

    /// Deletes an action and its direct shortcut.
    public func delete(_ id: String, revision: Int) throws {
        let a = try get(id)
        guard a.revision == revision else { throw CueError("REVISION_CONFLICT", "Action changed. Reload before continuing.") }
        try db.transaction {
            try db.execute("DELETE FROM shortcuts WHERE owner=?1", [.text("action:\(a.id)")])
            try db.execute("DELETE FROM actions WHERE id=?1", [.text(a.id)])
            try bump()
        }
    }

    public func saveSettings(_ settings: PromptSettings, revision: Int) throws {
        try checkRevision(revision, "Settings changed. Reload and try again.")
        let json = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        try db.transaction {
            try db.execute("UPDATE settings SET data=?1 WHERE id=1", [.text(json)])
            try bump()
        }
    }

    /// Renames (`old` set, non-empty `name`), removes (`old` set, empty `name`), or creates (`old` nil) a category.
    public func category(old: String?, name input: String, revision: Int) throws {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.unicodeScalars.count > 50 { throw CueError.validation("Category names are limited to 50 characters.") }
        try checkRevision(revision)
        let actions = try snapshot().actions
        try db.transaction {
            if let old {
                try db.execute("DELETE FROM categories WHERE normalized=?1", [.text(ActionRules.key(old))])
                for var a in actions where a.category == old {
                    a.category = name.isEmpty ? nil : name
                    a.revision += 1
                    a.updatedAt = Timestamp.now()
                    try db.execute("UPDATE actions SET revision=?1,data=?2 WHERE id=?3", [SQLValue(a.revision), try encode(a), .text(a.id)])
                }
            }
            if !name.isEmpty {
                do {
                    try db.execute("INSERT INTO categories VALUES(?1,?2)", [.text(name), .text(ActionRules.key(name))])
                } catch let error as SQLiteError where error.isConstraint {
                    throw CueError.validation("A category with this name already exists.")
                }
            }
            try bump()
        }
    }

    public func clearUsage() throws {
        let actions = try snapshot().actions
        try db.transaction {
            for var a in actions {
                a.useCount = 0
                a.lastUsedAt = nil
                try db.execute("UPDATE actions SET data=?1 WHERE id=?2", [try encode(a), .text(a.id)])
            }
            try bump()
        }
    }

    public func saveBinding(owner: String, chord: String) throws {
        if chord.isEmpty {
            try db.execute("DELETE FROM shortcuts WHERE owner=?1", [.text(owner)])
        } else {
            try db.execute("INSERT INTO shortcuts VALUES(?1,?2) ON CONFLICT(owner) DO UPDATE SET accelerator=excluded.accelerator",
                           [.text(owner), .text(chord)])
        }
    }

    // MARK: Import

    /// Validates an export file strictly and holds it for five minutes until `commitImport`.
    public func preview(_ data: Data) throws -> ImportPreview {
        if data.count > 10 * 1024 * 1024 { throw CueError("OUTPUT_TOO_LARGE", "Import files must be smaller than 10 MiB.") }
        guard let raw = try? JSONSerialization.jsonObject(with: data) else {
            throw CueError.validation("The file is not valid UTF-8 JSON.")
        }
        guard let object = raw as? [String: Any], Set(object.keys) == ["schemaVersion", "exportedAt", "actions"] else {
            throw CueError.validation("Import contains unsupported fields.")
        }
        let allowed: Set = ["id", "name", "description", "template", "aliases", "tags", "category", "deliveryMode", "favorite", "enabled"]
        guard let rawActions = object["actions"] as? [[String: Any]], rawActions.allSatisfy({ Set($0.keys) == allowed }),
              let export = try? JSONDecoder().decode(ExportFile.self, from: data)
        else { throw CueError.validation("Import fields do not match schema version 1.") }
        guard export.schemaVersion == 1, Timestamp.parse(export.exportedAt) != nil else {
            throw CueError.validation("Unsupported schema or invalid export timestamp.")
        }
        var ids = Set<String>()
        for item in export.actions {
            guard ids.insert(item.id).inserted else { throw CueError.validation("Import contains duplicate IDs.") }
            var action = item.action
            try ActionRules.validate(&action)
        }
        let snapshot = try snapshot()
        if snapshot.actions.count + export.actions.count > ActionRules.libraryLimit {
            throw CueError.validation("Import would exceed the 5,000-action limit.")
        }
        let existingIDs = Set(snapshot.actions.map(\.id))
        let existingNames = Set(snapshot.actions.map { ActionRules.key($0.name) })
        let existingCategories = Set(snapshot.categories.map(ActionRules.key))
        var newCategories: [String: String] = [:]
        for c in export.actions.compactMap(\.category) where !existingCategories.contains(ActionRules.key(c)) {
            newCategories[ActionRules.key(c)] = newCategories[ActionRules.key(c)] ?? c
        }
        let token = UUID().uuidString
        pending = (token, snapshot.revision, Date(), export.actions)
        return ImportPreview(token: token, actions: export.actions,
                             duplicateIDs: export.actions.filter { existingIDs.contains($0.id) }.count,
                             duplicateNames: export.actions.filter { existingNames.contains(ActionRules.key($0.name)) }.count,
                             newCategories: newCategories.sorted { $0.key < $1.key }.map(\.value), revision: snapshot.revision)
    }

    /// Imports the previewed actions. `update` replaces actions with the same ID; otherwise all are added as new.
    /// Imported actions use Copy delivery and lose direct shortcuts. A backup is taken first.
    public func commitImport(token: String, update: Bool) throws {
        guard let p = pending else { throw CueError("REVISION_CONFLICT", "Import preview expired. Choose the file again.") }
        pending = nil
        guard p.token == token, Date().timeIntervalSince(p.created) <= 300, try p.revision == revision() else {
            throw CueError("REVISION_CONFLICT", "Library changed or preview expired. Choose the file again.")
        }
        try db.backup(into: directory.appendingPathComponent("backups"), prefix: "cue")
        let existing = Dictionary(uniqueKeysWithValues: try snapshot().actions.map { ($0.id, $0) })
        try db.transaction {
            for item in p.actions {
                var a = item.action
                try ActionRules.validate(&a)
                if update, let old = existing[a.id] {
                    a.revision = old.revision + 1
                    a.createdAt = old.createdAt
                    a.useCount = old.useCount
                    a.lastUsedAt = old.lastUsedAt
                    try db.execute("DELETE FROM shortcuts WHERE owner=?1", [.text("action:\(a.id)")])
                } else {
                    a.id = UUID().uuidString.lowercased()
                    a.revision = 1
                }
                a.deliveryMode = .copy
                a.category = try canonicalCategory(a.category)
                try db.execute("INSERT INTO actions VALUES(?1,?2,?3) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,data=excluded.data",
                               [.text(a.id), SQLValue(a.revision), try encode(a)])
            }
            try bump()
        }
    }

    public func backup() throws {
        try db.backup(into: directory.appendingPathComponent("backups"), prefix: "cue")
    }
}
