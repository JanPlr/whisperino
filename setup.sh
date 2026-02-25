#!/bin/bash
set -e

INSTALL_DIR="$HOME/.whisper-flow"
WHISPER_REPO="https://github.com/ggerganov/whisper.cpp.git"
MODEL_NAME="base"

echo "==> WhisperFlow Setup"
echo ""

# Check for cmake
if ! command -v cmake &> /dev/null; then
    echo "cmake not found. Installing via Homebrew..."
    if ! command -v brew &> /dev/null; then
        echo "Error: Homebrew is required. Install from https://brew.sh"
        exit 1
    fi
    brew install cmake
fi

# Create install directory
mkdir -p "$INSTALL_DIR/bin"
mkdir -p "$INSTALL_DIR/models"

# Clone or update whisper.cpp
WHISPER_SRC="$INSTALL_DIR/whisper.cpp"
if [ -d "$WHISPER_SRC" ]; then
    echo "==> Updating whisper.cpp..."
    cd "$WHISPER_SRC"
    git pull --quiet
else
    echo "==> Cloning whisper.cpp..."
    git clone --depth 1 "$WHISPER_REPO" "$WHISPER_SRC"
    cd "$WHISPER_SRC"
fi

# Build with Metal support for Apple Silicon
echo "==> Building whisper.cpp with Metal acceleration..."
cmake -B build \
    -DWHISPER_METAL=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    2>&1 | tail -5

cmake --build build --config Release -j$(sysctl -n hw.ncpu) 2>&1 | tail -5

# Find and copy the CLI binary
CLI_BIN=""
for candidate in build/bin/whisper-cli build/bin/main; do
    if [ -f "$candidate" ]; then
        CLI_BIN="$candidate"
        break
    fi
done

if [ -z "$CLI_BIN" ]; then
    echo "Error: Could not find whisper-cli binary after build"
    echo "Build directory contents:"
    ls -la build/bin/ 2>/dev/null || echo "(no build/bin directory)"
    exit 1
fi

cp "$CLI_BIN" "$INSTALL_DIR/bin/whisper-cli"
chmod +x "$INSTALL_DIR/bin/whisper-cli"
echo "==> Installed whisper-cli to $INSTALL_DIR/bin/"

# Download model
MODEL_FILE="$INSTALL_DIR/models/ggml-${MODEL_NAME}.bin"
if [ -f "$MODEL_FILE" ]; then
    echo "==> Model ggml-${MODEL_NAME}.bin already downloaded"
else
    echo "==> Downloading ggml-${MODEL_NAME}.bin model (~142 MB)..."
    MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${MODEL_NAME}.bin"
    curl -L --progress-bar -o "$MODEL_FILE" "$MODEL_URL"
fi

# Verify
echo ""
echo "==> Setup complete!"
echo "    Binary: $INSTALL_DIR/bin/whisper-cli"
echo "    Model:  $MODEL_FILE"
echo ""
echo "    Next: Run ./build.sh to build WhisperFlow.app"
