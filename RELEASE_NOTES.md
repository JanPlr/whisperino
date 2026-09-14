# Whisperino 3.4.3 — Settings Window Focus, Again

3.4.2 fixed the settings window coming up in its inactive look only for the
first open. Reopening it from the menu bar item went through a different
path that still ordered the window front before activating the app.

## What changed

- Both the first and every later open of the settings window activate
  Whisperino first, then bring the window front, and re-check on the next
  turn of the run loop in case activation lands late. The window now comes
  up focused from the menu bar item every time: sidebar panel, vivid
  selection, no stray title.

## Upgrade note

Existing users can install this release with Whisperino's Update button. Since
GitHub artifacts remain ad-hoc signed, macOS may ask them to enable
Accessibility for the new build; Whisperino relaunches after the grant becomes
active.

For a fresh install, download the DMG, drag Whisperino to Applications, and
launch the Applications copy.
