# Quick Actions — Product and Engineering Specification

**Working name:** Quick Actions  
**Version:** 1.0  
**Date:** October 6, 2026  
**Status:** Implementation proposal. No application has been built or tested from this specification.  
**Product:** A local desktop prompt launcher built with Tauri.  
**Targets:** macOS, Windows, and Linux, with explicit differences in OS integration.

## 1. Product definition

A small desktop app for saving reusable text, finding it with a global keyboard shortcut, and copying or pasting it into another app.

The main interaction is:

**Focus a text field → open Quick Actions → search → select → copy or paste → continue working.**

Examples include “Resolve CI,” “Resolve merge conflicts,” “Explain this PR,” and “Rewrite in clear English.” The user creates and edits these actions.

This is a prompt launcher, not an AI client or an automation platform. In V1, an **action is a text template with a delivery preference**. It does not execute a program, call a model, inspect a repository, or control a conversation.

### 1.1 Problem being solved

The user repeats instructions across coding tools and wants a faster way to reuse them. Some built-in coding-tool actions open a new conversation. Quick Actions avoids those buttons and inserts the user's instruction into the text field they were using.

The app does not know which conversation is open. It neither creates a conversation nor guarantees what the receiving agent will do. The receiving app supplies its own context and tools.

A “Resolve CI” action can ask an agent to inspect CI. Quick Actions itself does not fetch CI logs. A useful action must handle missing context rather than assume the logs are attached.

### 1.2 Requirements from the brief

| Requirement | Meaning |
| --- | --- |
| Standalone | Works independently of T3 Code. |
| Tauri | Uses a Tauri desktop shell with a web-based UI. |
| Cross-platform | Provides a usable desktop app on macOS, Windows, and Linux. |
| Quick actions | Stores reusable text and exposes it through a searchable palette. |
| Keyboard-first | Opening, searching, selecting, and managing actions do not require a mouse. |
| Basic but good-looking | Small interface, consistent spacing, readable text, no dashboard or decorative clutter. |
| Current working context | Returns to the original app when possible instead of opening a new chat or workspace. |

### 1.3 Proposed defaults

These are implementation choices, not additional requirements already approved by the user.

| Decision | Default |
| --- | --- |
| Stack | Tauri 2, React, TypeScript, Vite, Rust, SQLite. |
| Data | Local only; no account, server, sync, or telemetry. |
| First-use delivery | Copy. Offer automatic paste as an optional setup step. |
| Submission | Never simulate Enter to submit a prompt. |
| Organization | One optional category, multiple tags, favorites, and recent usage. |
| Templates | Plain text with `{{clipboard}}`, `{{date}}`, and `{{time}}`. |
| Theme | Follow the OS, with light and dark overrides. |
| UI language | English; all stored content supports Unicode. |
| Start at login | Off until the user enables it. |
| Clipboard after use | Keep the action text. Do not automatically restore or clear the clipboard. |
| Distribution | Downloadable desktop packages; manual updates in V1. |

## 2. Scope

### 2.1 V1 requirements

| ID | Feature | Required behavior |
| --- | --- | --- |
| QA-01 | Palette | Open from a configurable global shortcut where supported; always provide an app-launch fallback. |
| QA-02 | Search | Rank actions by name, aliases, tags, and category. |
| QA-03 | Action management | Create, edit, duplicate, enable, disable, and delete actions. |
| QA-04 | Organization | Categories, tags, favorites, and recent actions. |
| QA-05 | Copy | Copy the fully rendered action as plain text. |
| QA-06 | Paste | Optionally restore a known target window and issue its standard paste shortcut on tested platforms. |
| QA-07 | Direct shortcuts | Bind an optional global shortcut to an action using the same execution path as the palette. |
| QA-08 | Templates | Expand the three supported variables once, with no expression evaluation. |
| QA-09 | Persistence | Store actions and settings locally, with migrations and safe backup. |
| QA-10 | Import/export | Exchange versioned JSON files with validation and preview. |
| QA-11 | OS status | Show shortcut availability, paste support, and permission problems separately. |
| QA-12 | Lifecycle | Single instance, explicit Quit, optional start at login, and tray/menu access where available. |
| QA-13 | Presentation | Light/dark themes, accessible keyboard navigation, and consistent visual states. |

### 2.2 Not in V1

Do not build shell commands, scripts, macros, HTTP actions, an AI integration, a plugin marketplace, cloud sync, shared libraries, or account management.

Also exclude selected-text capture, screenshots, window-content reading, clipboard history, automatic submission, character-by-character typing, and automatic clipboard restoration.

This app does **not** solve T3's multi-repository state, worktree management, diffs, PR tracking, or checkpoint behavior. Those remain a separate project.

### 2.3 Possible later features

Only after V1 works reliably: named input fields, selected-text variables, per-application action filtering, encrypted sync, a browser extension, and a consent-based Wayland integration.

Executable actions require a separate security design. Do not add a hidden command runner “for future use.”

## 3. Platform contract

### 3.1 Initial release targets

These are proposed test targets, not claims about Tauri's minimum OS requirements or already verified compatibility. Pin exact OS versions and package versions when implementation starts.

| Target | Initial architecture | Required release behavior |
| --- | --- | --- |
| macOS 14 or newer | Apple Silicon | Palette, library, copy, direct shortcuts, and optional paste after permission/setup tests. |
| Windows 11 | x64 | Palette, library, copy, direct shortcuts, and optional paste into non-elevated tested applications. |
| Ubuntu 24.04 or newer, X11 | x64 | Library and copy; global shortcuts and paste must pass the native integration gate before being advertised. |
| Ubuntu 24.04 or newer, Wayland | x64 | Library and copy; explicit launcher/manual-paste fallback. No automatic-paste promise in V1. |

Builds for Intel Macs, Windows ARM64, and additional Linux distributions can follow. Building a package is not sufficient to claim native integration support.

### 3.2 Important limits

Tauri provides clipboard and global-shortcut plugins, but those are separate capabilities. Clipboard support does not imply permission to inject input or restore another app's focus. [S01] [S02]

The `global-hotkey` library documents Linux support as X11-only. Do not assume its shortcut mechanism works across native Wayland applications. The XDG GlobalShortcuts portal is a separate possible implementation, with session and user-configuration behavior. [S03] [S04]

On Windows, input injection is restricted by process integrity levels, and foreground activation can be denied. On macOS, accessibility control requires user authorization. [S05] [S06] [S07]

### 3.3 Runtime capability report

The Rust backend must report capabilities rather than let the UI infer support from the OS name alone:

| Capability | Values |
| --- | --- |
| Global shortcut | Available, unavailable, registration failed. |
| Clipboard read/write | Available, unavailable, temporarily failed. |
| Target-window capture | Available, unavailable. |
| Focus restoration | Available, unavailable, denied. |
| Paste injection | Available, permission required, blocked, unsupported. |
| Tray access | Available, unavailable. |
| Session type | macOS, Windows, X11, Wayland, unknown. |

Recheck relevant capabilities after permission changes, resume from sleep, and a failed operation. A temporary failure must not silently alter the user's saved preferences.

**Release wording:** “Copy on all supported desktops; automatic paste where supported and enabled.” Do not advertise identical OS behavior.

## 4. Core user flows

### 4.1 First launch

Show one compact onboarding screen with an explanation, a shortcut recorder, and two delivery choices.

