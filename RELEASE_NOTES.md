# Whisperino 3.3.3 — Notch Placement After Unplugging a Display

This patch keeps the notch island on the MacBook's top edge after an
external display is disconnected. The island no longer flies in from the
bottom of the screen on the next take.

## What changed

- Parks the overlay on the current display's notch before the first
  recording, instead of leaving it at the bottom-left of the screen map.
- Snaps the island into place after a display is plugged or unplugged,
  rather than easing it across the remapped coordinates.
- Re-applies that notch position once the window is actually on screen,
  so macOS cannot reopen it at the bottom.

## Upgrade note

Existing users can install this release with Whisperino's Update button. Since
GitHub artifacts remain ad-hoc signed, macOS may ask them to enable
Accessibility for the new build; Whisperino relaunches after the grant becomes
active.

For a fresh install, download the DMG, drag Whisperino to Applications, and
launch the Applications copy.
