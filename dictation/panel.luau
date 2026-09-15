-- Panel view: microphone choice, live job status, and the transcript the user
-- reads and copies. Everything it shows comes from the controller's state.

local WIDTH = 460
local LABEL_WIDTH = WIDTH - 32

local isOpen = false
local draft = nil
local draftKey = ""
local commandSeq = 0
-- The history detail keeps its own draft, so an edit made while reading an older
-- dictation never becomes the current job's transcript.
local historyJob = ""
local historyDraft = nil
local historyDraftKey = ""
local historyNote = ""
-- A destructive action is armed first and only sent on the next confirmation, so
-- "Delete dictation" is never one stray click away from removing audio.
local historyConfirm = ""
local diagnosticsConfirm = false

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

local function sizeLabel(bytes)
  if type(bytes) ~= "number" then return "unknown" end
  if bytes >= 1073741824 then return string.format("%.1f GB", bytes / 1073741824) end
  if bytes >= 1048576 then return string.format("%.1f MB", bytes / 1048576) end
  if bytes >= 1024 then return string.format("%.0f kB", bytes / 1024) end
  return tostring(math.floor(bytes)) .. " B"
end

-- The helper's outcome codes are the durable contract; these are the few that
-- read better as words than as the code with its underscores opened up.
local OUTCOME_TEXT = {
  ok = "Transcribed",
  running = "In progress",
  interrupted = "Interrupted",
  cancelled = "Cancelled",
  invalid_recording = "No usable audio",
  invalid_wav = "No usable audio",
  recorder_failed = "Recorder failed",
  recorder_unavailable = "Recorder unavailable",
  engine_unavailable = "Engine unavailable",
  engine_failed = "Engine failed",
  engine_incompatible = "Engine incompatible",
}

local function historyList(s)
  local history = type(s.history) == "table" and s.history or {}
  return type(history.list) == "table" and history.list or {}, history
end

-- A job this controller is still working on has no summary yet, so the helper
-- reports it as interrupted. The live phase is this session's, not the disk's, so
-- it is named here rather than written back over the durable record.
local function historyLive(s, entry)
  local job = type(s.job) == "table" and s.job or nil
  if not job or type(entry) ~= "table" or entry.id ~= job.id then return false end
  local activity = s.activity or "idle"
  return activity == "running" or activity == "recording"
end

local function historyOutcome(s, entry)
  if historyLive(s, entry) then return "In progress" end
  local code = type(entry) == "table" and type(entry.outcome) == "string" and entry.outcome or ""
  if code == "" then return "Unknown" end
  return OUTCOME_TEXT[code] or string.gsub(string.gsub(code, "_", " "), "^%l", string.upper)
end

local function historyLabel(s, entry)
  local parts = {}
  if type(entry.timestamp) == "string" and entry.timestamp ~= "" then table.insert(parts, entry.timestamp) end
  if type(entry.duration) == "string" and entry.duration ~= "" then table.insert(parts, entry.duration) end
  table.insert(parts, historyOutcome(s, entry))
  if type(entry.preview) == "string" and entry.preview ~= "" then table.insert(parts, entry.preview) end
  return table.concat(parts, "  \u{00b7}  ")
end

local function historyColor(s, entry)
  if historyLive(s, entry) then return "primary" end
  if entry.state == "interrupted" then return "tertiary" end
  return severityColor(entry.severity)
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

local function editedDraft(s)
  -- The panel can show an edited transcript, and that is the text the user sees: it is
  -- what Copy copies and what Paste now sends. The draft only counts while it
  -- belongs to the transcript on screen - a draft left over from an earlier job is
  -- not an edit of this one, and then the saved transcript is used instead.
  if type(draft) ~= "string" or type(s) ~= "table" then return nil end
  if draftKey ~= tostring(s.transcriptPath) then return nil end
  if draft == s.transcript then return nil end
  return draft
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

