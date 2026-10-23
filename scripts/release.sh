#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "error: $*" >&2; exit 1; }

[[ -n "${DEVELOPMENT_TEAM:-}" ]] || fail "DEVELOPMENT_TEAM is required. Unsigned updates would drop Accessibility access on every install."
IDENTITY="${APPLE_SIGNING_IDENTITY:-Developer ID Application}"
if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  NOTARY=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
elif [[ -n "${APPLE_API_KEY_PATH:-}" && -n "${APPLE_API_KEY_ID:-}" && -n "${APPLE_API_ISSUER_ID:-}" ]]; then
  NOTARY=(--key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID")
else
  fail "Set NOTARY_KEYCHAIN_PROFILE, or APPLE_API_KEY_PATH, APPLE_API_KEY_ID, and APPLE_API_ISSUER_ID."
fi

BUILD="${BUILD:-$(git rev-list --count HEAD)}"
VERSION="${VERSION:-0.2.$BUILD}"
REPO_URL="${RELEASE_URL_BASE:-https://github.com/joaoheusi/cue/releases/download}"
DERIVED=build/DerivedData-release
OUT=build/release
APP="$DERIVED/Build/Products/Release/Cue.app"
rm -rf "$OUT" && mkdir -p "$OUT"

echo "==> Building Cue $VERSION ($BUILD)"
rm -rf "$DERIVED/Build/Products/Release"
if ! xcodebuild -project Cue.xcodeproj -scheme Cue -configuration Release -derivedDataPath "$DERIVED" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" \
  OTHER_CODE_SIGN_FLAGS=--timestamp build > "$OUT/build.log" 2>&1; then
  grep -E "error:" "$OUT/build.log" | head -20 >&2
  fail "Build failed. See $OUT/build.log."
fi

echo "==> Signing Sparkle helpers and the app with hardened runtime"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign() { codesign --force --options runtime --timestamp --sign "$IDENTITY" "$@"; }
sign "$SPARKLE/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
sign "$SPARKLE/Autoupdate"
sign "$SPARKLE/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign "$APP"

codesign --verify --strict --deep "$APP"
DETAILS=$(codesign -dvv "$APP" 2>&1)
REQUIREMENT=$(codesign -d -r- "$APP" 2>&1)
grep -q "^TeamIdentifier=$DEVELOPMENT_TEAM$" <<<"$DETAILS" || fail "App is not signed by team $DEVELOPMENT_TEAM."
grep -q "Authority=Developer ID Application:" <<<"$DETAILS" || fail "App is not signed with a Developer ID Application certificate."
grep -q "anchor apple generic" <<<"$REQUIREMENT" && ! grep -q cdhash <<<"$REQUIREMENT" || fail "Designated requirement is build-specific; updates would lose Accessibility access."

echo "==> Creating the disk image"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname Cue -srcfolder "$STAGE" -ov -format UDZO "$OUT/Cue.dmg"
rm -rf "$STAGE"
sign "$OUT/Cue.dmg"

echo "==> Notarizing (this can take a few minutes)"
xcrun notarytool submit "$OUT/Cue.dmg" "${NOTARY[@]}" --wait --timeout 30m | tee "$OUT/notarization.log"
grep -q "status: Accepted" "$OUT/notarization.log" || fail "Notarization was not accepted. See $OUT/notarization.log."
xcrun stapler staple "$OUT/Cue.dmg"
spctl --assess --type open --context context:primary-signature --verbose "$OUT/Cue.dmg"

echo "==> Signing the update for Sparkle"
SIGN_UPDATE=$(find build -path "*artifacts/sparkle/Sparkle/bin/sign_update" -not -path "*/old_dsa_scripts/*" | head -1)
[[ -x "$SIGN_UPDATE" ]] || fail "Sparkle's sign_update was not found. Resolve packages first."
if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
  ATTRIBUTES=$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - "$OUT/Cue.dmg")
else
  ATTRIBUTES=$("$SIGN_UPDATE" --account cue "$OUT/Cue.dmg")
fi
[[ "$ATTRIBUTES" == *'sparkle:edSignature="'* && "$ATTRIBUTES" == *'length="'* ]] || fail "sign_update did not return a signature."

cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Cue</title>
    <item>
      <title>Cue $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="$REPO_URL/v$VERSION/Cue.dmg" type="application/octet-stream" $ATTRIBUTES/>
    </item>
  </channel>
</rss>
XML
echo "$VERSION" > "$OUT/version"
echo "==> Done: $OUT/Cue.dmg and $OUT/appcast.xml for Cue $VERSION ($BUILD)"
