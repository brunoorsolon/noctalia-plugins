-- Drives the plugin's widget entry against a stubbed Noctalia runtime and a
-- stubbed hyprctl, so the status file to widget state mapping is checked here
-- rather than only on a host with Noctalia, Hyprland and Pi. The hyprctl stub
-- evaluates dispatch arguments the way a Lua-configured Hyprland does, so the
-- compositor boundary is a parsed dispatcher table, not a command string.
-- ./selftest.sh injects the entry source as the global SOURCES table and runs
-- this file.
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
-- What the extension uses when neither XDG_RUNTIME_DIR nor XDG_STATE_HOME is set.
local HOME_STATUS_PATH = "/home/user/.local/state/pi-hypr-agent-monitor/status.json"
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
local calls = {}         -- the dispatcher table each dispatch expression built
local dispatchReplies = {} -- queued { exitCode, stdout } dispatch replies, in order
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

-- Entries run in isolated VMs and exchange plain values through this channel, so
-- the stub keeps one table for the whole run: that is all two placements share.
local shared = {}
noctalia.state = {
  get = function(key) return shared[key] end,
  set = function(key, value) shared[key] = value end,
}

-- Wall-clock milliseconds, moved by the harness so a spawn grace can lapse.
local clock = 1000000
function noctalia.nowMs() return clock end
local function advance(ms) clock = clock + ms end

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

-- What a Lua-configured Hyprland does with a dispatch: hyprctl evaluates
-- `return hl.dispatch(<argument>)`, so the stub evaluates the same expression
-- against the dispatcher API and records the table it built. A queued failure
-- answers the way a real rejection does instead.
hl = {
  dispatch = function(dispatcher)
    assert(type(dispatcher) == "table", "hl.dispatch needs a dispatcher table")
    table.insert(calls, dispatcher)
  end,
  dsp = {
    exec_cmd = function(command, rules)
      return { kind = "exec_cmd", command = command, rules = rules or {} }
    end,
    workspace = {
      toggle_special = function(name)
        return { kind = "toggle_special", name = name }
      end,
    },
  },
}

function noctalia.runAsync(argv, onResult)
  local result = { exitCode = 0, stdout = "", stderr = "", timedOut = false, stdoutTruncated = false, stderrTruncated = false }
  if argv[1] == "hyprctl" and argv[2] == "-j" then
    result.stdout = monitorsJson()
  elseif argv[1] == "hyprctl" and argv[2] == "dispatch" then
    local reply = table.remove(dispatchReplies, 1)
    if reply then
      result.exitCode = reply.exitCode
      result.stdout = reply.stdout
    else
      local chunk, err = loadstring("return hl.dispatch(" .. argv[3] .. ")")
      assert(chunk, "the dispatch argument is not a valid Lua expression: " .. tostring(err))
      chunk()
      result.stdout = "ok\n"
    end
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
local firstUpdate, firstOnClick = update, onClick
assert(loadstring(SOURCES.scratchpad, "scratchpad.luau"))()
local secondUpdate, secondOnClick = update, onClick

-- ── Fixtures ─────────────────────────────────────────────────────────────────

-- One document per state, in the shape the companion extension documents: every
-- field present, state as one of the three words, updated_at in Unix seconds.
local function document(state, pid)
  local raw = ('{"state":"%s","pid":%d,"session_id":"0f3c1a","cwd":"/home/bruno","model":"anthropic/claude-sonnet-4-5","updated_at":1757260800}'):format(state, pid)
  decoded[raw] = { state = state, pid = pid, session_id = "0f3c1a", cwd = "/home/bruno", model = "anthropic/claude-sonnet-4-5", updated_at = 1757260800 }
  return raw
end

local WORKING = document("working", LIVE_PID)
local WAITING = document("waiting", LIVE_PID)
local IDLE = document("idle", LIVE_PID)
local UNRECOGNISED = document("thinking", LIVE_PID)
-- A document with no pid at all: there is no process to check, so it cannot be
-- reported as gone.
local PIDLESS = '{"state":"working","session_id":"0f3c1a","cwd":"/home/bruno"}'
decoded[PIDLESS] = { state = "working", session_id = "0f3c1a", cwd = "/home/bruno" }
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

