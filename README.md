# WhisperFlow

Minimal, local-only voice transcription for macOS. Lives in your menu bar, runs fully on-device using [whisper.cpp](https://github.com/ggerganov/whisper.cpp) with Metal GPU acceleration.

Press **Option+D** to start recording. Press again to stop. The transcribed text is pasted directly into your focused text field.

## Install

```bash
git clone https://github.com/janpluer/whisper-flow.git
cd whisper-flow
./install.sh
```

This clones whisper.cpp, builds it with Metal, downloads the Whisper small model (~466 MB), builds the app, and installs it to `/Applications`. After that, find it in Spotlight or launch from the menu bar.

### Requirements

- macOS 14+ (Sonoma or later)
- Apple Silicon Mac (M1/M2/M3/M4)
- Xcode Command Line Tools (`xcode-select --install`)
- cmake (`brew install cmake`)

## How it works

1. **Option+D** toggles recording
2. A minimal overlay appears at the bottom of your screen showing audio levels
3. When you stop, whisper.cpp transcribes locally on your Mac
4. The text is pasted directly into whatever text field has focus (also copied to clipboard)

No network calls, no API keys, no telemetry. Everything runs on your machine.

## Permissions

On first launch, macOS will ask for two permissions:

- **Microphone** — needed to record your voice
- **Accessibility** — needed to paste text into the focused app

Grant both in System Settings > Privacy & Security. After a rebuild, you may need to re-grant Accessibility (the code signature changes).

## Manual setup

If you prefer to run steps individually:

```bash
./setup.sh    # Install whisper.cpp + download model
./build.sh    # Build WhisperFlow.app
open build/WhisperFlow.app
```

## Model

Default model is `small` (466 MB, multilingual). To change it, edit `MODEL_NAME` in `setup.sh` and `modelPath` in `Transcriber.swift`:

| Model | Size | Speed | Quality |
|-------|------|-------|---------|
| `tiny` | 75 MB | Fastest | Basic |
| `base` | 142 MB | Fast | Good |
| `small` | 466 MB | Medium | Better (default) |
| `medium` | 1.5 GB | Slower | High |

Models are stored in `~/.whisper-flow/models/`.

## Architecture

- **Swift + SwiftUI** native macOS menu bar app
- **whisper.cpp** with Metal GPU acceleration
- **Carbon API** for global hotkey (Option+D)
- **AVAudioEngine** for microphone capture
- **CGEvent** for instant paste simulation
