# Whisperino 3.0.1 — Bluetooth Microphone Reliability

This patch fixes an intermittent macOS audio failure where Bluetooth headphones appeared to start recording normally but delivered no sound.

## What changed

- Detects microphones that return only digital silence despite a healthy-looking `AVAudioEngine`.
- Detects missing or stalled audio-buffer callbacks after recording begins.
- Rebuilds the microphone graph when macOS changes the Bluetooth hardware format or sample rate.
- Waits for Bluetooth input routes to stabilize before recording, including when using **Automatic** input selection.
- Retries a silent stream automatically instead of producing an empty transcription.
- Preserves valid audio already captured before a Bluetooth route change.
- Uses the same reliable graph-rebuild path when changing microphones from the notch.

## Upgrade note

macOS may ask you to re-enable **Accessibility** after updating. Open **System Settings → Privacy & Security → Accessibility**, enable Whisperino, then quit and reopen it once.
