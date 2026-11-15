#!/usr/bin/env bash
# install.sh - installs dictarchy for the current user on Omarchy 4.5 or newer.
#
# Usage: ./install.sh [--link]
#   --link   symlink ~/.local/bin/dictarchy to this checkout (for development)
#
# What it does (nothing system-wide; missing packages only after you confirm):
#   1. ~/.local/bin/dictarchy and ~/.config/dictarchy/config (an existing config is kept)
#   2. the bar widget in ~/.config/omarchy/plugins/io.github.vyrix44.dictarchy/
#   3. a marked block in ~/.config/hypr/hyprland.lua that loads hypr/dictarchy.lua
#   4. the widget entry in ~/.config/omarchy/shell.json (bar.layout.right)
# Every file it edits is backed up first (*.dictarchy-backup-<timestamp>).
# It does not ask for the API key: the bar icon shows "Setup needed" until you
# click it and enter the key in a floating terminal.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
readonly CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
readonly CONFIG_DIR="$CONFIG_HOME/dictarchy"
readonly CONFIG_FILE="$CONFIG_DIR/config"
readonly BIN_DIR="$HOME/.local/bin"
readonly BIN="$BIN_DIR/dictarchy"
readonly HYPR_DIR="$CONFIG_HOME/hypr"
readonly HYPR_CONF="$HYPR_DIR/hyprland.lua"
readonly LEGACY_BINDINGS="$HYPR_DIR/dictarchy.conf"
readonly PLUGIN_ID="io.github.vyrix44.dictarchy"
readonly PLUGIN_DIR="$CONFIG_HOME/omarchy/plugins/$PLUGIN_ID"
readonly SHELL_JSON="$CONFIG_HOME/omarchy/shell.json"
readonly OMARCHY_ROOT="${OMARCHY_PATH:-/usr/share/omarchy}"
readonly MARK_BEGIN="-- >>> dictarchy >>>"
readonly MARK_END="-- <<< dictarchy <<<"
readonly BAR_BEFORE="omarchy.audio"   # the widget goes left of the volume icon when present

LINK=0
PLUGIN_FILES_CHANGED=0
STAMP=$(date +%Y%m%d-%H%M%S)
readonly STAMP

info() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

ask_yes_no() {  # PROMPT DEFAULT(y|n) -> 0 for yes
  local prompt=$1 default=$2 answer hint="[y/N]"
  if [[ $default == y ]]; then hint="[Y/n]"; fi
  read -r -p "$prompt $hint " answer || true
  answer=${answer:-$default}
  [[ $answer =~ ^[Yy]$ ]]
}

backup() {  # FILE - copies FILE next to itself, prints the backup path
  local target="$1.dictarchy-backup-$STAMP"
  cp -p -- "$1" "$target"
  printf '%s' "$target"
}

usage() {
  cat <<'EOF'
Usage: ./install.sh [--link]

  --link   symlink ~/.local/bin/dictarchy to this checkout instead of copying
           (the bar widget is always copied: the shell refuses symlinked plugins)
EOF
}

parse_args() {
  local arg
  for arg in "$@"; do
    case $arg in
      --link) LINK=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $arg (see --help)" ;;
    esac
  done
}

