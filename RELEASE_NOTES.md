# Whisperino 3.2.4 — Cleaner Recording and Safer Installation

This patch makes Tap recording reliable, simplifies its settings, and removes
an intrusive source-install signing step.

## What changed

- Fixes Tap mode so the first press starts recording and the second press
  stops and sends it, including quick Fn and custom-shortcut taps.
- Keeps the chosen shortcut unchanged when switching between Hold and Tap.
- Replaces the verbose recording section with a compact shortcut control and
  clearly labelled **Hold to record** and **Tap to start** choices.
- Stops `install.sh` from creating a self-signed certificate or private key in
  the login Keychain.
- Makes source builds use ad-hoc signing by default, even if an old Whisperino
  identity remains in Keychain. Maintainer signing is now explicitly opt-in.
- Removes the obsolete self-signing setup helper.

## Upgrade note

Existing users can install this release with Whisperino's Update button; the
old app does not need to be deleted.

If the v3.2.3 source installer created **Whisperino Self-Signed** in Keychain,
deny any `codesign` password prompt and remove that identity from the login
keychain in Keychain Access. Whisperino 3.2.4 no longer creates or uses it.

GitHub release artifacts are currently ad-hoc signed, so macOS may require
Accessibility to be enabled again after the update, followed by one quit and
reopen.
