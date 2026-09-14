-- Panel view: microphone choice, live job status, and the transcript the user
-- reads and copies. Everything it shows comes from the controller's state.

local WIDTH = 460
local LABEL_WIDTH = WIDTH - 32

local isOpen = false
local draft = nil
local draftKey = ""
local commandSeq = 0

local PHASE_TEXT = {
  starting = "Starting the recorder.",
  recording = "Recording.",
  finalizing = "Finalizing the recording.",
  transcribing = "Transcribing.",
}

local function state()
  local value = noctalia.state.get("dictation")
  if type(value) ~= "table" then return {} end
  return value
end

local function configPath(key)
  local value = noctalia.getConfig(key)
  if type(value) ~= "string" then return "" end
  value = noctalia.string.trim(value)
  if value == "" then return "" end
  return noctalia.expandPath(value)
end

local function severityColor(severity)
  if severity == "error" then return "error" end
  if severity == "review" then return "tertiary" end
  if severity == "cancelled" then return "on_surface_variant" end
  return "primary"
end

local function sendCommand(action, extra)
  commandSeq = commandSeq + 1
  -- `from` is what tells the controller whether this recording was started from a
  -- surface that holds the keyboard: the panel is not a paste destination.
  local command = { seq = commandSeq, action = action, from = "panel" }
  if type(extra) == "table" then
    for key, value in pairs(extra) do command[key] = value end
  end
  noctalia.state.set("dictation.command", command)
end

local function jobElapsed(s)
  local job = s.job
  if type(job) ~= "table" or type(job.elapsedSeconds) ~= "number" then return 0 end
  return job.elapsedSeconds
end

local function statusText(s)
  local activity = s.activity or "idle"
  -- A job whose helper went silent is still owned, so the panel reports the
  -- lost contact instead of claiming work is progressing normally.
  if activity == "recording" or activity == "running" then
    if s.severity == "error" and type(s.message) == "string" and s.message ~= "" then
      return s.message
    end
    local elapsed = jobElapsed(s)
    local phase = activity == "recording" and (PHASE_TEXT[s.phase] or "Recording.") or "Transcribing."
    return string.format("%s %d:%02d elapsed.", phase, math.floor(elapsed / 60), elapsed % 60)
  end
  if activity == "verifying" then return "Verifying the executable and hashing the files." end
  if type(s.message) == "string" and s.message ~= "" then return s.message end
  return "Ready."
end

local function setupBanner(s)
  local setup = type(s.setup) == "table" and s.setup or {}
  if setup.state == "ok" then
    local text = "Setup recorded."
    if setup.engineSha256 and setup.engineSha256 ~= "" then
      text = string.format("Setup recorded. Engine %s, model %s.", setup.engineSha256, setup.modelSha256)
    end
    return ui.label({ text = text, fontSize = 12, color = "on_surface_variant", maxWidth = LABEL_WIDTH })
  end
  if setup.state == "verifying" then
    return ui.label({ text = "Verifying setup.", color = "primary", maxWidth = LABEL_WIDTH })
  end

  local required = setup.state == "required"
  local color = required and "error" or "tertiary"
  local actions = {
    ui.button({ text = "Verify and record", variant = required and "ghost" or "primary", onClick = "onVerify" }),
    ui.button({ text = "Open settings", variant = required and "primary" or "ghost", onClick = "onOpenSettings" }),
  }
  return ui.column({ gap = 8, fill = color .. "/0.12", radius = 8, padding = 12 }, {
    ui.label({ text = setup.message or "Setup required.", color = color, maxWidth = LABEL_WIDTH }),
    ui.row({ gap = 8 }, actions),
  })
end

