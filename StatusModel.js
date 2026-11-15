.pragma library

// Parses the JSON that `dictarchy status` prints (and writes to
// $XDG_RUNTIME_DIR/dictarchy/status.json). The CLI is ours, but the input is
// still treated as untrusted: only known states and short, plain values pass.
// Returns null for anything that is not a valid status.

var states = ["idle", "recording", "transcribing", "error", "setup"]

function bounded(value, pattern) {
  if (typeof value !== "string" || value.length > 64) return ""
  return pattern.test(value) ? value : ""
}

function parse(raw) {
  var data
  try {
    data = JSON.parse(String(raw || "").trim())
  } catch (e) {
    return null
  }
  if (!data || typeof data !== "object" || states.indexOf(data.state) === -1) return null
  return {
    state: data.state,
    language: bounded(data.language, /^([a-z]{2,3}|auto)$/),
    ptt: bounded(data.ptt, /^[A-Za-z0-9_ +]*$/),
    toggle: bounded(data.toggle, /^[A-Za-z0-9_ +]*$/),
    overlay: data.overlay !== false
  }
}
