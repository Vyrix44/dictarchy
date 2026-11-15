#!/usr/bin/env bash
# Stub-based smoke test for dictarchy. Needs no audio device, network, Wayland,
# Hyprland or running Omarchy shell: every external tool (pw-record, curl, wtype,
# wl-copy, notify-send, hyprctl, ffmpeg, omarchy-menu-*, xdg-terminal-exec, ...)
# is replaced by a stub on PATH that records its calls into a temporary directory.
# install.sh and uninstall.sh run against a sandbox HOME.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DICT="$REPO/bin/dictarchy"
DICT_REAL=$(readlink -f "$DICT")
readonly KEY="gsk_TESTKEY_0123456789"

TMP=$(mktemp -d)
KEEP_TMP=${KEEP_TMP:-0}
trap '(( KEEP_TMP )) || rm -rf "$TMP"' EXIT
readonly STUB_BIN="$TMP/stubs" LOGS="$TMP/logs"
mkdir -p "$STUB_BIN" "$LOGS" "$TMP/home/.config" "$TMP/state" "$TMP/run"
chmod 700 "$TMP/run"

export HOME="$TMP/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_STATE_HOME="$TMP/state"
export XDG_RUNTIME_DIR="$TMP/run"
export STUB_LOG="$LOGS"
export STUB_EXPECT_KEY="$KEY"
export DICTARCHY_UI_LANG=en
export PATH="$STUB_BIN:/usr/bin:/bin"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok    $*"; }
failed() { FAIL=$((FAIL + 1)); echo "  FAIL  $*"; }
check() {  # DESCRIPTION COMMAND...
  local desc=$1
  shift
  if "$@" >/dev/null; then pass "$desc"; else failed "$desc"; fi
}
skip() { echo "  skip  $*"; }

# ---------------------------------------------------------------------------
# Stubs
# ---------------------------------------------------------------------------
make_stub() {  # NAME BODY (read from stdin)
  { echo '#!/usr/bin/env bash'; cat; } > "$STUB_BIN/$1"
  chmod +x "$STUB_BIN/$1"
}

make_stub pw-record <<'EOF'
# Writes a fake WAV and waits for SIGINT like the real recorder.
for last; do :; done
printf 'RIFF-fake-audio' > "$last"
echo "pw-record $*" >> "$STUB_LOG/pw-record.log"
trap 'exit 0' INT TERM
while :; do sleep 0.05 & wait $!; done
EOF

make_stub curl <<'EOF'
# The API key must arrive on stdin (-K -), never in argv.
config=$(cat)
out=""
prev=""
for arg in "$@"; do
  if [[ $prev == -o ]]; then out=$arg; fi
  prev=$arg
done
{
  printf 'ARGS'
  for arg in "$@"; do printf ' [%s]' "$arg"; done
  printf '\n'
} >> "$STUB_LOG/curl.log"
if grep -qF "header = \"Authorization: Bearer $STUB_EXPECT_KEY\"" <<< "$config"; then
  echo AUTH_OK >> "$STUB_LOG/curl.log"
else
  echo AUTH_MISSING >> "$STUB_LOG/curl.log"
fi
if [[ "$*" == *"$STUB_EXPECT_KEY"* ]]; then echo KEY_IN_ARGV >> "$STUB_LOG/curl.log"; fi
if [[ -n $out && $out != /dev/null ]]; then printf '%s' "${STUB_BODY:-hello world}" > "$out"; fi
printf '%s' "${STUB_HTTP_CODE:-200}"
EOF

make_stub wtype <<'EOF'
echo CALL >> "$STUB_LOG/wtype.log"
printf '%s\n' "$@" >> "$STUB_LOG/wtype.log"
EOF

make_stub wl-copy <<'EOF'
# The transcript must arrive on stdin; argv is logged to prove it is not there.
echo CALL >> "$STUB_LOG/wl-copy.log"
printf 'ARGV:%s\n' "$*" >> "$STUB_LOG/wl-copy.log"
cat >> "$STUB_LOG/wl-copy.log"
echo >> "$STUB_LOG/wl-copy.log"
EOF

make_stub notify-send <<'EOF'
printf '%s\n' "$*" >> "$STUB_LOG/notify.log"
EOF

make_stub hyprctl <<'EOF'
printf '%s\n' "$*" >> "$STUB_LOG/hyprctl.log"
case ${1:-} in
  binds) cat "${STUB_BINDS:-/dev/null}" 2>/dev/null || echo '[]' ;;
  configerrors) printf '%s' "${STUB_CONFIG_ERRORS:-}" ;;
esac
exit 0
EOF

make_stub ffmpeg <<'EOF'
# volumedetect: report STUB_MAX_VOLUME (default -20 dB) on stderr.
if [[ " $* " == *" volumedetect "* ]]; then
  echo "[Parsed_volumedetect_0 @ 0x1] max_volume: ${STUB_MAX_VOLUME:--20.0} dB" >&2
  exit 0
fi
# Any other call is a conversion: copy input to output (last argument).
input=""
prev=""
for arg in "$@"; do
  if [[ $prev == -i ]]; then input=$arg; fi
  prev=$arg
