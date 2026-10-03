#!/usr/bin/env bash
# Signs (and, when possible, notarizes) the built Spwrite.app, then zips it.
#
# Why: macOS blocks downloaded apps it cannot verify ("Apple could not verify
# 'Spwrite' is free of malware..."). An app passes that check only when it is
# signed with a Developer ID certificate, hardened, and notarized by Apple.
#
# Usage:
#   scripts/macos_sign.sh <path/to/Spwrite.app> <output.zip>
#
# Environment (all optional; without them the app is ad-hoc signed only, which
# still runs after "Open Anyway" but shows the warning on first launch):
#   MACOS_CERTIFICATE           base64 of the "Developer ID Application" .p12
#   MACOS_CERTIFICATE_PASSWORD  password of that .p12
#   APPLE_ID                    Apple ID e-mail used for notarization
#   APPLE_TEAM_ID               10-character Apple Developer Team ID
#   APPLE_APP_PASSWORD          app-specific password for that Apple ID
#   ENTITLEMENTS                entitlements plist (default: macos/Runner/Release.entitlements)
set -euo pipefail

APP="${1:?Usage: macos_sign.sh <Spwrite.app> <output.zip>}"
OUT="${2:?Usage: macos_sign.sh <Spwrite.app> <output.zip>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTITLEMENTS="${ENTITLEMENTS:-$SCRIPT_DIR/../macos/Runner/Release.entitlements}"

[ -d "$APP" ] || { echo "error: $APP not found" >&2; exit 1; }
[ -f "$ENTITLEMENTS" ] || { echo "error: $ENTITLEMENTS not found" >&2; exit 1; }
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac

log() { printf '==> %s\n' "$*"; }

# Signs every nested library and framework first (inside-out), then the app.
sign_all() {
  local identity="$1"; shift
  local flags=(--force --sign "$identity" "$@")
  while IFS= read -r -d '' lib; do
    codesign "${flags[@]}" "$lib"
  done < <(find "$APP/Contents" -type f \( -name '*.dylib' -o -name '*.so' \) -print0)
  if [ -d "$APP/Contents/Frameworks" ]; then
    while IFS= read -r -d '' fw; do
      codesign "${flags[@]}" "$fw"
    done < <(find "$APP/Contents/Frameworks" -maxdepth 1 -name '*.framework' -print0)
  fi
  codesign "${flags[@]}" --entitlements "$ENTITLEMENTS" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
}

zip_app() {
  rm -f "$OUT"
  # ditto keeps the bundle's structure, symlinks and permissions intact.
  ditto -c -k --keepParent "$APP" "$OUT"
}

if [ -z "${MACOS_CERTIFICATE:-}" ] || [ -z "${MACOS_CERTIFICATE_PASSWORD:-}" ]; then
  log "No Developer ID certificate set: ad-hoc signing only."
  echo "warning: the app is not notarized, so macOS will say it cannot verify" \
    "Spwrite is free of malware until the user chooses Open Anyway." >&2
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::warning::macOS app is not notarized. Add the MACOS_CERTIFICATE, MACOS_CERTIFICATE_PASSWORD, APPLE_ID, APPLE_TEAM_ID and APPLE_APP_PASSWORD secrets to sign and notarize it."
  fi
  sign_all -
  zip_app
  exit 0
fi

# --- Import the certificate into a throwaway keychain -----------------------
WORK="$(mktemp -d)"
KEYCHAIN="$WORK/signing.keychain-db"
KEYCHAIN_PASSWORD="$(uuidgen)"
cleanup() {
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

printf '%s' "$MACOS_CERTIFICATE" | base64 --decode >"$WORK/cert.p12"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "$MACOS_CERTIFICATE_PASSWORD" \
  -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
  -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
# Put the new keychain first in the search list so codesign finds the identity.
# shellcheck disable=SC2046
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')

IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" \
  | awk -F'"' '/Developer ID Application/ { print $2; exit }')"
[ -n "$IDENTITY" ] || { echo "error: no 'Developer ID Application' identity in the certificate" >&2; exit 1; }
log "Signing with: $IDENTITY"

# Hardened runtime + secure timestamp are required for notarization.
sign_all "$IDENTITY" --options runtime --timestamp

# --- Notarize and staple -------------------------------------------------------
if [ -z "${APPLE_ID:-}" ] || [ -z "${APPLE_TEAM_ID:-}" ] || [ -z "${APPLE_APP_PASSWORD:-}" ]; then
  echo "warning: signed but not notarized (APPLE_ID, APPLE_TEAM_ID or APPLE_APP_PASSWORD missing)." \
    "macOS still warns about downloaded apps that are not notarized." >&2
  [ -n "${GITHUB_ACTIONS:-}" ] && echo "::warning::macOS app is signed but not notarized."
  zip_app
  exit 0
fi

log "Submitting to Apple for notarization (this can take a few minutes)..."
ditto -c -k --keepParent "$APP" "$WORK/notarize.zip"
xcrun notarytool submit "$WORK/notarize.zip" \
  --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" \
  --wait --timeout 30m
# Staple the ticket so the app verifies even without a network connection.
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
log "Notarized."
zip_app
