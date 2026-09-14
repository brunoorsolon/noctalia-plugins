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
local clipboardMime = nil
local notifications = {}
local launches = {}
local panelsOpened = 0
local stateStore = {}
local watchers = {}
local lastTree = nil
local lastBarTree = nil
-- Delivery is exercised in its own section below; the checks that came first are
-- about recognition, so they run in manual mode, where nothing is ever pasted.
local CONFIG = { engine = "", model = "", recording = "", threads = 4, delivery = "manual" }
local freeBytes = 1024 * 1024 * 1024
local mkdirFails = false
-- What the runtime answers about a live process for the job: nil = cannot
-- answer, true = observed alive, false = observed gone.
local jobProcessAlive = nil
local jobProcessDrop = 0
-- What the helper prints for a source scan: ok = JSON on stdout,
-- nostdout = nothing readable, so only the durable file can help.
local availability = "ok"

-- What the compositor reports as the focused window, what it answers to the chord
-- dispatch, and which tools this runtime does not have. The chord goes out with
-- `hyprctl dispatch sendshortcut`, and the setup probe dispatches the same command
-- with no chord, which the dispatcher answers with its own argument error.
local activeWindow = nil
local activeWindowExitCode = 0
local chordReply = "ok"
local probeReply = "sendshortcut: invalid args"
local pasteExitCode = 0
local pasteStartRefused = false
local pasteSilent = false
local markerWriteFails = false
local clipboardWriteFails = false
local missingCommands = {}

-- The shortcut setup writes into the host's own Hyprland configuration, so the
-- stub carries the environment the lookup reads, the file the host would load, the
-- compositor's bind table, and the ways a write or a reload can go wrong.
local ENV = { HOME = "/home/user", XDG_CONFIG_HOME = "/home/user/.config" }
local CONFIG_DIR = "/home/user/.config/hypr"
local CONF_PATH = CONFIG_DIR .. "/hyprland.conf"
local LUA_PATH = CONFIG_DIR .. "/hyprland.lua"
local bindTable = ""
local reloadExitCode = 0
local reloadSilent = false
local bindsSilent = false
local duringBindsQuery = nil
local fixtureBinds = {}
local bindsIgnoreConfig = false
local configWriteFails = false
local backupWriteFails = false

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
function noctalia.commandExists(name) return missingCommands[name] ~= true end
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
  if markerWriteFails and type(path) == "string" and string.find(path, "/delivery.json", 1, true) then
    return false, "No space left on device"
  end
  if backupWriteFails and type(path) == "string" and string.find(path, ".magus-dictation.bak", 1, true) then
    return false, "Read-only file system"
  end
  if configWriteFails and (path == CONF_PATH or path == LUA_PATH) then
    return false, "Read-only file system"
  end
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
function noctalia.copyToClipboard(text, mime)
  if clipboardWriteFails then return false end
  clipboard, clipboardMime = text, mime
  return true
end
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
function noctalia.getenv(name) return ENV[name] end

-- The compositor's bind table, derived from the active configuration file the way
-- a reload would: whatever the plugin's delimited block declares becomes a
-- registered bind, and a fixture bind can hold the chord instead.
local MOD_BITS = { SHIFT = 1, CAPS = 2, CTRL = 4, ALT = 8, MOD2 = 16, MOD3 = 32, SUPER = 64, META = 64, MOD4 = 64, MOD5 = 128 }
local function chordModmask(chord)
  local mask = 0
  for word in chord:upper():gmatch("[%u%d]+") do
    -- The bits are distinct, so addition is the union.
    mask = mask + (MOD_BITS[word] or 0)
  end
  return mask
end