1. Explain: “Save instructions. Find them with a shortcut. Use them in the app you are working in.”
2. Let the user choose the palette shortcut. Suggest `Cmd+Shift+Space` on macOS and `Ctrl+Shift+Space` on Windows/Linux, but register and test the choice. No shortcut is assumed to be universally free.
3. Offer the user's preferred `Cmd+G` or `Cmd+Shift+K` as examples of custom bindings, not mandatory defaults. Explain that a global binding may replace an application's normal use of that chord.
4. Start in copy mode. Offer **Enable automatic paste** separately.
5. Offer editable starter actions. Add them once; never recreate actions the user deleted.
6. Open the library with a visible “Try the palette” control.

Denied permissions must not block use of the library or copy mode.

### 4.2 Normal palette use

The user focuses the receiving text field before opening the palette.

The native backend captures the active external window **before** showing Quick Actions. The palette opens with search focused. Results update as the user types. Enter performs the action's effective delivery mode; Shift+Enter always copies instead.

A successful copy or issued paste request closes the palette. Escape cancels without changing the clipboard. Clicking outside dismisses it without stealing focus back from the newly selected application.

The palette footer names the delivery mode and, when known, the target application. It must not imply that the app understands the receiving chat.

### 4.3 Direct action shortcut

A direct shortcut bypasses search, not safety checks.

Capture a fresh target and invocation, load the action, render variables, and use the standard execution engine. Ignore disabled or deleted actions. If execution is blocked, show the same recoverable error used by the palette.

Do not run an action repeatedly while its shortcut is held. Do not register direct shortcuts by default for starter or imported actions.

### 4.4 Create and edit an action

The editor contains name, optional description, aliases, category, tags, text, delivery preference, favorite toggle, enabled toggle, and optional direct shortcut.

Save is explicit. `Cmd/Ctrl+S` saves. Cancel or closing a dirty editor asks whether to discard changes. Saved changes appear in an already-open palette without restarting the app.

Duplicate creates a new ID and removes direct shortcuts. Deleting requires confirmation and unregisters any associated shortcut. Disabling hides the action from the palette and disables its shortcut while preserving its configuration.

### 4.5 Enable automatic paste

Explain what will happen before requesting permission: the app will remember the prior window, copy the action, return to that window, and issue a paste shortcut. It will not press Enter.

Provide a test using harmless text and an external text editor. After that test, the user can enable paste and choose it as the default.

Paste requires both a working platform adapter and user opt-in. Provide a simple per-application paste rule. A new target app starts as copy-only until the user explicitly enables it from a named target prompt or Settings. Do not treat a successful test in one app as proof that all apps behave the same way.

Terminal applications remain copy-only in V1. Browser windows are matched as applications, not individual websites or tabs. The user must focus the intended text field; the app does not inspect browser content.

## 5. Delivery engine

### 5.1 Delivery rules

Each action has `deliveryMode = inherit | copy | paste`. An inherited mode uses the global setting. Shift+Enter overrides everything to copy.

A paste preference does not override missing permission, an unsupported platform, a copy-only application rule, an unknown target, or a failed focus check.

Normal paste behavior applies: it inserts at the target's cursor and may replace selected text. Quick Actions must not issue Select All, Delete, navigation keys, or an extra newline to “make room.” It does not force text to the end of a draft.

### 5.2 Native invocation context

Keep an in-memory invocation record containing a random ID, creation time, source, captured target identity, cancellation state, and a consumed flag. The target includes a native window identifier and process identity, not just a display name.

Keep OS handles in Rust. Never accept a target handle or arbitrary process ID supplied by the webview. Each invocation may perform only one delivery: claim it before clipboard mutation and reject any second delivery even if it uses a new idempotency key. A failed preflight may transition to an explicit copy fallback before that claim; recovery after a clipboard write uses the separate copy-only recovery token. An invocation expires after five minutes or when explicitly cancelled. Reopening the palette creates a fresh invocation.

Opening from the app launcher, tray menu, or library may not provide a reliable prior text target. Default those invocations to copy. Never guess using an old target from a previous action.

### 5.3 Execution sequence

| Step | Required behavior |
| --- | --- |
| 1. Validate | Check invocation, enabled action, current revision, and delivery request. Reject a second execution while one is active. |
| 2. Render | Read clipboard text only if the template needs it; read before overwriting. Resolve date/time from one captured local instant. Validate output size and characters. |
| 3. Preflight | For paste, check opt-in, target identity, application rule, and permission. Do not request a new OS permission in the middle of delivery. |
| 4. Recover | If preflight blocks paste, offer **Copy instead** and an explanation. Do not silently report a paste success. |
| 5. Copy | Write the final plain text once. If the write fails, keep the palette open and do not inject anything. |
| 6. Hide | Hide the palette before any native paste operation. Copy-only completion may restore the original window when safe, but must not inject keys. |
| 7. Restore | For paste, activate the captured window and verify that exact target is foreground. If it closed, changed, or activation fails, stop. |
| 8. Wait | Wait for shortcut modifiers to be released, with a bounded timeout. Do not paste while the user's original shortcut is still held. |
| 9. Recheck | Verify foreground target and that the clipboard still contains this execution's output immediately before injection. Abort if either changed. |
| 10. Paste | Issue one standard paste chord. Release all synthetic modifiers even on failure. Never send Enter. |
| 11. Finish | Return an honest result and update local usage metadata once. Release transient state. |

Check cancellation at every boundary before injection. Cancellation after a successful clipboard write returns `copied_not_pasted`; it does not claim that no mutation occurred. Never try to undo a user copy or already-issued input.

The adapter should prefer focus events or explicit verification over an unconditional sleep. Use a maximum focus wait of 1.5 seconds and modifier-release wait of 1 second as initial tuning values. Exceeding either stops paste; it does not trigger a blind retry.

There is no universal atomic “verify focus and paste” operation. Checking the clipboard also does not lock it against other writers. Checks reduce risk but cannot eliminate every OS race. Likewise, an input API's success does not prove that the target consumed the clipboard. Do not claim stronger guarantees in UI or tests.

### 5.4 Result model

| Result | Meaning | User feedback |
| --- | --- | --- |
| `copied` | Clipboard write completed; no paste attempted. | “Copied.” |
| `paste_requested` | The adapter issued the paste chord to the verified foreground target. | Usually close silently; diagnostics say “Paste requested,” not “Insertion verified.” |
| `copied_not_pasted` | Copy succeeded, but focus, permission, clipboard, or injection checks blocked paste. | Explain that paste did not complete. Say text remains available only if clipboard ownership/content still matches. |
| `cancelled` | Cancelled before clipboard mutation. | No success notification. |
| `failed_before_copy` | Validation, rendering, or clipboard write failed. | Keep an actionable error visible. |

An OS may silently ignore a paste request. The user can paste the existing clipboard manually; never automatically repeat an operation after input may have been issued.

For a detected failure after copy, retain at most one rendered recovery payload in memory for 60 seconds, or until the recovery UI is dismissed or another invocation starts. **Copy again** uses that frozen payload; it must not reread `{{clipboard}}` and accidentally nest the previous output. An opaque recovery token expires with the payload. After expiry, remove the recovery command and require a fresh invocation. This is temporary error recovery, not a clipboard history.

### 5.5 Clipboard policy

V1 intentionally leaves the rendered text on the clipboard. Warn about this in paste setup and Settings.

