import Foundation
import Testing
@testable import CueKit

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
    return try Data(contentsOf: url)
}

private func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("cue-tests-\(UUID().uuidString)")
}

private func sample(_ name: String = "Test", template: String = "Hello {{date}}", category: String? = "Coding") -> Action {
    Action(name: name, template: template, category: category)
}

@Suite struct TemplateTests {
    @Test func usesOnePassAndOneInstant() throws {
        #expect(try Template.render("{{clipboard}} {{date}} {{date}} {{time}}", clipboard: "{{date}}", date: "2026-10-06", time: "13:05")
            == "{{date}} 2026-10-06 2026-10-06 13:05")
        let instant = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 13, minute: 5)))
        #expect(try Template.renderLocal("{{date}} {{time}}", clipboard: "", now: instant) == "2026-10-06 13:05")
    }

    @Test func pairedAndUnpairedEscapes() throws {
        #expect(try Template.render(#"\{{date}} \\{{date}} \\\{{date}}"#, clipboard: "x", date: "DATE", time: "TIME")
            == #"{{date}} \DATE \{{date}}"#)
    }

    @Test func rejectsControlsButKeepsBracesAndUnicode() throws {
        for text in ["hello\u{1b}", "\0"] {
            #expect(throws: CueError.self) { try Template.render(text, clipboard: "x", date: "d", time: "t") }
        }
        #expect(try Template.render(#"{"ok":true} Olá 😃\#n  text"#, clipboard: "", date: "d", time: "t") == "{\"ok\":true} Olá 😃\n  text")
    }

    @Test func otherPlaceholderLanguagesStayLiteral() throws {
        let cases = try JSONDecoder().decode([String].self, from: fixture("literal-placeholders.json"))
        for template in cases {
            #expect(try Template.render(template, clipboard: "clipboard text", date: "DATE", time: "TIME") == template)
            #expect(try !Template.needsClipboard(template))
        }
        #expect(try Template.render("@{{upstream}} {{clipboard}} {{date}} {{time}}", clipboard: "text", date: "DATE", time: "TIME")
            == "@{{upstream}} text DATE TIME")
    }

    @Test func readsClipboardOnlyForAnUnescapedToken() throws {
        #expect(try Template.needsClipboard("{{clipboard}}"))
        #expect(try !Template.needsClipboard(#"\{{clipboard}}"#))
        #expect(try !Template.needsClipboard("\u{e000}"))
        #expect(try Template.render("{{clipboard}}", clipboard: " \r\n ", date: "d", time: "t") == " \r\n ")
    }

    @Test func largeOutputFailsInsteadOfTruncating() {
        #expect(throws: CueError.self) {
            try Template.render("{{clipboard}}{{clipboard}}", clipboard: String(repeating: "x", count: 600_000), date: "d", time: "t")
        }
    }

    @Test func limitsCountUnicodeScalarsNotGraphemes() throws {
        var ok = sample(String(repeating: "🇧🇷", count: 50))
        try ActionRules.validate(&ok)
        var tooLong = sample(String(repeating: "🇧🇷", count: 50) + "x")
        #expect(throws: CueError.self) { try ActionRules.validate(&tooLong) }
    }

    @Test func validationNormalizesListsAndLineEndings() throws {
        var a = sample()
        a.template = "a\r\nb\rc"
        a.aliases = [" Fix ", "fix", "FIX build"]
        try ActionRules.validate(&a)
        #expect(a.template == "a\nb\nc")
        #expect(a.aliases == ["Fix", "FIX build"])
        var bad = sample()
        bad.id = "not-a-uuid"
        #expect(throws: CueError.self) { try ActionRules.validate(&bad) }
    }

    @Test func replaceRequiresTheSelectionToken() throws {
        var missing = sample(template: "Fix {{clipboard}}")
        missing.deliveryMode = .replace
        #expect(throws: CueError.validation("Add {{selection}} to the text to use Replace selection.")) { try ActionRules.validate(&missing) }
        var escaped = sample(template: #"Fix \{{selection}}"#)
        escaped.deliveryMode = .replace
        #expect(throws: CueError.self) { try ActionRules.validate(&escaped) }
        var ok = sample(template: "Fix {{selection}}")
        ok.deliveryMode = .replace
        try ActionRules.validate(&ok)
        ok.deliveryMode = .copy
        ok.template = "Fix {{clipboard}}"
        try ActionRules.validate(&ok)
    }

    @Test func replaceSurvivesEncoding() throws {
        var action = sample(template: "Fix {{selection}}")
        action.deliveryMode = .replace
        let decoded = try JSONDecoder().decode(Action.self, from: JSONEncoder().encode(action))
        #expect(decoded.deliveryMode == .replace)
        let exported = try JSONDecoder().decode(ExportAction.self, from: JSONEncoder().encode(action.export))
        #expect(exported.deliveryMode == .replace)
        #expect(String(decoding: try JSONEncoder().encode(DeliveryMode.replace), as: UTF8.self) == #""replace""#)
    }
}

