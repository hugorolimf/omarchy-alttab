-- Windows-style Alt+Tab with live thumbnails.
--
-- Hyprland owns the switching; the omarchy-shell plugin io.github.hugorolimf.alttab only
-- draws the panel. Alt+Tab lists the windows by recent use, like Windows,
-- whatever workspace they are on (each tile says which), and starts on the
-- window used before the active one, enters
-- the "hugorolimf-alttab" submap so Tab / Shift+Tab / arrows / Esc only mean
-- something while switching, and shows the panel once Alt has been held for
-- SHOW_DELAY ms. Letting go of Alt focuses the pick (and brings it to the
-- front); minimized windows (special:minimized) come back
-- to the current workspace. A quick Alt+Tab never reaches the shell at all.
--
-- Loaded by ~/.local/state/omarchy/toggles/hypr/hugorolimf-alttab.lua, which
-- the plugin writes when it loads. To get Omarchy's own Alt+Tab back, delete
-- that file and run hyprctl reload.

local SUBMAP = "hugorolimf-alttab"
local SHOW_DELAY = 40
local MINIMIZED = "special:minimized"

local state = {
  active = false,
  list = {},
  index = 1,
  session = 0,
  seq = 0,
  shown = false,
  show_timer = nil,
  poll_timer = nil,
}

local function json_string(value)
  local escaped = tostring(value or ""):gsub('[%c"\\]', function(c)
    if c == '"' then return '\\"' end
    if c == "\\" then return "\\\\" end
    return string.format("\\u%04x", c:byte())
  end)
  return '"' .. escaped .. '"'
end

local function shell(method, args)
  hl.exec_cmd("omarchy-shell -q io.github.hugorolimf.alttab " .. method .. " " .. args)
end

-- The window list (titles can be private) never goes in a command line,
-- which other accounts can read: it is written to a file in a 0700 folder
-- under $XDG_RUNTIME_DIR and only that path is handed to the shell. Without
-- a runtime dir there is no private place for it, so the panel stays off and
-- Alt+Tab still switches.
local RUNTIME = os.getenv("XDG_RUNTIME_DIR")
local LIST_DIR = RUNTIME and RUNTIME ~= "" and (RUNTIME .. "/glass-alttab") or nil
local LIST_FILE = LIST_DIR and (LIST_DIR .. "/list.json") or nil
local function quote(path) return "'" .. path:gsub("'", "'\\''") .. "'" end
if LIST_DIR then os.execute("mkdir -p -m 700 " .. quote(LIST_DIR) .. " && chmod 700 " .. quote(LIST_DIR)) end

local function write_list(json)
  if not LIST_FILE then return false end
  local tmp = LIST_FILE .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return false end
  f:write(json)
  f:close()
  return os.rename(tmp, LIST_FILE) ~= nil
end

-- Recent use, kept here rather than read from Hyprland's focus history:
-- focusing a window on another workspace first focuses the window that
-- workspace remembers, for an instant, and Hyprland counts that one as used
-- too, so a second Alt+Tab would go there instead of back. A window counts
-- as used once it has kept the focus for SETTLE ms. Windows not seen since
-- the config was loaded fall back to Hyprland's order, after these.
local SETTLE = 120
local recent, stamp = {}, 0
local pending, settle_timer = nil, nil
local function settle()
  if settle_timer then settle_timer:set_enabled(false) end
  settle_timer = nil
  if pending then
    stamp = stamp + 1
    recent[pending] = stamp
    pending = nil
  end
end
hl.on("window.active", function(w)
  if not w or not w.address then return end
  pending = w.address
  if settle_timer then settle_timer:set_enabled(false) end
  settle_timer = hl.timer(settle, { timeout = SETTLE, type = "oneshot" })
end)
hl.on("window.close", function(w)
  if w and w.address then recent[w.address] = nil end
end)

-- Windows to offer, most recently used first across every workspace, so
-- each Tab goes one window further back and a quick Alt+Tab, pressed again,
-- comes straight back. Minimized windows keep their place by when they were
-- used: one just put away is the one used before the active window, so a
-- quick Alt+Tab brings it back; one put away long ago sits further back.
-- Other special workspaces (scratchpad) stay out. Also
-- returns where the active window and the one before it (what a quick
-- Alt+Tab goes to) ended up.
-- The workspace a minimized window left, when the windowing script keeps it.
local function from_ws(address)
  local f = rawget(_G, "windowing_minimized_ws")
  return f and f(address) or nil
end

