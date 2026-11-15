#!/usr/bin/env bash
# uninstall.sh - removes dictarchy from the current user's account.
#
# Removes (after backups of every edited file): the bar entry in
# ~/.config/omarchy/shell.json, the bar widget, the marked block in
# ~/.config/hypr/hyprland.lua, ~/.config/hypr/dictarchy.lua,
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
readonly HYPR_CONF="$CONFIG_HOME/hypr/hyprland.lua"
readonly BINDINGS="$CONFIG_HOME/hypr/dictarchy.lua"
readonly PLUGIN_ID="io.github.vyrix44.dictarchy"
readonly PLUGIN_DIR="$CONFIG_HOME/omarchy/plugins/$PLUGIN_ID"
readonly SHELL_JSON="$CONFIG_HOME/omarchy/shell.json"
readonly MARK_BEGIN="-- >>> dictarchy >>>"
readonly MARK_END="-- <<< dictarchy <<<"

ASSUME_YES=0
STAMP=$(date +%Y%m%d-%H%M%S)
readonly STAMP

info() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

ask_yes_no() {  # PROMPT -> 0 for yes, default no
  local answer
  read -r -p "$1 [y/N] " answer || true
  [[ ${answer:-n} =~ ^[Yy]$ ]]
}

backup() {  # FILE - prints the backup path
  local target="$1.dictarchy-backup-$STAMP"
  cp -p -- "$1" "$target"
  printf '%s' "$target"
}

widget_in_bar() {
  [[ -f $SHELL_JSON ]] && jq -e --arg id "$PLUGIN_ID" \
    '[.bar.layout[]? | arrays | .[] | select(type == "object" and .id == $id)] | length > 0' \
    "$SHELL_JSON" >/dev/null 2>&1
}

remove_bar_entry() {
  info "Bar entry"
  if ! have jq || ! widget_in_bar; then
    echo "  no dictarchy entry in $SHELL_JSON"
    return 0
  fi
  echo "  backup: $(backup "$SHELL_JSON")"
  local tmp
  tmp=$(mktemp "$SHELL_JSON.XXXXXX")
  if jq --arg id "$PLUGIN_ID" '
       .bar.layout |= with_entries(
         if (.value | type) == "array"
         then .value |= map(select((type == "object" and .id == $id) | not))
         else . end)' "$SHELL_JSON" > "$tmp"; then
    mv -f -- "$tmp" "$SHELL_JSON"
    echo "  removed dictarchy from $SHELL_JSON"
    if have omarchy-shell; then omarchy-shell shell reloadConfig >/dev/null 2>&1 || true; fi
  else
    rm -f -- "$tmp"
    warn "could not edit $SHELL_JSON - remove the {\"id\": \"$PLUGIN_ID\"} entry by hand"
  fi
}

remove_hypr_block() {
  info "Hyprland block"
  if [[ ! -f $HYPR_CONF ]] || ! grep -qxF -- "$MARK_BEGIN" "$HYPR_CONF"; then
    echo "  no dictarchy block in $HYPR_CONF"
    return 0
  fi
  echo "  backup: $(backup "$HYPR_CONF")"
  # Drop the block and the blank line install.sh put in front of it.
  # Output lags one line behind, so a blank line right before the block can be dropped.
  awk -v begin="$MARK_BEGIN" -v end="$MARK_END" '
    $0 == begin { if (held && prev != "") print prev; held = 0; inside = 1; next }
    inside { if ($0 == end) inside = 0; next }
    { if (held) print prev; prev = $0; held = 1 }
    END { if (held) print prev }
  ' "$HYPR_CONF" > "$HYPR_CONF.tmp.$$"
  mv -f -- "$HYPR_CONF.tmp.$$" "$HYPR_CONF"
  echo "  removed the dictarchy block from $HYPR_CONF"
}

remove_files() {
  info "Files"
  local f
  for f in "$BINDINGS" "$BIN"; do
    if [[ -e $f || -L $f ]]; then
      rm -f -- "$f"
      echo "  removed $f"
    fi
  done
  if [[ -d $PLUGIN_DIR ]]; then
    rm -rf -- "$PLUGIN_DIR"
    echo "  removed $PLUGIN_DIR"
  fi
  if [[ -d $RUN_DIR ]]; then
    if [[ -f $RUN_DIR/pid ]]; then kill "$(cat "$RUN_DIR/pid")" 2>/dev/null || true; fi
    rm -rf -- "$RUN_DIR"
    echo "  removed runtime directory $RUN_DIR"
  fi
}

remove_dirs_on_request() {
  info "Config and state"
  if (( ASSUME_YES )); then
    echo "  kept $CONFIG_DIR and $STATE_DIR (--yes never deletes them)"
    return 0
  fi
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
  case ${1:-} in
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) echo "Usage: ./uninstall.sh [--yes]   (--yes: no questions, config and log are kept)"; exit 0 ;;
    '') ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  echo "This removes dictarchy from your account (no system-wide changes)."
  if (( ! ASSUME_YES )) && ! ask_yes_no "Continue?"; then
    echo "Aborted."
    exit 0
  fi
  remove_bar_entry
  remove_hypr_block
  remove_files
  remove_dirs_on_request
  reload_hyprland
  echo
  info "dictarchy has been removed."
}

main "$@"
