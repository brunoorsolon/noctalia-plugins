-- Drives the plugin's widget entry against a stubbed Noctalia runtime and a
-- stubbed hyprctl, so the status file to widget state mapping is checked here
-- rather than only on a host with Noctalia, Hyprland and Pi. ./selftest.sh
-- injects the entry source as the global SOURCES table and runs this file.
--
-- It is a check, not a plugin entry: plugin.toml never loads it.

local failures = 0
local function check(name, expected, actual)
  if expected ~= actual then
    failures = failures + 1
    print(("FAIL %-60s expected [%s] got [%s]"):format(name, tostring(expected), tostring(actual)))
  end
end
local function checkTrue(name, condition)
  if not condition then
    failures = failures + 1
    print(("FAIL %-60s condition was false"):format(name))
  end
end

-- ── The stub runtime ─────────────────────────────────────────────────────────

local RUNTIME_DIR = "/run/user/1000"
local STATE_DIR = "/home/user/.local/state"
local STATUS_PATH = RUNTIME_DIR .. "/pi-hypr-agent-monitor/status.json"
local STATE_STATUS_PATH = STATE_DIR .. "/pi-hypr-agent-monitor/status.json"
local LIVE_PID = 4242
local DEAD_PID = 4243

local CONFIG = {
  workspace = "pi",
  terminal = "foot",
  spawn = "pi -c --session-dir ~/.local/state/pi-scratchpad/sessions",
  working_dir = "~",
  geometry = "900x600",
  notify = true,
}

local files = {}         -- absolute path -> contents
local processes = {}     -- pid -> true for the ones the stub reports alive
local decoded = {}       -- raw JSON -> the table the runtime would decode it to
local dispatches = {}    -- every hyprctl dispatch argv, in order
local notifications = {} -- every noctalia.notify call
local updates = 0
local lastGlyph, lastTooltip = nil, nil
local visible = false

-- What the compositor would answer for `hyprctl -j monitors`: one monitor whose
-- specialWorkspace carries the workspace name while it is showing.
local function monitorsJson()
  local name = visible and ("special:" .. CONFIG.workspace) or ""
  local id = visible and 1 or 0
  local raw = ('[{"name":"DP-1","focused":true,"specialWorkspace":{"id":%d,"name":"%s"}}]'):format(id, name)
  decoded[raw] = { { name = "DP-1", focused = true, specialWorkspace = { id = id, name = name } } }
  return raw
end

noctalia = {}

local ENV = { XDG_RUNTIME_DIR = RUNTIME_DIR, HOME = "/home/user" }

function noctalia.getenv(name) return ENV[name] end

noctalia.string = { trim = function(value) return (value:gsub("^%s+", ""):gsub("%s+$", "")) end }

function noctalia.getConfig(key) return CONFIG[key] end
function noctalia.setUpdateInterval() end

function noctalia.fileExists(path)
  if files[path] ~= nil then return true end
  local pid = path:match("^/proc/(%d+)$")
  if pid then return processes[tonumber(pid)] == true end
  return false
end

function noctalia.readFile(path)
  local contents = files[path]
  if contents == nil then return nil, "No such file or directory" end
  return contents
end

-- The fixtures below are registered with the table the runtime would decode them
-- to; a malformed document is simply never registered, the way a real decoder
-- fails on it.
noctalia.json = {
  decode = function(raw) return decoded[raw] end,
}

function noctalia.notify(title, body) table.insert(notifications, { title = title, body = body }) end

function noctalia.runAsync(argv, onResult)
  local result = { exitCode = 0, stdout = "", stderr = "", timedOut = false, stdoutTruncated = false, stderrTruncated = false }
  if argv[1] == "hyprctl" and argv[2] == "-j" then
    result.stdout = monitorsJson()
  elseif argv[1] == "hyprctl" and argv[2] == "dispatch" then
    table.insert(dispatches, argv)
  end
  if type(onResult) == "function" then onResult(result) end
  return true
end

ui = {
  glyph = function(props) return { kind = "glyph", props = props or {} } end,
}

barWidget = {
  render = function(tree)
    lastGlyph = tree.kind == "glyph" and tree.props.name or nil
    lastTooltip = nil
  end,
  setTooltip = function(text) lastTooltip = text end,
}

-- ── The entry ────────────────────────────────────────────────────────────────

assert(loadstring(SOURCES.scratchpad, "scratchpad.luau"))()

-- ── Fixtures ─────────────────────────────────────────────────────────────────

-- One document per state, built to the extension's shape: state, pid, session_id,
-- cwd, model and updated_at, written atomically and removed on session_shutdown.
local function document(state, pid)
  local raw = ('{"state":"%s","pid":%d,"session_id":"s-1","cwd":"/home/user/project","model":"pi-3","updated_at":1757960000}'):format(state, pid)
  decoded[raw] = { state = state, pid = pid, session_id = "s-1", cwd = "/home/user/project", model = "pi-3", updated_at = 1757960000 }
  return raw
end

local WORKING = document("working", LIVE_PID)
local WAITING = document("waiting", LIVE_PID)
local IDLE = document("idle", LIVE_PID)
local UNRECOGNISED = document("thinking", LIVE_PID)
-- A document with no pid at all: there is no process to check, so it cannot be
-- reported as gone.
local PIDLESS = '{"state":"working","session_id":"s-1","cwd":"/home/user/project"}'
decoded[PIDLESS] = { state = "working", session_id = "s-1", cwd = "/home/user/project" }
local DEAD_PID_DOCUMENT = document("working", DEAD_PID)
-- A torn write: valid JSON never lands on disk, because the extension writes
-- atomically, so this is the "cannot be parsed" case.
local MALFORMED = '{"state":"working","pid":4242,'

