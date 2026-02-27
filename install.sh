#!/bin/bash
set -e

echo ""
echo "  ╦ ╦┬ ┬┬┌─┐┌─┐┌─┐┬─┐╔═╗┬  ┌─┐┬ ┬"
echo "  ║║║├─┤│└─┐├─┘├┤ ├┬┘╠╣ │  │ ││││"
echo "  ╚╩╝┴ ┴┴└─┘┴  └─┘┴└─╚  ┴─┘└─┘└┴┘"
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
if [ -f "$HOME/.whisper-flow/bin/whisper-cli" ] && [ -f "$HOME/.whisper-flow/models/ggml-small.bin" ]; then
    echo "[2/4] whisper.cpp + model: already installed"
else
    echo "[2/4] Installing whisper.cpp + downloading model (~466 MB)..."
    ./setup.sh
fi

# Build the app
echo "[3/4] Building WhisperFlow.app..."
./build.sh

# Install to /Applications
echo "[4/4] Installing to /Applications..."
if [ -d "/Applications/WhisperFlow.app" ]; then
    rm -rf "/Applications/WhisperFlow.app"
fi
cp -R build/WhisperFlow.app /Applications/

echo ""
echo "  ✓ WhisperFlow installed successfully!"
echo ""
echo "  Launch:    open /Applications/WhisperFlow.app"
echo "             or search 'WhisperFlow' in Spotlight"
echo ""
echo "  Usage:     Option+D to start/stop recording"
echo "             Click the menu bar icon to record"
echo "             Right-click menu bar icon for options"
echo ""
echo "  First run: Grant Microphone + Accessibility"
echo "             when macOS prompts you."
echo ""
