# Whisperino 3.3.1 — Your Voice, Smoother Settings

This patch adds optional local speaker filtering and removes the bright hover
flash that could appear while moving through Settings in dark mode.

## What changed

- Adds an opt-in **Only use my speech** mode with local voice enrollment and
  speaker matching. Enrollment audio is discarded after the voice profile is
  created.
- Keeps normal transcription as the safe fallback whenever speaker analysis is
  unavailable, times out, or is uncertain.
- Runs speaker analysis in an isolated helper process and only downloads its
  local models when voice setup is requested.
- Fixes dark-mode hover animations briefly flashing bright gray on speech-model
  rows and other selectable setting cards.

## Upgrade note

Existing users can install this release with Whisperino's Update button. Voice
filtering remains off until a voice profile is set up in Settings → Dictation.
Since GitHub artifacts remain ad-hoc signed, macOS may ask users to enable
Accessibility for the new build; Whisperino relaunches after the grant becomes
active.

For a fresh install, download the DMG, drag Whisperino to Applications, and
launch the Applications copy.
