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

# Setup whisper.cpp + model
if [ -f "$HOME/.whisperino/bin/whisper-cli" ] && [ -f "$HOME/.whisperino/models/ggml-medium.bin" ]; then
    echo "[2/3] whisper.cpp + model: already installed"
else
    echo "[2/3] Installing whisper.cpp + downloading model (~1.5 GB)..."
    ./setup.sh
fi

# Build the app + install to /Applications
echo "[3/3] Building and installing Whisperino.app..."
./build.sh

echo ""
echo "  ✓ Whisperino installed!"
echo ""
echo "  ─────────────────────────────────────────"
echo "  IMPORTANT — two permissions required:"
echo "  ─────────────────────────────────────────"
echo ""
echo "  1. MICROPHONE — macOS will ask on first"
echo "     recording. Click Allow."
echo ""
echo "  2. ACCESSIBILITY — required for auto-paste."
echo "     When the app launches, a System Settings"
echo "     window will open. Toggle Whisperino ON"
echo "     in Privacy & Security → Accessibility."
echo ""
echo "  ─────────────────────────────────────────"
echo ""
echo "  Launching Whisperino now..."
echo ""

open /Applications/Whisperino.app

sleep 2

# Open System Settings directly to Accessibility so they can grant permission
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

echo "  Look for Whisperino in the Accessibility list and toggle it ON."
echo ""
echo "  ─────────────────────────────────────────"
echo "  HOW TO USE"
echo "  ─────────────────────────────────────────"
echo ""
echo "  Dictation:"
echo "    • Hold Fn → speak → release   (auto-submits)"
echo "    • Double-tap Fn               (hands-free, tap Fn again to stop)"
echo ""
echo "  AI mode (LLM responds inline):"
echo "    • While holding Fn, also press Shift"
echo "    • Border turns rainbow → AI mode is active and latched"
echo "    • Cmd+C any text/images to attach them as context"
echo "    • Tap Fn or press Return to submit"
echo ""
echo "  Esc cancels at any time. Click the menu bar icon for Settings."
echo ""
