# Whisperino

Local voice transcription for macOS. Lives in your menu bar, runs fully on-device via [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) with Metal GPU acceleration. Parakeet TDT 0.6B v3 is the default; Nemotron (streaming) and Whisper are one click away.

## TL;DR

**Hold a recording button → speak → release.** The default is Fn. In Settings → Dictation you can add multiple keyboard shortcuts or auxiliary mouse buttons, then choose **Hold to record** or **Tap to start**. Your words are transcribed into the app where the take began; keep the intended field focused until delivery.

**Want the LLM to answer instead of just transcribe?** Add Shift any time while you're holding the shortcut - the pill turns rainbow, AI mode is on, and the recording becomes latched. Cmd+C any text or images you want as context (no clicks needed). Tap the shortcut (or press Enter) to submit. Esc to cancel.

## Install

For a normal fresh install, download the DMG from the
[latest release](https://github.com/JanPlr/whisperino/releases/latest), open it,
and drag **Whisperino** to **Applications** before launching it. Whisperino does
not request microphone or Accessibility access from Downloads or a temporary
App Translocation path.

To build from source instead:

```bash
git clone https://github.com/JanPlr/whisperino.git
cd whisperino && ./install.sh
```

Requirements: macOS 14+, Apple Silicon, Xcode CLT (`xcode-select --install`).

Homebrew is not required. SwiftPM downloads the pinned Metal
`CTranscribe.framework`, and Whisperino downloads speech models itself.

The script builds the self-contained
app with the in-process transcribe.cpp engine and installs exactly one copy at
`/Applications/Whisperino.app`. Speech models download from Hugging Face in the
app — Parakeet TDT 0.6B v3 (~705 MB) starts automatically. It does not add a
certificate or private key to your Keychain.

> Grant Accessibility to the exact `/Applications/Whisperino.app` installed by
> the script, then quit and reopen it once. Developers on Nix can `nix-shell`;
> Swift still comes from Xcode CLT.

### Permissions

After install, grant two permissions:

- **Microphone** - allow the first-launch prompt.
- **Accessibility** - needed for auto-paste. Its prompt follows the microphone prompt so macOS dialogs do not overlap; open System Settings from it and toggle Whisperino ON.

On the first launch Whisperino opens its Overview once, shows speech-model
setup progress, and then lives in the menu bar. The default Parakeet download
continues in the background.

## Shortcuts

Recording buttons are customizable in **Settings → Dictation**. Add as many keyboard shortcuts or auxiliary mouse buttons as you like. Defaults below use Fn; substitute any button you configured.

| Shortcut | What it does |
|----------|-------------|
| **Hold shortcut** | Dictate while held, submit on release *(Hold mode)* |
| **Double-tap shortcut** | Latched dictation - single tap stops & submits *(Hold mode)* |
| **Tap shortcut** | Start; tap again to stop and send *(Tap mode)* |
| **Add Shift** *(while holding the shortcut)* | Upgrade to AI mode (latched) |
| **Shortcut + Shift** *(held together)* | Start in AI mode |
| **Cmd+C** *(in AI mode)* | Auto-attach the copied text/image as context |
| **Tap shortcut or Return** *(in AI mode)* | Submit |
| **Esc** | Cancel - recording is discarded |
| Click menu bar icon | Toggle / Copy last / Settings / Updates / Quit |

## How AI mode works

1. Hold Fn - recording starts (white border).
2. Press Shift any time during the recording - border crossfades to a rainbow gradient. Recording is now **latched** (release doesn't submit).
3. While speaking, **Cmd+C anything** in any app - text or images get auto-attached and appear below the pill (up to 5).
4. When you're done: **single-tap Fn** (or press **Return**) to submit. The LLM (Claude Sonnet 4.6 via Langdock) generates a response and pastes it.

If you've configured agents in Settings → Agents, mention an agent's name during your request to route it there instead.

AI mode also supports typed tools with native notch cards:

- **Finder:** “Find my tax PDF.” Spotlight runs on-device and displays a local
  file table. Opening a result requires a second confirmation.
- **Calendar:** “Schedule a design review meeting tomorrow at 2 PM.” Whisperino
  shows the parsed title, time, attendees, and location before **Save** writes
  the event to macOS Calendar.
- **Web:** “Find and open Ada Lovelace on LinkedIn.” Whisperino previews the
  exact search before **Search** opens the default browser.

The screen-aware planner may use the captured screen to resolve references such
as “this person,” but screenshots cannot authorize actions. The planner can
only emit registered tool IDs and validated arguments; every operation that
writes data or opens another app waits for explicit confirmation.

## Long recordings

There's no practical length limit. Parakeet and Whisper rotate the recording into ~40s chunks (cut at silence) and transcribe finished chunks in the background — when you stop, only the last chunk still needs processing. Nemotron streams on Metal as you speak: its live transcript appears directly in the input where recording began. If you switch away, updates pause and move to Whisperino's top widget without touching the new app; returning to the original input resumes there.

Nothing gets lost:

- The raw transcript so far is written to `~/.whisperino/recovery/last-raw-transcript.txt` after every chunk.
- If a chunk fails to transcribe, its audio is kept in the same folder and the rest of the take continues.
- If a later step fails (e.g. the AI call), the raw transcript is copied to your clipboard.

## Settings

Click the menu bar icon → **Settings**.

- **General**: launch at login · pause and resume playing media around dictation · sound effects · API key · AI capabilities (Haiku enhancement · AI mode)
- **Dictation**: speech model (Parakeet · Nemotron 3.5 · Whisper turbo · Whisper large-v3) · multiple keyboard/mouse recording buttons · custom multi-select transcription languages (or automatic detection) · auto-submit apps
- **Dictionary**: terms the LLM should always spell correctly (`Langdock` or `langdonk = Langdock` mappings)
- **Snippets**: reusable text blocks
- **History**: last 50 transcriptions
- **Agents**: register Langdock agents to invoke by voice

## Privacy

- **Transcription is 100% local.** Audio is processed on-device by transcribe.cpp (Metal). No audio leaves your machine. Models are GGUFs from Hugging Face under `handy-computer`.
- **LLM features are opt-in.** Only transcribed *text* (and your attached context) is sent to `api.langdock.com` (EU). Off by default.
- **No telemetry, no analytics.** Everything stored as JSON in `~/.whisperino/`.

## Updating

Whisperino checks GitHub for new releases on launch and once a day. When an update is available, the menu bar menu shows **Update to vX.Y.Z…** - click it and the app downloads, installs, and relaunches itself. You can also check manually via menu → **Check for Updates…**.

Source builds are ad-hoc signed. macOS may ask you to grant Accessibility again
after rebuilding if the app's code identity changed.

Updating from source still works too:

```bash
cd whisperino && git pull && ./install.sh
```

## Releasing (maintainers)

```bash
./release.sh 1.2.0
```

That's it. [release.sh](release.sh) bumps the version in `Info.plist`, commits, tags `v1.2.0`, and pushes. The pushed tag triggers GitHub Actions ([release.yml](.github/workflows/release.yml)), which builds the app (version stamped from the tag), publishes a drag-to-Applications DMG for fresh installs, and publishes a ZIP for the in-app updater using the curated notes in [RELEASE_NOTES.md](RELEASE_NOTES.md). Installed apps pick it up on their next check.

The committed `Info.plist` version is the source of truth, kept in lockstep with the tag — so a `git clone`, a worktree, or even a "Download ZIP" build all report the correct version, not `0.0.0`.

## Troubleshooting

- **A v3.2.3 source install created `Whisperino Self-Signed` in Keychain** - click Deny on any `codesign` password prompt. Remove `Whisperino Self-Signed` from the login keychain in Keychain Access; current installs no longer create or use it.
- **Fn key doesn't trigger anything** - System Settings → Keyboard → "Press 🌐 key to…" should be set to **Do Nothing** or "Show Emoji & Symbols". If it's remapped (or you need Fn for something else), record a different shortcut in **Settings → Dictation**.
- **Paste doesn't work** - update with `git pull && ./install.sh`. Quit every running Whisperino copy, remove the existing Whisperino row from Accessibility, add `/Applications/Whisperino.app`, toggle it on, then quit/reopen the app once. Do not launch a copy from `build/`, Downloads, or another clone.
- **Dictation says the model is missing** - open Settings → Dictation and download Parakeet (or Nemotron / Whisper). The first launch starts the Parakeet download in the background.
- **No live text while speaking** - download and select Nemotron 3.5 in Settings → Dictation, then enable the switch in its model tile. Parakeet and Whisper are offline models. Accessibility is required to stream into the focused field; without a writable field, the partial transcript stays in Whisperino's top widget.
- **App doesn't appear in Accessibility list** - launch it first (`open /Applications/Whisperino.app`), then check.

## Changelog

### 2026-04-26 - Push-to-talk + AI-mode upgrade

- **Hold Fn** is now the primary dictation gesture. Release submits.
- **Double-tap Fn** for latched dictation (hands-free, single tap stops).
- **AI mode upgrade**: while holding Fn, press Shift any time to flip into AI mode. Border crossfades to rainbow. Recording becomes latched.
- **Auto-clipboard capture**: Cmd+C anywhere while in AI mode auto-attaches as context. No paperclip click.
- **Real-time waveform** with ~25ms onset-to-pixel latency. Rolls right-to-left with a per-tick fade.
- **Smarter onset detection**, noise gate, and synthesised low-register start/stop chimes (toggle in Settings).

For the full history, see `git log`.
