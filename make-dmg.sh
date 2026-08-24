#!/bin/bash
set -euo pipefail

APP_NAME="Whisperino"
DMG_DIR="dist"
STAGING="$DMG_DIR/staging"
USE_EXISTING_BUNDLE=false

if [ "${1:-}" = "--from-bundle" ]; then
    USE_EXISTING_BUNDLE=true
elif [ "$#" -gt 0 ]; then
    echo "Usage: $0 [--from-bundle]" >&2
    exit 2
fi

echo "==> Building $APP_NAME DMG installer"
echo ""

# Build the app unless the release workflow already produced and verified the
# signed bundle. Rebuilding here would silently replace it with another build.
if [ "$USE_EXISTING_BUNDLE" = false ]; then
    echo "==> Step 1/2: Building $APP_NAME.app..."
    ./build.sh --bundle-only
else
    echo "==> Step 1/2: Using existing signed $APP_NAME.app..."
fi

if [ ! -d "build/$APP_NAME.app" ]; then
    echo "Missing build/$APP_NAME.app" >&2
    exit 1
fi

APP_VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "build/$APP_NAME.app/Contents/Info.plist")}"
DMG_NAME="$APP_NAME-v$APP_VERSION"

# Create DMG
echo ""
echo "==> Step 2/2: Creating DMG..."
rm -rf "$STAGING"
mkdir -p "$STAGING" "$DMG_DIR"

# Copy app to staging
ditto "build/$APP_NAME.app" "$STAGING/$APP_NAME.app"

# Create a symlink to /Applications for drag-and-drop install
ln -s /Applications "$STAGING/Applications"

# Create the DMG
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG_DIR/$DMG_NAME.dmg" 2>&1 | tail -3

# Clean up staging
rm -rf "$STAGING"

DMG_PATH="$DMG_DIR/$DMG_NAME.dmg"
DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1 | xargs)

echo ""
echo "==> Done!"
echo "    DMG: $DMG_PATH ($DMG_SIZE)"
echo ""
echo "    Share this file with your colleagues."
echo "    They open it, drag Whisperino to Applications, done."
echo ""
echo "    Speech models download in-app from Hugging Face"
echo "    the first time Whisperino launches."
