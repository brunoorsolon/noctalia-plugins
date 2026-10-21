-- Bar entry: one glyph and one tooltip derived from the controller's snapshot,
-- plus the two interactions the bar owns. It reads only the shared contract, so a
-- click publishes a request and never mutates compositor state itself.

local shared = require("./shared.luau")

local DEFAULT_GLYPH = "layout-sidebar-right"

-- The tooltip is the only description an icon-only control has, so its action row
-- names the clicks this state acts on; no state leaves the bar unexplained.
local ACTIONS = {
  toggle = "Left click toggles the selected pad; right click opens the pad selector",
  busy = "Waiting for the current operation; right click opens the pad selector",
  none = "No pad is selected; right click opens the pad selector",
}

local function status()
  local value = noctalia.state.get(shared.STATUS_KEY)
  if type(value) ~= "table" then
    return {}
  end
  return value
end

-- The controller names the pad it acts on, so the bar follows that name rather
-- than the pad list: a snapshot caught mid-refresh must not make the bar refuse
-- an action the controller would accept.
local function selectedId(snapshot)
  local id = snapshot.selectedPadId
  return type(id) == "string" and id ~= "" and id or nil
end

local function padName(pad)
  if type(pad) ~= "table" then
    return "None selected"
  end
  if type(pad.name) == "string" and pad.name ~= "" then
    return pad.name
  end
  return pad.id
end

-- One reading per render, shared by the glyph, the tooltip and the click guard,
-- so the bar cannot draw one state while describing another. Busy comes first
-- because it is the state that decides whether a click is accepted; a failure the
-- controller still reports stays in the tooltip while the next attempt runs.
local function view(snapshot)
  local pad = shared.selectedPad(snapshot)
  local errorText = type(snapshot.error) == "string" and snapshot.error or nil
  if snapshot.busy then
    return { pad = pad, state = "busy", error = errorText, glyph = "loader", color = "primary" }
  end
  if errorText then
    return { pad = pad, state = "error", error = errorText, glyph = "alert-triangle", color = "error" }
  end
  if selectedId(snapshot) == nil then
    return { pad = nil, state = "unavailable", glyph = DEFAULT_GLYPH, color = "on_surface_variant" }
  end
  -- The selection is authoritative before its record arrives: with no runtime
  -- detail published yet, a named pad is simply not running and not shown.
  pad = pad or { id = selectedId(snapshot) }
  local glyph = type(pad.icon) == "string" and pad.icon ~= "" and pad.icon or DEFAULT_GLYPH
  if pad.visible then
    return { pad = pad, state = "visible", glyph = glyph, color = "primary" }
  end
  -- A hidden pad whose process is gone is still selectable: toggle launches it.
  return { pad = pad, state = pad.running and "hidden" or "stopped", glyph = glyph, color = "on_surface_variant" }
end

local function actionText(snapshot)
  if snapshot.busy then
    return ACTIONS.busy
  end
  if selectedId(snapshot) == nil then
    return ACTIONS.none
  end
  return ACTIONS.toggle
end

local function render()
  local snapshot = status()
  local v = view(snapshot)
  barWidget.setGlyph(v.glyph)
  barWidget.setGlyphColor(v.color)
  local rows = {
    { key = "Pad", value = padName(v.pad) },
    { key = "State", value = v.state },
  }
  if v.error then
    table.insert(rows, { key = "Error", value = v.error })
  end
  table.insert(rows, { key = "Actions", value = actionText(snapshot) })
  barWidget.setTooltip(rows)
end

-- A click during an in-flight operation joins nothing: the controller already
-- owns one operation, and a second request would compete with it.
function onClick()
  local snapshot = status()
  if snapshot.busy or selectedId(snapshot) == nil then
    return
  end
  -- The helper publishes the intent only; an identical consecutive click is
  -- still a new publication the controller stamps and answers.
  shared.request("toggle")
end

-- The panel is a local surface, not a controller request, so it stays reachable
-- while an operation runs.
function onRightClick()
  noctalia.togglePanel("magus/sidepad:selector")
end

noctalia.state.watch(shared.STATUS_KEY, render)
render()
