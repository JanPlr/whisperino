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

# Prevent Spotlight from indexing the build directory (avoid duplicate results)
touch "$BUILD_DIR/.metadata_never_index"

# Install to /Applications
echo "==> Installing to /Applications..."
pkill Whisperino 2>/dev/null || true
sleep 0.5
rm -rf "/Applications/$APP_NAME.app"
cp -R "$APP_BUNDLE" /Applications/

# Clear stale Accessibility entries — ad-hoc signing changes the CDHash
# on every build, leaving orphaned TCC records that confuse macOS
tccutil reset Accessibility com.whisperino.app 2>/dev/null || true

# Launch from /Applications so Accessibility permission is tied to the right app
echo "==> Launching $APP_NAME from /Applications..."
open /Applications/$APP_NAME.app

sleep 2

echo ""
echo "==> Build complete!"
echo ""
echo "  ⚠️  Grant Accessibility permission"
echo "  A system prompt should appear — click 'Open System Settings'"
echo "  then toggle Whisperino ON."
echo ""
echo "  If no prompt appeared, open System Settings manually:"
echo "  System Settings → Privacy & Security → Accessibility → Whisperino ON"
echo ""
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