-- The microphone list comes from pw-dump through the helper; the selection is a
-- stable node name, so a reconnect keeps the same microphone chosen.
local function microphoneRow(s)
  local sources = type(s.sources) == "table" and s.sources or {}
  local mic = type(s.microphone) == "table" and s.microphone or {}
  local options, selected = {}, 0
  if type(sources.list) == "table" then
    for index, source in ipairs(sources.list) do
      options[index] = source.description
      if mic.id == source.id then selected = index - 1 end
    end
  end

  local note, color = "", "on_surface_variant"
  -- A recorder keeps the microphone it was started with, so the choice is closed
  -- while audio is being captured instead of appearing to change it.
  local capturing = (s.activity or "idle") == "recording"
  if sources.state == "loading" then
    note = "Scanning for microphones."
  elseif sources.state == "error" then
    note, color = sources.message, "error"
  elseif mic.state == "missing" then
    note, color = mic.message, "error"
  elseif mic.state == "ok" then
    note = "Recording from: " .. tostring(mic.name)
  elseif mic.state == "unset" then
    note, color = "Choose a microphone before recording.", "tertiary"
  end

  return ui.column({ gap = 6 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = "Microphone", fontSize = 12, color = "on_surface_variant" }),
      ui.spacer({ flexGrow = 1 }),
      ui.button({ text = "Refresh", variant = "ghost", onClick = "onRefreshSources" }),
    }),
    ui.select({
      key = "microphone",
      options = options,
      selectedIndex = selected,
      enabled = #options > 0 and not capturing,
      placeholder = "No capture sources found",
      onChange = "onMicrophoneSelected",
    }),
    ui.label({ text = note, fontSize = 12, color = color, maxWidth = LABEL_WIDTH }),
  })
end

local function transcriptArea(s)
  if type(s.transcript) ~= "string" or s.transcript == "" then
    return ui.column({ gap = 8, flexGrow = 1, align = "center", justify = "center" }, {
      ui.label({ text = "No transcript yet.", color = "on_surface_variant", maxWidth = LABEL_WIDTH }),
    })
  end
  local key = tostring(s.transcriptPath)
  if draftKey ~= key then
    draftKey = key
    draft = s.transcript
  end
  return ui.column({ gap = 8, flexGrow = 1 }, {
    ui.row({ align = "center" }, {
      ui.label({ text = "Transcript", fontSize = 12, color = "on_surface_variant", flexGrow = 1 }),
      ui.label({ text = "attempt " .. tostring(s.attempt), fontSize = 12, color = "on_surface_variant" }),
    }),
    -- Multiline input rather than markdown: the text stays selectable and exactly
    -- as recognised, with no reinterpretation of its contents.
    ui.input({
      key = key,
      value = draft or s.transcript,
      multiline = true,
      flexGrow = 1,
      onChange = "onTranscriptEdited",
    }),
    ui.label({ text = s.transcriptPath, fontSize = 10, color = "on_surface_variant", maxLines = 2, maxWidth = LABEL_WIDTH }),
  })
end

local function recordingRow(s)
  local activity = s.activity or "idle"
  local idle = activity == "idle"
  local mic = type(s.microphone) == "table" and s.microphone or {}
  local canRecord = idle and mic.state == "ok"
  local hasRecording = type(s.recording) == "table" and s.recording.exists == true
  return ui.row({ gap = 8, align = "center" }, {
    ui.button({
      text = activity == "recording" and "Stop" or "Record",
      variant = "primary",
      enabled = canRecord or activity == "recording",
      onClick = activity == "recording" and "onStop" or "onRecord",
    }),
    ui.button({
      text = "Cancel",
      variant = "destructive",
      enabled = activity == "recording" or activity == "running",
      onClick = "onCancel",
    }),
    ui.button({ text = "Play", enabled = idle and hasRecording, onClick = "onPlay" }),
    ui.button({ text = "Retry", enabled = idle and hasRecording, onClick = "onRetry" }),
    ui.spacer({ flexGrow = 1 }),
    ui.button({ text = "Copy transcript", enabled = s.copyable == true, onClick = "onCopyTranscript" }),
  })
end

