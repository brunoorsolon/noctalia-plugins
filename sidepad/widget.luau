-- Bar entry: the selected pad's icon, name and state, and the one request a
-- click publishes. The panel publishes its requests through the same contract
-- module, so the controller sees one action path and one request shape.

local shared = require("./shared.luau")

local DEFAULT_GLYPH = "layout-sidebar-right"

local function status()
  local value = noctalia.state.get(shared.STATUS_KEY)
  if type(value) ~= "table" then
    return {}
  end
  return value
end

local function stateText(pad)
  if pad == nil then
    return "none"
  end
  if pad.visible then
    return "shown"
  end
  if pad.running then
    return "hidden"
  end
  return "stopped"
end

local function render()
  local s = status()
  local pad = shared.selectedPad(s)
  local errorText = type(s.error) == "string" and s.error or nil
  local glyph = DEFAULT_GLYPH
  if errorText then
    glyph = "alert-triangle"
  elseif s.busy then
    glyph = "loader"
  elseif pad and type(pad.icon) == "string" and pad.icon ~= "" then
    glyph = pad.icon
  end
  barWidget.setGlyph(glyph)
  local rows = {
    { key = "Pad", value = pad and (pad.name or pad.id) or "None selected" },
    { key = "State", value = errorText and "error" or stateText(pad) },
  }
  if errorText then
    table.insert(rows, { key = "Error", value = errorText })
  end
  barWidget.setTooltip(rows)
end

function onClick()
  shared.request("toggle")
end

noctalia.state.watch(shared.STATUS_KEY, render)
render()
