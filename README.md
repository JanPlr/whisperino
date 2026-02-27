# WhisperFlow

Minimal, local-only voice transcription for macOS. Lives in your menu bar, runs fully on-device using [whisper.cpp](https://github.com/ggerganov/whisper.cpp) with Metal GPU acceleration.

Press **Option+D** or click the menu bar icon to start recording. Press again to stop. The transcribed text is pasted directly into your focused text field.

## Install

```bash
git clone https://github.com/JanPlr/whisper-flow.git
cd whisper-flow
./install.sh
```

That's it. The script handles everything: installs whisper.cpp with Metal acceleration, downloads the model (~466 MB), builds the app, and installs it to `/Applications`.

After install, launch from **Spotlight** (search "WhisperFlow") or find it in `/Applications`.

### Requirements

- macOS 14+ (Sonoma or later)
- Apple Silicon Mac (M1/M2/M3/M4)
- Xcode Command Line Tools (`xcode-select --install`)
- cmake (`brew install cmake`)

## Usage

- **Option+D** — toggle recording from anywhere
- **Click menu bar icon** — toggle recording
- **Right-click menu bar icon** — options menu (quit, etc.)

A minimal overlay appears at the bottom of your screen while recording. When you stop, the text is transcribed locally and pasted into whatever text field has focus. It's also copied to your clipboard.

No network calls, no API keys, no telemetry. Everything runs on your machine.

## Permissions

On first launch, macOS will ask for two permissions:

- **Microphone** — needed to record your voice
- **Accessibility** — needed to auto-paste text into the focused app

Grant both in System Settings > Privacy & Security.

## Model

Default model is `small` (466 MB, multilingual). For different speed/quality tradeoffs, edit `MODEL_NAME` in `setup.sh` and `modelPath` in `Transcriber.swift`:

| Model | Size | Speed | Quality |
|-------|------|-------|---------|
| `tiny` | 75 MB | Fastest | Basic |
| `base` | 142 MB | Fast | Good |
| `small` | 466 MB | Medium | Better (default) |
| `medium` | 1.5 GB | Slower | High |

Models are stored in `~/.whisper-flow/models/`.

## Manual setup

```bash
./setup.sh    # Install whisper.cpp + download model
./build.sh    # Build WhisperFlow.app
open build/WhisperFlow.app
```
