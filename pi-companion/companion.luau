-- Bar widget for one long-lived Pi TUI parked in a Hyprland special workspace.
--
-- Pi's own TUI is the interface; this widget only reports what the companion
-- extension publishes and drives the compositor. On every tick it reads the
-- status file the extension writes atomically and deletes on session_shutdown.
-- It never guesses from process names, window titles, file age or Pi's session
-- transcripts - the extension owns the session, this widget owns nothing but
-- the compositor verbs.
--
-- plugin.toml loads this file on the host; selftest.sh loads it against stubs.

local icon = require("./icon.luau")

local STATUS_DIR = "pi-hypr-agent-monitor"
local STATUS_FILE = "status.json"
-- exec rules create dynamic tags; Hyprland's Lua query matches their '*' suffix exactly.
local WINDOW_TAG = "noctalia-pi-companion*"

local DEFAULT_WORKSPACE = "pi"
local DEFAULT_TERMINAL = "foot"
local DEFAULT_SPAWN = "pi -c --session-dir ~/.local/state/pi-companion/sessions"
local DEFAULT_WORKING_DIR = "~"
local DEFAULT_GEOMETRY = "900x600"

-- A spawn is dispatched seconds before the extension can publish a status file:
-- the terminal has to start and Pi has to boot. Clicks landing in that window are
-- ignored rather than obeyed, because a second Pi would share the one session
-- directory and the status file could not tell the two apart.
local SPAWN_GRACE_MS = 20000

-- Keys this plugin publishes on the runtime's per-plugin state channel. Entries
-- are isolated VMs, so that channel is the only thing two placements of this
-- widget share - without it each bar announces the same waiting turn.
local SPAWNED_UNTIL = "spawned_until"
local LAST_STATE = "last_state"
local REVEAL_UNTIL = "reveal_until"
local REOPEN_UNTIL = "reopen_until"

local SEEN_WAIT = "seen_wait"
local ACKNOWLEDGED_WAIT = "acknowledged_wait"

local LOOK = {
  working = "Pi is working",
  waiting = "Pi is waiting for you",
  idle = "Pi is idle",
  unknown = "Pi status is unreadable",
  not_running = "Pi is idle",
}

local KNOWN_STATES = { working = true, waiting = true, idle = true }

-- ── Settings ──────────────────────────────────────────────────────────────────

local function text(key, fallback)
  local value = noctalia.getConfig(key)
  if type(value) ~= "string" then return fallback end
  value = noctalia.string.trim(value)
  if value == "" then return fallback end
  return value
end

local function workspace()
  -- Accept both "pi" and "special:pi": the setting names the workspace, and
  -- Hyprland spells the selector as "special:<name>". A bare "special:" leaves
  -- nothing behind, which is the same as having set no name at all.
  local name = text("workspace", DEFAULT_WORKSPACE):gsub("^special:", "")
  if name == "" then return DEFAULT_WORKSPACE end
  return name
end

local function notificationsEnabled()
  return noctalia.getConfig("notify") ~= false
end

local function geometry()
  local width, height = text("geometry", DEFAULT_GEOMETRY):match("^(%d+)[%sxX]+(%d+)$")
  if width then return width, height end
  return DEFAULT_GEOMETRY:match("^(%d+)[xX](%d+)$")
end

-- ── The status file ───────────────────────────────────────────────────────────

-- The extension keeps the file under XDG_RUNTIME_DIR, or under XDG_STATE_HOME
-- when that is unset, which itself defaults to ~/.local/state. The search order
-- here is the one the extension documents, so the two agree on where the file is.
local function statusPath()
  local dir = noctalia.getenv("XDG_RUNTIME_DIR")
  if type(dir) ~= "string" or dir == "" then dir = noctalia.getenv("XDG_STATE_HOME") end
  if type(dir) ~= "string" or dir == "" then
    local home = noctalia.getenv("HOME")
    if type(home) ~= "string" or home == "" then return nil end
    dir = home .. "/.local/state"
  end
  return dir .. "/" .. STATUS_DIR .. "/" .. STATUS_FILE
end

