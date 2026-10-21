-- Controller entry: the single place an action is accepted. This slice owns the
-- pad configuration boundary: pads.json is read as data, checked, and turned
-- into the pad records every caller renders. No action is implemented yet, so
-- every declared action is refused here instead of half-working: the name
-- exists, no compositor operation is behind it yet. Nothing in this file
-- launches a process or touches a window, so an invalid configuration costs the
-- user one status error and nothing else.

local shared = require("./shared.luau")

local CONFIG_NAME = "pads.json"
local EXPECTED_VERSION = 1

local status = {
  revision = 0,
  phase = "ready",
  selectedPadId = nil,
  -- Defaults until the durable preference slice restores the user's own.
  side = "left",
  widthMode = "narrow",
  busy = false,
  error = nil,
  -- Filled by the configuration read below; the field is already part of the
  -- snapshot every caller renders.
  pads = {},
}

-- state.set serializes the value, so callers receive a copy they cannot use to
-- reach this table.
local function publish()
  status.revision = status.revision + 1
  noctalia.state.set(shared.STATUS_KEY, status)
end

local function refuse(message)
  status.error = message
  publish()
end

-- ── Pad configuration ───────────────────────────────────────────────────────
-- pads.json is trusted user configuration but never executable code: it is read
-- as data and checked here. These rules are the boundary later slices rely on,
-- so a value that reaches a compositor selector or a derived workspace name has
-- already been proved to contain nothing but the characters it is built from.

-- An ID names a pad in requests and derives its workspace, so only characters
-- that cannot break out of the derived name are accepted.
local function validId(id)
  return type(id) == "string" and id:match("^[a-z0-9_-]+$") ~= nil
end

-- A class is matched exactly against a Hyprland client class and later becomes a
-- selector, so only the characters a Wayland app_id uses are accepted.
local function validClass(class)
  return type(class) == "string" and class:match("^[%w%._@+%-]+$") ~= nil
end

local function nonEmpty(value)
  return type(value) == "string" and noctalia.string.trim(value) ~= ""
end

local function padLabel(entry, index)
  if type(entry) == "table" and nonEmpty(entry.id) then
    return "pad '" .. entry.id .. "'"
  end
  return ("pad %d"):format(index)
end

-- One pad definition, or the first rule it breaks. The record it returns is what
-- both UI entries already render, plus the exact class and argv the compositor
-- slices consume.
local function readPad(entry, index)
  if type(entry) ~= "table" then
    return nil, ("pad %d is not an object"):format(index)
  end
  local label = padLabel(entry, index)
  if not validId(entry.id) then
    return nil, label .. ": id must be a non-empty string of lowercase ASCII letters, digits, hyphens and underscores"
  end
  if not nonEmpty(entry.name) then
    return nil, label .. ": name must be a non-empty string"
  end
  if not validClass(entry.class) then
    return nil, label .. ": class must be a non-empty Wayland class of letters, digits, '.', '_', '@', '+' and '-'"
  end
  if entry.icon ~= nil and not nonEmpty(entry.icon) then
    return nil, label .. ": icon must be a non-empty string when it is set"
  end
  local command = entry.command
  -- shortcut: a JSON null inside an array is dropped by the host decoder before
  -- this check runs, so a null argument leaves the remaining argv intact but
  -- undetectable; revisit if the host ever preserves nulls.
  if type(command) ~= "table" or #command == 0 then
    return nil, label .. ": command must be a non-empty array"
  end
  for position, argument in ipairs(command) do
    if type(argument) ~= "string" then
      return nil, ("%s: command[%d] must be a string"):format(label, position)
    end
  end
  if not nonEmpty(command[1]) then
    return nil, label .. ": command[1] must name the executable"
  end
  if not noctalia.commandExists(command[1]) then
    return nil, ("%s: executable '%s' was not found"):format(label, command[1])
  end
  return {
    id = entry.id,
    name = entry.name,
    icon = entry.icon,
    class = entry.class,
    -- Kept as the argv array it was read as: no value is ever joined into a
    -- shell command.
    command = command,
    -- Derived from the checked ID, never configured, so two pads cannot be
    -- pointed at one managed workspace.
    workspace = shared.workspaceName(entry.id),
    -- Compositor state arrives with the reconciliation slice; a pad nobody has
    -- observed yet is truthfully stopped and hidden.
    running = false,
    visible = false,
    output = nil,
  }
