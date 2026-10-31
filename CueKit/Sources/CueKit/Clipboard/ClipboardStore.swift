import CryptoKit
import Foundation

public actor ClipboardStore {
    public static let fileName = "clipboard.sqlite3"
    public static let payloadFolder = "clipboard-payloads"
    static let schemaVersion = 4
    private static let bytesSQL = "length(text) + file_bytes + COALESCE(length(meta), 0) + COALESCE(length(rich), 0) + COALESCE(length(ocr_text), 0) + COALESCE(length(thumbnail), 0)"

    public static let keyUnavailable = CueError(
        "HISTORY_KEY_UNAVAILABLE",
        "Cue cannot read the Keychain key that unlocks your clipboard history. If Keychain Access asked about Cue, allow it and try again. Resetting history deletes the saved items and creates a new key.")
    static let newerVersion = CueError(
        "HISTORY_NEWER_VERSION",
        "This clipboard history was created by a newer version of Cue. Update Cue to open it. Your history has not been changed.")
    public static let dataMissing = CueError("CLIPBOARD_DATA_MISSING", "The saved data for this item is missing or damaged.")

    private let db: SQLite
    private let payloads: URL
    private var crypto: ClipboardCrypto?
    private var cache: [String: ClipItem] = [:]
    public private(set) var settings: ClipboardSettings
    public private(set) var captureEnabled: Bool
    public private(set) var capturePaused: Bool
    public private(set) var pinboards: [Pinboard] = []

    public init(url: URL?) throws {
        let db = try url.map { try SQLite(path: $0) } ?? SQLite()
        payloads = url?.deletingLastPathComponent().appendingPathComponent(Self.payloadFolder, isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("\(Self.payloadFolder)-\(Self.newID())", isDirectory: true)
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
        if try db.userVersion() < 2 {
            try db.transaction {
                try db.executeScript("""
                ALTER TABLE items ADD COLUMN sensitive INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE items ADD COLUMN expires_at TEXT;
                PRAGMA user_version=2;
                """)
            }
        }
        if try db.userVersion() < 3 {
            try db.transaction {
                try db.executeScript("""
                ALTER TABLE items ADD COLUMN format TEXT NOT NULL DEFAULT 'plain';
                ALTER TABLE items ADD COLUMN meta BLOB;
                ALTER TABLE items ADD COLUMN rich BLOB;
                ALTER TABLE items ADD COLUMN file_bytes INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE items ADD COLUMN title BLOB;
                ALTER TABLE items ADD COLUMN ocr_text BLOB;
                ALTER TABLE items ADD COLUMN thumbnail BLOB;
                PRAGMA user_version=3;
                """)
            }
        }
        if try db.userVersion() < 4 {
            try db.transaction { try db.executeScript("PRAGMA user_version=4") }
        }
        self.db = db
        guard let json = try db.scalar("SELECT value FROM meta WHERE key='settings'")?.data,
              let settings = try? JSONDecoder().decode(ClipboardSettings.self, from: json) else { throw CueError.storage() }
        self.settings = settings
        let capture = try db.scalar("SELECT value FROM meta WHERE key='capture'")?.int
        captureEnabled = capture == 1
        capturePaused = capture == 0
        pinboards = try Self.loadPinboards(db)
    }

    public var isUnlocked: Bool { crypto != nil }

    public func itemCount() throws -> Int { try db.scalar("SELECT COUNT(*) FROM items")?.int ?? 0 }

    public func counts() throws -> (items: Int, pinned: Int) {
        let row = try db.query("SELECT COUNT(*), COUNT(pinboard_id) FROM items").first
        return (row?[0].int ?? 0, row?[1].int ?? 0)
    }

    public func unlock(_ key: SymmetricKey) throws {
        let crypto = ClipboardCrypto(master: key)
        if try db.scalar("SELECT value FROM meta WHERE key='key_check'")?.data != crypto.keyCheck {
            if try itemCount() > 0 { throw Self.keyUnavailable }
            try db.execute("INSERT OR REPLACE INTO meta(key, value) VALUES('key_check', ?1)", [.blob(crypto.keyCheck)])
        }
        try load(crypto)
    }

    public func items() -> [ClipItem] { cache.values.sorted { $0.lastUsedAt > $1.lastUsedAt } }

    @discardableResult
    public func capture(_ text: String, source: String?, now: Date) throws -> String {
        try capture(.plain(text), source: source, now: now)
    }

    @discardableResult
    public func capture(_ captured: ClipCapture, source: String?, now: Date) throws -> String {
        let crypto = try requireCrypto()
        let (stamp, date) = Self.stamp(now)
        let sensitive = captured.content.isText && settings.sensitive != .keep && SensitiveText.matches(captured.text)
        let clip = sensitive ? ClipCapture.plain(captured.text) : captured
        let digest = crypto.digest(clip)
        let expiry = Self.expiry(sensitive: sensitive, settings: settings, now: date)
        if let id = try db.scalar("SELECT id FROM items WHERE digest=?1", [.blob(digest)])?.string {
            let old = cache[id]
            let kept = old?.isPinned == true ? nil : expiry
            let replaces = sensitive || clip.content == .rich
            let content = replaces ? clip.content : old?.content ?? clip.content
            let rich = try Self.sealedRich(clip, id: id, crypto: crypto)
            let restored = FileManager.default.fileExists(atPath: payloadFile(id).path) ? 0 : try writePayload(clip, id: id, crypto: crypto)
            try db.transaction {
                if restored > 0 {
                    try db.execute("UPDATE items SET file_bytes=?1, text=?2 WHERE id=?3", [SQLValue(restored), .blob(try Self.sealedInline(clip, id: id, crypto: crypto)), .text(id)])
                }
                try db.execute("UPDATE items SET last_used_at=?1, sensitive=?2, expires_at=?3 WHERE id=?4",
                               [.text(stamp), SQLValue(sensitive), kept.map { .text(Timestamp.iso($0)) } ?? .null, .text(id)])
                if replaces {
                    try db.execute("UPDATE items SET format=?1, rich=?2 WHERE id=?3", [.text(content.format), rich.map(SQLValue.blob) ?? .null, .text(id)])
                }
            }
            cache[id] = ClipItem(id: id, text: clip.text, source: old?.source, createdAt: old?.createdAt ?? date, lastUsedAt: date,
                                 pinboardID: old?.pinboardID, sensitive: sensitive, expiresAt: kept, content: content, byteSize: try storedBytes(id), ocrText: try ocrText(id))
            return id
        }
        let id = Self.newID()
        let sealedSource = try source.map { try crypto.seal($0, context: "\(id).source") }
        let sealedMeta = clip.content.isText ? nil : try crypto.seal(try JSONEncoder().encode(clip.content), context: "\(id).meta")
        let sealedThumbnail = try clip.thumbnail.map { try crypto.seal($0, context: "\(id).thumbnail") }
        let rich = try Self.sealedRich(clip, id: id, crypto: crypto)
        let fileBytes = try writePayload(clip, id: id, crypto: crypto)
        do {
            try db.execute("""
            INSERT INTO items(id, digest, text, source, created_at, last_used_at, sensitive, expires_at, format, meta, rich, file_bytes, thumbnail)
            VALUES(?1, ?2, ?3, ?4, ?5, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
            """, [.text(id), .blob(digest), .blob(try Self.sealedInline(clip, id: id, crypto: crypto)), sealedSource.map(SQLValue.blob) ?? .null, .text(stamp),
                  SQLValue(sensitive), expiry.map { .text(Timestamp.iso($0)) } ?? .null, .text(clip.content.format), sealedMeta.map(SQLValue.blob) ?? .null,
                  rich.map(SQLValue.blob) ?? .null, SQLValue(fileBytes), sealedThumbnail.map(SQLValue.blob) ?? .null])
        } catch {
            removePayload(id)
            throw error
        }
        cache[id] = ClipItem(id: id, text: clip.text, source: source, createdAt: date, lastUsedAt: date, pinboardID: nil, sensitive: sensitive,
                             expiresAt: expiry, content: clip.content, byteSize: try storedBytes(id))
        return id
    }

    public func nextOCR() throws -> String? {
        try db.scalar("SELECT id FROM items WHERE format='image' AND ocr_text IS NULL ORDER BY last_used_at DESC LIMIT 1")?.string
    }

    public func pendingOCRCount() throws -> Int {
        try db.scalar("SELECT COUNT(*) FROM items WHERE format='image' AND ocr_text IS NULL")?.int ?? 0
    }

    public func saveOCR(_ id: String, text: String) throws {
        let crypto = try requireCrypto()
        let masked = SensitiveText.maskedLines(ClipItem.prefix(text, bytes: ClipboardOCR.maxTextBytes))
        try db.execute("UPDATE items SET ocr_text=?1 WHERE id=?2 AND format='image' AND ocr_text IS NULL", [.blob(try crypto.seal(masked, context: "\(id).ocr")), .text(id)])
        guard db.changes > 0 else { return }
        cache[id] = try cache[id]?.withOCRText(masked, byteSize: storedBytes(id))
    }

    public func ocrText(_ id: String) throws -> String? {
        let crypto = try requireCrypto()
        guard let sealed = try db.scalar("SELECT ocr_text FROM items WHERE id=?1", [.text(id)])?.data else { return nil }
        return try? crypto.open(sealed, context: "\(id).ocr")
    }

    public func fullText(_ id: String) throws -> String {
        let crypto = try requireCrypto()
        guard let row = try db.query("SELECT text, file_bytes FROM items WHERE id=?1", [.text(id)]).first, let sealed = row[0].data else { throw Self.dataMissing }
        guard row[1].int ?? 0 > 0 else {
            guard let text = try? crypto.open(sealed, context: "\(id).text") else { throw Self.dataMissing }
            return text
        }
        guard let file = try? Data(contentsOf: payloadFile(id)), let text = try? crypto.open(file, context: "\(id).payload") else { throw Self.dataMissing }
        return text
    }

    public func payload(_ id: String) throws -> [String: Data] {
        let crypto = try requireCrypto()
        switch cache[id]?.content {
        case .image(let type, _, _):
            guard let sealed = try? Data(contentsOf: payloadFile(id)),
                  let data = try? crypto.openData(sealed, context: "\(id).payload") else { throw Self.dataMissing }
            return [type: data]
        case .rich:
            guard let sealed = try db.scalar("SELECT rich FROM items WHERE id=?1", [.text(id)])?.data,
                  let plist = try? crypto.openData(sealed, context: "\(id).rich"),
                  let data = try? PropertyListDecoder().decode([String: Data].self, from: plist) else { throw Self.dataMissing }
            return data
        default:
            throw Self.dataMissing
        }
    }

    public func thumbnail(_ id: String) throws -> Data? {
        let crypto = try requireCrypto()
        guard let sealed = try db.scalar("SELECT thumbnail FROM items WHERE id=?1", [.text(id)])?.data else { return nil }
        return try? crypto.openData(sealed, context: "\(id).thumbnail")
    }

    public func formatCounts() throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for row in try db.query("SELECT format, COUNT(*) FROM items GROUP BY format") {
            if let format = row[0].string { counts[format] = row[1].int }
        }
        return counts
    }

    public func storedBytes() throws -> Int { try db.scalar("SELECT COALESCE(SUM(\(Self.bytesSQL)), 0) FROM items")?.int ?? 0 }

    private func storedBytes(_ id: String) throws -> Int {
        try db.scalar("SELECT \(Self.bytesSQL) FROM items WHERE id=?1", [.text(id)])?.int ?? 0
    }

    private static func sealedInline(_ clip: ClipCapture, id: String, crypto: ClipboardCrypto) throws -> Data {
        try crypto.seal(ClipItem.prefix(clip.text, bytes: ClipItem.inlineBytes), context: "\(id).text")
    }

    private static func sealedRich(_ clip: ClipCapture, id: String, crypto: ClipboardCrypto) throws -> Data? {
        guard clip.content == .rich else { return nil }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try crypto.seal(try encoder.encode(clip.data), context: "\(id).rich")
    }

    private func payloadFile(_ id: String) -> URL { payloads.appendingPathComponent(id) }

    private func writePayload(_ clip: ClipCapture, id: String, crypto: ClipboardCrypto) throws -> Int {
        let data: Data
        switch clip.content {
        case .image(let type, _, _):
            guard let image = clip.data[type] else { throw CueError.storage() }
            data = image
        case .plain, .rich:
            guard clip.text.utf8.count > ClipItem.inlineBytes else { return 0 }
            data = Data(clip.text.utf8)
        case .files:
            return 0
        }
        let sealed = try crypto.seal(data, context: "\(id).payload")
        let manager = FileManager.default
        try manager.createDirectory(at: payloads, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: payloads.path)
        try sealed.write(to: payloadFile(id), options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: payloadFile(id).path)
        return sealed.count
    }

    private func removePayload(_ id: String) {
        try? FileManager.default.removeItem(at: payloadFile(id))
    }

    private func sweepPayloads() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: payloads.path)) ?? []
        guard !names.isEmpty, let rows = try? db.query("SELECT id FROM items WHERE file_bytes > 0") else { return }
        let live = Set(rows.compactMap { $0[0].string })
        for name in names where !live.contains(name) { removePayload(name) }
    }

    private static func expiry(sensitive: Bool, settings: ClipboardSettings, now: Date) -> Date? {
        sensitive && settings.sensitive == .maskAndExpire ? now.addingTimeInterval(SensitiveText.lifetime) : nil
    }

    public func markUsed(_ id: String, now: Date) throws {
        let (stamp, date) = Self.stamp(now)
        try db.execute("UPDATE items SET last_used_at=?1 WHERE id=?2", [.text(stamp), .text(id)])
        cache[id]?.lastUsedAt = date
    }

    public func setPinboard(_ id: String, _ pinboardID: String?) throws {
        if let pinboardID, !pinboards.contains(where: { $0.id == pinboardID }) { throw CueError.validation("That pinboard no longer exists.") }
        let expiry = pinboardID == nil ? Self.expiry(sensitive: cache[id]?.sensitive ?? false, settings: settings, now: Date()) : nil
        try db.execute("UPDATE items SET pinboard_id=?1, expires_at=?2 WHERE id=?3",
                       [SQLValue(pinboardID), expiry.map { .text(Timestamp.iso($0)) } ?? .null, .text(id)])
        cache[id]?.pinboardID = pinboardID
        cache[id]?.expiresAt = expiry
    }

    public func delete(_ id: String) throws {
        try db.execute("DELETE FROM items WHERE id=?1", [.text(id)])
        cache[id] = nil
        removePayload(id)
        try checkpoint()
    }

    @discardableResult
    public func purge(now: Date) throws -> Int {
        let doomed = ClipboardPurge.select(try purgeCandidates(), now: now, retention: settings.retention, maxItems: settings.maxItems, maxBytes: settings.maxStorage)
        try remove(doomed)
        return doomed.count
    }

    public func recentCount(in window: ClosedRange<Date>) throws -> Int {
        ClipboardPurge.recent(try purgeCandidates(), in: window).count
    }

    @discardableResult
    public func deleteRecent(in window: ClosedRange<Date>) throws -> Int {
        let doomed = ClipboardPurge.recent(try purgeCandidates(), in: window)
        try remove(doomed)
        return doomed.count
    }

    private func purgeCandidates() throws -> [PurgeCandidate] {
        try db.query("SELECT id, last_used_at, pinboard_id, expires_at, \(Self.bytesSQL) FROM items").compactMap { row in
            guard let id = row[0].string else { return nil }
            let used = row[1].string.flatMap(Timestamp.parse) ?? .distantPast
            return PurgeCandidate(id: id, lastUsedAt: used, pinned: row[2] != .null, expiresAt: row[3].string.flatMap(Timestamp.parse), bytes: row[4].int ?? 0)
        }
    }

    private func remove(_ ids: Set<String>) throws {
        guard !ids.isEmpty else { return }
        try db.transaction {
            for id in ids { try db.execute("DELETE FROM items WHERE id=?1", [.text(id)]) }
        }
        for id in ids {
            cache[id] = nil
            removePayload(id)
        }
        try checkpoint()
    }

    public func clear(keepPinned: Bool) throws {
        try db.execute(keepPinned ? "DELETE FROM items WHERE pinboard_id IS NULL" : "DELETE FROM items")
        cache = cache.filter { keepPinned && $0.value.isPinned }
        sweepPayloads()
        try checkpoint()
    }

    public func resetHistory() throws {
        try db.transaction {
            try db.execute("DELETE FROM items")
            try db.execute("DELETE FROM meta WHERE key='key_check'")
        }
        crypto = nil
        cache = [:]
        sweepPayloads()
        try checkpoint()
    }

    public func createPinboard(_ name: String) throws -> Pinboard {
        let board = Pinboard(id: Self.newID(), name: try Pinboard.validName(name, existing: pinboards))
        try db.execute("INSERT INTO pinboards(id, name, position) VALUES(?1, ?2, (SELECT COALESCE(MAX(position), -1) + 1 FROM pinboards))",
                       [.text(board.id), .text(board.name)])
        pinboards.append(board)
        return board
    }

    public func defaultPinboard() throws -> Pinboard {
        try pinboards.first ?? createPinboard("Pinned")
    }

    public func renamePinboard(_ id: String, to name: String) throws {
        let clean = try Pinboard.validName(name, existing: pinboards, excluding: id)
        try db.execute("UPDATE pinboards SET name=?1 WHERE id=?2", [.text(clean), .text(id)])
        if let index = pinboards.firstIndex(where: { $0.id == id }) { pinboards[index].name = clean }
    }

    public func deletePinboard(_ id: String) throws {
        let now = Date()
        let affected = cache.filter { $0.value.pinboardID == id }
        try db.transaction {
            try db.execute("DELETE FROM pinboards WHERE id=?1", [.text(id)])
            for (itemID, item) in affected {
                guard let expiry = Self.expiry(sensitive: item.sensitive, settings: settings, now: now) else { continue }
                try db.execute("UPDATE items SET expires_at=?1 WHERE id=?2", [.text(Timestamp.iso(expiry)), .text(itemID)])
            }
        }
        pinboards.removeAll { $0.id == id }
        for (itemID, item) in affected {
            cache[itemID]?.pinboardID = nil
            cache[itemID]?.expiresAt = Self.expiry(sensitive: item.sensitive, settings: settings, now: now)
        }
    }

    public func save(_ settings: ClipboardSettings) throws {
        try settings.validate()
        try Self.write(settings, db)
        self.settings = settings
    }

    public func setCaptureEnabled(_ enabled: Bool) throws {
        try db.execute("INSERT OR REPLACE INTO meta(key, value) VALUES('capture', ?1)", [SQLValue(enabled)])
        captureEnabled = enabled
        capturePaused = !enabled
    }

    public func exportData(now: Date) throws -> ClipboardExport.Result {
        if crypto == nil, try itemCount() > 0 { throw Self.keyUnavailable }
        var file = ClipboardExport(schemaVersion: ClipboardExport.currentVersion, exportedAt: Timestamp.iso(now), settings: settings, pinboards: pinboards, items: [])
        var room = ClipboardExport.maxBytes - (try file.encoded().count)
        var leftOut = 0
        let exportable = items().filter(\.isExportable)
        for item in exportable.filter(\.isPinned) + exportable.filter({ !$0.isPinned }) {
            guard room > 0, let text = item.isTruncated ? try? fullText(item.id) : item.text, text.utf8.count <= ClipboardExport.maxItemBytes else {
                leftOut += 1
                continue
            }
            let entry = ClipboardExport.Item(id: item.id, text: text, createdAt: Timestamp.iso(item.createdAt), lastUsedAt: Timestamp.iso(item.lastUsedAt), pinboardID: item.pinboardID)
            let size = try ClipboardExport.encoder.encode(entry).count + ClipboardExport.itemOverhead
            guard size <= room else {
                room = 0
                leftOut += 1
                continue
            }
            room -= size
            file.items.append(entry)
        }
        let data = try file.encoded()
        _ = try ClipboardExport.decode(data)
        return ClipboardExport.Result(data: data, exported: file.items.count, leftOut: leftOut)
    }

    public func importData(_ data: Data) throws {
        let file = try ClipboardExport.decode(data)
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
        if let crypto { try load(crypto) } else { sweepPayloads() }
        try checkpoint()
    }

    private final class ChunkResults: @unchecked Sendable {
        let pointer: UnsafeMutableBufferPointer<[ClipItem]>
        init(count: Int) { pointer = .allocate(capacity: count); pointer.initialize(repeating: []) }
        deinit { pointer.deinitialize(); pointer.deallocate() }
    }

    private static func decode(_ row: [SQLValue], crypto: ClipboardCrypto) -> ClipItem? {
        guard let id = row[0].string, let sealed = row[1].data, let text = try? crypto.open(sealed, context: "\(id).text"),
              let created = row[3].string.flatMap(Timestamp.parse), let used = row[4].string.flatMap(Timestamp.parse),
              let content = Self.content(format: row[8].string, meta: row[9].data, id: id, crypto: crypto)
        else { return nil }
        let source = row[2].data.flatMap { try? crypto.open($0, context: "\(id).source") }
        let ocrText = row[12].data.flatMap { try? crypto.open($0, context: "\(id).ocr") }
        return ClipItem(id: id, text: text, source: source, createdAt: created, lastUsedAt: used, pinboardID: row[5].string,
                        sensitive: row[6].int == 1, expiresAt: row[7].string.flatMap(Timestamp.parse), content: content, byteSize: row[10].int ?? 0,
                        truncated: row[11].int ?? 0 > 0, ocrText: ocrText)
    }

    private func load(_ crypto: ClipboardCrypto) throws {
        let rows = try db.query("SELECT id, text, source, created_at, last_used_at, pinboard_id, sensitive, expires_at, format, meta, \(Self.bytesSQL), file_bytes, ocr_text FROM items")
        var cache: [String: ClipItem] = [:]
        cache.reserveCapacity(rows.count)
        if rows.count > 64 {
            let ranges = ParallelChunks.ranges(count: rows.count, maxParts: ProcessInfo.processInfo.activeProcessorCount)
            let results = ChunkResults(count: ranges.count)
            DispatchQueue.concurrentPerform(iterations: ranges.count) { chunk in
                results.pointer[chunk] = rows[ranges[chunk]].compactMap { Self.decode($0, crypto: crypto) }
            }
            for chunk in results.pointer { for item in chunk { cache[item.id] = item } }
        } else {
            for row in rows { if let item = Self.decode(row, crypto: crypto) { cache[item.id] = item } }
        }
        self.crypto = crypto
        self.cache = cache
        sweepPayloads()
    }

    private static func content(format: String?, meta: Data?, id: String, crypto: ClipboardCrypto) -> ClipContent? {
        switch format {
        case "plain": .plain
        case "rich": .rich
        case "image", "files":
            meta.flatMap { try? crypto.openData($0, context: "\(id).meta") }.flatMap { try? JSONDecoder().decode(ClipContent.self, from: $0) }
        default: nil
        }
    }

    private func requireCrypto() throws -> ClipboardCrypto {
        guard let crypto else { throw Self.keyUnavailable }
        return crypto
    }

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

    private static func stamp(_ date: Date) -> (String, Date) {
        let text = Timestamp.iso(date)
        return (text, Timestamp.parse(text) ?? date)
    }

    static func newID() -> String { UUID().uuidString.lowercased() }
}