-- The delivery row names the mechanism and the outcome, and it is where a held
-- paste is re-armed. Nothing here claims the text landed: an accepted chord is
-- reported as an attempt.
local function deliveryRow(s)
  local delivery = type(s.delivery) == "table" and s.delivery or {}
  local paste = type(s.paste) == "table" and s.paste or {}
  local state = delivery.state or "idle"
  local color = "on_surface_variant"
  if state == "held" then
    color = "tertiary"
  elseif state == "failed" then
    color = "error"
  elseif state == "attempted" then
    color = "primary"
  end
  local message = type(delivery.message) == "string" and delivery.message or ""
  if message == "" then message = type(paste.message) == "string" and paste.message or "" end
  local manual = noctalia.getConfig("delivery") == "manual"
  return ui.column({ gap = 6 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = "Delivery", fontSize = 12, color = "on_surface_variant" }),
      ui.spacer({ flexGrow = 1 }),
      ui.button({ text = "Paste now", variant = "ghost", enabled = s.copyable == true and not manual, onClick = "onDeliver" }),
    }),
    ui.label({ text = message, fontSize = 12, color = color, maxWidth = LABEL_WIDTH }),
  })
end

local function jobRow(s, recording, idle)
  return ui.row({ gap = 8, align = "center" }, {
    ui.button({ text = "Transcribe file", variant = "ghost", enabled = idle and recording ~= "", onClick = "onTranscribe" }),
    ui.spacer({ flexGrow = 1 }),
    ui.button({ text = "Close", variant = "ghost", onClick = "onClosePanel" }),
  })
end

local function render()
  local s = state()
  local recording = configPath("recording")
  local threads = noctalia.getConfig("threads")
  if type(threads) ~= "number" then threads = 4 end
  local mic = type(s.microphone) == "table" and s.microphone or {}
  local micLabel = mic.state == "ok" and tostring(mic.name) or (mic.id ~= "" and mic.id or "none selected")
  local info = string.format("Backend CPU only. %d threads. Microphone: %s", math.floor(threads), micLabel)
  panel.render(ui.column({ gap = 10, padding = 16 }, {
    ui.label({ text = "Dictation", fontSize = 16, fontWeight = "bold" }),
    setupBanner(s),
    ui.label({ text = statusText(s), color = severityColor(s.severity), maxWidth = LABEL_WIDTH }),
    ui.label({ text = info, fontSize = 12, color = "on_surface_variant", maxWidth = LABEL_WIDTH }),
    microphoneRow(s),
    ui.separator(),
    transcriptArea(s),
    deliveryRow(s),
    recordingRow(s),
    jobRow(s, recording, s.activity == "idle" or s.activity == nil),
  }))
end

function onOpen(_context)
  isOpen = true
  -- The controller cannot ask the compositor about a layer surface, so the panel
  -- publishes the fact that it holds the keyboard: a paste sent now would land in
  -- the panel instead of the window the transcript belongs to.
  noctalia.state.set("dictation.panelOpen", true)
  render()
end

function onClose()
  isOpen = false
  noctalia.state.set("dictation.panelOpen", false)
end

function onRecord()
  sendCommand("record")
end

function onStop()
  sendCommand("stop")
end

function onCancel()
  sendCommand("cancel")
end

function onPlay()
  sendCommand("play")
end

function onRetry()
  sendCommand("retry")
end

function onTranscribe()
  sendCommand("import")
end

function onVerify()
  sendCommand("verify")
end

function onRefreshSources()
  sendCommand("sources")
end

function onMicrophoneSelected(index, _text)
  local s = state()
  local list = type(s.sources) == "table" and type(s.sources.list) == "table" and s.sources.list or {}
  local position = tonumber(index)
  local source = position and list[position + 1]
  if type(source) == "table" and type(source.id) == "string" then
    sendCommand("select", { source = source.id })
  end
end

function onDeliver()
  sendCommand("deliver")
end

function onOpenSettings()
  noctalia.openSettings()
end

function onClosePanel()
  panel.close()
end

function onTranscriptEdited(text)
  if type(text) == "string" then draft = text end
end

function onCopyTranscript()
  local s = state()
  local text = type(draft) == "string" and draft or ""
  if text == "" then text = type(s.transcript) == "string" and s.transcript or "" end
  if text == "" then return end
  if noctalia.copyToClipboard(text, "text/plain") then
    noctalia.notify("Dictation", "Transcript copied.")
  else
    noctalia.notifyError("Dictation", "Could not copy the transcript.")
  end
end

noctalia.state.watch("dictation", function()
  if isOpen then render() end
end)