end

-- The whole file, or one message naming what the user has to fix. Every refusal
-- is phrased for the person editing the file, because it is the only feedback
-- they get.
local function loadPads()
  local directory, directoryError = noctalia.pluginDataDir()
  if not directory then
    return nil, "no plugin data directory: " .. tostring(directoryError)
  end
  local path = directory .. "/" .. CONFIG_NAME
  local raw, readError = noctalia.readFile(path)
  if type(raw) ~= "string" then
    return nil,
      ("%s is missing or unreadable (%s); copy pads.example.json from the plugin directory and edit it"):format(
        path,
        tostring(readError)
      )
  end
  local document, decodeError = noctalia.json.decode(raw)
  if type(document) ~= "table" then
    return nil, ("%s is not valid JSON: %s"):format(path, tostring(decodeError))
  end
  if document.version ~= EXPECTED_VERSION then
    return nil, ("%s: version must be %d, got %s"):format(path, EXPECTED_VERSION, tostring(document.version))
  end
  local entries = document.pads
  -- A JSON object decodes to a table too, so an object keyed by pad id is caught
  -- here instead of silently contributing no pads. An empty object decodes to the
  -- same table as an empty array, so `{}` reads as "no pads configured" and there
  -- is nothing further to distinguish.
  if type(entries) ~= "table" or (next(entries) ~= nil and #entries == 0) then
    return nil, path .. ": pads must be an array"
  end
  local pads, ids, classes = {}, {}, {}
  for index, entry in ipairs(entries) do
    local id = type(entry) == "table" and entry.id or nil
    local class = type(entry) == "table" and entry.class or nil
    -- Duplicates are reported first so the message names the clash the user has
    -- to resolve rather than a secondary detail of the colliding pad.
    if type(id) == "string" and ids[id] then
      return nil, ("%s: duplicate pad id '%s'"):format(path, id)
    end
    if type(class) == "string" and classes[class] then
      return nil, ("%s: duplicate pad class '%s' in pad '%s'"):format(path, class, tostring(id))
    end
    local pad, problem = readPad(entry, index)
    if not pad then
      return nil, path .. ": " .. problem
    end
    ids[pad.id] = true
    classes[pad.class] = true
    table.insert(pads, pad)
  end
  return pads
end

-- The one action path: the request watcher below and onIpc both land here, so a
-- UI click and a `noctalia msg plugin` call cannot take different routes.
local function dispatch(action, padId)
  if not shared.isAction(action) then
    refuse("unknown action: " .. tostring(action))
    return
  end
  -- Every declared action belongs to a later slice. Naming the action is the
  -- truthful answer for this build: it is in the contract, it is not available.
  refuse(action .. " is not available yet")
end

-- The accepted-request sequence. The controller is the only writer of this
-- number, so allocation and publication happen in one operation and the sequence
-- cannot step back when two entries publish at once.
local lastNonce = 0

noctalia.state.watch(shared.REQUEST_KEY, function(request)
  if type(request) ~= "table" then
    refuse("malformed request")
    return
  end
  if type(request.action) ~= "string" then
    refuse("malformed request: action must be a string")
    return
  end
  if request.padId ~= nil and type(request.padId) ~= "string" then
    refuse("malformed request: padId must be a string")
    return
  end
  -- A request that already carries a nonce is this controller's own accepted
  -- request, not a new intent. The checks above run first, so a malformed value
  -- is still reported rather than excused as an echo.
  if type(request.nonce) == "number" then
    return
  end
  lastNonce = lastNonce + 1
  noctalia.state.set(shared.REQUEST_KEY, shared.stamp(request, lastNonce))
  dispatch(request.action, request.padId)
end)

function onIpc(event, payload)
  local padId = nil
  if type(payload) == "string" then
    local trimmed = noctalia.string.trim(payload)
    if trimmed ~= "" then
      padId = trimmed
    end
  end
  dispatch(event, padId)
end

-- Startup: one read of the user's definitions. A failure publishes no pads and
-- the reason in the status error both UI entries already render, so the user is
-- told what to fix while every caller stays usable; nothing here launches an
-- application or moves a window.
local configured, configError = loadPads()
if configured then
  status.pads = configured
else
  status.error = configError
end

publish()