Do not save clipboard contents to a database, log, crash report, usage history, or backup. Do not continuously monitor the clipboard. Drop transient references after completion, except for the bounded recovery payload in section 5.4; do not promise secure memory erasure.

Read only the system clipboard, not the X11 primary-selection clipboard. Images and rich text are not template inputs. Copy writes a plain-text representation.

Automatic clipboard restoration is out of scope. Restoring after a fixed delay could race with a slow target or overwrite a newer user copy. Do not implement it as an invisible convenience.

### 5.6 Unsafe targets and text

Never deliberately paste into detected password/secure fields or known terminal applications. If target identity is unavailable, require manual paste.

Terminal detection is not universal, especially inside browser and IDE panes. The setup warning must explain that multiline paste can execute commands in a terminal even when Quick Actions never sends Enter. A “no auto-submit” design is not a guarantee of no effects in every receiving application.

Reject NUL, ESC, and other C0 control characters except tab, carriage return, and line feed before clipboard mutation. Show the location of the invalid character without logging the text. Do not silently strip or truncate content.

## 6. Templates and starter actions

### 6.1 Template syntax

| Token | Expansion |
| --- | --- |
| `{{clipboard}}` | Current plain-text clipboard at execution time. |
| `{{date}}` | Local date in `YYYY-MM-DD` format. |
| `{{time}}` | Local time in `HH:mm` format, using a 24-hour clock. |

Templates are plain text. Preserve Unicode, indentation, and whitespace; normalize editor line endings to LF when saving. Do not trim clipboard input or normalize its line endings.

Use one non-recursive parsing pass. Clipboard text that contains `{{date}}` remains literal clipboard text; it is not evaluated again. Repeated tokens use the same clipboard snapshot and clock instant for one execution.

An escaped opening delimiter, `\{{`, produces a literal `{{` and removes that escape character. Define backslash handling in parser tests: pairs of backslashes are literal; an unmatched final backslash escapes the opening delimiter. Unescaped unknown, malformed, or unsupported tokens are validation errors. Ordinary single braces, including JSON objects, stay unchanged.

An empty, non-text, unreadable, or oversized clipboard blocks a template that needs `{{clipboard}}`. Do not replace it with an empty string without telling the user. Templates without that variable must work without reading the clipboard.

The editor's preview uses clearly labeled sample clipboard text. It must not read the real clipboard merely because an action is selected or the editor opens.

### 6.2 Validation limits

These are product limits, not library limits. Enforce them in Rust and mirror them in the UI.

| Field | Limit |
| --- | --- |
| Name | 1–100 Unicode scalar values after trimming. |
| Description | Up to 300 Unicode scalar values. |
| Template | 1–65,536 UTF-8 bytes; not whitespace-only. |
| Aliases | Up to 10; each 1–50 Unicode scalar values. |
| Tags | Up to 10; each 1–30 Unicode scalar values. |
| Category name | 1–50 Unicode scalar values. |
| Rendered output / clipboard input | 1 MiB maximum each. |
| Local library | Up to 5,000 actions. |
| Import file | 10 MiB maximum, including all content. |

Show “too large” errors before executing. Never silently truncate a prompt. Permit duplicate action names but show the category to distinguish them; IDs are authoritative.

### 6.3 Starter actions

Offer these as editable templates during onboarding. No direct shortcuts. Use the inherited delivery preference. Installing or updating the app must not overwrite edits to them.

**Resolve CI** — category: Coding; tags: `ci`, `fix`, `git`

> Work in this conversation and the current checkout. Inspect the CI failures for the current branch or pull request using the tools available to you. Identify the cause, make the smallest appropriate fix, and run the relevant checks. Do not commit, push, or start another conversation unless I ask. If you cannot access the failure logs, ask me to provide them. Report what changed and what you verified.

**Resolve merge conflicts** — category: Coding; tags: `git`, `conflicts`

> Inspect the current Git state and explain which operation caused the conflicts. Resolve them while preserving the intent of both changes. Ask when the intended behavior is ambiguous. Do not discard unrelated work, commit, push, or continue a rebase or merge without my approval. Summarize the resolutions and the checks you ran.

**Explain this PR** — category: Coding; tags: `review`, `explain`

> Explain this pull request as a linear flow. First describe the behavior before the change: what called what, in what order, and what happened. Then explain the new flow and its user-visible effects. Identify changed conditions, removed calls, side effects, and failure paths. Use simple technical English. Ask for the PR or diff if it is not available in this conversation.

**Review current changes** — category: Coding; tags: `review`, `bugs`

> Review the current changes for correctness, regressions, missing cases, and unsafe assumptions. Focus on concrete issues rather than style preferences. Explain each finding with the relevant file, behavior, and consequence. Do not modify files unless I ask. State what you could not verify.

**Rewrite clearly** — category: Writing; tags: `english`, `rewrite`

> Rewrite the text below in clear, natural English. Keep the meaning and tone. Remove filler and unnecessary jargon. Return only the rewritten text.
>
> Text:
> {{clipboard}}

**Create a handoff** — category: Coding; tags: `docs`, `handoff`

> Create an implementation handoff from this conversation. Include the goal, decisions, interfaces, affected areas, edge cases, completed work, pending work, and verification steps. Clearly separate confirmed details from assumptions. Do not invent missing implementation details.

## 7. Search and keyboard behavior

### 7.1 Search rules

Search enabled actions by name, aliases, tags, and category. Search is case-insensitive and accent-insensitive, without changing the displayed or saved text. V1 does not search prompt bodies.

Split the query into whitespace-separated tokens. Every token must match at least one searchable field. Support exact, prefix, substring, and fuzzy subsequence matches.

Use this ordering: exact full-name match; name/alias prefix matches; word matches; substrings; fuzzy matches. Within a match tier, rank name above alias, alias above tags, and tags above category. Use favorites, then latest use, then name and ID as deterministic tie-breakers. A favorite must not displace a substantially better text match.

For an empty query, show favorites first, then recent actions, then remaining actions alphabetically. Show each action once. Recompute usage ranking between invocations, not while a user is navigating an open result list.

Keep the selected action stable while it remains in the result set. A changed query with no surviving selection selects the first result. No results means Enter does nothing.

### 7.2 Keyboard map

`Primary` means Command on macOS and Control elsewhere. Display native glyphs on macOS and readable text on Windows/Linux.

| Context | Keys | Behavior |
| --- | --- | --- |
| Global | User's palette shortcut | Open palette; if already open, cancel it. |
| Global | User's action shortcut | Execute that action through the shared engine. |
| Palette | Up / Down | Move through results without changing input focus. |
| Palette | Enter | Execute selected action in its effective delivery mode. |
| Palette | Shift+Enter | Copy selected action without paste. |
| Palette | Escape | Close an open child menu first; otherwise cancel the palette. |
| Palette | Primary+K | Open the selected action's menu. |
| Palette | Primary+N | Open a new action in the library. Cancel the current delivery invocation. |
| Palette | Primary+, | Open Settings. Cancel the current delivery invocation. |
| Editor | Primary+S | Validate and save. |
| Editor | Escape | Close after handling unsaved changes. |

Preserve normal text-editing shortcuts. Do not hijack Primary+C when text is selected. Tab and Shift+Tab follow a predictable accessible focus order. Enter during IME composition must not execute an action.

### 7.3 Shortcut registration

