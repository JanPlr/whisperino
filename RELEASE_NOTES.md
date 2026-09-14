# Whisperino 3.4.2 — Settings Window Focus

Fixes the settings window opening in its inactive look when reached from the
menu bar.

## What changed

- Opening Settings from the menu bar item activates Whisperino before the
  window appears. Previously the window could come up without focus and
  macOS drew it flat - no sidebar panel, dimmed selection, a stray title.
- The "When you dictate" chart on the Overview draws its bars again.

## Upgrade note

Existing users can install this release with Whisperino's Update button. Since
GitHub artifacts remain ad-hoc signed, macOS may ask them to enable
Accessibility for the new build; Whisperino relaunches after the grant becomes
active.

For a fresh install, download the DMG, drag Whisperino to Applications, and
launch the Applications copy.
