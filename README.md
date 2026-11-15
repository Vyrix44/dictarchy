<img src="assets/icon.svg" width="64" height="64" alt="">

# dictarchy

Speech-to-text for [Omarchy](https://omarchy.org) 4.5+ via a cloud API.
Hold a key to dictate, or press a combo once to start and again to stop. The transcript is
typed into the focused window and/or copied to the clipboard. A bar icon shows the state,
opens the settings and switches the language.

## Features

- **Push-to-talk** on Left Ctrl by default: hold to record, release to transcribe.
  Short taps (Ctrl+C and friends) stay silent, and Ctrl keeps working in every app.
- **Toggle** on Super+Alt+D by default.
- **Bar widget** for the Omarchy shell: the dictarchy mark (five voice bars rising to a peak) with
  the language, red while recording, pulsing while transcribing, and "Setup needed" until an API key is saved.
- **Recording overlay** at the bottom of the screen: a live waveform of your microphone while you speak,
  a running wave while the text is transcribed. It takes no clicks or keyboard focus.
- **Settings menu** in the Omarchy menu: API key, language, push-to-talk key, toggle key, output, test, log.
- The **API key** is only ever entered in a floating terminal with hidden input, checked against the API,
  and stored with mode 600. It never appears in process arguments, logs or notifications.
- Any **OpenAI-compatible** `/audio/transcriptions` endpoint. Groq is the default.
- Discards very short and silent recordings before anything is sent (needs ffmpeg for the silence check).
- Menus, prompts, notifications and the widget follow the Omarchy language (English and German).

## Requirements

- **Omarchy 4.5 or newer**: Hyprland with the Lua config (`~/.config/hypr/hyprland.lua`), the
  Quickshell-based Omarchy shell (`~/.config/omarchy/shell.json`) and `omarchy-menu-select`.
  Omarchy 3.x (Waybar, Walker, `hyprland.conf`) is not supported by this version.
- Packages:

| Purpose                | Arch package   | Command           | Required |
|------------------------|----------------|-------------------|----------|
| Recording              | `pipewire`     | `pw-record`       | yes      |
| Typing text            | `wtype`        | `wtype`           | yes      |
| Clipboard              | `wl-clipboard` | `wl-copy`         | yes      |
| HTTP requests          | `curl`         | `curl`            | yes      |
| Notifications          | `libnotify`    | `notify-send`     | yes      |
| Locking, detaching     | `util-linux`   | `flock`, `setsid` | yes      |
| Shell config, binds    | `jq`           | `jq`              | yes      |
| Silence check, FLAC    | `ffmpeg`       | `ffmpeg`          | optional |

`install.sh` checks these and offers to run the `sudo pacman -S --needed ...` command for the missing ones.
dictarchy is not installed system-wide and never runs `sudo` on its own.

## Installation

```sh
git clone https://github.com/Vyrix44/dictarchy.git
cd dictarchy
./install.sh          # or ./install.sh --link to symlink the CLI for development
```

The installer does not ask for anything except missing packages. It:

1. checks the Omarchy version and the dependencies,
2. copies `bin/dictarchy` to `~/.local/bin/dictarchy`,
3. creates `~/.config/dictarchy/config` from `config/config.example` (an existing file is kept),
4. copies the bar widget and overlay to `~/.config/omarchy/plugins/io.github.vyrix44.dictarchy/`
   (and restarts the Omarchy shell when an update adds files to it, since the shell caches the file list),
5. appends a block between `-- >>> dictarchy >>>` and `-- <<< dictarchy <<<` to
   `~/.config/hypr/hyprland.lua` that loads `~/.config/hypr/dictarchy.lua`, then writes that file
   and reloads Hyprland (warning about hotkey conflicts),
6. adds `{"id": "io.github.vyrix44.dictarchy"}` to `bar.layout.right` in `~/.config/omarchy/shell.json`,
   left of the volume icon. With the shell running this goes through `omarchy plugin enable`; otherwise
   the file is edited with jq.

Every file it edits is backed up first as `<file>.dictarchy-backup-<timestamp>`. Running it again is safe:
the Hyprland block is found by its markers and the bar entry by its id (JSON has no comments, so
`shell.json` cannot carry markers).

## Setup

After installing, the bar icon shows **Setup needed**.

1. Create a Groq account at <https://console.groq.com>, open *API Keys* and create a key.
2. Click the dictarchy icon. A floating terminal opens and asks for the key; the input is hidden.
3. The key is checked against the API and saved to `~/.config/dictarchy/api_key` (mode 600).
   A rejected key is not saved.

The icon switches to the microphone and the language. Instead of the file you can export
`DICTARCHY_API_KEY` or `GROQ_API_KEY`.

## Using the bar icon

| Action      | Effect |
|-------------|--------|
| Left-click  | start or stop dictation; while setup is needed, enter the API key |
| Right-click | settings menu |
| Scroll      | next or previous language from `LANGUAGES` |

The settings menu:

| Entry            | What it does |
|------------------|--------------|
| API key          | opens the floating terminal to enter or replace the key |
| Language         | pick from `LANGUAGES`, or *Other...* for any ISO 639-1 code (added to the list) |
| Push-to-talk key | Left/Right Ctrl, Right Alt, Right Super, F9, a custom combination, or off |
| Toggle key       | Super+Alt+D, a custom combination, or off |
| Output           | type and copy, type only, or clipboard only |
| Recording overlay | turn the overlay at the bottom of the screen on or off |
| Test             | checks tools, key, API connection, hotkeys and bar entry, then transcribes a 4-second sample in the terminal |
| Log              | opens the log in a floating terminal |

When a new key is already bound in Hyprland, the menu names the existing binding and asks before taking it.
Omarchy's own dictation (when a backend is selected) uses Alt+Space and Right Alt.

## Hotkeys

| Action       | Default        | Behavior |
|--------------|----------------|----------|
| Push-to-talk | hold Left Ctrl | Records while held, transcribes on release. The overlay appears only after `MIN_DURATION_MS`. |
| Toggle       | Super+Alt+D    | Press to start, press again to stop and transcribe. |

The bindings are generated into `~/.config/hypr/dictarchy.lua` with Omarchy's `o.bind_hold` and
`o.rebind`. Change them from the menu, or edit the config and run `dictarchy bindings`.

## Configuration

Settings live in `~/.config/dictarchy/config` as `KEY=value` lines. The file is parsed, never sourced.
See [`config/config.example`](config/config.example) for the commented defaults.

| Key | Default | Meaning |
|-----|---------|---------|
| `API_BASE_URL` | `https://api.groq.com/openai/v1` | Base URL; `/audio/transcriptions` is appended |
| `MODEL` | `whisper-large-v3-turbo` | Transcription model |
| `LANGUAGE` | `en` | ISO 639-1 code, or `auto` to omit the language parameter |
| `LANGUAGES` | `en de auto` | Languages for scrolling and the menu |
| `PROMPT` | *(empty)* | Vocabulary hint sent as `prompt` |
| `OUTPUT_MODE` | `both` | `both`, `type` or `clipboard` |
| `TRAILING_SPACE` | `true` | Append a space after typed text |
| `MIN_DURATION_MS` | `400` | Shorter recordings are discarded |
| `SILENCE_THRESHOLD_DB` | `-50` | Recordings with a lower peak are discarded (ffmpeg) |
| `PTT_KEY` | `Control_L` | Push-to-talk key; empty disables it |
| `PTT_MODS` | *(empty)* | Modifiers for the push-to-talk key, e.g. `SUPER` |
| `TOGGLE_KEY` | `D` | Toggle key; empty disables it |
| `TOGGLE_MODS` | `SUPER ALT` | Modifiers for the toggle key |
| `NOTIFY` | `true` | Desktop notifications (errors are always shown) |
| `OVERLAY` | `true` | Recording overlay at the bottom of the screen |

The language picked by scrolling or in the menu is stored in `~/.local/state/dictarchy/language` and
overrides `LANGUAGE`. A `WAYBAR_SIGNAL` line from dictarchy 0.1 is ignored.

## Command line

```sh
dictarchy toggle | start [--ptt] | stop [--ptt] | cancel
dictarchy menu            # the settings menu
dictarchy key             # enter the API key (opens a floating terminal outside a terminal)
dictarchy lang [next|prev|CODE]
dictarchy bindings        # regenerate ~/.config/hypr/dictarchy.lua and reload Hyprland
dictarchy test            # setup check plus a sample transcription
dictarchy status          # JSON for the bar widget
dictarchy log
```

## Recording overlay

While dictarchy records, a small card appears at the bottom center of the focused monitor: a red dot and a
scrolling waveform of the microphone level. While the audio is transcribed, the bars turn into a running wave in
the theme's accent color; the card disappears when the text arrives. Push-to-talk taps shorter than
`MIN_DURATION_MS` never show it. The card follows the Omarchy theme (colors, border, corner rounding) and lets
every click through. The level comes from the default PipeWire source; a virtual source shows a flat line.

Turn it off with *Recording overlay* in the menu or `OVERLAY="false"` in the config. With the overlay off,
a "Recording..." notification marks the start of a recording instead.

## How the widget gets its state

`dictarchy` writes its status as JSON to `$XDG_RUNTIME_DIR/dictarchy/status.json` on every change.
The bar widget and the overlay service watch that file; the widget and also runs `dictarchy status --write` every 5 seconds, which catches
stale states and keys added by hand. It calls `~/.local/bin/dictarchy`; set `"command"` on the widget's
entry in `shell.json` to use another path.

## Privacy

Audio is sent to the API endpoint configured in `API_BASE_URL` (Groq by default) for transcription, and
nothing else is sent. The key check calls `$API_BASE_URL/models`. dictarchy does not keep recordings:
temporary audio is deleted after each request. The log file records timestamps, HTTP status codes and
durations, but never the API key or the transcript text. The test transcript is only shown in the terminal.

## Troubleshooting

Start with **Test** in the menu (or `dictarchy test` in a terminal), then the log
(`~/.local/state/dictarchy/dictarchy.log`).

- **"Invalid API key"**: right-click the icon, choose *API key*, and enter a new one.
- **Nothing happens on the hotkey**: run `dictarchy bindings`, then `hyprctl configerrors`.
  Check that the dictarchy block is in `~/.config/hypr/hyprland.lua` and that
  `omarchy menu keybindings --print` lists the *Dictarchy* bindings.
- **The icon is missing**: run `omarchy plugin list` and check that `io.github.vyrix44.dictarchy` is in
  `bar.layout` in `~/.config/omarchy/shell.json`; `omarchy-shell shell rescanPlugins` forces a rescan.
- **Text is not typed**: `wtype` needs a Wayland session with virtual keyboard support. Check that
  `wtype "test"` works in a terminal. The clipboard copy still works in `both` mode.
- **Whisper writes text for silence** (for example "Thank you."): raise `SILENCE_THRESHOLD_DB`
  (for example to `-40`) and install ffmpeg for the check.
- **Quiet speech is discarded**: lower `SILENCE_THRESHOLD_DB` (for example to `-60`).

## Uninstall

```sh
./uninstall.sh          # ./uninstall.sh --yes skips the questions and keeps config and log
```

It removes the bar entry from `shell.json` and the Hyprland block (both after backups), the widget,
`~/.config/hypr/dictarchy.lua`, `~/.local/bin/dictarchy` and the runtime directory. It asks before deleting
the config directory (it contains your API key) and the state directory (log and language).

## Development

```sh
bash tests/smoke.sh   # stub-based; needs no audio device, network, Wayland or running shell
```

The test replaces every external tool with a stub and covers configuration parsing, recording, push-to-talk,
the setup state and key handling, language cycling, status JSON, API errors, the generated Lua bindings
(checked with `luac` and a Lua harness), the settings menu, the widget's QML syntax and status parser, and an
install/uninstall round trip in a sandbox `HOME` that must leave `hyprland.lua` and `shell.json` exactly as they were.

## License

MIT. See [LICENSE](LICENSE).
