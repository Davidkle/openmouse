#!/bin/sh
# Notarizes and packages build/OpenMouse.app (run scripts/build-app.sh first,
# signed with a Developer ID identity).
#
# Produces build/OpenMouse-$VERSION.dmg and build/OpenMouse-$VERSION.zip, both
# notarized and stapled, plus .sha256 files.
#
# Notary credentials (App Store Connect API key):
#   NOTARY_KEY_FILE  path to AuthKey_XXXX.p8
#   NOTARY_KEY_ID    key ID
#   NOTARY_ISSUER_ID issuer ID
# Set SKIP_NOTARIZE=1 to only package.
set -e
cd "$(dirname "$0")/.."

VERSION=${VERSION:-0.1.0}
APP=build/OpenMouse.app
DMG=build/OpenMouse-$VERSION.dmg
ZIP=build/OpenMouse-$VERSION.zip

notarize() {
  [ "$SKIP_NOTARIZE" = "1" ] && return 0
  : "${NOTARY_KEY_FILE:?set NOTARY_KEY_FILE}" "${NOTARY_KEY_ID:?set NOTARY_KEY_ID}" "${NOTARY_ISSUER_ID:?set NOTARY_ISSUER_ID}"
  xcrun notarytool submit "$1" --key "$NOTARY_KEY_FILE" --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER_ID" --wait --timeout 30m --output-format json > build/notary.json
  cat build/notary.json
  if ! grep -q '"status" *: *"Accepted"' build/notary.json; then
    ID=$(sed -nE 's/.*"id" *: *"([^"]+)".*/\1/p' build/notary.json | head -1)
    [ -n "$ID" ] && xcrun notarytool log "$ID" --key "$NOTARY_KEY_FILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" || true
    echo "Notarization failed" >&2
    exit 1
  fi
}

# Fetching the ticket from Apple's CDN sometimes drops the connection, and a
# freshly issued ticket can take a moment to propagate, so retry.
staple() {
  [ "$SKIP_NOTARIZE" = "1" ] && return 0
  for attempt in 1 2 3 4 5; do
    xcrun stapler staple "$1" && return 0
    echo "Stapling $1 failed (attempt $attempt), retrying in $((attempt * 10))s" >&2
    sleep $((attempt * 10))
  done
  return 1
}

# 1. Notarize the app itself and staple it, so the ZIP works offline too.
rm -f build/OpenMouse-notarize.zip
ditto -c -k --keepParent "$APP" build/OpenMouse-notarize.zip
notarize build/OpenMouse-notarize.zip
staple "$APP"
rm -f build/OpenMouse-notarize.zip

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# 2. DMG with an Applications shortcut, signed, notarized and stapled.
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "OpenMouse" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
if [ -n "$CODESIGN_IDENTITY" ]; then
  codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG"
fi
notarize "$DMG"
staple "$DMG"

(cd build && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
[ "$SKIP_NOTARIZE" = "1" ] || spctl --assess --type execute --verbose "$APP"
echo "Packaged $DMG and $ZIP"
