-- Owns the single job and publishes the state the panel and the bar widget
-- render. The bundled Python helper runs detached and mirrors every outcome into
-- a summary file, because a captured-process callback is capped far below a long
-- job and because the helper owns the recorder, the watchdog and the children.
--
-- Recording is owned the same way: the helper records the microphone the user
-- chose, and this controller keeps a lease on the job. A controller that dies
-- stops refreshing the lease, and the helper releases the microphone on its own.

local PLUGIN_DIR = noctalia.pluginDir()
local HELPER = type(PLUGIN_DIR) == "string" and (PLUGIN_DIR .. "/dictation-helper.py") or ""

local DATA = noctalia.pluginDataDir()
if type(DATA) ~= "string" then DATA = nil end
local JOBS = DATA and (DATA .. "/jobs") or nil
-- Names the one job this plugin currently owns. It lives on disk because the
-- plugin's own state does not survive a reload, and a detached helper does.
local JOB_POINTER = DATA and (DATA .. "/current-job") or nil
local SOURCES_PATH = DATA and (DATA .. "/sources.json") or nil
local MIC_PATH = DATA and (DATA .. "/microphone.json") or nil
-- The last recording the panel can play or transcribe again. The job pointer is
-- gone once a job ends, so a recording the user has not dealt with yet needs its
-- own path to outlive the job and the plugin's state.
local LAST_RECORDING_PATH = DATA and (DATA .. "/last-recording") or nil

-- One rootless delivery mechanism: the finished transcript goes on the clipboard,
-- and the compositor itself sends the single paste chord. `hyprctl dispatch
-- sendshortcut CTRL,V,` reaches the focused client through Hyprland's own seat: it
-- writes the chord's modifier state (ctrl) into that client first, sends the key
-- straight to the client instead of through the bind matcher, and clears the
-- modifiers again afterwards. A modifier the user still holds is therefore
-- replaced rather than consulted - the application receives exactly Ctrl+V
-- whatever the keyboard holds - and no speech is ever typed as keystrokes.
-- ydotool is refused on purpose: it needs a running daemon and access to the input
-- devices, and this plugin never asks for either.
local PASTE_TOOL = "hyprctl"
-- The empty window selector is deliberate: `sendshortcut` re-points focus, and
-- restores it afterwards, when it is given a window to target, so the chord is
-- addressed to the focused client and the focus check below stays the one thing
-- that decides where the paste goes. The trailing comma is what carries that
-- empty selector, and the dispatcher refuses a dispatch with fewer than three
-- fields as invalid arguments.
local PASTE_CHORD = { PASTE_TOOL, "dispatch", "sendshortcut", "CTRL,V," }
-- The focused window is read from the compositor; its address is the identity a
-- paste is checked against.
local WINDOW_QUERY = { PASTE_TOOL, "-j", "activewindow" }
-- The chord is sent no sooner than this after a job finished, so a panel that is
-- closing or a focus change that is landing has a moment to settle. It is not a
-- modifier wait: the modifier state of the chord comes from the compositor, so a
-- modifier the user still holds cannot join it either way.
local PASTE_SETTLE_MS = 500
-- A compositor answer that never arrives must not leave the panel saying
-- "checking" for the rest of the session.
local PASTE_STALL_MS = 30 * 1000

-- A window class is all that can be read, so these holds are class level and the
-- plugin never claims to detect a password field: a window whose class looks like
-- a shell or a password manager is held for an explicit action instead.
local TERMINAL_CLASSES = {
  kitty = true,
  foot = true,
  alacritty = true,
  wezterm = true,
  konsole = true,
  ghostty = true,
  xterm = true,
  urxvt = true,
  st = true,
  tilix = true,
  terminator = true,
  ["gnome-terminal"] = true,
  ["xfce4-terminal"] = true,
  ["org.wezfurlong.wezterm"] = true,
  ["com.mitchellh.ghostty"] = true,
}
local PASSWORD_CLASSES = {
  keepassxc = true,
  keepass = true,
  bitwarden = true,
  ["1password"] = true,
  ["onepassword"] = true,
  seahorse = true,
  ["gnome-keyring"] = true,
  passwordsafe = true,
}
local HOLD_FRAGMENTS = { "term", "keepass", "bitwarden", "1password", "password", "keyring" }
local HELD_MESSAGE = {
  terminal = "Paste held: a terminal would receive the text at its prompt. Use Paste now to send it anyway, or copy the transcript.",
  password = "Paste held: the window looks like a password manager. Use Paste now to send it anyway, or copy the transcript.",
  unknown = "Paste held: the focused window could not be identified. Use Paste now while the target window is focused, or copy the transcript.",
}

-- How long a helper may stay silent before the controller reports the lost
-- contact. The helper rewrites its heartbeat every few seconds, so silence this
-- long means the plugin can no longer see it working.
local RUN_SILENT_SECONDS = 60
local PROBE_STALL_SECONDS = 10 * 60
-- A process check whose callback never arrives is retried this often; a missing
-- answer is never read as one.
local PROCESS_CHECK_RETRY_MS = 5000
-- Recording is refused below this free space so a full disk cannot destroy an
-- older job's files or leave a truncated recording.
local MIN_FREE_BYTES = 20 * 1024 * 1024

local S = {
  activity = "idle", -- idle | recording | running | verifying
  phase = "",
  setup = { state = "unknown", message = "" },
  sources = { state = "idle", message = "", list = {} },
  microphone = { id = "", name = "", state = "unset", message = "" },
  recording = { path = "", exists = false },
  job = nil,
  outcome = nil,
  severity = nil,
  message = "",
  copyable = false,
  transcript = "",
  transcriptPath = "",
  resultPath = "",
  attempt = 0,
  controlTokens = {},
  -- idle | manual | waiting | checking | pasting | attempted | held | failed
  delivery = { state = "idle", message = "" },
  -- The delivery mechanism itself, so the panel can name it and its state.
  paste = { state = "untested", tested = false, message = "Automatic paste waits for the first verification." },
}

local summaryPath = nil
local activityStartedAtMs = 0
local silenceReported = false
-- Lost contact is not lost ownership: a job is released only when the helper
-- reports or when the runtime confirms that no process for it is left.
-- nil = not asked yet, true = observed running, false = observed gone.
local jobProcessAlive = nil
local processCheckSinceMs = nil

local function publish()
  noctalia.state.set("dictation", S)
end

-- A refusal is not an outcome: the old record stays, and the new request is named.
local function refuse(message)
  S.message = message
  publish()
  noctalia.notifyError("Dictation", message)
end

local function configPath(key)
  local value = noctalia.getConfig(key)
  if type(value) ~= "string" then return "" end
  value = noctalia.string.trim(value)
  if value == "" then return "" end
  return noctalia.expandPath(value)
end

local function configThreads()
  local value = noctalia.getConfig("threads")
  if type(value) ~= "number" then return 4 end
  return math.floor(value)
end

