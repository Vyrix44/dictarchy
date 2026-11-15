<img src="assets/icon.svg" width="64" height="64" alt="">

# dictarchy

Speech-to-text for [Omarchy](https://omarchy.org) (Arch Linux + Hyprland) via a cloud API.
Hold a key to dictate, or press a combo once to start and again to stop. The transcript is
typed into the focused window and/or copied to the clipboard.

## Features

- **Push-to-talk** on Left Ctrl by default: hold to record, release to transcribe.
  Short taps (Ctrl+C and friends) stay silent.
- **Toggle** on Super+Alt+D by default.
- Any **OpenAI-compatible** `/audio/transcriptions` endpoint. Groq is the default.
- Output by typing (`wtype`), copying (`wl-copy`), or both.
- Language switching with a cycle list, including `auto` detection.
- **Waybar** status module with recording, transcribing and error states.
- Discards very short and silent recordings before anything is sent (needs ffmpeg for the silence check).
- The API key never appears in process arguments, logs or notifications.

## Requirements

| Purpose                | Arch package | Command      | Required |
|------------------------|--------------|--------------|----------|
| Recording              | `pipewire`   | `pw-record`  | yes      |
| Typing text            | `wtype`      | `wtype`      | yes      |
| Clipboard              | `wl-clipboard` | `wl-copy`  | yes      |
| HTTP requests          | `curl`       | `curl`       | yes      |
| Notifications          | `libnotify`  | `notify-send`| yes      |
| Locking, detaching     | `util-linux` | `flock`, `setsid` | yes |
| Silence check, FLAC    | `ffmpeg`     | `ffmpeg`     | optional |
| Readable API errors    | `jq`         | `jq`         | optional |

`install.sh` checks these and offers to run the `sudo pacman -S --needed ...` command for the missing ones.
dictarchy is not installed system-wide and never runs `sudo` on its own.

## Installation

```sh
git clone https://github.com/Vyrix44/dictarchy.git
cd dictarchy
./install.sh          # or ./install.sh --link to symlink for development
```

The installer:

1. checks dependencies,
2. copies `bin/dictarchy` to `~/.local/bin/dictarchy`,
3. creates `~/.config/dictarchy/config` from `config/config.example` (an existing file is kept),
4. asks for your API key and hotkeys if no key is found (`dictarchy setup`),
5. adds a `source` block to `~/.config/hypr/hyprland.conf` (backup first, idempotent),
6. writes `~/.config/hypr/dictarchy.conf`, warns about hotkey conflicts, and reloads Hyprland,
7. prints the Waybar snippet. It does not edit your Waybar config.

Make sure `~/.local/bin` is on your `PATH`. Omarchy usually has it there.

## Getting a Groq API key

1. Create an account at <https://console.groq.com>.
2. Open *API Keys* and create a new key.
3. Run `dictarchy setup` and paste the key. The input is hidden. It is saved to
   `~/.config/dictarchy/api_key` with mode 600.

Alternatively, export `DICTARCHY_API_KEY` or `GROQ_API_KEY` in your environment.

## Configuration

Settings live in `~/.config/dictarchy/config` as `KEY=value` lines. The file is parsed, never sourced.
See [`config/config.example`](config/config.example) for the commented defaults.

| Key | Default | Meaning |
|-----|---------|---------|
| `API_BASE_URL` | `https://api.groq.com/openai/v1` | Base URL; `/audio/transcriptions` is appended |
| `MODEL` | `whisper-large-v3-turbo` | Transcription model |
| `LANGUAGE` | `en` | ISO 639-1 code, or `auto` to omit the language parameter |
| `LANGUAGES` | `en de auto` | Cycle list for `dictarchy lang next` |
| `PROMPT` | *(empty)* | Vocabulary hint sent as `prompt` |
| `OUTPUT_MODE` | `both` | `both`, `type` or `clipboard` |
| `TRAILING_SPACE` | `true` | Append a space after typed text |
| `MIN_DURATION_MS` | `400` | Shorter recordings are discarded |
| `SILENCE_THRESHOLD_DB` | `-50` | Recordings with a lower peak are discarded (ffmpeg) |
| `PTT_KEY` | `Control_L` | Push-to-talk key; empty disables it |
| `PTT_MODS` | *(empty)* | Modifiers for the push-to-talk key, e.g. `SUPER` |
| `TOGGLE_KEY` | `D` | Toggle key; empty disables it |
| `TOGGLE_MODS` | `SUPER ALT` | Modifiers for the toggle key |
| `WAYBAR_SIGNAL` | `11` | Waybar signal used for refreshes |
| `NOTIFY` | `true` | Desktop notifications (errors are always shown) |

The language set with `dictarchy lang` is stored in `~/.local/state/dictarchy/language` and overrides `LANGUAGE`.

## Hotkeys

| Action | Default | Behavior |
|--------|---------|----------|
| Push-to-talk | hold Left Ctrl | Records while held, transcribes on release. Shows "Recording..." only after `MIN_DURATION_MS`. |
| Toggle | Super+Alt+D | Press to start, press again to stop and transcribe. |

To change a hotkey, edit the config and regenerate the bindings:

```sh
$EDITOR ~/.config/dictarchy/config   # e.g. PTT_KEY=Shift_R, TOGGLE_MODS="SUPER"
dictarchy bindings
```

Or run `dictarchy setup`, which asks for the hotkeys and regenerates the bindings.

The generated file `~/.config/hypr/dictarchy.conf` is managed by dictarchy. Edit the config instead.

## Language switching

```sh
dictarchy lang          # print the current language
dictarchy lang next     # cycle through LANGUAGES
dictarchy lang de       # set a language directly
dictarchy lang auto     # let the model detect the language
```

In Waybar, right-click the module to run `dictarchy lang next`.

## Waybar

Run `dictarchy waybar` to print the module and CSS. Then:

1. Add `"custom/dictarchy"` to `modules-right` in `~/.config/waybar/config.jsonc`.
2. Paste the module definition printed by `dictarchy waybar` (it uses absolute paths). [`waybar/module.jsonc`](waybar/module.jsonc) is the same snippet with plain command names.
3. Paste the CSS from [`waybar/style.css`](waybar/style.css) into `~/.config/waybar/style.css`.
4. Restart Waybar.

The module shows a microphone (red while recording), an hourglass while transcribing, and the current
language code. Left-click toggles recording, right-click cycles the language.

## Privacy

Audio is sent to the API endpoint configured in `API_BASE_URL` (Groq by default) for transcription, and nothing else
is sent. dictarchy does not keep recordings: temporary audio is deleted after each request. The log file records
timestamps, HTTP status codes and durations, but never the API key or the transcript text.

## Troubleshooting

Check the log first:

```sh
tail -n 50 ~/.local/state/dictarchy/dictarchy.log
```

- **"Invalid API key"**: run `dictarchy setup`, or check `DICTARCHY_API_KEY` / `GROQ_API_KEY`.
- **Nothing happens on the hotkey**: run `dictarchy bindings`, then check `~/.config/hypr/dictarchy.conf`
  and that `hyprctl binds` lists the binding. Make sure the `source` line is in `hyprland.conf`.
- **Ctrl push-to-talk with modifier-only keys**: `bindn`/`bindrn` depend on Hyprland reporting the modifier
  in the mask. dictarchy adds `CTRL` to the release binding for `Control_L`/`Control_R`, and the equivalent
  for Shift, Alt and Super. If a release is missed, pick a non-modifier key such as `F9` for `PTT_KEY`.
- **Text is not typed**: `wtype` needs a Wayland session with virtual keyboard support. Check that
  `wtype "test"` works in a terminal. The clipboard copy still works in `both` mode.
- **Whisper writes text for silence** (for example "Thank you." or subtitles): raise `SILENCE_THRESHOLD_DB`
  (for example to `-40`) so quiet recordings are dropped, and install ffmpeg for the check.
- **Quiet speech is discarded**: lower `SILENCE_THRESHOLD_DB` (for example to `-60`).
- **Waybar does not update**: check that `WAYBAR_SIGNAL` matches `"signal"` in the module.

## Uninstall

```sh
./uninstall.sh
```

It removes the Hyprland block (with a backup), the generated bindings, `~/.local/bin/dictarchy`
and the runtime directory. It asks before deleting the config directory (it contains your API key) and the state
directory (log and language). Remove the Waybar module by hand.

## Development

```sh
bash tests/smoke.sh   # stub-based test; needs no audio device, network or Wayland
```

The test replaces every external tool with a stub and checks configuration parsing, the start/stop path,
push-to-talk, language cycling, status JSON, API error handling, the Hyprland bindings, and setup.

## License

MIT. See [LICENSE](LICENSE).
