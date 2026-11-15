#!/usr/bin/env bash
# install.sh - installs dictarchy for the current user (Omarchy / Hyprland).
#
# Usage: ./install.sh [--link]
#   --link   symlink ~/.local/bin/dictarchy to this checkout (for development)
#
# Nothing is installed system-wide. Missing system packages are installed only
# after you confirm the exact pacman command shown.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
readonly CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
readonly CONFIG_DIR="$CONFIG_HOME/dictarchy"
readonly CONFIG_FILE="$CONFIG_DIR/config"
readonly API_KEY_FILE="$CONFIG_DIR/api_key"
readonly BIN_DIR="$HOME/.local/bin"
readonly BIN="$BIN_DIR/dictarchy"
readonly HYPR_CONF="$CONFIG_HOME/hypr/hyprland.conf"
readonly MARK_BEGIN="# >>> dictarchy >>>"
readonly MARK_END="# <<< dictarchy <<<"

LINK=0

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

usage() {
  cat <<'EOF'
Usage: ./install.sh [--link]

  --link   symlink ~/.local/bin/dictarchy to this checkout instead of copying
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

check_dependencies() {
  local -A pkg_for=(
    [pw-record]=pipewire
    [wtype]=wtype
    [wl-copy]=wl-clipboard
    [curl]=curl
    [notify-send]=libnotify
    [flock]=util-linux
    [setsid]=util-linux
  )
  local -A optional_pkg_for=(
    [ffmpeg]=ffmpeg
    [jq]=jq
  )
  local cmd missing_pkgs=() missing_opt=() pkg
  info "Checking dependencies"
  for cmd in pw-record wtype wl-copy curl notify-send flock setsid; do
    if have "$cmd"; then
      printf '  ok       %s\n' "$cmd"
    else
      printf '  MISSING  %s\n' "$cmd"
      pkg=${pkg_for[$cmd]}
      if [[ ! " ${missing_pkgs[*]} " == *" $pkg "* ]]; then missing_pkgs+=("$pkg"); fi
    fi
  done
  for cmd in ffmpeg jq; do
    if have "$cmd"; then
      printf '  ok       %s (optional)\n' "$cmd"
    else
      printf '  missing  %s (optional)\n' "$cmd"
      missing_opt+=("${optional_pkg_for[$cmd]}")
    fi
  done

  if (( ${#missing_pkgs[@]} > 0 )); then
    if have pacman; then
      local cmd_line="sudo pacman -S --needed ${missing_pkgs[*]}"
      echo
      echo "Required packages are missing. Command:"
      echo "  $cmd_line"
      if ask_yes_no "Run this command now?" n; then
        # shellcheck disable=SC2086 # package names are plain words from the list above
        sudo pacman -S --needed ${missing_pkgs[*]} || warn "pacman failed - install the packages manually"
      else
        warn "skipped - dictarchy will not work until the packages are installed"
      fi
    else
      warn "install these packages with your package manager: ${missing_pkgs[*]}"
    fi
  fi
  if (( ${#missing_opt[@]} > 0 )) && have pacman; then
    echo "Optional (silence check and smaller uploads, JSON error messages):"
    echo "  sudo pacman -S --needed ${missing_opt[*]}"
  fi
}

install_binary() {
  info "Installing dictarchy to $BIN"
  mkdir -p "$BIN_DIR"
  if (( LINK )); then
    ln -sfn "$SCRIPT_DIR/bin/dictarchy" "$BIN"
    echo "  symlinked to $SCRIPT_DIR/bin/dictarchy"
  else
    cp -f "$SCRIPT_DIR/bin/dictarchy" "$BIN"
    chmod 755 "$BIN"
  fi
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) warn "$BIN_DIR is not on your PATH - add it, or call $BIN directly" ;;
  esac
}

install_config() {
  info "Configuration"
  mkdir -p -m 700 "$CONFIG_DIR"
  if [[ -e $CONFIG_FILE ]]; then
    echo "  keeping existing $CONFIG_FILE"
  else
    cp "$SCRIPT_DIR/config/config.example" "$CONFIG_FILE"
    echo "  created $CONFIG_FILE from config/config.example"
  fi
}

api_key_present() {
  [[ -n ${DICTARCHY_API_KEY:-} || -n ${GROQ_API_KEY:-} || -f $API_KEY_FILE ]]
}

maybe_run_setup() {
  if api_key_present; then
    info "API key found - skipping key setup"
    return 0
  fi
  echo
  if ask_yes_no "No API key found. Run 'dictarchy setup' now (API key and hotkeys)?" y; then
    "$BIN" setup
  else
    echo "  skipped - run '$BIN setup' later"
  fi
}

# Warn when the toggle combo is already bound in Hyprland (best effort).
check_hypr_conflicts() {
  local key mods
  key=$(config_get TOGGLE_KEY D)
  mods=$(config_get TOGGLE_MODS "SUPER ALT")
  [[ -n $key ]] || return 0
  have hyprctl || return 0
  local binds
  binds=$(hyprctl binds -j 2>/dev/null || true)
  [[ -n $binds ]] || return 0
  if have jq; then
    local matches
    matches=$(jq -r --arg k "$key" \
      '.[] | select(.key == $k) | "  existing bind: modmask=\(.modmask) dispatcher=\(.dispatcher) arg=\(.arg)"' \
      <<< "$binds" 2>/dev/null || true)
    if [[ -n $matches ]]; then
      warn "key '$key' (combo: $mods) already has Hyprland binds - the toggle may conflict:"
      printf '%s\n' "$matches" >&2
    fi
  elif grep -q "\"key\": *\"$key\"" <<< "$binds"; then
    warn "a Hyprland bind already uses key '$key' - the toggle combo may conflict (install jq for details)"
  fi
}

install_hypr_source() {
  info "Hyprland configuration"
  if [[ ! -f $HYPR_CONF ]]; then
    warn "$HYPR_CONF not found - add this line to your Hyprland config manually:"
    echo "  source = ~/.config/hypr/dictarchy.conf"
    return 0
  fi
  if grep -qF "$MARK_BEGIN" "$HYPR_CONF"; then
    echo "  source line already present in $HYPR_CONF"
    return 0
  fi
  local backup="$HYPR_CONF.dictarchy-backup-$(date +%Y%m%d-%H%M%S)"
  cp -p "$HYPR_CONF" "$backup"
  echo "  backup written to $backup"
  {
    echo ""
    echo "$MARK_BEGIN"
    echo "# Managed by dictarchy - do not edit between these markers."
    echo "source = ~/.config/hypr/dictarchy.conf"
    echo "$MARK_END"
  } >> "$HYPR_CONF"
  echo "  added source block to $HYPR_CONF"
}

generate_bindings() {
  info "Generating Hyprland bindings"
  check_hypr_conflicts
  "$BIN" bindings
}

print_waybar_instructions() {
  info "Waybar (not edited automatically)"
  echo "Paste the module and CSS below into your Waybar config (see README.md):"
  echo
  "$BIN" waybar
}

main() {
  parse_args "$@"
  check_dependencies
  install_binary
  install_config
  maybe_run_setup
  install_hypr_source
  generate_bindings
  print_waybar_instructions
  echo
  info "Done. Log file: ${XDG_STATE_HOME:-$HOME/.local/state}/dictarchy/dictarchy.log"
}

main "$@"
