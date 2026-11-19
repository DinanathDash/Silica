#!/bin/bash
# Build and run the local Release version of Silica (non-dev app: "Silica.app",
# bundle id com.hieudinh.Silica), installing it to /Applications and signing with
# your local Keychain identity.
#
# Usage:
#   scripts/run_release.sh
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME="Silica"
DERIVED="build.noindex/release"
PRODUCT="$DERIVED/Build/Products/Release/$APP_NAME.app"
TARGET="/Applications/$APP_NAME.app"

step() { printf '\n==> %s\n' "$1"; }

step "Building $APP_NAME (Release configuration)"
LOCAL_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -E 'Apple Development:|Mac Developer:' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' || true)

xcodebuild \
  -project Silica.xcodeproj \
  -scheme Silica \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  -skipPackagePluginValidation \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="-" \
  build 2>&1 | tail -n 5

step "Installing $APP_NAME to $TARGET"
rm -rf "$TARGET.old"
mv "$TARGET" "$TARGET.old" 2>/dev/null || true
ditto "$PRODUCT" "$TARGET"
rm -rf "$TARGET.old" 2>/dev/null || true

if [ -n "${LOCAL_IDENTITY:-}" ]; then
  printf 'Signing with local Keychain identity: %s\n' "$LOCAL_IDENTITY"
  codesign --force --deep --sign "$LOCAL_IDENTITY" "$TARGET"
  xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
elif codesign --verify --deep --strict "$TARGET" 2>/dev/null; then
  xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
else
  codesign --force --deep --sign - "$TARGET"
fi

step "Relaunching $APP_NAME"
osascript -e "with timeout of 10 seconds" -e "tell application \"$APP_NAME\" to quit" -e "end timeout" 2>/dev/null || true
sleep 1
open -a "$TARGET"
printf '\n%s is now running!\n' "$APP_NAME"
