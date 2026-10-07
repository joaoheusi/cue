# Manual verification

Use a debug build so release data is separate. Do not use sensitive clipboard content. Record OS, architecture, app build, display scaling, and session type.

## Confirmed locally

- [x] Browser onboarding added six editable starters once.
- [x] Browser created and explicitly saved a Unicode/multiline template.
- [x] Navigating away from a dirty browser editor displayed a discard decision; cancelling kept edits.
- [x] Browser alias search `fix checks` found Resolve CI.
- [x] Native `.app` opened with bundled assets.
- [x] Native onboarding populated the SQLite library.
- [x] Native Cmd+Shift+Space opened the palette with search focused.
- [x] Native Copy wrote the exact stored Resolve CI text; manual Cmd+V into a local test field matched it.
- [x] Native alias search and Shift+Enter copied once and hid the palette; the counter advanced once.
- [x] Optimized release package opened with the final restricted window permissions.
- [x] Release onboarding created six starters; closing and reopening retained them and the active shortcut status.
- [x] Release Copy produced the exact saved 403-character Resolve CI template in a temporary unsaved local draft. The draft was discarded.
- [x] Release library button opened the palette with search focused on the built-in display.
- [x] Welcome and setup screens use one canvas without an outer card border or shadow.
- [x] Rebuilt native palette shows rounded corners with a transparent native window background.
- [x] Drag installer builds without Finder automation. DMG checksum is valid. Mounted image contains Cue and an Applications link at the configured positions; its executable matches the rebuilt app.
- [x] Installed app updated with library data preserved. Tags field removed; Clipboard text button explains when substitution occurs.
- [x] Native Cmd+Z reverses a variable insertion separately from earlier typing. Cmd+Shift+Z restores it. Tab indentation and replacement of selected text also undo correctly. Temporary unsaved diagnostic drafts were discarded.

## October 7 fixes

- [x] Compact preview button and separate category label checked in the browser UI. Enter is labeled Paste; Shift+Enter remains Copy.
- [x] macOS schema-2 migration preserves the saved action and its explicit delivery override, backs up the old database, and runs only once.
- [x] Explicit Quit exits the installed application.
- [x] Background-launch intent tests verify that an autostart request does not reveal the library.
- [ ] Finish native close/reopen and unsaved-draft retention checks.
- [x] User confirmed automatic paste into J4 Code after the target-focus fix. Accessibility and event-posting access remain enabled.
- [ ] Complete automatic-paste coverage in a local text editor.

## Required before release

- [ ] Restart after edits; check names, categories, settings, shortcuts, and use counts.
- [ ] Launch twice; only one database owner and shortcut set survives.
- [ ] Configure a direct shortcut; test press, hold, release, disabled action, pause, and resume.
- [x] User verified the final release global shortcut and automatic paste from J4 Code without UI automation.
- [ ] A conflicting replacement retains the previous active palette shortcut.
- [ ] Escape and outside click do not mutate the clipboard or show a copy success.
- [ ] No results plus Enter performs no action. IME composition Enter does not deliver.
- [ ] Copy a required clipboard variable, including literal nested tokens, whitespace, Unicode, and non-text/empty input.
- [x] Save and copy the full publishing prompt containing `@{{upstream}}` unchanged in the browser persistence tests and native SQLite tests. Shared literal-placeholder cases pass in both renderers.
- [ ] Save text with prohibited controls or exceeding the byte limit; confirm the error and absence of clipboard writes.
- [ ] Import valid, malformed, oversized, duplicate-ID, stale, and unknown-field files. Compare preview and committed data.
- [ ] Update matching IDs only after viewing before/after and confirming. Check shortcut removal and copy-only delivery.
- [ ] Export and overwrite a file. Check that exported data excludes usage, shortcuts, permissions, and clipboard expansions.
- [ ] Verify five-backup retention. Test corruption, full disk, and a future schema without silent data replacement.
- [ ] Close a dirty library, keep running, reopen through the tray, and explicitly Quit.
- [ ] Check opt-in launch at login; it starts hidden and copies nothing.
- [ ] Test light/dark/system appearance, high contrast, reduced motion, screen readers, 200% scaling, and narrow windows.
- [ ] Test multiple displays, display removal, full-screen apps, and Spaces.
- [ ] Repeat copy and shortcut checks on Windows 11, X11 Ubuntu 24.04, and native Wayland.

The macOS input adapter is implemented and its native regression suite passes. Automatic-paste acceptance tests AT-13–AT-22, AT-25, and AT-36 still require external-app checks. Follow the full specification before claiming release acceptance. Never press Enter in the target app or retry input after it may have been issued.
