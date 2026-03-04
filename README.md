# Whisperino

Local voice transcription for macOS. Lives in your menu bar, runs fully on-device using [whisper.cpp](https://github.com/ggerganov/whisper.cpp) with Metal GPU acceleration.

Press **Option+D**, double-tap **Option**, or click the menu bar icon to record. When you stop, the transcribed text is automatically pasted into your focused text field and copied to the clipboard.

## Features

- **Fully local** — all transcription happens on-device. No audio leaves your machine.
- **Multilingual** — automatic language detection. Switch languages mid-sentence and it picks up both.
- **Push-to-talk** — hold Option+D to record, release to transcribe. Or tap to toggle.
- **Double-tap Option** — quickly press Option twice to start recording (always active).
- **Configurable shortcut** — change the keyboard shortcut in Settings.
- **LLM refinement** (optional) — cleans up filler words, adds punctuation, corrects backtracking, and applies your custom dictionary. Uses Claude Haiku via Langdock. Disabled by default; requires an API key.
- **Custom dictionary** — teach the LLM the correct spelling of names, products, and jargon that Whisper frequently mishears.
- **Snippets** — save and quickly insert frequently used text blocks from the menu bar.
- **Minimal overlay** — a small waveform appears at the bottom of your screen while recording. Hover over it to see a stop button. It never steals focus from your current app.

## Requirements

- macOS 14+ (Sonoma or later)
- Apple Silicon Mac (M1/M2/M3/M4)
- Xcode Command Line Tools with Swift 5.9+ (`xcode-select --install`)
- [Homebrew](https://brew.sh) — cmake is installed automatically if missing

## Install

```bash
git clone https://github.com/JanPlr/whisperino.git
cd whisperino
./install.sh
```

The install script does the following automatically:

1. Checks for Xcode Command Line Tools and Swift 5.9+ (tells you how to update if needed)
2. Installs cmake via Homebrew if missing
3. Builds whisper.cpp with Metal acceleration and downloads the `medium` model (~1.5 GB)
4. Builds the Whisperino.app bundle
5. Copies it to `/Applications`
6. Launches the app and opens **System Settings > Accessibility**

### After install — two permissions you need to grant manually

**Microphone** — macOS will show a permission dialog the first time you record. Click **Allow**.

**Accessibility** — required so Whisperino can paste text into your focused app. After install, System Settings opens automatically. Find **Whisperino** in the Accessibility list and **toggle it ON**. If you don't see it, scroll down or search.

Once both permissions are granted, you're ready to go.

## Usage

| Action | What it does |
|--------|-------------|
| **Option+D** (tap) | Toggle recording on/off |
| **Option+D** (hold > 0.4s) | Push-to-talk — records while held, transcribes on release |
| **Double-tap Option** | Start recording (always works, even with a custom shortcut) |
| **Left-click** menu bar icon | Toggle recording |
| **Right-click** menu bar icon | Open the options menu |

### Recording flow

1. Start recording with Option+D, double-tap Option, or by clicking the menu bar icon. The icon turns **red** and a waveform overlay appears.
2. Speak. The overlay shows your audio level in real time.
3. Stop recording — tap the shortcut again, release if holding, click the waveform (hover to see a stop icon), or click the menu bar icon. The icon turns **gray** while transcribing.
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

- **Dictation shortcut** — click the shortcut button and press your desired key combination (must include at least one modifier key like Option, Cmd, Shift, or Ctrl). Default is Option+D. Double-tap Option always works as an additional trigger regardless of this setting.
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

## Updating

```bash
cd whisperino
git pull
./build.sh
```

After the build, macOS revokes Accessibility permission because the code signature changes. System Settings opens automatically — find Whisperino, toggle it **OFF**, then **ON** again. Then relaunch:

```bash
open /Applications/Whisperino.app
```

If the update includes whisper.cpp changes, re-run the full install instead:

```bash
./install.sh
```

## Troubleshooting

**"Swift 5.9+ is required"** — your Xcode Command Line Tools are outdated. Update them:

```bash
sudo rm -rf /Library/Developer/CommandLineTools
xcode-select --install
```

**Paste doesn't work** — make sure Accessibility is enabled for Whisperino in System Settings > Privacy & Security > Accessibility. Toggle it off and on again after each rebuild.

**App doesn't appear in Accessibility list** — launch the app first (`open /Applications/Whisperino.app`), then check the list again.

## Manual setup

If you prefer to run the steps individually:

```bash
./setup.sh    # Build whisper.cpp + download model + install cmake
./build.sh    # Build Whisperino.app
cp -R build/Whisperino.app /Applications/
open /Applications/Whisperino.app
```

## File structure

```
~/.whisperino/
├── bin/whisper-cli          # whisper.cpp binary
├── models/ggml-medium.bin   # Whisper model
├── settings.json            # App settings (LLM toggle, API key, shortcut)
├── dictionary.json          # Custom dictionary terms
└── snippets.json            # Saved snippets
```

## Changelog

### 2026-03-04

**New features:**
- **Context awareness** — when LLM refinement is enabled, Whisperino can read surrounding text from the active app to help the LLM better recognize names and technical terms. Enable in Settings → General.

**Fixes:**
- **Menu bar behavior** — left and right click now both show the standard macOS menu (with pin/unpin). Recording is started via hotkey only.
- **Overlay colors** — switched from system `.primary` to explicit white so text and icons are always visible regardless of macOS light/dark mode.
- **Paste now works reliably from Spotlight / Applications** — fixed an issue where auto-paste silently failed when launching from Spotlight or /Applications. Root cause: stale Accessibility (TCC) entries from ad-hoc code signing. The build script now resets TCC entries automatically on each build.
- **Overlay visible on all backgrounds** — added a subtle white border so the dark overlay is visible on black wallpapers.
- **Overlay hover redesign** — hovering the waveform now dims the bars and overlays a stop icon instead of swapping them out. Cleaner look, stop action is clearly visible.
- **No more duplicate Spotlight results** — the local build directory is now excluded from Spotlight indexing.
- **Build script improvements** — automatically installs to /Applications, launches the app, resets Accessibility permissions, and opens System Settings. No manual steps needed beyond toggling Accessibility ON.
- **Fixed deprecated whisper.cpp cmake flag** — updated `WHISPER_METAL` to `GGML_METAL`.
- **Added Swift 5.9+ version check** — build and install scripts now check your Swift version upfront and tell you how to update if needed.

### 2025-03-03

**New features:**
- **Configurable keyboard shortcut** — change the dictation hotkey in Settings > General. Click the shortcut button, press your desired key combo (requires at least one modifier), and it takes effect immediately. Persists across restarts.
- **Double-tap Option** — quickly press the Option key twice to start recording. Always active regardless of the configured shortcut.
- **Hover stop indicator** — hovering over the waveform overlay during recording shows a stop icon. Click to stop and transcribe.
- **LLM refinement** — optional post-processing via Claude Haiku (Langdock) to clean up filler words, add punctuation, and apply dictionary corrections.
- **Custom dictionary** — add terms and phonetic mappings so the LLM always spells names, products, and jargon correctly.
- **Snippets** — save frequently used text blocks and insert them from the menu bar.

**Fixes:**
- **Dictionary delete/edit** — delete button now works on macOS (replaced swipe-to-delete with selection + minus button and keyboard Delete key).
- **Snippet delete/edit** — fixed selection binding issue in SwiftUI List on macOS.
- **Paste reliability** — text now reliably pastes into the previously focused app by re-activating it before sending Cmd+V.
- **Settings text fields** — Cmd+V, Cmd+C, Cmd+X, and Cmd+A now work in Settings text fields (API key, dictionary, snippets).
- **Dynamic menu label** — the right-click menu shows the current shortcut instead of hardcoded "Option+D".
- **Backward-compatible settings** — existing `settings.json` files without the `hotkey` field load without errors (defaults to Option+D).