@Suite struct SearchTests {
    private func a(_ name: String, aliases: [String] = [], tags: [String] = [], category: String? = nil,
                   favorite: Bool = false, enabled: Bool = true, template: String = "Text", lastUsedAt: String? = nil) -> Action {
        var action = Action(name: name, template: template, aliases: aliases, tags: tags, category: category, favorite: favorite, enabled: enabled)
        action.lastUsedAt = lastUsedAt
        return action
    }

    @Test func exactRanksAboveFavoriteFuzzy() {
        let exact = a("Resolve CI")
        #expect(ActionSearch.search([a("Resolve complicated issue", favorite: true), exact], query: "resolve ci").first?.id == exact.id)
    }

    @Test func exactKeywordTiesExactNameAndBeatsWeakerMatches() throws {
        #expect(ActionSearch.score("dia", name: "Dia")?.tier == -1)
        #expect(ActionSearch.score("dia", name: "Fix Text", fields: [("dia", 1)])?.tier == -1)
        #expect(ActionSearch.score("dia", name: "Fix Text", fields: [("dia", 2)])?.tier == 0)
        let exact = a("Fix Text", aliases: ["dia"]), fuzzy = a("Next Display")
        #expect(ActionSearch.search([fuzzy, exact], query: "dia") == [exact, fuzzy])
        let fuzzyTier = try #require(ActionSearch.score("dia", name: "Next Display")?.tier)
        #expect(try #require(ActionSearch.score("movit", name: "Movitera Link")?.tier) < fuzzyTier)
    }

    @Test func preparedQueryScoresLikeOneShotScore() {
        let queries = ["dia", "resolve ci", "résumé", "  fix  text ", "zzzz", ""]
        let names = [("Dia", [(String, Int)]()), ("Fix Text", [("dia", 1), ("write", 2)]), ("Résumé Review", [("cv", 1)]), ("Next Display", [])]
        for query in queries {
            let prepared = ActionSearch.prepare(query)
            for (name, fields) in names {
                let oneShot = ActionSearch.score(query, name: name, fields: fields)
                let batched = prepared.score(name: name, fields: fields)
                #expect(oneShot?.tier == batched?.tier && oneShot?.weight == batched?.weight, "\(query) / \(name)")
            }
            let actions = names.map { a($0.0, aliases: $0.1.filter { $0.1 == 1 }.map(\.0)) }
            #expect(ActionSearch.scored(actions, query: query).map(\.action.id) == ActionSearch.scored(actions, query: prepared).map(\.action.id))
        }
    }

    @Test func accentsAliasesTokensAndTypos() {
        let action = a("Revisão", aliases: ["resolve CI"], tags: ["git"], category: "Coding")
        #expect(ActionSearch.search([action], query: "revisao") == [action])
        #expect(ActionSearch.search([action], query: "res ci git") == [action])
        #expect(ActionSearch.search([action], query: "rslv") == [action])
        let emoji = a("🚀 Resolve CI")
        #expect(ActionSearch.search([emoji], query: "🚀ci") == [emoji])
        #expect(ActionSearch.search([action], query: "rslv missing").isEmpty)
    }

    @Test func excludesDisabledAndBodies() {
        #expect(ActionSearch.search([a("disabled", enabled: false), a("other", template: "secret")], query: "disabled").isEmpty)
        #expect(ActionSearch.search([a("other", template: "secret")], query: "secret").isEmpty)
    }

    @Test func favoritesThenRecentsThenNames() {
        let favorite = a("Z", favorite: true), recent = a("B", lastUsedAt: "2026-10-06T12:00:00Z"), alpha = a("A")
        #expect(ActionSearch.search([alpha, recent, favorite], query: "") == [favorite, recent, alpha])
    }
}