processes[LIVE_PID] = true

local function show(raw) files[STATUS_PATH] = raw end

local function glyphFor(raw)
  show(raw)
  updates = updates + 1
  update()
  return lastGlyph
end

local function tooltipFor(raw)
  show(raw)
  update()
  return lastTooltip
end

-- ── Every state the status file can be in ────────────────────────────────────

show(nil)
update()

local working = glyphFor(WORKING)
local waiting = glyphFor(WAITING)
local idle = glyphFor(IDLE)
local malformed = glyphFor(MALFORMED)
local unrecognised = glyphFor(UNRECOGNISED)
local pidless = glyphFor(PIDLESS)
local deadPid = glyphFor(DEAD_PID_DOCUMENT)
local missing = glyphFor(nil)

checkTrue("working, waiting and idle render three different glyphs",
  working ~= waiting and waiting ~= idle and working ~= idle)
check("a document that cannot be parsed reads the same as an unrecognised state", unrecognised, malformed)
check("a document with no usable pid reads as unknown, not as gone", pidless, malformed)
check("a recorded pid with no live process reads the same as a missing file", missing, deadPid)
checkTrue("an unreadable status is distinct from not running", malformed ~= missing)

-- The glyph alone does not say which state a bar is in, so the tooltip has to
-- name it. Substrings, not the exact copy, so the wording stays free.
local function names(raw, word)
  local tooltip = tooltipFor(raw)
  return type(tooltip) == "string" and tooltip:lower():find(word, 1, true) ~= nil
end
checkTrue("the working state says working", names(WORKING, "working"))
checkTrue("the waiting state says waiting", names(WAITING, "waiting"))
checkTrue("the idle state says idle", names(IDLE, "idle"))

-- When the runtime directory is unset the extension writes under XDG_STATE_HOME,
-- so the widget has to look there too.
ENV.XDG_RUNTIME_DIR = nil
ENV.XDG_STATE_HOME = STATE_DIR
files[STATE_STATUS_PATH] = WORKING
check("the XDG_STATE_HOME fallback finds the status file", working, glyphFor(nil))
files[STATE_STATUS_PATH] = nil
ENV.XDG_RUNTIME_DIR = RUNTIME_DIR
ENV.XDG_STATE_HOME = nil

-- ── Click routing ────────────────────────────────────────────────────────────

local function hasDispatch(kind)
  for _, argv in ipairs(dispatches) do
    for _, argument in ipairs(argv) do
      if argument == kind then return true end
    end
  end
  return false
end

local function commandText()
  for _, argv in ipairs(dispatches) do
    if argv[2] == "dispatch" and argv[3] == "exec" then return argv[4] end
  end
  return ""
end

-- Nothing running: the click has to spawn, floating at the configured size in
-- the configured special workspace, with the monitor variable set.
show(nil)
dispatches = {}
onClick()
local spawn = commandText()
checkTrue("a missing session spawns Pi", hasDispatch("exec"))
checkTrue("the spawn sets PI_HYPR_MONITOR", spawn:find("PI_HYPR_MONITOR=1", 1, true) ~= nil)
checkTrue("the spawn floats at the configured size", spawn:find("size 900 600", 1, true) ~= nil)
checkTrue("the spawn targets the special workspace", spawn:find("workspace special:pi]", 1, true) ~= nil)
checkTrue("the spawn reveals the workspace it spawns into", hasDispatch("togglespecialworkspace"))
-- A quoted "~" never expands under the /bin/sh Hyprland runs, so the working
-- directory has to be absolute by the time it is quoted.
checkTrue("the default working directory resolves before it is quoted", spawn:find("cd '/home/user'", 1, true) ~= nil)

CONFIG.working_dir = "~/project"
dispatches = {}
onClick()
checkTrue("a ~/ working directory resolves too", commandText():find("cd '/home/user/project'", 1, true) ~= nil)
CONFIG.working_dir = "~"

-- A live session: the click has to toggle, not spawn a second Pi.
dispatches = {}
show(WORKING)
onClick()
checkTrue("a live session toggles the workspace", hasDispatch("togglespecialworkspace"))
checkTrue("a live session never spawns", not hasDispatch("exec"))

-- A status that cannot be read still means a session was there, so it toggles
-- instead of risking a duplicate.
dispatches = {}
show(MALFORMED)
onClick()
checkTrue("an unreadable status toggles instead of spawning", not hasDispatch("exec"))

-- "special:pi" and "pi" name the same workspace; the plugin must not build
-- "special:special:pi".
CONFIG.workspace = "special:hi"
dispatches = {}
show(nil)
onClick()
checkTrue("a special: prefix in the setting is not doubled",
  commandText():find("workspace special:hi]", 1, true) ~= nil and
  commandText():find("special:special:", 1, true) == nil)
CONFIG.workspace = "pi"

-- ── The waiting notification ─────────────────────────────────────────────────

local function notifyCount()
  local count = #notifications
  notifications = {}
  return count
end

visible = false
show(nil)
update()
notifyCount()

show(WAITING)
update()
check("becoming waiting while hidden notifies once", 1, notifyCount())
update()
check("staying waiting does not notify again", 0, notifyCount())

show(IDLE)
update()
notifyCount()
visible = true
show(WAITING)
update()
check("becoming waiting on screen is silent", 0, notifyCount())

show(IDLE)
update()
visible = false
CONFIG.notify = false
show(WAITING)
update()
check("the notify setting silences it", 0, notifyCount())
CONFIG.notify = true

-- The check has to fail its process, not only print: a caller and any automation
-- reading the exit status must see a failed run.
if failures > 0 then
  error(("scratchpad harness FAILED: %d"):format(failures), 0)
end
print(("scratchpad harness ok (%d ticks)"):format(updates))
