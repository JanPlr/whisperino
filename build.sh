#!/bin/bash
# pipefail: `swift build | tail` must fail the script when the build fails
set -eo pipefail

APP_NAME="Whisperino"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

# --bundle-only: stop after creating build/Whisperino.app (used by CI)
BUNDLE_ONLY=false
[ "$1" = "--bundle-only" ] && BUNDLE_ONLY=true

# Version: $VERSION env wins (CI sets it from the tag), else nearest git tag,
# else a dev placeholder. Stamped into the bundle's Info.plist below so the
# in-app update check can compare against GitHub releases.
if [ -z "$VERSION" ]; then
    # `|| true`: with no tags yet, git describe fails - under set -e /
    # pipefail that would kill the script before the fallback below.
    VERSION=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)
fi
VERSION="${VERSION:-0.0.0}"

echo "==> Building $APP_NAME v$VERSION..."

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

# Copy Info.plist and icon, stamp the version
cp Info.plist "$APP_BUNDLE/Contents/"
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleShortVersionString $VERSION" \
    -c "Set :CFBundleVersion $VERSION" \
    "$APP_BUNDLE/Contents/Info.plist"
cp AppIcon.icns "$APP_BUNDLE/Contents/Resources/"

# Ad-hoc code sign (required for microphone access)
codesign --force --sign - "$APP_BUNDLE"

# Prevent Spotlight from indexing the build directory (avoid duplicate results)
touch "$BUILD_DIR/.metadata_never_index"

if [ "$BUNDLE_ONLY" = true ]; then
    echo "==> Bundle ready: $APP_BUNDLE (v$VERSION)"
    exit 0
fi

# Install to /Applications
echo "==> Installing to /Applications..."
pkill Whisperino 2>/dev/null || true
sleep 0.5
rm -rf "/Applications/$APP_NAME.app"
cp -R "$APP_BUNDLE" /Applications/

# Clear stale Accessibility entries - ad-hoc signing changes the CDHash
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
echo "  A system prompt should appear - click 'Open System Settings'"
echo "  then toggle Whisperino ON."
echo ""
echo "  If no prompt appeared, open System Settings manually:"
echo "  System Settings → Privacy & Security → Accessibility → Whisperino ON"
echo ""
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