done
for last; do :; done
cp -- "$input" "$last"
EOF

# Menus answer from a queue file, one line per call. An empty line or the end of
# the queue means "dismissed" (exit 1), like pressing Escape.
make_stub omarchy-menu-select <<'EOF'
printf 'SELECT %s\n' "$*" >> "$STUB_LOG/menu.log"
q="$STUB_LOG/menu-answers"
[[ -s $q ]] || exit 1
answer=$(head -n 1 "$q"); sed -i 1d "$q"
[[ -n $answer ]] || exit 1
printf '%s' "$answer"
EOF
cp "$STUB_BIN/omarchy-menu-select" "$STUB_BIN/omarchy-menu-input"
sed -i 's/SELECT/INPUT/' "$STUB_BIN/omarchy-menu-input"

make_stub xdg-terminal-exec <<'EOF'
printf '%s\n' "$*" >> "$STUB_LOG/terminal.log"
EOF
make_stub uwsm-app <<'EOF'
[[ ${1:-} == -- ]] && shift
exec "$@"
EOF

make_stub omarchy-version <<'EOF'
echo "${STUB_OMARCHY_VERSION:-4.5.0-3}"
EOF
# No running shell: the installer must fall back to editing shell.json with jq.
make_stub omarchy-shell <<'EOF'
printf '%s\n' "$*" >> "$STUB_LOG/omarchy-shell.log"
[[ ${STUB_SHELL_UP:-0} == 1 ]]
EOF
make_stub omarchy-restart-shell <<'EOF'
echo restart >> "$STUB_LOG/restart-shell.log"
EOF
make_stub omarchy-plugin-validate <<'EOF'
real=/usr/share/omarchy/bin/omarchy-plugin-validate
if [[ -x $real ]]; then exec "$real" "$@"; fi
exit 0
EOF

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
CFG_DIR="$XDG_CONFIG_HOME/dictarchy"
CFG="$CFG_DIR/config"
RUN_DIR="$TMP/run/dictarchy"
STATE_LOG="$TMP/state/dictarchy/dictarchy.log"
BIND_FILE="$XDG_CONFIG_HOME/hypr/dictarchy.lua"

