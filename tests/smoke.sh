#!/usr/bin/env bash
# Stub-based smoke test for dictarchy. Needs no audio device, network, Wayland or Hyprland:
# every external tool (pw-record, curl, wtype, wl-copy, notify-send, pkill, hyprctl, ffmpeg)
# is replaced by a stub on PATH that records its calls into a temporary directory.
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DICT="$REPO/bin/dictarchy"
DICT_REAL=$(readlink -f "$DICT")
readonly KEY="gsk_TESTKEY_0123456789"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
readonly STUB_BIN="$TMP/stubs" LOGS="$TMP/logs"
mkdir -p "$STUB_BIN" "$LOGS" "$TMP/home" "$TMP/config" "$TMP/state" "$TMP/run"
chmod 700 "$TMP/run"

export HOME="$TMP/home"
export XDG_CONFIG_HOME="$TMP/config"
export XDG_STATE_HOME="$TMP/state"
export XDG_RUNTIME_DIR="$TMP/run"
export STUB_LOG="$LOGS"
export STUB_EXPECT_KEY="$KEY"
export PATH="$STUB_BIN:/usr/bin:/bin"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok    $*"; }
failed() { FAIL=$((FAIL + 1)); echo "  FAIL  $*"; }
check() {  # DESCRIPTION COMMAND...
  local desc=$1
  shift
  if "$@"; then pass "$desc"; else failed "$desc"; fi
}

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
printf '%s' "${STUB_BODY:-hello world}" > "$out"
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

make_stub pkill <<'EOF'
printf '%s\n' "$*" >> "$STUB_LOG/pkill.log"
EOF

make_stub hyprctl <<'EOF'
printf '%s\n' "$*" >> "$STUB_LOG/hyprctl.log"
if [[ ${1:-} == binds ]]; then echo '[]'; fi
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

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
CFG_DIR="$TMP/config/dictarchy"
CFG="$CFG_DIR/config"
RUN_DIR="$TMP/run/dictarchy"
STATE_LOG="$TMP/state/dictarchy/dictarchy.log"