-- The recording shortcut is a compositor binding, so this row shows the proposed
-- chord, what the compositor currently reports for it, and the two actions that
-- change it. Nothing here installs anything by itself: both writes go through the
-- controller, which refuses a chord somebody else already holds.
local function shortcutRow(s)
  local shortcut = type(s.shortcut) == "table" and s.shortcut or {}
  local state = shortcut.state or "unknown"
  local chord = type(shortcut.chord) == "string" and shortcut.chord or "Super+Alt+D"
  local color = "on_surface_variant"
  if state == "error" then
    color = "error"
  elseif state == "conflict" then
    color = "tertiary"
  elseif state == "installed" then
    color = "primary"
  end
  local busy = state == "working"
  local message = type(shortcut.message) == "string" and shortcut.message or "Not checked yet."
  return ui.column({ gap = 6 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = "Recording shortcut (" .. chord .. ")", fontSize = 12, color = "on_surface_variant" }),
      ui.spacer({ flexGrow = 1 }),
      ui.button({ text = "Check again", variant = "ghost", enabled = not busy, onClick = "onCheckShortcut" }),
    }),
    ui.label({ text = message, fontSize = 12, color = color, maxWidth = LABEL_WIDTH }),
    ui.row({ gap = 8, align = "center" }, {
      ui.button({
        text = state == "installed" and "Install again" or "Install shortcut",
        variant = state == "installed" and "ghost" or "primary",
        enabled = shortcut.canInstall == true and not busy,
        onClick = "onInstallShortcut",
      }),
      ui.button({
        text = "Undo shortcut",
        variant = "ghost",
        enabled = shortcut.canRemove == true and not busy,
        onClick = "onRemoveShortcut",
      }),
    }),
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

-- The history is the helper's durable record, so it lists what happened across
-- panel closes, reloads and restarts. Selecting an entry exposes the whole text;
-- Play, Retry, Export text and the two deletes act on that entry's own files,
-- never on the current job.
local function confirmBox(text)
  return ui.column({ gap = 6, fill = "error/0.12", radius = 8, padding = 10 }, {
    ui.label({ text = text, fontSize = 12, color = "error", maxWidth = LABEL_WIDTH }),
    ui.row({ gap = 8, align = "center" }, {
      ui.button({ text = "Confirm delete", variant = "destructive", onClick = "onHistoryConfirm" }),
      ui.button({ text = "Keep", variant = "ghost", onClick = "onHistoryCancel" }),
    }),
  })
end

