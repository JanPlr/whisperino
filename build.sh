#!/bin/bash
set -e

APP_NAME="Whisperino"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "==> Building $APP_NAME..."

# Check Swift version (need 5.9+ for swift-tools-version: 5.9)
SWIFT_VER=$(swift --version 2>&1 | grep -oE 'Swift version [0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+')
SWIFT_MAJOR=$(echo "$SWIFT_VER" | cut -d. -f1)
SWIFT_MINOR=$(echo "$SWIFT_VER" | cut -d. -f2)
if [ -z "$SWIFT_VER" ] || [ "$SWIFT_MAJOR" -lt 5 ] || { [ "$SWIFT_MAJOR" -eq 5 ] && [ "$SWIFT_MINOR" -lt 9 ]; }; then
    echo ""
    echo "  ✗ Swift 5.9+ is required (found: ${SWIFT_VER:-none})"
    echo "    Update Xcode Command Line Tools:"
    echo "    sudo rm -rf /Library/Developer/CommandLineTools"
    echo "    xcode-select --install"
    echo ""
    exit 1
fi

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

# Install to /Applications
echo "==> Installing to /Applications..."
pkill Whisperino 2>/dev/null || true
sleep 0.5
rm -rf "/Applications/$APP_NAME.app"
cp -R "$APP_BUNDLE" /Applications/

echo ""
echo "==> Build complete! Installed to /Applications/$APP_NAME.app"
echo ""
echo "  ⚠️  Re-grant Accessibility permission"
echo "  Each rebuild changes the code signature, so macOS"
echo "  revokes Accessibility. Toggle Whisperino OFF then ON"
echo "  in the System Settings window that just opened."
echo ""
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

echo "  Then launch:  open /Applications/$APP_NAME.app"
echo "  Or find Whisperino in Spotlight."
echo ""
