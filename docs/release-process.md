# Release process

Releases are automatic. Every push to `main` that passes CI becomes a GitHub release that installed copies of Cue download and install through Sparkle.

## One-time setup

Done on October 22, 2026: all six repository secrets are set. The notarization key is App Store Connect team key "Cue CI" (`53MZL42XUM`, Developer role); its only copy is `~/.appstoreconnect/private_keys/AuthKey_53MZL42XUM.p8`. Repeat the steps below only to rotate credentials.

1. `SPARKLE_ED_PRIVATE_KEY` is already a repository secret. The same key is in your login Keychain under the Sparkle account `cue`. Back it up (`generate_keys --account cue -x <file>` from Sparkle's `bin/`, then store the file somewhere safe). If it is lost, installed copies can never accept another update.
2. Export your **Developer ID Application** certificate with its private key from Keychain Access as a `.p12` with a password. Export only that one item.
3. Create an **App Store Connect API key** (Users and Access → Integrations → Team Keys, role Developer). Download the `.p8` and note the key ID and issuer ID.
4. Run `scripts/setup-release-secrets.sh <cert.p12> <AuthKey.p8> <key-id> <issuer-id>`. It checks the files and sets `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`, `APPLE_API_KEY_BASE64`, `APPLE_API_KEY_ID`, and `APPLE_API_ISSUER_ID`. Delete the exported `.p12` afterwards.

Your Developer ID certificates expire on February 1, 2027. Renew before then and rerun step 4. Renewal keeps the same team, so Cue's designated requirement and Accessibility access do not change. Releases signed before expiry stay valid because they are timestamped.

## What a release does

`scripts/release.sh` (run by CI, or locally with `make dmg`):

1. Builds Release with version `0.2.<commit count>` and build number `<commit count>`. The commit count only grows on `main`, so Sparkle always sees a newer build.
2. Signs Sparkle's helpers, the framework, and the app with Developer ID, hardened runtime, and a timestamp.
3. Refuses to continue unless the app is signed by team `SC7RQ3BWQ6` with a Developer ID designated requirement (not a build-specific hash). An ad-hoc or differently signed update would drop Accessibility access and re-prompt for the clipboard Keychain key on every install.
4. Creates `Cue.dmg` with an Applications link, signs it, notarizes it, staples the ticket, and checks it with `spctl`.
5. Signs the DMG with the Sparkle EdDSA key and writes `appcast.xml` pointing at `releases/download/v<version>/Cue.dmg`.

CI then publishes release `v<version>` with both files. The app's feed URL is `releases/latest/download/appcast.xml`, which always redirects to the newest release. Do not mark releases as drafts or prereleases: `latest` skips them and installed copies would not see them.

## Local release

Set `DEVELOPMENT_TEAM`, `APPLE_SIGNING_IDENTITY` (use the SHA-1 fingerprint if you have several Developer ID certificates), and `NOTARY_KEYCHAIN_PROFILE` in `.env`, then run `make dmg`. It produces the same files in `build/release/` but does not publish them.

## Rules

- Keep the bundle identifier `app.cue.launcher` and team `SC7RQ3BWQ6` for every release.
- Never force-push `main`: the build number would go backwards and Sparkle would ignore new releases until the count passes the old one.
- Do not install ad-hoc development builds over the signed app. Their signature invalidates Accessibility access. To repair it, turn Cue off and on in Accessibility, then quit and reopen Cue.
- The prompt export format is versioned in `schemas/actions-v1.schema.json`.