local function shortHash(hash)
  if type(hash) ~= "string" or #hash < 16 then return "" end
  return hash:sub(1, 8) .. "..." .. hash:sub(#hash - 3)
end

-- A recorded file that changed size is no longer the file the recorded hash
-- describes. A file that cannot be inspected is left to the run-time check.
local function sameSize(entry)
  if type(entry) ~= "table" or type(entry.size) ~= "number" then return true end
  local info = noctalia.fileInfo(entry.path)
  if type(info) ~= "table" then return true end
  return info.size == entry.size
end

-- A summary file is written with a rename, so its presence means it is complete.
local function readSummary(path)
  local raw = noctalia.readFile(path)
  local summary = type(raw) == "string" and noctalia.json.decode(raw) or nil
  if type(summary) ~= "table" or type(summary.outcome) ~= "string" then return nil end
  return summary
end

local function readJob(jobId)
  local raw = noctalia.readFile(JOBS .. "/" .. jobId .. "/job.json")
  local job = type(raw) == "string" and noctalia.json.decode(raw) or nil
  return type(job) == "table" and job or nil
end

local function readStatus(jobId)
  local raw = noctalia.readFile(JOBS .. "/" .. jobId .. "/status.json")
  local status = type(raw) == "string" and noctalia.json.decode(raw) or nil
  return type(status) == "table" and status or nil
end

-- The last JSON line of a helper's stdout, used when a callback arrives before
-- the durable file is readable.
local function readLastJson(stdout)
  if type(stdout) ~= "string" then return nil end
  local last = nil
  for line in stdout:gmatch("[^\n]+") do
    if line:match("^%s*{") then last = line end
  end
  if not last then return nil end
  local value = noctalia.json.decode(last)
  return type(value) == "table" and value or nil
end

-- The delivery mechanism is setup too: which tool is used, whether it is
-- installed, and whether the compositor accepted it the last time setup ran.
local function refreshPaste()
  local tested = S.paste.tested == true
  if noctalia.getConfig("delivery") == "manual" then
    S.paste = { state = "manual", tested = tested, message = "Manual copy mode: the transcript is only copied when you ask for it." }
  elseif not noctalia.commandExists(PASTE_TOOL) then
    S.paste = { state = "missing", tested = false, message = "Automatic paste sends the chord with the compositor's `sendshortcut`, which needs " .. PASTE_TOOL .. ". It is not installed, so only copying works." }
  elseif tested then
    S.paste = {
      state = "ok",
      tested = true,
      message = "Automatic paste sends `sendshortcut CTRL,V` through " .. PASTE_TOOL .. ", and the compositor accepted it. The transcript is copied to the clipboard first, so a clipboard manager keeps it in its history.",
    }
  else
    S.paste = { state = "untested", tested = false, message = "Automatic paste sends `sendshortcut CTRL,V` through " .. PASTE_TOOL .. ". Verify and record tests it." }
  end
end

-- Cheap half of setup: it never starts a process, so it is safe on every config
-- change. The explicit probe is what records hashes and engine capabilities.
local function refreshSetup()
  refreshPaste()
  local engine, model = configPath("engine"), configPath("model")
  local reason = nil
  if not DATA then
    reason = "Setup required: the plugin data directory is unavailable."
  elseif not noctalia.commandExists("python3") then
    reason = "Setup required: python3 is not installed."
  elseif engine == "" then
    reason = "Setup required: choose the installed recognition executable."
  elseif not noctalia.fileExists(engine) then
    reason = "Setup required: the recognition executable does not exist: " .. engine
  elseif model == "" then
    reason = "Setup required: choose the GGUF model."
  elseif not noctalia.fileExists(model) then
    reason = "Setup required: the GGUF model does not exist: " .. model
  end
  if reason then
    S.setup = { state = "required", message = reason }
    return
  end

  local raw = noctalia.readFile(DATA .. "/setup.json")
  local record = type(raw) == "string" and noctalia.json.decode(raw) or nil
  if type(record) ~= "table" then
    S.setup = { state = "unknown", message = "Setup is not verified yet. Verify and record the executable and model." }
    return
  end
  local recordedEngine = type(record.engine) == "table" and record.engine.path or ""
  local recordedModel = type(record.model) == "table" and record.model.path or ""
  if recordedEngine ~= engine or recordedModel ~= model then
    S.setup = { state = "stale", message = "Setup recorded a different executable or model. Verify and record again." }
    return
  end
  if not (sameSize(record.engine) and sameSize(record.model)) then
    S.setup = { state = "stale", message = "The recorded executable or model changed. Verify and record again." }
    return
  end
  S.setup = {
    state = "ok",
    message = "Setup verified.",
    engineSha256 = shortHash(record.engine.sha256),
    modelSha256 = shortHash(record.model.sha256),
  }
end

-- ── Microphone ───────────────────────────────────────────────────────────────

local function loadMicrophone()
  local raw = DATA and noctalia.readFile(MIC_PATH) or nil
  local record = type(raw) == "string" and noctalia.json.decode(raw) or nil
  if type(record) == "table" and type(record.id) == "string" and record.id ~= "" then
    S.microphone = {
      id = record.id,
      name = type(record.name) == "string" and record.name or record.id,
      state = "unknown",
      message = "",
    }
  else
    S.microphone = { id = "", name = "", state = "unset", message = "Choose a microphone in the panel." }
  end
end

-- The selection is reconciled against the live list, never silently replaced: a
-- microphone that is not present stays selected and is reported as missing.
local function applySources(sources)
  local list = {}
  for _, source in ipairs(sources) do
    if type(source) == "table" and type(source.id) == "string" and source.id ~= "" then
      table.insert(list, {
        id = source.id,
        name = type(source.name) == "string" and source.name or source.id,
        description = type(source.description) == "string" and source.description or source.id,
      })
    end
  end
  S.sources.list = list
  S.sources.state = "ok"
  S.sources.message = ""
  local chosen = S.microphone.id
  if chosen == "" then
    S.microphone.state = "unset"
    S.microphone.message = "Choose a microphone in the panel."
    return
  end
  for _, source in ipairs(list) do
    if source.id == chosen then
      S.microphone.state = "ok"
      S.microphone.name = source.description
      S.microphone.message = ""
      return
    end
  end
  S.microphone.state = "missing"
  S.microphone.message = "The selected microphone is not connected: " .. S.microphone.name
end

local function refreshSources()
  if not DATA or HELPER == "" or not SOURCES_PATH then
    S.sources.state = "error"
    S.sources.message = "Could not locate the bundled recognition helper."
    publish()
    return
  end
  S.sources.state = "loading"
  S.sources.message = "Reading the PipeWire graph."
  publish()
  local argv = { "python3", HELPER, "sources", "--data-dir", DATA }
  local accepted = noctalia.runAsync(argv, function(result)
    local summary = type(result) == "table" and readLastJson(result.stdout) or nil
    if type(summary) ~= "table" then
      summary = noctalia.fileExists(SOURCES_PATH) and readSummary(SOURCES_PATH) or nil
    end
    if type(summary) ~= "table" or summary.outcome ~= "ok" then
      S.sources.state = "error"
      S.sources.message = type(summary) == "table" and summary.message or "Could not read the PipeWire graph."
      publish()
      return
    end
    applySources(type(summary.sources) == "table" and summary.sources or {})
    publish()
  end, 30000)
  if accepted == false then
    S.sources.state = "error"
    S.sources.message = "Could not start the microphone scan."
    publish()
  end
end

local function selectSource(id)
  if type(id) ~= "string" or id == "" then return end
  -- The recorder holds the microphone it was started with, so a change while
  -- audio is being captured would be a lie the bar then repeats.
  if S.activity == "recording" then
    refuse("The recording uses the microphone it was started with. Stop or cancel it first.")
    return
  end
  local chosen = nil
  for _, source in ipairs(S.sources.list) do
    if source.id == id then chosen = source end
  end
  if not chosen then
    return -- a stale choice from a re-rendered list: ignore it, never guess
  end
  S.microphone = { id = chosen.id, name = chosen.description, state = "ok", message = "" }
  if MIC_PATH then
    local ok, err = noctalia.writeFile(MIC_PATH, noctalia.json.encode({ id = chosen.id, name = chosen.description }, true))
    if not ok then
      noctalia.notifyError("Dictation", "Could not save the microphone choice: " .. tostring(err))
    end
  end
  publish()
end

-- ── Activity helpers ─────────────────────────────────────────────────────────

-- Ends the current activity without losing the record of the job it belonged to;
-- `activity` is what makes a job live, and `S.job` is what the panel reports on.
local function resetActivity()
  if JOB_POINTER then noctalia.removeFile(JOB_POINTER) end
  if JOBS and S.job then noctalia.removeFile(JOBS .. "/" .. S.job.id .. ".lease") end
  S.activity = "idle"
  S.phase = ""
  summaryPath = nil
  silenceReported = false
  jobProcessAlive = nil
  processCheckSinceMs = nil
end

local function fail(message, outcome)
  if S.job then
    S.job.elapsedSeconds = math.max(0, math.floor((noctalia.nowMs() - S.job.startedAtMs) / 1000))
  end
  resetActivity()
  S.outcome = outcome or "internal"
  S.severity = "error"
  S.message = message
  S.copyable = false
  publish()
  noctalia.notifyError("Dictation", message)
end

local function busyMessage()
  if S.activity == "recording" then return "A recording is in progress. Stop or cancel it first." end
  if S.activity == "running" then return "A recognition job is already running. Cancel it first." end
  return "Setup verification is running; try again when it finishes."
end

-- A unique job id keeps the controller from ever reading another job's summary,
-- even for two jobs inside the same millisecond.
local function newJobId()
  local stamp = "job-" .. tostring(noctalia.nowMs())
  local candidate, index = stamp, 1
  while true do
    local info = noctalia.fileInfo(JOBS .. "/" .. candidate)
    if type(info) ~= "table" and not noctalia.fileExists(JOBS .. "/" .. candidate .. "/summary.json") then
      return candidate
    end
    index = index + 1
    candidate = stamp .. "-" .. tostring(index)
  end
end

local function summaryPathFor(jobId)
  return JOBS .. "/" .. jobId .. "/summary.json"
end

-- A restart forgets the plugin's state but not the recording on disk, so the last
-- one stays reachable for Play and Retry. Nothing is run automatically.
local function rememberRecording(path)
  if not LAST_RECORDING_PATH then return end
  if type(path) ~= "string" or path == "" or not noctalia.fileExists(path) then return end
  noctalia.writeFile(LAST_RECORDING_PATH, path)
end

-- The newest recording the job directories still hold. The pointer above is the
-- fast path; this walk is what keeps Play and Retry reachable when the pointer
-- was never written, so a recording that already exists is not lost with it.
local function newestRecordingOnDisk()
  if not JOBS or type(noctalia.listDir) ~= "function" then return "" end
  local entries = noctalia.listDir(JOBS)
  if type(entries) ~= "table" then return "" end
  local newest, newestMtime = "", nil
  for _, entry in ipairs(entries) do
    if type(entry) == "string" and entry ~= "" then
      local dir = entry:sub(1, 1) == "/" and entry or (JOBS .. "/" .. entry)
      local path = dir .. "/recording.wav"
      local info = noctalia.fileInfo(path)
      -- More than a WAV header, or the capture never wrote a frame. The helper
      -- rejects such a file anyway, so it is not offered as the recovered one.
      if type(info) == "table" and not info.isDir and (info.size or 0) > 44 then
        local mtime = type(info.mtime) == "number" and info.mtime or 0
        if newestMtime == nil or mtime > newestMtime then
          newest, newestMtime = path, mtime
        end
      end
    end
  end
  return newest
end

local function recallRecording()
  if not LAST_RECORDING_PATH or S.recording.path ~= "" then return end
  local raw = noctalia.readFile(LAST_RECORDING_PATH)
  local path = type(raw) == "string" and noctalia.string.trim(raw) or ""
  if path == "" or not noctalia.fileExists(path) then
    path = newestRecordingOnDisk()
  end
  if path == "" then return end
  S.recording = { path = path, exists = true }
end

-- The helper rewrites its heartbeat every few seconds; nil means it never wrote
-- one, so the plugin cannot tell a live helper from a dead one.
local function heartbeatAge(jobId)
  local raw = noctalia.readFile(JOBS .. "/" .. jobId .. "/heartbeat.json")
  local beat = type(raw) == "string" and noctalia.json.decode(raw) or nil
  if type(beat) ~= "table" or type(beat.ts) ~= "number" then return nil end
  return os.time() - beat.ts
end

local function activeJob()
  return S.activity == "running" or S.activity == "recording"
end

local function helperSilent()
  if not activeJob() or not S.job then return false end
  -- Give a freshly started or newly adopted job time to report at all.
  if (noctalia.nowMs() - activityStartedAtMs) / 1000 < RUN_SILENT_SECONDS then return false end
  local age = heartbeatAge(S.job.id)
  return age == nil or age > RUN_SILENT_SECONDS
end

local function refreshLease()
  if S.activity ~= "recording" or not S.job or not JOBS then return end
  noctalia.writeFile(JOBS .. "/" .. S.job.id .. ".lease", noctalia.json.encode({ ts = os.time() }))
end

local function diskFreeBytes()
  if not DATA or type(noctalia.diskStats) ~= "function" then return nil end
  local stats = noctalia.diskStats(DATA)
  if type(stats) ~= "table" then return nil end
  if type(stats.availableBytes) == "number" then return stats.availableBytes end
  if type(stats.freeBytes) == "number" then return stats.freeBytes end
  return nil
end

-- ── Delivering the transcript ───────────────────────────────────────────────

-- The window the current recording was started from, the paste that is queued but
-- has not touched the clipboard or the keyboard yet, and the window classes the
-- user has confirmed as paste targets in this session: a GUI target is only
-- delivered to automatically once it has been confirmed by hand.
local destination = nil
local pendingDelivery = nil
local validatedTargets = {}

local function holdKindFor(class)
  if type(class) ~= "string" or class == "" then return "unknown" end
  local name = class:lower()
  if TERMINAL_CLASSES[name] then return "terminal" end
  if PASSWORD_CLASSES[name] then return "password" end
  for _, fragment in ipairs(HOLD_FRAGMENTS) do
    if name:find(fragment, 1, true) then
      return fragment == "term" and "terminal" or "password"
    end
  end
  return nil
end

local function deliveryPath(jobId)
  return JOBS .. "/" .. jobId .. "/delivery.json"
end

local function readDelivery(jobId)
  local raw = noctalia.readFile(deliveryPath(jobId))
  local record = type(raw) == "string" and noctalia.json.decode(raw) or nil
  return type(record) == "table" and record or nil
end

-- The attempt marker is durable before anything is copied or typed, so a paste
-- interrupted by a crash is visible afterwards and is never repeated on its own.
local function writeDelivery(record)
  return noctalia.writeFile(deliveryPath(record.jobId), noctalia.json.encode(record, true))
end

-- The panel keeps the keyboard while it is open, and the compositor is never
-- asked about a layer surface, so the panel publishes its own state.
local function panelHoldsKeyboard()
  return noctalia.state.get("dictation.panelOpen") == true
end

local function setDelivery(state, message)
  S.delivery = { state = state, message = message }
  publish()
end

-- A hold is not a failed recognition and not a paste: the text stays where it is,
-- and the panel keeps offering Copy and Paste now.
local function holdDelivery(message)
  pendingDelivery = nil
  setDelivery("held", message)
  noctalia.notify("Dictation", message)
end

-- The focused window comes from the compositor, never from a guess: a window that
-- cannot be read is reported, and nothing is pasted into it.
local function queryDestination(callback)
  if not noctalia.commandExists("hyprctl") then
    callback(nil, "hyprctl is not installed, so the focused window cannot be identified.")
    return
  end
  local accepted = noctalia.runAsync(WINDOW_QUERY, function(result)
    if type(result) ~= "table" or result.exitCode ~= 0 then
      callback(nil, "hyprctl could not report the focused window.")
      return
    end
    local text = type(result.stdout) == "string" and noctalia.string.trim(result.stdout) or ""
    local window = text ~= "" and noctalia.json.decode(text) or nil
    local address = type(window) == "table" and window.address or nil
    if type(address) ~= "string" or address == "" then
      callback(nil, "No window is focused, so the transcript was not pasted.")
      return
    end
    local class = type(window.class) == "string" and window.class or ""
    callback({ address = address, class = class, held = holdKindFor(class) }, nil)
  end)
  if accepted == false then
    callback(nil, "hyprctl could not be run, so the focused window is unknown.")
  end
end

-- At record start the user is still in the window the dictation belongs to, so
-- that is the one window the automatic paste is allowed to reach.
local function captureDestination(jobId)
  destination = nil
  queryDestination(function(found, reason)
    if not S.job or S.job.id ~= jobId then return end
    if not found then
      destination = { jobId = jobId, problem = reason }
      return
    end
    destination = { jobId = jobId, address = found.address, class = found.class }
  end)
end

-- The compositor answers a dispatch with "ok", and it still exits 0 when it
-- refuses the chord, so the reply - not the exit status - is what says the chord
-- was sent into the client.
local function chordAccepted(result)
  if type(result) ~= "table" or result.exitCode ~= 0 then
    return false, "hyprctl exited with status " .. tostring(type(result) == "table" and result.exitCode or nil)
  end
  local text = type(result.stdout) == "string" and noctalia.string.trim(result.stdout) or ""
  if text == "ok" then return true end
  return false, text ~= "" and text or "hyprctl returned no answer"
end

-- The setup probe sends no key at all: dispatching `sendshortcut` with no
-- arguments asks the compositor for a chord and lets it answer with its own
-- argument error, which only a compositor that has the dispatcher can say. Older
-- compositors answer a successful dispatch with a plain "ok" whatever the
-- dispatcher does with it, and refuse an unknown dispatcher by name, so both
-- answers are read here and only the refusal is a missing mechanism.
local function dispatcherInstalled(result)
  if type(result) ~= "table" or result.exitCode ~= 0 then return false end
  local text = type(result.stdout) == "string" and noctalia.string.trim(result.stdout) or ""
  if text == "" or string.find(text, "Invalid dispatcher", 1, true) then return false end
  return text == "ok" or string.find(text, "sendshortcut", 1, true) ~= nil
end

-- Copy and paste, once, into the destination that was just checked. The marker is
-- written first: nothing after this point is repeated automatically.
local function pasteInto(target, text)
  local request = pendingDelivery
  local class = target.class ~= "" and target.class or "the focused window"
  local record = {
    jobId = request.jobId,
    state = "attempting",
    attempt = ((readDelivery(request.jobId) or {}).attempt or 0) + 1,
    at = os.time(),
    target = { address = target.address, class = target.class },
  }
  local saved, saveError = writeDelivery(record)
  if not saved then
    -- The marker is what makes a crash distinguishable from a fresh start. Without
    -- it the attempt could not be recognised afterwards, so nothing is copied and
    -- no key is sent: the durable boundary is enforced, not merely intended.
    pendingDelivery = nil
    local reason = type(saveError) == "string" and (" (" .. saveError .. ")") or ""
    local message = "The delivery attempt could not be recorded" .. reason .. ", so nothing was copied and no keys were sent. Copy the transcript and paste it yourself."
    setDelivery("failed", message)
    noctalia.notifyError("Dictation", message)
    return
  end

  if not noctalia.copyToClipboard(text, "text/plain") then
    pendingDelivery = nil
    record.state, record.message = "failed", "the transcript could not be put on the clipboard"
    writeDelivery(record)
    local message = "The transcript could not be put on the clipboard, so no keys were sent. Copy it again or select the text."
    setDelivery("failed", message)
    noctalia.notifyError("Dictation", message)
    return
  end
  record.clipboard = true
  writeDelivery(record)
  setDelivery("pasting", "Pasting into " .. class .. ".")

  local accepted = noctalia.runAsync(PASTE_CHORD, function(result)
    -- The request stays queued until its answer arrives, so a wait that gave up on
    -- it must not have its report overwritten by a late status.
    if pendingDelivery ~= request then return end
    pendingDelivery = nil
    -- An accepted chord only proves the requested V was handed to the focused
    -- client: nothing reads the destination's buffer, so the result is
    -- "attempted", never "inserted".
    local sent, why = chordAccepted(result)
    record.exitCode, record.finishedAt = type(result) == "table" and result.exitCode or nil, os.time()
    if sent then
      record.state = "attempted"
      writeDelivery(record)
      -- The user confirmed this target by hand, so it can be automatic from now
      -- on in this session.
      if request.explicit and target.class ~= "" then validatedTargets[target.class] = true end
      setDelivery("attempted", "Paste attempted into " .. class .. ". The transcript is on the clipboard.")
      return
    end
    record.state, record.message = "failed", "the compositor refused the chord: " .. why
    writeDelivery(record)
    local message = "The compositor refused the paste chord (" .. why .. "), so nothing was typed. The transcript is on the clipboard; paste it yourself."
    setDelivery("failed", message)
    noctalia.notifyError("Dictation", message)
  end)
  if accepted == false then
    pendingDelivery = nil
    record.state, record.message = "failed", "the chord could not be started"
    writeDelivery(record)
    local message = "The paste chord could not be started, so nothing was sent. The transcript is on the clipboard; paste it yourself."
    setDelivery("failed", message)
    noctalia.notifyError("Dictation", message)
  end
end

-- The automatic route: the recording's own window has to still be the focused
-- one. A destination that changed, closed or became ineligible is held instead of
-- receiving the text, and focus is never moved to it.
local function checkAutomaticDelivery()
  local request = pendingDelivery
  queryDestination(function(current, reason)
    if not pendingDelivery or pendingDelivery ~= request then return end
    if panelHoldsKeyboard() then
      holdDelivery("Paste held: the dictation panel is open and holds the keyboard. Close it and use Paste now, or copy the transcript.")
      return
    end
    if not current then
      holdDelivery((reason or "The destination window could not be confirmed.") .. " Nothing was pasted; use Paste now while the target window is focused, or copy the transcript.")
      return
    end
    if current.address ~= request.target.address then
      holdDelivery("Paste held: the focused window changed after the recording finished, so nothing was pasted. Use Paste now to paste into the window that is focused now, or copy the transcript.")
      return
    end
    if current.held then
      holdDelivery(HELD_MESSAGE[current.held])
      return
    end
    pasteInto(current, request.text)
  end)
end

-- The explicit route: the user asked for the paste, so the window that is focused
-- now is the destination and the hold classes do not apply.
local function checkExplicitDelivery()
  local request = pendingDelivery
  queryDestination(function(current, reason)
    if not pendingDelivery or pendingDelivery ~= request then return end
    if panelHoldsKeyboard() then
      holdDelivery("Paste held: the panel still holds the keyboard. Focus the window you want, paste from a shortcut, or copy the transcript.")
      return
    end
    if not current then
      holdDelivery((reason or "The focused window could not be identified.") .. " Nothing was pasted; copy the transcript.")
      return
    end
    pasteInto(current, request.text)
  end)
end

-- The automatic decision, taken once per finished recording. An import, a retry, a
-- job re-adopted after a restart and a replayed recording never reach this point.
local function queueDelivery(jobId)
  if noctalia.getConfig("delivery") == "manual" then
    setDelivery("manual", "Manual copy mode: the transcript is ready to copy.")
    return
  end
  -- Nothing is injected without the compositor that injects it, and the plugin
  -- never installs or replaces one for you.
  if not noctalia.commandExists(PASTE_TOOL) then
    holdDelivery("Paste held: automatic paste needs " .. PASTE_TOOL .. ", which is not installed. Copy the transcript and paste it yourself.")
    return
  end
  if panelHoldsKeyboard() then
    holdDelivery("Paste held: the dictation panel is open and holds the keyboard. Close it and use Paste now, or copy the transcript.")
    return
  end
  if type(destination) ~= "table" or destination.jobId ~= jobId or type(destination.address) ~= "string" then
    local reason = "The window to paste into was not identified."
    if type(destination) == "table" and destination.jobId == jobId and type(destination.problem) == "string" then
      reason = destination.problem
    end
    holdDelivery(reason .. " Nothing was pasted; use Paste now while the target window is focused, or copy the transcript.")
    return
  end
  local kind = holdKindFor(destination.class)
  if kind then
    holdDelivery(HELD_MESSAGE[kind])
    return
  end
  -- No release gate is needed here, and none would be sound: Hyprland fires a
  -- `bindr` command on the key release while the bind's modifiers are still held
  -- (that is what the bind matches on), and no rootless client can read held
  -- modifiers at all - `hyprctl devices` reports the lock keys, not ctrl, alt,
  -- shift or super. The chord is made safe instead of observed: the compositor
  -- writes the chord's modifier state into the client itself.
  local class = destination.class ~= "" and destination.class or "the focused window"
  -- A GUI target is only automatic once the user has confirmed that pasting there
  -- works, so a window the plugin has never been told about is held instead.
  if destination.class == "" or not validatedTargets[destination.class] then
    holdDelivery("Paste held: automatic paste is not confirmed for " .. class .. " yet. Use Paste now once to confirm it; after that it is automatic for this session, or copy the transcript.")
    return
  end
  pendingDelivery = { jobId = jobId, target = destination, readyAtMs = noctalia.nowMs() + PASTE_SETTLE_MS, text = S.transcript }
  setDelivery("waiting", "Waiting to paste into " .. class .. ".")
end

-- The explicit paste, from the panel or a shortcut: into whatever window is
-- focused now. The panel is closed first, because it holds the keyboard.
local function deliverNow(text)
  if S.activity ~= "idle" then
    refuse("Wait for the job to finish before pasting.")
    return
  end
  local job = S.job
  if not job then
    refuse("There is no finished job to paste from.")
    return
  end
  -- The panel can show an edited transcript, and that is the text the user sees,
  -- so it is what an explicit paste sends - exactly like Copy transcript. Without
  -- an edit, and on every shortcut or IPC route, it is the saved transcript.
  local payload = type(text) == "string" and text or ""
  if payload == "" then payload = S.transcript end
  if payload == "" then
    refuse("There is no transcript to paste.")
    return
  end
  if noctalia.getConfig("delivery") == "manual" then
    refuse("Manual copy mode is on. Copy the transcript, or switch Delivery to automatic.")
    return
  end
  if not noctalia.commandExists(PASTE_TOOL) then
    refuse("Automatic paste needs " .. PASTE_TOOL .. " for the compositor's `sendshortcut`.")
    return
  end
  if pendingDelivery or S.delivery.state == "checking" or S.delivery.state == "pasting" then
    refuse("A paste is already in progress.")
    return
  end
  pendingDelivery = { jobId = job.id, target = {}, readyAtMs = noctalia.nowMs() + PASTE_SETTLE_MS, explicit = true, text = payload }
  if panelHoldsKeyboard() then
    -- Giving the keyboard back and waiting for it is the difference between
    -- pasting into the window the user came from and pasting into the panel.
    noctalia.togglePanel("magus/dictation:panel")
    setDelivery("waiting", "Closing the panel and pasting into the window you came from.")
  else
    setDelivery("waiting", "Pasting into the focused window.")
  end
end

-- The queued paste is one step of the update tick: the settle wait cannot block
-- the controller, and it is the only reason a paste needs a second look.
local function pumpDelivery()
  local request = pendingDelivery
  if not request then return end
  -- The request belongs to the job that produced it: a job replaced before the
  -- settle expired must never be delivered to the new one's destination.
  if not S.job or S.job.id ~= request.jobId then
    pendingDelivery = nil
    setDelivery("idle", "")
    return
  end
  local state = S.delivery.state
  -- A check or a paste already in flight is never restarted; an answer that never
  -- arrives is bounded instead of retried.
  if state == "checking" or state == "pasting" then
    if noctalia.nowMs() - request.readyAtMs > PASTE_STALL_MS then
      -- The attempt marker is left as it is: a paste whose answer never arrived is
      -- not repeated, not on the next tick and not after a restart.
      if state == "pasting" then
        holdDelivery("Paste held: the paste tool never reported back, so the attempt was not repeated. The transcript is on the clipboard; paste it yourself.")
      else
        holdDelivery("Paste held: the compositor did not report the focused window. Nothing was pasted; copy the transcript.")
      end
    end
    return
  end
  if noctalia.nowMs() < request.readyAtMs then return end
  setDelivery("checking", "Checking the destination window.")
  if request.explicit then
    checkExplicitDelivery()
  else
    checkAutomaticDelivery()
  end
end

-- ── Starting jobs ────────────────────────────────────────────────────────────

-- Import and retry share one path: they transcribe a recording that is already on
-- disk. Their config is captured when the job starts, so a settings change during
-- the job never rewrites the arguments it was launched with.
local function startJob(wav, label)
  if S.activity ~= "idle" then
    noctalia.notify("Dictation", busyMessage())
    return
  end
  refreshSetup()
  if S.setup.state == "required" then
    publish()
    noctalia.notifyError("Dictation", S.setup.message)
    return
  end
  if not DATA or HELPER == "" then
    fail("Could not locate the bundled recognition helper.", "internal")
    return
  end
  local threads = configThreads()
  if threads < 1 or threads > 64 then
    fail("Setup required: the inference thread count must be between 1 and 64.", "invalid_threads")
    return
  end
  local jobId = newJobId()
  local prepared, prepareError = noctalia.mkdirAll(JOBS .. "/" .. jobId)
  if not prepared then
    fail("Could not prepare the job directory: " .. tostring(prepareError), "internal")
    return
  end
  local recorded, recordError = noctalia.writeFile(JOB_POINTER, jobId)
  if not recorded then
    fail("Could not record the running job: " .. tostring(recordError), "internal")
    return
  end
  -- Argument vector, never a shell string: paths are passed through verbatim.
  local argv = {
    "python3",
    HELPER,
    "run",
    "--engine",
    configPath("engine"),
    "--model",
    configPath("model"),
    "--threads",
    tostring(threads),
    "--wav",
    wav,
    "--job-id",
    jobId,
    "--data-dir",
    DATA,
  }
  if not noctalia.runAsync(argv) then
    resetActivity()
    fail("Could not start the recognition helper.", "internal")
    return
  end
  S.activity = "running"
  S.phase = "transcribing"
  S.job = { id = jobId, mode = "import", startedAtMs = noctalia.nowMs(), elapsedSeconds = 0, label = label }
  S.outcome, S.severity, S.message = nil, nil, "Transcribing."
  S.copyable, S.transcript, S.transcriptPath, S.resultPath = false, "", "", ""
  S.attempt, S.controlTokens = 0, {}
  -- A queued paste belongs to the job that produced it. An import or a retry
  -- replaces that job, so the queue is dropped rather than carried into a job
  -- that #11 excludes from automatic delivery.
  pendingDelivery = nil
  if S.delivery.state ~= "manual" then S.delivery = { state = "idle", message = "" } end
  summaryPath = summaryPathFor(jobId)
  activityStartedAtMs = S.job.startedAtMs
  publish()
end

local function recordingMessage()
  local subject = S.phase == "finalizing" and "Finalizing the recording" or "Recording"
  if S.microphone.name ~= "" then return subject .. " from " .. S.microphone.name .. "." end
  return subject .. "."
end

local function startRecording(from)
  if S.activity ~= "idle" then
    noctalia.notify("Dictation", busyMessage())
    return
  end
  refreshSetup()
  if S.setup.state == "required" then
    publish()
    noctalia.notifyError("Dictation", S.setup.message)
    return
  end
  if not DATA or HELPER == "" then
    fail("Could not locate the bundled recognition helper.", "internal")
    return
  end
  if S.microphone.id == "" then
    refuse("Choose a microphone in the panel before recording.")
    return
  end
  if S.microphone.state ~= "ok" then
    refuse(S.microphone.message ~= "" and S.microphone.message or ("The selected microphone is not available: " .. S.microphone.id))
    return
  end
  local threads = configThreads()
  if threads < 1 or threads > 64 then
    fail("Setup required: the inference thread count must be between 1 and 64.", "invalid_threads")
    return
  end
  local free = diskFreeBytes()
  if free and free < MIN_FREE_BYTES then
    refuse(string.format(
      "Not enough free disk space to record: %d MB free, at least %d MB is needed. Nothing was started and earlier jobs are untouched.",
      math.floor(free / 1048576),
      math.floor(MIN_FREE_BYTES / 1048576)
    ))
    return
  end
  local jobId = newJobId()
  local prepared, prepareError = noctalia.mkdirAll(JOBS .. "/" .. jobId)
  if not prepared then
    fail("Could not prepare the job directory: " .. tostring(prepareError), "internal")
    return
  end
  local recorded, recordError = noctalia.writeFile(JOB_POINTER, jobId)
  if not recorded then
    fail("Could not record the recording job: " .. tostring(recordError), "internal")
    return
  end
  -- The lease goes down before the helper starts: the helper reads it as this
  -- controller's claim, and a missing or stale one releases the microphone.
  local leasePath = JOBS .. "/" .. jobId .. ".lease"
  if not noctalia.writeFile(leasePath, noctalia.json.encode({ ts = os.time() })) then
    noctalia.removeFile(JOB_POINTER)
    fail("Could not claim the recording job.", "internal")
    return
  end
  local argv = {
    "python3",
    HELPER,
    "record",
    "--engine",
    configPath("engine"),
    "--model",
    configPath("model"),
    "--threads",
    tostring(threads),
    "--source",
    S.microphone.id,
    "--job-id",
    jobId,
    "--data-dir",
    DATA,
  }
  if not noctalia.runAsync(argv) then
    noctalia.removeFile(leasePath)
    noctalia.removeFile(JOB_POINTER)
    fail("Could not start the recording helper.", "internal")
    return
  end
  S.activity = "recording"
  S.phase = "starting"
  S.job = {
    id = jobId,
    mode = "record",
    startedAtMs = noctalia.nowMs(),
    elapsedSeconds = 0,
    source = S.microphone.id,
    engine = configPath("engine"),
    model = configPath("model"),
    threads = threads,
    -- Delivery is decided when this job finishes, and only a recording this
    -- session started is allowed to deliver: a job re-adopted after a restart is
    -- not, and neither is an import or a retry.
    deliver = true,
  }
  S.recording = { path = JOBS .. "/" .. jobId .. "/recording.wav", exists = false }
  S.outcome, S.severity = nil, nil
  -- The bar names the microphone in its own status line, so the identity has to
  -- be in the message the bar shows, not only in the panel's microphone row.
  S.message = recordingMessage()
  S.copyable, S.transcript, S.transcriptPath, S.resultPath = false, "", "", ""
  S.attempt, S.controlTokens = 0, {}
  -- The destination is captured now, while the user is still in the window the
  -- dictation is meant for. A recording started from the panel arms nothing: the
  -- window behind the panel is not a destination the user chose.
  pendingDelivery = nil
  S.delivery = { state = "idle", message = "" }
  if from == "panel" then
    destination = { jobId = jobId, problem = "The recording was started from the panel, so no destination window was recorded." }
  else
    captureDestination(jobId)
  end
  summaryPath = summaryPathFor(jobId)
  activityStartedAtMs = S.job.startedAtMs
  publish()
end

local function requestStop()
  if S.activity ~= "recording" or not S.job then
    if S.activity == "running" then
      refuse("The recording already ended. Use Cancel to stop the recognition job.")
    end
    return
  end
  -- A stop that arrives while the helper is already finalizing the WAV is a
  -- duplicate: report the state instead of asking a second time.
  if S.phase == "finalizing" then
    refuse("The recording is already being finalized.")
    return
  end
  local ok, err = noctalia.writeFile(JOBS .. "/" .. S.job.id .. ".stop", "stop\n")
  if ok then
    S.phase = "finalizing"
    S.message = recordingMessage()
    publish()
  else
    noctalia.notifyError("Dictation", "Could not request the stop: " .. tostring(err))
  end
end

-- Toggle is the bar widget's one gesture: start when idle, finalize when
-- recording, and report the job that is already running otherwise.
local function toggleRecording(from)
  if S.activity == "idle" then
    startRecording(from)
  elseif S.activity == "recording" then
    requestStop()
  else
    refuse(busyMessage())
  end
end

local function requestCancel()
  if not activeJob() or not S.job then return end
  local ok, err = noctalia.writeFile(JOBS .. "/" .. S.job.id .. ".cancel", "cancel\n")
  if ok then
    S.message = "Cancelling."
    publish()
  else
    noctalia.notifyError("Dictation", "Could not request cancellation: " .. tostring(err))
  end
end

local function playRecording()
  local path = S.recording.path
  if path == "" or not noctalia.fileExists(path) then
    refuse("There is no saved recording to play yet.")
    return
  end
  -- Playback belongs to the helper, like every other child this plugin starts, so
  -- a helper that goes away cannot leave a player running. Nothing is pasted.
  local accepted = noctalia.runAsync({ "python3", HELPER, "play", "--wav", path }, function(result)
    local summary = type(result) == "table" and readLastJson(result.stdout) or nil
    if type(summary) == "table" and summary.severity == "error" then
      noctalia.notifyError("Dictation", type(summary.message) == "string" and summary.message or "Playback failed.")
    end
  end, 660000)
  if accepted == false then
    refuse("Could not start playback.")
    return
  end
  noctalia.notify("Dictation", "Playing the saved recording. Nothing is pasted.")
end

local function retryRecording()
  local path = S.recording.path
  if path == "" or not noctalia.fileExists(path) then
    refuse("There is no saved recording to transcribe again.")
    return
  end
  startJob(path, "retry")
end

local function verifySetup()
  if S.activity ~= "idle" then return end
  refreshSetup()
  if S.setup.state == "required" then
    publish()
    noctalia.notifyError("Dictation", S.setup.message)
    return
  end
  if not DATA or HELPER == "" then
    fail("Could not locate the bundled recognition helper.", "internal")
    return
  end

  local path = DATA .. "/setup-summary.json"
  noctalia.removeFile(path)
  local argv = {
    "python3",
    HELPER,
    "probe",
    "--engine",
    configPath("engine"),
    "--model",
    configPath("model"),
    "--data-dir",
    DATA,
  }
  if not noctalia.runAsync(argv) then
    fail("Could not start the setup verification.", "internal")
    return
  end
  S.activity = "verifying"
  summaryPath = path
  activityStartedAtMs = noctalia.nowMs()
  S.setup = { state = "verifying", message = "Verifying the executable and hashing the files." }
  publish()
end

-- ── Finishing ────────────────────────────────────────────────────────────────

local function finishJob(summary, jobId)
  local job = S.job
  local id = jobId or (job and job.id)
  local paths = type(summary.paths) == "table" and summary.paths or {}
  local transcriptPath = type(paths.transcript) == "string" and paths.transcript or ""
  local resultPath = type(paths.result) == "string" and paths.result or ""
  local recordingPath = type(paths.recording) == "string" and paths.recording or S.recording.path
  -- Copy is offered only once both persisted files are really on disk, but any
  -- text the engine did return is still shown, including a partial result whose
  -- outcome was an error or a review.
  local transcript = ""
  if transcriptPath ~= "" and noctalia.fileExists(transcriptPath) then
    transcript = noctalia.readFile(transcriptPath) or ""
  end
  local copyable = summary.copyable == true
    and transcript ~= ""
    and resultPath ~= ""
    and noctalia.fileExists(resultPath)

  resetActivity()
  S.recording = {
    path = recordingPath or "",
    exists = type(recordingPath) == "string" and recordingPath ~= "" and noctalia.fileExists(recordingPath),
  }
  if S.recording.exists then rememberRecording(S.recording.path) end
  S.outcome = summary.outcome
  S.severity = type(summary.severity) == "string" and summary.severity or "error"
  S.message = type(summary.message) == "string" and summary.message or ""
  S.copyable = copyable
  S.transcript = transcript
  S.transcriptPath = transcriptPath
  S.resultPath = resultPath
  S.attempt = type(summary.attempt) == "number" and summary.attempt or 0
  S.controlTokens = type(summary.controlTokens) == "table" and summary.controlTokens or {}
  -- Automatic delivery is decided here and nowhere else. An import, a retry, a job
  -- re-adopted after a restart and a replayed recording never reach this point,
  -- and the durable attempt marker is what keeps a paste that a crash interrupted
  -- from being repeated on its own.
  local previous = id and readDelivery(id) or nil
  if previous and previous.state == "attempting" then
    holdDelivery("Paste held: an earlier paste attempt did not finish, so it was not repeated. The transcript is on the clipboard; copy it or use Paste now.")
  elseif job and job.deliver == true and id and summary.outcome == "ok" and copyable then
    queueDelivery(id)
  else
    setDelivery("idle", "")
  end
  publish()
  if S.severity == "error" then
    noctalia.notifyError("Dictation", S.message)
  end
end

local function probePasteTool()
  -- Asking for a chord with no arguments is answered by the dispatcher's own
  -- argument error and sends nothing, so the mechanism is tested without a key.
  local accepted = noctalia.runAsync({ PASTE_TOOL, "dispatch", "sendshortcut" }, function(result)
    S.paste.tested = dispatcherInstalled(result)
    refreshPaste()
    publish()
  end)
  if accepted == false then
    S.paste.tested = false
    refreshPaste()
    publish()
  end
end

local function finishProbe(summary)
  resetActivity()
  if summary.outcome == "ok" then
    refreshSetup()
    probePasteTool()
  else
    S.setup = { state = "required", message = type(summary.message) == "string" and summary.message or "Setup verification failed." }
  end
  publish()
  if summary.outcome ~= "ok" then
    noctalia.notifyError("Dictation", S.setup.message)
  end
end

-- A verification helper starts no engine and records nothing, so giving up on one
-- cannot overlap a job; only a job has to be released with its children.
local function probeExpired()
  if S.activity ~= "verifying" then return false end
  if (noctalia.nowMs() - activityStartedAtMs) / 1000 <= PROBE_STALL_SECONDS then return false end
  fail("The setup verification stopped without reporting a result.", "internal")
  return true
end

-- Silence is not an exit. Contact can stop while the helper keeps working, so
-- the job stays owned and its Cancel stays valid until a summary arrives or the
-- runtime confirms that no process for the job is left. A clock cannot make that
-- call, because the helper's watchdog dies with the helper, not with its children.
-- The job id is in the helper's and the recorder's command line, so a match is a
-- live job and only no match releases it.
-- ponytail: when the runtime cannot answer the process check the job stays
-- owned, so a helper that died leaving a live child locks out new jobs until
-- that child stops. Add an abandon action if that lock ever bites a real user.
local function checkJobProcess()
  if not activeJob() or not S.job then return end
  -- Retry a request the runtime accepted but never answered, so a dropped
  -- callback cannot freeze the check; an unanswered request is not an exit.
  if processCheckSinceMs and (noctalia.nowMs() - processCheckSinceMs) < PROCESS_CHECK_RETRY_MS then return end
  if type(noctalia.processMatches) ~= "function" then return end
  local jobId = S.job.id
  processCheckSinceMs = noctalia.nowMs()
  local accepted = noctalia.processMatches(function(matched)
    processCheckSinceMs = nil
    if S.job and S.job.id == jobId then jobProcessAlive = matched == true end
  end, jobId)
  if accepted == false then processCheckSinceMs = nil end
end

local function reportSilence()
  if silenceReported then return end
  silenceReported = true
  S.outcome = "internal"
  S.severity = "error"
  S.message = "Lost contact with the dictation helper. The job is still owned: Cancel stops it, and another job waits until it is released."
  publish()
  noctalia.notifyError("Dictation", S.message)
end

function update()
  if S.activity == "idle" then
    pumpDelivery()
    return
  end
  if S.activity == "recording" then refreshLease() end
  local path = summaryPath
  local summary = path and noctalia.fileExists(path) and readSummary(path) or nil
  if not summary then
    if probeExpired() then return end
    if helperSilent() then
      reportSilence()
      -- Contact is lost, not ownership. Release the job only on a confirmed
      -- absence, never on elapsed time.
      checkJobProcess()
      if jobProcessAlive == false then
        fail("The dictation helper stopped without reporting, and no process for the job is left.", "internal")
        return
      end
    elseif silenceReported then
      -- Contact resumed before any result: the job is live again, so stop
      -- showing the lost-contact error.
      silenceReported = false
      S.outcome, S.severity = nil, nil
      S.message = S.activity == "recording" and recordingMessage() or "Transcribing."
    end
    if S.job and activeJob() then
      S.job.elapsedSeconds = math.max(0, math.floor((noctalia.nowMs() - S.job.startedAtMs) / 1000))
      if S.activity == "recording" then
        local status = readStatus(S.job.id)
        if type(status) == "table" and type(status.phase) == "string" and status.phase ~= "" then
          -- The helper takes a moment to notice the stop and rewrite its own
          -- status, so the status it wrote before that cannot undo an accepted
          -- stop: once the WAV is being finalized it stays that way.
          if not (S.phase == "finalizing" and status.phase == "recording") then
            S.phase = status.phase
          end
          -- Capture is over once the helper reports the recognition phase, so the
          -- job leaves the recording activity: neither surface offers Stop for a
          -- microphone that is already released, and a Toggle reports the running
          -- job instead of asking the helper to stop a job that is not recording.
          if S.phase == "transcribing" then
            S.activity = "running"
            S.message = "Transcribing the recording."
          end
        end
        if S.recording.path ~= "" then
          S.recording.exists = noctalia.fileExists(S.recording.path)
        end
      end
      publish()
    end
    return
  end
  if activeJob() then
    finishJob(summary)
  else
    finishProbe(summary)
  end
end

function onConfigChanged()
  refreshSetup()
  publish()
end

-- Disabling or uninstalling the plugin must release the microphone and the
-- engine. A reload and a shutdown are not handled here: the lease covers a
-- controller that disappears, and a fast reload keeps the job alive.
function onExit(_signal, reason)
  if reason == "disable" or reason == "uninstall" then
    if activeJob() and S.job and JOBS then
      noctalia.writeFile(JOBS .. "/" .. S.job.id .. ".cancel", "cancel\n")
    end
  end
end

-- The controller exposes the actions a shortcut or another tool can drive; the
-- panel and the bar widget use the state channel instead.
function onIpc(event, _payload)
  local name = type(event) == "string" and event:lower() or ""
  if name == "toggle" then
    toggleRecording("ipc")
  elseif name == "stop" then
    requestStop()
  elseif name == "cancel" then
    requestCancel()
  elseif name == "show" then
    noctalia.togglePanel("magus/dictation:panel")
  elseif name == "paste" then
    deliverNow()
  end
end

-- The plugin's own state is process-lifetime, so a reload forgets a job that is
-- still running on disk. The job pointer does not: adopt whatever job the last
-- runtime recorded, so a reload can neither start a second job nor lose Cancel.
local function restoreJob()
  if not JOB_POINTER or not JOBS then return end
  local raw = noctalia.readFile(JOB_POINTER)
  local jobId = type(raw) == "string" and noctalia.string.trim(raw) or ""
  if not jobId:match("^job%-[%w%-]+$") then return end
  local path = summaryPathFor(jobId)
  local summary = noctalia.fileExists(path) and readSummary(path) or nil
  if summary then
    finishJob(summary, jobId)
    return
  end
  local job = readJob(jobId)
  local startedAtMs = type(job) == "table" and type(job.startedAt) == "number" and job.startedAt or noctalia.nowMs()
  local recordingPath = type(job) == "table" and type(job.recording) == "string" and job.recording or ""
  if type(job) == "table" and job.mode == "record" then
    local status = readStatus(jobId)
    S.activity = "recording"
    S.phase = type(status) == "table" and type(status.phase) == "string" and status.phase or "recording"
    S.message = "Re-adopted the recording that was already in progress."
  else
    S.activity = "running"
    S.phase = "transcribing"
    S.message = "Tracking the recognition job that was already running."
  end
  S.job = {
    id = jobId,
    mode = type(job) == "table" and job.mode or nil,
    startedAtMs = startedAtMs,
    elapsedSeconds = 0,
    source = type(job) == "table" and job.source or nil,
  }
  S.recording = { path = recordingPath, exists = recordingPath ~= "" and noctalia.fileExists(recordingPath) }
  S.outcome, S.severity = nil, nil
  summaryPath = path
  activityStartedAtMs = noctalia.nowMs()
  publish()
end

noctalia.setUpdateInterval(1000)
if JOBS then noctalia.mkdirAll(JOBS) end

loadMicrophone()
refreshSetup()
restoreJob()
recallRecording()
publish()
refreshSources()

noctalia.state.watch("dictation.command", function(command)
  if type(command) ~= "table" then return end
  local action = command.action
  if action == "record" then
    startRecording(command.from)
  elseif action == "toggle" then
    toggleRecording(command.from)
  elseif action == "stop" then
    requestStop()
  elseif action == "cancel" then
    requestCancel()
  elseif action == "import" then
    startJob(configPath("recording"), "import")
  elseif action == "retry" then
    retryRecording()
  elseif action == "play" then
    playRecording()
  elseif action == "verify" then
    verifySetup()
  elseif action == "sources" then
    refreshSources()
  elseif action == "select" then
    selectSource(command.source)
  elseif action == "deliver" then
    deliverNow(command.text)
  end
end)
