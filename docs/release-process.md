# Release process

Cue is a native macOS app (Swift 6, SwiftUI, AppKit). Releases are Developer ID signed. Public distribution also requires notarization.

1. Run `make test` (unit tests and the UI test). Run the manual checks in `docs/manual-test-checklist.md`.
2. Set `DEVELOPMENT_TEAM` and `APPLE_SIGNING_IDENTITY` in `.env`. Keep the same team and the `app.cue.launcher` bundle identifier for every release. A different team or an ad-hoc signature changes Cue's designated requirement. macOS then drops Accessibility access, and the legacy Keychain asks again for the clipboard-history key.
3. Run `make dmg`. It builds the Release app with a timestamped signature, verifies it with `codesign --verify --strict`, and creates `build/Cue.dmg` with an Applications link.
4. Notarize and staple:

   ```sh
   xcrun notarytool submit build/Cue.dmg --keychain-profile <profile> --wait
   xcrun stapler staple build/Cue.dmg
   ```

   Store notarization credentials with `xcrun notarytool store-credentials`. Never put them in the repository or in `.env.example`.
5. Exercise an upgrade from a previous library. Check that `backups/` contains a copy taken before any schema change. A failed migration must leave the existing database untouched.
6. Publish the DMG on the release page. If you use the opt-in update check, point `CUE_UPDATE_URL` at the GitHub "latest release" API for that repository. Cue only compares versions and opens the release page. It never downloads or installs anything.

Keep rollback copies as archives outside Applications. A renamed `.app` left in Applications can replace Cue's name in Accessibility settings.

Do not install ad-hoc development builds over the signed app. Their build-specific signature invalidates Accessibility access, even when System Settings still shows the switch on. To repair it, turn Cue off and on in Accessibility (or remove and re-add it), then quit and reopen Cue.

The prompt export format is versioned in `schemas/actions-v1.schema.json`. Runtime validation also enforces byte limits, template grammar, duplicate IDs, and control characters.