reset_env() {
  if [[ -f $RUN_DIR/pid ]]; then
    local pid
    pid=$(cat "$RUN_DIR/pid" 2>/dev/null || true)
    if [[ -n $pid ]]; then kill "$pid" 2>/dev/null || true; fi
  fi
  rm -rf "$CFG_DIR" "$TMP/state/dictarchy" "$RUN_DIR" "$TMP/config/hypr"
  rm -f "$LOGS"/*.log
  rm -f "$TMP/INJECT_PWNED"
  unset STUB_HTTP_CODE STUB_BODY STUB_MAX_VOLUME GROQ_API_KEY
  export DICTARCHY_API_KEY="$KEY"
  mkdir -p "$CFG_DIR"
  cd "$TMP" || exit 1
}

write_config() {  # reads the config body from stdin
  cat > "$CFG"
}

log_has() {  # FILE PATTERN (fixed string, whole line)
  [[ -f $LOGS/$1 ]] && grep -qxF -- "$2" "$LOGS/$1"
}

any_contains() {  # PATTERN - searches every stub log and the dictarchy log for a fixed string
  grep -rqF -- "$1" "$LOGS" "$TMP/state/dictarchy" 2>/dev/null
}

class_of_status() { "$DICT" status | sed -n 's/.*"class":"\([a-z]*\)".*/\1/p'; }

json_valid() {  # stdin: must be one JSON object
  if have_python; then
    python3 -c 'import json,sys; obj=json.loads(sys.stdin.read()); assert isinstance(obj, dict)' 2>/dev/null
  else
    grep -qE '^\{"text":".*","tooltip":".*","class":"[a-z]+","alt":"[a-z]+"\}$'
  fi
}

have_python() { command -v python3 >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
echo "== syntax"
# ---------------------------------------------------------------------------
for script in "$REPO/bin/dictarchy" "$REPO/install.sh" "$REPO/uninstall.sh" "$REPO/tests/smoke.sh"; do
  check "bash -n $(basename "$script")" bash -n "$script"
done
if command -v shellcheck >/dev/null 2>&1; then
  check "shellcheck bin/dictarchy" shellcheck -x "$REPO/bin/dictarchy"
else
  echo "  skip  shellcheck not installed"
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
MIN_DURATION_MS=0
OUTPUT_MODE=bogus
EOF
check "quoted LANGUAGE is read" test "$("$DICT" lang 2>/dev/null)" = "de"
"$DICT" lang >/dev/null 2>"$TMP/cfg-warnings.txt"
check "unknown key is reported and ignored" grep -q "unknown key 'EVIL'" "$TMP/cfg-warnings.txt"
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
"$DICT" toggle; sleep 0.3; "$DICT" toggle
check "pw-record was started" test -s "$LOGS/pw-record.log"
check "transcript typed via wtype (trailing space)" grep -qxF 'hello world ' "$LOGS/wtype.log"
check "transcript copied via wl-copy (stdin)" grep -qxF 'hello world' "$LOGS/wl-copy.log"
check "transcript not in wl-copy argv" grep -qxF 'ARGV:' "$LOGS/wl-copy.log"
check "curl got the key via stdin config" grep -q AUTH_OK "$LOGS/curl.log"
check "key was never in curl argv" bash -c "! grep -q KEY_IN_ARGV '$LOGS/curl.log'"
check "upload is FLAC (ffmpeg stub)" grep -q 'file=@.*\.flac\]' "$LOGS/curl.log"
check "key appears in no log, notification or argv record" bash -c "! grep -rqF '$KEY' '$LOGS' '$TMP/state' '$TMP/config'"
check "transcript text is not in the dictarchy log" bash -c "! grep -qF 'hello world' '$STATE_LOG'"
check "temporary audio is removed afterwards" bash -c "! compgen -G '$RUN_DIR/job-*' >/dev/null"
check "state is idle after the cycle" test "$(class_of_status)" = "idle"

# ---------------------------------------------------------------------------
echo "== API key from file (no environment variable)"
# ---------------------------------------------------------------------------
reset_env
unset DICTARCHY_API_KEY
write_config <<'EOF'
MIN_DURATION_MS=0
EOF
(umask 077; printf '%s\n' "$KEY" > "$CFG_DIR/api_key")
chmod 600 "$CFG_DIR/api_key"
"$DICT" toggle; sleep 0.3; "$DICT" toggle
check "key read from api_key file reaches curl via stdin" grep -q AUTH_OK "$LOGS/curl.log"
chmod 644 "$CFG_DIR/api_key"
unset DICTARCHY_API_KEY
"$DICT" toggle >/dev/null 2>&1; sleep 0.3; "$DICT" toggle 2>"$TMP/perm-warning.txt" >/dev/null
check "loose api_key permissions produce a warning" grep -q 'permissions' "$TMP/perm-warning.txt"
chmod 600 "$CFG_DIR/api_key"

# ---------------------------------------------------------------------------
echo "== short press is discarded silently (MIN_DURATION_MS=1000)"
# ---------------------------------------------------------------------------
reset_env
write_config <<'EOF'
MIN_DURATION_MS=1000
EOF
"$DICT" start --ptt; "$DICT" stop --ptt
check "short press: status stays idle" test "$(class_of_status)" = "idle"
sleep 1.4   # let the push-to-talk delay timer run out after the press is already over
check "short press: no curl call" test ! -e "$LOGS/curl.log"
check "short press: no typing" test ! -e "$LOGS/wtype.log"
check "short press: no 'Recording' notification" bash -c "! grep -q Recording '$LOGS/notify.log' 2>/dev/null"
check "short press: state idle afterwards" test "$(class_of_status)" = "idle"

# ---------------------------------------------------------------------------
echo "== push-to-talk: visible only after MIN_DURATION_MS (MIN_DURATION_MS=300)"
# ---------------------------------------------------------------------------
reset_env
write_config <<'EOF'
MIN_DURATION_MS=300
EOF
"$DICT" start --ptt
check "ptt start: status hidden during the delay" test "$(class_of_status)" = "idle"
sleep 0.8
check "ptt hold: 'Recording' notification shown" grep -q Recording "$LOGS/notify.log"
check "ptt hold: status shows recording" test "$(class_of_status)" = "recording"
"$DICT" stop --ptt
check "ptt hold: transcript typed" grep -qxF 'hello world ' "$LOGS/wtype.log"

# ---------------------------------------------------------------------------
echo "== language cycling and auto"
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
check "lang <code> sets a language" test "$("$DICT" lang fr)" = "fr"
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
EOF
check "status idle is valid JSON" bash -c "$(declare -f json_valid have_python); '$DICT' status | json_valid"
check "status idle has class idle" test "$(class_of_status)" = "idle"
"$DICT" toggle
check "status recording is valid JSON" bash -c "$(declare -f json_valid have_python); '$DICT' status | json_valid"
check "status recording has class recording" test "$(class_of_status)" = "recording"
check "status text shows the language" bash -c "'$DICT' status | grep -q 'EN'"
"$DICT" cancel >/dev/null
check "cancel removes the temporary WAV" bash -c "! compgen -G '$RUN_DIR/*.wav' >/dev/null"
check "cancel returns to idle" test "$(class_of_status)" = "idle"

# ---------------------------------------------------------------------------
echo "== API error handling"
# ---------------------------------------------------------------------------
reset_env
write_config <<'EOF'
MIN_DURATION_MS=0
EOF
export STUB_HTTP_CODE=401 STUB_BODY='{"error":{"message":"Invalid API Key"}}'
"$DICT" toggle; sleep 0.2; "$DICT" toggle
check "401: 'Invalid API key' notification" grep -qF 'Invalid API key - run dictarchy setup' "$LOGS/notify.log"
check "401: nothing typed" test ! -e "$LOGS/wtype.log"
check "401: key not leaked into logs" bash -c "! grep -rqF '$KEY' '$LOGS' '$TMP/state'"
check "401: state back to idle" test "$(class_of_status)" = "idle"

reset_env
write_config <<'EOF'
MIN_DURATION_MS=0
EOF
export STUB_HTTP_CODE=500 STUB_BODY='{"error":{"message":"Model overloaded"}}'
"$DICT" toggle; sleep 0.2; "$DICT" toggle
check "500: error notification shows the API code" grep -q 'API error 500' "$LOGS/notify.log"

# ---------------------------------------------------------------------------
echo "== Hyprland bindings"
# ---------------------------------------------------------------------------
reset_env
write_config <<'EOF'
PTT_KEY=Control_L
PTT_MODS=""
TOGGLE_KEY=D
TOGGLE_MODS="SUPER ALT"
EOF
"$DICT" bindings >/dev/null
BIND_FILE="$TMP/config/hypr/dictarchy.conf"
check "bindings file is written" test -f "$BIND_FILE"
check "push-to-talk press binding (bindn)" grep -qxF "bindn = , Control_L, exec, $DICT_REAL start --ptt" "$BIND_FILE"
check "push-to-talk release binding adds CTRL (bindrn)" grep -qxF "bindrn = CTRL, Control_L, exec, $DICT_REAL stop --ptt" "$BIND_FILE"
check "toggle binding" grep -qxF "bindd = SUPER ALT, D, Dictarchy toggle dictation, exec, $DICT_REAL toggle" "$BIND_FILE"
check "bindings header marks the file as managed" grep -q '^# managed by dictarchy, edit config instead' "$BIND_FILE"
check "hyprctl reload was called" grep -qxF 'reload' "$LOGS/hyprctl.log"

reset_env
write_config <<'EOF'
PTT_KEY=Super_L
PTT_MODS="SUPER"
TOGGLE_KEY=""
EOF
"$DICT" bindings >/dev/null
check "modifier release mask is de-duplicated (SUPER)" grep -qxF "bindrn = SUPER, Super_L, exec, $DICT_REAL stop --ptt" "$TMP/config/hypr/dictarchy.conf"
check "empty TOGGLE_KEY produces no toggle bind" bash -c "! grep -q bindd '$TMP/config/hypr/dictarchy.conf'"

# ---------------------------------------------------------------------------
echo "== setup (piped input: key, PTT key, PTT mods, toggle key, toggle mods)"
# ---------------------------------------------------------------------------
reset_env
unset DICTARCHY_API_KEY
printf '%s\n' "$KEY" "Control_L" "" "" "" | "$DICT" setup > "$TMP/setup-out.txt" 2>&1
check "setup writes the API key file" test -f "$CFG_DIR/api_key"
check "api_key file has mode 600" test "$(stat -c %a "$CFG_DIR/api_key")" = "600"
check "setup output never echoes the key" bash -c "! grep -qF '$KEY' '$TMP/setup-out.txt'"
check "setup writes PTT_KEY to config" grep -qxF 'PTT_KEY="Control_L"' "$CFG"
check "setup regenerates bindings" grep -q 'bindn = , Control_L' "$TMP/config/hypr/dictarchy.conf"

# ---------------------------------------------------------------------------
echo "== push-to-talk races and mixed modes"
# ---------------------------------------------------------------------------
reset_env
write_config <<'EOF'
MIN_DURATION_MS=0
EOF
"$DICT" stop --ptt; "$DICT" start --ptt
check "release before press: no recording is left running" test "$(class_of_status)" = "idle"
check "release before press: pw-record not started" test ! -s "$LOGS/pw-record.log"
"$DICT" start --ptt; sleep 0.3; "$DICT" stop --ptt
check "normal press after a raced tap still records" grep -qxF 'hello world ' "$LOGS/wtype.log"

reset_env
write_config <<'EOF'
MIN_DURATION_MS=0
EOF
"$DICT" toggle; sleep 0.2; "$DICT" stop --ptt
check "ptt release does not stop a toggle recording" test "$(class_of_status)" = "recording"
"$DICT" toggle
check "toggle recording is transcribed afterwards" grep -qxF 'hello world ' "$LOGS/wtype.log"
"$DICT" waybar > "$TMP/waybar.txt"
check "waybar snippet uses the absolute path" grep -qF "\"exec\": \"$DICT_REAL status\"" "$TMP/waybar.txt"

# ---------------------------------------------------------------------------
echo "== cancel while idle, invalid arguments, misc"
# ---------------------------------------------------------------------------
reset_env
write_config <<'EOF'
MIN_DURATION_MS=0
EOF
check "cancel while idle is a no-op" test "$("$DICT" cancel)" = "Nothing to cancel."
"$DICT" start --bogus >/dev/null 2>&1
check "unknown option exits with status 2" test "$?" = "2"
check "version" test "$("$DICT" version)" = "dictarchy 0.1.0"
check "waybar snippet contains the module" bash -c "'$DICT' waybar | grep -q 'custom/dictarchy'"
check "help lists toggle" bash -c "'$DICT' help | grep -q 'toggle'"

# ---------------------------------------------------------------------------
echo
echo "Result: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
  exit 1
fi
