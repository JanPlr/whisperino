# Whisperino 3.2.0 — Live Dictation Where You Type

This release makes Nemotron's live transcript appear directly in the text field you are using, with a cleaner fallback in Whisperino's top widget.

## What changed

- Streams partial text into the focused editable field while you speak, including browser-based inputs such as search bars and chat boxes.
- Falls back to the top widget when no writable field is focused, without briefly flashing the final transcript there after successful field insertion.
- Preserves existing text, selections, and clipboard contents while live partials are updated and finalized.
- Moves the widget to the display containing the focused field and smooths transitions between displays.
- Makes long fallback transcripts scroll cleanly inside the widget.
- Pauses media only when it was actually playing before dictation, then resumes that same playback afterward.
- Simplifies **Settings → Dictation**: Nemotron has one “Live streaming of text” badge and its streaming switch lives directly in the downloaded model tile.

## Upgrade note

Live field insertion requires Accessibility access. Select the downloaded Nemotron 3.5 model and leave its tile switch enabled. If macOS asks again after replacing an ad-hoc signed development build, re-enable Whisperino in **System Settings → Privacy & Security → Accessibility**.
