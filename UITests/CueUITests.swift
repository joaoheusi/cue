import AppKit
import XCTest

/// Core keyboard workflow: open the command window, search, move the selection, and copy with ⇧↩.
/// Runs against a temporary library seeded with the starter actions. No hotkeys or permissions are used.
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

        // "Rewrite clearly" inserts the clipboard text into its template. Restore the user's clipboard afterwards.
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
        // Replace the query entirely from the keyboard.
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
}
