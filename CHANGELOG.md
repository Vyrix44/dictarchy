# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] - 2026-11-15

### Added

- `dictarchy` CLI with `start [--ptt]`, `stop [--ptt]`, `toggle`, `cancel`,
  `status`, `lang`, `setup`, `bindings`, `waybar`, `version` and `help`.
- Speech-to-text through any OpenAI-compatible `/audio/transcriptions` endpoint
  (Groq by default).
- Push-to-talk (hold a key) and toggle (press once to start, once to stop) hotkeys,
  generated as Hyprland bindings.
- Output by typing (`wtype`) and/or copying to the clipboard (`wl-copy`).
- Language selection with cycling (`lang next`) and `auto` detection.
- Waybar module (JSON status, icons, colors) and snippets.
- Discarding of very short and silent recordings (ffmpeg optional).
- API key handling: environment variables or a file with mode 600, never in argv or logs.
- `install.sh` and `uninstall.sh`, stub-based smoke test in `tests/smoke.sh`.
