import CryptoKit
import Foundation

/// Encrypted clipboard history in its own SQLite file, so clearing history really deletes it.
/// Opening and purging need no key; reading and writing item text needs `unlock(_:)`.
public actor ClipboardStore {
    public static let fileName = "clipboard.sqlite3"
    static let schemaVersion = 1

    public static let keyUnavailable = CueError(
        "HISTORY_KEY_UNAVAILABLE",
        "Cue cannot read the Keychain key that unlocks your clipboard history. If Keychain Access asked about Cue, allow it and try again. Resetting history deletes the saved items and creates a new key.")
    static let newerVersion = CueError(
        "HISTORY_NEWER_VERSION",
        "This clipboard history was created by a newer version of Cue. Update Cue to open it. Your history has not been changed.")

    private let db: SQLite
    private var crypto: ClipboardCrypto?
    // ponytail: every item stays decrypted in memory (bounded by maxItems plus pinned, at most 256 KiB each).
    // Page from SQLite if very large histories ever matter.
    private var cache: [String: ClipItem] = [:]
    public private(set) var settings: ClipboardSettings
    public private(set) var captureEnabled: Bool
    public private(set) var pinboards: [Pinboard] = []

    /// Opens or creates the database. Refuses a newer schema instead of resetting it. Pass nil for in-memory.
    public init(url: URL?) throws {
        let db = try url.map { try SQLite(path: $0) } ?? SQLite()
        try db.executeScript("PRAGMA secure_delete=ON; PRAGMA journal_mode=WAL;")
        let version = try db.userVersion()
        if version > Self.schemaVersion { throw Self.newerVersion }
        if version < 1 {
            try db.transaction {
                try db.executeScript("""
                CREATE TABLE meta(key TEXT PRIMARY KEY, value BLOB NOT NULL);
                CREATE TABLE pinboards(id TEXT PRIMARY KEY, name TEXT NOT NULL, position INTEGER NOT NULL);
                CREATE TABLE items(
                    id TEXT PRIMARY KEY,
                    digest BLOB NOT NULL UNIQUE,
                    text BLOB NOT NULL,
                    source BLOB,
                    created_at TEXT NOT NULL,
                    last_used_at TEXT NOT NULL,
                    pinboard_id TEXT REFERENCES pinboards(id) ON DELETE SET NULL
                );
                CREATE INDEX items_pinboard ON items(pinboard_id);
                PRAGMA user_version=1;
                """)
                try db.execute("INSERT INTO pinboards(id, name, position) VALUES(?1, 'Pinned', 0)", [.text(Self.newID())])
                try Self.write(ClipboardSettings(), db)
            }
        }
        self.db = db
        guard let json = try db.scalar("SELECT value FROM meta WHERE key='settings'")?.data,
              let settings = try? JSONDecoder().decode(ClipboardSettings.self, from: json) else { throw CueError.storage() }
        self.settings = settings
        captureEnabled = try db.scalar("SELECT value FROM meta WHERE key='capture'")?.int == 1
        pinboards = try Self.loadPinboards(db)
    }

    public var isUnlocked: Bool { crypto != nil }

    public func itemCount() throws -> Int { try db.scalar("SELECT COUNT(*) FROM items")?.int ?? 0 }

    /// All rows, including any that cannot be decrypted. For diagnostics.
    public func counts() throws -> (items: Int, pinned: Int) {
        let row = try db.query("SELECT COUNT(*), COUNT(pinboard_id) FROM items").first
        return (row?[0].int ?? 0, row?[1].int ?? 0)
    }

    /// Verifies `key` against the stored key check, then decrypts every item into memory.
    /// A different key is accepted only when there are no items it would orphan.
    public func unlock(_ key: SymmetricKey) throws {
        let crypto = ClipboardCrypto(master: key)
        if try db.scalar("SELECT value FROM meta WHERE key='key_check'")?.data != crypto.keyCheck {
            if try itemCount() > 0 { throw Self.keyUnavailable }
            try db.execute("INSERT OR REPLACE INTO meta(key, value) VALUES('key_check', ?1)", [.blob(crypto.keyCheck)])
        }
        try load(crypto)
    }

    /// Every readable item, last used first.
    public func items() -> [ClipItem] { cache.values.sorted { $0.lastUsedAt > $1.lastUsedAt } }

    // MARK: Items

    /// Saves `text`, or moves an existing identical item to the top. Returns the item's ID.
    @discardableResult
    public func capture(_ text: String, source: String?, now: Date) throws -> String {
        let crypto = try requireCrypto()
        let (stamp, date) = Self.stamp(now)
        let digest = crypto.digest(text)
        if let id = try db.scalar("SELECT id FROM items WHERE digest=?1", [.blob(digest)])?.string {
            try db.execute("UPDATE items SET last_used_at=?1 WHERE id=?2", [.text(stamp), .text(id)])
            cache[id]?.lastUsedAt = date
            return id
        }
        let id = Self.newID()
        let sealedSource = try source.map { try crypto.seal($0, context: "\(id).source") }
        try db.execute("INSERT INTO items(id, digest, text, source, created_at, last_used_at) VALUES(?1, ?2, ?3, ?4, ?5, ?5)",
                       [.text(id), .blob(digest), .blob(try crypto.seal(text, context: "\(id).text")), sealedSource.map(SQLValue.blob) ?? .null, .text(stamp)])
        cache[id] = ClipItem(id: id, text: text, source: source, createdAt: date, lastUsedAt: date, pinboardID: nil)
        return id
    }

    public func markUsed(_ id: String, now: Date) throws {
        let (stamp, date) = Self.stamp(now)
        try db.execute("UPDATE items SET last_used_at=?1 WHERE id=?2", [.text(stamp), .text(id)])
        cache[id]?.lastUsedAt = date
    }

    /// Pins to `pinboardID`, or unpins with nil.
    public func setPinboard(_ id: String, _ pinboardID: String?) throws {
        if let pinboardID, !pinboards.contains(where: { $0.id == pinboardID }) { throw CueError.validation("That pinboard no longer exists.") }
        try db.execute("UPDATE items SET pinboard_id=?1 WHERE id=?2", [SQLValue(pinboardID), .text(id)])
        cache[id]?.pinboardID = pinboardID
    }

    public func delete(_ id: String) throws {
        try db.execute("DELETE FROM items WHERE id=?1", [.text(id)])
        cache[id] = nil
        try checkpoint()
    }

    /// Deletes expired and excess unpinned items with real `DELETE`s. Works without the key.
    @discardableResult
    public func purge(now: Date) throws -> Int {
        let candidates = try db.query("SELECT id, last_used_at, pinboard_id FROM items").compactMap { row -> PurgeCandidate? in
            guard let id = row[0].string else { return nil }
            // An unparsable date counts as oldest, so damaged rows expire instead of lingering.
            let used = row[1].string.flatMap(Timestamp.parse) ?? .distantPast
            return PurgeCandidate(id: id, lastUsedAt: used, pinned: row[2] != .null)
        }
        let doomed = ClipboardPurge.select(candidates, now: now, retention: settings.retention, maxItems: settings.maxItems)
        guard !doomed.isEmpty else { return 0 }
        try db.transaction {
            for id in doomed { try db.execute("DELETE FROM items WHERE id=?1", [.text(id)]) }
        }
        for id in doomed { cache[id] = nil }
        try checkpoint()
        return doomed.count
    }

    public func clear(keepPinned: Bool) throws {
        try db.execute(keepPinned ? "DELETE FROM items WHERE pinboard_id IS NULL" : "DELETE FROM items")
        cache = cache.filter { keepPinned && $0.value.isPinned }
        try checkpoint()
    }

    /// Deletes every item and forgets the key check, so a new key can be used. Pinboards and settings stay.
    public func resetHistory() throws {
        try db.transaction {
            try db.execute("DELETE FROM items")
            try db.execute("DELETE FROM meta WHERE key='key_check'")
        }
        crypto = nil
        cache = [:]
        try checkpoint()
    }

    // MARK: Pinboards

    public func createPinboard(_ name: String) throws -> Pinboard {
        let board = Pinboard(id: Self.newID(), name: try Pinboard.validName(name, existing: pinboards))
        try db.execute("INSERT INTO pinboards(id, name, position) VALUES(?1, ?2, (SELECT COALESCE(MAX(position), -1) + 1 FROM pinboards))",
                       [.text(board.id), .text(board.name)])
        pinboards.append(board)
        return board
    }

    /// The first pinboard, created as "Pinned" when there is none. Used by ⌘P.
    public func defaultPinboard() throws -> Pinboard {
        try pinboards.first ?? createPinboard("Pinned")
    }

    public func renamePinboard(_ id: String, to name: String) throws {
        let clean = try Pinboard.validName(name, existing: pinboards, excluding: id)
        try db.execute("UPDATE pinboards SET name=?1 WHERE id=?2", [.text(clean), .text(id)])
        if let index = pinboards.firstIndex(where: { $0.id == id }) { pinboards[index].name = clean }
    }

    /// Deletes the pinboard. Its items become unpinned and can expire again.
    public func deletePinboard(_ id: String) throws {
        try db.execute("DELETE FROM pinboards WHERE id=?1", [.text(id)])
        pinboards.removeAll { $0.id == id }
        for (itemID, item) in cache where item.pinboardID == id { cache[itemID]?.pinboardID = nil }
    }

    // MARK: Settings

    public func save(_ settings: ClipboardSettings) throws {
        try settings.validate()
        try Self.write(settings, db)
        self.settings = settings
    }

    public func setCaptureEnabled(_ enabled: Bool) throws {
        try db.execute("INSERT OR REPLACE INTO meta(key, value) VALUES('capture', ?1)", [SQLValue(enabled)])
        captureEnabled = enabled
    }

    // MARK: Export and import

    /// Plaintext JSON of settings, pinboards, and every readable item.
    public func exportData(now: Date) throws -> Data {
        if crypto == nil, try itemCount() > 0 { throw Self.keyUnavailable }
        let file = ClipboardExport(
            schemaVersion: ClipboardExport.currentVersion, exportedAt: Timestamp.iso(now), settings: settings, pinboards: pinboards,
            items: items().map { .init(id: $0.id, text: $0.text, createdAt: Timestamp.iso($0.createdAt), lastUsedAt: Timestamp.iso($0.lastUsedAt), pinboardID: $0.pinboardID) })
        return try file.encoded()
    }

    /// Replaces items, pinboards, and settings with the file's contents in one transaction.
    /// Nothing changes when validation or any write fails.
    public func importData(_ data: Data) throws {
        let file = try ClipboardExport.decode(data)
        // A file without items needs no key, so settings can be imported before history is ever unlocked.
        let crypto = file.items.isEmpty ? crypto : try requireCrypto()
        var digests = Set<Data>()
        try db.transaction {
            try db.execute("DELETE FROM items")
            try db.execute("DELETE FROM pinboards")
            for (position, board) in file.pinboards.enumerated() {
                try db.execute("INSERT INTO pinboards(id, name, position) VALUES(?1, ?2, ?3)", [.text(board.id), .text(board.name), SQLValue(position)])
            }
            for (index, item) in file.items.enumerated() {
                guard let crypto else { throw Self.keyUnavailable }
                let digest = crypto.digest(item.text)
                guard digests.insert(digest).inserted else { throw CueError.validation("Item \(index + 1) duplicates an earlier item.") }
                try db.execute("INSERT INTO items(id, digest, text, created_at, last_used_at, pinboard_id) VALUES(?1, ?2, ?3, ?4, ?5, ?6)", [
                    .text(item.id), .blob(digest), .blob(try crypto.seal(item.text, context: "\(item.id).text")),
                    .text(item.createdAt), .text(item.lastUsedAt), SQLValue(item.pinboardID),
                ])
            }
            try Self.write(file.settings, db)
        }
        settings = file.settings
        pinboards = file.pinboards
        cache = [:]
        if let crypto { try load(crypto) }
        try checkpoint()
    }

    // MARK: Helpers

    /// Decrypts every item into memory.
    private func load(_ crypto: ClipboardCrypto) throws {
        var cache: [String: ClipItem] = [:]
        for row in try db.query("SELECT id, text, source, created_at, last_used_at, pinboard_id FROM items") {
            // A row that fails authentication is skipped, never shown. It still expires through `purge`.
            guard let id = row[0].string, let sealed = row[1].data, let text = try? crypto.open(sealed, context: "\(id).text"),
                  let created = row[3].string.flatMap(Timestamp.parse), let used = row[4].string.flatMap(Timestamp.parse)
            else { continue }
            let source = row[2].data.flatMap { try? crypto.open($0, context: "\(id).source") }
            cache[id] = ClipItem(id: id, text: text, source: source, createdAt: created, lastUsedAt: used, pinboardID: row[5].string)
        }
        self.crypto = crypto
        self.cache = cache
    }

    private func requireCrypto() throws -> ClipboardCrypto {
        guard let crypto else { throw Self.keyUnavailable }
        return crypto
    }

    /// Moves deleted pages out of the write-ahead log so `secure_delete` covers them too.
    private func checkpoint() throws { try db.executeScript("PRAGMA wal_checkpoint(TRUNCATE)") }

    private static func write(_ settings: ClipboardSettings, _ db: SQLite) throws {
        try db.execute("INSERT OR REPLACE INTO meta(key, value) VALUES('settings', ?1)", [.blob(try JSONEncoder().encode(settings))])
    }

    private static func loadPinboards(_ db: SQLite) throws -> [Pinboard] {
        try db.query("SELECT id, name FROM pinboards ORDER BY position").compactMap { row in
            guard let id = row[0].string, let name = row[1].string else { return nil }
            return Pinboard(id: id, name: name)
        }
    }

    /// Millisecond precision, so the in-memory date equals the stored one.
    private static func stamp(_ date: Date) -> (String, Date) {
        let text = Timestamp.iso(date)
        return (text, Timestamp.parse(text) ?? date)
    }

    static func newID() -> String { UUID().uuidString.lowercased() }
}

