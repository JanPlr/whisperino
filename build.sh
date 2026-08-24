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

# Prevent Spotlight from indexing the build directory (avoid duplicate
# results). Must exist BEFORE the .app bundle is created - Spotlight indexes
# new bundles within seconds, and a stale entry keeps showing up in search.
mkdir -p "$BUILD_DIR"
touch "$BUILD_DIR/.metadata_never_index"

# Build with Swift Package Manager
swift build -c release 2>&1 | tail -5

# Create .app bundle
echo "==> Creating $APP_NAME.app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp .build/release/Whisperino "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Embed transcribe.cpp's Metal framework. The binary loads it via @rpath;
# @loader_path only covers Contents/MacOS, so add the standard Frameworks slot.
FRAMEWORK_SRC=".build/release/CTranscribe.framework"
if [ ! -d "$FRAMEWORK_SRC" ]; then
    echo "Error: $FRAMEWORK_SRC missing after swift build" >&2
    exit 1
fi
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
ditto "$FRAMEWORK_SRC" "$APP_BUNDLE/Contents/Frameworks/CTranscribe.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Embed the MediaRemote adapter and its entitled-host script. SwiftPM builds
# the dynamic product as a dylib (not an Xcode .framework), so copy it into the
# rpath directly and give the app a stable resource path for the Perl helper.
MEDIA_REMOTE_DYLIB_SRC=".build/release/libMediaRemoteAdapter.dylib"
MEDIA_REMOTE_SCRIPT_SRC=".build/release/MediaRemoteAdapter_MediaRemoteAdapter.bundle/run.pl"
if [ ! -f "$MEDIA_REMOTE_DYLIB_SRC" ] || [ ! -f "$MEDIA_REMOTE_SCRIPT_SRC" ]; then
    echo "Error: MediaRemote adapter build products are missing" >&2
    exit 1
fi
cp "$MEDIA_REMOTE_DYLIB_SRC" "$APP_BUNDLE/Contents/Frameworks/"
cp "$MEDIA_REMOTE_SCRIPT_SRC" "$APP_BUNDLE/Contents/Resources/mediaremote-adapter.pl"

# Copy Info.plist and icon, stamp the version
cp Info.plist "$APP_BUNDLE/Contents/"
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleShortVersionString $VERSION" \
    -c "Set :CFBundleVersion $VERSION" \
    "$APP_BUNDLE/Contents/Info.plist"
cp AppIcon.icns "$APP_BUNDLE/Contents/Resources/"

# Code sign ad-hoc for local/source builds. Never select a keychain identity
# implicitly: doing that can display a surprising password prompt during a
# normal install. Maintainers can opt in to an existing identity explicitly,
# for example WHISPERINO_SIGN_IDENTITY="Developer ID Application: ...".
SIGN_IDENTITY="${WHISPERINO_SIGN_IDENTITY:--}"
if [ "$SIGN_IDENTITY" != "-" ]; then
    if ! security find-identity -v -p codesigning 2>/dev/null | grep -Fq "$SIGN_IDENTITY"; then
        echo "Error: Requested code-signing identity was not found: $SIGN_IDENTITY" >&2
        exit 1
    fi
    codesign --force --sign "$SIGN_IDENTITY" "$APP_BUNDLE/Contents/Frameworks/CTranscribe.framework"
    codesign --force --sign "$SIGN_IDENTITY" "$APP_BUNDLE/Contents/Frameworks/libMediaRemoteAdapter.dylib"
    codesign --force --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
    echo "==> Signed with requested identity ($SIGN_IDENTITY)"
else
    codesign --force --sign - "$APP_BUNDLE/Contents/Frameworks/CTranscribe.framework"
    codesign --force --sign - "$APP_BUNDLE/Contents/Frameworks/libMediaRemoteAdapter.dylib"
    codesign --force --sign - "$APP_BUNDLE"
    echo "==> Ad-hoc signed"
fi

# TCC keys privacy grants to the app's designated requirement (DR), not just
# its bundle identifier or the row displayed in System Settings. If the actual
# identity changes, reset the stale row so macOS can grant the new build.
designated_requirement() {
    codesign -dr - "$1" 2>&1 \
        | sed -n 's/^.*designated => //p' \
        | tail -1
}

NEW_DESIGNATED_REQUIREMENT=$(designated_requirement "$APP_BUNDLE")
if [ -z "$NEW_DESIGNATED_REQUIREMENT" ]; then
    echo "Error: Could not read the new app's designated requirement" >&2
    exit 1
fi

if [ "$BUNDLE_ONLY" = true ]; then
    echo "==> Bundle ready: $APP_BUNDLE (v$VERSION)"
    exit 0
fi

INSTALLED_APP="/Applications/$APP_NAME.app"
INSTALL_STAGING="/Applications/.$APP_NAME.app.installing"
INSTALL_BACKUP="/Applications/.$APP_NAME.app.previous"

