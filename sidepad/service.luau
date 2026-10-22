-- The controller owns configuration, reconciliation and serialized actions.
-- Existing windows are shown, hidden, resized and closed here; launching and
-- other actions are refused until their own slices implement them.

local shared = require("./shared.luau")

local CONFIG_NAME = "pads.json"
local EXPECTED_VERSION = 1

local status = {
  revision = 0,
  phase = "ready",
  selectedPadId = nil,
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

local function refuse(message, explicitAction)
  status.error = message
  publish()
  if explicitAction then
    noctalia.notifyError(message)
  end
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

-- ── Durable preferences ─────────────────────────────────────────────────────

local function validSelection(id)
  for _, pad in ipairs(status.pads) do
    if pad.id == id then return true end
  end
  return id == nil and #status.pads == 0
end

local function validSide(side)
  return side == "left" or side == "right"
end

local function loadPreferences()
  status.selectedPadId = status.pads[1] and status.pads[1].id or nil
  status.side = "left"
  local directory = noctalia.pluginDataDir()
  if not directory then return end
  local raw = noctalia.readFile(directory .. "/preferences.json")
  if type(raw) ~= "string" then return end
  local document = noctalia.json.decode(raw)
  if type(document) ~= "table" or not validSelection(document.selectedPadId) or not validSide(document.side) then
    return
  end
  status.selectedPadId, status.side = document.selectedPadId, document.side
end

-- Controller-local seam for the later selection and placement actions. A failed
-- save returns an actionable error and leaves the last durable values intact;
-- the action caller reports that failure instead of claiming success.
local function setPreferences(selectedPadId, side)
  if not validSelection(selectedPadId) then
    return nil, "cannot save preferences: selected pad is not configured"
  end
  if not validSide(side) then
    return nil, "cannot save preferences: side must be left or right"
  end
  if status.selectedPadId == selectedPadId and status.side == side then return true end
  local directory, directoryError = noctalia.pluginDataDir()
  if not directory then
    return nil, "cannot save preferences: no plugin data directory: " .. tostring(directoryError)
  end
  local path = directory .. "/preferences.json"
  local document, encodeError = noctalia.json.encode({ selectedPadId = selectedPadId, side = side })
  if not document then
    return nil, "cannot encode preferences: " .. tostring(encodeError)
  end
  local written, writeError = noctalia.writeFile(path, document)
  if not written then
    return nil, "cannot save " .. path .. ": " .. tostring(writeError)
  end
  status.selectedPadId, status.side = selectedPadId, side
  publish()
  return true
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
    and type(client.monitor) == "number"
    and type(client.workspace) == "table"
    and type(client.workspace.id) == "number"
    and type(client.workspace.name) == "string"
end

local function isMonitor(monitor)
  return type(monitor) == "table"
    and type(monitor.id) == "number"
    and type(monitor.name) == "string"
    and type(monitor.specialWorkspace) == "table"
    and type(monitor.specialWorkspace.id) == "number"
    and type(monitor.specialWorkspace.name) == "string"
end

local hasSnapshot = false
local refreshing = false
local refreshQueued = false
local configurationError = nil
local streamStarted = false
local streamConnected = false
local streamError = nil
local streamFailureRevision = 0
local streamRecoveryRevision = nil
local refreshQueuedRecovery = nil
local closeOperation = nil
local refresh
local operationActive = false
local refreshContinuation = nil
local snapshotMonitors = {}

local function applySnapshot(clients, monitors)
  snapshotMonitors = monitors
  local activeWorkspaces, monitorNames = {}, {}
  for _, monitor in ipairs(monitors) do
    monitorNames[monitor.id] = monitor.name
    local special = monitor.specialWorkspace
    if special.id ~= 0 and special.name ~= "" then
      activeWorkspaces[special.id] = monitor.name
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
      local visibleOutput = nil
      for _, client in ipairs(matches) do
        visibleOutput = activeWorkspaces[client.workspace.id]
        if visibleOutput then break end
      end
      pad.running, pad.visible, pad.output, pad.address = true, visibleOutput ~= nil, visibleOutput, nil
      table.insert(duplicates, ("duplicate windows for pad '%s' (%s)"):format(pad.id, pad.class))
    else
      local client = matches[1]
      local output = activeWorkspaces[client.workspace.id]
      pad.running = true
      pad.visible = output ~= nil
      pad.output = output or monitorNames[client.monitor]
      pad.address = client.address
    end
  end
  hasSnapshot = true
  status.error = streamError or (#duplicates > 0 and table.concat(duplicates, "; ") or nil)
  status.phase = status.error and "error" or "ready"
  status.busy = false
end

local function commandFailure(command, result)
  if type(result) ~= "table" then
    return command .. " could not be started"
  end
  if result.timedOut then
    return command .. " timed out"
  end
  if result.stdoutTruncated or result.stderrTruncated then
    return command .. " output was truncated"
  end
  if result.exitCode ~= 0 then
    return ("%s failed (exit %s)"):format(command, tostring(result.exitCode))
  end
  return nil
end

local refreshNotifiesOnFailure = false

local function completeRefresh(results, recoveryRevision)
  local clients
  local failure = commandFailure("hyprctl -j clients", results.clients)
    or commandFailure("hyprctl -j monitors", results.monitors)
  if failure then
    status.error = failure
    status.phase = "error"
    status.busy = false
  else
    local clientError
    clients, clientError = decodeArray(results.clients.stdout, "hyprctl -j clients", isClient)
    local monitors, monitorError = decodeArray(results.monitors.stdout, "hyprctl -j monitors", isMonitor)
    if not clients or not monitors then
      failure = clientError or monitorError
      status.error = failure
      status.phase = "error"
      status.busy = false
    else
      if recoveryRevision ~= nil and recoveryRevision == streamFailureRevision then
        streamError, streamRecoveryRevision = nil, nil
      end
      applySnapshot(clients, monitors)
    end
  end
  if failure and refreshNotifiesOnFailure then
    noctalia.notifyError(failure)
  end
  refreshNotifiesOnFailure = false
  refreshing = false
  status.busy = operationActive
  local continuation = refreshContinuation
  refreshContinuation = nil
  publish()
  if continuation then continuation(failure, clients) end
  if refreshQueued and not operationActive and not refreshing then
    local recovery = refreshQueuedRecovery
    refreshQueued, refreshQueuedRecovery = false, nil
    refresh(recovery)
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

local STREAM_DISCONNECTED = "__sidepad_stream_disconnected__"
local STREAM_CONNECTED = "__sidepad_stream_connected__"
local EVENT_STREAM_COMMAND = [[while true; do socat -d -d -U - UNIX-CONNECT:"$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock" 2>&1 | while IFS= read -r line; do case "$line" in *" N successfully connected "*) printf '%s\n' '__sidepad_stream_connected__' ;; *) printf '%s\n' "$line" ;; esac; done; printf '%s\n' '__sidepad_stream_disconnected__'; sleep 1; done]]