/// The export file. Text is plaintext so the file is useful anywhere; the app warns before saving.
public struct ClipboardExport: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let maxBytes = 20 * 1024 * 1024

    public var schemaVersion: Int
    public var exportedAt: String
    public var settings: ClipboardSettings
    public var pinboards: [Pinboard]
    public var items: [Item]

    public struct Item: Codable, Equatable, Sendable {
        public var id: String
        public var text: String
        public var createdAt: String
        public var lastUsedAt: String
        public var pinboardID: String?

        public init(id: String, text: String, createdAt: String, lastUsedAt: String, pinboardID: String?) {
            self.id = id
            self.text = text
            self.createdAt = createdAt
            self.lastUsedAt = lastUsedAt
            self.pinboardID = pinboardID
        }

        private enum CodingKeys: String, CodingKey { case id, text, createdAt, lastUsedAt, pinboardID }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(text, forKey: .text)
            try c.encode(createdAt, forKey: .createdAt)
            try c.encode(lastUsedAt, forKey: .lastUsedAt)
            try c.encode(pinboardID, forKey: .pinboardID) // explicit null when unpinned
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Decodes and validates strictly. Dates come back in Cue's canonical timestamp form.
    public static func decode(_ data: Data) throws(CueError) -> ClipboardExport {
        guard data.count <= maxBytes else { throw .validation("The file is larger than 20 MB.") }
        let version = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["schemaVersion"] as? Int
        guard let version else { throw .validation("This file is not a Cue clipboard export.") }
        guard version == currentVersion else {
            throw .validation(version > currentVersion ? "This export comes from a newer version of Cue. Update Cue to import it." : "This export version is not supported.")
        }
        var file: ClipboardExport
        do {
            file = try JSONDecoder().decode(ClipboardExport.self, from: data)
        } catch {
            throw .validation("The export file is incomplete or damaged.")
        }
        try file.settings.validate()
        var boardIDs = Set<String>()
        for (index, board) in file.pinboards.enumerated() {
            guard isCanonicalID(board.id), boardIDs.insert(board.id).inserted else { throw .validation("Pinboard \(index + 1) has a missing or repeated ID.") }
            file.pinboards[index].name = try Pinboard.validName(board.name, existing: Array(file.pinboards[..<index]))
        }
        var itemIDs = Set<String>()
        for (index, item) in file.items.enumerated() {
            let n = index + 1
            guard isCanonicalID(item.id), itemIDs.insert(item.id).inserted else { throw .validation("Item \(n) has a missing or repeated ID.") }
            if CaptureFilter.textProblem(item.text) != nil { throw .validation("Item \(n) is empty or larger than 256 KB.") }
            guard let created = Timestamp.parse(item.createdAt), let used = Timestamp.parse(item.lastUsedAt) else {
                throw .validation("Item \(n) has an invalid date.")
            }
            if let board = item.pinboardID, !boardIDs.contains(board) { throw .validation("Item \(n) refers to a pinboard that is not in the file.") }
            file.items[index].createdAt = Timestamp.iso(created)
            file.items[index].lastUsedAt = Timestamp.iso(used)
        }
        return file
    }

    /// Lowercase UUID, the form Cue writes.
    static func isCanonicalID(_ id: String) -> Bool { UUID(uuidString: id)?.uuidString.lowercased() == id }
}