public struct ClipboardExport: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let maxBytes = 20 * 1024 * 1024
    public static let maxItemBytes = 256 * 1024
    static let itemOverhead = 64

    public struct Result: Equatable, Sendable {
        public let data: Data
        public let exported: Int
        public let leftOut: Int
    }

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
            try c.encode(pinboardID, forKey: .pinboardID)
        }
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public func encoded() throws -> Data { try Self.encoder.encode(self) }

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
            if CaptureFilter.textProblem(item.text, limit: maxItemBytes) != nil { throw .validation("Item \(n) is empty or larger than 256 KB.") }
            guard let created = Timestamp.parse(item.createdAt), let used = Timestamp.parse(item.lastUsedAt) else {
                throw .validation("Item \(n) has an invalid date.")
            }
            if let board = item.pinboardID, !boardIDs.contains(board) { throw .validation("Item \(n) refers to a pinboard that is not in the file.") }
            file.items[index].createdAt = Timestamp.iso(created)
            file.items[index].lastUsedAt = Timestamp.iso(used)
        }
        return file
    }

    public static func lossWarning(_ counts: [String: Int]) -> String? {
        func entries(_ count: Int?, _ one: String, _ many: String) -> String? {
            guard let count, count > 0 else { return nil }
            return count == 1 ? "1 \(one)" : "\(count) \(many)"
        }
        var parts = [entries(counts["image"], "image", "images"), entries(counts["files"], "file entry", "file entries")].compactMap { $0 }
        if let rich = entries(counts["rich"], "rich text entry", "rich text entries") { parts.append("the formatting of \(rich)") }
        guard let last = parts.last else { return nil }
        let list = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and \(last)" : last
        return list.prefix(1).uppercased() + list.dropFirst() + " will be lost."
    }

    static func isCanonicalID(_ id: String) -> Bool { UUID(uuidString: id)?.uuidString.lowercased() == id }
}