local relevantEvents = {
  closewindow = true,
  focusedmon = true,
  changefloatingmode = true,
  monitoradded = true,
  monitoraddedv2 = true,
  monitorremoved = true,
  monitorremovedv2 = true,
  movewindow = true,
  movewindowv2 = true,
  moveworkspace = true,
  moveworkspacev2 = true,
  openwindow = true,
  workspace = true,
  workspacev2 = true,
  activespecial = true,
}

local function setStreamError(message)
  streamFailureRevision = streamFailureRevision + 1
  if streamError == message then return end
  streamError = message
  status.error = message
  status.phase = "error"
  publish()
end

local function onStreamLine(line)
  if line == STREAM_DISCONNECTED then
    streamConnected = false
    streamRecoveryRevision = nil
    setStreamError("Hyprland event stream disconnected; reconnecting")
    return
  elseif line == STREAM_CONNECTED then
    if not streamConnected then
      streamConnected = true
      streamRecoveryRevision = streamError and streamFailureRevision or nil
      refresh(streamRecoveryRevision)
    end
    return
  end
  local event = type(line) == "string" and line:match("^([%w_]+)>>")
  if event and relevantEvents[event] then
    streamConnected = true
    streamRecoveryRevision = streamError and streamFailureRevision or nil
    refresh(streamRecoveryRevision)
  end
