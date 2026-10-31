import AppKit
import XCTest

final class CueUITests: XCTestCase {
    func testPaletteSearchAndCopyWithKeyboardOnly() throws {
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("cue-ui-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: data) }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["CUE_DATA_DIR"] = data.path
        app.launch()
        addTeardownBlock { app.terminate() }

        let search = app.textFields["command.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 15), "The command window should open on launch in UI-testing mode.")
        search.click()

        let saved = NSPasteboard.general.string(forType: .string)
        addTeardownBlock {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("move the deploy to Thursday", forType: .string)

        search.typeText("review")
        XCTAssertTrue(app.staticTexts["Review current changes"].waitForExistence(timeout: 5))
        search.typeKey(.downArrow, modifierFlags: [])
        search.typeKey(.upArrow, modifierFlags: [])
        search.typeKey("a", modifierFlags: .command)
        search.typeText("rewrite")
        XCTAssertTrue(app.staticTexts["Rewrite clearly"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Review current changes"].waitForNonExistence(timeout: 5), "Search should filter out non-matching actions.")

        search.typeKey(.return, modifierFlags: .shift)

        let copied = expectation(description: "rendered prompt on the clipboard")
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let text = NSPasteboard.general.string(forType: .string), text.hasSuffix("Text:\nmove the deploy to Thursday") {
                copied.fulfill()
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        wait(for: [copied], timeout: 0.1)
        XCTAssertFalse(search.isHittable, "The command window closes after a successful copy.")
    }

    private func launch(prepare: (URL) throws -> Void = { _ in }) throws -> XCUIApplication {
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("cue-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: data) }
        try prepare(data)
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["CUE_DATA_DIR"] = data.path
        app.launch()
        addTeardownBlock { app.terminate() }
        XCTAssertTrue(app.textFields["command.search"].waitForExistence(timeout: 15), "The command window should open on launch in UI-testing mode.")
        app.textFields["command.search"].click()
        return app
    }

    private func waitForClipboard(_ matches: (String) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let text = NSPasteboard.general.string(forType: .string), matches(text) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    func testNewActionOpensWhenSearchHasNoResults() throws {
        let app = try launch()
        let search = app.textFields["command.search"]
        search.typeText("nothing matches this at all")
        XCTAssertTrue(app.staticTexts["No matches"].waitForExistence(timeout: 5))
        search.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.windows["Cue"].waitForExistence(timeout: 5), "⌘N should open the Library when the search has no results.")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 3), "The Library should come to the front, not open behind other windows.")
    }

    func testEditShortcutShowsTheSelectedActionInTheLibrary() throws {
        let app = try launch()
        let search = app.textFields["command.search"]
        search.typeText("review current")
        XCTAssertTrue(app.staticTexts["Review current changes"].waitForExistence(timeout: 5))
        search.typeKey("e", modifierFlags: .command)
        let name = app.windows["Cue"].textFields.matching(NSPredicate(format: "value == %@", "Review current changes")).firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5), "⌘E should show the selected action in the Library editor.")
    }

    func testLibraryArrowKeysMoveTheSelectionAndTestRunsInline() throws {
        let saved = NSPasteboard.general.string(forType: .string)
        addTeardownBlock {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("some text", forType: .string)
        let app = try launch()
        let search = app.textFields["command.search"]
        search.typeText("summarize")
        XCTAssertTrue(app.staticTexts["Summarize"].waitForExistence(timeout: 5))
        search.typeKey("e", modifierFlags: .command)
        let library = app.windows["Cue"]
        func name(_ value: String) -> XCUIElement { library.textFields.matching(NSPredicate(format: "value == %@", value)).firstMatch }
        XCTAssertTrue(name("Summarize").waitForExistence(timeout: 5))
        library.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Rewrite clearly")).firstMatch.click()
        XCTAssertTrue(name("Rewrite clearly").waitForExistence(timeout: 5))
        library.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(name("Create a handoff").waitForExistence(timeout: 5), "The down arrow should select the next row.")
        library.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Rewrite clearly")).firstMatch.click()
        XCTAssertTrue(name("Rewrite clearly").waitForExistence(timeout: 5))
        library.buttons["Test"].click()
        XCTAssertTrue(library.buttons["Close test"].waitForExistence(timeout: 5), "Test should show its result inside the editor.")
        library.buttons["Close test"].click()
        XCTAssertTrue(library.buttons["Close test"].waitForNonExistence(timeout: 5))
    }

    func testActionsMenuActsOnTheSelectedRow() throws {
        let app = try launch()
        let search = app.textFields["command.search"]
        search.typeText("review current")
        XCTAssertTrue(app.staticTexts["Review current changes"].waitForExistence(timeout: 5))
        search.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(app.menuItems["Edit in Library"].waitForExistence(timeout: 5))
        app.menuItems["Edit in Library"].click()
        let name = app.windows["Cue"].textFields.matching(NSPredicate(format: "value == %@", "Review current changes")).firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5), "⌘K should act on the selected row, not an earlier one.")
    }

    func testCopyPathShortcutCopiesTheSelectedFile() throws {
        let saved = NSPasteboard.general.string(forType: .string)
        addTeardownBlock {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }
        let app = try launch()
        let search = app.textFields["command.search"]
        NSPasteboard.general.clearContents()
        search.typeText("preview")
        XCTAssertTrue(app.staticTexts["Preview"].waitForExistence(timeout: 5))
        search.typeKey("c", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitForClipboard { $0.hasSuffix("Preview.app") }, "⌘⇧C should copy the selected file's path.")
    }

    func testNewActionRowOpensTheLibraryOnANewAction() throws {
        let app = try launch()
        let search = app.textFields["command.search"]
        search.typeText("new action")
        XCTAssertTrue(app.staticTexts["New Action"].waitForExistence(timeout: 5))
        search.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.windows["Cue"].staticTexts["Not saved"].waitForExistence(timeout: 5), "Return on New Action should open the Library on a new action.")
        XCTAssertTrue(app.windows["Cue"].buttons.matching(NSPredicate(format: "label CONTAINS %@", "Draft")).firstMatch.exists, "The new action should appear as a draft row in the list.")
    }

    func testUnifiedSearchFindsSnippetsScriptsAndWindowCommands() throws {
        let saved = NSPasteboard.general.string(forType: .string)
        addTeardownBlock {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }
        let app = try launch { data in
            try Data(#"[{"keyword": "signoff", "expansion": "Thanks, {clipboard}"}]"#.utf8).write(to: data.appendingPathComponent("snippets.json"))
            let folder = data.appendingPathComponent("commands")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let script = folder.appendingPathComponent("build-info.sh")
            try Data("echo script says hello\n".utf8).write(to: script)
        }
        let search = app.textFields["command.search"]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("Ana", forType: .string)

        search.typeText("left half")
        XCTAssertTrue(app.staticTexts["Left Half"].waitForExistence(timeout: 5))
        search.typeKey("a", modifierFlags: .command)
        search.typeText("build-info")
        XCTAssertTrue(app.staticTexts["build-info"].waitForExistence(timeout: 5))
        search.typeKey(.return, modifierFlags: .shift)
        XCTAssertTrue(app.staticTexts["script says hello"].waitForExistence(timeout: 5), "Shift-Return should show the script's output.")
        app.typeKey("[", modifierFlags: .command)

        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeKey("a", modifierFlags: .command)
        search.typeText("build-info")
        XCTAssertTrue(app.staticTexts["build-info"].waitForExistence(timeout: 5))
        search.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitForClipboard { $0 == "script says hello" }, "Return should copy the script's output.")
    }

    func testSnippetFillsPlaceholders() throws {
        let saved = NSPasteboard.general.string(forType: .string)
        addTeardownBlock {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }
        let app = try launch { data in
            try Data(#"[{"keyword": "signoff", "expansion": "Thanks, {clipboard}"}]"#.utf8).write(to: data.appendingPathComponent("snippets.json"))
        }
        let search = app.textFields["command.search"]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("Ana", forType: .string)
        search.typeText("signoff")
        XCTAssertTrue(app.staticTexts["signoff"].waitForExistence(timeout: 5))
        search.typeKey(.return, modifierFlags: .shift)
        XCTAssertTrue(waitForClipboard { $0 == "Thanks, Ana" })
    }

    func testActionsMenuOpensAndKeepsThePaletteOpen() throws {
        let app = try launch()
        let search = app.textFields["command.search"]
        search.typeText("review")
        XCTAssertTrue(app.staticTexts["Review current changes"].waitForExistence(timeout: 5))
        search.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(app.menuItems["Edit in Library"].waitForExistence(timeout: 5), "⌘K should open the actions menu.")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(search.waitForExistence(timeout: 5), "Closing the actions menu should leave the palette open.")
        XCTAssertTrue(app.staticTexts["Review current changes"].exists)
    }

    func testScopeSwitcherShowsClipboardAndMenuBar() throws {
        let app = try launch()
        let search = app.textFields["command.search"]
        search.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Clipboard history is off"].waitForExistence(timeout: 5))
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Menu bar hiding is off"].waitForExistence(timeout: 5))
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(search.waitForExistence(timeout: 5))
    }

    func testWhatYouCopyAppearsInClipboardHistory() throws {
        let saved = NSPasteboard.general.string(forType: .string)
        addTeardownBlock {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }
        let app = try launch()
        app.textFields["command.search"].typeKey("2", modifierFlags: .command)
        let turnOn = app.buttons["Turn On Clipboard History"]
        XCTAssertTrue(turnOn.waitForExistence(timeout: 5))
        turnOn.click()
        let confirm = app.dialogs.buttons["Turn On"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Cue should explain clipboard access before turning capture on.")
        confirm.click()
        XCTAssertTrue(app.staticTexts["Nothing copied yet"].waitForExistence(timeout: 20), "Capture did not turn on. In CI, the Keychain is the likely cause.")

        let copied = "copied through the reader \(UUID().uuidString)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copied, forType: .string)
        XCTAssertTrue(app.staticTexts[copied].firstMatch.waitForExistence(timeout: 40), "The copy should appear as a row in clipboard history.")
    }
}
