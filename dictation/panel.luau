-- Panel view: setup state, live job status, and the transcript the user reads and
-- copies. Everything it shows comes from the controller's published state.

local WIDTH = 460
local LABEL_WIDTH = WIDTH - 32

local isOpen = false
local draft = nil
local draftKey = ""
local commandSeq = 0

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

local function sendCommand(action)
  commandSeq = commandSeq + 1
  noctalia.state.set("dictation.command", { seq = commandSeq, action = action })
end

local function statusText(s)
  if s.activity == "running" then
    -- A job whose helper went silent is still owned, so the panel reports the
    -- lost contact instead of claiming the inference is progressing normally.
    if s.severity == "error" and type(s.message) == "string" and s.message ~= "" then
      return s.message
    end
    local elapsed = 0
    local job = s.job
    if type(job) == "table" and type(job.elapsedSeconds) == "number" then
      elapsed = job.elapsedSeconds
    end
    return string.format("Transcribing. %d:%02d elapsed.", math.floor(elapsed / 60), elapsed % 60)
  end
  if s.activity == "verifying" then return "Verifying the executable and hashing the files." end
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

local function buttonRow(s, recording)
  local canStart = s.activity == "idle" and recording ~= ""
  return ui.row({ gap = 8, align = "center" }, {
    ui.button({ text = "Transcribe", variant = "primary", enabled = canStart, onClick = "onTranscribe" }),
    ui.button({ text = "Cancel", variant = "destructive", enabled = s.activity == "running", onClick = "onCancel" }),
    ui.spacer({ flexGrow = 1 }),
    ui.button({
      text = "Copy transcript",
      enabled = s.copyable == true,
      onClick = "onCopyTranscript",
    }),
    ui.button({ text = "Close", variant = "ghost", onClick = "onClosePanel" }),
  })
end

local function render()
  local s = state()
  local recording = configPath("recording")
  local threads = noctalia.getConfig("threads")
  if type(threads) ~= "number" then threads = 4 end
  local info = string.format("Backend CPU only. %d threads. Recording: %s",
    math.floor(threads),
    recording ~= "" and recording or "none selected")
  panel.render(ui.column({ gap = 10, padding = 16 }, {
    ui.label({ text = "Dictation", fontSize = 16, fontWeight = "bold" }),
    setupBanner(s),
    ui.label({ text = statusText(s), color = severityColor(s.severity), maxWidth = LABEL_WIDTH }),
    ui.label({ text = info, fontSize = 12, color = "on_surface_variant", maxWidth = LABEL_WIDTH }),
    ui.separator(),
    transcriptArea(s),
    buttonRow(s, recording),
  }))
end

function onOpen(_context)
  isOpen = true
  render()
end

function onClose()
  isOpen = false
end

function onTranscribe()
  sendCommand("import")
end

function onCancel()
  sendCommand("cancel")
end

function onVerify()
  sendCommand("verify")
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