-- The order here is the contract. A missing file means Pi is gone, and a file
-- whose recorded pid has no live process means Pi died without shutting down.
-- Everything the widget cannot read - a torn document, no usable pid, a state
-- that is not one of the three - is "unknown", never silently "not running",
-- so a click toggles instead of starting a second Pi over a live one.
local function readState()
  local path = statusPath()
  if path == nil or not noctalia.fileExists(path) then return "not_running" end

  local raw = noctalia.readFile(path)
  local document = type(raw) == "string" and noctalia.json.decode(raw) or nil
  if type(document) ~= "table" then return "unknown" end

  local pid = document.pid
  if type(pid) ~= "number" or pid ~= math.floor(pid) or pid < 1 then return "unknown" end
  if not noctalia.fileExists("/proc/" .. tostring(pid)) then return "not_running" end

  if KNOWN_STATES[document.state] then
    -- A newly published wait must rearm attention even if a short turn fell
    -- between polls. Include the session and pid so a restart cannot reuse an ack.
    local token = tostring(pid) .. ":" .. tostring(document.session_id) .. ":" .. tostring(document.updated_at)
    return document.state, token
  end
  return "unknown"
end

-- ── The compositor ────────────────────────────────────────────────────────────

local function shellQuote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

-- Every value inside a dispatcher expression comes from a setting, so a quote or
-- a backslash in a spawn command, a path or a workspace name would otherwise end
-- the expression there and run whatever follows it.
local function luaQuote(value)
  return '"' .. value:gsub("[\\\"]", "\\%0"):gsub("\n", "\\n"):gsub("\r", "\\r") .. '"'
end

-- A folder setting can be "~", "~/project" or an absolute path. Hyprland runs the
-- spawn line through /bin/sh, but the shell only expands a tilde it can see and
-- this plugin single-quotes the path, so the expansion has to happen here or the
-- shipped "~" default would leave `cd '~'` failing and take the terminal with it.
-- noctalia.expandPath is not used because its handling of a bare "~" is not
-- documented, and this is the one place where getting it wrong is silent.
local function absolutePath(path)
  local home = noctalia.getenv("HOME")
  if type(home) == "string" and home ~= "" then
    if path == "~" then return home end
    if path:sub(1, 2) == "~/" then return home .. path:sub(2) end
  end
  return path
end

-- Every compositor call in this plugin goes through this one function. Nothing
-- else in the file names a compositor, so a niri port rewrites the bodies here
-- and leaves the widget above untouched.
--
-- The interface it speaks is Hyprland 0.55's Lua dispatcher API, because a
-- `hyprland.lua` configuration (the default since 0.55) evaluates every
-- `hyprctl dispatch` argument as the expression in `hl.dispatch(<argument>)`:
-- `hl.dsp.exec_cmd(command, rules)` for the launch and
-- `hl.dsp.workspace.toggle_special(name)` for the workspace. A hyprlang `.conf`
-- configuration reads the same argument as a legacy "dispatcher argument" pair
-- and rejects it; that rejection is reported, not swallowed.
--
--   "visible" -> onDone(boolean): is the special workspace showing right now?
--   "mapped"  -> onDone(boolean): has a companion window mapped?
--   "toggle"  -> show the special workspace if hidden, hide it if shown
--   "show"    -> reveal the workspace without ever hiding it
--   "spawn"   -> launch Pi; reveal it once its window maps

-- hyprctl answers a Lua dispatch with "ok" when it ran. Anything else - a Lua
-- error, a rejected argument, the legacy config's "Invalid dispatcher" reply -
-- is a failed dispatch, and its text is all the diagnostic there is.
local function dispatchSucceeded(result)
  if type(result) ~= "table" or result.exitCode ~= 0 then return false end
  local stdout = type(result.stdout) == "string" and result.stdout or ""
  return noctalia.string.trim(stdout) == "ok"
end

local function dispatchError(result)
  if type(result) ~= "table" then return "hyprctl did not run" end
  local stdout = type(result.stdout) == "string" and result.stdout or ""
  local stderr = type(result.stderr) == "string" and result.stderr or ""
  local detail = noctalia.string.trim(stdout .. " " .. stderr):gsub("^error:%s*", "")
  if detail == "" then detail = "hyprctl exited with status " .. tostring(result.exitCode) end
  return detail
end