Store requested bindings separately from runtime registration status. Validate syntax and internal conflicts, then attempt OS registration. Registration success does not prove that no foreground app previously used the chord.

When replacing a binding, register the replacement first when the backend allows it. Remove the old binding only after success. If the platform cannot stage the change, use a rollback path and report the actual active binding. Never leave the UI claiming that an inactive binding works.

A failed direct-action shortcut must not disable the palette. Restarting, waking the machine, or toggling shortcuts must not produce duplicate handlers. Process one activation per key press/release cycle.

## 8. Screens and visual design

### 8.1 Palette

Use a small, frameless window that appears on the work area of the captured target monitor. If that monitor is unavailable, use the pointer monitor, then the primary monitor. Clamp position and size to the visible work area.

Initial size: approximately **680 × 480 logical pixels**, no larger than 90% of the work area's width or height. At smaller sizes, reduce preview space before hiding search, results, or delivery feedback.

Layout, from top to bottom:

| Region | Content |
| --- | --- |
| Search | Search icon, text field, optional clear button. |
| Results | Action icon, name, short description/category, favorite indicator, optional shortcut badge. |
| Preview | Selected template excerpt, collapsed by default; no live clipboard contents. |
| Footer | Target app or “Copy mode,” Enter behavior, Shift+Enter hint, action-menu hint. |

Target a result-row height of 48–56 pixels and show roughly six to eight rows. Keep the app visually quiet: one selection highlight, one accent color, restrained shadows, and no oversized branding.

Keep the palette process/window warm after first use. It is topmost only while visible. It must not leave an invisible input-blocking overlay behind.

### 8.2 Library and editor

Use a normal resizable management window, approximately **1,000 × 720 logical pixels** with a minimum near **760 × 540**. Adapt to smaller displays and 200% text scaling.

Left area: All Actions, Favorites, categories, Settings. Center: searchable action list with New, Duplicate, Enable/Disable, and Delete. Right area: the selected action editor. On narrower windows, navigate between list and editor rather than compressing both beyond usability.

The text editor supports multiline text, indentation, undo/redo, and a character/byte limit indicator. No rich-text toolbar. Show variable chips or an insert-variable menu, plus inline validation messages.

The action menu includes Copy, use configured delivery, Edit, Duplicate, Favorite/Unfavorite, and Enable/Disable. Destructive actions are separated and labeled.

### 8.3 Settings

Use four small sections: General, Shortcuts, Paste & Permissions, and Data. Include an About area with version, build identity, and platform status.

A settings page must show requested versus active shortcuts and explain copy-only behavior. Avoid a single vague “Permissions granted” indicator when only some capabilities work.

### 8.4 Visual tokens

These are starting design values. Adjust them after contrast and native-window checks.

| Token | Light | Dark |
| --- | --- | --- |
| Background | `#FAFAFB` | `#17181C` |
| Raised surface | `#FFFFFF` | `#202228` |
| Main text | `#181A20` | `#F2F3F5` |
| Secondary text | `#5B616E` | `#AAB0BE` |
| Border | `#D8DCE4` | `#383C46` |
| Accent | `#315ECA` | `#A8C1FF` |

Use system UI fonts and system monospace for template previews where helpful. Do not require downloaded fonts. Use a consistent icon set bundled locally.

Use a 4/8-pixel spacing scale, 12–16-pixel panel radii, and clear 2-pixel focus indicators. Body text should generally be 14–15 pixels. Do not put essential text in tiny labels.

Opening/closing motion should be short, roughly 100–150 ms, and disabled for reduced-motion settings. Blur, transparency, and vibrancy are optional enhancements, not prerequisites for a good interface.

### 8.5 Accessibility and states

The palette must expose an accessible search/combobox and selectable result list. Announce selected results, errors, and result counts without reading a full prompt on every keystroke. Ensure every function is available by keyboard.

Target 4.5:1 contrast for normal text and 3:1 for relevant large text and control boundaries. Do not convey status through color alone. Test system high-contrast modes, screen readers, IME input, and 200% scaling.

Required visible states: initial loading, empty library, no search results, invalid template, save failure, shortcut conflict, unavailable paste, permission denied, missing target, copy success, copy failure, and copy-with-paste-blocked.

Use specific error text: “Could not return to T3 Code. Copy the action and paste it manually.” Avoid “Something went wrong” when the reason is known.

## 9. Native integration

### 9.1 Adapter boundary

Keep platform-specific behavior behind a Rust adapter with these responsibilities:

| Operation | Contract |
| --- | --- |
| `capabilities` | Report support and permission state. |
| `capture_target` | Capture the current external native window before Quick Actions appears. |
| `activate_target` | Attempt to restore that specific window. |
| `verify_target` | Confirm target identity and foreground status. |
| `wait_for_modifiers` | Bounded check for release; no general key logging. |
| `request_paste` | Send exactly one permitted paste chord. |
| `open_permission_settings` | Open the relevant fixed OS settings location on explicit user request. |

These names describe internal interfaces, not direct webview permissions. An unavailable implementation returns a typed unsupported result rather than pretending to succeed.

### 9.2 macOS

Use native application/window identity and activation APIs. Accessibility authorization is a user-controlled prerequisite for the chosen input-control path. Offer a Settings link and a recheck action. Do not repeatedly prompt after denial. [S07]

Prototype focus behavior with full-screen windows, multiple Spaces, and two windows of the same application. Capturing only the bundle ID is insufficient.

Use Command+V for the supported standard paste path. Do not use AppleScript, screen capture, or continuous event taps as a workaround. Do not ask for Input Monitoring or Screen Recording unless a later, separately approved feature actually needs them.

### 9.3 Windows

Capture both window identity and process identity. Use native foreground activation and input APIs; verify their outcomes. Never run the application as administrator merely to paste into elevated targets. Keep those targets copy-only. [S05] [S06]

Use Control+V for approved standard text applications. Do not attach to another process or disable OS focus protections to force delivery.

### 9.4 Linux

Detect the actual session/backend at runtime. Under X11, prove the adapter's focus and input behavior in the supported desktop before enabling paste. Do not treat an XWayland window as proof of native Wayland coverage.

For Wayland V1, offer the palette through the application launcher, tray menu when present, or a desktop-configured shortcut that launches the app with `--show-palette`. The already-running single instance must receive that request. This route is copy-only because a trusted original target may be unavailable.

The XDG GlobalShortcuts portal can be added later. Synthetic input through a remote-desktop portal involves a separate, consent-based session and is not part of the clipboard plugin. Do not request a remote-control session just to make V1 look feature-complete. [S04] [S08]

Do not require root, broad device permissions, a privileged input daemon, or hidden `xdotool`/`ydotool` dependencies.

### 9.5 Library choice

A cross-platform input library such as Enigo is a candidate implementation detail, not proof of equivalent support. It may be used behind the adapter after verifying its current feature flags, permissions, and behavior. Native APIs remain necessary where window identity or activation is not covered. [S09]

Prove target capture, focus restoration, and paste in a small test harness before investing heavily in UI polish.

## 10. Architecture and storage

### 10.1 Stack

