-- Drives the plugin's Luau entries against a stubbed Noctalia runtime and a
-- stubbed helper, so the controller's state machine is exercised without
-- Noctalia, PipeWire or a recognition engine. ./controller-selftest.sh injects
-- the entry sources as the global SOURCES table and runs this file.
--
-- It is a check, not a plugin entry: plugin.toml never loads it.

local failures = 0
local function check(name, expected, actual)
  if expected ~= actual then
    failures = failures + 1
    print(("FAIL %-56s expected [%s] got [%s]"):format(name, tostring(expected), tostring(actual)))
  end
end

-- ── The stub runtime ─────────────────────────────────────────────────────────

local clockMs = 1000000
local nowSeconds = 1000
-- The lease is stamped with the runtime clock, so shadow it with one this check
-- can move.
os = { time = function() return nowSeconds end }

local fs = {}
local mtimes = {}
local decoded = {}
local clipboard = nil
local notifications = {}
local launches = {}
local panelsOpened = 0
local stateStore = {}
local watchers = {}
local lastTree = nil
local lastBarTree = nil
local CONFIG = { engine = "", model = "", recording = "", threads = 4 }
local freeBytes = 1024 * 1024 * 1024
local mkdirFails = false
-- What the runtime answers about a live process for the job: nil = cannot
-- answer, true = observed alive, false = observed gone.
local jobProcessAlive = nil
local jobProcessDrop = 0
-- What the helper prints for a source scan: ok = JSON on stdout,
-- nostdout = nothing readable, so only the durable file can help.
local availability = "ok"

local SOURCE_LIST = {
  { id = "alsa_input.internal-mic", name = "alsa_input.internal-mic", description = "Built-in Microphone" },
  { id = "alsa_input.usb-mic", name = "alsa_input.usb-mic", description = "USB Microphone" },
}

local function parentFolder(path) return path:match("^(.*)/[^/]+$") end
local function putFile(path, content) fs[path] = content end
local function putTable(path, value, token)
  decoded[token] = value
  fs[path] = "#" .. token
end

fs["/data"] = "@dir"
fs["/bin/engine"] = "binary"
fs["/models/a.gguf"] = "model"

