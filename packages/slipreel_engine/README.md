# slipreel_engine

Pure-Dart processing engine for Slipreel: zoom detection, caption pipeline,
waveform extraction, and related utilities. No Flutter dependency; usable in
headless tests and CLI tools.

## Captions (whisper.cpp)

Auto-captions shell out to the whisper.cpp CLI. In development install it with:

    brew install whisper-cpp   # provides `whisper-cli`

The `small` ggml model is downloaded to the app-support dir on first use.
Shipping a bundled, signed binary inside the .app is tracked with the
distribution work (issue #1); `WhisperResolver.bundledPath` is the wire-up hook.