local function rebuildBinds()
  local binds = {}
  for _, bind in ipairs(fixtureBinds) do table.insert(binds, bind) end
  local active = fs[LUA_PATH] ~= nil and LUA_PATH or (fs[CONF_PATH] ~= nil and CONF_PATH or nil)
  local format = active == LUA_PATH and "lua" or "conf"
  local content = nil
  if not bindsIgnoreConfig then content = active and fs[active] or nil end
  local block = type(content) == "string"
    and content:match("magus/dictation:recording%-shortcut:begin(.-)magus/dictation:recording%-shortcut:end")
  if block then
    local line = block:match("(bindd[^\n]*)")
    local mods, key, description, arg
    if format == "lua" then
      local chord = block:match('hl%.bind%("([^"]*)"') or ""
      local tokens = {}
      for token in chord:gmatch("[^%s+]+") do table.insert(tokens, token) end
      mods, key = chord, tokens[#tokens] or ""
      description = block:match('description%s*=%s*"([^"]*)"')
      arg = block:match('exec_cmd%("([^"]*)"%)')
    else
      if line then
        mods, key, description = line:match("bindd%s*=%s*([^,]+),%s*([^,]+),%s*([^,]+),")
      end
      arg = line and line:match("exec,%s*(.-)%s*$")
      mods, key = mods and noctalia.string.trim(mods), key and noctalia.string.trim(key)
    end
    table.insert(binds, {
      modmask = chordModmask(mods or ""),
      key = key or "",
      has_description = description ~= nil and description ~= "",
      description = description and noctalia.string.trim(description) or "",
      dispatcher = format == "lua" and "__lua" or "exec",
      arg = arg or "",
    })
  end
  bindTable = encode(binds)
  decoded[bindTable] = binds
end

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

-- The compositor's answer for the focused window. The stub decodes by lookup, so
-- every answer is registered the way a durable file is.
local function putActiveWindow(address, class, title)
  local window = { address = address, class = class, title = title }
  activeWindow = encode(window)
  decoded[activeWindow] = window
end
putActiveWindow("0x1", "TextEditor", "notes.txt")
local EDITOR = activeWindow

-- Every helper invocation and every key injection the controller makes, in order.
function noctalia.runAsync(argv, onResult)
  table.insert(launches, argv)
  -- The compositor is asked which window is focused, and it is handed the chord:
  -- the query answers with a window, the dispatch answers with its own reply.
  if argv[1] == "hyprctl" then
    -- Setup reads the live bind table before it writes anything, and reloads the
    -- compositor after, so a written block has to come back as a registered bind.
    if argv[2] == "-j" and argv[3] == "binds" then
      if type(onResult) == "function" then
        -- One test edits the configuration while the compositor is answering, and
        -- one accepts the query without ever reporting back.
        if duringBindsQuery then
          local hook = duringBindsQuery
          duringBindsQuery = nil
          hook()
        end
        if not bindsSilent then
          rebuildBinds()
          onResult({ exitCode = 0, stdout = bindTable, stderr = "" })
        end
      end
      return true
    end
    if argv[2] == "reload" then
      -- A reload is answered normally, refused with a nonzero status, or accepted
      -- without ever reporting back.
      if reloadSilent then return true end
      if type(onResult) == "function" then onResult({ exitCode = reloadExitCode, stdout = "ok", stderr = "" }) end
      return true
    end
    if argv[2] == "dispatch" then
      -- The setup probe asks for a chord with no arguments, so it is answered by
      -- the dispatcher's own argument error and sends nothing.
      if argv[4] == nil then
        if type(onResult) == "function" then onResult({ exitCode = 0, stdout = probeReply, stderr = "" }) end
        return true
      end
      -- The chord is started detached in one test, answers a reply in the others,
      -- and in one test accepts it without ever reporting back.
      if pasteStartRefused then return false end
      if pasteSilent then return true end
      if type(onResult) == "function" then onResult({ exitCode = pasteExitCode, stdout = pasteExitCode == 0 and chordReply or "", stderr = "" }) end
      return true
    end
    if type(onResult) == "function" then
      onResult({ exitCode = activeWindowExitCode, stdout = activeWindowExitCode == 0 and activeWindow or "", stderr = "" })
    end
    return true
  end
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

local function findText(tree, needle)
  if type(tree) ~= "table" then return nil end
  if tree.kind == "label" and type(tree.props.text) == "string" and string.find(tree.props.text, needle, 1, true) then return tree end
  for _, child in ipairs(tree.children or {}) do
    local found = findText(child, needle)
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
local function lastLaunch()
  -- The query that reads the focused window and the reads and reloads that belong
  -- to shortcut setup are not job launches: they are what the last recording start
  -- or the last delivery check leaves behind. A chord dispatch is one.
  for index = #launches, 1, -1 do
    local launch = launches[index]
    local management = launch[1] == "hyprctl" and (launch[2] == "-j" or launch[2] == "reload")
    if not management then return table.concat(launch, ",") end
  end
  return ""
end
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

local function launchesFrom(mark)
  local out = {}
  for index = mark + 1, #launches do out[#out + 1] = table.concat(launches[index], " ") end
  return table.concat(out, " | ")
end

-- Key injections only: the window query and the setup probe are hyprctl too, but
-- they carry no chord, so they are not pastes.
local function pasteLaunches()
  local count = 0
  for _, argv in ipairs(launches) do
    if argv[2] == "dispatch" and argv[4] ~= nil then count = count + 1 end
  end
  return count
end

-- Reads of the compositor's bind table. Shortcut setup makes them; delivery must
-- not, because the paste chord's safety does not depend on which key invoke the job.
local function bindsReads()
  local count = 0
  for _, argv in ipairs(launches) do
    if argv[1] == "hyprctl" and argv[2] == "-j" and argv[3] == "binds" then count = count + 1 end
  end
  return count
end

local function launched(wanted)
  for _, argv in ipairs(launches) do
    if table.concat(argv, " ") == wanted then return true end
  end
  return false
end

-- The speech is never typed as keystrokes and no extra key rides along: every
-- injection is the one ordinary paste chord and nothing else.
local function chordOnly()
  for _, argv in ipairs(launches) do
    if argv[2] == "dispatch" and argv[4] ~= nil and table.concat(argv, " ") ~= "hyprctl dispatch sendshortcut CTRL,V," then return false end
  end
  return true
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
local picker = find(lastTree, "select")
check("panel lists the microphones", 2, #picker.props.options)
check("panel marks the chosen microphone", 1, picker.props.selectedIndex)
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

-- ── Delivery ─────────────────────────────────────────────────────────────────

-- Delivery is the only place the plugin touches the clipboard and the keyboard, so
-- every check drives it through the interface the panel and the bar use and then
-- reads what the runtime was really asked to do: which window was queried, whether
-- the clipboard was written, and which keys were injected. It also never asks the
-- compositor which binding invoked the job; that question belongs to shortcut
-- setup, and this section's read count is compared again at its end.
local bindsBeforeDelivery = bindsReads()
onClose()
clipboard, clipboardMime = nil, nil
CONFIG.delivery = "auto"
onConfigChanged()
check("delivery names its mechanism", "untested", state().paste.state)

-- Verify and record tests the mechanism itself, not only the engine: it asks the
-- compositor for a chord with no arguments, which the dispatcher answers with its
-- own argument error and which sends nothing.
command("verify")
putTable("/data/setup-summary.json", { outcome = "ok", severity = "ok", message = "Setup verified." }, "probe-ok-delivery")
update()
check("verify tests the paste tool", true, state().paste.tested)
check("tested mechanism is reported", "ok", state().paste.state)
check("the probe sends no chord", "hyprctl,dispatch,sendshortcut", lastLaunch())

-- The probe reads the compositor's answer, not the exit status, and a compositor
-- that does not have the dispatcher can name it in the refusal, so the refusal is
-- matched before the dispatcher's name is.
probeReply = "Invalid dispatcher, requested \"sendshortcut\" does not exist"
command("verify")
putTable("/data/setup-summary.json", { outcome = "ok", severity = "ok", message = "Setup verified." }, "probe-named-refusal-delivery")
update()
check("a refusal that names the dispatcher is still a refusal", false, state().paste.tested)
probeReply = "Invalid dispatcher"
command("verify")
putTable("/data/setup-summary.json", { outcome = "ok", severity = "ok", message = "Setup verified." }, "probe-refused-delivery")
update()
check("a refused probe is not a tested mechanism", false, state().paste.tested)
check("a refused probe is reported as untested", "untested", state().paste.state)

-- An answer that names neither the dispatcher nor a plain success says nothing
-- about this mechanism, so it is not accepted as evidence that it is installed.
probeReply = "Cannot dispatch"
command("verify")
putTable("/data/setup-summary.json", { outcome = "ok", severity = "ok", message = "Setup verified." }, "probe-foreign-delivery")
update()
check("an answer about something else is not a tested mechanism", false, state().paste.tested)

-- A compositor whose dispatchers answer with a plain "ok" accepts the probe too.
probeReply = "ok"
command("verify")
putTable("/data/setup-summary.json", { outcome = "ok", severity = "ok", message = "Setup verified." }, "probe-ok-only-delivery")
update()
check("an answered probe is a tested mechanism", true, state().paste.tested)
check("an answered probe is reported as ok", "ok", state().paste.state)
probeReply = "sendshortcut: invalid args"
command("verify")
putTable("/data/setup-summary.json", { outcome = "ok", severity = "ok", message = "Setup verified." }, "probe-restored-delivery")
update()

-- An unconfirmed window class is held: automatic delivery is only for targets the
-- user has confirmed once, and the hold is where that confirmation happens.
local firstText = "first line\nzweite Zeile"
local beforeHeld = pasteLaunches()
activeWindow = EDITOR
onWidgetRecord()
local heldJob = state().job.id
finishSummary(heldJob, "ok", "ok", "Transcription complete.", { transcript = firstText, recording = true, copyable = true })
update()
check("unconfirmed target is held", "held", state().delivery.state)
check("unconfirmed target sends no keys", beforeHeld, pasteLaunches())
check("unconfirmed target copies nothing", nil, clipboard)
check("unconfirmed target offers the confirmation", true, string.find(state().delivery.message, "Paste now") ~= nil)
check("held paste shows on the bar", "tertiary", find(lastBarTree, "glyph").props.color)
check("held paste is named on the bar", true, string.find(string.lower(barWidget.tooltip), "held") ~= nil)
onOpen({})
check("panel offers the re-arm", true, findByHandler(lastTree, "onDeliver") ~= nil)
check("panel delivery row names the state", true, find(lastTree, "label", "Delivery") ~= nil)
check("panel re-arm enabled with a transcript", true, findByHandler(lastTree, "onDeliver").props.enabled)

-- The explicit action sends the one ordinary chord into the focused window. It is
-- reported as an attempt, never as a verified insertion, because an injection tool
-- that exits cleanly cannot prove the application inserted the text.
onClose()
local beforeExplicit = pasteLaunches()
onDeliver()
check("explicit paste waits for the settle", "waiting", state().delivery.state)
check("explicit paste sends nothing yet", beforeExplicit, pasteLaunches())
clockMs = clockMs + 250
update()
check("explicit paste is still settling", beforeExplicit, pasteLaunches())
clockMs = clockMs + 250
update()
check("explicit paste injects one chord", beforeExplicit + 1, pasteLaunches())
check("explicit paste uses the ordinary shortcut", "hyprctl,dispatch,sendshortcut,CTRL,V,", lastLaunch())
check("explicit paste carries the transcript", firstText, clipboard)
check("explicit paste sends text data", "text/plain", clipboardMime)
check("explicit paste is an attempt", "attempted", state().delivery.state)
check("explicit paste says attempted", true, string.find(state().delivery.message, "attempted") ~= nil)
check("attempt marker is persisted", "attempted", noctalia.json.decode(fs[jobDir(heldJob) .. "/delivery.json"]).state)
check("attempt marker names the target", "0x1", noctalia.json.decode(fs[jobDir(heldJob) .. "/delivery.json"]).target.address)
check("attempt marker names the class", "TextEditor", noctalia.json.decode(fs[jobDir(heldJob) .. "/delivery.json"]).target.class)

-- One attempt stays one attempt: later ticks never repeat the side effects, and the
-- transcript is left on the clipboard for the user.
local beforeRepeat = pasteLaunches()
clockMs = clockMs + 5000
update()
update()
check("a finished attempt is not repeated", beforeRepeat, pasteLaunches())
check("the attempt is not restarted", "attempted", state().delivery.state)
check("the transcript stays on the clipboard", firstText, clipboard)

-- A confirmed target is pasted into automatically, after the settle and only into
-- the window the recording was started from.
clipboard = nil
activeWindow = EDITOR
onWidgetRecord()
local autoJob = state().job.id
finishSummary(autoJob, "ok", "ok", "Transcription complete.", { transcript = "auto text", recording = true, copyable = true })
update()
check("confirmed target waits for the settle", "waiting", state().delivery.state)
check("the settle injects nothing", beforeRepeat, pasteLaunches())
clockMs = clockMs + 500
update()
check("confirmed target is pasted into", beforeRepeat + 1, pasteLaunches())
check("automatic paste carries the new transcript", "auto text", clipboard)
check("automatic paste is an attempt", "attempted", state().delivery.state)

-- A destination that changed while the job ran is held, never followed: the paste
-- does not drift into a window the recording was not started from.
clipboard = nil
activeWindow = EDITOR
onWidgetRecord()
local movedJob = state().job.id
putActiveWindow("0x2", "TextEditor", "other.txt")
finishSummary(movedJob, "ok", "ok", "Transcription complete.", { transcript = "moved text", recording = true, copyable = true })
update()
clockMs = clockMs + 500
local beforeMoved = pasteLaunches()
update()
check("changed destination is held", "held", state().delivery.state)
check("changed destination sends no keys", beforeMoved, pasteLaunches())
check("changed destination copies nothing", nil, clipboard)
check("changed destination says why", true, string.find(state().delivery.message, "changed") ~= nil)
activeWindow = EDITOR

-- Terminals and password managers are held for an explicit action. The plugin knows
-- named window classes; it does not claim to recognise a password field.
putActiveWindow("0x3", "kitty", "shell")
onWidgetRecord()
local terminalJob = state().job.id
finishSummary(terminalJob, "ok", "ok", "Transcription complete.", { transcript = "shell text", recording = true, copyable = true })
update()
clockMs = clockMs + 500
local beforeTerminal = pasteLaunches()
update()
check("terminal destination is held", "held", state().delivery.state)
check("terminal receives no keys", beforeTerminal, pasteLaunches())
check("terminal hold is named", true, string.find(state().delivery.message, "terminal") ~= nil)
putActiveWindow("0x4", "KeePassXC", "vault")
onWidgetRecord()
local passwordJob = state().job.id
finishSummary(passwordJob, "ok", "ok", "Transcription complete.", { transcript = "secret text", recording = true, copyable = true })
update()
clockMs = clockMs + 500
local beforePassword = pasteLaunches()
update()
check("password manager is held", "held", state().delivery.state)
check("password manager receives no keys", beforePassword, pasteLaunches())

-- The explicit action overrides a hold, because the user asked for that window.
clipboard = nil
onClose()
onDeliver()
clockMs = clockMs + 500
update()
check("explicit action pastes into a held window", beforePassword + 1, pasteLaunches())
check("explicit override carries the transcript", "secret text", clipboard)

-- An edited transcript in the panel is the text the user sees, so Paste now sends
-- that text rather than the saved transcript the edit replaced.
local beforeEdited = pasteLaunches()
onOpen({})
onTranscriptEdited("edited text")
onClose()
onDeliver()
clockMs = clockMs + 500
update()
check("explicit paste carries the edited transcript", "edited text", clipboard)
check("explicit paste after an edit injects one chord", beforeEdited + 1, pasteLaunches())

-- A draft left over from an earlier job is not an edit of this one, so the saved
-- transcript is what an explicit paste carries.
clipboard = nil
activeWindow = EDITOR
onWidgetRecord()
local staleJob = state().job.id
finishSummary(staleJob, "ok", "ok", "Transcription complete.", { transcript = "stale text", recording = true, copyable = true })
update()
clockMs = clockMs + 500
update()
onClose()
onDeliver()
clockMs = clockMs + 500
update()
check("a stale panel draft is not sent", "stale text", clipboard)

-- Copy carries the same text as Paste now: an empty transcript has nothing to copy,
-- and a draft left from an earlier job must not reach the clipboard in its place.
clipboard = nil
activeWindow = EDITOR
onWidgetRecord()
local emptyJob = state().job.id
finishSummary(emptyJob, "empty", "error", "The engine returned no text.", { transcript = "", recording = true, copyable = false })
update()
onCopyTranscript()
check("copy never sends an earlier job's draft", nil, clipboard)

-- An import that starts while a paste is waiting must not inherit it: the queue
-- belongs to the job that produced it, and #11 excludes imports from automatic
-- delivery altogether.
clipboard = nil
activeWindow = EDITOR
onWidgetRecord()
local liveJob = state().job.id
finishSummary(liveJob, "ok", "ok", "Transcription complete.", { transcript = "live payload", recording = true, copyable = true })
update()
check("the replaced recording waits for the settle", "waiting", state().delivery.state)
local beforeImport = pasteLaunches()
command("import")
local importJob = state().job.id
check("an import is its own job", true, importJob ~= liveJob)
check("starting an import drops the waiting paste", "idle", state().delivery.state)
finishSummary(importJob, "ok", "ok", "Transcription complete.", { transcript = "import payload", recording = true, copyable = true })
update()
clockMs = clockMs + 500
update()
check("an import inherits no paste", beforeImport, pasteLaunches())
check("an import never auto-delivers", "idle", state().delivery.state)
check("an import copies nothing", nil, clipboard)
check("the replaced attempt left no marker", nil, fs[jobDir(liveJob) .. "/delivery.json"])

-- A delivery attempt that cannot be recorded is not made: the durable marker is
-- what stops a crash from repeating a paste, so without it nothing is copied and
-- no key is sent.
markerWriteFails = true
clipboard = nil
activeWindow = EDITOR
onWidgetRecord()
local unwritableJob = state().job.id
finishSummary(unwritableJob, "ok", "ok", "Transcription complete.", { transcript = "unwritable text", recording = true, copyable = true })
update()
clockMs = clockMs + 500
local beforeMarkerFail = pasteLaunches()
update()
check("an unrecordable attempt fails", "failed", state().delivery.state)
check("an unrecordable attempt copies nothing", nil, clipboard)
check("an unrecordable attempt sends no keys", beforeMarkerFail, pasteLaunches())
check("an unrecordable attempt says why", true, string.find(state().delivery.message, "record") ~= nil)
check("an unrecordable attempt is notified", "error", notifications[#notifications].kind)
check("an unrecordable attempt leaves no marker", nil, fs[jobDir(unwritableJob) .. "/delivery.json"])
markerWriteFails = false

-- A compositor that refuses the chord is a visible failure: hyprctl still exits 0
-- when it refuses one, so the reply - not the exit status - is what decides, and
-- nothing is ever reported as pasted.
chordReply = "Invalid dispatcher"
clipboard = nil
activeWindow = EDITOR
onWidgetRecord()
local refusedJob = state().job.id
finishSummary(refusedJob, "ok", "ok", "Transcription complete.", { transcript = "refused text", recording = true, copyable = true })
update()
clockMs = clockMs + 500
update()
check("a refused chord fails the delivery", "failed", state().delivery.state)
check("a refused chord repeats what the compositor said", true, string.find(state().delivery.message, "Invalid dispatcher") ~= nil)
check("a refused chord keeps the transcript", "refused text", clipboard)
check("a refused chord marker is persisted", "failed", noctalia.json.decode(fs[jobDir(refusedJob) .. "/delivery.json"]).state)
check("a refused chord is notified", "error", notifications[#notifications].kind)
chordReply = "ok"

-- The automatic chord is the same literal, addressed to the focused client and
-- never to a window of its own: `sendshortcut` re-points focus when it is given a
-- target, and the focus check is what decides the destination.
clipboard = nil
activeWindow = EDITOR
onWidgetRecord()
local selectorJob = state().job.id
local selectorMark = #launches
finishSummary(selectorJob, "ok", "ok", "Transcription complete.", { transcript = "selector text", recording = true, copyable = true })
update()
clockMs = clockMs + 500
update()
-- Nothing about the shortcut is consulted on the way: the delivery reads the
-- focused window and then hands over the one chord.
check("a delivery asks for the window and then sends the chord", "hyprctl -j activewindow | hyprctl dispatch sendshortcut CTRL,V,", launchesFrom(selectorMark))
check("an automatically delivered job is an attempt", "attempted", state().delivery.state)
-- A paste tool that accepts the chord and never reports back must not leave the
-- plugin saying "pasting" for the rest of the session, and must not be asked a
-- second time: the attempt marker stays unfinished.
pasteSilent = true
clipboard = nil
activeWindow = EDITOR
onWidgetRecord()
local silentJob = state().job.id
finishSummary(silentJob, "ok", "ok", "Transcription complete.", { transcript = "silent text", recording = true, copyable = true })
update()
clockMs = clockMs + 500
local beforeSilent = pasteLaunches()
update()
check("a silent paste tool is asked once", beforeSilent + 1, pasteLaunches())
check("a silent paste tool leaves the paste in flight", "pasting", state().delivery.state)
clockMs = clockMs + 31000
update()
check("a silent paste tool is held after the bound", "held", state().delivery.state)
check("a silent paste tool is not asked again", beforeSilent + 1, pasteLaunches())
check("a silent paste tool leaves the marker unfinished", "attempting", noctalia.json.decode(fs[jobDir(silentJob) .. "/delivery.json"]).state)
check("a silent paste tool keeps the transcript", "silent text", clipboard)
pasteSilent = false

-- A tool that fails, and a tool that cannot be started, are visible failures with
-- nothing typed into the user's window.
clipboard = nil
activeWindow = EDITOR
pasteExitCode = 1
onWidgetRecord()
local failedJob = state().job.id
finishSummary(failedJob, "ok", "ok", "Transcription complete.", { transcript = "failing text", recording = true, copyable = true })
update()
clockMs = clockMs + 500
update()
check("tool failure is reported", "failed", state().delivery.state)
check("tool failure keeps the transcript on the clipboard", "failing text", clipboard)
check("tool failure is notified", "error", notifications[#notifications].kind)
check("tool failure marker is persisted", "failed", noctalia.json.decode(fs[jobDir(failedJob) .. "/delivery.json"]).state)
check("bar shows the failed paste", "error", find(lastBarTree, "glyph").props.color)
pasteExitCode = 0

clipboard = nil
pasteStartRefused = true
onWidgetRecord()
local unstartedJob = state().job.id
finishSummary(unstartedJob, "ok", "ok", "Transcription complete.", { transcript = "unstarted text", recording = true, copyable = true })
update()
clockMs = clockMs + 500
local beforeUnstarted = pasteLaunches()
update()
check("a tool that cannot start is a failure", "failed", state().delivery.state)
check("a tool that cannot start injects once", beforeUnstarted + 1, pasteLaunches())
clockMs = clockMs + 2000
update()
check("a failed start is not retried", beforeUnstarted + 1, pasteLaunches())
check("a failed start keeps the transcript", "unstarted text", clipboard)
pasteStartRefused = false

-- Persistence failure before delivery: nothing is typed, and the failure says what
-- happened instead of pretending the paste went out.
clipboard, clipboardMime = nil, nil
clipboardWriteFails = true
activeWindow = EDITOR
onWidgetRecord()
local unwritableJob = state().job.id
finishSummary(unwritableJob, "ok", "ok", "Transcription complete.", { transcript = "unwritable text", recording = true, copyable = true })
update()
clockMs = clockMs + 500
local beforeUnwritable = pasteLaunches()
update()
check("a failed clipboard write is a failure", "failed", state().delivery.state)
check("a failed clipboard write sends no keys", beforeUnwritable, pasteLaunches())
check("a failed clipboard write says why", true, string.find(state().delivery.message, "clipboard") ~= nil)
clipboardWriteFails = false

-- Output the plugin cannot trust is never pasted on its own, even when the text is
-- still readable and copyable by hand: the whole point is that the user decides.
local untrusted = {
  { "empty", "error", false },
  { "malformed_row", "error", false },
  { "truncated", "review", true },
  { "unknown_token", "review", true },
  { "nonzero_exit", "error", false },
}
for _, case in ipairs(untrusted) do
  clipboard = nil
  onWidgetRecord()
  local badJob = state().job.id
  finishSummary(badJob, case[1], case[2], "Not trustworthy.", { transcript = "untrusted text", recording = true, copyable = case[3] })
  update()
  clockMs = clockMs + 500
  local beforeBad = pasteLaunches()
  update()
  check("never pastes on its own: " .. case[1], beforeBad, pasteLaunches())
  check("copies nothing for: " .. case[1], nil, clipboard)
  check("stays idle for: " .. case[1], "idle", state().delivery.state)
end

-- A recording started from the panel has no destination: the panel is a layer
-- surface the recording came from, not the application the user was typing in.
activeWindow = EDITOR
onOpen({})
onRecord()
local panelStartedJob = state().job.id
onClose()
finishSummary(panelStartedJob, "ok", "ok", "Transcription complete.", { transcript = "panel started", recording = true, copyable = true })
update()
clockMs = clockMs + 500
local beforePanelStart = pasteLaunches()
update()
check("a panel-started recording arms no destination", "held", state().delivery.state)
check("a panel-started recording pastes nothing", beforePanelStart, pasteLaunches())
check("a panel-started recording asks for a target", true, string.find(state().delivery.message, "panel") ~= nil)

-- An open panel holds the keyboard, so the chord would land in the panel. Automatic
-- delivery is held; the explicit action closes the panel so the keyboard returns to
-- the window the user came from, and a panel that stays open is held instead.
clipboard = nil
activeWindow = EDITOR
onWidgetRecord()
local keyboardJob = state().job.id
onOpen({})
finishSummary(keyboardJob, "ok", "ok", "Transcription complete.", { transcript = "keyboard text", recording = true, copyable = true })
update()
clockMs = clockMs + 500
local beforeKeyboard = pasteLaunches()
update()
check("an open panel holds automatic delivery", "held", state().delivery.state)
check("an open panel receives no chord", beforeKeyboard, pasteLaunches())
check("an open panel is named in the hold", true, string.find(state().delivery.message, "panel") ~= nil)
local opens = panelsOpened
onDeliver()
check("explicit paste closes the holding panel", opens + 1, panelsOpened)
onClose()
clockMs = clockMs + 500
update()
check("explicit paste after the panel closes", "attempted", state().delivery.state)
check("explicit paste after the panel closes injects", beforeKeyboard + 1, pasteLaunches())

clipboard = nil
activeWindow = EDITOR
onWidgetRecord()
local settledJob = state().job.id
finishSummary(settledJob, "ok", "ok", "Transcription complete.", { transcript = "settled text", recording = true, copyable = true })
update()
clockMs = clockMs + 500
update()
check("a confirmed target pastes", "attempted", state().delivery.state)
onOpen({})
local beforeStuck = pasteLaunches()
onDeliver()
clockMs = clockMs + 500
update()
check("a panel that stays open holds the paste", "held", state().delivery.state)
check("a panel that stays open receives nothing", beforeStuck, pasteLaunches())
onClose()

-- Manual copy is a deliberate preference and the recovery route: nothing is pasted
-- on its own, the interface offers no paste, and the explicit action is refused.
CONFIG.delivery = "manual"
onConfigChanged()
check("manual mode is named in setup", "manual", state().paste.state)
onOpen({})
check("manual mode disables the paste action", false, findByHandler(lastTree, "onDeliver").props.enabled)
onClose()
clipboard = nil
onWidgetRecord()
local manualJob = state().job.id
finishSummary(manualJob, "ok", "ok", "Transcription complete.", { transcript = "manual text", recording = true, copyable = true })
update()
clockMs = clockMs + 500
local beforeManual = pasteLaunches()
update()
check("manual mode pastes nothing", beforeManual, pasteLaunches())
check("manual mode says why", "manual", state().delivery.state)
onDeliver()
check("manual mode refuses the explicit paste", beforeManual, pasteLaunches())
check("manual mode keeps copy available", true, state().copyable)
CONFIG.delivery = "auto"
onConfigChanged()

-- The mechanism and the window query are dependencies, not privileges: a missing
-- tool is explained and held, never installed and never escalated. The chord runs
-- through the same hyprctl the window query uses, so losing it loses both.
missingCommands.hyprctl = true
onConfigChanged()
check("missing paste tool is reported", "missing", state().paste.state)
check("missing paste tool is named in setup", true, string.find(state().paste.message, "hyprctl") ~= nil)
activeWindow = EDITOR
onWidgetRecord()
local noQueryJob = state().job.id
finishSummary(noQueryJob, "ok", "ok", "Transcription complete.", { transcript = "no query text", recording = true, copyable = true })
update()
clockMs = clockMs + 500
local beforeNoQuery = pasteLaunches()
update()
check("missing window query holds delivery", "held", state().delivery.state)
check("missing window query sends no keys", beforeNoQuery, pasteLaunches())
check("missing window query is named", true, string.find(state().delivery.message, "hyprctl") ~= nil)
onDeliver()
check("explicit paste without the tool sends no keys", beforeNoQuery, pasteLaunches())
missingCommands.hyprctl = nil
onConfigChanged()

-- A crash around the marker is never repeated. With the marker on disk the next
-- runtime holds the job, and a job recovered from disk never delivers at all: its
-- destination belonged to a runtime that is gone.
clipboard = nil
activeWindow = EDITOR
onWidgetRecord()
local crashJob = state().job.id
finishSummary(crashJob, "ok", "ok", "Transcription complete.", { transcript = "crashed mid paste", recording = true, copyable = true })
putTable(jobDir(crashJob) .. "/delivery.json", { jobId = crashJob, state = "attempting", attempt = 1, clipboard = true }, "marker-attempting")
nowSeconds = nowSeconds + 3
onClose()
onExit(0, "reload")
watchers = {}
load()
local beforeCrash = pasteLaunches()
check("a paste interrupted by a crash is not repeated", "held", state().delivery.state)
check("a crash mid paste sends no keys", beforeCrash, pasteLaunches())
check("a crash mid paste explains itself", true, string.find(state().delivery.message, "did not finish") ~= nil)
check("a crash mid paste keeps the transcript", "crashed mid paste", state().transcript)

clipboard = nil
activeWindow = EDITOR
onWidgetRecord()
local recoveredJob = state().job.id
finishSummary(recoveredJob, "ok", "ok", "Transcription complete.", { transcript = "recovered text", recording = true, copyable = true })
nowSeconds = nowSeconds + 2
onExit(0, "reload")
watchers = {}
load()
local beforeRecovered = pasteLaunches()
check("a job recovered from disk is not delivered", "idle", state().delivery.state)
clockMs = clockMs + 5000
update()
check("a recovered job sends no keys", beforeRecovered, pasteLaunches())
check("a recovered job copies nothing", nil, clipboard)
check("a recovered job keeps its transcript", "recovered text", state().transcript)

-- Over the whole run every injection was the one ordinary paste chord: no speech
-- typed as keystrokes, no extra key, and no injected Return.
check("every injection is the ordinary paste chord", true, chordOnly())

-- The chord's safety is a property of the mechanism, so delivery never asks which
-- shortcut invoked the job. Shortcut setup is the only reader of the bind table.
check("delivery asks nothing about the bind table", bindsBeforeDelivery, bindsReads())

-- ── Recording shortcut ───────────────────────────────────────────────────────

-- The recording shortcut is the user's own compositor binding, so setup reads the
-- live bind table before proposing anything, writes one delimited block in the file
-- the host actually loads, copies that file aside first, and undoes by removing
-- exactly that block. Every check here drives the panel's own buttons through the
-- command channel, then reads the file and the launches the runtime really saw.
fs[CONFIG_DIR] = "@dir"
fixtureBinds = {}
putFile(CONF_PATH, "# user config\nbind = SUPER, Return, exec, terminal\n")

command("shortcut-refresh")
check("a free chord is offered", "available", state().shortcut.state)
check("a free chord is named", "Super+Alt+D", state().shortcut.chord)
check("a free chord can be installed", true, state().shortcut.canInstall)
check("a free chord has nothing to undo", false, state().shortcut.canRemove)

-- A bind defined inside a submap only fires while that submap is active, so it
-- does not occupy the chord in the default submap.
fixtureBinds = { { modmask = 72, key = "D", submap = "resize", has_description = true, description = "resize mode" } }
command("shortcut-refresh")
check("a submap binding is not a conflict", "available", state().shortcut.state)
fixtureBinds = {}

command("shortcut-install")
check("install reports the effective binding", "installed", state().shortcut.state)
check("install writes the proposed chord", true, string.find(fs[CONF_PATH], "bindd = SUPER ALT, D,", 1, true) ~= nil)
check("install invokes the controller IPC", true, string.find(fs[CONF_PATH], "noctalia msg plugin magus/dictation:controller all toggle", 1, true) ~= nil)
check("install writes one delimited block", 1, select(2, string.gsub(fs[CONF_PATH], "magus/dictation:recording%-shortcut:begin", "")))
check("install keeps the user's lines", true, string.find(fs[CONF_PATH], "bind = SUPER, Return, exec, terminal", 1, true) ~= nil)
check("install writes the block above the user's lines", true, string.find(fs[CONF_PATH], "recording-shortcut:begin", 1, true) < string.find(fs[CONF_PATH], "# user config", 1, true))
check("install backs the file up first", "# user config\nbind = SUPER, Return, exec, terminal\n", fs[CONF_PATH .. ".magus-dictation.bak"])
check("install reloads the compositor", true, launched("hyprctl reload"))
check("install offers undo", true, state().shortcut.canRemove)
check("install reports the copy", true, string.find(state().shortcut.message, ".magus-dictation.bak", 1, true) ~= nil)

-- A no-change retry converges: the second install writes the same file and leaves
-- one block, not two.
local installedOnce = fs[CONF_PATH]
command("shortcut-install")
check("a repeated install converges", installedOnce, fs[CONF_PATH])
check("a repeated install adds no second block", 1, select(2, string.gsub(fs[CONF_PATH], "magus/dictation:recording%-shortcut:begin", "")))
check("a repeated install stays installed", "installed", state().shortcut.state)

-- A chord somebody else already holds is never overwritten.
fixtureBinds = { { modmask = 72, key = "D", has_description = true, description = "my launcher" } }
command("shortcut-refresh")
check("an already used chord is a conflict", "conflict", state().shortcut.state)
check("an already used chord offers no install", false, state().shortcut.canInstall)
check("a conflict names who holds the chord", true, string.find(state().shortcut.message, "my launcher", 1, true) ~= nil)
check("a conflict still offers undo", true, state().shortcut.canRemove)
local beforeConflict = fs[CONF_PATH]
command("shortcut-install")
check("installing over a conflict writes nothing", beforeConflict, fs[CONF_PATH])
check("installing over a conflict stays a conflict", "conflict", state().shortcut.state)

fixtureBinds = {}
command("shortcut-refresh")
check("the installed chord is recognised as this setup's", "installed", state().shortcut.state)

-- The user keeps editing after setup wrote its block. Undo takes the block and
-- leaves everything else, including the edits made after the copy was taken.
putFile(CONF_PATH, fs[CONF_PATH] .. "\nbind = SUPER SHIFT, Q, exit\n")
command("shortcut-remove")
check("undo removes the block", nil, string.find(fs[CONF_PATH], "magus/dictation:recording-shortcut:begin", 1, true))
check("undo keeps later user edits", true, string.find(fs[CONF_PATH], "bind = SUPER SHIFT, Q, exit", 1, true) ~= nil)
check("undo keeps the user's original lines", true, string.find(fs[CONF_PATH], "bind = SUPER, Return, exec, terminal", 1, true) ~= nil)
check("undo does not restore the older copy over them", nil, string.find(fs[CONF_PATH], "magus/dictation", 1, true))
check("undo restores the file exactly", "# user config\nbind = SUPER, Return, exec, terminal\n\nbind = SUPER SHIFT, Q, exit\n", fs[CONF_PATH])
check("undo copies the current file aside", true, string.find(fs[CONF_PATH .. ".magus-dictation.bak"], "bind = SUPER SHIFT, Q, exit", 1, true) ~= nil)
check("undo reloads the compositor", true, launched("hyprctl reload"))
check("undo leaves the chord free", "available", state().shortcut.state)
check("undo has nothing left to remove", false, state().shortcut.canRemove)

-- A host that runs the Lua configuration never loads a hyprland.conf fragment, so
-- the same setup writes the form that host reads, and a top-level return stays
-- last because a Lua chunk may end there.
fs[CONF_PATH] = nil
putFile(LUA_PATH, "hl.config({ general = {} })\n")
fixtureBinds = {}
command("shortcut-refresh")
check("the lua configuration is found", "available", state().shortcut.state)
check("the lua configuration is named", LUA_PATH, state().shortcut.path)
command("shortcut-install")
check("lua install is effective", "installed", state().shortcut.state)
check("lua install binds through hl", true, string.find(fs[LUA_PATH], 'hl.bind("SUPER + ALT + D"', 1, true) ~= nil)
check("lua install invokes the controller IPC", true, string.find(fs[LUA_PATH], 'exec_cmd("noctalia msg plugin magus/dictation:controller all toggle")', 1, true) ~= nil)
check("lua install keeps the user's configuration", true, string.find(fs[LUA_PATH], "hl.config({ general = {} })", 1, true) ~= nil)
check("lua install writes no hyprlang bind", nil, string.find(fs[LUA_PATH], "bindd =", 1, true))

putFile(LUA_PATH, "local opts = {}\nreturn opts\n")
command("shortcut-refresh")
command("shortcut-install")
check("the lua block precedes a top-level return", true, string.find(fs[LUA_PATH], "hl.bind", 1, true) < string.find(fs[LUA_PATH], "return opts", 1, true))
check("the lua block is written once", 1, select(2, string.gsub(fs[LUA_PATH], "magus/dictation:recording%-shortcut:begin", "")))
command("shortcut-remove")
check("undo restores the short lua file", "local opts = {}\nreturn opts\n", fs[LUA_PATH])

-- A write that fails leaves the configuration alone and says what to look at.
putFile(LUA_PATH, "hl.config({})\n")
command("shortcut-refresh")
backupWriteFails = true
command("shortcut-install")
check("a failed copy writes no binding", "hl.config({})\n", fs[LUA_PATH])
check("a failed copy is reported", "error", state().shortcut.state)
check("a failed copy can be retried", true, state().shortcut.canInstall)
backupWriteFails = false
configWriteFails = true
command("shortcut-install")
check("a failed write leaves the configuration", "hl.config({})\n", fs[LUA_PATH])
check("a failed write is reported", "error", state().shortcut.state)
check("a failed write names the copy", true, string.find(state().shortcut.message, ".magus-dictation.bak", 1, true) ~= nil)
check("a failed write can be retried", true, state().shortcut.canInstall)
configWriteFails = false

-- An undo whose copy cannot be written leaves the block in place rather than
-- removing something it could not record first.
command("shortcut-install")
check("undo setup installed the block", "installed", state().shortcut.state)
backupWriteFails = true
command("shortcut-remove")
check("a failed undo copy is reported", "error", state().shortcut.state)
check("a failed undo copy leaves the block", true, string.find(fs[LUA_PATH], "recording-shortcut:begin", 1, true) ~= nil)
check("a failed undo copy can be retried", true, state().shortcut.canRemove)
backupWriteFails = false
command("shortcut-remove")
check("the retried undo removes the block", "available", state().shortcut.state)

-- A binding that was written but not registered is reported truthfully, and undo is
-- offered because the block really is on disk.
fixtureBinds = {}
bindsIgnoreConfig = true
command("shortcut-install")
check("an unregistered binding is reported", "error", state().shortcut.state)
check("an unregistered binding is on disk", true, string.find(fs[LUA_PATH], "magus/dictation:recording-shortcut:begin", 1, true) ~= nil)
check("an unregistered binding offers undo", true, state().shortcut.canRemove)
check("an unregistered binding says so", true, string.find(state().shortcut.message, "did not register", 1, true) ~= nil)
bindsIgnoreConfig = false
command("shortcut-remove")
check("undo clears the unregistered binding", "available", state().shortcut.state)
check("undo leaves the rest of the file", "hl.config({})\n", fs[LUA_PATH])

-- A reload that fails leaves a truthful status without a second write: the block is
-- on disk, so undo is still the recovery action.
putFile(LUA_PATH, "hl.config({})\n")
fixtureBinds = {}
command("shortcut-refresh")
reloadExitCode = 1
command("shortcut-install")
check("a failed reload is reported", "error", state().shortcut.state)
check("a failed reload keeps the binding on disk", true, string.find(fs[LUA_PATH], "magus/dictation:recording-shortcut:begin", 1, true) ~= nil)
check("a failed reload offers undo", true, state().shortcut.canRemove)
check("a failed reload names the copy", true, string.find(state().shortcut.message, ".magus-dictation.bak", 1, true) ~= nil)
reloadExitCode = 0
command("shortcut-remove")
check("undo clears a failed reload", "available", state().shortcut.state)

-- An undo whose reload fails says the chord may still be active rather than
-- claiming it is gone.
fixtureBinds = {}
command("shortcut-install")
reloadExitCode = 1
command("shortcut-remove")
check("a failed undo reload is reported", "error", state().shortcut.state)
check("a failed undo reload removed the block", nil, string.find(fs[LUA_PATH], "magus/dictation:recording%-shortcut:begin"))
check("a failed undo reload says the chord may be active", true, string.find(state().shortcut.message, "may still be active", 1, true) ~= nil)
reloadExitCode = 0
command("shortcut-refresh")

-- A compositor that accepts the reload and never answers must not leave the row
-- busy forever: the wait is bounded and the row comes back with an action.
putFile(LUA_PATH, "hl.config({})\n")
fixtureBinds = {}
command("shortcut-refresh")
reloadSilent = true
command("shortcut-install")
check("an unanswered reload is busy", "working", state().shortcut.state)
clockMs = clockMs + 31000
update()
check("an unanswered reload is bounded", "error", state().shortcut.state)
check("an unanswered reload comes back with a recheck", true, state().shortcut.canInstall)
reloadSilent = false
command("shortcut-refresh")
check("the bounded wait recovers", "installed", state().shortcut.state)

-- A bind query that never answers is bounded too, so the row cannot stay busy.
bindsSilent = true
command("shortcut-refresh")
check("an unanswered check is busy", "working", state().shortcut.state)
clockMs = clockMs + 31000
update()
check("an unanswered check is bounded", "error", state().shortcut.state)
check("an unanswered check comes back with a recheck", true, state().shortcut.canInstall)
bindsSilent = false
command("shortcut-refresh")

-- An edit made while the compositor is answering is not written over: the file is
-- read again after the answer.
putFile(LUA_PATH, "hl.config({})\n")
fixtureBinds = {}
command("shortcut-refresh")
duringBindsQuery = function() putFile(LUA_PATH, "hl.config({})\n-- user edit during the query\n") end
command("shortcut-install")
duringBindsQuery = nil
check("an edit during the query survives install", true, string.find(fs[LUA_PATH], "user edit during the query", 1, true) ~= nil)
check("an edit during the query still gets the binding", true, string.find(fs[LUA_PATH], "magus/dictation:recording-shortcut:begin", 1, true) ~= nil)
command("shortcut-remove")
check("undo clears an install beside a concurrent edit", "available", state().shortcut.state)

-- A bind that only shares this setup's wording is somebody else's until the block
-- on disk says otherwise, so it is refused instead of claimed as this setup's.
fixtureBinds = { {
  modmask = 72, key = "D", has_description = true,
  description = "Dictation: start or stop recording", dispatcher = "exec", arg = "their-own-dictation-script",
} }
command("shortcut-refresh")
check("a foreign binding that shares the wording is a conflict", "conflict", state().shortcut.state)
command("shortcut-install")
check("a foreign binding that shares the wording is not written", nil, string.find(fs[LUA_PATH], "recording-shortcut:begin", 1, true))
check("a foreign binding that shares the wording names who holds it", true, string.find(state().shortcut.message, "their-own-dictation-script", 1, true) ~= nil)

-- A binding of the same command written by hand is not this setup's either: the
-- compositor runs every binding on a chord, so installing beside it would toggle twice.
fixtureBinds = { { modmask = 72, key = "D", dispatcher = "exec", arg = "noctalia msg plugin magus/dictation:controller all toggle" } }
command("shortcut-refresh")
check("a hand-written binding of the same command is a conflict", "conflict", state().shortcut.state)
check("a hand-written binding of the same command offers no install", false, state().shortcut.canInstall)
fixtureBinds = {}
command("shortcut-refresh")

-- A block the user half-deleted by hand is neither overwritten nor claimed as
-- removed: writing beside it would add a second binding, and stripping it would
-- report a removal that never happened.
putFile(LUA_PATH, "-- magus/dictation:recording-shortcut:begin\nhl.bind(\"SUPER + ALT + D\", nil)\n")
local halfDeleted = fs[LUA_PATH]
command("shortcut-refresh")
check("a half-deleted block is reported", "error", state().shortcut.state)
check("a half-deleted block is not installable", false, state().shortcut.canInstall)
check("a half-deleted block is not removable", false, state().shortcut.canRemove)
check("a half-deleted block names its marker", true, string.find(state().shortcut.message, "recording-shortcut:end", 1, true) ~= nil)
command("shortcut-install")
check("a half-deleted block is left alone on install", halfDeleted, fs[LUA_PATH])
command("shortcut-remove")
check("a half-deleted block is left alone on undo", halfDeleted, fs[LUA_PATH])

-- The panel shows the shortcut in the ordinary native widgets and its buttons are
-- the only way to change the binding. A host without the compositor tool keeps
-- recording usable, so the shortcut row is a limitation and not a dead end.
putFile(LUA_PATH, "hl.config({})\n")
fixtureBinds = {}
command("shortcut-refresh")
onOpen({})
check("the panel names the proposed chord", true, find(lastTree, "label", "Recording shortcut (Super+Alt+D)") ~= nil)
check("the panel offers the install action", true, findByHandler(lastTree, "onInstallShortcut") ~= nil)
check("the panel offers the undo action", true, findByHandler(lastTree, "onRemoveShortcut") ~= nil)
check("the panel offers a recheck", true, findByHandler(lastTree, "onCheckShortcut") ~= nil)
check("the install action is enabled while the chord is free", true, findByHandler(lastTree, "onInstallShortcut").props.enabled)
command("shortcut-install")
onOpen({})
check("the panel reports the effective binding", true, findText(lastTree, "starts and stops recording") ~= nil)
check("the panel offers undo once installed", true, findByHandler(lastTree, "onRemoveShortcut").props.enabled)
check("the panel stops offering the first install", nil, find(lastTree, "button", "Install shortcut"))
command("shortcut-remove")
missingCommands.hyprctl = true
command("shortcut-refresh")
check("a missing compositor tool is unsupported", "unsupported", state().shortcut.state)
check("a missing compositor tool cannot install", false, state().shortcut.canInstall)
check("a missing compositor tool still names a chord", "Super+Alt+D", state().shortcut.chord)
onOpen({})
check("the panel still offers recording", true, findByHandler(lastTree, "onRecord") ~= nil)
check("the install action is disabled while unsupported", false, findByHandler(lastTree, "onInstallShortcut").props.enabled)
check("the undo action is disabled while unsupported", false, findByHandler(lastTree, "onRemoveShortcut").props.enabled)
onClose()
missingCommands.hyprctl = nil

-- With nothing to write to at all, the setup says where it looked instead of
-- pretending it can install.
fs[CONF_PATH], fs[LUA_PATH] = nil, nil
command("shortcut-refresh")
check("no configuration file is unsupported", "unsupported", state().shortcut.state)
check("no configuration file cannot install", false, state().shortcut.canInstall)

-- A path the compositor was told to use but that is not there is named, instead of
-- being reported as a free chord this setup cannot write to.
ENV.HYPRLAND_CONFIG = CONFIG_DIR .. "/missing.lua"
command("shortcut-refresh")
check("a missing explicit configuration is unsupported", "unsupported", state().shortcut.state)
check("a missing explicit configuration is named", true, string.find(state().shortcut.message, "missing.lua", 1, true) ~= nil)
check("a missing explicit configuration cannot install", false, state().shortcut.canInstall)
ENV.HYPRLAND_CONFIG = nil

-- The compositor runs every binding on a chord, so a second binding beside this
-- setup's own block is reported rather than hidden behind "installed".
putFile(CONF_PATH, "# user config\nbind = SUPER, Return, exec, terminal\n")
fixtureBinds = {}
command("shortcut-refresh")
check("the reinstalled chord is free", "available", state().shortcut.state)
command("shortcut-install")
check("the reinstalled chord is installed", "installed", state().shortcut.state)
fixtureBinds = { { modmask = 72, key = "D", has_description = true, description = "Dictation: start or stop recording" } }
command("shortcut-refresh")
check("a duplicate of this setup's own binding is a conflict", "conflict", state().shortcut.state)
check("a duplicate of this setup's own binding says the chord would run twice", true, string.find(state().shortcut.message, "run twice", 1, true) ~= nil)
check("a duplicate of this setup's own binding still offers undo", true, state().shortcut.canRemove)
fixtureBinds = { { modmask = 72, key = "D", dispatcher = "exec", arg = "their-own-dictation-script" } }
command("shortcut-refresh")
check("a second binding on the chord is a conflict", "conflict", state().shortcut.state)
check("a second binding on the chord is named", true, string.find(state().shortcut.message, "their-own-dictation-script", 1, true) ~= nil)
check("a second binding on the chord still offers undo", true, state().shortcut.canRemove)
local withDuplicate = fs[CONF_PATH]
command("shortcut-install")
check("a second binding on the chord is not written again", withDuplicate, fs[CONF_PATH])
fixtureBinds = {}
command("shortcut-refresh")
check("the chord is this setup's once the duplicate is gone", "installed", state().shortcut.state)
command("shortcut-remove")
check("undo clears the reinstalled block", "available", state().shortcut.state)

-- The check has to fail its process, not only print: a caller and any automation
-- reading the exit status must see a failed run.
if failures > 0 then
  error(("controller harness FAILED: %d"):format(failures), 0)
end
print("controller harness ok")