# Read KEY from the config file without sourcing it. Prints DEFAULT if unset.
config_get() {  # KEY DEFAULT
  local line value
  line=$(grep -E "^$1=" "$CONFIG_FILE" 2>/dev/null | tail -n 1 || true)
  if [[ -z $line ]]; then
    printf '%s' "$2"
    return 0
  fi
  value=${line#*=}
  value=${value#\"}
  value=${value%\"}
  printf '%s' "$value"
}

check_omarchy() {
  local version major
  info "Checking Omarchy"
  have omarchy-version || die "omarchy-version not found - dictarchy needs Omarchy 4.5 or newer"
  version=$(omarchy-version 2>/dev/null || true)
  major=${version%%.*}
  if [[ $major =~ ^[0-9]+$ ]] && (( major < 4 )); then
    die "Omarchy $version found - this version of dictarchy needs Omarchy 4.5 or newer"
  fi
  [[ -f $HYPR_CONF ]] || die "$HYPR_CONF not found - dictarchy needs Omarchy's Lua Hyprland config"
  have omarchy-menu-select || die "omarchy-menu-select not found - dictarchy needs Omarchy 4.5 or newer"
  echo "  Omarchy ${version:-unknown}"
}

check_dependencies() {
  local -A pkg_for=(
    [pw-record]=pipewire
    [wtype]=wtype
    [wl-copy]=wl-clipboard
    [curl]=curl
    [notify-send]=libnotify
    [flock]=util-linux
    [setsid]=util-linux
    [jq]=jq
  )
  local cmd missing_pkgs=() pkg
  info "Checking dependencies"
  for cmd in pw-record wtype wl-copy curl notify-send flock setsid jq; do
    if have "$cmd"; then
      printf '  ok       %s\n' "$cmd"
    else
      printf '  MISSING  %s\n' "$cmd"
      pkg=${pkg_for[$cmd]}
      if [[ ! " ${missing_pkgs[*]} " == *" $pkg "* ]]; then missing_pkgs+=("$pkg"); fi
    fi
  done
  if have ffmpeg; then
    printf '  ok       ffmpeg (optional)\n'
  else
    printf '  missing  ffmpeg (optional: silence check and smaller uploads)\n'
  fi

  if (( ${#missing_pkgs[@]} > 0 )); then
    echo
    echo "Required packages are missing. Command:"
    echo "  sudo pacman -S --needed ${missing_pkgs[*]}"
    if have pacman && ask_yes_no "Run this command now?" n; then
      # shellcheck disable=SC2086 # package names are plain words from the list above
      sudo pacman -S --needed ${missing_pkgs[*]} || warn "pacman failed - install the packages manually"
    else
      warn "skipped - dictarchy will not work until the packages are installed"
    fi
    have jq || die "jq is required to edit ~/.config/omarchy/shell.json"
  fi
}

install_binary() {
  info "Installing dictarchy to $BIN"
  mkdir -p "$BIN_DIR"
  if (( LINK )); then
    ln -sfn "$SCRIPT_DIR/bin/dictarchy" "$BIN"
    echo "  symlinked to $SCRIPT_DIR/bin/dictarchy"
  else
    rm -f -- "$BIN"
    cp -f "$SCRIPT_DIR/bin/dictarchy" "$BIN"
    chmod 755 "$BIN"
  fi
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) warn "$BIN_DIR is not on your PATH - the bar and hotkeys use the absolute path, so this only affects the terminal" ;;
  esac
}

install_config() {
  info "Configuration"
  mkdir -p -m 700 "$CONFIG_DIR"
  if [[ -e $CONFIG_FILE ]]; then
    echo "  keeping existing $CONFIG_FILE"
  else
    cp "$SCRIPT_DIR/config/config.example" "$CONFIG_FILE"
    echo "  created $CONFIG_FILE"
  fi
}

plugin_files() {  # DIR - sorted relative file list, empty when DIR is missing
  [[ -d $1 ]] || return 0
  (cd "$1" && find . -type f | sort)
}

install_plugin() {
  local before after
  info "Bar widget"
  before=$(plugin_files "$PLUGIN_DIR")
  mkdir -p "$(dirname "$PLUGIN_DIR")"
  rm -rf -- "$PLUGIN_DIR"
  # A real copy: the shell rejects plugins that contain symlinks.
  cp -r --no-preserve=ownership "$SCRIPT_DIR/plugin" "$PLUGIN_DIR"
  echo "  copied to $PLUGIN_DIR"
  after=$(plugin_files "$PLUGIN_DIR")
  # The running shell caches the plugin folder's file list: new files (say, a new
  # Service.qml) fail to load until it restarts. Edits to existing files reload live.
  if [[ -n $before && $before != "$after" ]]; then
    PLUGIN_FILES_CHANGED=1
  fi
  if have omarchy-plugin-validate; then
    omarchy-plugin-validate "$PLUGIN_DIR" >/dev/null || die "the shell would reject the widget (omarchy plugin validate $PLUGIN_DIR)"
  fi
}

# Warn when one of the configured hotkeys is already bound in Hyprland.
check_hypr_conflicts() {
  local key mods label mask binds matches
  have hyprctl || return 0
  binds=$(hyprctl binds -j 2>/dev/null || true)
  [[ -n $binds ]] || return 0
  key=$(config_get TOGGLE_KEY D)
  mods=$(config_get TOGGLE_MODS "SUPER ALT")
  [[ -n $key ]] || return 0
  mask=0
  [[ " $mods " == *" SHIFT "* ]] && mask=$((mask | 1))
  [[ " $mods " == *" CTRL "* ]] && mask=$((mask | 4))
  [[ " $mods " == *" ALT "* ]] && mask=$((mask | 8))
  [[ " $mods " == *" SUPER "* ]] && mask=$((mask | 64))
  matches=$(jq -r --arg k "$key" --argjson m "$mask" '
    .[] | select((.key | ascii_downcase) == ($k | ascii_downcase) and .modmask == $m)
        | select((.description // "") | startswith("Dictarchy") | not)
        | "  " + (if (.description // "") != "" then .description else "\(.dispatcher) \(.arg)" end)' \
    <<< "$binds" 2>/dev/null || true)
  if [[ -n $matches ]]; then
    label="${mods// / + } + $key"
    warn "$label is already bound - dictarchy replaces it. Pick another toggle key from the menu if you need it:"
    printf '%s\n' "$matches" >&2
  fi
}

install_hypr_block() {
  info "Hyprland configuration"
  if grep -qxF -- "$MARK_BEGIN" "$HYPR_CONF"; then
    echo "  dictarchy block already present in $HYPR_CONF"
  else
    echo "  backup: $(backup "$HYPR_CONF")"
    {
      echo ""
      echo "$MARK_BEGIN"
      echo "-- Managed by dictarchy (install.sh / uninstall.sh) - do not edit between these markers."
      echo "-- Loads the hotkeys from ~/.config/hypr/dictarchy.lua when that file exists."
      echo "do"
      echo "  local file = io.open(os.getenv(\"HOME\") .. \"/.config/hypr/dictarchy.lua\", \"r\")"
      echo "  if file then"
      echo "    file:close()"
      echo "    require(\"hypr.dictarchy\")"
      echo "  end"
      echo "end"
      echo "$MARK_END"
    } >> "$HYPR_CONF"
    echo "  added the dictarchy block to $HYPR_CONF"
  fi
  # Leftover from dictarchy 0.1 (hyprlang bindings, never loaded by a Lua config).
  if [[ -f $LEGACY_BINDINGS ]] && grep -q '^# managed by dictarchy' "$LEGACY_BINDINGS"; then
    rm -f -- "$LEGACY_BINDINGS"
    echo "  removed the old $LEGACY_BINDINGS"
  fi
}

generate_bindings() {
  info "Hotkeys"
  check_hypr_conflicts
  if "$BIN" bindings >/dev/null; then
    "$BIN" status | jq -r '"  push-to-talk: \(if .ptt == "" then "off" else .ptt + " (hold)" end)",
                           "  toggle:       \(if .toggle == "" then "off" else .toggle end)"'
    echo "  written to $HYPR_DIR/dictarchy.lua"
  else
    warn "Hyprland reported errors after loading the bindings - check: hyprctl configerrors"
  fi
}

shell_running() {
  have omarchy-shell && omarchy-shell shell rescanPlugins >/dev/null 2>&1
}

widget_in_bar() {
  [[ -f $SHELL_JSON ]] && jq -e --arg id "$PLUGIN_ID" \
    '[.bar.layout[]? | arrays | .[] | select(type == "object" and .id == $id)] | length > 0' \
    "$SHELL_JSON" >/dev/null 2>&1
}

# Adds {"id": PLUGIN_ID} to bar.layout.right, left of omarchy.audio when present.
# JSON has no comments, so there are no markers: the entry is found by its id.
add_widget_with_jq() {
  local source=$SHELL_JSON tmp
  if [[ ! -s $source ]]; then source="$OMARCHY_ROOT/config/omarchy/shell.json"; fi
  [[ -s $source ]] || die "no shell.json found (neither $SHELL_JSON nor $source)"
  tmp=$(mktemp "$SHELL_JSON.XXXXXX")
  jq --arg id "$PLUGIN_ID" --arg before "$BAR_BEFORE" '
    .version = (.version // 1)
    | .bar = (.bar // {}) | .bar.layout = (.bar.layout // {})
    | .bar.layout.right = (.bar.layout.right // [])
    | .bar.layout.right |= (
        (map(.id) | index($before)) as $i
        | if $i == null then [{id: $id}] + . else .[:$i] + [{id: $id}] + .[$i:] end)
  ' "$source" > "$tmp" || { rm -f -- "$tmp"; die "could not update $SHELL_JSON"; }
  mv -f -- "$tmp" "$SHELL_JSON"
}

install_bar_entry() {
  info "Bar entry"
  mkdir -p "$(dirname "$SHELL_JSON")"
  if widget_in_bar; then
    echo "  dictarchy is already in the bar ($SHELL_JSON)"
    return 0
  fi
  if [[ -f $SHELL_JSON ]]; then
    echo "  backup: $(backup "$SHELL_JSON")"
  fi
  local placement=(--section right)
  if [[ -f $SHELL_JSON ]] && jq -e --arg b "$BAR_BEFORE" '[.bar.layout.right[]?.id] | index($b) != null' \
       "$SHELL_JSON" >/dev/null 2>&1; then
    placement+=(--before "$BAR_BEFORE")
  fi
  # With the shell running, let it place the widget (it writes shell.json itself).
  if shell_running && have omarchy-plugin-enable \
     && omarchy-plugin-enable "$PLUGIN_ID" "${placement[@]}" >/dev/null 2>&1 && widget_in_bar; then
    echo "  added to the bar (right section) via omarchy plugin enable"
    return 0
  fi
  add_widget_with_jq
  echo "  added {\"id\": \"$PLUGIN_ID\"} to bar.layout.right in $SHELL_JSON"
  if have omarchy-shell; then
    omarchy-shell shell reloadConfig >/dev/null 2>&1 || true
  fi
}

main() {
  parse_args "$@"
  check_omarchy
  check_dependencies
  install_binary
  install_config
  install_plugin
  install_hypr_block
  generate_bindings
  install_bar_entry
  "$BIN" status --write >/dev/null 2>&1 || true
  if (( PLUGIN_FILES_CHANGED )) && shell_running && have omarchy-restart-shell; then
    info "Restarting the Omarchy shell (the widget gained new files)"
    omarchy-restart-shell >/dev/null 2>&1 || warn "restart failed - run: omarchy restart shell"
  fi
  echo
  info "Done."
  echo "The dictarchy icon in the bar shows \"Setup needed\" until an API key is saved."
  echo "Click it to enter your Groq API key (https://console.groq.com/keys) in a"
  echo "floating terminal. Right-click it for settings, scroll on it to change the language."
}

main "$@"