| Layer | Choice | Purpose |
| --- | --- | --- |
| Desktop | Tauri 2 | Windows, app lifecycle, native boundary, packaging. |
| Frontend | React + TypeScript + Vite | Two local UI surfaces: palette and library/settings. |
| Styling | CSS variables and reusable components | Small visual system; no runtime theme service. |
| Backend | Rust | Validation, persistence, shortcuts, clipboard, and native delivery. |
| Database | SQLite through `rusqlite` | Typed repository functions and transactional writes. |
| Inter-process calls | Narrow Tauri commands | UI requests intent; Rust decides and executes. |
| Global shortcuts | Tauri global-shortcut plugin where supported | Native registration handled centrally. |
| Clipboard | Tauri clipboard-manager plugin via Rust | Explicit text reads and writes. |
| Lifecycle | Single-instance plugin, tray API, optional autostart plugin | Resident desktop utility. |

Do not expose a general SQL API to JavaScript. Although Tauri offers an SQL plugin, this design chooses a Rust-owned database to keep validation and privileged operations in one place.

Use compatible, stable dependency versions and commit package-manager and Cargo lockfiles. Do not copy a version number from this document as a claim that it is the newest release. Tauri's official prerequisite documentation is the build baseline. [S10]

### 10.2 Responsibility split

The frontend owns rendering, search over cached action metadata, form state, and local navigation. Rust owns authoritative validation, template parsing, database writes, execution state, and OS interactions.

The palette does not start shell processes or evaluate templates. It sends an action ID and an invocation ID. The backend reloads the authoritative action before execution.

Use one serialized database owner on a worker thread. Keep database and file operations off UI/event-loop threads. Marshal native operations to the platform's required event loop; the global-hotkey library documents thread requirements for macOS and Windows. [S03]

A library change invalidates the palette cache through an event. On a missed event or revision mismatch, fetch a new snapshot. Do not rely on shared JavaScript memory between windows.

### 10.3 Suggested structure

```text
src/
  app/
  features/palette/
  features/actions/
  features/settings/
  components/
  styles/
  search/
  ipc/
  test/
src-tauri/
  src/commands/
  src/domain/
  src/storage/
  src/execution/
  src/platform/macos/
  src/platform/windows/
  src/platform/linux/
  src/shortcuts/
  src/lifecycle/
  capabilities/
  permissions/
  migrations/
  tests/
docs/
  platform-support.md
  manual-test-checklist.md
  release-process.md
```

### 10.4 Database model

Use UUIDs for identity, RFC 3339 UTC timestamps for storage, and increasing integer revisions for optimistic concurrency. Store local preferences and application rules in this database, not in a second competing settings file.

**`actions`**

| Field | Type / constraint |
| --- | --- |
| `id` | UUID, primary key. |
| `name`, `description`, `template` | Text; limits from section 6. |
| `aliases_json`, `tags_json` | Validated arrays of strings. |
| `category_id` | Nullable category reference; clear it when category is deleted. |
| `delivery_mode` | `inherit`, `copy`, or `paste`. |
| `favorite`, `enabled` | Booleans. |
| `use_count` | Non-negative integer, initially zero. |
| `last_used_at` | Nullable timestamp. |
| `created_at`, `updated_at` | Timestamps. |
| `revision` | Positive integer; increment on changes. |

**`categories`**: ID, display name, normalized name key, sort order, timestamps, revision. Normalize category/tag comparison with Unicode normalization and case folding; trim outer whitespace and deduplicate tags and aliases by their normalized keys while keeping the first display spelling. Category names are unique by normalized key. Tags are action-local strings; do not add a tag-management subsystem.

**`shortcuts`**: ID, platform, owner key (`palette` or `action:<uuid>`), nullable action reference, requested accelerator, normalized accelerator, enabled flag, revision. Enforce one binding per owner/platform and no duplicate enabled normalized accelerator on one platform. Runtime active/error status is computed, not treated as proof in the database.

**`app_paste_rules`**: platform, stable native application identity, display label, rule (`copy_only` or `paste_allowed`), timestamps. Absence means copy-only. Do not persist window titles, browser URLs, native window handles, or a running-process history.

**`settings`**: key, validated JSON value, revision. Only allow known keys.

**`library_state`**: one row with the current catalog revision. Increment it in the same transaction as action or category changes, including imports and usage changes that affect snapshots.

**`schema_migrations`**: migration version and application timestamp.

Usage metadata increments once for `copied`, `paste_requested`, or `copied_not_pasted`, after a successful copy. Its meaning is “action text prepared,” not “task succeeded.” Cancelling or failing before copy does not increment it.

### 10.5 Data integrity and backup

Use the OS application-data directory through Tauri's path APIs. Do not put the database beside the executable or under a source-code checkout.

Enable foreign keys, use transactions, and bind SQL parameters. Reject stale editor revisions instead of silently overwriting another window's save.

Back up before schema migration and an import that modifies existing data. Keep the latest five automatic backups. Use SQLite's online backup API or its supported equivalent rather than copying a live database file while journal/WAL data may be outstanding. [S11]

Migrations must be ordered and transactional where possible. A failed migration leaves the original usable. A newer unsupported schema opens a recovery screen; never reset the database automatically. Corruption or full-disk errors must not lead to an empty replacement library without explicit confirmation.

Document that deleting records and backups is not a secure-erase guarantee.

## 11. Frontend/backend contracts

These are application contracts to implement, not claims that Tauri supplies these commands.

| Command | Input | Output / restriction |
| --- | --- | --- |
| `list_actions` | Optional category/enabled filters. | Metadata snapshot and library revision; exclude template bodies. |
| `get_action` | Action ID. | Full action and revision. |
| `save_action` | Validated fields, optional ID, expected revision for updates. | Saved record and new revision. |
| `duplicate_action` | ID and expected revision. | New record; no direct shortcut. |
| `delete_action` | ID and expected revision. | Deletion result; unregister shortcut safely. |
| `save_category` / `delete_category` | Fields or ID, expected revision. | Updated category state; deletion uncategorizes actions. |
| `get_settings` / `save_settings` | Allowed keys and expected revision. | Validated preferences; no arbitrary JSON setting names. |
| `configure_shortcut` | Owner, platform, accelerator, enabled flag, expected revision. | Saved preference plus actual registration status. |
| `configure_paste_rule` | Known application identity token from native capture, rule. | Saved rule; cannot bypass unsupported platforms or blocked targets. |
| `get_capabilities` | None. | Capability and permission report. |
| `open_palette` / `close_palette` | No target supplied by JS. | Opens a native-owned invocation or cancels the current one. |
| `execute_action` | Invocation ID, action ID, expected action revision, delivery override, idempotency key. | Typed execution result; only from palette or native direct-shortcut flow. |
| `copy_action` | Action ID, expected revision, idempotency key. | Library-only copy through the shared engine; creates a copy-only invocation with no external target. |
| `open_permission_settings` | Enumerated permission kind. | Opens a fixed supported OS destination. |
| `preview_import` | User starts native file picker. | Validated preview, proposed changes, opaque short-lived token. |
| `commit_import` | Preview token and explicit merge choices. | One transaction after revision checks and backup. |
| `export_actions` | Selected IDs or all. | Native save dialog and file-write result. |
| `copy_recovery_output` | Current recovery token. | Copies an already-rendered payload; does not rerender variables. |
| `clear_usage` | Confirmation. | Clears usage counters and recent dates, not actions. |

For direct native shortcuts, execution is internal; do not manufacture a webview call.

All commands return a typed success or a structured error with `code`, a safe message, and an optional safe field path. Never send a raw database error, filesystem path, or template content into diagnostics by default.

