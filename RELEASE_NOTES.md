# Whisperino 3.2.9 — Polished Dictation Handoff

This patch keeps successful dictation delivery visually quiet from recording
through paste and submission.

## What changed

- Keeps the notch compact while a finished offline transcript is pasted into
  its reserved destination, eliminating the brief transcript flash before
  paste and auto-submit.
- Uses the standard adaptive macOS menu-bar tint for the recording waveform
  instead of turning the icon red.

## Upgrade note

Existing users can install this release with Whisperino's Update button. Since
GitHub artifacts remain ad-hoc signed, macOS may ask them to enable
Accessibility for the new build; Whisperino relaunches after the grant becomes
active.

For a fresh install, download the DMG, drag Whisperino to Applications, and
launch the Applications copy.
