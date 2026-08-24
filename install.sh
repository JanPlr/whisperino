#!/bin/bash
set -e

echo ""
echo "  ╦ ╦┬ ┬┬┌─┐┌─┐┌─┐┬─┐┬┌┐┌┌─┐"
echo "  ║║║├─┤│└─┐├─┘├┤ ├┬┘│││││ │"
echo "  ╚╩╝┴ ┴┴└─┘┴  └─┘┴└─┴┘└┘└─┘"
echo ""
echo "  Local voice transcription for macOS"
echo ""

# Check for Xcode Command Line Tools
if ! xcode-select -p &>/dev/null; then
    echo "[1/3] Installing Xcode Command Line Tools..."
    xcode-select --install
    echo ""
    echo "  Please re-run this script after installation completes."
    exit 1
fi

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
echo "[1/3] Xcode Command Line Tools: OK (Swift $SWIFT_VER)"

# Create the stable local signing identity before the first build. Without it,
# every source rebuild gets a new ad-hoc identity and macOS silently invalidates
# the Accessibility grant even though its old row can still look enabled.
echo "[2/3] Preparing stable app identity..."
./setup-signing.sh

# Build the app + install to /Applications. build.sh owns the single launch and
# permission-pane flow. Speech models download in-app from Hugging Face.
echo "[3/3] Building and installing Whisperino.app..."
./build.sh

echo ""
echo "  ✓ Whisperino installed with a stable local identity!"
echo ""
echo "  ─────────────────────────────────────────"
echo "  IMPORTANT - two permissions required:"
echo "  ─────────────────────────────────────────"
echo ""
echo "  1. MICROPHONE - macOS will ask on first"
echo "     recording. Click Allow."
echo ""
echo "  2. ACCESSIBILITY - required for auto-paste."
echo "     When the app launches, a System Settings"
echo "     window will open. Toggle Whisperino ON"
echo "     in Privacy & Security → Accessibility."
echo "     After enabling it, quit and reopen Whisperino"
echo "     once so the running process picks up the grant."
echo ""
echo "  The first install may ask for your Mac password once while creating"
echo "  the signing identity. Future git pulls keep Accessibility working."
echo ""
