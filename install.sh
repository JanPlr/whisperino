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
    echo "[1/2] Installing Xcode Command Line Tools..."
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
echo "[1/2] Xcode Command Line Tools: OK (Swift $SWIFT_VER)"

# Build the app + install to /Applications. build.sh owns the single launch;
# the app sequences its permission prompts. Speech models download in-app. Normal
# installs use ad-hoc signing and never add certificates or keys to Keychain.
echo "[2/2] Building and installing Whisperino.app..."
./build.sh

echo ""
echo "  ✓ Whisperino installed!"
echo ""
echo "  ─────────────────────────────────────────"
echo "  IMPORTANT - two permissions required:"
echo "  ─────────────────────────────────────────"
echo ""
echo "  1. MICROPHONE - macOS asks after launch."
echo "     Click Allow."
echo ""
echo "  2. ACCESSIBILITY - required for auto-paste."
echo "     This prompt follows the microphone prompt."
echo "     Open System Settings from it, then toggle"
echo "     Whisperino ON under Accessibility."
echo "     After enabling it, quit and reopen Whisperino"
echo "     once so the running process picks up the grant."
echo ""
echo "  Whisperino does not add certificates or keys to your Keychain."
echo ""