local function collect()
  local windows = hl.get_windows()
  local active = hl.get_active_window()
  -- the window focused a moment ago is the one in use, settled or not
  if active and pending == active.address then settle() end
  local monitor = hl.get_active_monitor()
  local current = hl.get_active_workspace()
  local items = {}
  for i = 1, #windows do
    local w = windows[i]
    local ws = w.workspace
    if w.mapped and not w.hidden and ws and (not ws.special or ws.name == MINIMIZED) then
      items[#items + 1] = {
        address = w.address,
        class = w.class or "",
        title = w.title or "",
        minimized = ws.special == true,
        ws = ws.special and -1 or ws.id,
        ws_name = ws.special and tostring(from_ws(w.address) or "") or (ws.name or tostring(ws.id)),
        history = recent[w.address] and -recent[w.address] or 1000000 + (w.focus_history_id or 0),
      }
    end
  end
  table.sort(items, function(a, b) return a.history < b.history end)

  local active_index, previous_index
  for i = 1, #items do
    local it = items[i]
    if active and it.address == active.address then
      active_index = i
    elseif not previous_index or it.history < items[previous_index].history then
      previous_index = i
    end
  end
  return items, active_index, previous_index, monitor and monitor.name or "", current and current.id or 0
end

local function payload(monitor_name, current)
  local parts = {}
  for i = 1, #state.list do
    local it = state.list[i]
    parts[#parts + 1] = string.format('{"a":%s,"c":%s,"t":%s,"m":%s,"ws":%d,"wn":%s}',
      json_string(it.address), json_string(it.class), json_string(it.title), it.minimized and "true" or "false",
      it.ws, json_string(it.ws_name))
  end
  return string.format('{"s":%d,"q":%d,"i":%d,"mon":%s,"cur":%d,"w":[%s]}',
    state.session, state.seq, state.index - 1, json_string(monitor_name), current, table.concat(parts, ","))
end

local function stop_timers()
  if state.show_timer then state.show_timer:set_enabled(false) end
  if state.poll_timer then state.poll_timer:set_enabled(false) end
  state.show_timer = nil
  state.poll_timer = nil
end

local function finish()
  local was_shown = state.shown
  state.active = false
  state.shown = false
  state.list = {}
  stop_timers()
  hl.dispatch(hl.dsp.submap("reset"))
  if was_shown then shell("hide", tostring(state.session)) end
end