end

local function ensureEventStream()
  if streamStarted then return end
  if not noctalia.commandExists("socat") then
    setStreamError("socat was not found in PATH")
    return
  end
  if noctalia.runStream(EVENT_STREAM_COMMAND, onStreamLine) == false then
    setStreamError("Hyprland event stream could not be started")
    return
  end
  streamStarted = true
end

refresh = function(explicitAction, recoveryRevision, continuation)
  if type(explicitAction) ~= "boolean" then
    recoveryRevision, explicitAction = explicitAction, false
  end
  if recoveryRevision == nil and streamConnected and streamError then
    recoveryRevision = streamRecoveryRevision
  end
  if configurationError then
    status.error = configurationError
    status.phase = "error"
    status.busy = operationActive
    publish()
    if explicitAction then
      noctalia.notifyError(configurationError)
    end
    if continuation then continuation(configurationError) end
    return
  end
  ensureEventStream()
  if refreshing or (operationActive and not continuation) then
    refreshQueued = true
    if recoveryRevision then refreshQueuedRecovery = recoveryRevision end
    return
  end
  if not noctalia.commandExists("hyprctl") then
    status.error = "hyprctl was not found in PATH"
    status.phase = "error"
    status.busy = operationActive
    publish()
    if explicitAction then
      noctalia.notifyError(status.error)
    end
    if continuation then continuation(status.error) end
    return
  end
  refreshContinuation = continuation
  refreshNotifiesOnFailure = explicitAction == true
  refreshing = true
  status.phase = hasSnapshot and "refreshing" or "starting"
  status.busy = true
  publish()
  local results, remaining = {}, 2
  local function received(key, result)
    results[key] = result
    remaining = remaining - 1
    if remaining == 0 then
      completeRefresh(results, recoveryRevision)
    end
  end
  -- Both queries belong to this refresh cycle; neither is inferred from the
  -- other, and no compositor mutation is issued during reconciliation.
  query("clients", function(result) received("clients", result) end)
  query("monitors", function(result) received("monitors", result) end)
end

-- A close is acknowledged only after reconciliation observes the address gone.
-- A confirmation dialog or refusal gets a bounded wait, never another close.
local function finishClose(failure)
  closeOperation = nil
  operationActive = false
  status.busy = false
  if failure then
    status.error, status.phase = failure, "error"
    noctalia.notifyError(failure)
  end
  publish()
end

local function verifyClose(failure, clients)
  local operation = closeOperation
  if failure or operation.failure then
    finishClose(operation.failure or failure)
    return
  end
  for _, client in ipairs(clients) do
    if client.address == operation.address then
      if noctalia.nowMs() >= operation.deadline then
        finishClose("pad '" .. operation.pad.id .. "' is still open; close was refused or needs application confirmation")
      else
        operation.stage = "waiting"
      end
      return
    end
  end
  finishClose()
end

local function closePad(pad)
  operationActive = true
  closeOperation = { pad = pad, stage = "lookup" }
  refresh(false, nil, function(failure)
    if failure then return finishClose(failure) end
    if not pad.running then return finishClose() end
    if not pad.address then
      return finishClose("duplicate windows for pad '" .. pad.id .. "'; nothing was closed")
    end
    if not pad.address:match("^0x%x+$") or not pad.address:find("[1-9a-fA-F]") then
      return finishClose("invalid window address for pad '" .. pad.id .. "'; nothing was closed")
    end
    local operation = closeOperation
    operation.address, operation.stage = pad.address, "command"
    -- Check again inside the compositor: a vanished target must never fall back
    -- to the focused window, even if clients changed after the lookup snapshot.
    local expression = ([=[function()
      local windows = hl.get_windows({ class = %q })
      if #windows ~= 1 or windows[1].address ~= %q then
        error("Sidepad close target changed; refresh and retry")
      end
      return hl.dispatch(hl.dsp.window.close({ window = windows[1] }))
    end]=]):format(pad.class, pad.address)
    local completed = false
    local function done(result)
      if completed then return end
      completed = true
      operation.failure = commandFailure("hyprctl close", result)
      if not operation.failure and (type(result.stdout) ~= "string" or noctalia.string.trim(result.stdout) ~= "ok") then
        operation.failure = "Hyprland rejected close for pad '" .. pad.id .. "'; refresh and retry"
      end
      operation.deadline = noctalia.nowMs() + 2000
      operation.stage = "verify"
      refresh(false, nil, verifyClose)
    end
    if noctalia.runAsync({ "hyprctl", "dispatch", expression }, done) == false then done(nil) end
  end)
