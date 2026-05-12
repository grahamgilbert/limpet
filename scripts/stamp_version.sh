#!/usr/bin/env bash
#
# Build phase: stamp the version from the repo's VERSION file into the
# built app bundle's Info.plist. Single source of truth.
#
# Runs after Xcode finishes copying Info.plist into Contents/, so we
# overwrite whatever the source plist had.

set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
VERSION_FILE="$PROJECT_DIR/VERSION"
INFO_PLIST="${INFOPLIST_PATH:?must be set by Xcode}"
BUILT_PLIST="$BUILT_PRODUCTS_DIR/$INFO_PLIST"

if [ ! -f "$VERSION_FILE" ]; then
    echo "warning: VERSION file not found at $VERSION_FILE; leaving Info.plist untouched"
    exit 0
fi
if [ ! -f "$BUILT_PLIST" ]; then
    echo "error: Info.plist not found at $BUILT_PLIST"
    exit 1
fi

VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
if [ -z "$VERSION" ]; then
    echo "error: VERSION file is empty"
    exit 1
fi

# Build number — git commit count is monotonic and works locally + in CI.
if BUILD_NUMBER="$(git -C "$PROJECT_DIR" rev-list --count HEAD 2>/dev/null)"; then
    :
else
    BUILD_NUMBER="1"
fi

/usr/libexec/PlistBuddy \
    -c "Set :CFBundleShortVersionString $VERSION" \
    -c "Set :CFBundleVersion $BUILD_NUMBER" \
    "$BUILT_PLIST"

echo "stamped: CFBundleShortVersionString=$VERSION CFBundleVersion=$BUILD_NUMBER"
