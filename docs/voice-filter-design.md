# Voice-only transcription v2

This branch treats speaker filtering as transcript attribution, not audio
gating. The ASR model always receives the original recording. A separately
launched helper identifies speaker turns and the enrolled speaker, then the app
selects timestamped words. If the helper fails, times out, or cannot identify a
speaker confidently, the original transcript is returned unchanged.

## Design constraints

- Disabled mode does not launch or link the speaker runtime into Whisperino's
  main executable. It uses the existing streaming/offline paths and requests no
  timestamps.
- Enabled mode never replaces microphone PCM with silence and never changes the
  recording handed to ASR.
- Speaker analysis runs concurrently with ASR and has a hard timeout.
- Only a strong negative match can suppress all text. Ambiguous matches fail
  open to the normal transcript.
- Enrollment stores three embeddings plus a centroid, not enrollment audio.
- Models are downloaded only during setup and verified by exact byte count and
  SHA-256.

## Primary sources reviewed

- sherpa-onnx speaker embedding, diarization, Swift, and C API documentation:
  https://k2-fsa.github.io/sherpa/onnx/speaker-identification/
  https://k2-fsa.github.io/sherpa/onnx/speaker-diarization/swift.html
  https://k2-fsa.github.io/sherpa/onnx/c-api/html/speaker_diarization.html
- pyannote's overlap-aware diarization pipeline and exclusive diarization:
  https://github.com/pyannote/pyannote-audio/blob/main/src/pyannote/audio/pipelines/speaker_diarization.py
- CAM++ architecture and efficiency results:
  https://arxiv.org/abs/2303.00332
- WeSpeaker production toolkit, enrollment averaging, model licenses, and
  runtime ONNX models:
  https://github.com/wenet-e2e/wespeaker
  https://github.com/wenet-e2e/wespeaker/blob/master/docs/pretrained.md
- transcribe.cpp timestamp/result contracts:
  https://github.com/handy-computer/transcribe.cpp/blob/main/docs/bindings.md
- NVIDIA Sortformer accuracy, overlap evaluation, and limitations (reviewed as
  an alternative; rejected here because its Q8 model is 139 MB and still needs
  cross-recording identity matching):
  https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2.1
  https://github.com/handy-computer/transcribe.cpp/blob/main/docs/models/diar_streaming_sortformer_4spk-v2.1.md

## Known limitations

Speaker recognition is probabilistic, not authentication. Very short speech,
heavy reverberation, voice changes, and simultaneous speakers can be ambiguous.
The fail-open policy deliberately favors retaining the user's words over
aggressively hiding every possible background utterance.