Events: `actions_changed` with library revision, `settings_changed`, `shortcut_status_changed`, and `execution_result`. Send execution results only to the initiating surface. Do not broadcast rendered text or clipboard contents.

One execution is allowed at a time. Repeated requests with the same idempotency key return the previous result instead of repeating side effects. Retain result identities in memory for the invocation lifetime. Do not persist or replay pending execution after a crash.

## 12. Import and export

### 12.1 Format

Use UTF-8 JSON, with a published JSON Schema checked into the repository. Schema version is independent of application version.

Example export:

```json
{
  "schemaVersion": 1,
  "exportedAt": "2026-10-06T16:43:00Z",
  "actions": [
    {
      "id": "7b5bdc21-bf22-4d6e-8a7c-3c2376e1c8a4",
      "name": "Resolve CI",
      "description": "Ask the current agent to inspect and fix CI.",
      "aliases": ["fix build", "fix checks"],
      "category": "Coding",
      "tags": ["ci", "git"],
      "template": "Inspect CI failures for the current branch. Make the smallest appropriate fix and report your verification. Ask for logs if they are unavailable. Do not commit or push unless I ask.",
      "deliveryMode": "inherit",
      "favorite": true,
      "enabled": true
    }
  ]
}
```

This is the normative V1 field set. `description`, `category`, aliases, and tags may be empty or null only as defined by the schema: description is a string, category is a nullable string, and aliases/tags are arrays. All listed fields are required in exported V1 objects. Import rejects unknown fields rather than interpreting future executable behavior.

Do not export direct shortcuts, paste permissions, app rules, OS handles, machine paths, usage history, or clipboard data. Export contains only stored templates, never live variable expansions.

### 12.2 Import behavior

Read a bounded file from a native picker and validate structure, UTF-8, types, IDs, duplicate IDs within the file, size limits, and templates before mutation.

Show action count, category changes, duplicate IDs/names, and rejected entries. Reject the whole file on invalid input in V1; do not silently import a partial set.

Check that the resulting library, including disabled actions, will remain within the 5,000-action limit.

Default to **Add as new actions** with new IDs. Preserve content and organization, but set imported delivery modes to `copy` and assign no shortcuts. Explain this reset in the preview.

An optional **Update matching IDs** choice requires explicit confirmation and a before/after summary. Never treat a matching name as permission to overwrite. Map categories by normalized category name. Reuse an existing category instead of creating duplicates.

Bind preview tokens to the parsed content and the library revision used to prepare the preview. Tokens expire after five minutes. Recheck before commit; if the library changed, require a refreshed preview rather than applying stale decisions.

Back up, apply all changes in a transaction, update library revision, and notify both windows. Cancelling does not modify the database or register any shortcut.

For export, use a native save dialog, explicit overwrite confirmation, and a temporary file plus replacement in the same destination directory. Do not claim success until the write completes. Never take arbitrary write paths from imported content.

## 13. Settings and lifecycle

### 13.1 User settings

| Setting | Initial value |
| --- | --- |
| Theme | System. |
| Default delivery | Copy. |
| Automatic paste | Disabled until setup completes. |
| Palette shortcut | User-selected during onboarding; may remain unregistered if unavailable. |
| Direct action shortcuts | None. |
| Launch at login | Off. |
| Keep running after closing library | On only after explaining background/tray behavior. |
| Preview panel | Collapsed. |
| Per-app paste rules | Empty; unknown targets are copy-only. |
| Diagnostics logging | Off. |

Keep these installation-local. Do not assume permission or shortcut settings are portable between machines.

### 13.2 Resident process

Initialize single-instance handling before registering shortcuts. A second launch shows the existing UI rather than creating another database writer or registering another shortcut. Tauri provides single-instance and autostart plugins for the lifecycle integration. [S12] [S13]

Accept only the fixed `--show-palette` UI activation argument in V1. No command-line action execution, prompt injection, file import, or arbitrary path opening.

The tray menu, where available, contains Open Palette, Manage Actions, Settings, Pause/Resume Shortcuts, and Quit. Linux tray click behavior differs from other desktops; provide actual menu items and do not depend on a left-click event. [S14]

If no tray is available, the application launcher and normal window must remain a clear way back in. Do not leave users with an invisible app they cannot reopen or quit.

Quit unregisters shortcuts, closes the database cleanly, and ends the process. Closing the palette only hides it. Auto-start, when enabled, starts hidden after onboarding is complete and never copies or pastes anything.

Pause unregisters global shortcuts but leaves the library usable. Resume attempts registration again and shows failures. Screen lock or suspend cancels active invocations. Never finish an old paste after unlock or resume.

Opening Settings, editing an action, or receiving a second-launch request must not steal focus during a pending paste. Cancel or defer the UI transition at a defined execution boundary.

## 14. Security and privacy

### 14.1 Permissions boundary

Only load bundled local frontend assets. Block webview navigation to remote pages, remote iframes, inline executable content, and remote scripts. Use a production Content Security Policy with the minimum Tauri IPC allowances required by the installed version.

Render action text, import content, and labels as text, not HTML. Do not render unsanitized Markdown or auto-open links embedded in templates.

Define separate capabilities for the palette and management window. The palette can read action metadata and request execution; it cannot import files, edit app rules, or write arbitrary settings. The management window can edit the library and run copy tests, but it cannot supply a native paste target.

Tauri's plugin permissions do not automatically restrict all custom application commands. Its documentation states that registered application commands are available to app windows by default unless restricted, including through `AppManifest::commands`. Define explicit custom-command permissions and validate caller window labels in privileged handlers. [S15]

Keep the clipboard, input injection, database, and shortcut plugins behind Rust-owned services. Do not grant broad JavaScript access just because a plugin supports it. Do not expose generic shell, filesystem, HTTP, SQL, keypress, or window-creation commands.

### 14.2 Threats and mitigations

| Risk | Required mitigation |
| --- | --- |
| Clipboard secret exposure | Read only for explicit execution, no history/logging, bounded input, clear privacy notice. |
| Pasting into the wrong app | Capture before palette focus, bind to native target, require app opt-in, recheck before injection, fail to copy/manual flow. |
| Duplicate paste | Serialized execution, idempotency, key-repeat suppression, no automatic post-injection retry. |
| Malicious import | Strict schema, no executable fields, no active shortcuts, preview and transaction. |
| Template code execution | Literal one-pass substitution only; no eval, shell, expressions, or recursive expansion. |
| Renderer compromise | Local assets, restricted CSP, narrow commands, caller checks, Rust validation. |
| Clipboard restoration race | No automatic restoration or clearing in V1. |
| Data loss | Revision checks, transactions, backups, failed-migration recovery. |
| Privilege escalation | Never request root/admin access to overcome OS input restrictions. |

Local-only does not mean encrypted. SQLite, exports, and backups contain readable action text. The system clipboard and external clipboard tools are outside this app's privacy boundary. Do not position the app as a password manager.

### 14.3 Diagnostics

No telemetry or analytics uploads. No network requirement during normal use.

Optional diagnostics record only bounded event codes, build/platform version, durations, and capability states. Exclude action bodies, clipboard data, action names, file paths, window titles, URLs, and credentials. Keep at most 1 MiB of rotating local diagnostic data and provide a clear-delete control.

An exported diagnostic bundle is opt-in and previewable. Disable WebView developer tools and test automation endpoints in distribution builds.

## 15. Error handling