local function dispatch(expression, onDone)
  local done = onDone or function() end
  local accepted = noctalia.runAsync({ "hyprctl", "dispatch", expression }, function(result)
    if dispatchSucceeded(result) then return done(true) end
    -- The click has to say what Hyprland said, or a misconfigured compositor
    -- looks exactly like a widget that does nothing.
    noctalia.notify("Pi Companion dispatch failed", dispatchError(result))
    done(false)
  end)
  -- The runtime can decline to start the process at all, and then no result ever
  -- arrives. A click reported as obeyed would hold the spawn latch down with
  -- nothing running, so the local refusal is reported and cleared here.
  if accepted == false then
    noctalia.notify("Pi Companion dispatch failed", "hyprctl could not be started, so nothing was sent to Hyprland.")
    done(false)
  end
  return accepted
end

-- Run placement in the same compositor dispatch as reveal: no stale monitor or
-- window snapshot can move another window after focus changes.
local function revealExpression(action)
  local horizontal = ({ left = 0, center = 0.5, right = 1 })[text("horizontal_alignment", "center")] or 0.5
  local vertical = ({ top = 0, center = 0.5, bottom = 1 })[text("vertical_alignment", "center")] or 0.5
  local width, height = geometry()
  return ([=[function()
    local windows = hl.get_windows({ workspace = %s, tag = %s, mapped = true })
    if #windows ~= 1 then error("Expected one tagged companion window. Close an older Pi terminal and reopen it with Pi Companion.") end
    local window = windows[1]
    local result = hl.dispatch(%s)
    if not result.ok then return result end
    local monitor = hl.get_active_monitor()
    local special = monitor and monitor.active_special_workspace
    if not special or special.name ~= %s then return result end
    if not window.floating then error("The companion window must be floating for placement") end
    local mw, mh = monitor.width, monitor.height
    if monitor.transform %% 2 == 1 then mw, mh = mh, mw end
    -- Hyprland 0.55 does not expose reserved edges through its Lua API.
    local edges = monitor.reserved or { left = 0, right = 0, top = 0, bottom = 0 }
    local width = math.max(1, math.floor(mw / monitor.scale - edges.left - edges.right))
    local height = math.max(1, math.floor(mh / monitor.scale - edges.top - edges.bottom))
    result = hl.dispatch(hl.dsp.window.resize({ window = window,
      x = math.min(%s, width), y = math.min(%s, height) }))
    if not result.ok then return result end
    result = hl.dispatch(hl.dsp.window.move({ window = window,
      x = monitor.x + edges.left + math.floor(math.max(0, width - window.size.x) * %s),
      y = monitor.y + edges.top + math.floor(math.max(0, height - window.size.y) * %s) }))
    if not result.ok then return result end
    return hl.dispatch(hl.dsp.focus({ window = window }))
  end]=]):format(luaQuote("special:" .. workspace()), luaQuote(WINDOW_TAG), action,
    luaQuote("special:" .. workspace()), width, height, horizontal, vertical)
end

