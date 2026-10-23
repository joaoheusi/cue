# Platform evidence

Updated October 22, 2026. Built and tested on macOS 26.4.1 (25E253), Apple Silicon, Xcode 26.6, Swift 6.3.3. Deployment target: macOS 14.

Cue is now macOS-only. The earlier Tauri build also targeted Windows and Linux; those targets were removed with the move to Swift, SwiftUI, and AppKit.

| Feature | Evidence on this machine | Notes |
| --- | --- | --- |
| Unit and end-to-end logic tests | `make test-unit` passes (Swift Testing) | Templates, validation, search, prompt store and legacy rows, paste rules, clipboard crypto/filter/expiry/store, menu-bar layout/planning/store |
| Core keyboard workflow | `make test-ui` passes | Opens the command window, searches, moves the selection, copies with ⇧↩, checks the rendered text on the clipboard |
| Prompt library compatibility | Unit test reads rows and settings written by the Rust version, then edits them | Same `cue.sqlite3` schema (version 2); no migration needed |
| Hidden main menu for edit keys | Verified by the UI test (⌘A in the search field) | Without it, ⌘A/⌘C/⌘V/⌘Z do nothing in a menu-bar-only app |
| Menu-bar hide/reveal separator | Verified: a status item set to length 10,000 moved items on its left from x=830 to x=−4150; restoring the length brought them back. No permission needed. | A live run with the module on hid a probe item (x=−9175); it returned after Cue exited |
| Menu-bar item identification | `CGWindowList` shows every status item as owned by Control Center with no name on macOS 26 | Cue uses Accessibility (`AXExtrasMenuBar`) instead |
| Menu-bar listing, pressing, ⌘-drag arranging | **Not verified** | Needs an Accessibility grant, which this session could not give |
| Clipboard pasteboard privacy | SDK confirms `NSPasteboard.accessBehavior` (macOS 15.4+) | Reading the general pasteboard triggers the system alert unless the user allows it; `changeCount` does not |
| Global shortcuts (Carbon) | Built; not pressed by automation | Synthetic keystrokes do not trigger system hot keys reliably |
| Automatic paste into another app | Rules unit-tested (ported from the former native suite); Accessibility calls **not verified** in this build | The previous build's paste was confirmed by the user in J4 Code; the Swift port keeps the same checks and order |
| Launch at login (`SMAppService`) | Built; not enabled on this machine | macOS may require approval in Login Items |
| Keychain key storage | Clipboard tests inject a key; the real Keychain is not touched by tests | Data-protection Keychain needs a team-signed build; ad-hoc builds fall back to the login Keychain |

## Known limits

- Ad-hoc signed rebuilds change Cue's code signature. macOS then drops Accessibility access, and the login Keychain asks before releasing the clipboard key. Set `DEVELOPMENT_TEAM` in `.env` to avoid this.
- Arranging menu-bar items treats every Control Center and System UI Server item as fixed, including movable ones such as Wi-Fi.
- Menu-bar auto-hide waits while the pointer is in the menu bar, but it cannot see another app's open menu.
- No claims are made about screen readers, multiple displays, or performance targets.
