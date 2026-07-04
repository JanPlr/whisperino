#!/bin/bash
# pipefail: `swift build | tail` must fail the script when the build fails
set -eo pipefail

APP_NAME="Whisperino"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

# --bundle-only: stop after creating build/Whisperino.app (used by CI)
BUNDLE_ONLY=false
[ "$1" = "--bundle-only" ] && BUNDLE_ONLY=true

# Version resolution, in priority order:
#   1. $VERSION env       — CI sets this from the pushed tag.
#   2. git describe       — a tagged checkout builds the exact tag.
#   3. committed Info.plist — the source of truth that ships in the repo, so
#      a ZIP download / shallow clone / worktree (where no git tag is
#      reachable) still reports a real version instead of 0.0.0.
# release.sh keeps (2) and (3) in lockstep, so they always agree.
# Stamped into the bundle's Info.plist below for the in-app update check.
if [ -z "$VERSION" ]; then
    # `|| true`: with no tags reachable, git describe fails — under set -e /
    # pipefail that would kill the script before the fallbacks below.
    VERSION=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)
fi
if [ -z "$VERSION" ]; then
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist 2>/dev/null || true)
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

# Code sign. Prefer a stable self-signed identity so TCC grants (Accessibility,
# Screen Recording) survive rebuilds - ad-hoc signing changes the CDHash every
# build, so macOS treats each build as a new app and drops the grants. Create
# the identity once with ./setup-signing.sh; until then we fall back to ad-hoc.
SIGN_IDENTITY="Whisperino Self-Signed"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    codesign --force --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
    STABLE_SIGNED=true
    echo "==> Signed with stable identity ($SIGN_IDENTITY) - permissions persist across builds"
else
    codesign --force --sign - "$APP_BUNDLE"
    STABLE_SIGNED=false
    echo "==> Ad-hoc signed - run ./setup-signing.sh once so permissions stop resetting"
fi

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

# Only reset TCC on ad-hoc builds. Ad-hoc signing changes the CDHash every
# build, orphaning the grants - resetting at least forces a clean re-grant. With
# the stable identity the grants persist, so resetting would just make the user
# re-approve needlessly.
if [ "$STABLE_SIGNED" = false ]; then
    tccutil reset Accessibility com.whisperino.app 2>/dev/null || true
    tccutil reset ScreenCapture com.whisperino.app 2>/dev/null || true
fi

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
echo "  ⚠️  Grant Screen Recording permission (for AI mode's screenshot)"
echo "  Toggle Whisperino ON, then relaunch the app for it to take effect."
echo "  System Settings → Privacy & Security → Screen Recording → Whisperino ON"
echo ""

# Open both permission panes so the user can grant them right away. Screen
# Recording is opened last (with a beat between) so it lands frontmost - it's
# the one that needs a manual toggle + app relaunch to take effect.
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
sleep 1
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
