# Whisperino 3.2.5 — Safer Dictation and a Smoother First Run

This patch keeps dictation bound to the text field where it started, tightens
memory use during long sessions, and makes clean installation more dependable.

## What changed

- Prevents streaming transcription, rollback, paste, and auto-submit events
  from reaching another app, browser tab, window, button, or text field.
- Pauses field updates while you work elsewhere, then safely resumes in the
  exact original input when you return and finishes the transcript there.
- Keeps Parakeet and Whisper results out of the notch when a valid input owns
  the take; the notch remains the fallback only when no safe input is available.
- Clears the previous transcript before a new recording begins, removing the
  brief stale-text flash between takes.
- Coalesces live PCM work so long streaming sessions cannot build an unbounded
  queue, cleans up interrupted model downloads, and bounds screenshot memory.
- Improves first-run guidance with a clear Overview, visible model-download
  progress, and ordered Microphone and Accessibility permission prompts.
- Makes source installation rollback-safe: the new app is staged and verified
  before it replaces the working installation.
- Keeps DMG creation from performing an unintended local installation.

## Upgrade note

Existing users can install this release with Whisperino's Update button; the
old app does not need to be deleted.

GitHub release artifacts are currently ad-hoc signed, so macOS may require
Accessibility to be enabled again after the update, followed by one quit and
reopen.
