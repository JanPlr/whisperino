#!/bin/bash
set -e

APP_NAME="Whisperino"
DMG_NAME="Whisperino-Installer"
DMG_DIR="dist"
STAGING="$DMG_DIR/staging"

echo "==> Building $APP_NAME DMG installer"
echo ""

# Build the app
echo "==> Step 1/2: Building $APP_NAME.app..."
./build.sh --bundle-only

# Create DMG
echo ""
echo "==> Step 2/2: Creating DMG..."
rm -rf "$DMG_DIR"
mkdir -p "$STAGING"

# Copy app to staging
cp -R "build/$APP_NAME.app" "$STAGING/"

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
