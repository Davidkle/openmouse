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
#   SPARKLE_FEED_URL, SPARKLE_PUBLIC_ED_KEY
#                      enable Sparkle updates (set by the release workflow; local
#                      builds leave them unset so they never update themselves).
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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks" "$APP/Contents/Library/LaunchAgents"
cp "$BIN" "$APP/Contents/MacOS/OpenMouse"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/OpenMouse"
SPARKLE=$(find .build -path "*/release/Sparkle.framework" -type d | head -1)
[ -n "$SPARKLE" ] || SPARKLE=$(find .build/artifacts -path "*/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" -type d | head -1)
[ -n "$SPARKLE" ] || { echo "Sparkle.framework not found in .build" >&2; exit 1; }
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
cp Resources/dev.openmouse.OpenMouse.agent.plist "$APP/Contents/Library/LaunchAgents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp THIRD_PARTY_NOTICES "$APP/Contents/Resources/"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
if [ -n "$SPARKLE_FEED_URL" ] && [ -n "$SPARKLE_PUBLIC_ED_KEY" ]; then
  for entry in "SUFeedURL string $SPARKLE_FEED_URL" "SUPublicEDKey string $SPARKLE_PUBLIC_ED_KEY" \
               "SUEnableInstallerLauncherService bool true" "SUEnableDownloaderService bool true"; do
    /usr/libexec/PlistBuddy -c "Add :$entry" "$APP/Contents/Info.plist"
  done
fi

if [ -z "$CODESIGN_IDENTITY" ]; then
  IDS=$(security find-identity -v -p codesigning 2>/dev/null || true)
  CODESIGN_IDENTITY=$(echo "$IDS" | grep '"Developer ID Application' | head -1 | sed -E 's/.*"(.*)"/\1/')
  [ -n "$CODESIGN_IDENTITY" ] || CODESIGN_IDENTITY=$(echo "$IDS" | grep '"Apple Development' | head -1 | sed -E 's/.*"(.*)"/\1/')
fi
case "$CODESIGN_IDENTITY" in
  "")
    echo "No signing identity found; signing ad-hoc"
    CODESIGN_IDENTITY=-
    SIGN_FLAGS="--force" ;;
  "Developer ID Application"*)
    echo "Signing for distribution with: $CODESIGN_IDENTITY"
    SIGN_FLAGS="--force --options runtime --timestamp" ;;
  *)
    echo "Signing with: $CODESIGN_IDENTITY"
    SIGN_FLAGS="--force" ;;
esac
# Apple's timestamp server sometimes times out; retry instead of failing.
sign() {
  for attempt in 1 2 3; do
    codesign $SIGN_FLAGS --sign "$CODESIGN_IDENTITY" "$@" && return 0
    echo "codesign failed (attempt $attempt), retrying" >&2
    sleep $((attempt * 5))
  done
  return 1
}
# Inside-out (no --deep): Sparkle's helpers keep their own entitlements, then
# the framework, then the app.
SPARKLE_CUR="$APP/Contents/Frameworks/Sparkle.framework/Versions/Current"
for item in "$SPARKLE_CUR/XPCServices/Downloader.xpc" "$SPARKLE_CUR/XPCServices/Installer.xpc" \
            "$SPARKLE_CUR/Autoupdate" "$SPARKLE_CUR/Updater.app"; do
  if [ -e "$item" ]; then sign --preserve-metadata=entitlements "$item"; fi
done
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign --entitlements Resources/OpenMouse.entitlements "$APP"
codesign --verify --strict --deep "$APP"
echo "Built $APP"

if [ "$1" = "--install" ]; then
  pkill -x OpenMouse 2>/dev/null && sleep 1 || true
  rm -rf /Applications/OpenMouse.app
  cp -R "$APP" /Applications/
  open /Applications/OpenMouse.app
  echo "Installed to /Applications/OpenMouse.app"
fi
