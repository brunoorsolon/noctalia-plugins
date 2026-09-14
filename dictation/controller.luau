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

-- Cheap half of setup: it never starts a process, so it is safe on every config
-- change. The explicit probe is what records hashes and engine capabilities.
local function refreshSetup()
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
  summaryPath = summaryPathFor(jobId)
  activityStartedAtMs = S.job.startedAtMs
  publish()
end

local function recordingMessage()
  local subject = S.phase == "finalizing" and "Finalizing the recording" or "Recording"
  if S.microphone.name ~= "" then return subject .. " from " .. S.microphone.name .. "." end
  return subject .. "."
end

local function startRecording()
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
  }
  S.recording = { path = JOBS .. "/" .. jobId .. "/recording.wav", exists = false }
  S.outcome, S.severity = nil, nil
  -- The bar names the microphone in its own status line, so the identity has to
  -- be in the message the bar shows, not only in the panel's microphone row.
  S.message = recordingMessage()
  S.copyable, S.transcript, S.transcriptPath, S.resultPath = false, "", "", ""
  S.attempt, S.controlTokens = 0, {}
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
local function toggleRecording()
  if S.activity == "idle" then
    startRecording()
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

local function finishJob(summary)
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
  publish()
  if S.severity == "error" then
    noctalia.notifyError("Dictation", S.message)
  end
end

local function finishProbe(summary)
  resetActivity()
  if summary.outcome == "ok" then
    refreshSetup()
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
  if S.activity == "idle" then return end
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
    toggleRecording()
  elseif name == "stop" then
    requestStop()
  elseif name == "cancel" then
    requestCancel()
  elseif name == "show" then
    noctalia.togglePanel("magus/dictation:panel")
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
    finishJob(summary)
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
    startRecording()
  elseif action == "toggle" then
    toggleRecording()
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
  end
end)
