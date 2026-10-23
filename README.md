# Cue

Your prompts, clipboard, and menu bar, on cue. Cue is one native macOS menu-bar app with three tools:

1. **Prompts** — a library of reusable instructions. Press a shortcut in any app, pick an action, and Cue pastes it into the field you were typing in.
2. **Clipboard** — an encrypted, searchable clipboard history with pinboards and automatic expiration.
3. **Menu Bar** — hide, reveal, and arrange other apps' menu-bar items with your own rules.

All three share one searchable command window, global shortcuts, and one settings screen. Everything stays on your Mac. Cue has no accounts, sync, telemetry, analytics, or hosted services.

Built with Swift 6, SwiftUI, AppKit where needed, SQLite, and the macOS Keychain. Requires macOS 14 or later.

## Run

Install Xcode 26 (or later). Then run one command:

```sh
make run
```

This builds a debug copy and opens it. Debug builds keep their data in `~/Library/Application Support/app.cue.launcher.dev`, separate from a release install. The first run opens setup for the prompt library. After that, Cue starts quietly in the menu bar.

The repository includes the generated `Cue.xcodeproj`. If you change `project.yml`, install [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`); `make` regenerates the project automatically when it is installed.

### Configuration and secrets

Copy `.env.example` to `.env` (git-ignored) and fill in only what you need:

| Variable | Purpose |
| --- | --- |
| `DEVELOPMENT_TEAM` | Signs builds with your Apple Development certificate, so Accessibility and Keychain access survive rebuilds. Leave empty for ad-hoc signing. |
| `CUE_UPDATE_URL` | Optional GitHub "latest release" API URL for the opt-in update check. Empty disables update checks. |
| `APPLE_SIGNING_IDENTITY` | Release packaging only (`make release`, `make dmg`). |

Never commit `.env` or any credential. Notarization credentials belong in the Keychain (`xcrun notarytool store-credentials`).

### Commands

| Command | What it does |
| --- | --- |
| `make run` | Build (Debug) and open Cue. |
| `make test` | Unit tests, then the UI test. |
| `make test-unit` | `swift test --package-path CueKit` |
| `make test-ui` | The XCUITest keyboard workflow. It types into Cue, so do not use the Mac while it runs. |
| `make release` | Release build, signed with `APPLE_SIGNING_IDENTITY` when set, then `codesign --verify`. |
| `make dmg` | Release build in a drag-to-Applications disk image. See `docs/release-process.md`. |

## Using Cue

| Shortcut (default) | Action |
| --- | --- |
| ⇧⌘Space | Open the command window on **Prompts** |
| ⌥⌘V | Open the command window on **Clipboard** |
| ⌥⌘B | Reveal or hide the hidden menu-bar section |

Every shortcut can be changed in Settings. In the command window: type to search, ↑/↓ to move, ↩ to use, ⇧↩ to copy only, ⌘1–3 to switch tools, ⎋ to close. The menu-bar icon offers the same commands, plus Pause Shortcuts, Settings, and Quit.

### Prompts

- ↩ pastes into the app you were using (default) or copies, per action or globally. ⇧↩ always copies.
- `{{clipboard}}`, `{{date}}`, and `{{time}}` are replaced once when you use an action. Other `{{…}}` text stays literal. A backslash escapes the three variables.
- The library window (menu bar → Manage Prompts…) has favorites, recents, categories, aliases, an explicit-save editor with native undo, per-action shortcuts, JSON import with a preview, and JSON export.
- Search covers names, aliases, tags, and categories. It ignores accents and never searches prompt bodies.

### Clipboard

<!-- CLIPBOARD -->

### Menu Bar

- Off by default, because it changes your menu bar. Turn it on in Settings → Menu Bar or from the Menu Bar tool.
- Cue adds a chevron (‹). Hold ⌘ and drag an icon to the left of the chevron to hide it. Click the chevron or press ⌥⌘B to show hidden icons. ⌥-click the chevron to also show the always-hidden section.
- **Rules:** put any item in *Visible*, *Hidden*, or *Always Hidden*; hide again automatically after N seconds (default 10, 0 turns it off); show hidden icons while chosen apps are frontmost.
- With Accessibility access, the Menu Bar tool lists every item by section. ↩ opens an item's menu (revealing it first). ⌥← / ⌥→ moves an item to the neighbouring section and saves that as a rule. **Apply Rules Now** moves items with a simulated ⌘-drag, one at a time, checks each move, and stops at the first failure.
- When you turn the feature off or quit Cue, every icon comes back.

## Permissions

Cue asks for each permission only when you first use a feature that needs it, and explains why before macOS shows its prompt or Cue opens System Settings.

| Permission | Needed for | Without it |
| --- | --- | --- |
| Accessibility | Pasting a prompt or clipboard item into the field you were typing in (Cue reads which field has focus and sends one ⌘V). Listing and arranging menu-bar items. | Prompts and clipboard items are copied; paste them yourself. Menu-bar hide/reveal still works. |
| Clipboard access (macOS 15.4+ "Paste from other apps") | Saving clipboard history. Choose "Always Allow". | Clipboard history stays off. |
| Login Items | Launch at login (optional, off by default). | Start Cue yourself. |

Global shortcuts use the Carbon hot-key API and need no permission. Cue never records keystrokes or screen content. Automatic paste refuses secure text fields and terminals, checks that the exact window and field are still focused, requires an unchanged clipboard and released modifier keys, and sends at most one ⌘V.

## Architecture

```
App/                   macOS app target (SwiftUI + AppKit)
  Shell/               AppDelegate, menu-bar icon, command window (NSPanel), global hotkeys (Carbon),
                       settings window, permissions, launch at login, update check, file import/export
  Shared/              PasteService (Accessibility paste), shared SwiftUI components
  Prompts/             Prompt library model, palette, library window, editor, settings
  Clipboard/           Clipboard monitor, history UI, settings
  MenuBar/             Separators, Accessibility item listing, arranging, settings
CueKit/                Swift package with all testable logic (no AppKit)
  Sources/CueKit/Core/      SQLite wrapper, errors, shortcuts, safe file names, paste rules, update check
  Sources/CueKit/Prompts/   Templates, validation, search, PromptStore (SQLite)
  Sources/CueKit/Clipboard/ Encryption, capture filter, expiration, search, store, export codec
  Sources/CueKit/MenuBar/   Layout classification, move planning, rules, store, export codec
  Tests/CueKitTests/        Swift Testing unit and end-to-end tests
UITests/               One XCUITest for the core keyboard workflow
project.yml            XcodeGen project definition
```

- Each tool owns one SQLite file. Each store is an actor that owns its connection, so database work never blocks the UI and never races.
- Every write is a transaction. Schema versions use `PRAGMA user_version`. Cue refuses to open a database written by a newer version instead of resetting it, and backs up before migrating.
- The command window is a non-activating panel. The app you were typing in stays frontmost, which is what makes paste-back reliable.
- Decisions that matter for safety (paste rules, clipboard capture filter, expiration, menu-bar move planning) are pure functions in CueKit with unit tests.

## Data location

| Path (in `~/Library/Application Support/app.cue.launcher/`) | Contents |
| --- | --- |
| `cue.sqlite3` | Prompt library, settings, and shortcuts. Readable SQLite; prompt text is not encrypted. |
| `backups/cue-*.sqlite3` | Automatic library backups before migrations and imports (newest five kept). |
| `clipboard.sqlite3` | Clipboard history and pinboards. Item text is encrypted (AES-GCM). |
| `menubar.sqlite3` | Menu-bar settings and rules. |

The clipboard encryption key is in your login Keychain under the service `app.cue.launcher.clipboard`. Debug builds use `app.cue.launcher.dev` for both the folder and the Keychain service. Settings → Data & Privacy shows the folder and opens it in Finder.

Cue upgrades the library from the earlier Tauri version in place: same bundle ID, same folder, same `cue.sqlite3` schema. Your actions, categories, settings, and shortcuts carry over.

## Export, import, and backup

- **Prompts:** Library → More → Export Actions… writes JSON (`schemas/actions-v1.schema.json`). Import shows a preview first and backs up the library before it changes anything.
- **Clipboard:** Settings → Clipboard → Export writes JSON with **plain text**. Store it somewhere safe. Import accepts the same format.
- **Menu Bar:** Settings → Menu Bar → Export Rules / Import Rules.
- **Diagnostics:** Settings → Data & Privacy → Export Diagnostics… writes versions, permission states, settings, counts, and recent error codes. It never includes prompt text, clipboard text, or menu-bar item names.

To back up everything, quit Cue and copy the whole `app.cue.launcher` folder. To restore, quit Cue and put the folder back. Clipboard history can only be decrypted with the Keychain key from the same Mac and user account. To move clipboard history to another Mac, use the clipboard export instead.

## Uninstall

1. Choose **Quit Cue** from the menu-bar icon.
2. Turn off **Launch at login** in Settings → General (or remove Cue in System Settings → General → Login Items).
3. Remove Cue from System Settings → Privacy & Security → **Accessibility** and **Paste**. Or run `tccutil reset Accessibility app.cue.launcher`.
4. Delete `Cue.app` from Applications.
5. Delete `~/Library/Application Support/app.cue.launcher` (and `app.cue.launcher.dev` if you ran a debug build).
6. Delete the clipboard key: `security delete-generic-password -s app.cue.launcher.clipboard` (and `-s app.cue.launcher.dev.clipboard`).
7. Optional: `defaults delete app.cue.launcher` removes window positions.

## Deliberately left out

- Accounts, billing, telemetry, analytics, and any hosted control plane.
- Cloud accounts and cross-device sync.
- A third-party extension or plugin marketplace.
- Automation that runs scripts or untrusted code. Cue only copies text, pastes once, and moves menu-bar items you chose.
- Automatic updates. The update check is opt-in, sends one request, and only links to the release page.

## Status

See `docs/platform-support.md` for what was verified on which macOS version, and `docs/manual-test-checklist.md` for the checks that still need a person at the keyboard.
