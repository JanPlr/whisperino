# Whisperino 3.1.0 — Faster, In-Process Transcription

This release replaces the external whisper.cpp process with transcribe.cpp running directly inside Whisperino on Metal.

## What changed

- Added Parakeet TDT 0.6B v3 as the new default model for fast, accurate local dictation in 25 European languages.
- Added one-click model selection and downloads in **Settings → Dictation**.
- Added Nemotron 3.5 ASR with a live streaming transcript while you speak.
- Kept Whisper large-v3-turbo and large-v3 available for broad language support.
- Removed the Homebrew and separate whisper.cpp setup requirement; the transcription engine is now bundled with the app.
- Kept all speech recognition fully on-device with Metal acceleration.

## Upgrade note

On first launch, Whisperino starts downloading the default Parakeet model (about 705 MB). Dictation becomes available when that download finishes. You can choose a different model or follow download progress in **Settings → Dictation**.

Thanks to Hendrik Hofstadt for this major transcription-engine upgrade.
