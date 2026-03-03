# Whisperino

Local voice transcription for macOS. Lives in your menu bar, runs fully on-device using [whisper.cpp](https://github.com/ggerganov/whisper.cpp) with Metal GPU acceleration.

Press **Option+D** or click the menu bar icon to record. When you stop, the transcribed text is automatically pasted into your focused text field and copied to the clipboard.

## Features

- **Fully local** — all transcription happens on-device. No audio leaves your machine.
- **Multilingual** — automatic language detection. Switch languages mid-sentence and it picks up both.
- **Push-to-talk** — hold Option+D to record, release to transcribe. Or tap to toggle.
- **LLM refinement** (optional) — cleans up filler words, adds punctuation, corrects backtracking, and applies your custom dictionary. Uses Claude Haiku via Langdock. Disabled by default; requires an API key.
- **Custom dictionary** — teach the LLM the correct spelling of names, products, and jargon that Whisper frequently mishears.
- **Snippets** — save and quickly insert frequently used text blocks from the menu bar.
- **Minimal overlay** — a small waveform appears at the bottom of your screen while recording. It never steals focus from your current app.

## Requirements

- macOS 14+ (Sonoma or later)
- Apple Silicon Mac (M1/M2/M3/M4)
- Xcode Command Line Tools (`xcode-select --install`)
- cmake (`brew install cmake`)

## Install

```bash
git clone https://github.com/JanPlr/whisperino.git
cd whisperino
./install.sh
```

The install script does the following automatically:

1. Checks for Xcode Command Line Tools (prompts you to install if missing)
2. Builds whisper.cpp with Metal acceleration and downloads the `medium` model (~1.5 GB)
3. Builds the Whisperino.app bundle
4. Copies it to `/Applications`
5. Launches the app
6. Opens **System Settings > Privacy & Security > Accessibility**

### After install — two permissions you need to grant manually

**Microphone** — macOS will show a permission dialog the first time you record. Click **Allow**.

**Accessibility** — required so Whisperino can paste text into your focused app. After install, System Settings opens automatically. Find **Whisperino** in the Accessibility list and **toggle it ON**. If you don't see it, scroll down or search.

Once both permissions are granted, you're ready to go.

## Usage

| Action | What it does |
|--------|-------------|
| **Option+D** (tap) | Toggle recording on/off |
| **Option+D** (hold > 0.4s) | Push-to-talk — records while held, transcribes on release |
| **Left-click** menu bar icon | Toggle recording |
| **Right-click** menu bar icon | Open the options menu |

### Recording flow

1. Start recording with Option+D or by clicking the menu bar icon. The icon turns **red** and a waveform overlay appears.
2. Speak. The overlay shows your audio level in real time.
3. Stop recording (tap Option+D again, release if holding, or click the icon). The icon turns **gray** while transcribing.
4. The transcribed text is placed on your clipboard and automatically pasted (Cmd+V) into whatever text field has focus.
5. The overlay briefly shows the result, then fades away.

### Menu bar options (right-click)

- **Toggle Recording** — same as left-click
- **Save Last as Snippet** — saves your most recent transcription as a reusable snippet
- **Insert Snippet** — paste a saved snippet into the focused text field
- **Settings** — open the settings window
- **Quit Whisperino**

## Settings

Right-click the menu bar icon and select **Settings**, or use the keyboard shortcut **Cmd+,** while the menu is open.

### General

- **Enable LLM refinement** — when turned on, transcriptions are post-processed by Claude Haiku (via Langdock) to remove filler words ("um", "uh", "like"), add punctuation and capitalization, handle spoken corrections ("scratch that", "actually"), and apply your dictionary terms.
- **Langdock API Key** — required for LLM refinement. Paste your API key from [Langdock](https://langdock.com). The key is stored locally in `~/.whisperino/settings.json`.

### Dictionary

Add terms the LLM should always spell correctly. This is useful for proper nouns, product names, and technical jargon that Whisper frequently mishears.

Two formats:
- **Single term** — e.g. `Langdock` — corrects any phonetically similar mishearing to this spelling
- **Phonetic mapping** — e.g. `langdonk = Langdock` — maps what Whisper hears (left) to the correct spelling (right)

Dictionary corrections only apply when LLM refinement is enabled.

### Snippets

Create reusable text blocks you can quickly insert from the menu bar. Use the **+** button to add a snippet, give it a name, and write or paste the text. Insert any snippet via right-click > Insert Snippet.

You can also save your last transcription as a snippet directly from the menu bar.

## Data & privacy

- **Transcription is 100% local.** Audio is processed on-device by whisper.cpp. No audio or text is sent anywhere.
- **LLM refinement is opt-in and off by default.** When enabled, only the transcribed text (not audio) is sent to `api.langdock.com` (EU endpoint) for cleanup. This is the only network call the app makes.
- **No telemetry, no analytics, no tracking.**
- Settings, dictionary, and snippets are stored as JSON files in `~/.whisperino/`.

## Model

The default model is `medium` (1.5 GB) — multilingual with strong accuracy and language detection. For different speed/quality tradeoffs, edit `MODEL_NAME` in `setup.sh` and re-run setup:

| Model | Size | Speed | Quality |
|-------|------|-------|---------|
| `tiny` | 75 MB | Fastest | Basic |
| `base` | 142 MB | Fast | Good |
| `small` | 466 MB | Medium | Better |
| `medium` | 1.5 GB | Slower | High (default) |

Models are stored in `~/.whisperino/models/`.

## Rebuilding

After each rebuild, macOS revokes Accessibility permission because the code signature changes. You need to re-grant it:

```bash
./build.sh
```

The build script opens System Settings automatically. Find Whisperino, toggle it **OFF**, then **ON** again.

## Manual setup

If you prefer to run the steps individually:

```bash
./setup.sh    # Build whisper.cpp + download model
./build.sh    # Build Whisperino.app
open build/Whisperino.app
```

## File structure

```
~/.whisperino/
├── bin/whisper-cli          # whisper.cpp binary
├── models/ggml-medium.bin   # Whisper model
├── settings.json            # App settings (LLM toggle, API key)
├── dictionary.json          # Custom dictionary terms
└── snippets.json            # Saved snippets
```