-- A tiny encoder for the flat tables the controller writes. The decode side is a
-- lookup, so an encoded value decodes back to the exact table that produced it.
local function encode(value)
  if type(value) == "string" then return string.format("%q", value) end
  if type(value) == "boolean" then return tostring(value) end
  if type(value) == "number" then return tostring(value) end
  if type(value) ~= "table" then return "null" end
  local parts = {}
  for key, item in pairs(value) do
    parts[#parts + 1] = string.format("%q", tostring(key)) .. ":" .. encode(item)
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

noctalia = {}
function noctalia.pluginDir() return "/plugin" end
function noctalia.pluginDataDir() return "/data", nil end
function noctalia.nowMs() return clockMs end
function noctalia.expandPath(path) return path end
function noctalia.commandExists() return true end
function noctalia.diskStats()
  return { availableBytes = freeBytes, freeBytes = freeBytes, totalBytes = freeBytes, usagePercent = 0 }
end
function noctalia.processMatches(onResult)
  if jobProcessDrop > 0 then
    jobProcessDrop = jobProcessDrop - 1
    return true -- accepted, answer dropped
  end
  if jobProcessAlive == nil then return false end
  onResult(jobProcessAlive)
  return true
end
function noctalia.fileExists(path) return type(path) == "string" and fs[path] ~= nil and fs[path] ~= "@dir" end
function noctalia.readFile(path)
  if fs[path] == nil or fs[path] == "@dir" then return nil, "no such file" end
  return fs[path]
end
function noctalia.writeFile(path, contents)
  local parent = parentFolder(path)
  if parent and fs[parent] == nil then return false, "no such directory" end
  fs[path] = contents
  return true
end
function noctalia.removeFile(path)
  if fs[path] == nil then return false, "no such file" end
  fs[path] = nil
  return true
end
function noctalia.mkdirAll(path)
  if mkdirFails then return false, "not a directory" end
  fs[path] = "@dir"
  return true
end
function noctalia.fileInfo(path)
  if fs[path] == nil then return nil, "no such file" end
  return { size = #fs[path], mtime = mtimes[path] or 0, isDir = fs[path] == "@dir" }
end
function noctalia.listDir(path)
  if fs[path] ~= "@dir" then return nil, "not a directory" end
  local prefix = path .. "/"
  local names, seen = {}, {}
  for candidate in pairs(fs) do
    if candidate:sub(1, #prefix) == prefix then
      local name = candidate:sub(#prefix + 1):match("^([^/]+)")
      if name and not seen[name] then
        seen[name] = true
        table.insert(names, name)
      end
    end
  end
  table.sort(names)
  return names
end
function noctalia.setUpdateInterval() end
function noctalia.notify(title, body) table.insert(notifications, { kind = "info", title = title, body = body }) end
function noctalia.notifyError(title, body) table.insert(notifications, { kind = "error", title = title, body = body }) end
function noctalia.copyToClipboard(text) clipboard = text return true end
function noctalia.openSettings() end
function noctalia.togglePanel() panelsOpened = panelsOpened + 1 end
noctalia.string = { trim = function(value) return (value:gsub("^%s+", ""):gsub("%s+$", "")) end }
noctalia.state = {
  set = function(key, value)
    stateStore[key] = value
    for _, callback in ipairs(watchers[key] or {}) do callback(value) end
  end,
  get = function(key) return stateStore[key] end,
  watch = function(key, callback)
    watchers[key] = watchers[key] or {}
    table.insert(watchers[key], callback)
  end,
}
function noctalia.getConfig(key) return CONFIG[key] end

local sourceStdout = '{"outcome":"ok","severity":"ok","message":"Found 2 capture sources.","sources":"@sources"}'
decoded[sourceStdout] = {
  outcome = "ok",
  severity = "ok",
  message = "Found 2 capture sources.",
  sources = SOURCE_LIST,
}
noctalia.json = {
  decode = function(value) return decoded[(value:gsub("^#", ""))] end,
  encode = function(value)
    local text = encode(value)
    decoded[text] = value
    return text
  end,
}

-- Every helper invocation the controller makes, in order.
function noctalia.runAsync(argv, onResult)
  table.insert(launches, argv)
  if argv[3] == "sources" and type(onResult) == "function" then
    if availability == "ok" then
      onResult({ exitCode = 0, stdout = sourceStdout, stderr = "" })
    elseif availability == "nostdout" then
      onResult({ exitCode = 1, stdout = "", stderr = "pw-dump: connect failed" })
    end
  end
  return true
end

ui, panel, barWidget = {}, {}, {}
ui.column = function(props, children) return { kind = "column", props = props or {}, children = children } end
ui.row = function(props, children) return { kind = "row", props = props or {}, children = children } end
ui.label = function(props) return { kind = "label", props = props or {} } end
ui.input = function(props) return { kind = "input", props = props or {} } end
ui.button = function(props) return { kind = "button", props = props or {} } end
ui.spacer = function(props) return { kind = "spacer", props = props or {} } end
ui.separator = function(props) return { kind = "separator", props = props or {} } end
ui.select = function(props) return { kind = "select", props = props or {} } end
ui.glyph = function(props) return { kind = "glyph", props = props or {} } end
panel.render = function(tree) lastTree = tree end
panel.close = function() end
barWidget.render = function(tree) lastBarTree = tree end
barWidget.setTooltip = function(text) barWidget.tooltip = text end
barWidget.clearTooltip = function() barWidget.tooltip = nil end

local function load()
  for _, name in ipairs({ "controller", "panel", "widget" }) do
    assert(loadstring(SOURCES[name], name))()
  end
end

local function find(tree, kind, text)
  if type(tree) ~= "table" then return nil end
  if tree.kind == kind and (text == nil or tree.props.text == text) then return tree end
  for _, child in ipairs(tree.children or {}) do
    local found = find(child, kind, text)
    if found then return found end
  end
  return nil
end

local function findByHandler(tree, handler)
  if type(tree) ~= "table" then return nil end
  if tree.kind == "button" and tree.props.onClick == handler then return tree end
  for _, child in ipairs(tree.children or {}) do
    local found = findByHandler(child, handler)
    if found then return found end
  end
  return nil
end

local seq = 0
local function command(action, extra)
  seq = seq + 1
  local payload = { seq = seq, at = clockMs, action = action }
  if type(extra) == "table" then
    for key, value in pairs(extra) do payload[key] = value end
  end
  watchers["dictation.command"][1](payload)
end

local function state() return stateStore["dictation"] end
local function lastLaunch() return table.concat(launches[#launches], ",") end
local function jobDir(jobId) return "/data/jobs/" .. jobId end
local function leaseOf(jobId) return fs[jobDir(jobId) .. ".lease"] end
-- Only the runs that own a job matter for "nothing was started" checks; a source
-- scan is not a job.
local function jobLaunches()
  local count = 0
  for _, argv in ipairs(launches) do
    if argv[3] == "record" or argv[3] == "run" then count = count + 1 end
  end
  return count
end

local function finishSummary(jobId, outcome, severity, message, opts)
  opts = opts or {}
  local dir = jobDir(jobId)
  local paths = {}
  if opts.transcript then
    putFile(dir .. "/attempt-1/result.json", "{}")
    putFile(dir .. "/attempt-1/transcript.txt", opts.transcript)
    paths.transcript = dir .. "/attempt-1/transcript.txt"
    paths.result = dir .. "/attempt-1/result.json"
  end
  if opts.recording then
    -- The helper reports the audio this job produced; for an imported file that
    -- path is the imported file itself, not a copy.
    local target = type(opts.recording) == "string" and opts.recording or (dir .. "/recording.wav")
    putFile(target, "RIFF")
    paths.recording = target
  end
  putTable(dir .. "/summary.json", {
    outcome = outcome,
    severity = severity,
    message = message,
    copyable = opts.copyable == true,
    attempt = opts.attempt or 1,
    controlTokens = {},
    paths = paths,
  }, "summary:" .. jobId .. ":" .. outcome .. ":" .. tostring(opts.transcript))
end

-- ── Bootstrap ────────────────────────────────────────────────────────────────

load()
check("initial activity", "idle", state().activity)
check("initial setup", "required", state().setup.state)
check("sources are listed", "ok", state().sources.state)
check("two sources offered", 2, #state().sources.list)
check("no microphone chosen yet", "unset", state().microphone.state)

-- The durable file is the fallback when stdout carries nothing readable.
availability = "nostdout"
putTable("/data/sources.json", { outcome = "ok", sources = SOURCE_LIST }, "sources-durable")
command("sources")
check("durable source fallback", "ok", state().sources.state)
check("durable source list", 2, #state().sources.list)

-- A graph that cannot be read at all is reported, not guessed around.
fs["/data/sources.json"] = nil
command("sources")
check("unreadable graph", "error", state().sources.state)
check("unreadable graph says why", true, state().sources.message ~= "")
availability = "ok"
command("sources")
check("graph readable again", "ok", state().sources.state)
check("sources readable again", 2, #state().sources.list)

-- ── Setup ────────────────────────────────────────────────────────────────────

CONFIG.engine, CONFIG.model, CONFIG.recording = "/bin/engine", "/models/a.gguf", "/rec/one.wav"
putFile("/rec/one.wav", "wav")
onConfigChanged()
check("setup unknown after paths set", "unknown", state().setup.state)

command("verify")
check("verify activity", "verifying", state().activity)
check("probe argv", "python3,/plugin/dictation-helper.py,probe,--engine,/bin/engine,--model,/models/a.gguf,--data-dir,/data", lastLaunch())
putTable("/data/setup.json", {
  engine = { path = "/bin/engine", sha256 = string.rep("e", 64), size = #"binary" },
  model = { path = "/models/a.gguf", sha256 = string.rep("m", 64), size = #"model" },
}, "setup")
putTable("/data/setup-summary.json", { outcome = "ok", severity = "ok", message = "Setup verified." }, "probe-ok")
update()
check("setup ok after probe", "ok", state().setup.state)
check("setup engine hash", "eeeeeeee...eeee", state().setup.engineSha256)
check("verify returns to idle", "idle", state().activity)

-- A thread count outside the settings range is reported, not clamped.
CONFIG.threads = 0
onConfigChanged()
local beforeThreads = jobLaunches()
command("import")
check("invalid threads blocks launch", beforeThreads, jobLaunches())
check("invalid threads outcome", "invalid_threads", state().outcome)
CONFIG.threads = 4
onConfigChanged()

-- Required setup refuses to launch and says why.
CONFIG.engine = ""
onConfigChanged()
check("missing engine requires setup", "required", state().setup.state)
local beforeRequired = jobLaunches()
command("record")
check("required setup blocks recording", beforeRequired, jobLaunches())
check("required setup notified", "error", notifications[#notifications].kind)
CONFIG.engine = "/bin/engine"
onConfigChanged()

-- ── Microphone choice ────────────────────────────────────────────────────────

command("select", { source = "alsa_input.usb-mic" })
check("microphone selected", "alsa_input.usb-mic", state().microphone.id)
check("microphone named", "USB Microphone", state().microphone.name)
check("microphone writable state", "ok", state().microphone.state)
check("microphone persisted", "alsa_input.usb-mic", noctalia.json.decode(fs["/data/microphone.json"]).id)
command("select", { source = "alsa_input.nonexistent" })
check("unknown source ignored", "alsa_input.usb-mic", state().microphone.id)

-- A source that disappears stays selected and blocks recording: nothing is
-- silently substituted with another microphone or a monitor.
availability = "nostdout"
putTable("/data/sources.json", { outcome = "ok", sources = { SOURCE_LIST[1] } }, "sources-without-usb")
command("sources")
check("missing microphone detected", "missing", state().microphone.state)
local beforeMissing = jobLaunches()
command("record")
check("missing microphone blocks recording", beforeMissing, jobLaunches())
check("missing microphone notified", "error", notifications[#notifications].kind)
check("missing microphone stays selected", "alsa_input.usb-mic", state().microphone.id)
availability = "ok"
command("sources")
check("reconnected microphone accepted", "ok", state().microphone.state)

-- ── Recording ────────────────────────────────────────────────────────────────

freeBytes = 1024 * 1024
local beforeDisk = jobLaunches()
command("record")
check("low disk blocks recording", beforeDisk, jobLaunches())
check("low disk names the reason", true, state().message:find("disk space") ~= nil)
check("low disk keeps older jobs", "idle", state().activity)
freeBytes = 1024 * 1024 * 1024

local beforeRecord = jobLaunches()
command("record")
local rec = state().job.id
check("one recorder launched", beforeRecord + 1, jobLaunches())
check("recording activity", "recording", state().activity)
check("recording phase", "starting", state().phase)
check("recording job id", true, rec:match("^job%-%d") ~= nil)
check("job pointer recorded", rec, fs["/data/current-job"])
check(
  "record argv",
  "python3,/plugin/dictation-helper.py,record,--engine,/bin/engine,--model,/models/a.gguf,--threads,4,--source,alsa_input.usb-mic,--job-id," .. rec .. ",--data-dir,/data",
  lastLaunch()
)
check("recording path", jobDir(rec) .. "/recording.wav", state().recording.path)
check("recording not on disk yet", false, state().recording.exists)
check("recording pastes nothing", nil, clipboard)
check("lease written before launch", true, leaseOf(rec) ~= nil)
check("lease stamped now", nowSeconds, noctalia.json.decode(leaseOf(rec)).ts)

-- The lease is refreshed on every tick; that is what lets the helper notice a
-- controller that has gone away.
nowSeconds = nowSeconds + 5
clockMs = clockMs + 5000
update()
check("lease refreshed on tick", nowSeconds, noctalia.json.decode(leaseOf(rec)).ts)
check("recording elapsed", 5, state().job.elapsedSeconds)
check("recording phase before status", "starting", state().phase)
putTable(jobDir(rec) .. "/status.json", { phase = "recording", jobId = rec }, "status-rec")
update()
check("phase follows the helper", "recording", state().phase)

-- A second record is refused, and Toggle finalizes instead of starting another.
local beforeSecond = jobLaunches()
command("record")
check("second record refused", beforeSecond, jobLaunches())
check("second record refused with reason", true, notifications[#notifications].body:find("in progress") ~= nil)
command("toggle")
check("toggle requests the stop", "stop\n", fs[jobDir(rec) .. ".stop"])
check("stop phase", "finalizing", state().phase)
command("stop")
check("duplicate stop converges", "stop\n", fs[jobDir(rec) .. ".stop"])
check("duplicate stop keeps the job", rec, state().job.id)
check("duplicate stop launches nothing", beforeSecond, jobLaunches())
check("stop keeps the activity", "recording", state().activity)

-- Cancel routes to this job's own request file, and a stop already in flight is
-- not lost: the helper owns the final ordering.
command("cancel")
check("cancel request written", "cancel\n", fs[jobDir(rec) .. ".cancel"])
finishSummary(rec, "ok", "ok", "Transcription complete.", { transcript = "hello world", recording = true, copyable = true })
update()
check("recording finished", "idle", state().activity)
check("recording outcome", "ok", state().outcome)
check("recording transcript", "hello world", state().transcript)
check("recording copyable", true, state().copyable)
check("recording kept", true, state().recording.exists)
check("job pointer cleared", nil, fs["/data/current-job"])
check("lease cleared", nil, leaseOf(rec))

-- Playback goes through the helper and puts nothing on the clipboard.
clipboard = nil
local beforePlay = panelsOpened
command("play")
check("play argv", "python3,/plugin/dictation-helper.py,play,--wav," .. jobDir(rec) .. "/recording.wav", lastLaunch())
check("play leaves the clipboard alone", nil, clipboard)
check("play opens no panel", beforePlay, panelsOpened)

-- ── Import and retry ─────────────────────────────────────────────────────────

command("import")
local imported = state().job.id
check("import activity", "running", state().activity)
check(
  "import argv",
  "python3,/plugin/dictation-helper.py,run,--engine,/bin/engine,--model,/models/a.gguf,--threads,4,--wav,/rec/one.wav,--job-id," .. imported .. ",--data-dir,/data",
  lastLaunch()
)
check("each job gets its own directory", true, imported ~= rec)
check("import is no recording", false, state().job.mode == "record")
-- A config change while a job runs must not abandon it or rewrite its arguments.
CONFIG.threads = 8
onConfigChanged()
clockMs = clockMs + 1000
update()
check("config change keeps the job", "running", state().activity)
check("config change keeps the argv", "4", launches[#launches][9])
CONFIG.threads = 4
onConfigChanged()
command("record")
check("record refused while transcribing", imported, state().job.id)
check("record refused with the job name", true, notifications[#notifications].body:find("recognition job") ~= nil)
finishSummary(imported, "ok", "ok", "Transcription complete.", { transcript = "imported text", copyable = true })
update()
check("import finished", "idle", state().activity)

-- Retry transcribes the saved recording as a new job.
command("retry")
local retried = state().job.id
check("retry runs again", "running", state().activity)
check("retry uses the saved recording", jobDir(rec) .. "/recording.wav", launches[#launches][11])
check("retry is its own job", true, retried ~= rec and retried ~= imported)
finishSummary(retried, "cancelled", "cancelled", "Cancelled.", { recording = true })
update()
check("cancel outcome", "cancelled", state().outcome)
check("cancelled keeps the audio", true, state().recording.exists)

-- ── Losing contact ───────────────────────────────────────────────────────────

command("import")
local silent = state().job.id
putTable(jobDir(silent) .. "/heartbeat.json", { ts = nowSeconds }, "beat-live")
clockMs = clockMs + 120000
update()
check("live heartbeat keeps the job", "running", state().activity)
putTable(jobDir(silent) .. "/heartbeat.json", { ts = nowSeconds - 300 }, "beat-stale")
clockMs = clockMs + 61000
update()
check("silent helper reports the failure", "internal", state().outcome)
check("silent helper keeps the job owned", "running", state().activity)
check("silent helper keeps the pointer", silent, fs["/data/current-job"])
local beforeSilent = jobLaunches()
command("import")
check("silent helper refuses a second job", beforeSilent, jobLaunches())
command("cancel")
check("silent helper still routes cancel", "cancel\n", fs[jobDir(silent) .. ".cancel"])
fs[jobDir(silent) .. ".cancel"] = nil
-- A heartbeat that resumes clears the report without releasing the job.
putTable(jobDir(silent) .. "/heartbeat.json", { ts = nowSeconds }, "beat-back")
clockMs = clockMs + 1000
update()
check("resumed contact clears the report", "Transcribing.", state().message)
check("resumed contact keeps the job", "running", state().activity)
putTable(jobDir(silent) .. "/heartbeat.json", { ts = nowSeconds - 300 }, "beat-stale-2")
clockMs = clockMs + 61000
update()
check("contact can be lost twice", "internal", state().outcome)

-- Silence is not an exit: an unanswerable check keeps the job, an answer that was
-- dropped is retried, and only a confirmed absence releases it.
jobProcessAlive = nil
clockMs = clockMs + 120000
update()
check("unanswerable check keeps the job", "running", state().activity)
jobProcessDrop = 1
update()
check("dropped answer keeps the job", "running", state().activity)
jobProcessAlive = false
update()
check("dropped answer is not read as gone", "running", state().activity)
clockMs = clockMs + 5000
update()
check("confirmed absence releases the job", "idle", state().activity)
check("confirmed absence clears the pointer", nil, fs["/data/current-job"])
jobProcessAlive = nil

-- ── Reload ───────────────────────────────────────────────────────────────────

-- A reload forgets the plugin's own state, so the job pointer and the helper's
-- files are what the new runtime adopts: no second recorder, no lost Cancel.
command("record")
local live = state().job.id
putTable(jobDir(live) .. "/job.json", {
  jobId = live,
  mode = "record",
  source = "alsa_input.usb-mic",
  startedAt = clockMs,
  recording = jobDir(live) .. "/recording.wav",
}, "job-live")
putTable(jobDir(live) .. "/status.json", { phase = "recording", jobId = live }, "status-live")
putFile(jobDir(live) .. "/recording.wav", "RIFF")
nowSeconds = nowSeconds + 3
onExit(0, "reload")
watchers = {}
load()
check("reload adopts the recording", "recording", state().activity)
check("reload keeps the job", live, state().job.id)
check("reload keeps the recording path", jobDir(live) .. "/recording.wav", state().recording.path)
check("reload sees the audio", true, state().recording.exists)
local adopted = jobLaunches()
command("record")
check("reload cannot start a second recorder", adopted, jobLaunches())
command("stop")
check("reload stop reaches the adopted job", "stop\n", fs[jobDir(live) .. ".stop"])
nowSeconds = nowSeconds + 7
clockMs = clockMs + 7000
update()
check("adopted lease is refreshed", nowSeconds, noctalia.json.decode(leaseOf(live)).ts)
finishSummary(live, "interrupted", "error", "Noctalia stopped claiming the recording.", { recording = true })
update()
check("adopted job finishes", "idle", state().activity)
check("adopted outcome", "interrupted", state().outcome)
check("interrupted recording kept", true, state().recording.exists)

-- An interrupted recording stays recognizable after the restart: the restart
-- never resumes it, but the panel can still play or transcribe that recording.
local afterRestart = jobLaunches()
onExit(0, "reload")
watchers = {}
load()
check("restart does not resume", "idle", state().activity)
check("restart launches no job", afterRestart, jobLaunches())
check("restart remembers the interrupted recording", true, state().recording.exists)
check("restart names the interrupted recording", jobDir(live) .. "/recording.wav", state().recording.path)
command("retry")
check("restart can transcribe the interrupted recording", jobDir(live) .. "/recording.wav", launches[#launches][11])
finishSummary(state().job.id, "ok", "ok", "Transcription complete.", { transcript = "recovered", copyable = true })
update()
check("restart retry finishes", "idle", state().activity)
check("restart retry kept the transcript", "recovered", state().transcript)

-- The pointer is the fast path, not the only one: with it gone, the newest
-- recording the job directories still hold is the one Play and Retry address,
-- and a file that never received a frame is not offered as recovered audio.
fs["/data/last-recording"] = nil
putFile(jobDir("job-old") .. "/recording.wav", string.rep("x", 128))
putFile(jobDir("job-new") .. "/recording.wav", string.rep("x", 256))
putFile(jobDir("job-header-only") .. "/recording.wav", "RIFF")
mtimes[jobDir("job-old") .. "/recording.wav"] = 10
mtimes[jobDir("job-new") .. "/recording.wav"] = 20
mtimes[jobDir("job-header-only") .. "/recording.wav"] = 30
onExit(0, "reload")
watchers = {}
load()
check("recall without the pointer", jobDir("job-new") .. "/recording.wav", state().recording.path)

-- A runtime that cannot list a directory simply reports no recording instead of
-- failing: the fallback is not a hard dependency.
local listDir = noctalia.listDir
noctalia.listDir = nil
onExit(0, "reload")
watchers = {}
load()
check("recall without a listing", false, state().recording.exists)
noctalia.listDir = listDir

-- Disabling releases the microphone through the helper's own cancel request.
command("record")
local disabled = state().job.id
onExit(0, "disable")
check("disable cancels the recorder", "cancel\n", fs[jobDir(disabled) .. ".cancel"])
fs[jobDir(disabled) .. ".cancel"] = nil
finishSummary(disabled, "cancelled", "cancelled", "Cancelled.", { recording = true })
update()

-- ── IPC ──────────────────────────────────────────────────────────────────────

local beforeIpc = jobLaunches()
onIpc("toggle", nil)
check("ipc toggle starts a recording", beforeIpc + 1, jobLaunches())
local ipcJob = state().job.id
check("ipc recording is the live job", "recording", state().activity)
onIpc("stop", nil)
check("ipc stop routes the stop", "stop\n", fs[jobDir(ipcJob) .. ".stop"])
onIpc("cancel", nil)
check("ipc cancel routes the cancel", "cancel\n", fs[jobDir(ipcJob) .. ".cancel"])
onIpc("show", nil)
check("ipc show opens the panel", true, panelsOpened > 0)
onIpc("nonsense", nil)
check("unknown ipc event is ignored", ipcJob, state().job.id)
finishSummary(ipcJob, "cancelled", "cancelled", "Cancelled.", { recording = true })
update()

-- Storage the job cannot write into is refused before anything is launched.
mkdirFails = true
local refused = jobLaunches()
command("record")
check("unusable storage blocks launch", refused, jobLaunches())
check("unusable storage outcome", "internal", state().outcome)
check("unusable storage notified", "error", notifications[#notifications].kind)
mkdirFails = false

-- ── Panel and widget ─────────────────────────────────────────────────────────

local beforePanel = panelsOpened
onOpen({})
check("panel rendered", "column", lastTree.kind)
local select = find(lastTree, "select")
check("panel lists the microphones", 2, #select.props.options)
check("panel marks the chosen microphone", 1, select.props.selectedIndex)
check("panel names the chosen microphone", true, find(lastTree, "label", "Recording from: USB Microphone") ~= nil)
check("panel record enabled", true, findByHandler(lastTree, "onRecord").props.enabled)
check("panel offers no stop while idle", nil, findByHandler(lastTree, "onStop"))
check("panel play enabled with a recording", true, findByHandler(lastTree, "onPlay").props.enabled)
check("panel retry enabled with a recording", true, findByHandler(lastTree, "onRetry").props.enabled)

onMicrophoneSelected(0, "Built-in Microphone")
check("panel selection reaches the controller", "alsa_input.internal-mic", state().microphone.id)
check("panel selection persisted", "alsa_input.internal-mic", noctalia.json.decode(fs["/data/microphone.json"]).id)
check("panel shows the new choice", 0, find(lastTree, "select").props.selectedIndex)

-- The bar's Record and the panel's Record drive the same single job.
onWidgetRecord()
local panelJob = state().job.id
check("widget record starts the recording", "recording", state().activity)
check("widget record opens no panel", beforePanel, panelsOpened)
check("widget record pastes nothing", nil, clipboard)
command("record")
check("panel record does not stack a job", panelJob, state().job.id)
check("bar hides record while recording", false, findByHandler(lastBarTree, "onWidgetRecord").props.visible)
check("bar shows stop while recording", true, findByHandler(lastBarTree, "onWidgetStop").props.visible)
check("bar shows cancel while recording", true, findByHandler(lastBarTree, "onWidgetCancel").props.visible)
check("bar shows the elapsed time", true, find(lastBarTree, "label", "0:00") ~= nil)
check("widget tooltip names the microphone", "Recording from Built-in Microphone.", barWidget.tooltip)

-- The recorder keeps the microphone it was started with, so the choice is closed
-- while audio is being captured instead of appearing to change it.
local micNotices = #notifications
onMicrophoneSelected(1, "USB Microphone")
check("microphone change refused while recording", "alsa_input.internal-mic", state().microphone.id)
check("microphone refusal says why", micNotices + 1, #notifications)
onOpen({})
check("microphone picker closed while recording", false, find(lastTree, "select").props.enabled)
onWidgetStop()
check("widget stop routes the stop", "stop\n", fs[jobDir(panelJob) .. ".stop"])

-- The helper has not noticed the stop yet, so its own status still says the
-- microphone is capturing; that status cannot undo the accepted stop.
putTable(jobDir(panelJob) .. "/status.json", { phase = "recording", jobId = panelJob }, "status-stale")
update()
check("accepted stop keeps finalizing", "finalizing", state().phase)

-- Once the stop is accepted the capture is over, so the bar stops offering Stop
-- and shows that the WAV is being finalized, while the tooltip still names the
-- microphone the audio came from.
check("bar finalizing glyph", "loader", find(lastBarTree, "glyph").props.name)
check("bar hides stop while finalizing", false, findByHandler(lastBarTree, "onWidgetStop").props.visible)
check("bar keeps cancel while finalizing", true, findByHandler(lastBarTree, "onWidgetCancel").props.visible)
check("bar finalizing names the microphone", "Finalizing the recording from Built-in Microphone.", barWidget.tooltip)

-- A second Stop cannot be sent: the helper is already finalizing the WAV.
fs[jobDir(panelJob) .. ".stop"] = nil
local finalizingNotices = #notifications
onWidgetStop()
check("stop while finalizing is refused", nil, fs[jobDir(panelJob) .. ".stop"])
check("stop while finalizing says why", finalizingNotices + 1, #notifications)

-- The helper reports the recognition phase once the WAV is finalized. The
-- microphone is free by then, so the job has to leave the recording activity: the
-- bar shows the work instead of a live microphone with a Stop button, and Toggle
-- reports the running job instead of writing a second Stop the helper ignores.
putTable(jobDir(panelJob) .. "/status.json", { phase = "transcribing", jobId = panelJob }, "status-transcribing")
update()
check("transcribing leaves the recording activity", "running", state().activity)
check("transcribing hides stop on the bar", false, findByHandler(lastBarTree, "onWidgetStop").props.visible)
check("transcribing shows the working glyph", "loader", find(lastBarTree, "glyph").props.name)
check("transcribing counts the elapsed time", true, find(lastBarTree, "label", "0:00") ~= nil)
check("transcribing tooltip names the phase", true, string.find(string.lower(barWidget.tooltip), "transcrib") ~= nil)
fs[jobDir(panelJob) .. ".stop"] = nil
local transcribingNotices = #notifications
command("toggle")
check("toggle during transcription writes no Stop", nil, fs[jobDir(panelJob) .. ".stop"])
check("toggle during transcription reports the job", transcribingNotices + 1, #notifications)

onWidgetCancel()
check("widget cancel routes the cancel", "cancel\n", fs[jobDir(panelJob) .. ".cancel"])
check("widget controls open no panel", beforePanel, panelsOpened)
onWidgetPanel()
check("only the panel button opens the panel", beforePanel + 1, panelsOpened)
finishSummary(panelJob, "ok", "ok", "Transcription complete.", { transcript = "typed text", recording = true, copyable = true })
update()
check("panel returns to idle", "idle", state().activity)

onOpen({})
check("panel shows the transcript", "typed text", find(lastTree, "input").props.value)
check("panel copy enabled", true, findByHandler(lastTree, "onCopyTranscript").props.enabled)
check("panel copy is user driven", nil, clipboard)
onCopyTranscript()
check("panel copies on request", "typed text", clipboard)
onTranscriptEdited("edited by hand")
check("widget idle glyph", "check", find(lastBarTree, "glyph").props.name)
check("widget idle tooltip", "Transcription complete.", barWidget.tooltip)

-- A partial result from a review outcome is readable, and the bar says review.
command("import")
local reviewJob = state().job.id
check("bar counts elapsed time while transcribing", true, find(lastBarTree, "label", "0:00") ~= nil)
finishSummary(reviewJob, "truncated", "review", "The transcript was truncated.", { transcript = "partial text", copyable = false, recording = "/imports/sample.wav" })
update()
check("import becomes the play target", "/imports/sample.wav", state().recording.path)
check("review severity kept", "review", state().severity)
check("review keeps the partial text", "partial text", state().transcript)
check("review is not copyable", false, state().copyable)
check("widget review glyph", "alert-triangle", find(lastBarTree, "glyph").props.name)
check("widget review tooltip", "The transcript was truncated.", barWidget.tooltip)
onOpen({})
check("panel shows the partial text", "partial text", find(lastTree, "input").props.value)
check("panel review label", "The transcript was truncated.", find(lastTree, "label", "The transcript was truncated.").props.text)
check("panel stays rendered", "column", lastTree.kind)

-- The check has to fail its process, not only print: a caller and any automation
-- reading the exit status must see a failed run.
if failures > 0 then
  error(("controller harness FAILED: %d"):format(failures), 0)
end
print("controller harness ok")
