#!/bin/bash
set -euo pipefail
REPO="${REPO:-joaoheusi/cue}"
[[ $# -eq 4 ]] || { sed -n 2,11p "$0"; exit 1; }
P12="$1" P8="$2" KEY_ID="$3" ISSUER="$4"
[[ -f "$P12" && -f "$P8" ]] || { echo "error: file not found" >&2; exit 1; }

read -r -s -p "Password of $P12: " P12_PASSWORD; echo
export P12_PASSWORD
SUBJECT=$( { openssl pkcs12 -in "$P12" -nokeys -passin env:P12_PASSWORD 2>/dev/null \
          || openssl pkcs12 -legacy -in "$P12" -nokeys -passin env:P12_PASSWORD 2>/dev/null; } | openssl x509 -noout -subject 2>/dev/null || true)
[[ "$SUBJECT" == *"Developer ID Application"* ]] || { echo "error: wrong password, or the file is not a Developer ID Application certificate" >&2; exit 1; }
grep -q "BEGIN PRIVATE KEY" "$P8" || { echo "error: $P8 is not an App Store Connect API key" >&2; exit 1; }

base64 < "$P12" | gh secret set DEVELOPER_ID_P12_BASE64 -R "$REPO"
printf '%s' "$P12_PASSWORD" | gh secret set DEVELOPER_ID_P12_PASSWORD -R "$REPO"
base64 < "$P8" | gh secret set APPLE_API_KEY_BASE64 -R "$REPO"
printf '%s' "$KEY_ID" | gh secret set APPLE_API_KEY_ID -R "$REPO"
printf '%s' "$ISSUER" | gh secret set APPLE_API_ISSUER_ID -R "$REPO"
echo "Release secrets are set for $REPO. SPARKLE_ED_PRIVATE_KEY was set separately."
gh secret list -R "$REPO"
