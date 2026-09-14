-- Bar entry: mirrors the controller's live status and opens the panel.

local STATUS = {
  running = { glyph = "loader", color = "primary" },
  verifying = { glyph = "loader", color = "primary" },
  ok = { glyph = "check", color = "primary" },
  review = { glyph = "alert-triangle", color = "tertiary" },
  error = { glyph = "alert-triangle", color = "error" },
  cancelled = { glyph = "microphone", color = "on_surface_variant" },
}

local function render()
  local s = noctalia.state.get("dictation")
  local activity = type(s) == "table" and s.activity or "idle"
  local severity = type(s) == "table" and s.severity or nil
  local status
  if activity == "running" and severity == "error" then
    -- The job is still owned but its helper stopped reporting: show the error,
    -- not a spinner, because nothing is confirmed to be progressing.
    status = STATUS.error
  elseif activity ~= "idle" then
    status = STATUS[activity]
  else
    status = severity and STATUS[severity] or nil
  end

  barWidget.setGlyph(status and status.glyph or "microphone")
  barWidget.setText("")
  barWidget.setColor(status and status.color or "on_surface_variant")

  local message = type(s) == "table" and s.message or nil
  if type(message) == "string" and message ~= "" then
    barWidget.setTooltip(message)
  else
    barWidget.clearTooltip()
  end
end

function onClick()
  noctalia.togglePanel("magus/dictation:panel")
end

noctalia.state.watch("dictation", render)
render()