reset_env() {
  if [[ -f $RUN_DIR/pid ]]; then
    local pid
    pid=$(cat "$RUN_DIR/pid" 2>/dev/null || true)
    if [[ -n $pid ]]; then kill "$pid" 2>/dev/null || true; fi
  fi
  rm -rf "$CFG_DIR" "$TMP/state/dictarchy" "$RUN_DIR" "$XDG_CONFIG_HOME/hypr" "$XDG_CONFIG_HOME/omarchy" "$HOME/.local"
  rm -f "$LOGS"/*.log "$LOGS/menu-answers"
  rm -f "$TMP/INJECT_PWNED"
  unset STUB_HTTP_CODE STUB_BODY STUB_MAX_VOLUME GROQ_API_KEY STUB_BINDS STUB_CONFIG_ERRORS
  export DICTARCHY_API_KEY="$KEY"
  mkdir -p "$CFG_DIR"
  cd "$TMP" || exit 1
}

write_config() {  # reads the config body from stdin
  cat > "$CFG"
}

wait_for() {  # FILE - detached launches (open_terminal) log asynchronously
  local i
  for (( i = 0; i < 40; i++ )); do
    [[ -s $1 ]] && return 0
    sleep 0.05
  done
  return 1
}

menu_answers() {  # LINE... - queue answers for the stubbed menus
  printf '%s\n' "$@" > "$LOGS/menu-answers"
}

field_of_status() {  # FIELD
  "$DICT" status | sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p"
}
state_of_status() { field_of_status state; }

json_valid() {  # stdin: must be one JSON object
  python3 -c 'import json,sys; obj=json.loads(sys.stdin.read()); assert isinstance(obj, dict)' 2>/dev/null
}

# ---------------------------------------------------------------------------
echo "== syntax"
# ---------------------------------------------------------------------------
for script in "$REPO/bin/dictarchy" "$REPO/install.sh" "$REPO/uninstall.sh" "$REPO/tests/smoke.sh"; do
  check "bash -n $(basename "$script")" bash -n "$script"
done
if command -v shellcheck >/dev/null 2>&1; then
  check "shellcheck" shellcheck -x "$REPO/bin/dictarchy" "$REPO/install.sh" "$REPO/uninstall.sh"
else
  skip "shellcheck not installed"
fi
for json in "$REPO/plugin/manifest.json" "$REPO/plugin/i18n/"*.json; do
  check "valid JSON: ${json#"$REPO/"}" jq -e . "$json"
done
check "de.json has every key of en.json" bash -c "diff <(jq -r 'keys[]' '$REPO/plugin/i18n/en.json') <(jq -r 'keys[]' '$REPO/plugin/i18n/de.json') >/dev/null"
QMLFORMAT=$(command -v qmlformat || echo /usr/lib/qt6/bin/qmlformat)
if [[ -x $QMLFORMAT ]]; then
  for qml in "$REPO/plugin/"*.qml; do
    check "$(basename "$qml") parses (qmlformat)" "$QMLFORMAT" "$qml"
  done
else
  skip "qmlformat not installed"
fi
check "plugin passes omarchy plugin validate" omarchy-plugin-validate "$REPO/plugin"
check "manifest declares the overlay service" test "$(jq -c '[.kinds, .entryPoints.service]' "$REPO/plugin/manifest.json")" = '[["bar-widget","service"],"Service.qml"]'
if command -v node >/dev/null 2>&1; then
  node -e '
    const fs = require("fs"); const vm = require("vm");
    const src = fs.readFileSync(process.argv[1], "utf8").replace(/^\.pragma library\s*$/m, "");
    const ctx = {}; vm.createContext(ctx); vm.runInContext(src, ctx);
    const ok = ctx.parse(JSON.stringify({state:"recording",language:"de",ptt:"Control_L",toggle:"SUPER + ALT + D",output:"both",overlay:false}));
    const bad = [ "not json", JSON.stringify({state:"pwned"}), JSON.stringify({state:"idle",language:"<img src=x>"}) ].map(ctx.parse);
    if (!ok || ok.state !== "recording" || ok.overlay !== false || ok.language !== "de") process.exit(1);
    if (bad[0] !== null || bad[1] !== null || bad[2].language !== "") process.exit(2);
  ' "$REPO/plugin/StatusModel.js"
  check "StatusModel.js accepts valid status and rejects markup and unknown states" test "$?" = "0"
else
  skip "node not installed (StatusModel.js check)"
fi

# ---------------------------------------------------------------------------
echo "== config parsing"
# ---------------------------------------------------------------------------
reset_env
write_config <<'EOF'
# comment line

LANGUAGE="de"
MODEL='whisper-test-model'
PROMPT="Vocabulary: Hyprland, $(touch INJECT_PWNED) #tags"
EVIL=1
WAYBAR_SIGNAL=11
MIN_DURATION_MS=0
OUTPUT_MODE=bogus
EOF
check "quoted LANGUAGE is read" test "$("$DICT" lang 2>/dev/null)" = "de"
"$DICT" lang >/dev/null 2>"$TMP/cfg-warnings.txt"
check "unknown key is reported and ignored" grep -q "unknown key 'EVIL'" "$TMP/cfg-warnings.txt"
check "deprecated WAYBAR_SIGNAL is accepted silently" bash -c "! grep -q WAYBAR_SIGNAL '$TMP/cfg-warnings.txt'"
check "invalid OUTPUT_MODE is reported" grep -q "invalid OUTPUT_MODE" "$TMP/cfg-warnings.txt"
"$DICT" toggle >/dev/null 2>&1; sleep 0.3; "$DICT" toggle >/dev/null 2>&1
check "MODEL from config reaches curl" grep -qF '[model=whisper-test-model]' "$LOGS/curl.log"
check "LANGUAGE from config reaches curl" grep -q '\[language=de\]' "$LOGS/curl.log"
check "PROMPT is passed literally" grep -q 'INJECT_PWNED' "$LOGS/curl.log"
check "PROMPT command substitution was not executed" test ! -e "$TMP/INJECT_PWNED"

# ---------------------------------------------------------------------------
echo "== start -> stop path (toggle, MIN_DURATION_MS=0)"
# ---------------------------------------------------------------------------
reset_env
write_config <<'EOF'
MIN_DURATION_MS=0
EOF
"$DICT" toggle; sleep 0.3
check "status file shows recording" grep -q '"state":"recording"' "$RUN_DIR/status.json"
"$DICT" toggle
check "pw-record was started" test -s "$LOGS/pw-record.log"
check "transcript typed via wtype (trailing space)" grep -qxF 'hello world ' "$LOGS/wtype.log"
check "transcript copied via wl-copy (stdin)" grep -qxF 'hello world' "$LOGS/wl-copy.log"
check "transcript not in wl-copy argv" grep -qxF 'ARGV:' "$LOGS/wl-copy.log"
check "curl got the key via stdin config" grep -q AUTH_OK "$LOGS/curl.log"
check "key was never in curl argv" bash -c "! grep -q KEY_IN_ARGV '$LOGS/curl.log'"
check "upload is FLAC (ffmpeg stub)" grep -q 'file=@.*\.flac\]' "$LOGS/curl.log"
check "key appears in no log, notification or argv record" bash -c "! grep -rqF '$KEY' '$LOGS' '$TMP/state' '$XDG_CONFIG_HOME'"
check "transcript text is not in the dictarchy log" bash -c "! grep -qF 'hello world' '$STATE_LOG'"
check "temporary audio is removed afterwards" bash -c "! compgen -G '$RUN_DIR/job-*' >/dev/null"
check "state is idle after the cycle" test "$(state_of_status)" = "idle"
check "status file is back to idle" grep -q '"state":"idle"' "$RUN_DIR/status.json"

# ---------------------------------------------------------------------------
echo "== API key: file, setup state, key --stdin"
# ---------------------------------------------------------------------------
reset_env
unset DICTARCHY_API_KEY
write_config <<'EOF'
MIN_DURATION_MS=0
EOF
check "no key: status is setup" test "$(state_of_status)" = "setup"
"$DICT" toggle
check "no key: toggle does not record" test ! -e "$LOGS/pw-record.log"
check "no key: toggle shows 'Setup needed'" grep -q 'Setup needed' "$LOGS/notify.log"
"$DICT" start --ptt; "$DICT" stop --ptt
check "no key: push-to-talk stays silent" test "$(grep -c 'Setup needed' "$LOGS/notify.log")" = "1"
printf '%s\n' "$KEY" | "$DICT" key --stdin > "$TMP/key-out.txt" 2>&1
check "key --stdin writes the key file" test -f "$CFG_DIR/api_key"
check "api_key file has mode 600" test "$(stat -c %a "$CFG_DIR/api_key")" = "600"
check "key --stdin never echoes the key" bash -c "! grep -qF '$KEY' '$TMP/key-out.txt'"
check "after saving: status is idle" test "$(state_of_status)" = "idle"
check "after saving: status file updated" grep -q '"state":"idle"' "$RUN_DIR/status.json"
printf 'has space in it\n' | "$DICT" key --stdin >/dev/null 2>&1
check "key --stdin rejects malformed keys" test "$?" != "0"
"$DICT" toggle; sleep 0.3; "$DICT" toggle
check "key read from api_key file reaches curl via stdin" grep -q AUTH_OK "$LOGS/curl.log"
chmod 644 "$CFG_DIR/api_key"
"$DICT" toggle >/dev/null 2>&1; sleep 0.3; "$DICT" toggle 2>"$TMP/perm-warning.txt" >/dev/null
check "loose api_key permissions produce a warning" grep -q 'permissions' "$TMP/perm-warning.txt"
"$DICT" status 2>"$TMP/status-warning.txt" >/dev/null
check "status polling does not warn" test ! -s "$TMP/status-warning.txt"
chmod 600 "$CFG_DIR/api_key"

reset_env
unset DICTARCHY_API_KEY
"$DICT" key </dev/null; wait_for "$LOGS/terminal.log"
check "key without a terminal opens a floating terminal" grep -qF -- "--app-id=org.omarchy.terminal" "$LOGS/terminal.log"
check "the terminal runs 'dictarchy key'" grep -qF -- "-e $DICT_REAL key" "$LOGS/terminal.log"
rm -f "$LOGS/terminal.log"
"$DICT" setup </dev/null; wait_for "$LOGS/terminal.log"
check "setup without a key opens the key prompt" grep -qF -- "-e $DICT_REAL key" "$LOGS/terminal.log"

# ---------------------------------------------------------------------------
echo "== short press is discarded silently (MIN_DURATION_MS=1000)"
# ---------------------------------------------------------------------------
reset_env
write_config <<'EOF'
MIN_DURATION_MS=1000
EOF
"$DICT" start --ptt; "$DICT" stop --ptt
check "short press: status stays idle" test "$(state_of_status)" = "idle"
sleep 1.4   # let the push-to-talk delay timer run out after the press is already over
check "short press: no curl call" test ! -e "$LOGS/curl.log"
check "short press: no typing" test ! -e "$LOGS/wtype.log"
check "short press: no 'Recording' notification" bash -c "! grep -q Recording '$LOGS/notify.log' 2>/dev/null"

# ---------------------------------------------------------------------------
echo "== push-to-talk: visible only after MIN_DURATION_MS (MIN_DURATION_MS=300)"
# ---------------------------------------------------------------------------
reset_env
write_config <<'EOF'
MIN_DURATION_MS=300
EOF
"$DICT" start --ptt
check "ptt start: status hidden during the delay" test "$(state_of_status)" = "idle"
sleep 0.8
check "ptt hold: 'Recording' notification shown" grep -q Recording "$LOGS/notify.log"
check "ptt hold: status shows recording" test "$(state_of_status)" = "recording"
"$DICT" stop --ptt
check "ptt hold: transcript typed" grep -qxF 'hello world ' "$LOGS/wtype.log"

# ---------------------------------------------------------------------------
echo "== language cycling (scroll) and auto"
# ---------------------------------------------------------------------------
reset_env
write_config <<'EOF'
LANGUAGE=en
LANGUAGES="en de auto"
MIN_DURATION_MS=0
EOF
check "lang without argument prints current" test "$("$DICT" lang)" = "en"
check "lang next: en -> de" test "$("$DICT" lang next)" = "de"
check "lang next: de -> auto" test "$("$DICT" lang next)" = "auto"
check "lang next: auto -> en (wraps)" test "$("$DICT" lang next)" = "en"
check "lang prev: en -> auto (wraps back)" test "$("$DICT" lang prev)" = "auto"
check "lang change updates the status file" grep -q '"language":"auto"' "$RUN_DIR/status.json"
check "lang <code> sets a language" test "$("$DICT" lang fr)" = "fr"
check "lang <code> adds it to LANGUAGES" grep -qxF 'LANGUAGES="en de auto fr"' "$CFG"
check "language persists" test "$("$DICT" lang)" = "fr"
"$DICT" lang auto >/dev/null
"$DICT" toggle; sleep 0.3; "$DICT" toggle
check "auto omits the language parameter" bash -c "! grep -q 'language=' '$LOGS/curl.log'"

# ---------------------------------------------------------------------------
echo "== status JSON"
# ---------------------------------------------------------------------------
reset_env
write_config <<'EOF'
MIN_DURATION_MS=0
PTT_KEY=Control_L
PTT_MODS=""
TOGGLE_KEY=D
TOGGLE_MODS="SUPER ALT"
EOF
check "status idle is valid JSON" bash -c "$(declare -f json_valid); '$DICT' status | json_valid"
check "status lists the push-to-talk key" test "$(field_of_status ptt)" = "Control_L"
check "status lists the toggle combo" test "$(field_of_status toggle)" = "SUPER + ALT + D"
check "status lists the language" test "$(field_of_status language)" = "en"
check "status reports the overlay setting" bash -c "'$DICT' status | grep -q '\"overlay\":true}'"
"$DICT" toggle
check "status recording is valid JSON" bash -c "$(declare -f json_valid); '$DICT' status | json_valid"
check "status recording has state recording" test "$(state_of_status)" = "recording"
"$DICT" cancel >/dev/null
check "cancel removes the temporary WAV" bash -c "! compgen -G '$RUN_DIR/*.wav' >/dev/null"
check "cancel returns to idle" test "$(state_of_status)" = "idle"
"$DICT" status --write >/dev/null
check "status --write creates the status file" bash -c "$(declare -f json_valid); json_valid < '$RUN_DIR/status.json'"

# ---------------------------------------------------------------------------
echo "== API error handling"
# ---------------------------------------------------------------------------
reset_env
write_config <<'EOF'
MIN_DURATION_MS=0
EOF
export STUB_HTTP_CODE=401 STUB_BODY='{"error":{"message":"Invalid API Key"}}'
"$DICT" toggle; sleep 0.2; "$DICT" toggle
check "401: 'Invalid API key' notification" grep -qF 'Invalid API key' "$LOGS/notify.log"
check "401: nothing typed" test ! -e "$LOGS/wtype.log"
check "401: key not leaked into logs" bash -c "! grep -rqF '$KEY' '$LOGS' '$TMP/state'"
check "401: state back to idle" test "$(state_of_status)" = "idle"

reset_env
write_config <<'EOF'
MIN_DURATION_MS=0
EOF
export STUB_HTTP_CODE=500 STUB_BODY='{"error":{"message":"Model overloaded"}}'
"$DICT" toggle; sleep 0.2; "$DICT" toggle
check "500: error notification shows the API code" grep -q 'API error 500' "$LOGS/notify.log"

reset_env
write_config <<'EOF'
MIN_DURATION_MS=0
EOF
DICTARCHY_UI_LANG=de "$DICT" toggle >/dev/null; sleep 0.2
export STUB_HTTP_CODE=429
DICTARCHY_UI_LANG=de "$DICT" toggle
check "German UI: notifications follow the Omarchy language" grep -q 'Anfragelimit' "$LOGS/notify.log"
mkdir -p "$XDG_CONFIG_HOME/omarchy"; echo de > "$XDG_CONFIG_HOME/omarchy/language"
unset STUB_HTTP_CODE
env -u DICTARCHY_UI_LANG "$DICT" lang fr >/dev/null
check "German UI is read from ~/.config/omarchy/language" grep -q 'Sprache: FR' "$LOGS/notify.log"

# ---------------------------------------------------------------------------
echo "== Hyprland bindings (Lua)"
# ---------------------------------------------------------------------------
# Loads a generated bindings file with stubbed o.* and prints one line per bind.
cat > "$TMP/harness.lua" <<'EOF'
local out = {}
o = {}
hl = { unbind = function(keys) table.insert(out, "unbind|" .. keys) end }
local function opts_string(t)
  local keys = {}
  for k, v in pairs(t or {}) do table.insert(keys, k .. "=" .. tostring(v)) end
  table.sort(keys)
  return table.concat(keys, ",")
end
function o.bind_hold(keys, d1, press, d2, release, opts)
  table.insert(out, table.concat({ "hold", keys, d1, press, d2, release, opts_string(opts) }, "|"))
end
function o.rebind(keys, d, cmd, opts)
  table.insert(out, table.concat({ "rebind", keys, d, cmd, opts_string(opts) }, "|"))
end
dofile(arg[1])
for _, line in ipairs(out) do print(line) end
EOF
LUA=$(command -v lua || command -v luajit || true)

reset_env
write_config <<'EOF'
PTT_KEY=Control_L
PTT_MODS=""
TOGGLE_KEY=D
TOGGLE_MODS="SUPER ALT"
EOF
"$DICT" bindings >/dev/null
check "bindings file is written" test -f "$BIND_FILE"
check "bindings header marks the file as managed" grep -q '^-- Managed by dictarchy' "$BIND_FILE"
check "hyprctl reload and configerrors were called" bash -c "grep -qx reload '$LOGS/hyprctl.log' && grep -qx configerrors '$LOGS/hyprctl.log'"
if command -v luac >/dev/null 2>&1; then
  check "bindings file is valid Lua (luac -p)" luac -p "$BIND_FILE"
fi
if [[ -n $LUA ]]; then
  "$LUA" "$TMP/harness.lua" "$BIND_FILE" > "$TMP/binds.txt"
  check "push-to-talk: bind_hold on Control_L, non-consuming, any modifiers" \
    grep -qxF "hold|Control_L|Dictarchy: push-to-talk start|$DICT_REAL start --ptt|Dictarchy: push-to-talk stop|$DICT_REAL stop --ptt|ignore_mods=true,non_consuming=true" "$TMP/binds.txt"
  check "toggle: rebind SUPER + ALT + D" \
    grep -qxF "rebind|SUPER + ALT + D|Dictarchy: toggle dictation|$DICT_REAL toggle|" "$TMP/binds.txt"
else
  skip "lua not installed"
fi

reset_env
write_config <<'EOF'
PTT_KEY=F9
PTT_MODS="SUPER"
TOGGLE_KEY=""
EOF
"$DICT" bindings >/dev/null
if [[ -n $LUA ]]; then
  "$LUA" "$TMP/harness.lua" "$BIND_FILE" > "$TMP/binds.txt"
  check "non-modifier push-to-talk key: consuming, replaces an existing bind" \
    bash -c "grep -qxF 'unbind|SUPER + F9' '$TMP/binds.txt' && grep -q '^hold|SUPER + F9|.*|$' '$TMP/binds.txt'"
  check "empty TOGGLE_KEY produces no toggle bind" bash -c "! grep -q '^rebind' '$TMP/binds.txt'"
fi

reset_env
mkdir -p "$TMP/weird dir"
cp "$DICT" "$TMP/weird dir/dict\"archy"
"$TMP/weird dir/dict\"archy" bindings >/dev/null
if [[ -n $LUA ]]; then
  "$LUA" "$TMP/harness.lua" "$BIND_FILE" > "$TMP/binds.txt"
  check "odd install paths are quoted for Lua and the shell" \
    grep -qF "|$(printf '%q' "$TMP/weird dir/dict\"archy") toggle|" "$TMP/binds.txt"
fi

reset_env
export STUB_CONFIG_ERRORS="dictarchy.lua:3: boom"
"$DICT" bindings >/dev/null 2>&1
check "config errors after reload are reported" test "$?" != "0"
check "config errors are logged" grep -q 'hyprland config errors' "$STATE_LOG"

# ---------------------------------------------------------------------------
echo "== settings menu (stubbed omarchy-menu-select)"
# ---------------------------------------------------------------------------
reset_env
write_config <<'EOF'
OUTPUT_MODE=both
EOF
menu_answers "Output" "Clipboard only"
"$DICT" menu
check "menu: main menu lists all entries" \
  bash -c "head -n1 '$LOGS/menu.log' | grep -q 'API key' && head -n1 '$LOGS/menu.log' | grep -q 'Language' && head -n1 '$LOGS/menu.log' | grep -q 'Push-to-talk key' && head -n1 '$LOGS/menu.log' | grep -q 'Toggle key' && head -n1 '$LOGS/menu.log' | grep -q 'Output' && head -n1 '$LOGS/menu.log' | grep -q 'Test' && head -n1 '$LOGS/menu.log' | grep -q 'Log'"
check "menu: output set to clipboard" grep -qxF 'OUTPUT_MODE="clipboard"' "$CFG"

reset_env
menu_answers "Language" "Other..." "PT"
"$DICT" menu
check "menu: language via 'Other...' input" test "$("$DICT" lang)" = "pt"

reset_env
menu_answers "Language" "" "Output" "Type only"
"$DICT" menu
check "menu: dismissing a submenu returns to the main menu" grep -qxF 'OUTPUT_MODE="type"' "$CFG"

reset_env
menu_answers "Push-to-talk key" "Control_R"
"$DICT" menu
check "menu: push-to-talk key saved" grep -qxF 'PTT_KEY="Control_R"' "$CFG"
check "menu: bindings regenerated" grep -q '"Control_R"' "$BIND_FILE"

reset_env
menu_answers "Toggle key" "Other..." "super+shift+r"
"$DICT" menu
check "menu: custom toggle combo is normalized" bash -c "grep -qxF 'TOGGLE_MODS=\"SUPER SHIFT\"' '$CFG' && grep -qxF 'TOGGLE_KEY=\"R\"' '$CFG'"

reset_env
echo '[{"key":"r","modmask":65,"description":"Screen recording","dispatcher":"exec","arg":"x"}]' > "$TMP/binds.json"
export STUB_BINDS="$TMP/binds.json"
menu_answers "Toggle key" "Other..." "SUPER + SHIFT + R" "Cancel"
"$DICT" menu
check "menu: conflicting combo asks first" grep -q 'already bound: Screen recording' "$LOGS/menu.log"
check "menu: cancelling the conflict keeps the old key" bash -c "! grep -q 'TOGGLE_KEY=\"R\"' '$CFG'"

reset_env
menu_answers "Recording overlay"
"$DICT" menu
check "menu: recording overlay can be switched off" grep -qxF 'OVERLAY="false"' "$CFG"
check "menu: status reports the overlay as off" bash -c "'$DICT' status | grep -q '\"overlay\":false}'"

reset_env
menu_answers "Toggle key" "Disable"
"$DICT" menu
check "menu: toggle key can be disabled" grep -qxF 'TOGGLE_KEY=""' "$CFG"
check "menu: disabled toggle shows as empty in the status" test "$(field_of_status toggle)" = ""

reset_env
menu_answers "API key"
"$DICT" menu; wait_for "$LOGS/terminal.log"
check "menu: API key opens the key prompt in a floating terminal" grep -qF -- "-e $DICT_REAL key" "$LOGS/terminal.log"
check "menu: the API key is never asked in the menu" bash -c "! grep -q '^INPUT' '$LOGS/menu.log'"
rm -f "$LOGS/terminal.log"
menu_answers "Test"
"$DICT" menu; wait_for "$LOGS/terminal.log"
check "menu: Test opens 'dictarchy test' in a terminal" grep -qF -- "-e $DICT_REAL test" "$LOGS/terminal.log"
rm -f "$LOGS/terminal.log"
menu_answers "Log"
"$DICT" menu; wait_for "$LOGS/terminal.log"
check "menu: Log opens the log in a terminal" grep -q 'less' "$LOGS/terminal.log"

# ---------------------------------------------------------------------------
echo "== push-to-talk races and mixed modes"
# ---------------------------------------------------------------------------
reset_env
write_config <<'EOF'
MIN_DURATION_MS=0
EOF
"$DICT" stop --ptt; "$DICT" start --ptt
check "release before press: no recording is left running" test "$(state_of_status)" = "idle"
check "release before press: pw-record not started" test ! -s "$LOGS/pw-record.log"
"$DICT" start --ptt; sleep 0.3; "$DICT" stop --ptt
check "normal press after a raced tap still records" grep -qxF 'hello world ' "$LOGS/wtype.log"

reset_env
write_config <<'EOF'
MIN_DURATION_MS=0
EOF
"$DICT" toggle; sleep 0.2; "$DICT" stop --ptt
check "ptt release does not stop a toggle recording" test "$(state_of_status)" = "recording"
"$DICT" toggle
check "toggle recording is transcribed afterwards" grep -qxF 'hello world ' "$LOGS/wtype.log"

# ---------------------------------------------------------------------------
echo "== install.sh / uninstall.sh (sandbox HOME, no running shell)"
# ---------------------------------------------------------------------------
reset_env
unset DICTARCHY_API_KEY
rm -rf "$CFG_DIR"
mkdir -p "$XDG_CONFIG_HOME/hypr" "$XDG_CONFIG_HOME/omarchy"
cat > "$XDG_CONFIG_HOME/hypr/hyprland.lua" <<'EOF'
dofile((os.getenv("OMARCHY_PATH") or "/usr/share/omarchy") .. "/default/hypr/bootstrap.lua")
require("default.hypr.omarchy")
require("hypr.bindings")
EOF
cat > "$XDG_CONFIG_HOME/omarchy/shell.json" <<'EOF'
{
  "bar": { "layout": { "left": [{ "id": "omarchy.menu" }],
                       "right": [{ "id": "omarchy.tray" }, { "id": "omarchy.audio" }, { "id": "omarchy.power" }] } },
  "plugins": [],
  "version": 1
}
EOF
cp "$XDG_CONFIG_HOME/hypr/hyprland.lua" "$TMP/hyprland.orig"
cp "$XDG_CONFIG_HOME/omarchy/shell.json" "$TMP/shell.orig"

"$REPO/install.sh" </dev/null > "$TMP/install-out.txt" 2>&1
check "install: exits successfully" test "$?" = "0"
check "install: never asks for the API key" bash -c "! grep -qi 'input hidden' '$TMP/install-out.txt' && test ! -e '$CFG_DIR/api_key'"
check "install: binary installed" test -x "$HOME/.local/bin/dictarchy"
check "install: config created" test -f "$CFG"
PLUGIN_DIR="$XDG_CONFIG_HOME/omarchy/plugins/io.github.vyrix44.dictarchy"
check "install: widget copied" bash -c "test -f '$PLUGIN_DIR/manifest.json' && test -f '$PLUGIN_DIR/BarWidget.qml' && test -f '$PLUGIN_DIR/i18n/de.json'"
check "install: widget contains no symlinks" test -z "$(find "$PLUGIN_DIR" -type l)"
check "install: hyprland.lua backed up" bash -c "compgen -G '$XDG_CONFIG_HOME/hypr/hyprland.lua.dictarchy-backup-*' >/dev/null"
check "install: marker block added" bash -c "grep -qxF -- '-- >>> dictarchy >>>' '$XDG_CONFIG_HOME/hypr/hyprland.lua' && grep -qxF -- '-- <<< dictarchy <<<' '$XDG_CONFIG_HOME/hypr/hyprland.lua'"
if command -v luac >/dev/null 2>&1; then
  check "install: hyprland.lua is still valid Lua" luac -p "$XDG_CONFIG_HOME/hypr/hyprland.lua"
fi
check "install: dictarchy.lua generated" test -f "$BIND_FILE"
check "install: shell.json backed up" bash -c "compgen -G '$XDG_CONFIG_HOME/omarchy/shell.json.dictarchy-backup-*' >/dev/null"
check "install: widget placed left of omarchy.audio" \
  test "$(jq -c '[.bar.layout.right[].id]' "$XDG_CONFIG_HOME/omarchy/shell.json")" = '["omarchy.tray","io.github.vyrix44.dictarchy","omarchy.audio","omarchy.power"]'
check "install: the rest of shell.json is unchanged" \
  test "$(jq -S 'del(.bar.layout.right[] | select(.id == "io.github.vyrix44.dictarchy"))' "$XDG_CONFIG_HOME/omarchy/shell.json")" = "$(jq -S . "$TMP/shell.orig")"
check "install: status starts as 'setup'" test "$("$HOME/.local/bin/dictarchy" status | jq -r .state)" = "setup"

"$REPO/install.sh" </dev/null > "$TMP/install-out2.txt" 2>&1
check "install again: still exactly one marker block" test "$(grep -cxF -- '-- >>> dictarchy >>>' "$XDG_CONFIG_HOME/hypr/hyprland.lua")" = "1"
check "install again: no shell restart when the widget files are the same" test ! -e "$LOGS/restart-shell.log"
rm -f "$PLUGIN_DIR/Service.qml"   # an older install without the overlay service
STUB_SHELL_UP=1 "$REPO/install.sh" </dev/null >/dev/null 2>&1
check "upgrade adding widget files restarts the running shell" test -s "$LOGS/restart-shell.log"
check "install again: still exactly one bar entry" test "$(jq '[.bar.layout[][] | select(.id == "io.github.vyrix44.dictarchy")] | length' "$XDG_CONFIG_HOME/omarchy/shell.json")" = "1"

"$REPO/uninstall.sh" --yes > "$TMP/uninstall-out.txt" 2>&1
check "uninstall: exits successfully" test "$?" = "0"
check "uninstall: hyprland.lua is back to the original" cmp -s "$XDG_CONFIG_HOME/hypr/hyprland.lua" "$TMP/hyprland.orig"
check "uninstall: shell.json is back to the original" \
  test "$(jq -S . "$XDG_CONFIG_HOME/omarchy/shell.json")" = "$(jq -S . "$TMP/shell.orig")"
check "uninstall: widget, bindings and binary removed" \
  bash -c "test ! -e '$PLUGIN_DIR' && test ! -e '$BIND_FILE' && test ! -e '$HOME/.local/bin/dictarchy'"
check "uninstall --yes keeps the config" test -f "$CFG"

reset_env
mkdir -p "$XDG_CONFIG_HOME/hypr" "$XDG_CONFIG_HOME/omarchy"
echo 'require("hypr.bindings")' > "$XDG_CONFIG_HOME/hypr/hyprland.lua"
echo '{"bar":{"layout":{"right":[{"id":"omarchy.power"}]}},"version":1}' > "$XDG_CONFIG_HOME/omarchy/shell.json"
"$REPO/install.sh" </dev/null >/dev/null 2>&1
check "install without omarchy.audio: widget goes first in the right section" \
  test "$(jq -c '[.bar.layout.right[].id]' "$XDG_CONFIG_HOME/omarchy/shell.json")" = '["io.github.vyrix44.dictarchy","omarchy.power"]'

reset_env
mkdir -p "$XDG_CONFIG_HOME/hypr"
echo 'require("hypr.bindings")' > "$XDG_CONFIG_HOME/hypr/hyprland.lua"
STUB_OMARCHY_VERSION=3.1.0 "$REPO/install.sh" </dev/null > "$TMP/install-old.txt" 2>&1
check "install refuses Omarchy 3.x" bash -c "test $? != 0 && grep -q 'needs Omarchy 4.5' '$TMP/install-old.txt'"

# ---------------------------------------------------------------------------
echo "== misc"
# ---------------------------------------------------------------------------
reset_env
check "cancel while idle is a no-op" test "$("$DICT" cancel)" = "Nothing to cancel."
"$DICT" start --bogus >/dev/null 2>&1
check "unknown option exits with status 2" test "$?" = "2"
check "version" test "$("$DICT" version)" = "dictarchy 0.2.0"
check "help lists the menu" bash -c "'$DICT' help | grep -q 'menu'"
check "manifest version matches" test "$(jq -r .version "$REPO/plugin/manifest.json")" = "0.2.0"

# ---------------------------------------------------------------------------
echo
echo "Result: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  exit 1
fi
