# Whisperino 3.2.6 — Reliable Pasting on Fresh Installs

This hotfix restores automatic pasting for newly installed copies while
preserving the exact-field safety introduced in 3.2.5.

## What changed

- Fixes the fresh-permission state where macOS showed Accessibility as enabled,
  but 3.2.5 could not capture the exact text field and left the result in the
  notch instead of pasting it.
- Prevents recording from starting before Accessibility is genuinely active.
- Automatically relaunches Whisperino once a newly granted Accessibility
  permission becomes usable, giving the next take a clean AX session.
- Keeps the existing per-update permission setup for ad-hoc signed releases.
- Prevents browser downloads and App Translocation copies from onboarding or
  requesting permissions before Whisperino is installed in Applications.
- Adds a drag-to-Applications DMG as the primary artifact for fresh installs;
  the ZIP remains available for Whisperino's in-app updater.
- Retains the 3.2.5 safety boundary: dictation can only affect the exact field
  where the take began and never another app, tab, window, or control.

## Upgrade note

Existing users can install this release with Whisperino's Update button. macOS
will ask them to enable Accessibility for the new build as before; Whisperino
relaunches automatically after the grant becomes active.

For a fresh install, download the DMG, drag Whisperino to Applications, and
launch the Applications copy.
