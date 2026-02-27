#!/bin/bash
set -e

echo "==> WhisperFlow Installer"
echo ""

# Check for Xcode Command Line Tools
if ! xcode-select -p &>/dev/null; then
    echo "Xcode Command Line Tools not found. Installing..."
    xcode-select --install
    echo "Please re-run this script after installation completes."
    exit 1
fi

# Step 1: Setup whisper.cpp + model
echo "==> Step 1/3: Setting up whisper.cpp and downloading model..."
./setup.sh

# Step 2: Build the app
echo ""
echo "==> Step 2/3: Building WhisperFlow.app..."
./build.sh

# Step 3: Install to /Applications
echo ""
echo "==> Step 3/3: Installing to /Applications..."
if [ -d "/Applications/WhisperFlow.app" ]; then
    echo "    Removing old version..."
    rm -rf "/Applications/WhisperFlow.app"
fi
cp -R build/WhisperFlow.app /Applications/
echo "    Installed to /Applications/WhisperFlow.app"

echo ""
echo "==> Done! WhisperFlow is ready."
echo ""
echo "    Open from Spotlight: search 'WhisperFlow'"
echo "    Or run: open /Applications/WhisperFlow.app"
echo ""
echo "    Shortcut: Option+D to toggle recording"
echo ""
echo "    First launch: macOS will ask for Microphone and"
echo "    Accessibility permissions. Grant both for auto-paste."