local function compositor(op, onDone)
  local done = onDone or function() end

  if op == "visible" then
    local accepted = noctalia.runAsync({ "hyprctl", "-j", "monitors" }, function(result)
      local visible, valid = false, false
      if type(result) == "table" and result.exitCode == 0 then
        local monitors = noctalia.json.decode(result.stdout)
        valid = type(monitors) == "table" and #monitors > 0
        for _, monitor in ipairs(type(monitors) == "table" and monitors or {}) do
          local special = type(monitor) == "table" and monitor.specialWorkspace or nil
          if type(special) ~= "table" or type(special.name) ~= "string" then
            valid = false
          elseif special.name == workspace() or special.name == "special:" .. workspace() then
            visible = true
          end
        end
      end
      done(visible, valid)
    end)
    if accepted == false then done(false, false) end
    return accepted
  end

  if op == "mapped" then
    local accepted = noctalia.runAsync({ "hyprctl", "-j", "clients" }, function(result)
      local clients = type(result) == "table" and result.exitCode == 0 and noctalia.json.decode(result.stdout) or nil
      local valid = type(clients) == "table" and (#clients > 0 or next(clients) == nil)
      local matches = 0
      for _, client in ipairs(type(clients) == "table" and clients or {}) do
        if type(client) ~= "table" or type(client.mapped) ~= "boolean" or
          type(client.workspace) ~= "table" or type(client.workspace.name) ~= "string" then
          valid = false
        elseif client.mapped and client.workspace.name == "special:" .. workspace() then
          if type(client.tags) ~= "table" then
            valid = false
          elseif table.find(client.tags, WINDOW_TAG) then
            matches = matches + 1
          end
        end
      end
      done(matches == 1, valid and matches <= 1)
    end)
    if accepted == false then done(false, false) end
    return accepted
  end

  if op == "show" then
    return dispatch(revealExpression("hl.dsp.focus({ window = window })"), done)
  end

  -- toggle_special takes the bare name: it prefixes "special:" itself.
  if op == "toggle" then
    return dispatch(revealExpression("hl.dsp.workspace.toggle_special(" .. luaQuote(workspace()) .. ")"), done)
  end

  -- "spawn". exec_cmd runs the command through /bin/sh and its rule table is the
  -- Lua form of the old bracket block: float, centre, the configured size, and
  -- the special workspace. PI_HYPR_MONITOR=1 is what makes the companion
  -- extension publish the status file, and it reaches Pi through the terminal.
  local width, height = geometry()
  local command = "cd " .. shellQuote(absolutePath(text("working_dir", DEFAULT_WORKING_DIR))) ..
    " && PI_HYPR_MONITOR=1 " .. text("terminal", DEFAULT_TERMINAL) .. " " .. text("spawn", DEFAULT_SPAWN)
  local expression = "hl.dsp.exec_cmd(" .. luaQuote(command) .. ", { tag = " .. luaQuote("+" .. WINDOW_TAG) ..
    ", float = true, center = true, size = { " ..
    width .. ", " .. height .. " }, workspace = " .. luaQuote("special:" .. workspace()) .. " })"
  return dispatch(expression, done)
end

-- ── The widget ────────────────────────────────────────────────────────────────

local function paint(state, token)
  local acknowledged = state == "waiting" and noctalia.state.get(ACKNOWLEDGED_WAIT) == token
  local display = acknowledged and "idle" or state
  barWidget.render(icon.render(display, noctalia.nowMs()))
  barWidget.setTooltip(LOOK[display])
  local pending = math.max(noctalia.state.get(REVEAL_UNTIL) or 0, noctalia.state.get(REOPEN_UNTIL) or 0)
  local interval = pending > noctalia.nowMs() and 250 or 1000
  noctalia.setUpdateInterval((display == "working" or display == "waiting") and icon.interval or interval)
end

local nextVisibilityCheck = 0
local function observeWaiting(state, token)
  if state ~= "waiting" then
    noctalia.state.set(SEEN_WAIT, "")
    noctalia.state.set(ACKNOWLEDGED_WAIT, "")
    nextVisibilityCheck = 0
    return
  end
  local now = noctalia.nowMs()
  if now < nextVisibilityCheck then return end
  nextVisibilityCheck = now + 1000
  compositor("visible", function(visible, valid)
    local current, currentToken = readState()
    if not valid or current ~= "waiting" or currentToken ~= token then return end
    if visible then
      noctalia.state.set(SEEN_WAIT, token)
    elseif noctalia.state.get(SEEN_WAIT) == token then
      noctalia.state.set(ACKNOWLEDGED_WAIT, token)
    end
    paint(current, currentToken)
  end)
end

-- Waiting is the only state worth interrupting for, only on the way into it, and
-- only while the companion is hidden - Pi asking for attention on screen is
-- already the notification.
local function announce(previous, state)
  if state ~= "waiting" or previous == nil or previous == "waiting" then return end
  if not notificationsEnabled() then return end
  compositor("visible", function(visible)
    if visible then return end
    noctalia.notify("Pi is waiting", "Pi needs you.")
  end)
end

-- A Pi this widget has just started is not in the status file yet, so a click
-- cannot tell it apart from a Pi that is not running. The deadline covers the
-- terminal launch and the boot; it is published as well as kept locally, so the
-- two placements of a widget on two bars do not both start one.
local spawnAt = 0

local function spawnInFlight()
  local now = noctalia.nowMs()
  if now < spawnAt then return true end
  local published = noctalia.state.get(SPAWNED_UNTIL)
  local pending = math.max(noctalia.state.get(REVEAL_UNTIL) or 0, noctalia.state.get(REOPEN_UNTIL) or 0)
  return (type(published) == "number" and now < published) or now < pending
end

local function clearSpawnLatch()
  spawnAt = 0
  noctalia.state.set(SPAWNED_UNTIL, 0)
end

local tick
local function startSpawn()
  spawnAt = noctalia.nowMs() + SPAWN_GRACE_MS
  noctalia.state.set(SPAWNED_UNTIL, spawnAt)
  local deadline = spawnAt
  compositor("spawn", function(ok)
    if ok == false then
      clearSpawnLatch()
    else
      noctalia.state.set(REVEAL_UNTIL, deadline)
      tick()
    end
  end)
end

local revealBusy = 0
local function revealSpawn()
  local deadline = noctalia.state.get(REVEAL_UNTIL)
  if type(deadline) ~= "number" or deadline == 0 then return end
  if noctalia.nowMs() >= deadline then
    noctalia.state.set(REVEAL_UNTIL, 0)
    noctalia.notify("Pi Companion did not appear", "No mapped companion window was found within 20 seconds. Check the terminal and spawn command.")
    return
  end
  if revealBusy == deadline then return end
  revealBusy = deadline
  compositor("mapped", function(mapped, valid)
    if revealBusy == deadline then revealBusy = 0 end
    if not valid or not mapped or noctalia.state.get(REVEAL_UNTIL) ~= deadline or noctalia.nowMs() >= deadline then return end
    -- Consume before dispatch so another placement cannot reveal it twice.
    noctalia.state.set(REVEAL_UNTIL, 0)
    -- Mapping can itself show the workspace. An idempotent focus cannot hide it
    -- again if that happens between our snapshot and the dispatcher running.
    compositor("show")
  end)
end

tick = function()
  local reopening = noctalia.state.get(REOPEN_UNTIL) or 0
  if reopening > 0 then
    if noctalia.nowMs() >= reopening then
      noctalia.state.set(REOPEN_UNTIL, 0)
      noctalia.notify("Pi Companion reopen timed out", "Pi is still running but no tagged companion window was found. If it was opened before this update, close its terminal and reopen it with Pi Companion. A second session was not started.")
    elseif readState() == "not_running" then
      noctalia.state.set(REOPEN_UNTIL, 0)
      startSpawn()
    end
  end
  revealSpawn()
  local state, token = readState()
  -- A session in the status file is the one a spawn was for, so the latch lifts
  -- as soon as Pi publishes anything at all, readable or not.
  if state ~= "not_running" then clearSpawnLatch() end
  observeWaiting(state, token)
  paint(state, token)

  -- Publish before announcing: the other placement has to see the transition as
  -- already announced when it ticks.
  local previous = noctalia.state.get(LAST_STATE)
  if previous ~= state then noctalia.state.set(LAST_STATE, state) end
  announce(previous, state)
  return state
end

function update()
  tick()
end

function onClick()
  -- A click on a Pi this widget just started would be read as "nothing is
  -- running" and start a second one, so it is ignored until the session shows up
  -- in the status file or the grace expires.
  if spawnInFlight() then return end

  -- Only a missing or dead process spawns. An unreadable file still means a
  -- session was there, so toggling is the safe verb for it.
  local state, token = readState()
  if state == "not_running" then return startSpawn() end
  if state == "unknown" then return compositor("toggle") end

  compositor("mapped", function(mapped, valid)
    if spawnInFlight() then return end
    if not valid then
      noctalia.notify("Pi Companion window query failed", "Could not read Hyprland clients or found multiple tagged companion windows. Nothing was launched or toggled.")
      return
    end
    if not mapped then
      -- Closing a terminal can unmap it before Pi finishes shutting down. Keep
      -- this click's intent, but never start another Pi over the live process.
      noctalia.state.set(REOPEN_UNTIL, noctalia.nowMs() + SPAWN_GRACE_MS)
      tick()
      return
    end
    if state ~= "waiting" then return compositor("toggle") end
    compositor("visible", function(visible, visibleValid)
      compositor("toggle", function(ok)
        local current, currentToken = readState()
        if ok and visibleValid and visible and current == "waiting" and currentToken == token then
          noctalia.state.set(ACKNOWLEDGED_WAIT, token)
          paint(current, token)
        end
      end)
    end)
  end)
end

function onIpc(event)
  if event == "toggle" then onClick() end
end

update()
