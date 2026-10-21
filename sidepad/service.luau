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

-- The host decoder preallocates the JSON array and writes every original index,
-- so a JSON null leaves a hole while the later indices stay in place. ipairs
-- stops at the first hole and the length operator is not defined for a sparse
-- table, so a list is proved dense before anything iterates it: a hidden pad or
-- a hidden command argument would otherwise be accepted without an error.
local function denseLength(list)
  if type(list) ~= "table" then
    return nil, "must be an array"
  end
  local count, highest = 0, 0
  for key in pairs(list) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return nil, "must be an array"
    end
    count = count + 1
    if key > highest then
      highest = key
    end
  end
  if count ~= highest then
    for position = 1, highest do
      if list[position] == nil then
        return nil, ("has no value at position %d; a JSON null is not allowed here"):format(position)
      end
    end
  end
  return highest
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
  local argumentCount, commandProblem = denseLength(command)
  if not argumentCount then
    return nil, label .. ": command " .. commandProblem
  end
  if argumentCount == 0 then
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
  -- A JSON object decodes to a table too, so an object keyed by pad id is refused
  -- here instead of silently contributing no pads. An empty object decodes to the
  -- same table as an empty array, so `{}` reads as "no pads configured" and there
  -- is nothing further to distinguish.
  local entries, entriesProblem = denseLength(document.pads)
  if not entries then
    return nil, path .. ": pads " .. entriesProblem
  end
  local pads, ids, classes = {}, {}, {}
  for index, entry in ipairs(document.pads) do
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

-- Parse one compositor JSON array without trusting its contents. Invalid
-- snapshots leave the last good pad state intact and surface one recoverable
-- error rather than publishing guessed state.
local function decodeArray(raw, command, validateItem)
  if type(raw) ~= "string" then
    return nil, command .. " returned no output"
  end
  if noctalia.string.trim(raw):sub(1, 1) ~= "[" then
    return nil, command .. " returned an invalid snapshot"
  end
  local ok, value = pcall(noctalia.json.decode, raw)
  if not ok or type(value) ~= "table" then
    return nil, command .. " returned invalid JSON"
  end
  local length = denseLength(value)
  if not length then
    return nil, command .. " returned an invalid snapshot"
  end
  for index = 1, length do
    if not validateItem(value[index]) then
      return nil, command .. " returned an invalid snapshot"
    end
  end
  return value
end

local function isClient(client)
  return type(client) == "table"
    and type(client.class) == "string"
    and type(client.address) == "string"
    and type(client.monitor) == "string"
    and type(client.workspace) == "table"
    and type(client.workspace.name) == "string"
end

local function isMonitor(monitor)
  return type(monitor) == "table"
    and type(monitor.name) == "string"
    and type(monitor.specialWorkspace) == "table"
    and type(monitor.specialWorkspace.name) == "string"
end

local hasSnapshot = false
local refreshing = false
local refreshQueued = false
local configurationError = nil
local refresh

local function workspaceKey(name)
  return name:gsub("^special:", "")
end

local function applySnapshot(clients, monitors)
  local activeWorkspaces = {}
  for _, monitor in ipairs(monitors) do
    local name = monitor.specialWorkspace.name
    if name ~= "" then
      activeWorkspaces[workspaceKey(name)] = monitor.name
    end
  end

  local duplicates = {}
  for _, pad in ipairs(status.pads) do
    local matches = {}
    for _, client in ipairs(clients) do
      if client.class == pad.class then
        table.insert(matches, client)
      end
    end
    if #matches == 0 then
      pad.running, pad.visible, pad.output, pad.address = false, false, nil, nil
    elseif #matches > 1 then
      pad.running, pad.visible, pad.output, pad.address = true, false, nil, nil
      table.insert(duplicates, ("duplicate windows for pad '%s' (%s)"):format(pad.id, pad.class))
    else
      local client = matches[1]
      local output = activeWorkspaces[workspaceKey(client.workspace.name)]
      pad.running = true
      pad.visible = output ~= nil
      pad.output = output or client.monitor
      pad.address = client.address
    end
  end
  hasSnapshot = true
  status.error = #duplicates > 0 and table.concat(duplicates, "; ") or nil
  status.phase = status.error and "error" or "ready"
  status.busy = false
end

local function commandFailure(command, result)
  if type(result) ~= "table" then
    return command .. " could not be started"
  end
  if result.exitCode ~= 0 then
    return ("%s failed (exit %s)"):format(command, tostring(result.exitCode))
  end
  return nil
end

local function completeRefresh(results)
  local failure = commandFailure("hyprctl -j clients", results.clients)
    or commandFailure("hyprctl -j monitors", results.monitors)
  if failure then
    status.error = failure
    status.phase = "error"
    status.busy = false
  else
    local clients, clientError = decodeArray(results.clients.stdout, "hyprctl -j clients", isClient)
    local monitors, monitorError = decodeArray(results.monitors.stdout, "hyprctl -j monitors", isMonitor)
    if not clients or not monitors then
      status.error = clientError or monitorError
      status.phase = "error"
      status.busy = false
    else
      applySnapshot(clients, monitors)
    end
  end
  refreshing = false
  publish()
  if refreshQueued then
    refreshQueued = false
    refresh()
  end
end

local function query(command, callback)
  local completed = false
  local function done(result)
    if completed then return end
    completed = true
    callback(result)
  end
  local accepted = noctalia.runAsync({ "hyprctl", "-j", command }, done)
  if accepted == false then
    done(nil)
  end
end

refresh = function()
  if configurationError then
    status.error = configurationError
    status.phase = "error"
    status.busy = false
    publish()
    return
  end
  if refreshing then
    refreshQueued = true
    return
  end
  if not noctalia.commandExists("hyprctl") then
    status.error = "hyprctl was not found in PATH"
    status.phase = "error"
    status.busy = false
    publish()
    return
  end
  refreshing = true
  status.phase = hasSnapshot and "refreshing" or "starting"
  status.busy = true
  publish()
  local results, remaining = {}, 2
  local function received(key, result)
    results[key] = result
    remaining = remaining - 1
    if remaining == 0 then
      completeRefresh(results)
    end
  end
  -- Both queries belong to this refresh cycle; neither is inferred from the
  -- other, and no compositor mutation is issued during reconciliation.
  query("clients", function(result) received("clients", result) end)
  query("monitors", function(result) received("monitors", result) end)
end

-- The one action path: the request watcher below and onIpc both land here.
local function dispatch(action, padId)
  if not shared.isAction(action) then
    refuse("unknown action: " .. tostring(action))
    return
  end
  if action == "refresh" then
    refresh()
    return
  end
  -- Other actions belong to later slices and must not imply work they cannot do.
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

-- Startup reads user definitions, then reconciles every configured class before
-- publishing the ready phase. A failure stays visible without launching or moving
-- any application.
local configured, configError = loadPads()
if configured then
  status.pads = configured
  refresh()
else
  configurationError = configError
  status.error = configError
  status.phase = "error"
  publish()
end
