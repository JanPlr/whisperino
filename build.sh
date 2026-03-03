#!/bin/bash
set -e

APP_NAME="Whisperino"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "==> Building $APP_NAME..."

# Build with Swift Package Manager
swift build -c release 2>&1 | tail -5

# Create .app bundle
echo "==> Creating $APP_NAME.app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp .build/release/Whisperino "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy Info.plist and icon
cp Info.plist "$APP_BUNDLE/Contents/"
cp AppIcon.icns "$APP_BUNDLE/Contents/Resources/"

# Ad-hoc code sign (required for microphone access)
codesign --force --sign - "$APP_BUNDLE"

echo ""
echo "==> Build complete!"
echo "    App: $APP_BUNDLE"
echo ""
echo "  ⚠️  IMPORTANT: Re-grant Accessibility permission"
echo "  Each rebuild changes the code signature, which causes"
echo "  macOS to revoke Accessibility. Without it, text insertion"
echo "  silently does nothing."
echo ""
echo "  Opening System Settings → Accessibility now..."
echo "  Find Whisperino and toggle it OFF then back ON."
echo ""
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

echo "    Run with:  open $APP_BUNDLE"
echo "    Or:        $APP_BUNDLE/Contents/MacOS/$APP_NAME"
echo ""
echo "    Shortcut:  Option+D to toggle recording"