local function historySection(s)
  local list, history = historyList(s)
  local idle = (s.activity or "idle") == "idle"
  local options, selected = {}, 1
  for index, entry in ipairs(list) do
    options[index] = historyLabel(s, entry)
    if entry.id == historyJob then selected = index end
  end
  local rows = {
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = "Recent dictations", fontSize = 12, color = "on_surface_variant" }),
      ui.spacer({ flexGrow = 1 }),
      ui.button({ text = "Clear history", variant = "ghost", enabled = history.state == "ok", onClick = "onHistoryClear" }),
      ui.button({ text = "Refresh", variant = "ghost", onClick = "onRefreshHistory" }),
    }),
  }
  -- Storage use comes from the helper's own accounting of its data directory, so
  -- it counts what the plugin saved rather than whatever happens to be on disk.
  local storage = type(history.storage) == "table" and history.storage or nil
  if storage then
    local text = string.format("Stored: %d dictation%s, %s", storage.jobsCount or 0, (storage.jobsCount == 1) and "" or "s", sizeLabel(storage.jobsBytes))
    if type(storage.freeBytes) == "number" then
      text = text .. "  \u{00b7}  " .. sizeLabel(storage.freeBytes) .. " free"
    end
    table.insert(rows, ui.label({ text = text, fontSize = 10, color = "on_surface_variant", maxWidth = LABEL_WIDTH }))
  end
  -- A retention failure is a real partial deletion, so it stays visible next to
  -- the rows it left behind instead of only in a notification that is gone.
  local retention = type(history.retention) == "table" and history.retention or nil
  if retention and type(retention.failures) == "table" and #retention.failures > 0 then
    table.insert(rows, ui.label({
      text = "Automatic retention could not remove some files: " .. table.concat(retention.failures, "; "),
      fontSize = 12,
      color = "error",
      maxWidth = LABEL_WIDTH,
    }))
  end
  if type(history.note) == "string" and history.note ~= "" then
    table.insert(rows, ui.label({ text = history.note, fontSize = 12, color = "tertiary", maxWidth = LABEL_WIDTH }))
  end
  if historyConfirm == "clear" then
    table.insert(rows, confirmBox("Delete every saved dictation, including audio and text, except work that is still running?"))
  end
  if #options == 0 then
    local failed = history.state == "error"
    local message = failed and (history.message ~= "" and history.message or "Could not read the history.") or "No saved dictations yet."
    table.insert(rows, ui.label({ text = message, fontSize = 12, color = failed and "error" or "on_surface_variant", maxWidth = LABEL_WIDTH }))
    return ui.column({ gap = 6, }, rows)
  end
  table.insert(rows, ui.select({
    key = "history",
    options = options,
    selectedIndex = selected - 1,
    onChange = "onHistorySelected",
  }))
  local entry = list[selected]
  if type(entry) == "table" then
    local key = type(entry.transcriptPath) == "string" and entry.transcriptPath or ""
    if historyDraft == nil or historyDraftKey ~= key then
      historyDraftKey = key
      historyDraft = key ~= "" and (noctalia.readFile(key) or "") or ""
    end
    local usable = entry.recordingUsable == true and type(entry.recordingPath) == "string" and entry.recordingPath ~= ""
    local retriedFrom = type(entry.retriesOf) == "string" and entry.retriesOf or ""
    table.insert(rows, ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = historyOutcome(s, entry), fontSize = 12, color = historyColor(s, entry), flexGrow = 1 }),
      -- A retry is a new job, so "attempt 1" alone would hide which dictation it
      -- transcribed again; name that dictation instead.
      ui.label({ text = retriedFrom ~= "" and ("retry of " .. retriedFrom) or ("attempt " .. tostring(entry.attempts or 0)), fontSize = 10, color = "on_surface_variant" }),
    }))
    if type(entry.message) == "string" and entry.message ~= "" then
      table.insert(rows, ui.label({ text = entry.message, fontSize = 12, color = "on_surface_variant", maxLines = 3, maxWidth = LABEL_WIDTH }))
    end
    if historyNote ~= "" then
      table.insert(rows, ui.label({ text = historyNote, fontSize = 12, color = "tertiary", maxWidth = LABEL_WIDTH }))
    end
    table.insert(rows, ui.input({
      key = "history:" .. tostring(entry.id),
      value = historyDraft or "",
      multiline = true,
      onChange = "onHistoryEdited",
    }))
    table.insert(rows, ui.row({ gap = 8, align = "center" }, {
      ui.button({ text = "Copy", enabled = (historyDraft or "") ~= "", onClick = "onHistoryCopy" }),
      ui.button({ text = "Play", enabled = usable and idle, onClick = "onHistoryPlay" }),
      ui.button({ text = "Retry", variant = "primary", enabled = usable and idle, onClick = "onHistoryRetry" }),
      ui.spacer({ flexGrow = 1 }),
      ui.label({ text = entry.id, fontSize = 10, color = "on_surface_variant" }),
    }))
    -- Explicit intent for the two destructive actions: each is armed here and
    -- sent only from the confirmation that follows.
    local armed = historyConfirm == "record:" .. entry.id and "Delete only this recording? The transcript and its attempt history stay, and playback and Retry stop being offered."
      or historyConfirm == "dictation:" .. entry.id and "Delete this whole dictation: its recording, transcript and every attempt?"
    if armed then
      table.insert(rows, confirmBox(armed))
    else
      table.insert(rows, ui.row({ gap = 8, align = "center" }, {
        ui.button({ text = "Export text", variant = "ghost", enabled = key ~= "", onClick = "onHistoryExportText" }),
        ui.button({ text = "Delete recording", variant = "ghost", enabled = usable, onClick = "onHistoryDeleteRecording" }),
        ui.button({ text = "Delete dictation", variant = "destructive", onClick = "onHistoryDeleteDictation" }),
        ui.spacer({ flexGrow = 1 }),
      }))
    end
    if not usable then
      local reason = type(entry.recordingMessage) == "string" and entry.recordingMessage ~= "" and entry.recordingMessage or "The saved audio is not usable, so this dictation cannot be played or retried."
      table.insert(rows, ui.label({ text = reason, fontSize = 12, color = "tertiary", maxWidth = LABEL_WIDTH }))
    end
  end
  return ui.column({ gap = 6, }, rows)
end

