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

    @Test func movingBetweenDisplaysKeepsTheWindowInside() {
        let big = CGRect(x: 0, y: 25, width: 2560, height: 1410)
        let small = CGRect(x: -1728, y: -205, width: 1728, height: 1085)
        let moved = WindowLayout.moved(CGRect(x: 2000, y: 100, width: 2000, height: 1200), from: big, to: small)
        #expect(small.contains(moved))
        #expect(WindowLayout.area(of: CGRect(x: -500, y: 0, width: 300, height: 300), in: [big, small]) == 1)
        #expect(WindowLayout.area(of: CGRect(x: 9000, y: 0, width: 300, height: 300), in: [small, big]) == 1)
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
}
