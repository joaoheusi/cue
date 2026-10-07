# Release process

This build is a local paste-first prototype. macOS installers are Developer ID signed. Public distribution still requires notarization and the native acceptance checks below.

1. Run the locked frontend build/tests and Rust format, lint, and tests.
2. Run the manual checks on each advertised OS. Record failures and update the support table.
3. Build with `npm run package:mac` on macOS, or `npm run package` on Windows and Linux. Use native runners. The macOS script uses an isolated Python environment with pinned `dmgbuild` dependencies. It writes the Finder layout directly and replaces the prior DMG only after the new image succeeds.
4. Keep the Developer ID team and `app.cue.launcher` bundle identifier stable. `package:mac` requires a valid Developer ID Application certificate and verifies the resulting signature before making an installer. It selects the sole developer identity in the keychain, or uses `APPLE_SIGNING_IDENTITY` (certificate name or SHA-1 fingerprint). Multiple developers require explicit selection. Renewed certificates for the same developer keep the same designated requirement. Supply signing/notarization credentials through protected CI secrets. Never check credentials into source.
5. Sign/notarize macOS packages and sign Windows installers. Verify clean-machine launch, runtime prerequisites, offline assets, and absence of debug endpoints.
6. Exercise upgrades with a prior database. Inspect migration backups. A failed migration must preserve the existing database.
7. Publish packages only after the support table matches observed behavior. Label untested integrations unavailable.

Keep rollback backups as archives outside Applications. Do not leave a renamed `.app` backup registered with macOS; it can replace Cue’s display name in Accessibility settings.

Updates are manual. Keep `app.cue.launcher` stable so user data survives updates. Debug builds isolate data in `app.cue.launcher.dev`. Never ship the browser preview database as a migration source. No automatic updater is included.

Do not install unsigned/ad-hoc development bundles over the signed app. Their build-specific designated requirement invalidates existing Accessibility access even when System Settings still shows the switch enabled. When upgrading from the old ad-hoc prototype to the signed app, refresh Cue’s existing Accessibility entry (off/on, or remove and re-add `/Applications/Cue.app`), then quit and reopen Cue. Subsequent signed updates must retain the same bundle identifier and Developer ID team.

The JSON format is independently versioned in `schemas/actions-v1.schema.json`. Runtime validation also enforces UTF-8 byte limits, template grammar, duplicate IDs, and control characters that cannot be fully expressed by that schema.

The verification workflow is provided but has not been dispatched from this workspace. Building a package does not verify native shortcuts, tray behavior, screen readers, or clipboard support on another OS.
