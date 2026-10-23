import Foundation
import Testing
@testable import CueKit

@Suite struct MenuBarTests {
    // Always-hidden separator at 300–310, hidden separator at 400–410. Collapsed frames keep the right edge.
    let separators = MenuBarSeparatorFrames(hidden: MenuBarSpan(minX: 400, maxX: 410), alwaysHidden: MenuBarSpan(minX: 300, maxX: 310))

    func item(_ name: String, _ minX: Double, width: Double = 20, movable: Bool = true) -> MenuBarItem {
        MenuBarItem(key: "com.example.\(name)|title:\(name)", bundleID: "com.example.\(name)", appName: name, label: name,
                    frame: MenuBarSpan(minX: minX, maxX: minX + width), movable: movable)
    }

    func rule(_ name: String, _ section: MenuBarSection) -> MenuBarRule {
        MenuBarRule(key: "com.example.\(name)|title:\(name)", bundleID: "com.example.\(name)", label: name, section: section)
    }

    @Test func classifiesBySeparatorRightEdges() {
        func section(_ minX: Double, _ maxX: Double) -> MenuBarSection {
            MenuBarLayout.section(of: MenuBarSpan(minX: minX, maxX: maxX), separators: separators)
        }
        #expect(section(500, 520) == .visible)
        #expect(section(410, 430) == .visible) // starts exactly at the hidden separator's right edge
        #expect(section(400, 420) == .visible) // center exactly on the edge counts as right
        #expect(section(380, 400) == .hidden) // ends exactly at the separator's left edge
        #expect(section(310, 330) == .hidden)
        #expect(section(280, 300) == .alwaysHidden)
        #expect(section(-4150, -4130) == .alwaysHidden) // pushed off-screen by a collapsed separator
        // A collapsed hidden separator spans far left but keeps its right edge.
        let collapsed = MenuBarSeparatorFrames(hidden: MenuBarSpan(minX: -4088, maxX: 928), alwaysHidden: MenuBarSpan(minX: -9000, maxX: -4124))
        #expect(MenuBarLayout.section(of: MenuBarSpan(minX: -4120, maxX: -4100), separators: collapsed) == .hidden)
        #expect(MenuBarLayout.section(of: MenuBarSpan(minX: 930, maxX: 950), separators: collapsed) == .visible)
    }

    @Test func sectionsShiftWithinBounds() {
        #expect(MenuBarSection.visible.shifted(-1) == .hidden)
        #expect(MenuBarSection.hidden.shifted(-1) == .alwaysHidden)
        #expect(MenuBarSection.alwaysHidden.shifted(-1) == .alwaysHidden)
        #expect(MenuBarSection.alwaysHidden.shifted(1) == .hidden)
        #expect(MenuBarSection.visible.shifted(1) == .visible)
    }

    @Test func planSkipsPlacedImmovableAndUnruledItems() {
        let items = [item("a", 320), item("b", 500), item("clock", 600, movable: false), item("free", 700)]
        let rules = [rule("a", .hidden), rule("b", .hidden), rule("clock", .hidden), rule("gone", .visible)]
        #expect(MenuBarLayout.plan(items: items, separators: separators, rules: rules) == [MenuBarMove(key: items[1].key, from: .visible, to: .hidden)])
    }

    @Test func planOrderKeepsRelativePositions() {
        // Into Visible: each drop lands just right of the separator, so the rightmost item goes first.
        // Into hidden sections: each drop lands just left of a separator, so the leftmost item goes first.
        let items = [item("p", 100), item("q", 150), item("r", 500), item("s", 600), item("t", 320)]
        let rules = [rule("p", .visible), rule("q", .visible), rule("s", .alwaysHidden), rule("r", .alwaysHidden), rule("t", .alwaysHidden)]
        let moves = MenuBarLayout.plan(items: items, separators: separators, rules: rules)
        #expect(moves.map { $0.key.split(separator: "|")[1] } == ["title:t", "title:r", "title:s", "title:q", "title:p"])
        #expect(moves.map(\.to) == [.alwaysHidden, .alwaysHidden, .alwaysHidden, .visible, .visible])
        #expect(moves.first?.from == .hidden)
    }

    @Test func dropPointsLandOnTheTargetSide() {
        #expect(MenuBarLayout.dropX(for: .visible, separators: separators) > separators.hidden.maxX)
        let hidden = MenuBarLayout.dropX(for: .hidden, separators: separators)
        #expect(hidden > separators.hidden.minX && hidden < separators.hidden.midX)
        let always = MenuBarLayout.dropX(for: .alwaysHidden, separators: separators)
        #expect(always > separators.alwaysHidden.minX && always < separators.alwaysHidden.midX)
    }

