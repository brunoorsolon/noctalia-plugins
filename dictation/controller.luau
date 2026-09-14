-- Owns the single recognition job and publishes the state the panel and the bar
-- widget render. The bundled Python helper runs detached and mirrors every
-- outcome into a summary file, because a captured-process callback is capped far
-- below a long inference and because the helper owns the inference watchdog.

local PLUGIN_DIR = noctalia.pluginDir()
local HELPER = type(PLUGIN_DIR) == "string" and (PLUGIN_DIR .. "/dictation-helper.py") or ""

local DATA = noctalia.pluginDataDir()
if type(DATA) ~= "string" then DATA = nil end
local JOBS = DATA and (DATA .. "/jobs") or nil
-- Names the one job this plugin currently owns. It lives on disk because the
-- plugin's own state does not survive a reload, and a detached helper does.
local JOB_POINTER = DATA and (DATA .. "/current-job") or nil

-- Longest a helper may stay silent before the controller stops waiting. The
-- helper's own watchdog stops inference after 30 minutes, and it rewrites its
-- heartbeat every few seconds, so silence this long means it is gone.
local RUN_SILENT_SECONDS = 60
local RUN_STALL_SECONDS = 35 * 60
local PROBE_STALL_SECONDS = 10 * 60

local S = {
  activity = "idle", -- idle | running | verifying
  setup = { state = "unknown", message = "" },
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

local function publish()
  noctalia.state.set("dictation", S)
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

-- Ends the current activity without losing the record of the job it belonged to;
-- `activity` is what makes a job live, and `S.job` is what the panel reports on.
local function resetActivity()
  S.activity = "idle"
  summaryPath = nil
  silenceReported = false
  if JOB_POINTER then noctalia.removeFile(JOB_POINTER) end
end

local function fail(message, outcome)
  if S.job then
    S.job.elapsedSeconds = math.floor((noctalia.nowMs() - S.job.startedAtMs) / 1000)
  end
  resetActivity()
  S.outcome = outcome or "internal"
  S.severity = "error"
  S.message = message
  S.copyable = false
  publish()
  noctalia.notifyError("Dictation", message)
end

-- A unique job id keeps the controller from ever reading another job's summary,
-- even for two imports inside the same millisecond.
local function newJobId()
  local stamp = "job-" .. tostring(noctalia.nowMs())
  local candidate, index = stamp, 1
  while noctalia.fileExists(JOBS .. "/" .. candidate .. "/summary.json") do
    index = index + 1
    candidate = stamp .. "-" .. tostring(index)
  end
  return candidate
end

local function summaryPathFor(jobId)
  return JOBS .. "/" .. jobId .. "/summary.json"
end

-- The helper rewrites its heartbeat every few seconds; nil means it never wrote
-- one, so the plugin cannot tell a live helper from a dead one.
local function heartbeatAge(jobId)
  local raw = noctalia.readFile(JOBS .. "/" .. jobId .. "/heartbeat.json")
  local beat = type(raw) == "string" and noctalia.json.decode(raw) or nil
  if type(beat) ~= "table" or type(beat.ts) ~= "number" then return nil end
  return os.time() - beat.ts
end

local function helperSilent()
  if S.activity ~= "running" or not S.job then return false end
  -- Give a freshly started or newly adopted job time to report at all.
  if (noctalia.nowMs() - activityStartedAtMs) / 1000 < RUN_SILENT_SECONDS then return false end
  local age = heartbeatAge(S.job.id)
  return age == nil or age > RUN_SILENT_SECONDS
end

local function startJob()
  if S.activity ~= "idle" then
    noctalia.notify("Dictation", "A recognition job is already running.")
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
  -- The settings picker already bounds this; a value outside it is reported
  -- rather than quietly changed, because the thread count is a real choice.
  local threads = configThreads()
  if threads < 1 or threads > 64 then
    fail("Setup required: the inference thread count must be between 1 and 64.", "invalid_threads")
    return
  end

  local jobId = newJobId()
  local path = summaryPathFor(jobId)
  -- Reject storage this job cannot write into before anything is launched: the
  -- helper could only fail where the plugin would never see it.
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
    configPath("recording"),
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
  S.job = { id = jobId, startedAtMs = noctalia.nowMs(), elapsedSeconds = 0 }
  S.outcome, S.severity, S.message = nil, nil, "Transcribing."
  S.copyable, S.transcript, S.transcriptPath, S.resultPath = false, "", "", ""
  S.attempt, S.controlTokens = 0, {}
  summaryPath = path
  activityStartedAtMs = S.job.startedAtMs
  publish()
end

local function requestCancel()
  if S.activity ~= "running" or not S.job then return end
  local ok, err = noctalia.writeFile(JOBS .. "/" .. S.job.id .. ".cancel", "cancel\n")
  if ok then
    S.message = "Cancelling."
    publish()
  else
    noctalia.notifyError("Dictation", "Could not request cancellation: " .. tostring(err))
  end
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

-- A summary file is written with a rename, so its presence means it is complete.
local function readSummary(path)
  local raw = noctalia.readFile(path)
  local summary = type(raw) == "string" and noctalia.json.decode(raw) or nil
  if type(summary) ~= "table" or type(summary.outcome) ~= "string" then return nil end
  return summary
end

local function finishJob(summary)
  local paths = type(summary.paths) == "table" and summary.paths or {}
  local transcriptPath = type(paths.transcript) == "string" and paths.transcript or ""
  local resultPath = type(paths.result) == "string" and paths.result or ""
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

local function stopWaiting()
  local seconds = (noctalia.nowMs() - activityStartedAtMs) / 1000
  local limit = S.activity == "running" and RUN_STALL_SECONDS or PROBE_STALL_SECONDS
  if seconds <= limit then return false end
  fail("The recognition helper stopped without reporting a result.", "internal")
  return true
end

-- Silence is not an exit. The engine may still be running, so reporting the lost
-- contact must not release the job: a second import would overlap the first, and
-- Cancel would lose its target. Ownership is handed back when the helper reports
-- an outcome, or when the stall window passes as a bounded escape hatch.
-- ponytail: the stall release is time-based, not proof of exit. A helper killed
-- with no report can leave an orphaned engine, and a detached-engine check would
-- have to observe the process itself; upgrade if an engine can outlive its helper.
local function reportSilence()
  if silenceReported then return end
  silenceReported = true
  S.outcome = "internal"
  S.severity = "error"
  S.message = "Lost contact with the recognition helper. The job is still owned: Cancel stops it, and another import waits until it exits."
  publish()
  noctalia.notifyError("Dictation", S.message)
end

function update()
  if S.activity == "idle" then return end
  local path = summaryPath
  local summary = path and noctalia.fileExists(path) and readSummary(path) or nil
  if not summary then
    if stopWaiting() then return end
    if helperSilent() then
      reportSilence()
    elseif silenceReported then
      -- Contact resumed before any result: the job is live again, so stop
      -- showing the lost-contact error.
      silenceReported = false
      S.outcome, S.severity, S.message = nil, nil, "Transcribing."
    end
    if S.activity == "running" and S.job then
      S.job.elapsedSeconds = math.floor((noctalia.nowMs() - S.job.startedAtMs) / 1000)
      publish()
    end
    return
  end
  if S.activity == "running" then
    finishJob(summary)
  else
    finishProbe(summary)
  end
end

function onConfigChanged()
  refreshSetup()
  publish()
end

-- Stopping a job that this service owns is the only teardown work needed.
function onExit(_signal, reason)
  if reason == "disable" or reason == "uninstall" then
    if S.activity == "running" and S.job and JOBS then
      noctalia.writeFile(JOBS .. "/" .. S.job.id .. ".cancel", "cancel\n")
    end
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
  S.activity = "running"
  S.job = { id = jobId, startedAtMs = noctalia.nowMs(), elapsedSeconds = 0 }
  S.outcome, S.severity = nil, nil
  S.message = "Tracking the recognition job that was already running."
  summaryPath = path
  activityStartedAtMs = noctalia.nowMs()
  publish()
end

noctalia.setUpdateInterval(1000)
if JOBS then noctalia.mkdirAll(JOBS) end

refreshSetup()
restoreJob()
publish()

noctalia.state.watch("dictation.command", function(command)
  if type(command) ~= "table" then return end
  local action = command.action
  if action == "import" then
    startJob()
  elseif action == "cancel" then
    requestCancel()
  elseif action == "verify" then
    verifySetup()
  end
end)