end

function update()
  if closeOperation and closeOperation.stage == "waiting" and not refreshing then
    closeOperation.stage = "verify"
    refresh(false, nil, verifyClose)
  end
end

local function finite(value)
  return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function placement(widthMode, outputName)
  local name = outputName or noctalia.focusedOutputName()
  local output = nil
  for _, candidate in ipairs(noctalia.outputs()) do
    if candidate.name == name then output = candidate; break end
  end
  if not output or not finite(output.x) or not finite(output.y)
    or not finite(output.width) or not finite(output.height) or output.width < 1 or output.height < 1 then
    return nil, "invalid focused-output geometry; check the focused output and retry"
  end
  local width = noctalia.getConfig((widthMode or status.widthMode) == "wide" and "wide_width" or "narrow_width")
  local edge = noctalia.getConfig("edge_gap")
  local top = noctalia.getConfig("top_gap")
  local bottom = noctalia.getConfig("bottom_gap")
  if not finite(width) or width < 1 or not finite(edge) or edge < 0
    or not finite(top) or top < 0 or not finite(bottom) or bottom < 0 then
    return nil, "invalid placement settings; check widths and gaps and retry"
  end
  edge = math.min(edge, output.width - 1)
  top = math.min(top, output.height - 1)
  width = math.min(width, output.width - edge)
  local height = math.max(1, output.height - top - bottom)
  local x = status.side == "right" and output.x + output.width - width - edge or output.x + edge
  return { name = name, x = x, y = output.y + top, width = width, height = height }
end

local function specialName(monitor)
  return monitor.specialWorkspace.name:gsub("^special:", "")
end

