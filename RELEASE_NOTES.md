# Whisperino 3.0.2 — Update Checker Fix

This patch fixes **Check for Updates** incorrectly reporting that Whisperino 3.0.0 was current after 3.0.1 had already been released.

## What changed

- Removed the updater's dependency on GitHub's anonymous REST API, whose shared 60-request-per-hour IP limit could be exhausted by a team or office.
- Uses GitHub's public releases feed and still selects the highest semantic version.
- Bypasses stale local and CDN responses when checking manually.
- Reports network, HTTP, and malformed-response errors honestly instead of presenting them as “You're up to date.”
- Constructs downloads from Whisperino's versioned release assets and keeps the existing automatic install-and-relaunch flow.

This release also includes the Bluetooth microphone recovery introduced in 3.0.1.

## Upgrade note

If an older version still says it is current, download 3.0.2 manually from this release page. Future updates will be detected normally. macOS may ask you to re-enable **Accessibility** after updating.
