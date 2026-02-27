#!/bin/bash
set -e

APP_NAME="WhisperFlow"
DMG_NAME="WhisperFlow-Installer"
DMG_DIR="dist"
STAGING="$DMG_DIR/staging"

echo "==> Building $APP_NAME DMG installer"
echo ""

# Step 1: Run setup if needed
if [ ! -f "$HOME/.whisper-flow/bin/whisper-cli" ] || [ ! -f "$HOME/.whisper-flow/models/ggml-small.bin" ]; then
    echo "==> Step 1/3: Setting up whisper.cpp + model..."
    ./setup.sh
else
    echo "==> Step 1/3: whisper.cpp already set up, skipping"
fi

# Step 2: Build the app
echo ""
echo "==> Step 2/3: Building $APP_NAME.app..."
./build.sh

# Step 3: Create DMG
echo ""
echo "==> Step 3/3: Creating DMG..."
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
echo "    They open it, drag WhisperFlow to Applications, done."
echo ""
echo "    NOTE: Recipients also need whisper.cpp installed locally."
echo "    They should run setup.sh first, or use install.sh for a"
echo "    full automated install from source."
