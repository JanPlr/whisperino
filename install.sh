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
    echo "[1/4] Installing Xcode Command Line Tools..."
    xcode-select --install
    echo ""
    echo "  Please re-run this script after installation completes."
    exit 1
fi
echo "[1/4] Xcode Command Line Tools: OK"

# Setup whisper.cpp + model
if [ -f "$HOME/.whisperino/bin/whisper-cli" ] && [ -f "$HOME/.whisperino/models/ggml-small.bin" ]; then
    echo "[2/4] whisper.cpp + model: already installed"
else
    echo "[2/4] Installing whisper.cpp + downloading model (~466 MB)..."
    ./setup.sh
fi

# Build the app
echo "[3/4] Building Whisperino.app..."
./build.sh

# Install to /Applications
echo "[4/4] Installing to /Applications..."
pkill Whisperino 2>/dev/null || true
if [ -d "/Applications/Whisperino.app" ]; then
    rm -rf "/Applications/Whisperino.app"
fi
cp -R build/Whisperino.app /Applications/

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
echo "  Then: Option+D to record  |  Right-click menu bar icon for Settings"
echo ""
