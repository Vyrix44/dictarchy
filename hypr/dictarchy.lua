-- dictarchy hotkeys: push-to-talk and toggle, bound inside Hyprland.
--
-- This file runs inside Hyprland's Lua config state. Nothing is written to the
-- user's Hyprland config: the dictarchy CLI loads it over hyprctl and passes the
-- keys from ~/.config/dictarchy/config,
--
--   hyprctl dispatch "(function() dofile('<this file>')
--     dictarchy_hotkeys.apply('<owner>', { command = ..., ptt = ..., toggle = ... })
--     return hl.dsp.exec_cmd('true') end)()"
--
-- and the plugin's shell service runs that ("dictarchy bindings --owner <token>")
-- when it starts and after every Hyprland config reload, which wipes this state.
-- When the plugin is disabled or removed, the service calls clear() with the
-- same token, so a stop from an older service instance (a shell reload) can't
-- remove the binds a newer one made.
--
-- The handles hl.bind returns are never kept. Hyprland 0.56 frees every bind on
-- a config reload but keeps the Lua state, and using a freed bind's handle
-- (remove(), or reading a field) crashes the compositor. dictarchy's binds are
-- removed by key combination with hl.unbind instead, as Omarchy's o.rebind does
-- on every config load. That also clears other binds on those combinations,
-- which the menu asks about before it takes a key.

local M = {}

M.PTT_START = "Dictarchy: push-to-talk start"
M.PTT_STOP = "Dictarchy: push-to-talk stop"
M.TOGGLE = "Dictarchy: toggle dictation"

local MODIFIER_KEYS = {
  Control_L = true, Control_R = true, Shift_L = true, Shift_R = true,
  Alt_L = true, Alt_R = true, Super_L = true, Super_R = true,
  Meta_L = true, Meta_R = true, ISO_Level3_Shift = true,
}
local MODS = { SUPER = true, CTRL = true, ALT = true, SHIFT = true }

-- ── Plan (pure; covered by tests/hotkeys_test.lua) ───────────────────────

function M.is_modifier_key(key)
  return MODIFIER_KEYS[key] == true
end