    @Test func keysPreferIdentifierThenTitleThenDescriptionThenIndex() {
        let keys = MenuBarLayout.keys(for: [
            ("com.a", "status", "Title", nil),
            ("com.a", nil, " Title ", "Desc"),
            ("com.a", nil, "", "Desc"),
            ("com.a", nil, nil, nil),
            ("com.b", nil, nil, nil),
            ("com.a", nil, "Title", nil),
        ])
        #expect(keys == ["com.a|id:status", "com.a|title:Title", "com.a|desc:Desc", "com.a|index:3", "com.b|index:0", "com.a|title:Title#2"])
    }

    @Test func rulesUpsertAndMatchByKey() {
        var rules = [rule("a", .hidden)]
        rules = MenuBarRules.upsert(rule("b", .visible), into: rules)
        rules = MenuBarRules.upsert(rule("a", .alwaysHidden), into: rules)
        #expect(rules.map(\.section) == [.alwaysHidden, .visible])
        #expect(MenuBarRules.rule(for: item("b", 0), in: rules)?.section == .visible)
        #expect(MenuBarRules.rule(for: item("c", 0), in: rules) == nil)
    }

    @Test func revealDecisions() {
        let apps = ["com.apple.Safari"]
        #expect(MenuBarReveal.onFrontmostChange(bundleID: "com.apple.Safari", revealApps: apps, revealedBy: nil) == true)
        #expect(MenuBarReveal.onFrontmostChange(bundleID: "com.apple.Safari", revealApps: apps, revealedBy: .user) == nil)
        #expect(MenuBarReveal.onFrontmostChange(bundleID: "com.apple.Notes", revealApps: apps, revealedBy: .frontmostApp) == false)
        #expect(MenuBarReveal.onFrontmostChange(bundleID: "com.apple.Notes", revealApps: apps, revealedBy: .user) == nil)
        #expect(MenuBarReveal.onFrontmostChange(bundleID: nil, revealApps: apps, revealedBy: nil) == nil)

        let start = Date(timeIntervalSince1970: 0)
        func rehide(after seconds: Double, limit: Int = 10, cause: MenuBarReveal.Cause = .user, pointer: Bool = false) -> Bool {
            MenuBarReveal.shouldRehide(now: start.addingTimeInterval(seconds), revealedAt: start, seconds: limit, cause: cause, pointerInMenuBar: pointer)
        }
        #expect(!rehide(after: 9.9))
        #expect(rehide(after: 10))
        #expect(!rehide(after: 100, limit: 0))
        #expect(!rehide(after: 100, cause: .frontmostApp))
        #expect(!rehide(after: 100, pointer: true))
    }

    @Test func validatesInput() throws {
        #expect(MenuBarValidation.isBundleID("com.apple.Safari"))
        #expect(MenuBarValidation.isBundleID("org.mozilla.firefox_beta-2"))
        #expect(!MenuBarValidation.isBundleID("Safari"))
        #expect(!MenuBarValidation.isBundleID("com..apple"))
        #expect(!MenuBarValidation.isBundleID("com.apple.Safari "))
        #expect(!MenuBarValidation.isBundleID("com.apple/x"))
        #expect(try MenuBarValidation.rehideSeconds(" 0 ") == 0)
        #expect(try MenuBarValidation.rehideSeconds("3600") == 3600)
        #expect(throws: CueError.self) { try MenuBarValidation.rehideSeconds("3601") }
        #expect(throws: CueError.self) { try MenuBarValidation.rehideSeconds("-1") }
        #expect(throws: CueError.self) { try MenuBarValidation.rehideSeconds("1.5") }
    }

