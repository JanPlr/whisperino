# Whisperino 3.2.3 — Reliable Updates, Permissions, and Playback

This patch makes source installation predictable and fixes two disruptive
macOS integration issues. It also includes customizable recording shortcuts
and Hold or Tap activation from the recently merged contribution.

## What changed

- Adds a shortcut recorder and Hold or Tap activation modes.
- Requests Accessibility at most once per launch instead of after every failed
  insertion.
- Resumes media only when the exact player and track Whisperino paused are
  still active, preventing an empty Play command from opening Apple Music.
- Makes `git clone` plus `./install.sh` the canonical Homebrew-free source
  installation.
- Creates a stable local signing identity during source installation so
  Accessibility permissions survive future source rebuilds.
- Removes duplicate app launches and duplicate Accessibility settings windows
  from the installer.
- Waits until GitHub has actually uploaded a release ZIP before offering an
  update, and validates the downloaded archive before installation.
- Replaces opaque `ditto exited with status 1` alerts with actionable update
  errors.

## Upgrade note

Existing users can install this release with Whisperino's Update button; the
old app does not need to be deleted. Because GitHub artifacts are currently
ad-hoc signed, macOS may require Accessibility to be enabled once again after
the update, followed by one quit and reopen.
