#!/bin/bash
# Dev loop for Silica: build Debug ("Silica Dev.app"), install it as the single
# /Applications copy of the dev app, and relaunch it.
#
#   scripts/quick_run.sh
#
# A Debug build is "Silica Dev" (bundle id com.hieudinh.Silica.dev): it runs
# beside the released Silica app with its own settings and never touches
# the release app's preferences.
#
# Builds under build.noindex/dev (never DerivedData),
# because the ".noindex" suffix keeps Spotlight and Launchpad from listing
# the build folder as a second copy of the app. There must only ever be one
# dev app: /Applications/Silica Dev.app.
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME="Silica Dev"
DERIVED="build.noindex/dev"
PRODUCT="$DERIVED/Build/Products/Debug/$APP_NAME.app"
TARGET="/Applications/$APP_NAME.app"

step() { printf '\n==> %s\n' "$1"; }

step "Building $APP_NAME (Debug)"

# Detect local codesigning identity from Keychain if present
LOCAL_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -E 'Apple Development:|Mac Developer:' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' || true)

xcodebuild \
  -project Silica.xcodeproj \
  -scheme Silica \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  -skipPackagePluginValidation \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="-" \
  build 2>&1 | tail -n 5

step "Installing $APP_NAME to $TARGET"
# Atomic swap: move running bundle aside so ditto installs the fresh build immediately
rm -rf "$TARGET.old"
mv "$TARGET" "$TARGET.old" 2>/dev/null || true
ditto "$PRODUCT" "$TARGET"
rm -rf "$TARGET.old" 2>/dev/null || true

# macOS TCC ties granted permissions to the app's signed identity. Use the local
# Keychain identity if found, so permissions persist across runs.
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
