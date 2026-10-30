import Foundation
import Testing
@testable import CueKit

@Suite struct CoreTests {
    @Test func transactionRollsBackOnError() throws {
        let db = try SQLite()
        try db.executeScript("CREATE TABLE t(v INTEGER)")
        #expect(throws: CueError.self) {
            try db.transaction {
                try db.execute("INSERT INTO t VALUES(?1)", [1])
                throw CueError.validation("stop")
            }
        }
        #expect(try db.scalar("SELECT COUNT(*) FROM t")?.int == 0)
    }

    @Test func backupsRetainNewestFiveConsistentCopies() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try SQLite(path: dir.appendingPathComponent("cue.sqlite3"))
        try db.executeScript("CREATE TABLE t(v TEXT); INSERT INTO t VALUES('x');")
        for _ in 0..<7 { try db.backup(into: dir.appendingPathComponent("backups"), prefix: "cue") }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("backups").path)
        #expect(files.count == 5)
        for file in files {
            let copy = try SQLite(path: dir.appendingPathComponent("backups").appendingPathComponent(file))
            #expect(try copy.scalar("SELECT COUNT(*) FROM t")?.int == 1)
        }
    }

    @Test func safeFilenames() {
        let date = Date(timeIntervalSince1970: 1_792_670_100)
        #expect(SafeFilename.make("../etc/passwd", ext: "json") == "etc-passwd.json")
        #expect(SafeFilename.make("  ..hidden  ", ext: "txt") == "hidden.txt")
        #expect(SafeFilename.make("a:b*c?\n", ext: "JSON!") == "a-b-c.json")
        #expect(SafeFilename.make("", ext: "txt") == "Cue.txt")
        #expect(SafeFilename.make("Cue Diagnostics", ext: "txt", date: date) == "Cue Diagnostics 2026-10-22 115500.txt")
        #expect(SafeFilename.make(String(repeating: "é", count: 200), ext: "txt").unicodeScalars.count == 84)
    }

    @Test func shortcutsRoundTripTheStoredFormat() throws {
        let palette = try #require(Shortcut("Super+Shift+Space"))
        #expect(palette.command && palette.shift && !palette.control)
        #expect(palette.description == "Super+Shift+Space")
        #expect(palette.display == "⇧⌘Space")
        #expect(palette.keyCode == 0x31)
        #expect(Shortcut("CommandOrControl+Alt+v")?.description == "Super+Alt+V")
        #expect(Shortcut("Shift+A") == nil)
        #expect(Shortcut("Shift+F5") != nil)
        #expect(Shortcut("Super+Nope") == nil)
        #expect(Shortcut("Space") == nil)
        #expect(Shortcut(keyCode: 0x09, command: true, control: false, option: false, shift: true)?.description == "Super+Shift+V")
    }

    @Test func controlCharactersAreReportedByScalarPosition() {
        #expect(TextLimits.firstInvalidControl(in: "ok\ttab\nline\r") == nil)
        #expect(TextLimits.firstInvalidControl(in: "🇧🇷\u{1b}") == 3)
        #expect(TextLimits.firstInvalidControl(in: "\u{7f}") == 1)
    }

    @Test func shortAgesReadLikeTheDesign() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: now)!
        #expect(ShortAge.text(noon.addingTimeInterval(-18), now: noon, calendar: calendar) == "18s")
        #expect(ShortAge.text(noon.addingTimeInterval(-720), now: noon, calendar: calendar) == "12m")
        #expect(ShortAge.text(noon.addingTimeInterval(-10_800), now: noon, calendar: calendar) == "3h")
        #expect(ShortAge.text(noon.addingTimeInterval(-86_400), now: noon, calendar: calendar) == "Yesterday")
        #expect(ShortAge.text(noon.addingTimeInterval(-3 * 86_400), now: noon, calendar: calendar) == "3d")
        #expect(ShortAge.until(noon.addingTimeInterval(61), now: noon) == "2m")
        #expect(ShortAge.until(noon.addingTimeInterval(20), now: noon) == "20s")
    }
}
