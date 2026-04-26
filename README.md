# Whisperino

Local voice transcription for macOS. Lives in your menu bar, runs fully on-device using [whisper.cpp](https://github.com/ggerganov/whisper.cpp) with Metal GPU acceleration.

**Hold Fn** to record. Speak. **Release Fn** to auto-submit. The transcribed text is pasted into your focused text field and copied to the clipboard. That's it — no toggling, no double-tapping.

## Features

- **Fully local transcription** — all audio is processed on-device. No audio ever leaves your machine.
- **Multilingual** — automatic language detection. Switch languages mid-sentence and it picks up both.
- **Three modes**:
  - **Dictation** — fast, accurate transcription
  - **Refinement** (optional) — Claude Haiku 4.5 cleans up filler words, adds punctuation, corrects backtracking, and applies your dictionary
  - **Instruction mode** — speak a request and Claude Sonnet 4.6 generates a response inline. Attach clipboard text or images for context.
  - **Agent mode** — say a configured agent's name during instruction mode to route the request to a Langdock Agent (with streaming status updates)
- **Animated overlay** — a small pill at the bottom of your screen shows a live waveform while you speak. Hover for cancel + mic-picker buttons. Never steals focus.
- **Audio input device picker** — switch microphones inline from the overlay. Hot-swap mid-recording.
- **Custom dictionary** — teach the LLM the correct spelling of names, products, and jargon Whisper frequently mishears.
- **Snippets** — save reusable text blocks for quick access.
- **Transcript history** — the last 50 transcriptions are saved locally and browsable from Settings.
- **Soft chime sounds** (off by default) — pleasant low-register tones when recording starts and ends.

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

### After install — permissions you need to grant manually

**Microphone** — macOS will show a permission dialog the first time you record. Click **Allow**.

**Accessibility** — required so Whisperino can paste text into your focused app. After install, System Settings opens automatically. Find **Whisperino** in the Accessibility list and **toggle it ON**. If you don't see it, scroll down or search.

**Screen Recording** *(optional, only if you use the screenshot button in instruction mode)* — macOS will prompt the first time you tap the camera-viewfinder icon. Toggle Whisperino ON in Privacy & Security → Screen Recording.

Once permissions are granted, you're ready to go.

## Shortcuts

| Shortcut | What it does |
|----------|-------------|
| **Hold Fn** | Push-to-talk — record while held, **auto-submit on release** |
| **Double-tap Fn** | Latched recording — keeps recording after you release. **Single tap Fn** stops and submits. |
| **Hold Fn + Shift** | Record in **instruction mode** (LLM responds), submit on release. Press order doesn't matter. |
| **Esc** (while recording) | Cancel — recording is discarded |
| **Return** (while recording) | Submit immediately |
| Click overlay waveform | Submit recording |
| Click menu bar icon | Show menu (toggle, copy last, settings, quit) |

> The overlay also has a small **×** button (top-right on hover) to cancel and a **mic** button (top-left on hover) to switch input devices.

## How it works

### Dictation flow (push-to-talk)

1. **Press and hold Fn** anywhere — the menu bar icon turns **red** and the waveform pill appears at the bottom of your screen, tracking your voice in real-time.
2. Speak.
3. **Release Fn** — recording stops and submits automatically. The icon turns **gray** while transcribing.
4. The transcribed text is placed on your clipboard and pasted (Cmd+V) into the previously focused text field.
5. The pill briefly confirms "Copied to clipboard", then fades away.

### Dictation flow (latched, hands-free)

If you'd rather not hold the key for long dictation:

1. **Double-tap Fn** — recording starts and stays running even after you release.
2. Speak as long as you want.
3. **Single-tap Fn** — recording stops and submits.

This is the right gesture for longer recordings where you want your hands free.

### Instruction mode

**Hold Fn together with Shift** — order doesn't matter; a small (~18ms) mode-decision window catches near-simultaneous presses. The pill border turns into an animated rainbow gradient.

1. Speak a request, e.g. "Reply to this email politely declining the meeting." or "Summarise this for me in one sentence."
2. **Auto-capture context while you talk:**
   - **Anything you Cmd+C while in instruction mode is auto-attached** — highlight text in any app, Cmd+C, and it lands in the pill as context. No need to click the paperclip. Up to 5 attachments stack.
   - **Click the camera-viewfinder icon** in the pill to attach a screenshot of your current screen. macOS will ask for Screen Recording permission the first time.
   - The paperclip still works for one-off clipboard attaching, and tapping it again clears all attachments.
3. **Release Fn** — the request is sent. Voice transcript + all attachments go to the LLM together.
4. The response is pasted into your focused text field.

> Tip: brief accidental Fn taps (<0.5s without follow-up) are discarded automatically — so a quick tap won't dump anything into your text field.

### Agent mode

If you've added Langdock agents in Settings → Agents, mention an agent's name during instruction mode (e.g. "Ask **researcher** about…") and the request is routed to that agent instead of the default Sonnet model. The pill shows live status updates ("Searching the web…", "Reading documents…") streamed from the agent.

## Menu bar menu

Click the menu bar waveform icon to open:

- **Toggle Recording** — same as the keyboard shortcut
- *fn fn — double-tap to toggle* (informational label)
- **Copy Last Transcription** — copy the most recent transcription back to your clipboard
- **Settings…** (Cmd+,)
- **Quit Whisperino**

## Settings

Open via the menu bar icon → **Settings…**.

### General

- **Launch at login**
- **Sound effects** — soft chime when recording starts and stops. Off by default.
- **Dictation shortcut** — hold `fn` (fixed)
- **Instruction mode shortcut** — hold `fn + shift` (fixed)
- **Langdock API Key** — required for LLM refinement, instruction mode, and agents. Paste your key from [Langdock](https://langdock.com). Stored locally in `~/.whisperino/settings.json`.
- **Enable LLM refinement** — when on, transcriptions are post-processed by Claude Haiku via Langdock to remove filler words, add punctuation/capitalization, handle spoken corrections ("scratch that", "actually"), and apply your dictionary.

### Dictionary

Add terms the LLM should always spell correctly. Useful for proper nouns, product names, technical jargon.

Two formats:
- **Single term** — `Langdock` corrects any phonetically similar mishearing to this spelling
- **Phonetic mapping** — `langdonk = Langdock` maps what Whisper hears (left) to the correct spelling (right)

Dictionary corrections only apply when LLM refinement is enabled.

### Snippets

Reusable text blocks. Use the **+** to add a snippet, name it, and paste in the text. (Snippet insertion is currently from the Settings UI; menu-bar insertion was simplified out.)

### History

Last 50 transcriptions, with timestamps. Sparkles icon marks instruction-mode entries. Select an entry and click **Copy** to put it back on the clipboard, or **Clear All** to wipe history.

### Agents

Define Langdock agents you want to invoke by voice. Each entry has a **name** (what you say) and an **agent ID** (from Langdock). Mention the name during instruction mode to route there.

## Data & privacy

- **Transcription is 100% local.** Audio is processed on-device by whisper.cpp. No audio leaves your machine.
- **LLM refinement / instruction mode / agents are opt-in.** When enabled, only the transcribed text (not audio) is sent to `api.langdock.com` (EU endpoint). For agents, the agent's response is streamed back.
- **No telemetry, no analytics, no tracking.**
- All settings, dictionary, snippets, agents, and history are stored as JSON files in `~/.whisperino/`.

## Model

The default Whisper model is `medium` (1.5 GB) — multilingual with strong accuracy and language detection. To change it, edit `MODEL_NAME` in `setup.sh` and re-run setup:

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

After the build, macOS revokes Accessibility permission because the code signature changes. System Settings opens automatically — find Whisperino, toggle it **OFF** then **ON**. Then relaunch:

```bash
open /Applications/Whisperino.app
```

If the update includes whisper.cpp changes, re-run the full install instead:

```bash
./install.sh
```

## Troubleshooting

**"Swift 5.9+ is required"** — your Xcode Command Line Tools are outdated:

```bash
sudo rm -rf /Library/Developer/CommandLineTools
xcode-select --install
```

**Paste doesn't work** — make sure Accessibility is enabled for Whisperino in System Settings → Privacy & Security → Accessibility. Toggle it off and on again after each rebuild.

**App doesn't appear in Accessibility list** — launch it first (`open /Applications/Whisperino.app`), then check the list again.

**Fn key not detected** — Whisperino watches the globe/Fn key via `NSEvent`. If your Fn key is remapped (System Settings → Keyboard → "Press 🌐 key to…"), double-tap detection may fail. Set it to "Do Nothing" or "Show Emoji & Symbols".

## Manual setup

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
├── settings.json            # App settings (LLM toggle, API key, sound effects)
├── dictionary.json          # Custom dictionary terms
├── snippets.json            # Saved snippets
├── agents.json              # Configured Langdock agents
└── history.json             # Last 50 transcriptions
```

## Changelog

### 2026-04-26

**New:**
- **Push-to-talk hotkey** — *just hold Fn*. The app records while you hold, and submits the moment you release. The simplest possible flow.
- **Double-tap Fn (latched)** — alternative for hands-free / long dictation: double-tap to start a latched recording that survives release. A single Fn tap then stops and submits.
- **Reliable instruction mode** — `Fn + Shift` works regardless of which order you press them. A tiny (~18ms) mode-decision window catches near-simultaneous presses.
- **Auto-clipboard capture in instruction mode** — anything you Cmd+C while holding Fn+Shift gets auto-attached as context. No more clicking the paperclip for every selection.
- **Screen-context attachment** — new camera-viewfinder button in the pill (instruction mode only) attaches a screenshot of your current screen so the LLM can "see" what you're looking at. Requires Screen Recording permission.
- **Real-time waveform** — bars now track your voice on every audio buffer (~12ms latency from voice to visible response). The wave actually rolls right-to-left across the pill with a gentle per-tick fade, instead of dancing in place or holding stale snapshots after you stop speaking.
- **Smarter onset detection** — when rising from silence, the meter snaps directly to voice level (no exponential climb). The first word out of silence is captured at full intensity from the very first buffer.

### 2026-04-25

**New features:**
- **Sound effects** — optional soft chimes when recording starts (descending A3→F3) and stops (ascending F3→A3). Synthesized in-memory, low-register, ~9% amplitude. Off by default; toggle in Settings → General.
- **Modernised waveform animation** — rolling 9-bar wave with center emphasis. New samples enter on the right, peak in the middle, fade out on the left. Heavy temporal + spatial smoothing so it reads as a continuous crest, not a jittery oscilloscope.
- **Noise gate** — bars stay flat at silence. Ambient room noise no longer makes the wave dance.
- **More visible recording pill** — brighter border, soft floating drop shadow, capsule-shaped corners.
- **Minimal close animation** — pill fades + slightly shrinks + blurs out. Removed the spinning red badge and sparkle particles.

### 2026-03-15

**New features:**
- **Agent mode** — invoke configured Langdock agents by name during instruction mode. Agent runs streamed inline with status updates ("Searching the web…").
- **Instruction-mode model upgrade** — switched to Claude Sonnet 4.6 for higher-quality responses.
- **Multi-attachment instruction mode** — stack up to 5 clipboard attachments (text or images) per session via the paperclip icon.
- **Inline input device picker** — mic button on the overlay shows available input devices. Hot-swappable mid-recording.
- **Transcript history** — last 50 transcriptions browsable in Settings → History.

**Improvements:**
- **Shortcuts simplified** — switched from Option+D / double-tap Option to **double-tap Fn** for dictation and **Fn + double-tap Shift** for instruction mode.
- **Single Fn stops recording** — once started, a single Fn tap stops and transcribes.
- **Enter / Esc keys** — Return stops and submits, Esc cancels.
- **Cleaner overlay hover** — × in the top right cancels, mic in the top left switches input device.
- **Clipboard preserved on paste** — your clipboard is restored after the auto-paste so you don't lose what was on it.

### 2026-03-05

**New features:**
- **Instruction mode** — speak instructions to the LLM and get a generated response pasted directly. Attach clipboard text or images via the paperclip icon.

**Improvements:**
- **Redesigned settings** — shortcuts shown clearly in General tab. API key is a prerequisite for LLM features.
- **Animated overlay border** — instruction mode shows a colorful rotating gradient border.
- **Empty transcription handling** — LLM is no longer called when no speech is detected.

**Removed:**
- **Context awareness** — didn't work reliably for browser-based apps.
- **Custom shortcut recorder** — replaced with fixed, documented shortcuts.

### 2026-03-04

**Fixes:**
- **Menu bar behavior** — left and right click both show the menu.
- **Overlay colors** — explicit white text/icons regardless of macOS light/dark mode.
- **Paste reliability from Spotlight / Applications** — fixed stale Accessibility (TCC) entries from ad-hoc code signing. Build script now resets TCC entries automatically.
- **Overlay visibility on dark wallpapers** — added subtle white border.
- **Build script improvements** — auto-installs to /Applications, launches the app, resets Accessibility, opens System Settings.
- **Updated whisper.cpp cmake flag** — `WHISPER_METAL` → `GGML_METAL`.
- **Swift 5.9+ version check** — build/install scripts check upfront and explain how to update.

### 2026-03-03

**New features:**
- **Configurable keyboard shortcut** *(later removed in favor of fixed shortcuts)*.
- **Hover stop indicator** on the overlay during recording.
- **LLM refinement** — Claude Haiku post-processing.
- **Custom dictionary** — phonetic mappings.
- **Snippets** — reusable text blocks.

**Fixes:**
- **Dictionary delete/edit** — replaced swipe-to-delete with selection + minus button.
- **Snippet delete/edit** — fixed selection binding in SwiftUI List on macOS.
- **Paste reliability** — text reliably pastes into the previously focused app by re-activating it before Cmd+V.
- **Settings text fields** — Cmd+V/C/X/A now work.
- **Backward-compatible settings** — existing `settings.json` files load without errors.
