# Whisperino 3.3.2 — Smooth Dark-Mode Settings

This patch fixes the bright flash that could appear while moving through
Settings in dark mode.

## What changed

- Keeps speech-model rows on a stable dark card surface while their hover
  treatment fades in and out.
- Applies the same stable hover rendering to other selectable setting cards.
- Contains no speaker-filtering or voice-enrollment functionality.

## Upgrade note

Existing users can install this release with Whisperino's Update button. Since
GitHub artifacts remain ad-hoc signed, macOS may ask them to enable
Accessibility for the new build; Whisperino relaunches after the grant becomes
active.

For a fresh install, download the DMG, drag Whisperino to Applications, and
launch the Applications copy.
