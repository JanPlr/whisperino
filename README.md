# WhisperFlow

Minimal, local-only voice transcription for macOS. Lives in your menu bar, runs fully on-device using [whisper.cpp](https://github.com/ggerganov/whisper.cpp) with Metal acceleration.

Press **Option+D** to start recording. Press again to stop. Transcription is copied to your clipboard.

## Setup

```bash
# Install whisper.cpp and download the model (~142 MB)
./setup.sh

# Build the app
./build.sh

# Run
open build/WhisperFlow.app
```

## How it works

1. **Option+D** toggles recording
2. A minimal overlay appears at the bottom of your screen
3. When you stop, whisper.cpp transcribes locally on your Mac
4. The text is copied to your clipboard automatically

## Requirements

- macOS 14+
- Xcode Command Line Tools (`xcode-select --install`)
- cmake (`brew install cmake`)

## Model

Default model is `base` (142 MB, multilingual). For better accuracy on a powerful machine, edit `setup.sh` and change `MODEL_NAME` to:

| Model | Size | Speed | Quality |
|-------|------|-------|---------|
| `tiny` | 75 MB | Fastest | Basic |
| `base` | 142 MB | Fast | Good (default) |
| `small` | 466 MB | Medium | Better |
| `medium` | 1.5 GB | Slower | High |

Models are stored in `~/.whisper-flow/models/`.

## Architecture

- **Swift + SwiftUI** native macOS menu bar app
- **whisper.cpp** with Metal GPU acceleration for transcription
- **Carbon API** for global hotkey registration
- **AVAudioEngine** for microphone capture
- No network calls, no telemetry, fully offline