| Code | Meaning | Recovery |
| --- | --- | --- |
| `SHORTCUT_CONFLICT` | Binding conflicts internally or failed OS registration. | Keep old working binding; choose another. |
| `SHORTCUT_UNSUPPORTED` | No supported global-shortcut backend. | Launch palette manually or use desktop launcher binding. |
| `PERMISSION_REQUIRED` | Optional paste permission is missing. | Copy instead or open permission setup. |
| `TARGET_UNAVAILABLE` | No valid captured external window. | Copy instead. |
| `TARGET_CHANGED` | Target identity or focus no longer matches. | Stop paste; offer manual recovery. |
| `FOCUS_TIMEOUT` | Could not verify foreground target in time. | No injection; manual paste. |
| `MODIFIERS_HELD` | Original modifier keys were not released in time. | Stop; user can invoke again. |
| `PASTE_UNSUPPORTED` | OS, session, or application rule blocks paste. | Copy instead. |
| `CLIPBOARD_UNAVAILABLE` | Clipboard read/write failed. | Retry only on explicit user action. |
| `CLIPBOARD_CHANGED` | Another copy occurred before paste. | Do not paste or overwrite the newer clipboard automatically. |
| `CLIPBOARD_EMPTY` | Required plain-text clipboard input is missing. | Copy source text, then invoke again. |
| `TEMPLATE_INVALID` | Unknown/malformed variable or prohibited control character. | Edit action; show error location. |
| `OUTPUT_TOO_LARGE` | Input/output exceeds configured limits. | Reduce text; no truncation. |
| `REVISION_CONFLICT` | Saved record or import basis changed. | Reload and reconcile. |
| `EXECUTION_BUSY` | Another action is delivering. | Ignore duplicate activation and show brief status if needed. |
| `INVOCATION_EXPIRED` | Target context expired or was cancelled. | Reopen from the intended application. |
| `STORAGE_FAILURE` | Save, migration, backup, or disk operation failed. | Keep current state and offer recovery. |

Errors after a clipboard write must report that stage accurately. A failed paste is not equivalent to a failed copy.

## 16. Performance and test plan

### 16.1 Performance targets

These are acceptance targets to measure, not current benchmarks. Use release builds and record hardware, OS, display/session type, library size, and percentile methodology.

| Measurement | Target |
| --- | --- |
| Warm palette open to search-ready | P95 under 150 ms. |
| Search over 1,000 actions | P95 under 50 ms from input to painted results. |
| Search over 5,000 actions | P95 under 100 ms. |
| Cold start to usable library | Target under 2 seconds on reference hardware. |
| Idle CPU | No continuous polling; average below 1% over a five-minute idle sample. |
| Memory | Initial target below 150 MiB steady-state across app and WebView processes; investigate platform differences. |
| Normal copy | Target under 100 ms after validation for a small static action. |

Native permission dialogs and user delays are excluded from latency targets. If targets are missed, report measurements and causes rather than hiding the result.

### 16.2 Automated tests

Rust tests cover validation, template parsing/escaping, one-pass substitution, date/time consistency, limits, migrations, backup/restore, revision checks, import atomicity, and execution state transitions.

Use fake platform adapters to exercise missing permissions, changing focus, closed windows, modifier timeouts, clipboard changes, partial injection failure, repeated invocation, and cancellation. Fake-adapter tests cannot establish real OS support.

Frontend tests cover search ranking, empty states, keyboard navigation, IME composition, dirty editors, action menus, settings status, and multi-window invalidation. Test HTML/script-like templates as inert content.

Use browser-level UI tests with mocked IPC for fast checks and packaged-app tests for the native wrapper. Tauri documents WebdriverIO integration with an embedded driver, including a macOS path; this does not replace external-application focus and paste tests. Test-only driver plugins must be absent from release builds. [S16]

### 16.3 Required acceptance cases

| ID | Scenario | Pass condition |
| --- | --- | --- |
| AT-01 | Fresh installation | Onboarding works without an account, network, or paste permission. |
| AT-02 | Shortcut already used | Registration failure is visible; another binding or launcher remains usable. |
| AT-03 | Warm open | Search receives focus and typed characters are not lost. |
| AT-04 | Search typo/alias | Intended action is found; exact name ranks above a weak favorite match. |
| AT-05 | Disabled action | Missing from palette; direct shortcut does not execute it. |
| AT-06 | Create/edit/restart | Saved content and settings survive restart. |
| AT-07 | Unsaved editor | Closing prompts for discard; no silent data loss. |
| AT-08 | Plain copy | Unicode, indentation, and multiline content match expected output. |
| AT-09 | Clipboard variable | Original clipboard is read before output replaces it. |
| AT-10 | Nested-looking input | Tokens inside clipboard content are not expanded. |
| AT-11 | Missing/oversized input | No output or silent truncation; actionable error. |
| AT-12 | Escape/outside click | No clipboard mutation or late paste. |
| AT-13 | Paste into an approved app | Correct captured window receives one paste request; no extra Enter. |
| AT-14 | Existing draft / selected text | Standard paste semantics; no Select All or draft clearing. |
| AT-15 | Two windows of one app | Exact window is checked, not just process/bundle identity. |
| AT-16 | Target closes or focus changes | Paste stops; no automatic delivery to another window. |
| AT-17 | Clipboard changes before paste | New clipboard is not pasted or silently overwritten. |
| AT-18 | Keys held / repeated Enter | No duplicate delivery; modifiers are cleaned up. |
| AT-19 | Paste permission denied/revoked | Copy works; paste is unavailable until explicitly restored. |
| AT-20 | Elevated Windows target | No privilege escalation; copy-only recovery. |
| AT-21 | Wayland session | Copy works and limitations are explicit; no claimed universal hotkey/paste support. |
| AT-22 | Known terminal | Automatic paste is disabled. |
| AT-23 | US and PT-BR layouts, IME, accents, emoji | Search/editing and displayed shortcut labels work; composition Enter does not execute. |
| AT-24 | Multiple monitors / scaling | Palette stays visible and usable, including display removal. |
| AT-25 | Sleep/lock during delivery | Old invocation is cancelled and never resumes paste. |
| AT-26 | Start app twice | One resident instance, database owner, and shortcut registration set. |
| AT-27 | Missing Linux tray | Launcher and normal window remain usable. |
| AT-28 | Malformed/malicious import | Nothing executes; no records are changed. |
| AT-29 | Valid import / duplicate IDs | Preview matches transaction; no implicit overwrite or active shortcuts. |
| AT-30 | Stale import/editor | Revision conflict blocks unintended overwrite. |
| AT-31 | Disk full / migration failure | Existing data remains recoverable; no silent reset. |
| AT-32 | Diagnostics/export privacy | No clipboard text, runtime target details, or usage data leak into action exports. |
| AT-33 | Keyboard and screen reader | Core flows are usable without a mouse; focus and errors are announced. |
| AT-34 | Distribution build | No dev server, test endpoint, or remote content loaded. |
| AT-35 | Offline use | Create, search, render, copy, and local native operations need no service connection. |
| AT-36 | Retry a failed clipboard-template paste | Copy again reproduces the frozen output without expanding the action a second time; expired tokens cannot run. |

### 16.4 Native compatibility checklist

Test the receiving applications the user actually uses: T3 Code first, then available Claude/Codex desktop clients, an IDE, a browser text field, and a native text editor. Treat them as test targets, not as integrations already verified.