-- Omarchy turns workspace animations off, so a pick on another workspace
-- would jump there. Alt+Tab slides instead: the slide is turned on just for
-- that change and put back as configured once it is over. What is
-- configured is asked of hyprctl in the background after each load (Lua
-- can't call hyprctl and wait: hyprctl talks to this very process) and kept
-- next to the window list. Someone whose workspaces already animate, or who
-- never overrode them, is left alone.
local SLIDE_SPEED = 2.2 -- tenths of a second
local SLIDE_CURVE = "hugorolimfAltTab"
local ANIM_FILE = LIST_DIR and (LIST_DIR .. "/animations.json") or nil
hl.curve(SLIDE_CURVE, { type = "bezier", points = { { 0.32, 0.72 }, { 0, 1 } } })
if ANIM_FILE then hl.exec_cmd("hyprctl animations -j > " .. quote(ANIM_FILE)) end

local function configured_slide()
  local f = ANIM_FILE and io.open(ANIM_FILE, "r")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  local entry = text:match('{[^{}]-"name"%s*:%s*"workspaces"[^{}]-}')
  if not entry then return nil end
  return {
    overridden = entry:match('"overridden"%s*:%s*(%a+)') == "true",
    enabled = entry:match('"enabled"%s*:%s*(%a+)') == "true",
    speed = tonumber(entry:match('"speed"%s*:%s*([%d%.]+)')),
    bezier = entry:match('"bezier"%s*:%s*"([^"]*)"'),
  }
end

local function slide_to(workspace)
  local was = configured_slide()
  if was and was.overridden and not was.enabled then
    if state.slide_timer then state.slide_timer:set_enabled(false) end
    hl.animation({ leaf = "workspaces", enabled = true, speed = SLIDE_SPEED, bezier = SLIDE_CURVE, style = "slide" })
    local back = { leaf = "workspaces", enabled = false }
    if was.speed then back.speed = was.speed end
    if was.bezier and was.bezier ~= "" then back.bezier = was.bezier end
    -- Turning it off mid-way would snap the slide, so only after it ends.
    state.slide_timer = hl.timer(function()
      hl.animation(back)
      state.slide_timer = nil
    end, { timeout = math.floor(SLIDE_SPEED * 100) + 150, type = "oneshot" })
  end
  hl.dispatch(hl.dsp.focus({ workspace = tostring(workspace.id) }))
end

local function focus(item)
  local sel = "address:" .. item.address
  local w = hl.get_window(sel)
  if not w then return end
  local ws = w.workspace
  if ws and ws.name == MINIMIZED and rawget(_G, "windowing_restore") then
    -- back to the workspace it was minimized from
    windowing_restore(item.address)
    return
  elseif ws and ws.name == MINIMIZED then
    local here = hl.get_active_workspace()
    if here then
      hl.dispatch(hl.dsp.window.move({ workspace = tostring(here.id), window = sel, follow = false }))
    end
  elseif ws and not ws.special and not ws.active then
    -- On a workspace that isn't on screen: slide there first.
    slide_to(ws)
  end
  hl.dispatch(hl.dsp.focus({ window = sel }))
  hl.dispatch(hl.dsp.window.bring_to_top())
end

local function commit(source)
  if not state.active then return end
  local item = state.list[state.index]
  finish()
  if item then focus(item) end
end

local function cancel()
  if state.active then finish() end
end

local function alt_down()
  -- Keycodes (xkb) for the left and right Alt keys, plus their keysyms.
  return hl.is_key_down(64) or hl.is_key_down(108) or hl.is_key_down("Alt_L") or hl.is_key_down("Alt_R")
end

local function step(dir)
  if not state.active then
    local list, active_index, previous_index, monitor_name, current = collect()
    if #list == 0 then return end
    state.active = true
    state.shown = false
    state.list = list
    -- Sessions keep growing across config reloads, so the panel never
    -- mistakes a new switch for a stale one.
    state.session = math.max(state.session + 1, os.time())
    state.seq = 0
    -- Forward starts on the window used before this one, as a quick Alt+Tab
    -- expects; backward on the one just before the active window in the panel.
    if dir > 0 then
      state.index = previous_index or active_index or 1
    else
      state.index = active_index and ((active_index - 2) % #list) + 1 or #list
    end
    hl.dispatch(hl.dsp.submap(SUBMAP))

    local session = state.session
    stop_timers()
    state.show_timer = hl.timer(function()
      if state.active and state.session == session and not state.shown then
        state.shown = true
        if write_list(payload(monitor_name, current)) then shell("showFile", o.shell_quote(LIST_FILE)) end
      end
    end, { timeout = SHOW_DELAY, type = "oneshot" })
    -- Letting go of Alt, checked every frame: the Alt_L/Alt_R release binds
    -- below don't fire here in practice, so this is what commits.
    state.poll_timer = hl.timer(function()
      if state.active and state.session == session and not alt_down() then commit("poll") end
    end, { timeout = 16, type = "repeat" })
    return
  end

  local n = #state.list
  state.index = ((state.index - 1 + dir) % n) + 1
  if state.shown then
    state.seq = state.seq + 1
    shell("select", state.session .. " " .. state.seq .. " " .. (state.index - 1))
  end
end

-- Called by the panel when a thumbnail is clicked.
function hugorolimf_alttab_pick(session, index)
  if not state.active or session ~= state.session or not state.list[index] then return end
  state.index = index
  commit()
end

function hugorolimf_alttab_cancel(session)
  if session == nil or session == state.session then cancel() end
end

-- Replaces Omarchy's ALT + TAB (was: cycle_next + bring_to_top) and
-- ALT + SHIFT + TAB (was: cycle_next backwards + bring_to_top).
hl.unbind("ALT + TAB")
hl.unbind("ALT + SHIFT + TAB")
hl.bind("ALT + TAB", function() step(1) end, { description = "Switch windows (thumbnails)" })
hl.bind("ALT + SHIFT + TAB", function() step(-1) end, { description = "Switch windows backwards (thumbnails)" })

-- Releasing Alt picks. Universal, because Hyprland matches a release
-- against the submap the key was pressed in (the global one); non_consuming
-- so apps still see Alt. Outside a switch it does nothing.
local release = { release = true, non_consuming = true, ignore_mods = true, submap_universal = true, description = "Alt+Tab: focus the pick" }
hl.bind("Alt_L", function() commit("release") end, release)
hl.bind("Alt_R", function() commit("release") end, release)

hl.define_submap(SUBMAP, function()
  hl.bind("ALT + TAB", function() step(1) end, { repeating = true })
  hl.bind("ALT + SHIFT + TAB", function() step(-1) end, { repeating = true })
  hl.bind("ALT + RIGHT", function() step(1) end, { repeating = true })
  hl.bind("ALT + LEFT", function() step(-1) end, { repeating = true })
  hl.bind("ESCAPE", cancel, { ignore_mods = true })
  hl.bind("RETURN", commit, { ignore_mods = true })
end)

-- Liquid Glass behind the panel, only on its layer namespace (each
-- hyprglass.layer() call adds its namespace to the whitelist; never enable
-- layers without one). live_resample = false: no redraw every frame.
-- alpha_region: the panel declares where its glass is (an empty box while
-- hidden), so the full-screen layer costs nothing at rest.
if hl.plugin and hl.plugin.hyprglass then
  local hg = hl.plugin.hyprglass
  hg.config({ layers = { enabled = true } })
  hg.preset("hugorolimf-alttab", { lens_distortion = 0.0, refraction_strength = 0.0, chromatic_aberration = 0.0 })
  hg.layer("hugorolimf-alttab", { preset = "hugorolimf-alttab", mask_threshold = 0.2, live_resample = false, mask_mode = "alpha_region" })
end
