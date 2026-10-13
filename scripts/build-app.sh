#!/bin/sh
# Builds build/OpenMouse.app.
#   scripts/build-app.sh            release build
#   scripts/build-app.sh --install  also copy to /Applications and launch
#
# Environment:
#   VERSION            marketing version (default 0.1.0)
#   UNIVERSAL=1        build arm64 + x86_64 (needs full Xcode)
#   CODESIGN_IDENTITY  signing identity. Defaults to the first "Developer ID
#                      Application" or "Apple Development" identity, else ad-hoc.
#
# A stable identity matters: macOS ties the Accessibility grant to the
# signature, so ad-hoc builds need re-granting after every rebuild. Developer ID
# builds get the hardened runtime and a secure timestamp, as notarization requires.
set -e
cd "$(dirname "$0")/.."

VERSION=${VERSION:-0.1.0}
BUILD=${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
APP=build/OpenMouse.app

if [ "$UNIVERSAL" = "1" ]; then
  ARCH_FLAGS="--arch arm64 --arch x86_64"
fi
swift build -c release $ARCH_FLAGS
BIN=$(swift build -c release $ARCH_FLAGS --show-bin-path)/OpenMouse

[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift .

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OpenMouse"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp THIRD_PARTY_NOTICES "$APP/Contents/Resources/"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"

if [ -z "$CODESIGN_IDENTITY" ]; then
  IDS=$(security find-identity -v -p codesigning 2>/dev/null || true)
  CODESIGN_IDENTITY=$(echo "$IDS" | grep '"Developer ID Application' | head -1 | sed -E 's/.*"(.*)"/\1/')
  [ -n "$CODESIGN_IDENTITY" ] || CODESIGN_IDENTITY=$(echo "$IDS" | grep '"Apple Development' | head -1 | sed -E 's/.*"(.*)"/\1/')
fi
case "$CODESIGN_IDENTITY" in
  "")
    echo "No signing identity found; signing ad-hoc"
    codesign --force --sign - "$APP" ;;
  "Developer ID Application"*)
    echo "Signing for distribution with: $CODESIGN_IDENTITY"
    codesign --force --options runtime --timestamp \
      --entitlements Resources/OpenMouse.entitlements --sign "$CODESIGN_IDENTITY" "$APP" ;;
  *)
    echo "Signing with: $CODESIGN_IDENTITY"
    codesign --force --entitlements Resources/OpenMouse.entitlements --sign "$CODESIGN_IDENTITY" "$APP" ;;
esac
codesign --verify --strict "$APP"
echo "Built $APP"

if [ "$1" = "--install" ]; then
  pkill -x OpenMouse 2>/dev/null && sleep 1 || true
  rm -rf /Applications/OpenMouse.app
  cp -R "$APP" /Applications/
  open /Applications/OpenMouse.app
  echo "Installed to /Applications/OpenMouse.app"
fi