-- And XDG_STATE_HOME itself defaults to ~/.local/state, so a session with neither
-- variable set is still findable.
ENV.XDG_STATE_HOME = nil
files[HOME_STATUS_PATH] = WORKING
check("the ~/.local/state default finds the status file", working, glyphFor(nil))
files[HOME_STATUS_PATH] = nil
ENV.XDG_RUNTIME_DIR = RUNTIME_DIR

-- ── Click routing ────────────────────────────────────────────────────────────

local function callsOf(kind)
  local found = {}
  for _, call in ipairs(calls) do
    if call.kind == kind then table.insert(found, call) end
  end
  return found
end

local function spawnCount()
  return #callsOf("exec_cmd")
end

local function lastCall()
  return calls[#calls]
end

-- Nothing running: the click has to spawn, in the configured special workspace,
-- with the monitor variable set, through a Lua dispatcher expression rather
-- than the legacy command pair.
show(nil)
advance(60000) -- no spawn is in flight from an earlier case
calls = {}
onClick()
local spawn = callsOf("exec_cmd")[1]
check("a missing session spawns Pi", spawn and spawn.kind, "exec_cmd")
checkTrue("the spawn sets PI_HYPR_MONITOR", spawn.command:find("PI_HYPR_MONITOR=1", 1, true) ~= nil)
check("the spawn carries the configured size",
  spawn.rules.size and (spawn.rules.size[1] .. "x" .. spawn.rules.size[2]), "900x600")
checkTrue("the spawn floats and centres", spawn.rules.float == true and spawn.rules.center == true)
check("the spawn targets the configured special workspace", spawn.rules.workspace, "special:pi")
check("the spawn reveals the workspace it spawns into", lastCall() and lastCall().kind, "toggle_special")
check("the reveal names the workspace once", lastCall() and lastCall().name, "pi")
-- A quoted "~" never expands under the /bin/sh Hyprland runs, so the working
-- directory has to be absolute by the time it is quoted.
checkTrue("the default working directory resolves before it is quoted", spawn.command:find("cd '/home/user'", 1, true) ~= nil)

-- Pi is still booting and the click is repeated. It reads as "nothing is running"
-- for as long as the boot takes, and a second Pi would share the session
-- directory, so the in-flight spawn has to block it.
onClick()
check("a second click while Pi is starting does not spawn again", 1, spawnCount())

-- The latch also lifts as soon as the session shows up in the status file,
-- without waiting the grace out.
show(WORKING)
update()
show(nil)
calls = {}
CONFIG.working_dir = "~/project"
onClick()
checkTrue("a ~/ working directory resolves too", callsOf("exec_cmd")[1].command:find("cd '/home/user/project'", 1, true) ~= nil)
CONFIG.working_dir = "~"

-- And a spawn that never publishes a session at all must not wedge the widget:
-- once the grace lapses the next click is obeyed again.
show(nil)
advance(60000)
calls = {}
onClick()
check("the spawn grace lapses", 1, spawnCount())

-- A live session: the click has to toggle, not spawn a second Pi.
show(WORKING)
update()
calls = {}
onClick()
check("a live session toggles the workspace", lastCall() and lastCall().kind, "toggle_special")
check("a live session never spawns", 0, spawnCount())

-- A status that cannot be read still means a session was there, so it toggles
-- instead of risking a duplicate.
calls = {}
show(MALFORMED)
onClick()
check("an unreadable status toggles instead of spawning", 0, spawnCount())

-- "special:pi" and "pi" name the same workspace; the plugin must not build
-- "special:special:pi".
CONFIG.workspace = "special:hi"
calls = {}
show(nil)
advance(60000)
onClick()
check("a special: prefix in the setting is not doubled", callsOf("exec_cmd")[1].rules.workspace, "special:hi")
check("the reveal is not doubled either", lastCall().name, "hi")
CONFIG.workspace = "pi"

-- Configured values reach the compositor unchanged, however they are spelled: a
-- quote or a backslash in a spawn command or a workspace name must not close the
-- Lua expression and must not be mangled on the way through it.
CONFIG.workspace = 'p"i\\x'
CONFIG.spawn = 'pi "quoted" \\ backslash'
calls = {}
show(nil)
advance(60000)
onClick()
check("a spawn command with a quote and a backslash arrives unchanged", callsOf("exec_cmd")[1].command,
  "cd '/home/user' && PI_HYPR_MONITOR=1 foot pi \"quoted\" \\ backslash")
check("a workspace name with a quote and a backslash arrives unchanged", lastCall().name, 'p"i\\x')
check("and is still targeted as a special workspace", callsOf("exec_cmd")[1].rules.workspace, 'special:p"i\\x')
CONFIG.workspace = "pi"
CONFIG.spawn = "pi -c --session-dir ~/.local/state/pi-scratchpad/sessions"

-- ── A rejected dispatch ──────────────────────────────────────────────────────

-- A compositor that refuses the expression has to say why, and a refused launch
-- has to stay retryable instead of holding the spawn latch down.
show(nil)
advance(60000)
calls, notifications = {}, {}
dispatchReplies = { { exitCode = 7, stdout = "error: hl.dsp.exec_cmd: unknown effect 'float'\n" } }
onClick()
check("a rejected spawn is announced", 1, #notifications)
checkTrue("the diagnostic carries the compositor's error",
  notifications[1] and notifications[1].body:find("unknown effect 'float'", 1, true) ~= nil)
check("a rejected spawn does not reveal the workspace", 0, #callsOf("toggle_special"))
calls = {}
onClick()
check("a failed launch is retried on the next click", 1, spawnCount())

-- A launch Hyprland accepted but could not reveal is not a launch to retry: Pi is
-- already booting, so the latch stays down and the next click must not start a
-- second Pi. The queued "ok" is the accepted exec; the reveal then fails.
show(nil)
advance(60000)
calls, notifications = {}, {}
dispatchReplies = {
  { exitCode = 0, stdout = "ok\n" },
  { exitCode = 7, stdout = "error: Could not resolve special workspace\n" },
}
onClick()
check("a reveal Hyprland refused is announced", 1, #notifications)
calls = {}
onClick()
check("a launched Pi is not spawned twice when the reveal failed", 0, spawnCount())
advance(60000)
calls = {}
onClick()
check("the latch still lapses after a failed reveal", 1, spawnCount())

-- A rejected toggle is announced too, and does not stop the next click.
show(WORKING)
update()
calls, notifications = {}, {}
dispatchReplies = { { exitCode = 7, stdout = "error: Invalid special workspace\n" } }
onClick()
check("a rejected toggle is announced", 1, #notifications)
calls, notifications = {}, {}
onClick()
check("a rejected toggle is retried on the next click", 1, #callsOf("toggle_special"))

-- A hyprlang `.conf` compositor answers a Lua expression with "Invalid
-- dispatcher" and a zero exit status, so success has to be the "ok" reply and
-- not merely a zero status.
show(WORKING)
update()
calls, notifications = {}, {}
dispatchReplies = { { exitCode = 0, stdout = "Invalid dispatcher\n" } }
onClick()
check("a reply that is not ok is a failed dispatch", 1, #notifications)
checkTrue("the diagnostic carries the legacy reply", notifications[1].body:find("Invalid dispatcher", 1, true) ~= nil)
check("the refused reply is not recorded as a dispatch", 0, #callsOf("toggle_special"))
dispatchReplies = {}

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

-- ── Two placements ───────────────────────────────────────────────────────────

-- A widget placed on two bars runs as two entries in isolated VMs, so the
-- per-plugin state channel is all they share. It has to be enough for one
-- notification per waiting turn and one Pi per spawn.
visible = false
show(IDLE)
firstUpdate()
secondUpdate()
notifyCount()

show(WAITING)
firstUpdate()
check("the first placement announces the waiting turn", 1, notifyCount())
secondUpdate()
check("the second placement does not announce it again", 0, notifyCount())

show(nil)
advance(60000)
calls = {}
firstOnClick()
secondOnClick()
check("two placements do not start two Pis", 1, spawnCount())
-- The check has to fail its process, not only print: a caller and any automation
-- reading the exit status must see a failed run.
if failures > 0 then
  error(("scratchpad harness FAILED: %d"):format(failures), 0)
end
print(("scratchpad harness ok (%d ticks)"):format(updates))
