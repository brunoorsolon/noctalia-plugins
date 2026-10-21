-- Selector panel entry: it renders the controller's copied snapshot and sends
-- requests through the same shared contract as the bar.

local shared = require("./shared.luau")

local isOpen = false
local pendingSelect = nil

local function status()
  local value = noctalia.state.get(shared.STATUS_KEY)
  return type(value) == "table" and value or {}
end

local function padState(pad)
  if pad.visible then
    return type(pad.output) == "string" and ("shown on " .. pad.output) or "shown"
  end
  return pad.running and "hidden" or "stopped"
end

local function selectedPad(snapshot)
  for _, pad in ipairs(type(snapshot.pads) == "table" and snapshot.pads or {}) do
    if type(pad) == "table" and pad.id == snapshot.selectedPadId then
      return pad
    end
  end
  return nil
end

local function request(action, padId)
  if not status().busy then
    shared.request(action, padId)
  end
end

local function selectPad(padId)
  local snapshot = status()
  if snapshot.busy then return end
  pendingSelect = { padId = padId, revision = snapshot.revision or 0 }
  shared.request("select", padId)
end

local function render()
  local snapshot = status()
  local busy = snapshot.busy == true
  local selected = selectedPad(snapshot)
  local available = selected ~= nil
  local errorText = type(snapshot.error) == "string" and snapshot.error or nil
  local children = {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = "Sidepad", fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      ui.button({ text = "Refresh", enabled = not busy, onClick = "onRefresh" }),
    }),
  }

  if errorText then
    table.insert(children, ui.label({ text = errorText, color = "error", fontSize = 12 }))
  end
  if busy then
    table.insert(children, ui.label({ text = "Operation in progress.", color = "primary", fontSize = 12 }))
  end

  local pads = type(snapshot.pads) == "table" and snapshot.pads or {}
  if #pads == 0 then
    table.insert(children, ui.label({ text = "No pads configured yet.", color = "on_surface_variant" }))
  else
    for _, pad in ipairs(pads) do
      local icon = type(pad.icon) == "string" and pad.icon ~= "" and pad.icon or "app-window"
      local name = type(pad.name) == "string" and pad.name ~= "" and pad.name or pad.id
      local label = name .. " · " .. padState(pad)
      local isSelected = pad.id == snapshot.selectedPadId
      if isSelected then label = label .. " · selected" end
      table.insert(children, ui.button({
        key = pad.id,
        text = label,
        glyph = icon,
        selected = isSelected,
        enabled = not busy,
        onClick = function()
          selectPad(pad.id)
        end,
      }))
    end
  end

  local visible = available and selected.visible == true
  local running = available and selected.running == true
  local side = snapshot.side == "right" and "right" or "left"
  local widthMode = snapshot.widthMode == "wide" and "wide" or "narrow"
  table.insert(children, ui.row({ gap = 8 }, {
    ui.button({
      key = "visibility",
      text = visible and "Hide" or "Show",
      enabled = available and not busy,
      onClick = function()
        if available then request(visible and "hide" or "show", selected.id) end
      end,
    }),
    ui.button({
      key = "width",
      text = widthMode == "wide" and "Narrow" or "Wide",
      enabled = running and not busy,
      onClick = function()
        if running then request("toggle_width", selected.id) end
      end,
    }),
    ui.button({
      key = "side",
      text = side == "left" and "Move to right" or "Move to left",
      enabled = available and not busy,
      onClick = function()
        if available then request("switch_side", selected.id) end
      end,
    }),
    ui.button({
      key = "close",
      text = "Close",
      enabled = running and not busy,
      onClick = function()
        if running then request("close", selected.id) end
      end,
    }),
  }))

  panel.render(ui.column({ gap = 10, padding = 16 }, children))
end

function onOpen(_context)
  isOpen = true
  render()
end

function onClose()
  isOpen = false
  pendingSelect = nil
end

function onRefresh()
  request("refresh")
end

function onToggle()
  local snapshot = status()
  local selected = selectedPad(snapshot)
  if selected and not snapshot.busy then
    request("toggle", selected.id)
  end
end

noctalia.state.watch(shared.STATUS_KEY, function(snapshot)
  if pendingSelect and type(snapshot) == "table" and (snapshot.revision or 0) > pendingSelect.revision and not snapshot.busy then
    local pad = selectedPad(snapshot)
    local succeeded = snapshot.error == nil and snapshot.selectedPadId == pendingSelect.padId and pad ~= nil and pad.visible == true
    pendingSelect = nil
    if succeeded then
      panel.close()
      isOpen = false
    end
  end
  if isOpen then render() end
end)
