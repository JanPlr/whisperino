# Whisperino 3.4.0 — A Real Mac App

Whisperino now lives in the Dock as well as the menu bar, with a settings
window rebuilt from native macOS controls, a usage overview with charts, and
a new icon.

## What changed

- **Dock app.** Whisperino shows in the Dock and the app switcher and has a
  full menu bar (About, Settings ⌘, Edit, Window, Help). Clicking the Dock
  icon reopens the window; closing the window does not quit - dictation keeps
  working from the trigger and the menu bar item.
- **Native settings.** The window is stock SwiftUI end to end: a sidebar,
  grouped forms, system switches, radio groups, pickers and tables. No custom
  chrome. Languages and auto-submit apps moved into sheets; dictionary,
  snippets and agents are proper tables with `+` / `−`.
- **Overview with charts.** Words today, words overall, time saved and day
  streak at a glance, plus words per day for the last 30 days and the hours
  you dictate most. Whisperino now keeps a small per-dictation log
  (`~/.whisperino/stats.json`) so the charts can look back further than the
  50-entry history; existing history is used to seed it.
- **New icon.** A cursive w on a lime plate, drawn from
  [make-icon.swift](make-icon.swift) so it stays editable. The menu bar
  glyph and the sidebar badge draw the same mark.
- **Hoist the flag.** Rafterino mode is switched on by dragging the flag up
  the mast in General.

## Upgrade note

Existing users can install this release with Whisperino's Update button. Since
GitHub artifacts remain ad-hoc signed, macOS may ask them to enable
Accessibility for the new build; Whisperino relaunches after the grant becomes
active.

For a fresh install, download the DMG, drag Whisperino to Applications, and
launch the Applications copy.