    @Test func codecRejectsInvalidFiles() throws {
        func document(settings: String = #"{"autoRehideSeconds":10,"revealApps":[],"shortcut":"Super+Alt+B"}"#,
                      rules: String = "[]", version: Int = 1) -> Data {
            Data(#"{"schemaVersion":\#(version),"exportedAt":"2026-10-22T10:00:00.000Z","settings":\#(settings),"rules":\#(rules)}"#.utf8)
        }
        func code(_ data: Data) -> String? {
            do { _ = try MenuBarTransfer.decode(data); return nil } catch { return error.code }
        }
        let good = #"{"key":"com.a.b|title:X","bundleID":"com.a.b","label":"X","section":"hidden"}"#
        #expect(code(document(rules: "[\(good)]")) == nil)
        #expect(code(Data("not json".utf8)) == "IMPORT_INVALID")
        #expect(code(document(version: 2)) == "IMPORT_UNSUPPORTED")
        #expect(code(document(rules: #"[{"key":"com.a.b|x","bundleID":"com.a.b","label":"X","section":"sideways"}]"#)) == "IMPORT_INVALID")
        #expect(code(document(rules: #"[{"key":"com.other|x","bundleID":"com.a.b","label":"X","section":"hidden"}]"#)) == "VALIDATION")
        #expect(code(document(rules: #"[{"key":"com.a.b|","bundleID":"com.a.b","label":"X","section":"hidden"}]"#)) == "VALIDATION")
        #expect(code(document(rules: #"[{"key":"bad|x","bundleID":"bad","label":"X","section":"hidden"}]"#)) == "VALIDATION")
        #expect(code(document(rules: #"[{"key":"com.a.b|x","bundleID":"com.a.b","label":"\u001b","section":"hidden"}]"#)) == "VALIDATION")
        #expect(code(document(rules: "[\(good),\(good)]")) == "VALIDATION")
        #expect(code(document(settings: #"{"autoRehideSeconds":3601,"revealApps":[],"shortcut":null}"#)) == "VALIDATION")
        #expect(code(document(settings: #"{"autoRehideSeconds":5,"revealApps":["nope"],"shortcut":null}"#)) == "VALIDATION")
        #expect(code(document(settings: #"{"autoRehideSeconds":5,"revealApps":[],"shortcut":"Shift+A"}"#)) == "VALIDATION")
        #expect(code(document(settings: #"{"autoRehideSeconds":5,"revealApps":[]}"#)) == nil) // no shortcut
        #expect(code(Data(count: MenuBarTransfer.maxBytes + 1)) == "OUTPUT_TOO_LARGE")
    }

    @Test func storeRefusesNewerSchemaWithoutResetting() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("menubar.sqlite3")
        _ = try MenuBarStore(url: url)
        try SQLite(path: url).executeScript("INSERT INTO rules VALUES('k','com.a.b','L','hidden','t'); PRAGMA user_version = 9;")
        #expect(throws: CueError("STORAGE_NEWER", "Menu bar data was saved by a newer version of Cue. Update Cue to use it. Your data has not been changed.")) {
            _ = try MenuBarStore(url: url)
        }
        #expect(try SQLite(path: url).scalar("SELECT COUNT(*) FROM rules")?.int == 1)
    }

    /// Store → rules → plan → export → import into a fresh store → identical rules and plan.
    @Test func endToEndHappyPath() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MenuBarStore(url: dir.appendingPathComponent("a/menubar.sqlite3"))
        var settings = MenuBarSettings()
        settings.enabled = true
        settings.autoRehideSeconds = 30
        settings.revealApps = ["com.apple.Safari"]
        settings.shortcut = nil
        try await store.save(settings)
        for rule in [rule("a", .hidden), rule("b", .visible), rule("c", .alwaysHidden)] { try await store.upsert(rule) }
        try await store.upsert(rule("a", .alwaysHidden))
        try await store.upsert(rule("gone", .hidden))
        try await store.deleteRule(key: rule("gone", .hidden).key)

        let loaded = try await store.load()
        #expect(loaded.settings == settings)
        #expect(loaded.rules == [rule("a", .alwaysHidden), rule("b", .visible), rule("c", .alwaysHidden)])

        let items = [item("a", 500), item("b", 320), item("c", 200), item("d", 600)]
        let plan = MenuBarLayout.plan(items: items, separators: separators, rules: loaded.rules)
        #expect(plan == [MenuBarMove(key: items[0].key, from: .visible, to: .alwaysHidden), MenuBarMove(key: items[1].key, from: .hidden, to: .visible)])

        let data = try MenuBarTransfer.encode(settings: loaded.settings, rules: loaded.rules, exportedAt: Date())
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["schemaVersion"] as? Int == 1)
        #expect((json["settings"] as? [String: Any])?["enabled"] == nil)

        let fresh = try MenuBarStore(url: dir.appendingPathComponent("b/menubar.sqlite3"))
        let decoded = try MenuBarTransfer.decode(data)
        try await fresh.importConfig(settings: decoded.settings, rules: decoded.rules)
        let imported = try await fresh.load()
        #expect(imported.rules == loaded.rules)
        #expect(imported.settings.autoRehideSeconds == 30 && imported.settings.revealApps == ["com.apple.Safari"] && imported.settings.shortcut == nil)
        #expect(imported.settings.enabled == false) // import never turns the feature on
        #expect(MenuBarLayout.plan(items: items, separators: separators, rules: imported.rules) == plan)
    }
}
