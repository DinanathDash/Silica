#!/bin/bash
# Builds and runs tests for Silica
#
# Usage:
#   scripts/test.sh [file_path]
#
# If no arguments provided, performs a fast check build of the Debug scheme.
# If a file path or test target is given, runs targeted validation.
set -euo pipefail

cd "$(dirname "$0")/.."
DERIVED="build.noindex/test"

step() { printf '\n==> %s\n' "$1"; }

TARGET_FILE="${1:-}"

if [ -n "$TARGET_FILE" ]; then
    step "Validating syntax of $TARGET_FILE"
    swiftc -parse "$TARGET_FILE"
fi

step "Building Silica (Debug check)"
xcodebuild \
  -project Silica.xcodeproj \
  -scheme Silica \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  -skipPackagePluginValidation \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="-" \
  build 2>&1 | tail -n 8

printf '\n✓ Build passed successfully!\n'
