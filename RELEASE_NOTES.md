# Whisperino 3.4.4 — Built Against the macOS 26 SDK

The 3.4.x releases were built on a macOS 14 runner and linked against the
macOS 14.5 SDK. On macOS 26 such an app runs in compatibility mode: the
settings window came up with the older flat sidebar and chrome instead of
the native macOS 26 look it was designed for. Locally built copies never
showed this, which is why it took a few releases to pin down.

## What changed

- Release builds run on a macOS 26 runner, so the app is linked against the
  macOS 26 SDK and gets the current system appearance. No app code changed.

## Upgrade note

Existing users can install this release with Whisperino's Update button. Since
GitHub artifacts remain ad-hoc signed, macOS may ask them to enable
Accessibility for the new build; Whisperino relaunches after the grant becomes
active.

For a fresh install, download the DMG, drag Whisperino to Applications, and
launch the Applications copy.
