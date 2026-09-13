-- Owns the single recognition job and publishes the state the panel and the bar
-- widget render. The bundled Python helper runs detached and mirrors every
-- outcome into a summary file, because a captured-process callback is capped far
-- below a long inference and because the helper owns the inference watchdog.

local PLUGIN_DIR = noctalia.pluginDir()
local HELPER = type(PLUGIN_DIR) == "string" and (PLUGIN_DIR .. "/dictation-helper.py") or ""

local DATA = noctalia.pluginDataDir()
if type(DATA) ~= "string" then DATA = nil end
local JOBS = DATA and (DATA .. "/jobs") or nil

-- Longest a helper may stay silent before the controller stops waiting. The
-- helper's own watchdog stops inference after 30 minutes.
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
  value = math.floor(value)
  if value < 1 then return 1 end
  if value > 64 then return 64 end
  return value
end

local function shortHash(hash)
  if type(hash) ~= "string" or #hash < 16 then return "" end
  return hash:sub(1, 8) .. "..." .. hash:sub(#hash - 3)
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
  S.setup = {
    state = "ok",
    message = "Setup verified.",
    engineSha256 = shortHash(record.engine.sha256),
    modelSha256 = shortHash(record.model.sha256),
  }
end

local function resetActivity()
  S.activity = "idle"
  S.job = nil
  summaryPath = nil
end

local function fail(message, outcome)
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

  local jobId = newJobId()
  local path = JOBS .. "/" .. jobId .. "/summary.json"
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
    tostring(configThreads()),
    "--wav",
    configPath("recording"),
    "--job-id",
    jobId,
    "--data-dir",
    DATA,
  }
  if not noctalia.runAsync(argv) then
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
  -- Copy is offered only once both persisted files are really on disk.
  local copyable = summary.copyable == true
    and transcriptPath ~= ""
    and resultPath ~= ""
    and noctalia.fileExists(transcriptPath)
    and noctalia.fileExists(resultPath)
  local transcript = ""
  if copyable then transcript = noctalia.readFile(transcriptPath) or "" end

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

function update()
  if S.activity == "idle" then return end
  local path = summaryPath
  local summary = path and noctalia.fileExists(path) and readSummary(path) or nil
  if not summary then
    if stopWaiting() then return end
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

noctalia.setUpdateInterval(1000)
if JOBS then noctalia.mkdirAll(JOBS) end

-- state is process-lifetime, so a reload can leave a job recorded as running that
-- this fresh runtime is not watching. Never render that as live work.
local previous = noctalia.state.get("dictation")
refreshSetup()
publish()
if type(previous) == "table" and (previous.activity == "running" or previous.activity == "verifying") then
  S.outcome, S.severity = "interrupted", "error"
  S.message = "A plugin reload interrupted tracking of the previous job. Its files are kept in the plugin data directory."
  publish()
  noctalia.notifyError("Dictation", S.message)
end

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
