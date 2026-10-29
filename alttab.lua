-- Windows-style Alt+Tab with live thumbnails.
--
-- Hyprland owns the switching; the omarchy-shell plugin io.github.hugorolimf.alttab only
-- draws the panel. Alt+Tab orders the windows by recent use (the window
-- before the active one first, then the current monitor's windows), enters
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

-- Windows to offer, most recently used first: the active one, the one before
-- it (what a quick Alt+Tab goes to), then the rest with this monitor's first.
-- Other special workspaces (scratchpad) stay out; minimized windows are in.
local function collect()
  local windows = hl.get_windows()
  local active = hl.get_active_window()
  local monitor = hl.get_active_monitor()
  local monitor_name = monitor and monitor.name or ""
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
        here = w.monitor ~= nil and w.monitor.name == monitor_name,
        history = w.focus_history_id or 100000,
      }
    end
  end
  table.sort(items, function(a, b) return a.history < b.history end)

  -- The most recent other window goes right after the active one, wherever
  -- it is; then this monitor's windows, then the others.
  local list, rest = {}, {}
  local has_active = false
  for i = 1, #items do
    local it = items[i]
    if active and it.address == active.address then
      has_active = true
      table.insert(list, 1, it)
    else
      rest[#rest + 1] = it
    end
  end
  if #rest > 0 then list[#list + 1] = rest[1] end
  for i = 2, #rest do
    if rest[i].here then list[#list + 1] = rest[i] end
  end
  for i = 2, #rest do
    if not rest[i].here then list[#list + 1] = rest[i] end
  end
  return list, has_active, monitor_name
end

local function payload(monitor_name)
  local parts = {}
  for i = 1, #state.list do
    local it = state.list[i]
    parts[#parts + 1] = string.format('{"a":%s,"c":%s,"t":%s,"m":%s}',
      json_string(it.address), json_string(it.class), json_string(it.title), it.minimized and "true" or "false")
  end
  return string.format('{"s":%d,"q":%d,"i":%d,"mon":%s,"w":[%s]}',
    state.session, state.seq, state.index - 1, json_string(monitor_name), table.concat(parts, ","))
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

local function focus(item)
  local sel = "address:" .. item.address
  local w = hl.get_window(sel)
  if not w then return end
  if w.workspace and w.workspace.name == MINIMIZED then
    local ws = hl.get_active_workspace()
    if ws then
      hl.dispatch(hl.dsp.window.move({ workspace = tostring(ws.id), window = sel, follow = false }))
    end
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
    local list, has_active, monitor_name = collect()
    if #list == 0 then return end
    state.active = true
    state.shown = false
    state.list = list
    -- Sessions keep growing across config reloads, so the panel never
    -- mistakes a new switch for a stale one.
    state.session = math.max(state.session + 1, os.time())
    state.seq = 0
    local first = (has_active and #list > 1) and 2 or 1
    state.index = dir > 0 and first or #list
    hl.dispatch(hl.dsp.submap(SUBMAP))

    local session = state.session
    stop_timers()
    state.show_timer = hl.timer(function()
      if state.active and state.session == session and not state.shown then
        state.shown = true
        shell("show", o.shell_quote(payload(monitor_name)))
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
if hl.plugin and hl.plugin.hyprglass then
  local hg = hl.plugin.hyprglass
  hg.config({ layers = { enabled = true } })
  hg.preset("hugorolimf-alttab", { lens_distortion = 0.0, refraction_strength = 0.0, chromatic_aberration = 0.0 })
  hg.layer("hugorolimf-alttab", { preset = "hugorolimf-alttab", mask_threshold = 0.2, live_resample = false })
end