For each supported OS/app pair, record build versions, focus mode, short/multiline/Unicode prompts, existing draft and selected text, multiple windows, denied permission, clipboard race, and any limitations. Run at least 100 repeated paste trials in each advertised primary configuration; investigate every wrong-window or duplicate-paste event.

A finite clean run is release evidence, not a guarantee that all focus races are impossible. Any known wrong-window or duplicate-delivery bug blocks automatic-paste release for that configuration.

## 17. Implementation sequence and release

### 17.1 Milestones

| Phase | Work | Exit condition |
| --- | --- | --- |
| 0. Native feasibility | Target capture, hide/restore, shortcut registration, clipboard write, one paste chord on each target OS. | Evidence-backed support matrix; copy fallback works wherever paste does not. |
| 1. Copy-first core | SQLite, action editor, palette, search, categories/tags/favorites, three variables. | End-to-end offline copy flow with persistence and parser tests. |
| 2. Daily-use workflow | Direct shortcuts, import/export, tray/single-instance, start at login, permissions UI. | Restart, failure, and import cases pass. |
| 3. Optional paste | Per-app opt-in, native execution engine, focus/modifier/clipboard checks, recovery. | Native acceptance gate passes for each advertised configuration. |
| 4. Polish and release | Themes, accessibility, package signing, migration recovery, compatibility documentation. | Release checklist complete with recorded test results. |

The earlier 3–5-day idea is a reasonable planning range for a narrow prototype or a one-platform copy-first build, not a commitment for this entire specification. A tested cross-platform release with optional native paste should be planned as several weeks, depending on OS behavior and available test machines. Full Wayland paste support is a separate scope decision.

### 17.2 Build and distribution

Build on native CI runners for macOS, Windows, and Linux. Run frontend checks, Rust formatting/lint/tests, migrations, package builds, and dependency/security checks. Native UI tests need an interactive desktop, not just a headless build runner.

Initial artifacts: macOS DMG, Windows installer, Linux AppImage and Debian package. Verify runtime requirements such as WebView and Linux libraries against the actual build targets; do not advertise “no dependencies” without testing. [S10] [S17]

Use separate app identifiers and data directories for development and release. Choose a stable production identifier and signing identity before permission testing and wider distribution.

For public macOS distribution, follow signing/notarization guidance. For Windows, plan code signing and distinguish developer test builds from signed releases. Signing keys and credentials belong in protected CI secrets, never in the repository. [S18] [S19]

V1 uses manual updates. Installing an update preserves the database and runs the migration checks. Do not switch to automatic updates without a separate signed-update and recovery design.

### 17.3 Definition of done

The deliverable is a repository containing the app, locked dependencies, schema/migrations, import JSON Schema, tests, package workflows, platform adapters, and concise developer/release documentation.

A V1 release is done when the required copy workflow works on every advertised desktop target; optional paste passes its native gate; action data survives restart and migration; errors have tested recovery; keyboard/accessibility flows work; and the published support matrix matches the evidence.

Unverified features must be labeled unavailable or experimental. Do not mark a platform supported solely because the code compiled.

### 17.4 Instructions for an implementation agent

Build the specified V1, not a general automation framework. Start with the native feasibility test and the copy-first path. Keep OS logic in Rust and UI logic in React. Use one database and one execution engine.

Never add automatic submission, global key logging, clipboard history, remote services, or hidden shell execution. Do not fake native behavior in order to show a completed UI. Preserve unsupported states and verify them.

Keep changes small enough to review. For each milestone, report what was implemented, which tests actually ran, platform evidence, and remaining limitations. A screenshot of the palette is not proof that cross-application paste works.

## 18. Technical references

Official documentation checked on October 6, 2026. These sources support the framework and OS constraints; the product behavior, scope, limits, and architecture above are proposed decisions.

| Ref | Source | Why it matters |
| --- | --- | --- |
| [S01] | Tauri: Global Shortcut | Shortcut plugin and permissions. |
| [S02] | Tauri: Clipboard | Explicit system clipboard read/write. |
| [S03] | `global-hotkey` crate documentation | X11-only Linux statement and platform event-loop requirements. |
| [S04] | XDG Desktop Portal: GlobalShortcuts | Consent/session-based shortcut path for supporting desktops. |
| [S05] | Microsoft: SendInput | Integrity-level and input-state limitations. |
| [S06] | Microsoft: SetForegroundWindow | Restrictions on activating another window. |
| [S07] | Apple: Accessibility access | User-controlled permission for accessibility control. |
| [S08] | XDG Desktop Portal: RemoteDesktop | Separate consent-based input-control session. |
| [S09] | Enigo crate documentation | Candidate input adapter, not a universal support guarantee. |
| [S10] | Tauri: Prerequisites | Build requirements to pin and verify. |
| [S11] | SQLite: Online Backup API | Safe backup rather than a naive live-file copy. |
| [S12] | Tauri: Single Instance | Resident-app launch behavior. |
| [S13] | Tauri: Autostart | Optional start-at-login integration. |
| [S14] | Tauri: System Tray | Tray support and Linux event differences. |
| [S15] | Tauri: Capabilities | Window permissions and custom-command restrictions. |
| [S16] | Tauri: WebDriver | Packaged-app testing options and platform distinctions. |
| [S17] | Tauri: Distribute | Packaging routes. |
| [S18] | Tauri: macOS Code Signing | Signing and notarization setup. |
| [S19] | Tauri: Windows Code Signing | Windows signing setup. |

[S01]: https://v2.tauri.app/plugin/global-shortcut/ "Tauri — Global Shortcut"
[S02]: https://v2.tauri.app/plugin/clipboard/ "Tauri — Clipboard"
[S03]: https://docs.rs/global-hotkey/latest/global_hotkey/ "global-hotkey — Rust documentation"
[S04]: https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.GlobalShortcuts.html "XDG Desktop Portal — GlobalShortcuts"
[S05]: https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput "Microsoft — SendInput"
[S06]: https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setforegroundwindow "Microsoft — SetForegroundWindow"
[S07]: https://support.apple.com/guide/mac-help/allow-accessibility-apps-to-access-your-mac-mh43185/mac "Apple — Allow accessibility apps to access your Mac"
[S08]: https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.RemoteDesktop.html "XDG Desktop Portal — RemoteDesktop"
[S09]: https://docs.rs/enigo/latest/enigo/ "Enigo — Rust documentation"
[S10]: https://v2.tauri.app/start/prerequisites/ "Tauri — Prerequisites"
[S11]: https://www.sqlite.org/backup.html "SQLite — Online Backup API"
[S12]: https://v2.tauri.app/plugin/single-instance/ "Tauri — Single Instance"
[S13]: https://v2.tauri.app/plugin/autostart/ "Tauri — Autostart"
[S14]: https://v2.tauri.app/learn/system-tray/ "Tauri — System Tray"
[S15]: https://v2.tauri.app/security/capabilities/ "Tauri — Capabilities"
[S16]: https://v2.tauri.app/develop/tests/webdriver/ "Tauri — WebDriver"
[S17]: https://v2.tauri.app/distribute/ "Tauri — Distribute"
[S18]: https://v2.tauri.app/distribute/sign/macos/ "Tauri — macOS Code Signing"
[S19]: https://v2.tauri.app/distribute/sign/windows/ "Tauri — Windows Code Signing"