@Suite struct PromptStoreTests {
    @Test func legacyMigrationPreservesActionsAndRunsOnce() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var action = sample()
        action.deliveryMode = .copy
        do {
            let store = try PromptStore(directory: dir)
            try await store.save(action)
        }
        do {
            let raw = try SQLite(path: dir.appendingPathComponent("cue.sqlite3"))
            try raw.executeScript("UPDATE settings SET data=json_set(data, '$.defaultDelivery', 'copy', '$.keepRunning', json('false')); DELETE FROM schema_migrations WHERE version=2; PRAGMA user_version=1;")
        }
        let store = try PromptStore(directory: dir)
        #expect(try await store.settings().defaultDelivery == .paste)
        #expect(try await store.settings().keepRunning)
        #expect(try await store.get(action.id).deliveryMode == .copy)
        #expect(try await store.get(action.id).template == action.template)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("backups").path).count == 1)
        #expect(try SQLite(path: dir.appendingPathComponent("cue.sqlite3")).userVersion() == 4)
        _ = try PromptStore(directory: dir)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("backups").path).count == 1)
    }

    @Test func readsRowsWrittenByTheRustVersion() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try PromptStore(directory: dir)
        let raw = try SQLite(path: dir.appendingPathComponent("cue.sqlite3"))
        let json = #"{"id":"0b7c1c1e-6a4f-4a8e-9a43-1f9f7f6f2a10","name":"Legacy","description":"","template":"Hi {{clipboard}}","aliases":[],"tags":["x"],"category":null,"deliveryMode":"inherit","favorite":true,"enabled":true,"revision":3,"useCount":7,"lastUsedAt":"2026-10-06T12:00:00.123456789+00:00","createdAt":"2026-10-01T00:00:00+00:00","updatedAt":"2026-10-02T00:00:00+00:00"}"#
        try raw.execute("INSERT INTO actions VALUES('0b7c1c1e-6a4f-4a8e-9a43-1f9f7f6f2a10',3,?1)", [.text(json)])
        try raw.execute(#"UPDATE settings SET data='{"theme":"dark","defaultDelivery":"copy","onboarded":true,"paletteShortcut":"Super+Shift+K","launchAtLogin":false,"keepRunning":true,"preview":false}'"#)
        let store = try PromptStore(directory: dir)
        let legacy = try await store.get("0b7c1c1e-6a4f-4a8e-9a43-1f9f7f6f2a10")
        #expect(legacy.useCount == 7 && legacy.category == nil && legacy.favorite)
        let settings = try await store.settings()
        #expect(settings.theme == .dark && settings.paletteShortcut == "Super+Shift+K")
        var edited = legacy
        edited.name = "Legacy edited"
        #expect(try await store.save(edited).revision == 4)
    }

    @Test func persistenceAndRevisions() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let saved = try await PromptStore(directory: dir).save(sample())
        #expect(saved.revision == 1)
        var stale = saved
        stale.revision = 0
        await #expect(throws: CueError.self) { try await PromptStore(directory: dir).save(stale) }
        #expect(try await PromptStore(directory: dir).get(saved.id).template == saved.template)
    }

    @Test func publishingPromptRoundTrip() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try PromptStore(directory: dir)
        var text = String(decoding: try fixture("publishing-prompt.txt"), as: UTF8.self)
        while text.hasSuffix("\n") { text.removeLast() }
        let saved = try await store.save(sample("Create PR or Merge Request", template: text))
        let stored = try await store.get(saved.id)
        #expect(stored.template == saved.template)
        #expect(try Template.renderLocal(stored.template, clipboard: "unused") == stored.template)
        #expect(try !Template.needsClipboard(stored.template))
    }

    @Test func importPreviewCommitAndStaleRejection() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try PromptStore(directory: dir)
        let saved = try await store.save(sample())
        let data = try JSONEncoder().encode(ExportFile(actions: [saved.export]))
        let preview = try await store.preview(data)
        #expect(preview.duplicateIDs == 1 && preview.duplicateNames == 1)
        try await store.commitImport(token: preview.token, update: false)
        let snapshot = try await store.snapshot()
        #expect(snapshot.actions.count == 2)
        #expect(snapshot.actions.filter { $0.deliveryMode == .copy }.count == 1)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("backups").path))
        let second = try await store.preview(data)
        try await store.save(sample("Other"))
        await #expect(throws: CueError.self) { try await store.commitImport(token: second.token, update: true) }
    }

    @Test func importedReplaceBecomesCopy() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try PromptStore(directory: dir)
        var action = sample(template: "Fix {{selection}}")
        action.deliveryMode = .replace
        let saved = try await store.save(action)
        #expect(try await store.get(saved.id).deliveryMode == .replace)
        let preview = try await store.preview(try JSONEncoder().encode(ExportFile(actions: [saved.export])))
        try await store.commitImport(token: preview.token, update: true)
        #expect(try await store.get(saved.id).deliveryMode == .copy)
    }

    @Test func invalidImportChangesNothing() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try PromptStore(directory: dir)
        let a = sample().export
        await #expect(throws: CueError.self) { try await store.preview(try JSONEncoder().encode(ExportFile(actions: [a, a]))) }
        await #expect(throws: CueError.self) { try await store.preview(Data(#"{"schemaVersion":1,"exportedAt":"2026-10-06T00:00:00Z","actions":[],"extra":1}"#.utf8)) }
        #expect(try await store.snapshot().actions.isEmpty)
    }

    @Test func newerSchemaIsNotReset() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try PromptStore(directory: dir)
        try SQLite(path: dir.appendingPathComponent("cue.sqlite3")).executeScript("PRAGMA user_version=99")
        #expect(throws: CueError.self) { try PromptStore(directory: dir) }
        #expect(try SQLite(path: dir.appendingPathComponent("cue.sqlite3")).userVersion() == 99)
    }

    @Test func onboardingIsAtomicAndRunsOnce() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try PromptStore(directory: dir)
        let revision = try await store.revision()
        var invalid = sample()
        invalid.template = "invalid\0text"
        await #expect(throws: CueError.self) { try await store.onboard([sample(), invalid], settings: PromptSettings(), revision: revision) }
        #expect(try await store.snapshot().actions.isEmpty)
        #expect(try await !store.settings().onboarded)
        try await store.onboard([sample()], settings: PromptSettings(), revision: revision)
        try await store.onboard([sample()], settings: PromptSettings(), revision: revision)
        #expect(try await store.snapshot().actions.count == 1)
    }

    @Test func categoriesUpdateActionsAndRejectStaleEdits() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try PromptStore(directory: dir)
        let a = try await store.save(sample())
        try await store.category(old: "Coding", name: "Code", revision: try await store.revision())
        #expect(try await store.get(a.id).category == "Code")
        await #expect(throws: CueError.self) { try await store.save(a) }
        try await store.category(old: "Code", name: "", revision: try await store.revision())
        #expect(try await store.snapshot().actions[0].category == nil)
    }

    @Test func endToEndStarterLibrary() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try PromptStore(directory: dir)
        try await store.onboard(Starters.actions(), settings: PromptSettings(), revision: try await store.revision())
        let snapshot = try await store.snapshot()
        let rewrite = try #require(ActionSearch.search(snapshot.actions, query: "rewrite").first)
        #expect(rewrite.name == "Rewrite clearly")
        #expect(try Template.needsClipboard(rewrite.template))
        #expect(try Template.renderLocal(rewrite.template, clipboard: "draft").hasSuffix("Text:\ndraft"))
        try await store.recordUse(rewrite.id)
        #expect(try await store.get(rewrite.id).useCount == 1)
        let exported = try JSONEncoder().encode(try await store.exportFile())
        let fresh = try PromptStore(directory: tempDirectory())
        let preview = try await fresh.preview(exported)
        try await fresh.commitImport(token: preview.token, update: false)
        #expect(try await fresh.snapshot().actions.count == 9)
    }

    @Test func selectionAndQuestionsFillIn() throws {
        let inputs = Template.Inputs(clipboard: "c", selection: "s", answers: ["Tone": "warm"])
        #expect(try Template.renderLocal("{{selection}} {{ask:Tone}} {{clipboard}}", inputs: inputs) == "s warm c")
        let uses = try Template.uses("{{selection}} {{ask}} {{ask:Tone}} {{ask:Tone}}")
        #expect(uses.selection && !uses.clipboard && uses.questions == ["Ask", "Tone"])
        #expect(try Template.uses(#"\{{ask}}"#).questions.isEmpty)
    }

    @Test func segmentsMarkTokens() {
        #expect(Template.segments("Hi {{clipboard}}, {{nope}} {{ask:Tone}}") == [
            .text("Hi "), .token("clipboard"), .text(", {{nope}}"), .text(" "), .token("ask: Tone"),
        ])
    }

    @Test func oldSettingsGainDefaults() throws {
        let decoded = try JSONDecoder().decode(PromptSettings.self, from: Data(#"{"theme":"dark","preview":false}"#.utf8))
        #expect(decoded.previewPane && decoded.searchIn == SearchSource.allCases && decoded.fileLocations == FileLocation.defaults)
    }

    @Test func scriptUseIsRememberedAndCleared() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try PromptStore(directory: dir)
        try await store.recordScriptUse("a.sh")
        #expect(try await store.settings().scriptUsage["a.sh"] != nil)
        try await store.clearUsage()
        #expect(try await store.settings().scriptUsage.isEmpty)
    }
}
