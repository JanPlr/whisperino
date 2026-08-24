# Whisperino 3.2.8 — Compact Offline Delivery

This patch keeps offline dictation compact while retaining the cross-app
compatibility paste restored in 3.2.7.

## What changed

- Prevents Parakeet and Whisper results from flashing in the notch immediately
  before a compatibility paste.
- Applies generally to offline dictation in Cursor, terminals, Electron apps,
  browsers, and native apps when macOS cannot expose a stable text-field node.
- Keeps rescue cards for destinations that are positively non-editable.
- Leaves Nemotron live streaming unchanged: when no writable Accessibility
  range exists, its live hypothesis remains visible in the notch.
- Preserves the v3.2.7 app-reactivation paste and auto-submit behavior.

## Upgrade note

Existing users can install this release with Whisperino's Update button. Since
GitHub artifacts remain ad-hoc signed, macOS may ask them to enable
Accessibility for the new build; Whisperino relaunches after the grant becomes
active.

For a fresh install, download the DMG, drag Whisperino to Applications, and
launch the Applications copy.

Keep the intended destination field focused until delivery. Within one app,
switching tabs or controls changes where the compatibility paste may land.
