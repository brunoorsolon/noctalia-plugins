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

local STATUS_DIR = "pi-hypr-agent-monitor"
local STATUS_FILE = "status.json"

local DEFAULT_WORKSPACE = "pi"
local DEFAULT_TERMINAL = "foot"
local DEFAULT_SPAWN = "pi -c --session-dir ~/.local/state/pi-scratchpad/sessions"
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

-- The launcher identity is the Pi glyph in every state, so the widget reads as
-- "bring Pi here" and never as a power button. The badge is what changes, so a
-- screenshot alone tells the states apart without relying on color, and a "+"
-- badge on a stopped Pi also says the click starts it.
--
-- Both glyphs take on_surface, the palette's role for text and icons on a bar:
-- it is the only role a palette guarantees to contrast with the bar. "outline"
-- is the border role and the accent roles are tuned for fills, so on some
-- built-in palettes they fall to 1.3:1 and 2.2:1 against the bar, which is the
-- invisible icon this widget had. A role token is also what makes the icon
-- follow the theme: the host resolves it against the active palette and
-- repaints when that palette changes, where a hex value would freeze it.
local IDENTITY = { glyph = "math-pi", color = "on_surface" }

-- Every state the widget can report, and the badge that tells it apart. Glyph
-- names are Tabler names.
local LOOK = {
  working = { badge = "loader", label = "Pi is working - click to show or hide it" },
  waiting = { badge = "bell", label = "Pi is waiting for you - click to show or hide it" },
  idle = { label = "Pi is idle - click to show or hide it" },
  unknown = { badge = "alert-triangle", label = "Pi status is unreadable - click to show or hide it" },
  not_running = { badge = "plus", label = "Pi is not running - click to start it" },
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

  if KNOWN_STATES[document.state] then return document.state end
  return "unknown"
end

-- ── The compositor ────────────────────────────────────────────────────────────

local function shellQuote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
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
--   "visible" -> onDone(boolean): is the special workspace showing right now?
--   "toggle"  -> show the special workspace if hidden, hide it if shown
--   "spawn"   -> open Pi in the special workspace, then show it
local function compositor(op, onDone)
  local done = onDone or function() end

  if op == "visible" then
    return noctalia.runAsync({ "hyprctl", "-j", "monitors" }, function(result)
      local visible = false
      if type(result) == "table" and result.exitCode == 0 then
        local monitors = noctalia.json.decode(result.stdout)
        for _, monitor in ipairs(type(monitors) == "table" and monitors or {}) do
          local special = type(monitor) == "table" and monitor.specialWorkspace or nil
          if type(special) == "table" and special.name ~= "" and
            (special.name == workspace() or special.name == "special:" .. workspace()) then
            visible = true
          end
        end
      end
      done(visible)
    end)
  end

  if op == "toggle" then
    return noctalia.runAsync({ "hyprctl", "dispatch", "togglespecialworkspace", workspace() }, done)
  end

  -- "spawn". Hyprland runs an exec payload through /bin/sh, and the leading
  -- bracket block is its exec-rule syntax: float, centre, the configured size,
  -- and the special workspace. PI_HYPR_MONITOR=1 is what makes the companion
  -- extension publish the status file, and it reaches Pi through the terminal.
  local width, height = geometry()
  local rules = "[float;center;size " .. width .. " " .. height ..
    ";workspace special:" .. workspace() .. "]"
  local command = rules .. " cd " .. shellQuote(absolutePath(text("working_dir", DEFAULT_WORKING_DIR))) ..
    " && PI_HYPR_MONITOR=1 " .. text("terminal", DEFAULT_TERMINAL) .. " " .. text("spawn", DEFAULT_SPAWN)
  return noctalia.runAsync({ "hyprctl", "dispatch", "exec", command }, function()
    -- An exec'd window lands in the special workspace but does not reveal it.
    compositor("visible", function(visible)
      if visible then done() else compositor("toggle", done) end
    end)
  end)
end

-- ── The widget ────────────────────────────────────────────────────────────────

local function paint(state)
  local look = LOOK[state]
  local glyphs = { ui.glyph({ name = IDENTITY.glyph, size = 14, color = IDENTITY.color }) }
  if look.badge then glyphs[#glyphs + 1] = ui.glyph({ name = look.badge, size = 12, color = IDENTITY.color }) end
  -- The capsule clips to bar thickness, so the pair stacks on a side bar.
  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = 2, align = "center" }, glyphs))
  barWidget.setTooltip(look.label)
end

-- Waiting is the only state worth interrupting for, only on the way into it, and
-- only while the scratchpad is hidden - Pi asking for attention on screen is
-- already the notification.
local function announce(previous, state)
  if state ~= "waiting" or previous == nil or previous == "waiting" then return end
  if not notificationsEnabled() then return end
  compositor("visible", function(visible)
    if visible then return end
    noctalia.notify("Pi is waiting", "Pi needs you. Click the Pi widget to bring the scratchpad up.")
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
  return type(published) == "number" and now < published
end

local function clearSpawnLatch()
  spawnAt = 0
  noctalia.state.set(SPAWNED_UNTIL, 0)
end

local function tick()
  local state = readState()
  -- A session in the status file is the one a spawn was for, so the latch lifts
  -- as soon as Pi publishes anything at all, readable or not.
  if state ~= "not_running" then clearSpawnLatch() end
  paint(state)

  -- Publish before announcing: the other placement has to see the transition as
  -- already announced when it ticks.
  local previous = noctalia.state.get(LAST_STATE)
  if previous ~= state then noctalia.state.set(LAST_STATE, state) end
  announce(previous, state)
  return state
end

function update()
  noctalia.setUpdateInterval(1000)
  tick()
end

function onClick()
  -- A click on a Pi this widget just started would be read as "nothing is
  -- running" and start a second one, so it is ignored until the session shows up
  -- in the status file or the grace expires.
  if spawnInFlight() then return end

  -- Only a missing or dead process spawns. An unreadable file still means a
  -- session was there, so toggling is the safe verb for it.
  if readState() == "not_running" then
    spawnAt = noctalia.nowMs() + SPAWN_GRACE_MS
    noctalia.state.set(SPAWNED_UNTIL, spawnAt)
    compositor("spawn")
  else
    compositor("toggle")
  end
end

update()
