# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.2.0] - 2026-11-15

Rewritten for Omarchy 4.5: Hyprland Lua config, the Quickshell-based Omarchy shell
and the Omarchy menu. Omarchy 3.x (Waybar, Walker, `hyprland.conf`) is no longer supported.

### Added

- Bar widget for the Omarchy shell (`io.github.vyrix44.dictarchy`): state icon with the
  language, "Setup needed" while no API key is saved. Left-click toggles dictation or opens
  the key prompt, right-click opens the settings menu, scrolling switches the language.
- `dictarchy menu`: settings in the Omarchy menu (API key, language, push-to-talk key,
  toggle key, output, test, log), with a confirmation before taking a key Hyprland already uses.
- `dictarchy key`: API key prompt in a floating terminal with hidden input; the key is checked
  against `$API_BASE_URL/models` before it is saved. `--stdin` for scripts.
- New mark: five voice bars rising to a peak ("Arch wave"), drawn natively in the bar
  (`ArchWave.qml`) in the theme color, and used for `assets/icon.svg`.
- Recording overlay (`Service.qml`): a card at the bottom of the focused monitor with a live
  microphone waveform while recording and a running wave while transcribing. Click-through,
  follows the theme; `OVERLAY` setting and a menu entry to turn it off.
- `dictarchy test`: setup check (tools, key, API, hotkeys, bar entry) and a sample transcription.
- `dictarchy log`, `dictarchy lang prev`, `dictarchy status --write`.
- English and German text for menus, prompts, notifications and the widget, following the Omarchy language.

### Changed

- `install.sh` no longer asks for the API key. It installs the widget, adds it to
  `bar.layout.right` in `shell.json`, and loads the hotkeys from a marked block in
  `hyprland.lua`, backing up every file it edits. It refuses to run on Omarchy older than 4.
- Hotkeys are generated as Lua (`~/.config/hypr/dictarchy.lua`, `o.bind_hold` / `o.rebind`).
- Without an API key, hotkeys no longer record: the toggle shows "Setup needed", push-to-talk stays silent.
- `dictarchy setup` asks for the key when it is missing and opens the menu otherwise.
- `jq` is now required.
- `install.sh` restarts the Omarchy shell when an update adds files to the widget.
- `uninstall.sh` also removes the bar entry and the widget; `--yes` skips the questions.

### Removed

- Waybar module, `dictarchy waybar`, the `waybar/` snippets and `WAYBAR_SIGNAL` (ignored if present).
- Interactive hotkey questions in `dictarchy setup` (use the menu).

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