local function windowAction(action)
  operationActive = true
  -- Reconcile before using addresses or toggling visibility, not just after:
  -- events may still be queued when the user clicks.
  refresh(false, nil, function(snapshotFailure)
    local function finish(operationFailure)
      refresh(false, nil, function(refreshFailure)
        operationActive = false
        status.busy = false
        status.error = operationFailure or refreshFailure or status.error
        status.phase = status.error and "error" or "ready"
        publish()
        if operationFailure or refreshFailure then noctalia.notifyError(status.error) end
      end)
    end
    if snapshotFailure then finish(snapshotFailure); return end
    local pad = shared.selectedPad(status)
    if not pad or not pad.running then
      finish("selected pad is not running; start its application and retry")
      return
    end
    if not pad.address or not pad.address:match("^0x%x+$") then
      finish("selected pad has no unique valid window address; resolve duplicate windows and retry")
      return
    end
    local name = pad.workspace:sub(9)
    local visibleOn = nil
    for _, monitor in ipairs(snapshotMonitors) do
      if monitor.specialWorkspace.id ~= 0 and specialName(monitor) == name then visibleOn = monitor.name end
    end
    local hide = action == "hide" or (action == "toggle" and visibleOn ~= nil)
    local widthMode = status.widthMode == "narrow" and "wide" or "narrow"
    local commands = {}
    local function add(expression) table.insert(commands, expression) end
    local function focusMonitor(output) add(("hl.dsp.focus({monitor=%q})"):format(output)) end
    local function toggle(workspace) add(("hl.dsp.workspace.toggle_special(%q)"):format(workspace)) end
    if action == "toggle_width" then
      -- Resize on the owning output without focusing or revealing its workspace.
      if not pad.output then finish("selected pad has no output; refresh and retry"); return end
      local geometry, problem = placement(widthMode, pad.output)
      if not geometry then finish(problem); return end
      local window = ("address:%s"):format(pad.address)
      add(("hl.dsp.window.resize({window=%q,x=%s,y=%s,relative=false})"):format(window, geometry.width, geometry.height))
      add(("hl.dsp.window.move({window=%q,x=%s,y=%s,relative=false})"):format(window, geometry.x, geometry.y))
    elseif hide then
      if visibleOn then
        focusMonitor(visibleOn)
        toggle(name)
      end
    else
      local geometry, problem = placement()
      if not geometry then finish(problem); return end
      for _, monitor in ipairs(snapshotMonitors) do
        local other = specialName(monitor)
        if monitor.specialWorkspace.id ~= 0 and other ~= name and other:sub(1, 17) == "noctalia-sidepad-" then
          focusMonitor(monitor.name)
          toggle(other)
        end
      end
      focusMonitor(geometry.name)
      local window = ("address:%s"):format(pad.address)
      add(("hl.dsp.window.move({window=%q,workspace=%q,follow=false})"):format(window, pad.workspace))
      if visibleOn ~= geometry.name then toggle(name) end
      add(("hl.dsp.window.float({window=%q,action='set'})"):format(window))
      add(("hl.dsp.window.resize({window=%q,x=%s,y=%s,relative=false})"):format(window, geometry.width, geometry.height))
      add(("hl.dsp.window.move({window=%q,x=%s,y=%s,relative=false})"):format(window, geometry.x, geometry.y))
      add(("hl.dsp.focus({window=%q})"):format(window))
    end
    local function run(index)
      local expression = commands[index]
      if not expression then
        if action == "toggle_width" then status.widthMode = widthMode end
        finish()
        return
      end
      local completed = false
      local function done(result)
        if completed then return end
        completed = true
        local failure = commandFailure("hyprctl dispatch " .. expression, result)
        if not failure and (type(result.stdout) ~= "string" or noctalia.string.trim(result.stdout) ~= "ok") then
          failure = "hyprctl rejected " .. expression .. "; check the Hyprland Lua dispatcher support and retry"
        end
        if failure then finish(failure) else run(index + 1) end
      end
      if noctalia.runAsync({ "hyprctl", "dispatch", expression }, done) == false then done(nil) end
    end
    run(1)
  end)
end

-- The one action path: the request watcher below and onIpc both land here.
local function dispatch(action, padId)
  if status.busy or closeOperation then
    return
  end
  if not shared.isAction(action) then
    refuse("unknown action: " .. tostring(action), true)
    return
  end
  if (action == "close" or action == "toggle_width") and padId == nil then padId = status.selectedPadId end
  if action ~= "toggle" and action ~= "refresh" then
    if type(padId) ~= "string" or padId == "" then
      refuse(action .. " requires a pad id", true)
      return
    end
    local found = false
    for _, pad in ipairs(status.pads) do
      if pad.id == padId then found = true; break end
    end
    if not found then
      refuse("unknown pad: " .. padId, true)
      return
    end
  elseif padId ~= nil then
    local found = false
    for _, pad in ipairs(status.pads) do
      if pad.id == padId then found = true; break end
    end
    if not found then
      refuse("unknown pad: " .. padId, true)
      return
    end
  end
  if action == "refresh" then
    refresh(true)
    return
  end
  if action == "close" then
    if padId ~= status.selectedPadId then
      refuse("close only targets the selected pad", true)
      return
    end
    for _, pad in ipairs(status.pads) do
      if pad.id == padId then closePad(pad); return end
    end
  end
  if action == "toggle" or action == "show" or action == "hide" or action == "toggle_width" then
    if padId ~= nil and padId ~= status.selectedPadId then
      refuse("action requires the selected pad", true)
      return
    end
    if not shared.selectedPad(status) or not shared.selectedPad(status).running then
      refuse("selected pad is not running; start its application and retry", true)
      return
    end
    windowAction(action)
    return
  end
  -- Other actions belong to later slices and must not imply work they cannot do.
  refuse(action .. " is not available yet", true)
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
  if payload ~= nil and type(payload) ~= "string" then
    refuse("malformed IPC payload: pad id must be a string", true)
    return
  end
  local padId = nil
  if payload ~= nil then
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
  loadPreferences()
  refresh()
else
  configurationError = configError
  status.error = configError
  status.phase = "error"
  publish()
end
