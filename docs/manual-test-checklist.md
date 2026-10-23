# Manual verification

Use a debug build (`make run`) so release data stays separate. Do not use sensitive clipboard content. Record the macOS version, architecture, build, and display setup.

## Automated (run `make test`)

- [x] Template rendering, escaping, literal placeholders, limits, and validation (ported from the Rust and TypeScript suites).
- [x] Search ranking: exact, aliases, accents, typos, favorites, recents.
- [x] Prompt store: migration from schema 1, rows written by the Rust version, revisions, import preview/commit, stale import, atomic onboarding, categories, backups.
- [x] Paste rules: permissions, exact window and field, inactive-target validation, clipboard and modifier gates.
- [x] Clipboard: capture filter, encryption, deduplication, expiration, search, export/import, end-to-end store.
- [x] Menu bar: section classification, move planning, rules, reveal decisions, export/import, end-to-end store.
- [x] UI: command window search, keyboard selection, ⇧↩ copy of a clipboard-variable prompt.

## Needs a person at the keyboard

### Prompts

- [ ] First run shows setup once; starters and the palette shortcut are saved; a later launch starts in the menu bar only.
- [ ] An existing library from the Tauri version opens with its actions, categories, settings, and shortcuts.
- [ ] ⇧⌘Space opens the palette over another app; pressing it again closes it.
- [ ] ↩ pastes into TextEdit, a browser field, and J4 Code. Secure fields and terminals refuse paste with a clear message.
- [ ] Changing focus, closing the target window, or changing the clipboard before delivery stops the paste and says why.
- [ ] Holding a modifier when the paste would fire waits, then pastes once; nothing is ever pasted twice.
- [ ] Escape and clicking outside close the palette without touching the clipboard.
- [ ] Direct action shortcuts: press, disabled action, pause/resume, conflicting chord keeps the old one.
- [ ] Editor: unsaved changes prompt before switching or quitting; closing the window keeps the draft; ⌘Z undoes a variable insertion separately.
- [ ] Import valid, malformed, oversized, duplicate-ID, unknown-field, and stale files. Export and re-import.

### Clipboard

- [ ] Turning history on shows Cue's explanation first, then the macOS paste prompt. "Always Allow" keeps it working.
- [ ] Copies from password managers, concealed/transient items, and excluded apps are not saved.
- [ ] Search, pin, unpin, delete, paste back, and copy only work from the keyboard.
- [ ] Items expire on schedule; pinned items never expire.
- [ ] Export warns about plain text; import restores items and pinboards.
- [ ] Denying access (System Settings → Privacy & Security → Paste) shows a recoverable error with a settings link.

### Menu bar

- [ ] Turning the feature on adds the chevron; ⌘-dragging icons to its left hides them; clicking reveals them.
- [ ] Auto-hide, reveal-while-frontmost apps, ⌥-click reveal-all, and the ⌥⌘B shortcut.
- [ ] With Accessibility: items are listed by section; ↩ opens an item's menu; ⌥←/⌥→ and Apply Rules Now move items and restore the pointer.
- [ ] Quitting Cue or turning the feature off brings every icon back.

### App

- [ ] Launch at login: on, approval flow, off. Login launch shows no window.
- [ ] Update check: off by default; Check Now with and without `CUE_UPDATE_URL`.
- [ ] Diagnostics export contains no prompt text, clipboard text, or item names.
- [ ] Light, dark, and system themes; VoiceOver labels on the command window; multiple displays and Spaces.
- [ ] Uninstall steps in the README remove every trace.
