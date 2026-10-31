import CoreGraphics
import Foundation
import Testing
@testable import CueKit

struct CommandTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cue-commands-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func script(_ text: String, in folder: URL, name: String = "tool.sh", executable: Bool = true) throws -> Script {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
        return Script(url: url)
    }

    @Test func dotEnvHandlesExportsQuotesAndComments() {
        let values = DotEnv.parse("# note\nexport A=1\nB = \"two words\"\nC='x=y'\nbad line\nD=\n")
        #expect(values == ["A": "1", "B": "two words", "C": "x=y", "D": ""])
    }

    @Test func credentialsNeedAKeyAndDefaultTheModel() throws {
        let dir = try folder()
        #expect(throws: CueError.self) { try Assistant.credentials(in: dir) }
        try Data("ANTHROPIC_API_KEY=k\n".utf8).write(to: dir.appendingPathComponent(".env"))
        #expect(try Assistant.credentials(in: dir) == .init(key: "k", model: Assistant.defaultModel))
        try Data("ANTHROPIC_API_KEY=k\nANTHROPIC_MODEL=m\n".utf8).write(to: dir.appendingPathComponent(".env"))
        #expect(try Assistant.credentials(in: dir).model == "m")
    }

    @Test func requestUsesCurrentApiShape() throws {
        let request = try Assistant.request("hi", credentials: .init(key: "k", model: "m"))
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "k")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["fallbacks"] as? String == "default")
        #expect(body["temperature"] == nil)
        #expect((body["output_config"] as? [String: String])?["effort"] == "low")
    }

    @Test func replyParsingReadsOnlyTextAndChecksTheStopReason() throws {
        func reply(_ json: String, _ status: Int = 200) throws -> String { try Assistant.parse(Data(json.utf8), status: status) }
        #expect(try reply(#"{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":""},{"type":"text","text":"a"},{"type":"text","text":"b"}]}"#) == "ab")
        func code(_ json: String, _ status: Int = 200) -> String? {
            do { _ = try reply(json, status); return nil } catch { return error.cueError.code }
        }
        #expect(code(#"{"stop_reason":"refusal","content":[]}"#) == "AI_REFUSED")
        #expect(code(#"{"stop_reason":"max_tokens","content":[{"type":"text","text":"cut"}]}"#) == "AI_TRUNCATED")
        #expect(code(#"{"stop_reason":"end_turn","content":[]}"#) == "AI_EMPTY")
        #expect(code(#"{"type":"error","error":{"message":"nope"}}"#, 401) == "AI_KEY_REJECTED")
        #expect(code(#"{"type":"error","error":{"message":"nope"}}"#, 500) == "AI_FAILED")
        #expect(code("not json", 502) == "AI_FAILED")
    }

    @Test func snippetsConvertSingleBracesAndRejectBadFiles() throws {
        #expect(Snippet(keyword: "k", expansion: "{date} {clipboard} {{time}} {other}").template == "{{date}} {{clipboard}} {{time}} {other}")
        #expect(try Snippets.decode(Data(Snippets.sample.utf8)).map(\.keyword) == ["today", "quote"])
        #expect(throws: CueError.self) { try Snippets.decode(Data("{}".utf8)) }
        #expect(try Snippets.load(try folder().appendingPathComponent("missing.json")).isEmpty)
        #expect(try Template.renderLocal(Snippet(keyword: "k", expansion: "> {clipboard}").template, clipboard: "x") == "> x")
    }

    @Test func scriptsListByNameAndRunWithOrWithoutExecuteBit() async throws {
        let dir = try folder()
        let direct = try script("#!/bin/sh\necho hello\n", in: dir, name: "b.sh")
        let plain = try script("echo plain\n", in: dir, name: "a.sh", executable: false)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent(".hidden"))
        #expect(Scripts.list(in: dir).map(\.name) == ["a", "b"])
        #expect(try await Scripts.run(direct) == "hello")
        #expect(try await Scripts.run(plain) == "plain")
    }

    @Test func scriptFailuresTimeoutsAndFloodsAreBounded() async throws {
        let dir = try folder()
        func code(_ script: Script, timeout: TimeInterval = 5, limit: Int = 1024) async -> String? {
            do { _ = try await Scripts.run(script, timeout: timeout, limit: limit); return nil } catch { return error.code }
        }
        let failing = try script("#!/bin/sh\necho oops >&2\nexit 3\n", in: dir, name: "fail.sh")
        do {
            _ = try await Scripts.run(failing)
            Issue.record("Expected a failure")
        } catch {
            #expect(error.code == "SCRIPT_FAILED")
            #expect(error.message == "oops")
        }
        #expect(await code(try script("#!/bin/sh\nsleep 20\n", in: dir, name: "slow.sh"), timeout: 0.2) == "SCRIPT_TIMEOUT")
        #expect(await code(try script("#!/bin/sh\nyes\n", in: dir, name: "flood.sh")) == "OUTPUT_TOO_LARGE")
    }

    @Test func timeoutStopsProcessesTheScriptStarted() async throws {
        let dir = try folder()
        let marker = dir.appendingPathComponent("child.pid")
        let parent = try script("#!/bin/sh\nsleep 30 &\necho $! > '\(marker.path)'\nwait\n", in: dir, name: "parent.sh")
        await #expect(throws: CueError.self) { try await Scripts.run(parent, timeout: 2) }
        let child = try #require(pid_t(String(decoding: try Data(contentsOf: marker), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        try await Task.sleep(for: .milliseconds(200))
        #expect(kill(child, 0) != 0, "The child should die with the script.")
    }

    @Test func assistantNamesTimeoutsSeparately() {
        #expect(Assistant.failure(URLError(.timedOut)).code == "AI_TIMEOUT")
        #expect(Assistant.failure(URLError(.notConnectedToInternet)).code == "AI_UNREACHABLE")
    }

    @Test func itemsAreExposedOnlyOnceTheirSeparatorsCollapse() {
        let narrow = MenuBarSpan(minX: 900, maxX: 924), wide = MenuBarSpan(minX: -9000, maxX: 1000)
        let revealed = MenuBarSeparatorFrames(hidden: narrow, alwaysHidden: wide)
        let collapsed = MenuBarSeparatorFrames(hidden: wide, alwaysHidden: wide)
        let all = MenuBarSeparatorFrames(hidden: narrow, alwaysHidden: narrow)
        #expect(MenuBarLayout.isExposed(.visible, separators: collapsed))
        #expect(!MenuBarLayout.isExposed(.hidden, separators: collapsed))
        #expect(MenuBarLayout.isExposed(.hidden, separators: revealed))
        #expect(!MenuBarLayout.isExposed(.alwaysHidden, separators: revealed))
        #expect(MenuBarLayout.isExposed(.alwaysHidden, separators: all))
    }

    @Test func onlyWindowsHangingFromTheItemCountAsOpen() {
        let item = CGPoint(x: 1000, y: 12)
        #expect(MenuBarLayout.isAnchored(CGRect(x: 800, y: 30, width: 300, height: 400), to: item, barHeight: 40))
        #expect(!MenuBarLayout.isAnchored(CGRect(x: 800, y: 300, width: 300, height: 400), to: item, barHeight: 40), "A floating palette lower down is not the item's menu.")
        #expect(!MenuBarLayout.isAnchored(CGRect(x: 100, y: 30, width: 300, height: 400), to: item, barHeight: 40), "A window elsewhere along the bar is not the item's menu.")
        #expect(!MenuBarLayout.isAnchored(CGRect(x: 980, y: 0, width: 40, height: 24), to: item, barHeight: 40), "The status item itself does not count.")
    }

    @Test func windowFramesFillTheArea() {
        let area = CGRect(x: 100, y: 30, width: 1200, height: 900)
        let window = CGRect(x: 0, y: 0, width: 400, height: 300)
        #expect(WindowLayout.frame(.leftHalf, window: window, area: area) == CGRect(x: 100, y: 30, width: 600, height: 900))
        #expect(WindowLayout.frame(.bottomRight, window: window, area: area) == CGRect(x: 700, y: 480, width: 600, height: 450))
        #expect(WindowLayout.frame(.rightThird, window: window, area: area) == CGRect(x: 900, y: 30, width: 400, height: 900))
        #expect(WindowLayout.frame(.maximize, window: window, area: area) == area)
        #expect(WindowLayout.frame(.center, window: window, area: area) == CGRect(x: 500, y: 330, width: 400, height: 300))
        #expect(WindowLayout.frame(.center, window: CGRect(x: 0, y: 0, width: 2000, height: 300), area: area)?.width == 1200)
        #expect(WindowLayout.frame(.restore, window: window, area: area) == nil)
    }

    @Test func newWindowFramesMatchRectangle() {
        let area = CGRect(x: 100, y: 30, width: 1200, height: 900)
        let window = CGRect(x: 300, y: 200, width: 400, height: 300)
        #expect(WindowLayout.frame(.centerHalf, window: window, area: area) == CGRect(x: 400, y: 30, width: 600, height: 900))
        #expect(WindowLayout.frame(.centerTwoThirds, window: window, area: area) == CGRect(x: 300, y: 30, width: 800, height: 900))
        #expect(WindowLayout.frame(.lastFourth, window: window, area: area) == CGRect(x: 1000, y: 30, width: 300, height: 900))
        #expect(WindowLayout.frame(.centerThreeFourths, window: window, area: area) == CGRect(x: 250, y: 30, width: 900, height: 900))
        #expect(WindowLayout.frame(.bottomCenterSixth, window: window, area: area) == CGRect(x: 500, y: 480, width: 400, height: 450))
        #expect(WindowLayout.frame(.almostMaximize, window: window, area: area) == CGRect(x: 160, y: 75, width: 1080, height: 810))
        #expect(WindowLayout.frame(.maximizeHeight, window: window, area: area) == CGRect(x: 300, y: 30, width: 400, height: 900))
        #expect(WindowLayout.frame(.moveLeft, window: window, area: area) == CGRect(x: 100, y: 330, width: 400, height: 300))
        #expect(WindowLayout.frame(.moveRight, window: window, area: area) == CGRect(x: 900, y: 330, width: 400, height: 300))
        #expect(WindowLayout.frame(.moveUp, window: window, area: area) == CGRect(x: 500, y: 30, width: 400, height: 300))
        #expect(WindowLayout.frame(.moveDown, window: window, area: area) == CGRect(x: 500, y: 630, width: 400, height: 300))
    }

    @Test func largerAndSmallerKeepSnappedEdges() {
        let area = CGRect(x: 100, y: 30, width: 1200, height: 900)
        let floating = CGRect(x: 300, y: 200, width: 400, height: 300)
        #expect(WindowLayout.frame(.larger, window: floating, area: area) == CGRect(x: 285, y: 185, width: 430, height: 330))
        #expect(WindowLayout.frame(.smaller, window: floating, area: area) == CGRect(x: 315, y: 215, width: 370, height: 270))
        let left = CGRect(x: 100, y: 30, width: 600, height: 900)
        #expect(WindowLayout.frame(.larger, window: left, area: area) == CGRect(x: 100, y: 30, width: 630, height: 900))
        #expect(WindowLayout.frame(.smaller, window: left, area: area) == CGRect(x: 100, y: 30, width: 570, height: 900))
        let right = CGRect(x: 700, y: 30, width: 600, height: 900)
        #expect(WindowLayout.frame(.smaller, window: right, area: area) == CGRect(x: 730, y: 30, width: 570, height: 900))
        #expect(WindowLayout.frame(.larger, window: area, area: area) == area)
        #expect(WindowLayout.frame(.smaller, window: area, area: area) == CGRect(x: 115, y: 45, width: 1170, height: 870))
        let smallest = CGRect(x: 300, y: 200, width: 310, height: 300)
        #expect(WindowLayout.frame(.smaller, window: smallest, area: area) == smallest, "A window at the minimum size stays as it is.")
    }

    @Test func windowMenuListsEveryCommandOnce() {
        #expect(WindowCommand.menuSections.flatMap(\.commands) == WindowCommand.allCases)
    }

    @Test func rectangleShortcutsAreValidAndUnique() {
        let shortcuts = WindowCommand.allCases.compactMap(\.rectangleShortcut)
        #expect(shortcuts.count == 21)
        #expect(shortcuts.allSatisfy { $0.isValid })
        #expect(Set(shortcuts).count == shortcuts.count)
        #expect(WindowCommand.rightThird.rectangleShortcut?.display == "⌃⌥R")
        #expect(WindowCommand.nextDisplay.rectangleShortcut?.display == "⌃⌥⌘→")
    }

    @Test func movingBetweenDisplaysKeepsTheWindowInside() {
        let big = CGRect(x: 0, y: 25, width: 2560, height: 1410)
        let small = CGRect(x: -1728, y: -205, width: 1728, height: 1085)
        let moved = WindowLayout.moved(CGRect(x: 2000, y: 100, width: 2000, height: 1200), from: big, to: small)
        #expect(small.contains(moved))
        #expect(WindowLayout.area(of: CGRect(x: -500, y: 0, width: 300, height: 300), in: [big, small]) == 1)
        #expect(WindowLayout.area(of: CGRect(x: 9000, y: 0, width: 300, height: 300), in: [small, big]) == 1)
    }

    @Test func aWindowMoveCountsOnlyWhenARequestedChangeWasAccepted() {
        let current = CGRect(x: 300, y: 200, width: 400, height: 300)
        let moved = CGRect(x: 100, y: 200, width: 400, height: 300)
        let snapped = CGRect(x: 100, y: 30, width: 600, height: 900)
        #expect(!WindowLayout.accepted(moved, from: current, result: current, placed: false, sized: true))
        #expect(!WindowLayout.accepted(snapped, from: current, result: nil, placed: false, sized: false))
        #expect(WindowLayout.accepted(snapped, from: current, result: current, placed: true, sized: false))
        #expect(WindowLayout.accepted(snapped, from: current, result: current, placed: false, sized: true))
        #expect(WindowLayout.accepted(snapped, from: current, result: snapped, placed: false, sized: false))
    }

    @Test func menuBarClickPointRejectsHiddenAndNotchedItems() {
        let displays = [
            MenuBarDisplay(frame: CGRect(x: 0, y: 0, width: 2560, height: 1440)),
            MenuBarDisplay(frame: CGRect(x: -1728, y: -239, width: 1728, height: 1117), notch: -957...(-772)),
        ]
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint? {
            MenuBarLayout.clickPoint(for: CGRect(x: x, y: y, width: 20, height: 24), displays: displays, barHeight: 30)
        }
        #expect(point(2000, 0) == CGPoint(x: 2010, y: 12))
        #expect(point(-300, -239) == CGPoint(x: -290, y: -227))
        #expect(point(-500, 0) == nil, "A hidden item sits at the main bar's height, over the laptop's desktop.")
        #expect(point(-850, -239) == nil, "An item behind the notch cannot be clicked.")
        #expect(point(-9000, 0) == nil)
    }

    @Test func rehideWaitsForAnOpenItem() {
        let start = Date(timeIntervalSince1970: 0)
        let later = start.addingTimeInterval(60)
        #expect(MenuBarReveal.shouldRehide(now: later, revealedAt: start, seconds: 10, cause: .user, pointerInMenuBar: false))
        #expect(!MenuBarReveal.shouldRehide(now: later, revealedAt: start, seconds: 10, cause: .user, pointerInMenuBar: false, itemOpen: true))
    }

    @Test func clipboardSearchFallsBackToFuzzyAfterExactMatches() {
        let base = Date(timeIntervalSince1970: 0)
        let items = [
            ClipItem(id: "1", text: "kubernetes deployment", source: nil, createdAt: base, lastUsedAt: base, pinboardID: nil),
            ClipItem(id: "2", text: "the deploy notes", source: nil, createdAt: base, lastUsedAt: base.addingTimeInterval(1), pinboardID: nil),
            ClipItem(id: "3", text: "unrelated", source: nil, createdAt: base, lastUsedAt: base.addingTimeInterval(2), pinboardID: nil),
        ]
        #expect(ClipboardSearch.filter(items, query: "deploy").map(\.id) == ["2", "1"])
        #expect(ClipboardSearch.filter(items, query: "kbnts").map(\.id) == ["1"])
        #expect(ClipboardSearch.filter(items, query: "dpl notes").map(\.id) == ["2"])
        #expect(ClipboardSearch.filter(items, query: "kb").isEmpty)
    }

    @Test func aiActionsSurviveStorageAndMigrateOnce() async throws {
        let dir = try folder()
        let store = try PromptStore(directory: dir)
        var settings = PromptSettings()
        settings.onboarded = true
        try await store.onboard([Action(name: "Mine", template: "x")], settings: settings, revision: try await store.revision())
        let raw = try SQLite(path: dir.appendingPathComponent("cue.sqlite3"))
        try raw.executeScript("DELETE FROM schema_migrations WHERE version=4; PRAGMA user_version=3;")
        let upgraded = try await PromptStore(directory: dir).snapshot().actions
        #expect(upgraded.filter { $0.ai == true }.map(\.name).sorted() == ["Fix Grammar", "Summarize", "Translate"])
        #expect(upgraded.first { $0.name == "Mine" }?.ai == nil)
        #expect(upgraded.first { $0.ai == true }?.deliveryMode == .copy)
        #expect(try await PromptStore(directory: dir).snapshot().actions.count == 4)
    }

    @Test func freshLibraryWaitsForOnboardingBeforeAddingAiActions() async throws {
        #expect(try await PromptStore(directory: try folder()).snapshot().actions.isEmpty)
    }

    @Test func mixedRankingUsesTheSameScore() {
        #expect(ActionSearch.score("left half", name: "Left Half")?.tier == -1)
        #expect(ActionSearch.score("lft", name: "Left Half")?.tier == 4)
        #expect(ActionSearch.score("zzz", name: "Left Half") == nil)
        #expect(ActionSearch.score("", name: "Left Half")?.tier == 0)
    }

    @Test func dotEnvSettingEditsOnlyTheKey() {
        let text = "# keep\nexport ANTHROPIC_API_KEY=old\nANTHROPIC_MODEL=m\n"
        #expect(DotEnv.setting("ANTHROPIC_API_KEY", to: "new", in: text) == "# keep\nANTHROPIC_API_KEY=new\nANTHROPIC_MODEL=m\n")
        #expect(DotEnv.setting("ANTHROPIC_API_KEY", to: nil, in: text) == "# keep\nANTHROPIC_MODEL=m\n")
        #expect(DotEnv.setting("ANTHROPIC_API_KEY", to: "k", in: "") == "ANTHROPIC_API_KEY=k\n")
        #expect(DotEnv.setting("ANTHROPIC_API_KEY", to: "k", in: "A=1\n") == "A=1\nANTHROPIC_API_KEY=k\n")
    }

    @Test func dotEnvSettingKeepsOtherLinesInCRLFFiles() {
        let text = "ANTHROPIC_API_KEY=old\r\nANTHROPIC_MODEL=custom\r\n"
        #expect(DotEnv.parse(DotEnv.setting("ANTHROPIC_API_KEY", to: "new", in: text)) == ["ANTHROPIC_API_KEY": "new", "ANTHROPIC_MODEL": "custom"])
        #expect(DotEnv.parse(DotEnv.setting("ANTHROPIC_API_KEY", to: nil, in: text)) == ["ANTHROPIC_MODEL": "custom"])
    }

    @Test func storedKeyWinsOverTheEnvFile() throws {
        let dir = try folder()
        try Data("ANTHROPIC_API_KEY=file\nANTHROPIC_MODEL=m\n".utf8).write(to: dir.appendingPathComponent(".env"))
        #expect(try Assistant.credentials(in: dir, storedKey: "stored") == .init(key: "stored", model: "m"))
    }

    @Test func streamRequestAsksForStreaming() throws {
        let request = try Assistant.request("hi", credentials: .init(key: "k", model: "m"), stream: true)
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["stream"] as? Bool == true && body["max_tokens"] as? Int == 64000)
    }

    private func decode(_ lines: [String]) throws -> String {
        var decoder = Assistant.StreamDecoder()
        var text = ""
        for line in lines { text += try decoder.feed(line) ?? "" }
        try decoder.finish()
        return text
    }

    private let start = #"data: {"type":"message_start","message":{"id":"m"}}"#
    private let hello = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#

    private func stop(_ reason: String) -> String { #"data: {"type":"message_delta","delta":{"stop_reason":"\#(reason)"},"usage":{"output_tokens":1}}"# }

    @Test func streamDecoderCollectsTextAndIgnoresOtherEvents() throws {
        #expect(try decode(["event: message_start", start, "", #"data: {"type":"ping"}"#, hello, #"data: {"type":"content_block_start","index":1,"content_block":{"type":"fallback"}}"#, hello, stop("end_turn")]) == "HelloHello")
    }

    @Test func streamDecoderRejectsBrokenEndings() {
        #expect(throws: CueError("AI_REFUSED", "Claude declined this text.")) { try decode([hello, stop("refusal")]) }
        #expect(throws: CueError("AI_TRUNCATED", "The result was too long, so Cue stopped it here.")) { try decode([hello, stop("max_tokens")]) }
        #expect(throws: CueError("AI_UNREACHABLE", "The connection to Claude ended early. Try again.")) { try decode([hello]) }
        #expect(throws: CueError("AI_EMPTY", "Claude returned no text.")) { try decode([stop("end_turn")]) }
        #expect(throws: CueError("AI_FAILED", "Overloaded")) { try decode([hello, #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#]) }
    }

    @Test func diffMarksOnlyInsertedWords() {
        let runs = TextDiff.additions(from: "a unica mudanca", to: "a unica mudança, agora")
        #expect(runs.map(\.text).joined() == "a unica mudança, agora")
        #expect(runs.filter(\.added).map(\.text) == ["mudança,", "agora"])
        #expect(TextDiff.additions(from: "same text", to: "same text") == [.init("same text", added: false)])
        #expect(TextDiff.additions(from: "x", to: "") == [])
    }

    @Test func fileScopeHonorsDepthAndSkips() {
        let scope = FileScope(locations: [.init(path: "/Users/a", depth: 2), .init(path: "/Users/a/Projects", depth: nil)],
                              skip: ["node_modules", "venv*"], home: "/Users/a")
        #expect(scope.allows("/Users/a/notes.txt"))
        #expect(scope.allows("/Users/a/Docs/notes.txt"))
        #expect(!scope.allows("/Users/a/Docs/old/notes.txt"))
        #expect(scope.allows("/Users/a/Projects/a/b/c/d.txt"))
        #expect(!scope.allows("/Users/a/Projects/a/node_modules/d.txt"))
        #expect(!scope.allows("/Users/a/Projects/a/venv3/d.txt"))
        #expect(!scope.allows("/Users/a/.config/x"))
        #expect(!scope.allows("/Users/a/Library/x"))
        #expect(!scope.allows("/Users/a/Projects/App.app/Contents/x"))
        #expect(!scope.allows("/tmp/x"))
    }

    @Test func snippetsBecomeActionsOnce() {
        let existing = [Action(name: "Today", template: "x")]
        let actions = Snippets.actions([.init(keyword: "today", expansion: "{date}"), .init(keyword: "sig", expansion: "> {clipboard}")], existing: existing)
        #expect(actions.map(\.name) == ["sig"] && actions[0].template == "> {{clipboard}}")
    }
}
