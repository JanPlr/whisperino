# Whisperino

Local voice transcription for macOS. Lives in your menu bar, runs fully on-device via [whisper.cpp](https://github.com/ggerganov/whisper.cpp) with Metal GPU acceleration.

## TL;DR

**Hold Fn → speak → release.** Your words are transcribed and pasted into whatever text field is focused.

**Want the LLM to answer instead of just transcribe?** Add Shift any time while you're holding Fn — the pill turns rainbow, AI mode is on, and the recording becomes latched. Cmd+C any text or images you want as context (no clicks needed). Tap Fn (or press Enter) to submit. Esc to cancel.

## Install

```bash
git clone https://github.com/JanPlr/whisperino.git
cd whisperino && ./install.sh
```

Requirements: macOS 14+, Apple Silicon, Xcode CLT (`xcode-select --install`), Homebrew.

The script builds whisper.cpp + downloads the medium model (~1.5 GB), builds the app, and installs to `/Applications`.

### Permissions

After install, grant two permissions:

- **Microphone** — allow on first record prompt.
- **Accessibility** — needed for auto-paste. System Settings opens automatically after install; find Whisperino and toggle it ON.

## Shortcuts

| Shortcut | What it does |
|----------|-------------|
| **Hold Fn** | Dictate while held, submit on release |
| **Double-tap Fn** | Latched dictation — single tap stops & submits |
| **Add Shift** *(while holding Fn)* | Upgrade to AI mode (latched) |
| **Fn + Shift** *(held together)* | Start in AI mode |
| **Cmd+C** *(in AI mode)* | Auto-attach the copied text/image as context |
| **Tap Fn or Return** *(in AI mode)* | Submit |
| **Esc** | Cancel — recording is discarded |
| Click menu bar icon | Toggle / Copy last / Settings / Quit |

## How AI mode works

1. Hold Fn — recording starts (white border).
2. Press Shift any time during the recording — border crossfades to a rainbow gradient. Recording is now **latched** (release doesn't submit).
3. While speaking, **Cmd+C anything** in any app — text or images get auto-attached and appear below the pill (up to 5).
4. When you're done: **single-tap Fn** (or press **Return**) to submit. The LLM (Claude Sonnet 4.6 via Langdock) generates a response and pastes it.

If you've configured agents in Settings → Agents, mention an agent's name during your request to route it there instead.

## Settings

Click the menu bar icon → **Settings**.

- **General**: launch at login · sound effects · API key · LLM refinement toggle
- **Dictionary**: terms the LLM should always spell correctly (`Langdock` or `langdonk = Langdock` mappings)
- **Snippets**: reusable text blocks
- **History**: last 50 transcriptions
- **Agents**: register Langdock agents to invoke by voice

## Privacy

- **Transcription is 100% local.** Audio is processed on-device by whisper.cpp. No audio leaves your machine.
- **LLM features are opt-in.** Only transcribed *text* (and your attached context) is sent to `api.langdock.com` (EU). Off by default.
- **No telemetry, no analytics.** Everything stored as JSON in `~/.whisperino/`.

## Updating

```bash
cd whisperino && git pull && ./build.sh
```

After rebuilding, re-toggle Accessibility (off → on) since the code signature changes. The build script opens System Settings for you.

## Troubleshooting

- **Fn key doesn't trigger anything** — System Settings → Keyboard → "Press 🌐 key to…" should be set to **Do Nothing** or "Show Emoji & Symbols". If it's remapped, our detection fails.
- **Paste doesn't work** — re-toggle Accessibility for Whisperino (off → on) after each rebuild.
- **App doesn't appear in Accessibility list** — launch it first (`open /Applications/Whisperino.app`), then check.

## Changelog

### 2026-04-26 — Push-to-talk + AI-mode upgrade

- **Hold Fn** is now the primary dictation gesture. Release submits.
- **Double-tap Fn** for latched dictation (hands-free, single tap stops).
- **AI mode upgrade**: while holding Fn, press Shift any time to flip into AI mode. Border crossfades to rainbow. Recording becomes latched.
- **Auto-clipboard capture**: Cmd+C anywhere while in AI mode auto-attaches as context. No paperclip click.
- **Real-time waveform** with ~25ms onset-to-pixel latency. Rolls right-to-left with a per-tick fade.
- **Smarter onset detection**, noise gate, and synthesised low-register start/stop chimes (toggle in Settings).

For the full history, see `git log`.