# Recover a previous interrupted activation before evaluating identity. If a
# healthy installed bundle already exists, the hidden backup is stale.
rm -rf "$INSTALL_STAGING"
if [ -d "$INSTALL_BACKUP" ]; then
    if [ -d "$INSTALLED_APP" ]; then
        rm -rf "$INSTALL_BACKUP"
    else
        echo "==> Recovering previous Whisperino installation"
        mv "$INSTALL_BACKUP" "$INSTALLED_APP"
    fi
fi

OLD_DESIGNATED_REQUIREMENT=""
if [ -d "$INSTALLED_APP" ]; then
    OLD_DESIGNATED_REQUIREMENT=$(designated_requirement "$INSTALLED_APP")
fi

TCC_RESET_REQUIRED=false
if [ "$OLD_DESIGNATED_REQUIREMENT" != "$NEW_DESIGNATED_REQUIREMENT" ]; then
    TCC_RESET_REQUIRED=true
fi

# Install to /Applications
echo "==> Installing to /Applications..."
pkill Whisperino 2>/dev/null || true
sleep 0.5

# Copy and verify under a hidden staging name before touching the working app.
# If the final rename fails, restore the previous bundle so an interrupted
# update never leaves the user with no runnable Whisperino installation.
if ! ditto "$APP_BUNDLE" "$INSTALL_STAGING"; then
    rm -rf "$INSTALL_STAGING"
    echo "Error: Could not stage the new app; the existing install was not changed" >&2
    exit 1
fi

# Fail before launch if copying changed or invalidated the signature. This also
# makes it impossible to grant TCC access to a bundle different from the one we
# just inspected above.
if ! codesign --verify --strict --verbose=2 "$INSTALL_STAGING"; then
    rm -rf "$INSTALL_STAGING"
    echo "Error: Staged app failed code-signature verification; the existing install was not changed" >&2
    exit 1
fi
INSTALLED_DESIGNATED_REQUIREMENT=$(designated_requirement "$INSTALL_STAGING")
if [ "$INSTALLED_DESIGNATED_REQUIREMENT" != "$NEW_DESIGNATED_REQUIREMENT" ]; then
    rm -rf "$INSTALL_STAGING"
    echo "Error: Installed app's code identity differs from the built app" >&2
    exit 1
fi

if [ -d "$INSTALLED_APP" ]; then
    if ! mv "$INSTALLED_APP" "$INSTALL_BACKUP"; then
        rm -rf "$INSTALL_STAGING"
        echo "Error: Could not back up the existing app; it was not changed" >&2
        exit 1
    fi
fi
if ! mv "$INSTALL_STAGING" "$INSTALLED_APP"; then
    if [ -d "$INSTALL_BACKUP" ]; then
        if mv "$INSTALL_BACKUP" "$INSTALLED_APP"; then
            echo "Error: Could not activate the new app; the previous install was restored" >&2
        else
            echo "Error: Could not activate or restore the app; the previous bundle remains at $INSTALL_BACKUP" >&2
        fi
    else
        echo "Error: Could not activate the new app" >&2
    fi
    exit 1
fi
rm -rf "$INSTALL_BACKUP"

# Remove the local bundle copy - it's fully installed now, and leaving a
# second Whisperino.app on disk creates duplicate Spotlight/Launchpad entries
# that launch a conflicting second instance.
rm -rf "$APP_BUNDLE"

# Reset only when the actual designated requirement changed. This catches
# ad-hoc rebuilds, ad-hoc → self-signed migration, a replaced certificate, and
# the reverse transition, while preserving grants across true stable rebuilds.
if [ "$TCC_RESET_REQUIRED" = true ]; then
    echo "==> Code identity changed - resetting stale privacy grants"
    tccutil reset Accessibility com.whisperino.app 2>/dev/null || true
    tccutil reset ScreenCapture com.whisperino.app 2>/dev/null || true
else
    echo "==> Code identity unchanged - preserving privacy grants"
fi

# Launch from /Applications so Accessibility permission is tied to the right app
echo "==> Launching $APP_NAME from /Applications..."
open /Applications/$APP_NAME.app

sleep 2

echo ""
echo "==> Build complete!"
echo ""
if [ "$TCC_RESET_REQUIRED" = true ]; then
    echo "  ⚠️  The app's code identity changed."
    echo "  Grant Accessibility to /Applications/Whisperino.app,"
    echo "  then quit and reopen Whisperino once."
    echo ""
    echo "  If no prompt appeared, open System Settings manually:"
    echo "  System Settings → Privacy & Security → Accessibility → Whisperino ON"
else
    echo "  ✓ Code identity is stable; existing privacy grants were preserved."
fi
echo ""
echo "  (Screen Recording is requested on-demand the first time you start"
echo "   Talk to your screen - no need to grant it here.)"
echo ""

# The app sequences its own microphone and Accessibility prompts. Opening
# System Settings here used to race those prompts on a fresh install.
