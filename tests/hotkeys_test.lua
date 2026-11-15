-- Tests for the hotkey engine (hypr/dictarchy.lua). Run from the repository root:
--   lua tests/hotkeys_test.lua
-- Plain Lua, no Hyprland needed: hl is a stub that records every call.

local ENGINE = "hypr/dictarchy.lua"

local failures, checks = 0, 0
local function check(cond, msg)
  checks = checks + 1
  if not cond then
    failures = failures + 1
    print("FAIL: " .. msg)
  end
end

-- ── Plan ─────────────────────────────────────────────────────────────────
local P = dofile(ENGINE)   -- no hl yet: only the pure part is used
check(rawget(_G, "dictarchy_hotkeys") == nil, "without hl the engine installs no global")

local function find(plan, description)
  for _, b in ipairs(plan.binds) do
    if b.description == description then return b end
  end
end

local function has(list, value)
  for _, v in ipairs(list) do
    if v == value then return true end
  end
  return false
end

do
  local plan = P.plan({ command = "'/p/dictarchy'", ptt = { mods = "", key = "Alt_L" }, toggle = { mods = "SUPER ALT", key = "D" } })
  check(#plan.errors == 0, "default keys plan without errors")
  check(#plan.binds == 3, "default keys: press, release and toggle")
  local press, release, toggle = find(plan, P.PTT_START), find(plan, P.PTT_STOP), find(plan, P.TOGGLE)
  check(press and press.keys == "Alt_L" and press.command == "'/p/dictarchy' start --ptt", "push-to-talk press runs start --ptt")
  check(press.options.non_consuming == true and press.options.ignore_mods == true, "bare modifier press: non-consuming, any modifiers")
  check(not press.options.release, "the press half is not a release bind")
  check(release.command == "'/p/dictarchy' stop --ptt", "push-to-talk release runs stop --ptt")
  check(release.options.release and release.options.transparent and release.options.ignore_mods and release.options.non_consuming,
    "release half: release, transparent, ignore_mods, non_consuming")
  check(toggle.keys == "SUPER + ALT + D" and toggle.command == "'/p/dictarchy' toggle", "toggle on SUPER + ALT + D")
  check(#plan.combos == 2 and has(plan.combos, "Alt_L") and has(plan.combos, "SUPER + ALT + D"), "each combination is listed once")
end

do
  local plan = P.plan({ command = "x", ptt = { mods = "SUPER", key = "F9" } })
  local press = find(plan, P.PTT_START)
  check(press.keys == "SUPER + F9", "push-to-talk with modifiers")
  check(not press.options.non_consuming and not press.options.ignore_mods, "ordinary push-to-talk key is consuming and exact")
  check(find(plan, P.TOGGLE) == nil, "no toggle spec, no toggle bind")
end

do
  local plan = P.plan({ command = "x", ptt = { mods = "CTRL", key = "Shift_L" } })
  local press = find(plan, P.PTT_START)
  check(press.options.non_consuming and not press.options.ignore_mods, "modifier key with modifiers: non-consuming, exact modifiers")
end

do
  local plan = P.plan({ command = "x", ptt = { mods = "", key = "" }, toggle = { mods = "", key = "" } })
  check(#plan.binds == 0 and #plan.errors == 0, "empty keys disable both hotkeys")
end

do
  local plan = P.plan({ command = "x", ptt = { mods = "HYPER", key = "F9" }, toggle = { mods = "SUPER", key = "a;b" } })
  check(#plan.binds == 0 and #plan.errors == 2, "unknown modifiers and odd key names are refused")
end

do
  local plan = P.plan({ command = "x", ptt = { mods = "SUPER", key = "F9" }, toggle = { mods = "SUPER", key = "F9" } })
  check(#plan.binds == 2 and #plan.errors == 1, "a toggle on the push-to-talk combo is refused, push-to-talk stays")
end

check(#P.plan({}).errors == 1 and #P.plan({}).binds == 0, "no command, no binds")

-- ── Binding against a stub hl ────────────────────────────────────────────
-- Like Hyprland 0.56: hl.unbind removes every bind on a combination, a config
-- reload frees all binds but keeps the Lua state, and the handle hl.bind returns
-- must never be used (after a reload it points at freed memory).
local hl_binds, log, foreign_id
local function new_hl()
  hl_binds, log = {}, { unbinds = {}, execs = {} }
  hl = {
    dsp = { exec_cmd = function(cmd) return { exec = cmd } end },
    exec_cmd = function(cmd) log.execs[#log.execs + 1] = cmd end,
    unbind = function(keys)
      log.unbinds[#log.unbinds + 1] = keys
      for i = #hl_binds, 1, -1 do
        if hl_binds[i].keys == keys then table.remove(hl_binds, i) end
      end
    end,
    bind = function(keys, handler, options)
      hl_binds[#hl_binds + 1] = { keys = keys, handler = handler, options = options }
      return setmetatable({}, { __index = function(_, k) error("bind handle used: " .. tostring(k)) end })
    end,
  }
end
local function reload() hl_binds = {} end   -- what a config reload does to binds
local function ours()
  local n = 0
  for _, b in ipairs(hl_binds) do
    if tostring(b.options.description or ""):find("^Dictarchy") then n = n + 1 end
  end
  return n
end
local function foreign(keys)
  hl_binds[#hl_binds + 1] = { keys = keys, options = { description = "Other app" } }
end
local function has_foreign(keys)
  for _, b in ipairs(hl_binds) do
    if b.keys == keys and b.options.description == "Other app" then return true end
  end
  return false
end

local spec = { command = "dictarchy", ptt = { mods = "", key = "Alt_L" }, toggle = { mods = "SUPER ALT", key = "D" } }
local ok, err

new_hl()
foreign("SUPER + ALT + D")
dofile(ENGINE)
local M = dictarchy_hotkeys
check(M ~= nil, "loading with hl installs dictarchy_hotkeys")
ok, err = pcall(M.apply, "owner-a", spec)
check(ok, "apply succeeds and never touches a bind handle: " .. tostring(err))
check(ours() == 3 and #hl_binds == 3, "apply makes three binds and replaces the foreign one on the toggle combo")
check(hl_binds[1].options.description == P.PTT_START, "binds carry their description")

-- Push-to-talk hold logic.
local press_handler, release_handler, toggle_handler = hl_binds[1].handler, hl_binds[2].handler, hl_binds[3].handler
check(type(toggle_handler) == "table" and toggle_handler.exec == "dictarchy toggle", "toggle bind dispatches exec_cmd")
release_handler()
check(#log.execs == 0, "a release without its press does nothing")
press_handler(); release_handler(); release_handler()
check(#log.execs == 2 and log.execs[1] == "dictarchy start --ptt" and log.execs[2] == "dictarchy stop --ptt",
  "press then release runs start and stop once")

-- Re-applying, also from a freshly loaded copy of the file, replaces the binds.
ok, err = pcall(M.apply, nil, spec)
check(ok and ours() == 3, "applying again leaves exactly three binds")
dofile(ENGINE)
M = dictarchy_hotkeys
ok, err = pcall(M.apply, nil, { command = "dictarchy", ptt = { mods = "", key = "Control_R" } })
check(ok, "re-apply from a reloaded file succeeds: " .. tostring(err))
check(ours() == 2 and hl_binds[1].keys == "Control_R", "the old combinations are unbound, only the new binds remain")

-- A config reload frees the binds and gives the old combination back to the config.
reload()
foreign("Control_R")
ok, err = pcall(M.apply, nil, spec, true)
check(ok and ours() == 3, "after a reload (fresh) the binds are made again: " .. tostring(err))
check(has_foreign("Control_R"), "fresh: a combination bound before the reload is not unbound")
reload()
ok, err = pcall(M.apply, nil, spec)
check(ok and ours() == 3, "a reload the CLI missed (not fresh) is no crash either: " .. tostring(err))

-- clear() honours the owner.
M.clear("owner-b")
check(ours() == 3, "clear from another owner leaves the binds alone")
M.clear("owner-a")
check(ours() == 0 and #M.combos() == 0, "clear from the owner (kept across re-applies) removes them")
local unbinds = #log.unbinds
M.clear("owner-a")
M.clear()
check(#log.unbinds == unbinds, "clearing again unbinds nothing")
ok = pcall(M.apply, "owner-c", spec)
M.clear()
check(ok and ours() == 0, "clear without an owner always removes the binds")

-- A state left by an older engine that kept bind handles: they are never touched.
new_hl()
dictarchy_hotkeys = { _state = { owner = "x", handles = {
  setmetatable({}, { __index = function() error("stale handle used") end }) } } }
dofile(ENGINE)
M = dictarchy_hotkeys
ok, err = pcall(M.apply, nil, spec)
check(ok and ours() == 3, "stale handles from an older engine are dropped untouched: " .. tostring(err))
M.clear("x")
check(ours() == 0, "and its owner is kept")

-- A bind Hyprland refuses is reported, the others are still made.
new_hl()
dofile(ENGINE)
M = dictarchy_hotkeys
local real_bind = hl.bind
hl.bind = function(keys, ...)
  if keys == "SUPER + ALT + D" then error("no such key") end
  return real_bind(keys, ...)
end
ok, err = pcall(M.apply, "owner-d", spec)
check(not ok and tostring(err):find("cannot bind SUPER %+ ALT %+ D") ~= nil, "a refused bind raises an error naming it")
check(ours() == 2, "the push-to-talk binds are made anyway")
ok, err = pcall(M.apply, "owner-d", { command = "dictarchy", ptt = { mods = "HYPER", key = "F9" } })
check(not ok and tostring(err):find("invalid push%-to%-talk key") ~= nil, "an invalid key raises an error")
check(ours() == 0, "and the previous binds are gone")

print(string.format("%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
