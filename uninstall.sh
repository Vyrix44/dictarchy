#!/usr/bin/env bash
# uninstall.sh - removes dictarchy from the current user's account.
#
# Removes: the Hyprland source block (after a backup), the generated bindings,
# ~/.local/bin/dictarchy and the runtime directory. The config directory (it
# holds the API key) and the state directory (log, language) are kept unless
# you confirm their removal.
set -euo pipefail

readonly CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
readonly STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
readonly RUNTIME_BASE="${XDG_RUNTIME_DIR:-/tmp/dictarchy-runtime-$(id -u)}"
readonly CONFIG_DIR="$CONFIG_HOME/dictarchy"
readonly STATE_DIR="$STATE_HOME/dictarchy"
readonly RUN_DIR="$RUNTIME_BASE/dictarchy"
readonly BIN="$HOME/.local/bin/dictarchy"
readonly BINDINGS="$CONFIG_HOME/hypr/dictarchy.conf"
readonly HYPR_CONF="$CONFIG_HOME/hypr/hyprland.conf"
readonly MARK_BEGIN="# >>> dictarchy >>>"
readonly MARK_END="# <<< dictarchy <<<"

info() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

ask_yes_no() {  # PROMPT -> 0 for yes, default no
  local answer
  read -r -p "$1 [y/N] " answer || true
  [[ ${answer:-n} =~ ^[Yy]$ ]]
}

remove_hypr_block() {
  info "Hyprland source block"
  if [[ ! -f $HYPR_CONF ]] || ! grep -qF "$MARK_BEGIN" "$HYPR_CONF"; then
    echo "  no dictarchy block found"
    return 0
  fi
  local backup="$HYPR_CONF.dictarchy-backup-$(date +%Y%m%d-%H%M%S)"
  cp -p "$HYPR_CONF" "$backup"
  echo "  backup written to $backup"
  # The markers contain no regex metacharacters, so they are matched literally.
  sed -i '/^# >>> dictarchy >>>$/,/^# <<< dictarchy <<<$/d' "$HYPR_CONF"
  echo "  removed dictarchy block from $HYPR_CONF"
}

remove_files() {
  info "Files"
  if [[ -e $BINDINGS || -L $BINDINGS ]]; then
    rm -f -- "$BINDINGS"
    echo "  removed $BINDINGS"
  fi
  if [[ -e $BIN || -L $BIN ]]; then
    rm -f -- "$BIN"
    echo "  removed $BIN"
  fi
  if [[ -d $RUN_DIR ]]; then
    rm -rf -- "$RUN_DIR"
    echo "  removed runtime directory $RUN_DIR"
  fi
}

remove_dirs_on_request() {
  info "Config and state (you are asked for each)"
  if [[ -d $CONFIG_DIR ]]; then
    echo "  $CONFIG_DIR contains your API key and settings."
    if ask_yes_no "  Delete $CONFIG_DIR?"; then
      rm -rf -- "$CONFIG_DIR"
      echo "  removed $CONFIG_DIR"
    else
      echo "  kept $CONFIG_DIR"
    fi
  fi
  if [[ -d $STATE_DIR ]]; then
    if ask_yes_no "  Delete the log and state directory $STATE_DIR?"; then
      rm -rf -- "$STATE_DIR"
      echo "  removed $STATE_DIR"
    else
      echo "  kept $STATE_DIR"
    fi
  fi
}

reload_hyprland() {
  if have hyprctl; then
    hyprctl reload >/dev/null 2>&1 || warn "hyprctl reload failed"
  fi
}

main() {
  echo "This removes dictarchy from your account (no system-wide changes)."
  if ! ask_yes_no "Continue?"; then
    echo "Aborted."
    exit 0
  fi
  remove_hypr_block
  remove_files
  remove_dirs_on_request
  reload_hyprland
  echo
  info "dictarchy has been removed."
  echo "Remove the dictarchy module from your Waybar config by hand if you added it."
}

main "$@"
