# Whisperino 3.2.7 — Restore Pasting Across Apps

This compatibility hotfix restores automatic pasting for users whose
Accessibility text-field identity is unavailable or changes during a take.

## What changed

- Restores the dependable pre-3.2.5 behavior: Whisperino remembers the app
  where dictation began, brings it forward, waits for it to become ready, and
  pastes into its currently focused field.
- Fixes rescue-card-only results in Cursor, terminals, Electron apps, and
  systems where macOS recreates or cannot expose a stable Accessibility node.
- Restores live insertion when an Electron or terminal Accessibility object is
  rebuilt while its application remains frontmost.
- Keeps the v3.2.6 permission relaunch, stable Applications-path enforcement,
  DMG installation flow, and ad-hoc update permission handling.

## Upgrade note

Existing users can install this release with Whisperino's Update button. Since
GitHub artifacts remain ad-hoc signed, macOS may ask them to enable
Accessibility for the new build; Whisperino relaunches after the grant becomes
active.

For a fresh install, download the DMG, drag Whisperino to Applications, and
launch the Applications copy.

Keep the intended destination field focused until delivery. Within one app,
switching tabs or controls changes where the compatibility paste may land.
