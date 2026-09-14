-- Bar entry: composite controls for the one job, plus live status. The buttons
-- send the same commands as the panel; they never open a panel, so recording
-- from the bar leaves the focused window focused.

local STATUS = {
  recording = { glyph = "microphone", color = "error" },
  running = { glyph = "loader", color = "primary" },
  verifying = { glyph = "loader", color = "primary" },
  ok = { glyph = "check", color = "primary" },
  review = { glyph = "alert-triangle", color = "tertiary" },
  error = { glyph = "alert-triangle", color = "error" },
  cancelled = { glyph = "microphone", color = "on_surface_variant" },
}

local commandSeq = 0

-- Delivery outcomes that outlive the job: the bar must not show recognition
-- success while the paste was held or failed.
local DELIVERY_STATUS = {
  attempted = { glyph = "check", color = "primary" },
  held = { glyph = "alert-triangle", color = "tertiary" },
  failed = { glyph = "alert-triangle", color = "error" },
}

local function send(action, extra)
  commandSeq = commandSeq + 1
  -- `from` tells the controller this recording started from a surface that keeps
  -- the focused window focused, so the window can be captured as the destination.
  local command = { seq = commandSeq, action = action, from = "bar" }
  if type(extra) == "table" then
    for key, value in pairs(extra) do command[key] = value end
  end
  noctalia.state.set("dictation.command", command)
end

local function statusFor(activity, severity)
  if activity == "recording" then return STATUS.recording end
  if activity ~= "idle" then
    -- The job is still owned but its helper stopped reporting: show the error,
    -- not a spinner, because nothing is confirmed to be progressing.
    if severity == "error" then return STATUS.error end
    return STATUS[activity]
  end
  return severity and STATUS[severity] or nil
end

local function render()
  local s = noctalia.state.get("dictation")
  local activity = type(s) == "table" and s.activity or "idle"
  local severity = type(s) == "table" and s.severity or nil
  local phase = type(s) == "table" and s.phase or nil
  local finalizing = activity == "recording" and phase == "finalizing"
  local delivery = type(s) == "table" and type(s.delivery) == "table" and s.delivery or nil
  local deliveryStatus = delivery and DELIVERY_STATUS[delivery.state] or nil
  -- Capture is over once the WAV is being finalized, so the bar swaps the
  -- microphone for a working glyph and drops Stop; the tooltip keeps naming the
  -- microphone the audio came from. A finished job shows what happened to the
  -- transcript - attempted, held or failed - rather than recognition success
  -- alone, because a hold is not an insertion.
  local status = finalizing and { glyph = "loader", color = "primary" }
    or (activity == "idle" and deliveryStatus)
    or statusFor(activity, severity)
    or { glyph = "microphone", color = "on_surface_variant" }

  local elapsed = 0
  if type(s) == "table" and type(s.job) == "table" and type(s.job.elapsedSeconds) == "number" then
    elapsed = s.job.elapsedSeconds
  end
  local text = ""
  -- The panel already counts elapsed time for a running job, so the bar shows the
  -- same clock instead of a bare spinner for a long transcription.
  if activity == "recording" or activity == "running" then
    text = string.format("%d:%02d", math.floor(elapsed / 60), elapsed % 60)
  end

  local recording = activity == "recording"
  local busy = recording or activity == "running"
  barWidget.render(ui.row({ gap = 4, align = "center" }, {
    ui.glyph({ name = status.glyph, size = 14, color = status.color }),
    ui.label({ text = text, fontSize = 11, color = status.color, visible = text ~= "" }),
    ui.button({ glyph = "square", controlSize = "sm", visible = recording and not finalizing, onClick = "onWidgetStop", tooltip = "Stop and finalize the recording" }),
    ui.button({ glyph = "microphone", controlSize = "sm", visible = activity == "idle", onClick = "onWidgetRecord", tooltip = "Record from the selected microphone" }),
    ui.button({ glyph = "x", controlSize = "sm", visible = busy, onClick = "onWidgetCancel", tooltip = "Cancel the job" }),
    ui.button({ glyph = "panel-right", controlSize = "sm", onClick = "onWidgetPanel", tooltip = "Open the dictation panel" }),
  }))

  local message = type(s) == "table" and s.message or nil
  -- A held or failed paste is the more useful line: the recognition message can
  -- say the text is ready while nothing was inserted anywhere.
  if delivery and type(delivery.message) == "string" and delivery.message ~= "" and (delivery.state == "held" or delivery.state == "failed") then
    message = delivery.message
  end
  if type(message) == "string" and message ~= "" then
    barWidget.setTooltip(message)
  else
    barWidget.clearTooltip()
  end
end

function onWidgetRecord()
  send("record")
end

function onWidgetStop()
  send("stop")
end

function onWidgetCancel()
  send("cancel")
end

function onWidgetPanel()
  noctalia.togglePanel("magus/dictation:panel")
end

function onRightClick()
  noctalia.togglePanel("magus/dictation:panel")
end

noctalia.state.watch("dictation", render)
render()
