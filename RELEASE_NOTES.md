# Whisperino 3.2.1 — Unobtrusive External Displays

This patch keeps Whisperino accessible without occupying real menu-bar space on external displays.

## What changed

- Removes the permanent idle fake notch from external displays.
- Keeps external menu-bar icons visible, clickable, and free from accidental hover expansion.
- Still opens Whisperino on the display containing the focused text field while dictating.
- Preserves the idle hover affordance on a MacBook's physical notch, where it does not cover usable menu-bar space.

## Upgrade note

Use the configured Fn or Option-D shortcut to start dictation on an external display. The active notch appears for the take and disappears again afterward.
