#!/bin/sh
# Builds a Developer ID-signed Release of the app and zips it.
#
#   Tools/release.sh                       build + zip  (.build/release/Blood-Pressure-<version>.zip)
#   NOTARY_PROFILE=name Tools/release.sh   also notarize and staple; the profile comes from
#                                          `xcrun notarytool store-credentials name ...`
#   INSTALL=1 Tools/release.sh             also install to /Applications (quits a running copy first)
set -eu
cd "$(dirname "$0")/.."

xcodegen generate --quiet
xcodebuild -project BPTracker.xcodeproj -scheme BPTracker -configuration Release \
  -destination 'platform=macOS' -derivedDataPath .build/release build -quiet

APP=".build/release/Build/Products/Release/Blood Pressure.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
ZIP=".build/release/Blood-Pressure-$VERSION.zip"

codesign --verify --strict --deep "$APP"
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow; then
  echo "release: build has the get-task-allow entitlement, which notarization rejects" >&2; exit 1
fi
codesign -dv "$APP" 2>&1 | grep -E 'Authority=Developer ID Application|Timestamp=' >/dev/null \
  || { echo "release: not signed with Developer ID and a secure timestamp" >&2; exit 1; }

# Universal binary with the expected minimum macOS (see ambiotica-plugin's PLUGIN-RELEASE-PITFALLS #1-2).
BIN="$APP/Contents/MacOS/Blood Pressure"
[ "$(lipo -archs "$BIN")" = "x86_64 arm64" ] || { echo "release: expected x86_64 arm64, got $(lipo -archs "$BIN")" >&2; exit 1; }
for arch in x86_64 arm64; do
  minos=$(otool -l -arch "$arch" "$BIN" | grep -A3 LC_BUILD_VERSION | awk '/minos/ {print $2}')
  [ "$minos" = "14.0" ] || { echo "release: $arch minimum macOS is $minos, expected 14.0" >&2; exit 1; }
done

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
fi
echo "built $ZIP"

if [ "${INSTALL:-0}" = 1 ]; then
  osascript -e 'tell application id "com.charlesvestal.BPTracker" to quit' 2>/dev/null || true
  pkill -f "Blood Pressure.app/Contents/MacOS/Blood Pressure" 2>/dev/null || true
  sleep 1
  rm -rf "/Applications/Blood Pressure.app"
  ditto "$APP" "/Applications/Blood Pressure.app"
  echo "installed /Applications/Blood Pressure.app"
fi