-- Diagnostics are opt-in and graphical: opening them prepares this plugin's own
-- bounded metadata and shows it verbatim, and only the confirmation below
-- exports those same bytes to a local file. No audio, transcript text, raw
-- recognition log or environment value is ever included.
local function diagnosticsSection(s)
  local d = type(s.diagnostics) == "table" and s.diagnostics or {}
  local state = type(d.state) == "string" and d.state or "idle"
  local preview = type(d.preview) == "string" and d.preview or ""
  local busy = state == "preparing" or state == "exporting"
  local rows = {
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = "Diagnostics", fontSize = 12, color = "on_surface_variant" }),
      ui.spacer({ flexGrow = 1 }),
      ui.button({ text = preview ~= "" and "Rebuild preview" or "Open diagnostics", variant = "ghost", enabled = not busy, onClick = "onDiagnosticsPreview" }),
      ui.button({ text = "Export diagnostics", enabled = preview ~= "" and not busy, onClick = "onDiagnosticsExport" }),
    }),
  }
  local color = state == "error" and "error" or "on_surface_variant"
  local message = type(d.message) == "string" and d.message or ""
  if message == "" then
    message = "Nothing is collected until you ask. The export contains no audio and no transcripts."
  end
  table.insert(rows, ui.label({ text = message, fontSize = 12, color = color, maxWidth = LABEL_WIDTH }))
  if preview ~= "" then
    -- Read-only rendered text, not an editable field: what is on screen is exactly
    -- the file the export copies, so the two cannot drift apart.
    table.insert(rows, ui.scroll({ height = 200, fill = "surface_variant/0.4", radius = 8, padding = 8 }, {
      ui.markdown({ text = "```json\n" .. preview .. "\n```" }),
    }))
    if diagnosticsConfirm then
      table.insert(rows, ui.column({ gap = 6, fill = "primary/0.12", radius = 8, padding = 10 }, {
        ui.label({ text = "Export this exact text, unchanged, to a file in your home directory? Nothing leaves this machine.", fontSize = 12, color = "primary", maxWidth = LABEL_WIDTH }),
        ui.row({ gap = 8, align = "center" }, {
          ui.button({ text = "Confirm export", variant = "primary", onClick = "onDiagnosticsConfirm" }),
          ui.button({ text = "Cancel", variant = "ghost", onClick = "onDiagnosticsCancel" }),
        }),
      }))
    end
    if type(d.exportedPath) == "string" and d.exportedPath ~= "" then
      table.insert(rows, ui.label({ text = "Exported to " .. d.exportedPath, fontSize = 10, color = "on_surface_variant", maxWidth = LABEL_WIDTH }))
    end
  end
  return ui.column({ gap = 6 }, rows)
end

local function render()
  local s = state()
  local recording = configPath("recording")
  local threads = noctalia.getConfig("threads")
  if type(threads) ~= "number" then threads = 4 end
  local mic = type(s.microphone) == "table" and s.microphone or {}
  local micLabel = mic.state == "ok" and tostring(mic.name) or (mic.id ~= "" and mic.id or "none selected")
  local info = string.format("Backend CPU only. %d threads. Microphone: %s", math.floor(threads), micLabel)
  -- The panel body scrolls: storage accounting and the diagnostics preview add
  -- real content below the history, and nothing may be reachable only by resizing.
  panel.render(ui.scroll({ flexGrow = 1 }, {
    ui.column({ gap = 10, padding = 16 }, {
      ui.label({ text = "Dictation", fontSize = 16, fontWeight = "bold" }),
      setupBanner(s),
      ui.label({ text = statusText(s), color = severityColor(s.severity), maxWidth = LABEL_WIDTH }),
      ui.label({ text = info, fontSize = 12, color = "on_surface_variant", maxWidth = LABEL_WIDTH }),
      microphoneRow(s),
      shortcutRow(s),
      ui.separator(),
      transcriptArea(s),
      deliveryRow(s),
      recordingRow(s),
      jobRow(s, recording, s.activity == "idle" or s.activity == nil),
      ui.separator(),
      historySection(s),
      diagnosticsSection(s),
    }),
  }))
end

function onOpen(_context)
  isOpen = true
  -- The controller cannot ask the compositor about a layer surface, so the panel
  -- publishes the fact that it holds the keyboard: a paste sent now would land in
  -- the panel instead of the window the transcript belongs to.
  noctalia.state.set("dictation.panelOpen", true)
  -- Opening the panel re-reads the durable history, so a job from an earlier
  -- session is visible without restarting anything.
  sendCommand("history-refresh")
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

