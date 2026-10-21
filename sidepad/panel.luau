-- Selector panel entry: the same status snapshot the bar renders, with one
-- control per configured pad and the requests this surface owns. It is thin on
-- purpose: the accessible selector, its disabled states and its dismissal rules
-- belong to the panel slice, which replaces this tree.

local shared = require("./shared.luau")

local isOpen = false

local function status()
  local value = noctalia.state.get(shared.STATUS_KEY)
  if type(value) ~= "table" then
    return {}
  end
  return value
end

local function stateText(pad)
  if pad.visible then
    return type(pad.output) == "string" and ("shown on " .. pad.output) or "shown"
  end
  return pad.running and "hidden" or "stopped"
end

local function render()
  local s = status()
  local children = {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = "Sidepad", fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      ui.button({ glyph = "refresh", variant = "ghost", tooltip = "Refresh pad state", onClick = "onRefresh" }),
    }),
  }

  local errorText = type(s.error) == "string" and s.error or nil
  if errorText then
    table.insert(children, ui.label({ text = errorText, color = "error", fontSize = 12 }))
  end

  local pads = type(s.pads) == "table" and s.pads or {}
  if #pads == 0 then
    table.insert(children, ui.label({ text = "No pads configured yet.", color = "on_surface_variant" }))
  else
    for _, pad in ipairs(pads) do
      local icon = type(pad.icon) == "string" and pad.icon ~= "" and pad.icon or "app-window"
      table.insert(children, ui.button({
        key = pad.id,
        text = (pad.name or pad.id) .. " · " .. stateText(pad),
        glyph = icon,
        selected = pad.id == s.selectedPadId,
        onClick = function()
          shared.request("select", pad.id)
        end,
      }))
    end
  end

  table.insert(children, ui.row({ gap = 8 }, {
    ui.button({ text = "Show or hide", onClick = "onToggle" }),
  }))

  panel.render(ui.column({ gap = 10, padding = 16 }, children))
end

function onOpen(_context)
  isOpen = true
  render()
end

function onClose()
  isOpen = false
end

function onRefresh()
  shared.request("refresh")
end

function onToggle()
  shared.request("toggle")
end

noctalia.state.watch(shared.STATUS_KEY, function()
  if isOpen then
    render()
  end
end)