-- "SUPER ALT", "D" -> "SUPER + ALT + D". Nil for an unknown modifier or a key
-- with anything but letters, digits and underscores.
function M.combo(mods, key)
  if type(key) ~= "string" or not key:match("^[%w_]+$") then return nil end
  local parts = {}
  for mod in tostring(mods or ""):gmatch("%S+") do
    if not MODS[mod] then return nil end
    parts[#parts + 1] = mod
  end
  parts[#parts + 1] = key
  return table.concat(parts, " + ")
end

local function copy(t)
  local c = {}
  for k, v in pairs(t) do c[k] = v end
  return c
end

-- Turns the spec from the CLI into the binds to make:
--   { binds = { { keys, description, command, options, kind } ... },
--     combos = { combo ... }, errors = { message ... } }
-- kind is "press" (a plain bind), or "hold" / "release" for the two halves of
-- push-to-talk. combos lists each key combination once.
function M.plan(spec)
  local result = { binds = {}, combos = {}, errors = {} }
  spec = spec or {}
  local command = spec.command
  if type(command) ~= "string" or command == "" then
    result.errors[#result.errors + 1] = "no command given"
    return result
  end
  local used = {}

  local ptt = spec.ptt
  if ptt and ptt.key and ptt.key ~= "" then
    local keys = M.combo(ptt.mods, ptt.key)
    if not keys then
      result.errors[#result.errors + 1] = "invalid push-to-talk key: " .. tostring(ptt.mods) .. " " .. tostring(ptt.key)
    else
      local options = {}
      if M.is_modifier_key(ptt.key) then
        -- A modifier's mask changes between press and release, and it is part
        -- of every shortcut: the press must not take it from other binds or
        -- apps (Ctrl+C keeps working), and a bare modifier fires with any
        -- other modifiers held. Short taps are discarded by the CLI.
        options.non_consuming = true
        if (ptt.mods or "") == "" then options.ignore_mods = true end
      end
      -- Hyprland skips a plain release bind once another key was released
      -- during the hold or the modifiers changed, so the release half is
      -- transparent, ignores modifiers and runs only after its own press (the
      -- same scheme as Omarchy's o.bind_hold). It is non-consuming: a release
      -- bind that ignores modifiers would otherwise take the key from apps.
      local release = copy(options)
      release.release, release.transparent = true, true
      release.ignore_mods, release.non_consuming = true, true
      result.binds[#result.binds + 1] = {
        keys = keys, description = M.PTT_START, command = command .. " start --ptt", options = options, kind = "hold",
      }
      result.binds[#result.binds + 1] = {
        keys = keys, description = M.PTT_STOP, command = command .. " stop --ptt", options = release, kind = "release",
      }
      result.combos[#result.combos + 1] = keys
      used[keys] = true
    end
  end

  local toggle = spec.toggle
  if toggle and toggle.key and toggle.key ~= "" then
    local keys = M.combo(toggle.mods, toggle.key)
    if not keys then
      result.errors[#result.errors + 1] = "invalid toggle key: " .. tostring(toggle.mods) .. " " .. tostring(toggle.key)
    elseif used[keys] then
      result.errors[#result.errors + 1] = "toggle key " .. keys .. " is the push-to-talk key; toggle not bound"
    else
      result.combos[#result.combos + 1] = keys
      result.binds[#result.binds + 1] = {
        keys = keys, description = M.TOGGLE, command = command .. " toggle", options = {}, kind = "press",
      }
    end
  end

  return result
end

-- ── Binding (needs Hyprland's hl) ────────────────────────────────────────

local previous = rawget(_G, "dictarchy_hotkeys")
-- Loading the file again (every apply does) keeps the combinations the previous
-- copy bound and its owner. Anything else an older copy kept (bind handles, up
-- to 0.5.0-dev) is dropped untouched: those binds may already be freed.
local old = (previous and previous._state) or {}
local state = { combos = old.combos or {}, owner = old.owner }
M._state = state

local function unbind_all(extra)
  local seen = {}
  local function unbind(keys)
    if seen[keys] then return end
    seen[keys] = true
    pcall(hl.unbind, keys)
  end
  for _, keys in ipairs(state.combos) do unbind(keys) end
  for _, keys in ipairs(extra or {}) do unbind(keys) end
  state.combos = {}
end

local function bind(entry, held)
  local options = copy(entry.options)
  options.description = entry.description
  local handler
  if entry.kind == "press" then
    handler = hl.dsp.exec_cmd(entry.command)
  elseif entry.kind == "hold" then
    handler = function()
      held.down = true
      hl.exec_cmd(entry.command)
    end
  else
    handler = function()
      if held.down then
        held.down = false
        hl.exec_cmd(entry.command)
      end
    end
  end
  -- The returned handle is dropped on purpose (see the top of this file).
  hl.bind(entry.keys, handler, options)
end

-- Replaces dictarchy's binds with the ones in spec. owner (the service's token)
-- is remembered for clear(); nil keeps the current owner, as for a key change
-- made from the menu. fresh says that Hyprland has none of dictarchy's binds
-- (it reloaded its config since the last apply): the combinations bound before
-- are then forgotten rather than unbound, since the reload may have given them
-- back to other binds. Raises an error listing what could not be bound, after
-- binding everything else, so hyprctl reports it to the CLI.
function M.apply(owner, spec, fresh)
  if owner ~= nil then state.owner = owner end
  if fresh then state.combos = {} end
  local plan = M.plan(spec)
  unbind_all(plan.combos)
  local held = { down = false }
  local bound = {}
  for _, entry in ipairs(plan.binds) do
    local ok, err = pcall(bind, entry, held)
    if ok then
      if not bound[entry.keys] then
        bound[entry.keys] = true
        state.combos[#state.combos + 1] = entry.keys
      end
    else
      plan.errors[#plan.errors + 1] = "cannot bind " .. entry.keys .. ": " .. tostring(err)
    end
  end
  if #plan.errors > 0 then
    error("dictarchy: " .. table.concat(plan.errors, "; "), 0)
  end
end

-- Removes dictarchy's binds. With an owner, only when it is the one that last
-- applied them. Binds that apply() replaced come back with the next config reload.
function M.clear(owner)
  if owner ~= nil and owner ~= state.owner then return end
  unbind_all()
  state.owner = nil
end

function M.combos()
  local list = {}
  for i, keys in ipairs(state.combos) do list[i] = keys end
  return list
end

if rawget(_G, "hl") then
  _G.dictarchy_hotkeys = M
end

return M