function onInstallShortcut()
  sendCommand("shortcut-install")
end

function onRemoveShortcut()
  sendCommand("shortcut-remove")
end

function onCheckShortcut()
  sendCommand("shortcut-refresh")
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
  sendCommand("deliver", { text = editedDraft(state()) })
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

function onRefreshHistory()
  historyNote = ""
  historyConfirm = ""
  sendCommand("history-refresh")
end

function onHistorySelected(index, _text)
  local s = state()
  local list = historyList(s)
  local position = tonumber(index)
  local entry = position and list[position + 1]
  if type(entry) ~= "table" then return end
  historyJob = entry.id
  historyNote = ""
  -- Nil is "not loaded yet", so an entry with no transcript still reloads. Clearing
  -- the key alone would keep the previous dictation's text on screen and copyable,
  -- because an entry with no transcript has an empty key too.
  historyDraft = nil
  render()
end

-- The entry the history buttons act on: the selection, or the newest one the
-- list shows when nothing has been chosen yet.
local function selectedHistory(s)
  local list = historyList(s)
  for _, entry in ipairs(list) do
    if entry.id == historyJob then return entry end
  end
  return list[1]
end

-- Arming is local, so a destructive action shows what it would remove in the same
-- view the user is already reading before anything is sent to the helper.
local function armHistory(action)
  local entry = selectedHistory(state())
  if type(entry) ~= "table" then return end
  historyNote = ""
  historyConfirm = action .. ":" .. entry.id
  render()
end

function onHistoryEdited(text)
  if type(text) == "string" then historyDraft = text end
end

function onHistoryCopy()
  local text = historyDraft or ""
  if text == "" then return end
  -- Copying never starts a recording and never focuses another window, so an
  -- error is reported here in the panel instead of only in a notification.
  if noctalia.copyToClipboard(text, "text/plain") then
    historyNote = "Copied the text you see, not the saved file."
    noctalia.notify("Dictation", "Transcript copied.")
  else
    historyNote = "Could not copy the transcript. Select the text and copy it by hand."
  end
  render()
end

function onHistoryPlay()
  local entry = selectedHistory(state())
  if type(entry) ~= "table" then return end
  historyNote = ""
  sendCommand("history-play", { jobId = entry.id })
end

function onHistoryRetry()
  local entry = selectedHistory(state())
  if type(entry) ~= "table" then return end
  historyNote = ""
  sendCommand("history-retry", { jobId = entry.id })
end

-- Two steps for anything destructive: arm, read what it will remove, then confirm.
function onHistoryDeleteRecording()
  armHistory("record")
end

function onHistoryDeleteDictation()
  armHistory("dictation")
end

function onHistoryClear()
  historyNote = ""
  historyConfirm = "clear"
  render()
end

function onHistoryConfirm()
  local entry = selectedHistory(state())
  local armed = historyConfirm
  historyConfirm = ""
  if armed == "clear" then
    sendCommand("history-clear")
  elseif type(entry) == "table" and armed == "record:" .. entry.id then
    sendCommand("history-delete-recording", { jobId = entry.id })
  elseif type(entry) == "table" and armed == "dictation:" .. entry.id then
    sendCommand("history-delete", { jobId = entry.id })
  end
  render()
end

function onHistoryCancel()
  historyConfirm = ""
  render()
end

function onHistoryExportText()
  local entry = selectedHistory(state())
  if type(entry) ~= "table" then return end
  historyNote = ""
  sendCommand("history-export-text", { jobId = entry.id })
end

-- Opening the diagnostics is the explicit request; exporting needs a second one.
function onDiagnosticsPreview()
  diagnosticsConfirm = false
  sendCommand("diagnostics-preview")
end

function onDiagnosticsExport()
  diagnosticsConfirm = true
  render()
end

function onDiagnosticsConfirm()
  diagnosticsConfirm = false
  sendCommand("diagnostics-export")
  render()
end

function onDiagnosticsCancel()
  diagnosticsConfirm = false
  render()
end

function onCopyTranscript()
  local s = state()
  local text = editedDraft(s) or ""
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
