-- Drives the plugin's entries against a stubbed Noctalia runtime, so entry
-- loading, the shared request/status contract and both UI consumers are checked
-- here rather than only on a host with Noctalia and Hyprland. ./selftest.sh
-- injects the entry sources as the global SOURCES table, the manifest's panel
-- address as PANEL_ENTRY_ID, and runs this file.
--
-- It is a check, not a plugin entry: plugin.toml never loads it.

local failures = 0
local function check(name, expected, actual)
  if expected ~= actual then
    failures = failures + 1
    print(("FAIL %-64s expected [%s] got [%s]"):format(name, tostring(expected), tostring(actual)))
  end
end
local function checkTrue(name, condition)
  if not condition then
    failures = failures + 1
    print(("FAIL %-64s condition was false"):format(name))
  end
end
local function checkContains(name, expected, text)
  if type(text) ~= "string" or not text:find(expected, 1, true) then
    failures = failures + 1
    print(("FAIL %-64s expected to contain [%s] got [%s]"):format(name, expected, tostring(text)))
  end
end

-- ── The stub runtime ─────────────────────────────────────────────────────────

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[key] = copy(item) end
  return out
end

-- The host stores state as JSON and decodes a fresh value on every read, so the
-- stub copies on the same boundary: a caller can never reach the controller's
-- own snapshot. Watchers fire on every set, as the host's do.
local stateStore = {}
local watchers = {}
-- Notifications can be held so two requests are published before the controller
-- answers either, the closest this API allows to two entries writing at once: a
-- caller only ever publishes an intent, never a nonce.
local held = nil

noctalia = {}
noctalia.string = { trim = function(value) return (value:gsub("^%s+", ""):gsub("%s+$", "")) end }
noctalia.state = {
  set = function(key, value)
    stateStore[key] = copy(value)
    local notify = function()
      for _, callback in ipairs(watchers[key] or {}) do callback(copy(value)) end
    end
    if held then table.insert(held, notify) else notify() end
  end,
  get = function(key) return copy(stateStore[key]) end,
  watch = function(key, callback)
    watchers[key] = watchers[key] or {}
    table.insert(watchers[key], callback)
  end,
}

-- ── The user's configuration and the host calls that read it ────────────────

-- The host decodes pads.json with its JSON parser. The stub decodes for real, so
-- a fixture is refused because its text is not JSON, not because the check
-- declared it malformed.
local function decodeJson(text)
  -- cursor is the last consumed byte, so the next byte to read is cursor + 1.
  local cursor = 0
  local function fail(reason)
    error(("json: %s at byte %d"):format(reason, cursor + 1), 0)
  end
  local function peek()
    return text:sub(cursor + 1, cursor + 1)
  end
  local function skip()
    while peek():match("%s") do cursor = cursor + 1 end
  end
  local function take(byte)
    if peek() ~= byte then fail(("expected '%s'"):format(byte)) end
    cursor = cursor + 1
  end
  local parseValue
  local function parseString()
    take('"')
    local out = {}
    while true do
      local character = peek()
      if character == "" then fail("unterminated string") end
      if character == '"' then
        cursor = cursor + 1
        return table.concat(out)
      end
      if character == "\\" then
        local escape = text:sub(cursor + 2, cursor + 2)
        local simple = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
        if simple[escape] == nil then fail("unsupported escape") end
        table.insert(out, simple[escape])
        cursor = cursor + 2
      else
        table.insert(out, character)
        cursor = cursor + 1
      end
    end
  end
  local function parseArray()
    take("[")
    local out = {}
    local position = 1
    skip()
    if peek() == "]" then
      cursor = cursor + 1
      return out
    end
    while true do
      -- The host writes every original index, so a JSON null stays a hole with
      -- the later indices in place; keeping that shape is what lets a fixture
      -- prove the controller refuses a hidden pad or command argument.
      local value = parseValue()
      if value ~= nil then out[position] = value end
      position = position + 1
      skip()
      if peek() == "]" then
        cursor = cursor + 1
        return out
      end
      take(",")
      skip()
    end
  end
  local function parseObject()
    take("{")
    local out = {}
    skip()
    if peek() == "}" then
      cursor = cursor + 1
      return out
    end
    while true do
      local key = parseString()
      skip()
      take(":")
      out[key] = parseValue()
      skip()
      if peek() == "}" then
        cursor = cursor + 1
        return out
      end
      take(",")
      skip()
    end
  end
  function parseValue()
    skip()
    local character = peek()
    if character == "{" then return parseObject() end
    if character == "[" then return parseArray() end
    if character == '"' then return parseString() end
    if text:sub(cursor + 1, cursor + 4) == "true" then
      cursor = cursor + 4
      return true
    end
    if text:sub(cursor + 1, cursor + 5) == "false" then
      cursor = cursor + 5
      return false
    end
    if text:sub(cursor + 1, cursor + 4) == "null" then
      cursor = cursor + 4
      return nil
    end
    local number = text:sub(cursor + 1):match("^%-?%d+%.?%d*")
    if number then
      cursor = cursor + #number
      return tonumber(number)
    end
    fail("unexpected value")
  end
  local ok, value = pcall(parseValue)
  if not ok then return nil, value end
  skip()
  if cursor < #text then return nil, "trailing content" end
  return value
end

-- The plugin data directory the controller reads, and the executables the host
-- would not find on PATH. Both are switched per fixture below.
local files = {}
local absentCommands = {}

noctalia.pluginDataDir = function() return "/data" end
noctalia.readFile = function(path)
  local contents = files[path]
  if contents == nil then return nil, "cannot open file" end
  return contents
end
noctalia.commandExists = function(name) return absentCommands[name] ~= true end
-- Preferences are JSON objects; encode every supplied field so accidental
-- runtime-state persistence is visible to the round-trip assertions below.
local function encodeJson(value)
  if type(value) == "string" then
    return '"' .. value:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n") .. '"'
  elseif type(value) ~= "table" then
    return tostring(value)
  end
  local fields = {}
  for key, item in pairs(value) do
    table.insert(fields, encodeJson(tostring(key)) .. ":" .. encodeJson(item))
  end
  return "{" .. table.concat(fields, ",") .. "}"
end
noctalia.json = { decode = decodeJson, encode = encodeJson }

-- Process commands, queries, files and notifications are recorded separately so
-- snapshot refreshes can be proved observational rather than mistaken for actions.
local launches, writes, notifications, compositorQueries = {}, {}, {}, {}
local queryReplies = {
  clients = { exitCode = 0, stdout = "[]", stderr = "" },
  monitors = { exitCode = 0, stdout = "[]", stderr = "" },
}
local declinedQueries, pendingQueries = {}, {}
local streamCallbacks = {}
local streamAccepted = true
local deferQueries = false
local closeDispatch = nil
local clock = 0
noctalia.nowMs = function() return clock end
noctalia.runAsync = function(argv, onResult)
  table.insert(launches, copy(argv))
  if type(argv) == "table" and argv[1] == "hyprctl" and argv[2] == "-j" then
    local kind = argv[3]
    table.insert(compositorQueries, copy(argv))
    if declinedQueries[kind] then return false end
    if onResult then
      if deferQueries then
        table.insert(pendingQueries, { kind = kind, callback = onResult })
      else
        onResult(copy(queryReplies[kind]))
      end
    end
  elseif closeDispatch and type(argv) == "table" and argv[1] == "hyprctl" and argv[2] == "dispatch" then
    return closeDispatch(argv, onResult)
  end
  return true
end
noctalia.runStream = function(command, onLine)
  table.insert(launches, command)
  table.insert(streamCallbacks, onLine)
  return streamAccepted
end
local function queryCount(kind)
  local count = 0
  for _, argv in ipairs(compositorQueries) do
    if kind == nil or argv[3] == kind then count = count + 1 end
  end
  return count
end
local function finishQuery(kind)
  for index, pending in ipairs(pendingQueries) do
    if pending.kind == kind then
      table.remove(pendingQueries, index)
      pending.callback(copy(queryReplies[kind]))
      return true
    end
  end
  return false
end
local function nonQueryLaunchCount()
  local count = 0
  for _, argv in ipairs(launches) do
    if type(argv) == "table" and not (argv[1] == "hyprctl" and argv[2] == "-j") then count = count + 1 end
  end
  return count
end
local writeFailure = nil
noctalia.writeFile = function(path, contents)
  table.insert(writes, path)
  if writeFailure then return false, writeFailure end
  files[path] = contents
  return true
end
noctalia.notifyError = function(message) table.insert(notifications, message) end

-- A configuration the controller accepts: three pads, one of them without the
-- optional icon, and therefore the file every startup check below loads unless
-- it names its own.
local VALID_PADS = [[
{
  "version": 1,
  "pads": [
    { "id": "terminal", "name": "Terminal", "icon": "terminal-2",
      "class": "noctalia-sidepad-terminal",
      "command": ["kitty", "--class", "noctalia-sidepad-terminal"] },
    { "id": "browser", "name": "Browser",
      "class": "noctalia-sidepad-browser",
      "command": ["firefox", "--class", "noctalia-sidepad-browser"] },
    { "id": "notes", "name": "Notes", "icon": "notes",
      "class": "noctalia-sidepad-notes",
      "command": ["notes", "--pad"] }
  ]
}
]]

files["/data/pads.json"] = VALID_PADS

local function hold() held = {} end
local function release()
  local pending = held
  held = nil
  for _, notify in ipairs(pending) do notify() end
end

local lastGlyph, lastGlyphColor, lastTooltip, lastTree = nil, nil, nil, nil
local toggledPanels, closedPanels = {}, 0

ui = {}
local function node(kind)
  return function(props, children) return { kind = kind, props = props or {}, children = children } end
end
ui.column = node("column")
ui.row = node("row")
ui.label = node("label")
ui.button = node("button")
ui.glyph = node("glyph")
ui.separator = node("separator")

panel = {
  render = function(tree) lastTree = tree end,
  close = function() closedPanels = closedPanels + 1 end,
}
barWidget = {
  setGlyph = function(name) lastGlyph = name end,
  setGlyphColor = function(role) lastGlyphColor = role end,
  setTooltip = function(content) lastTooltip = content end,
  clearTooltip = function() lastTooltip = nil end,
}
-- The bar's right click opens the selector panel by id; the host call is recorded
-- so the check asserts the panel the widget asks for.
noctalia.togglePanel = function(id) table.insert(toggledPanels, id) end

-- Each entry calls require at load, so the module for the entry being loaded is
-- the one require returns.
local entryShared = nil
require = function(path)
  assert(path == "./shared.luau", "unexpected require path: " .. tostring(path))
  assert(entryShared ~= nil, "require was called outside an entry load")
  return entryShared
end

-- ── Loading the entries ─────────────────────────────────────────────────────

-- Each entry is its own runtime with its own module cache, so shared.luau is
-- loaded once per entry exactly as the host does it. The accepted nonce lives in
-- the controller's VM, so the per-VM module instances cannot disagree about it.
local setPreferences
local function loadEntry(entry)
  entryShared = assert(loadstring(SOURCES.shared, "shared.luau"))()
  -- Expose the controller-local seam only in the harness, without adding a
  -- public IPC action or making selection imply a partially implemented show.
  local source = SOURCES[entry] .. (entry == "service" and "\nreturn setPreferences" or "")
  local result = assert(loadstring(source, entry .. ".luau"))()
  if entry == "service" then setPreferences = result end
  return entryShared
end

local serviceShared = loadEntry("service")
local widgetShared = loadEntry("widget")
local panelShared = loadEntry("panel")

local function status() return noctalia.state.get("sidepad.status") end
local function request() return noctalia.state.get("sidepad.request") end

local function strictlyIncreasing(sequence)
  for index = 2, #sequence do
    if sequence[index] <= sequence[index - 1] then return false end
  end
  return true
end

local function tooltipValue(key)
  for _, row in ipairs(lastTooltip or {}) do
    if row.key == key then return row.value end
  end
  return nil
end

local function find(tree, predicate)
  if type(tree) ~= "table" then return nil end
  if predicate(tree) then return tree end
  for _, child in ipairs(tree.children or {}) do
    local found = find(child, predicate)
    if found then return found end
  end
  return nil
end

local function buttonByKey(tree, key)
  return find(tree, function(n) return n.kind == "button" and n.props.key == key end)
end

local function hasText(tree, needle)
  return find(tree, function(n)
    return type(n.props.text) == "string" and n.props.text:find(needle, 1, true) ~= nil
  end) ~= nil
end

-- A snapshot for the bar to render: one selected pad whose record the snapshot
-- describes, so a state check changes only the field it is about. The revision
-- stays whatever the controller last published. `fields` overrides any part of
-- it, and `selectedPadId = false` is how a nil selection survives a table
-- literal, which drops nil values.
local function snapshot(fields)
  fields = fields or {}
  local value = status()
  value.selectedPadId = "terminal"
  value.busy = false
  value.error = nil
  value.pads = {
    { id = "terminal", name = "Terminal", icon = "terminal-2", running = true, visible = false, output = "DP-1" },
  }
  for key, field in pairs(fields) do
    if key ~= "selectedPadId" then value[key] = field end
  end
  if fields.selectedPadId == false then
    value.selectedPadId = nil
  end
  noctalia.state.set(serviceShared.STATUS_KEY, value)
end

-- ── The declared contract ───────────────────────────────────────────────────

check("the service and the widget share the request key", widgetShared.REQUEST_KEY, serviceShared.REQUEST_KEY)
check("the service and the panel share the status key", panelShared.STATUS_KEY, serviceShared.STATUS_KEY)
check("the request key is the contract's", "sidepad.request", serviceShared.REQUEST_KEY)
check("the status key is the contract's", "sidepad.status", serviceShared.STATUS_KEY)
check("the command contract covers eight actions", 8, #serviceShared.ACTIONS)
for _, action in ipairs({ "toggle", "show", "hide", "select", "toggle_width", "switch_side", "close", "refresh" }) do
  checkTrue("the contract declares " .. action, serviceShared.isAction(action))
end
check("an undeclared command is not an action", false, serviceShared.isAction("explode"))

check("the controller watches the request key", 1, #(watchers[serviceShared.REQUEST_KEY] or {}))
checkTrue("both UI entries watch the status key", #(watchers[serviceShared.STATUS_KEY] or {}) >= 2)

-- ── The published snapshot ──────────────────────────────────────────────────

local initial = status()
check("the controller publishes before any request", true, type(initial) == "table")
check("the initial phase", "ready", initial.phase)
check("the initial revision", 2, initial.revision)
check("the initial side", "left", initial.side)
check("the initial width mode", "narrow", initial.widthMode)
check("the initial busy flag", false, initial.busy)
check("the initial error", nil, initial.error)
check("the initial selected pad", "terminal", initial.selectedPadId)
check("the snapshot carries the configured pads", 3, #initial.pads)
check("a configured pad keeps its identity", "terminal", initial.pads[1].id)
check("a configured pad keeps its name", "Terminal", initial.pads[1].name)
check("a configured pad keeps its icon", "terminal-2", initial.pads[1].icon)
check("an optional icon may be absent", nil, initial.pads[2].icon)
check("a configured pad keeps its exact class", "noctalia-sidepad-terminal", initial.pads[1].class)
check("a configured command stays an argv array", "kitty", initial.pads[1].command[1])
check("a configured argv keeps its later arguments", "--class", initial.pads[1].command[2])
check("the managed workspace derives from the id", "special:noctalia-sidepad-terminal", initial.pads[1].workspace)
check("an unobserved pad is stopped", false, initial.pads[1].running)
check("an unobserved pad is hidden", false, initial.pads[1].visible)
check("an unobserved pad has no output", nil, initial.pads[1].output)
check("startup queries each snapshot once", 2, #compositorQueries)
check("startup queries clients once", 1, queryCount("clients"))
check("startup queries monitors once", 1, queryCount("monitors"))
check("startup reconciliation launches no application", 0, nonQueryLaunchCount())
check("loading a configuration writes nothing", 0, #writes)
check("loading a configuration notifies nobody", 0, #notifications)

-- A consumer gets a copy: editing what it read cannot rewrite the controller.
initial.revision = 99
initial.pads[1] = { id = "mutated" }
local reread = status()
check("a caller cannot rewrite the published snapshot", 2, reread.revision)
check("a caller cannot replace a published pad", "terminal", reread.pads[1].id)

-- ── One action path, from two entry VMs and from IPC ────────────────────────

-- Every accepted request the controller publishes, in publication order: the
-- sequence is checked on the values a reader sees, not on the controller's own
-- counter.
local published = {}
table.insert(watchers[serviceShared.REQUEST_KEY], function(value)
  if type(value) == "table" and type(value.nonce) == "number" then
    table.insert(published, value.nonce)
  end
end)

-- A caller publishes the intent; the controller, the only writer of the nonce,
-- stamps and dispatches it.
local intent = widgetShared.request("select", "terminal")
check("a caller publishes its action", "select", intent.action)
check("a caller publishes its pad", "terminal", intent.padId)
check("a caller does not allocate the nonce", nil, intent.nonce)
check("the controller stamps the accepted request", 1, request().nonce)
check("the stamp keeps the action", "select", request().action)
check("the stamp keeps the pad", "terminal", request().padId)

-- The widget only acts on a pad the controller reports as selected, so its click
-- contract is exercised from a snapshot where an action is available.
local before = status().revision
snapshot()
onClick()
check("a widget click takes the next nonce", 2, request().nonce)
check("the widget's request names its action", "toggle", request().action)
check("the controller answers the widget's request", before + 1, status().revision)
checkContains("a stopped pad cannot yet be launched", "selected pad is not running", status().error)

-- The panel runs in its own VM with its own module instance. The nonce still
-- increases, because the controller owns it and no caller can allocate one.
snapshot()
before = status().revision
onToggle()
check("a later request from another entry VM takes the next nonce", 3, request().nonce)
check("the controller answers the panel's request too", before + 1, status().revision)

-- Overlapping publications must never step the nonce back. Two intents are held
-- before the controller answers either, which is the overlap this API allows.
snapshot()
before = status().revision
hold()
onClick()
onToggle()
release()
check("overlapping publications never carry a smaller nonce", true, request().nonce > 3)
check("every overlapping publication is still delivered", before + 2, status().revision)
check("the accepted sequence is strictly increasing", true, strictlyIncreasing(published))
check("five accepted requests were published", 5, #published)

-- The controller's own accepted request is not a new intent, so it is not
-- dispatched twice.
before = status().revision
noctalia.state.set(serviceShared.REQUEST_KEY, { nonce = 99, action = "toggle" })
check("the controller's own stamp is not dispatched again", before, status().revision)

-- The host notifies watchers on every set, so two identical requests are both
-- delivered and both accepted.
before = status().revision
noctalia.state.set(serviceShared.REQUEST_KEY, { action = "toggle" })
noctalia.state.set(serviceShared.REQUEST_KEY, { action = "toggle" })
check("identical consecutive requests are both delivered", before + 2, status().revision)
check("and both take their own nonce", 7, request().nonce)

-- The helper refuses a command that is not in the contract, without publishing
-- anything, so the controller never receives an invented action.
local publishedNonce = request().nonce
local refused, reason = widgetShared.request("explode")
check("an undeclared command is refused by the helper", nil, refused)
check("the refusal names the command", "unsupported action: explode", reason)
check("a refused command does not publish a request", publishedNonce, request().nonce)
-- IPC lands on the same dispatch, so its answer cannot differ from the UI's.
before = status().revision
onIpc("toggle")
check("IPC answers through the same dispatch", before + 1, status().revision)
checkContains("IPC's answer matches the UI's answer", "selected pad is not running", status().error)
onIpc("explode")
check("IPC refuses a command outside the contract", "unknown action: explode", status().error)
onIpc("select", "terminal")
check("IPC routes a declared action with its payload", "select is not available yet", status().error)

-- ── The request boundary ────────────────────────────────────────────────────

-- Anything other than a well-formed request is reported, not dispatched.
noctalia.state.set(serviceShared.REQUEST_KEY, "noise")
check("a non-request value is refused", "malformed request", status().error)
noctalia.state.set(serviceShared.REQUEST_KEY, { padId = "terminal" })
check("a request without an action is refused", "malformed request: action must be a string", status().error)
noctalia.state.set(serviceShared.REQUEST_KEY, { nonce = 50, action = "select", padId = 5 })
check("a request with a non-string pad is refused", "malformed request: padId must be a string", status().error)

-- ── The status snapshot both UI entries render ──────────────────────────────

-- Published snapshot fixture: pad records are the contract this slice declares,
-- and their producer arrives with the pad-configuration slice. Both consumers
-- have to render identity, name, icon and running/visible/output from it.
local fixture = {
  revision = 40,
  phase = "ready",
  selectedPadId = "terminal",
  side = "right",
  widthMode = "wide",
  busy = false,
  error = nil,
  pads = {
    { id = "terminal", name = "Terminal", icon = "terminal-2", running = true, visible = true, output = "DP-1" },
    { id = "browser", name = "Browser", icon = "world", running = true, visible = false, output = "DP-1" },
    { id = "notes", name = "Notes", icon = "notes", running = false, visible = false, output = nil },
  },
}
noctalia.state.set(serviceShared.STATUS_KEY, fixture)

check("the bar shows the selected pad's icon", "terminal-2", lastGlyph)
check("the bar tooltip names the selected pad", "Terminal", tooltipValue("Pad"))
check("the bar tooltip reports the visible state", "visible", tooltipValue("State"))

onOpen()
checkTrue("the panel renders the pad list", type(lastTree) == "table")
check("the panel marks the selected pad", true, buttonByKey(lastTree, "terminal").props.selected)
check("the panel marks another pad as unselected", false, buttonByKey(lastTree, "browser").props.selected)
checkTrue("the panel names a running visible pad", hasText(lastTree, "Terminal · running · visible on DP-1"))
checkTrue("the panel names a running hidden pad", hasText(lastTree, "Browser · running · hidden"))
checkTrue("the panel names a stopped hidden pad", hasText(lastTree, "Notes · stopped · hidden"))
check("the panel shows a pad's icon", "terminal-2", buttonByKey(lastTree, "terminal").props.glyph)
check("pad names include their selected state for assistive users", true, buttonByKey(lastTree, "terminal").props.text:find("selected", 1, true) ~= nil)
check("the selected pad shows Hide", "Hide", buttonByKey(lastTree, "visibility").props.text)
check("a running pad offers the opposite width", "Narrow", buttonByKey(lastTree, "width").props.text)
check("the panel names the side action", "Move to left", buttonByKey(lastTree, "side").props.text)
check("a running pad exposes Close", true, buttonByKey(lastTree, "close").props.enabled)

-- The selected control actions route through the shared request contract.
buttonByKey(lastTree, "width").props.onClick()
check("width action uses the declared toggle contract", "toggle_width", request().action)
check("width request names the selected pad", "terminal", request().padId)
snapshot()
buttonByKey(lastTree, "side").props.onClick()
check("side action uses the declared switch contract", "switch_side", request().action)
snapshot()
buttonByKey(lastTree, "close").props.onClick()
check("close action uses the declared contract", "close", request().action)
snapshot({ pads = { { id = "terminal", name = "Terminal", running = true, visible = true, output = "DP-1" } } })
buttonByKey(lastTree, "visibility").props.onClick()
check("visibility action follows the selected pad state", "hide", request().action)
check("visibility request names its pad", "terminal", request().padId)
-- The controller republishes an error for unsupported actions; failure keeps the panel open.
check("failed actions do not dismiss the panel", 0, closedPanels)
check("the panel displays the controller failure", true, hasText(lastTree, "selected pad is not running"))

snapshot({
  busy = true,
  pads = {
    { id = "terminal", name = "Terminal", running = true, visible = true },
    { id = "browser", name = "Browser", running = true, visible = false },
  },
})
check("busy disables pad selection", false, buttonByKey(lastTree, "browser").props.enabled)
check("busy disables visibility actions", false, buttonByKey(lastTree, "visibility").props.enabled)
check("busy disables refresh", false, find(lastTree, function(n) return n.kind == "button" and n.props.text == "Refresh" end).props.enabled)
local busyNonce = request().nonce
buttonByKey(lastTree, "browser").props.onClick()
buttonByKey(lastTree, "visibility").props.onClick()
check("busy panel actions publish nothing", busyNonce, request().nonce)

snapshot({ pads = { { id = "terminal", name = "Terminal", running = false, visible = false } } })
check("a stopped pad can still be shown", true, buttonByKey(lastTree, "visibility").props.enabled)
check("width is disabled until the pad is running", false, buttonByKey(lastTree, "width").props.enabled)
check("close is disabled until the pad is running", false, buttonByKey(lastTree, "close").props.enabled)
check("side preference remains available for a stopped pad", true, buttonByKey(lastTree, "side").props.enabled)
buttonByKey(lastTree, "visibility").props.onClick()
check("a stopped pad's Show button requests show", "show", request().action)

snapshot({ busy = false, selectedPadId = false, pads = {} })
check("no configured selection disables actions", false, buttonByKey(lastTree, "visibility").props.enabled)
check("no configured selection disables width changes", false, buttonByKey(lastTree, "width").props.enabled)
check("no configured selection disables close", false, buttonByKey(lastTree, "close").props.enabled)
local unavailableNonce = request().nonce
buttonByKey(lastTree, "visibility").props.onClick()
check("unavailable actions publish nothing", unavailableNonce, request().nonce)

-- A fresh selection stays open on failure, then dismisses only after the
-- controller publishes the requested selected pad as visible without an error.
snapshot({
  pads = {
    { id = "terminal", name = "Terminal", running = true, visible = true },
    { id = "browser", name = "Browser", running = true, visible = false },
    { id = "notes", name = "Notes", running = false, visible = false },
  },
})
local requestWatchers = watchers[serviceShared.REQUEST_KEY]
watchers[serviceShared.REQUEST_KEY] = {}
buttonByKey(lastTree, "browser").props.onClick()
watchers[serviceShared.REQUEST_KEY] = requestWatchers
check("a pad selection requests select-and-show", "select", request().action)
check("the request carries the chosen pad", "browser", request().padId)
check("pending select-and-show remains open", 0, closedPanels)
check("selection remains disabled while select-and-show is pending", false, buttonByKey(lastTree, "browser").props.enabled)
check("other controls remain disabled while select-and-show is pending", false, buttonByKey(lastTree, "side").props.enabled)
buttonByKey(lastTree, "side").props.onClick()
check("pending selection prevents a competing action", "select", request().action)
local selectedSuccess = {
  revision = (status().revision or 0) + 1,
  phase = "ready",
  selectedPadId = "browser",
  side = "left",
  widthMode = "narrow",
  busy = false,
  error = nil,
  pads = {
    { id = "terminal", name = "Terminal", icon = "terminal-2", running = true, visible = false },
    { id = "browser", name = "Browser", icon = "world", running = true, visible = true },
    { id = "notes", name = "Notes", icon = "notes", running = false, visible = false },
  },
}
noctalia.state.set(serviceShared.STATUS_KEY, selectedSuccess)
check("successful select-and-show dismisses the panel", 1, closedPanels)
-- The request watcher was withheld to represent the asynchronous action's pending
-- interval; restore a stamped request so subsequent entries see a host-like state.
noctalia.state.set(serviceShared.REQUEST_KEY, { nonce = 99, action = "select", padId = "browser" })

-- ── The bar's states and its two interactions ───────────────────────────────

-- The bar derives every state from the snapshot alone, so each state is asserted
-- from a snapshot that differs only in what the controller reports.
local function lastPanel() return toggledPanels[#toggledPanels] end

-- The description has to agree with the click guard: a state that swallows the
-- left click may not advertise it.
local function describesLeftClick()
  return tostring(tooltipValue("Actions")):find("Left click", 1, true) ~= nil
end
local function describesRightClick()
  return tostring(tooltipValue("Actions")):find("right click", 1, true) ~= nil
end

snapshot()
check("a hidden pad keeps the pad's icon", "terminal-2", lastGlyph)
check("a hidden pad is drawn in the muted theme role", "on_surface_variant", lastGlyphColor)
check("the tooltip names the hidden state", "hidden", tooltipValue("State"))
check("the tooltip names the selected pad in every state", "Terminal", tooltipValue("Pad"))
checkTrue("a state that accepts the left click says so", describesLeftClick())

snapshot({ pads = { { id = "terminal", name = "Terminal", running = false, visible = false } } })
check("a stopped pad is reported as stopped", "stopped", tooltipValue("State"))
check("a pad without an icon falls back to the default glyph", "layout-sidebar-right", lastGlyph)

snapshot({ pads = { { id = "terminal", name = "Terminal", icon = "terminal-2", running = true, visible = true, output = "DP-1" } } })
check("a visible pad shows the pad's icon", "terminal-2", lastGlyph)
check("a visible pad is drawn in the primary theme role", "primary", lastGlyphColor)
check("the tooltip names the visible state", "visible", tooltipValue("State"))

snapshot({ selectedPadId = false, pads = {} })
check("an empty snapshot reports no selection", "None selected", tooltipValue("Pad"))
check("an empty snapshot reports the unavailable state", "unavailable", tooltipValue("State"))
check("an unavailable pad is drawn in the muted theme role", "on_surface_variant", lastGlyphColor)
check("an unavailable bar does not advertise the left click it ignores", false, describesLeftClick())
checkTrue("an unavailable bar still describes the panel it opens", describesRightClick())

snapshot({ busy = true })
check("a busy controller shows the busy glyph", "loader", lastGlyph)
check("a busy controller is drawn in the primary theme role", "primary", lastGlyphColor)
check("the tooltip names the busy state", "busy", tooltipValue("State"))
check("the busy tooltip still names the selected pad", "Terminal", tooltipValue("Pad"))
check("a busy bar does not advertise the left click it ignores", false, describesLeftClick())
checkTrue("a busy bar still describes the panel it opens", describesRightClick())

snapshot({ selectedPadId = false, pads = {}, error = "hyprctl not found" })
check("an error shows the error glyph", "alert-triangle", lastGlyph)
check("an error is drawn in the error theme role", "error", lastGlyphColor)
check("the tooltip names the error state", "error", tooltipValue("State"))
check("the tooltip reports the error itself", "hyprctl not found", tooltipValue("Error"))
check("an error with no selection does not advertise the left click", false, describesLeftClick())

snapshot({ error = "launch failed" })
checkTrue("an error with a selected pad describes the left click it accepts", describesLeftClick())
check("an error keeps the selected pad named", "Terminal", tooltipValue("Pad"))

-- Busy decides the click, so it is the state the bar draws even while the
-- controller still reports the failure of the previous attempt; the tooltip
-- keeps that failure rather than hiding it.
snapshot({ busy = true, error = "launch failed" })
check("a busy controller draws busy, not the stale error", "busy", tooltipValue("State"))
check("a busy controller keeps the reported error in the tooltip", "launch failed", tooltipValue("Error"))
check("a busy bar does not advertise the left click it ignores", false, describesLeftClick())

-- A selection whose record the snapshot does not describe yet is still the
-- controller's selection: the bar names it from the selection and treats a pad it
-- has no runtime detail for as not running and not shown.
snapshot({ pads = {} })
check("a named selection is named without its record", "terminal", tooltipValue("Pad"))
check("a named selection without runtime detail is reported as stopped", "stopped", tooltipValue("State"))
checkTrue("a named selection still describes the left click", describesLeftClick())
onClick()
check("a named selection is still toggleable", "toggle", request().action)
check("a named selection click is stamped", true, type(request().nonce) == "number")

-- The name survives the states that decide the click too: an operation in flight
-- and a reported failure both still say which pad they concern.
snapshot({ pads = {}, busy = true })
check("a busy bar still names the pad the controller selected", "terminal", tooltipValue("Pad"))
check("a busy bar does not advertise the left click it ignores", false, describesLeftClick())

snapshot({ pads = {}, error = "launch failed" })
check("a failed bar still names the pad the controller selected", "terminal", tooltipValue("Pad"))
check("a failed bar reports the failure", "launch failed", tooltipValue("Error"))
checkTrue("a failed bar still describes the left click it accepts", describesLeftClick())

-- An absent selection stays absent whatever else the snapshot reports.
snapshot({ selectedPadId = false, pads = {}, busy = true })
check("busy without a selection still reports none", "None selected", tooltipValue("Pad"))
snapshot({ selectedPadId = false, pads = {}, error = "launch failed" })
check("an error without a selection still reports none", "None selected", tooltipValue("Pad"))

-- Left click publishes one toggle request through the shared helper. Two
-- identical consecutive clicks are two publications, each with its own nonce.
snapshot()
local clickNonce = request().nonce
onClick()
check("a left click publishes a toggle request", "toggle", request().action)
check("the click names no pad, so the controller applies its own selection", nil, request().padId)
check("the click takes the next nonce", clickNonce + 1, request().nonce)
-- The controller answered with its own snapshot, so the bar's next tooltip is a
-- rendering of what the controller published, not of a fixture.
check("the bar renders the snapshot the controller publishes", "Terminal", tooltipValue("Pad"))

snapshot()
clickNonce = request().nonce
onClick()
check("an identical consecutive click is still published", "toggle", request().action)
check("the identical click takes its own nonce", clickNonce + 1, request().nonce)

-- While an operation is in flight the bar publishes nothing: the controller
-- already owns one operation and a second request would compete with it.
snapshot({ busy = true })
local blockedNonce, blockedRevision = request().nonce, status().revision
onClick()
check("a click during an in-flight operation publishes no request", blockedNonce, request().nonce)
check("a click during an in-flight operation leaves the snapshot alone", blockedRevision, status().revision)

snapshot({ selectedPadId = false, pads = {} })
blockedNonce, blockedRevision = request().nonce, status().revision
onClick()
check("a click with no selected pad publishes no request", blockedNonce, request().nonce)
check("a click with no selected pad leaves the snapshot alone", blockedRevision, status().revision)

-- An error is recoverable through a later action, so the click still publishes.
snapshot({ error = "launch failed" })
local retryNonce = request().nonce
onClick()
check("a click after an error still requests the toggle", "toggle", request().action)
check("the retry is a new publication", retryNonce + 1, request().nonce)

-- Right click opens the selector panel by id; it is a local surface, so it stays
-- reachable while an operation runs and publishes no controller request.
toggledPanels = {}
snapshot()
local panelNonce = request().nonce
onRightClick()
check("a right click opens the panel the manifest declares", PANEL_ENTRY_ID, lastPanel())
check("a right click publishes no controller request", panelNonce, request().nonce)

snapshot({ busy = true })
onRightClick()
check("the selector still opens while an operation runs", PANEL_ENTRY_ID, lastPanel())
check("the panel is asked for once per click", 2, #toggledPanels)

-- ── Pad configuration ───────────────────────────────────────────────────────

-- The controller reads the user's definitions once at startup, so every fixture
-- below is a real startup: the entry is loaded again with only that file on
-- disk, and the processes and notifications it causes are counted from zero.
local function startWith(padsJson, preferencesJson)
  files = {}
  if padsJson ~= nil then files["/data/pads.json"] = padsJson end
  files["/data/preferences.json"] = preferencesJson
  stateStore, watchers, held = {}, {}, nil
  launches, writes, notifications, compositorQueries = {}, {}, {}, {}
  pendingQueries, streamCallbacks = {}, {}
  loadEntry("service")
  return status()
end

-- Existing-window actions use a small compositor model. Execute the generated
-- Lua expressions against dispatcher-shaped functions, then feed snapshots back
-- through the real query interface; assertions below concern window outcomes.
local originalRunAsync = noctalia.runAsync
local focusedOutput = "DP-1"
local outputs = {
  { name = "DP-1", x = 0, y = 0, width = 1920, height = 1080 },
  { name = "DP-2", x = -1280, y = -200, width = 1280, height = 720 },
}
local settings = { narrow_width = 900, wide_width = 1200, edge_gap = 10, top_gap = 100, bottom_gap = 100 }
noctalia.outputs = function() return copy(outputs) end
noctalia.focusedOutputName = function() return focusedOutput end
noctalia.getConfig = function(key) return settings[key] end
local windows, monitors, compositorFocus, focusedWindow
local mutationFailure, mutationDeclined, deferMutation, pendingMutation
local function modelSnapshots()
  local function array(items)
    local values = {}
    for _, item in ipairs(items) do table.insert(values, encodeJson(item)) end
    return "[" .. table.concat(values, ",") .. "]"
  end
  queryReplies.clients = { exitCode = 0, stdout = array(windows) }
  queryReplies.monitors = { exitCode = 0, stdout = array(monitors) }
end
local function windowFor(selector)
  for _, window in ipairs(windows) do
    if "address:" .. window.address == selector then return window end
  end
  error("window not found")
end
local function monitorFor(name)
  for _, monitor in ipairs(monitors) do if monitor.name == name then return monitor end end
  error("output not found")
end
hl = { dsp = { window = {}, workspace = {} } }
hl.dsp.focus = function(args)
  return function()
    if args.monitor then
      compositorFocus = args.monitor
    else
      local window = windowFor(args.window)
      if window.workspace.name:sub(1, 8) == "special:"
        and monitorFor(compositorFocus).specialWorkspace.name ~= window.workspace.name then
        hl.dsp.workspace.toggle_special(window.workspace.name:sub(9))()
      end
      focusedWindow = window.address
    end
  end
end
hl.dsp.workspace.toggle_special = function(name)
  return function()
    local target = monitorFor(compositorFocus)
    local alreadyHere = target.specialWorkspace.name:gsub("^special:", "") == name
    for _, monitor in ipairs(monitors) do
      if monitor.specialWorkspace.name:gsub("^special:", "") == name then
        monitor.specialWorkspace = { id = 0, name = "" }
      end
    end
    if not alreadyHere then
      target.specialWorkspace = { id = name == "noctalia-sidepad-terminal" and -99 or -98, name = "special:" .. name }
      for _, window in ipairs(windows) do
        if window.workspace.name == "special:" .. name then window.monitor = target.id end
      end
    end
  end
end
hl.dsp.window.move = function(args)
  return function()
    local window = windowFor(args.window)
    if args.workspace then
      if window.workspace.name == args.workspace then return end
      local owner = monitorFor(compositorFocus)
      for _, monitor in ipairs(monitors) do
        if monitor.specialWorkspace.name == args.workspace then owner = monitor; break end
      end
      window.workspace = { id = -99, name = args.workspace }
      window.monitor = owner.id
      -- Hyprland follows workspace moves unless follow=false is supplied.
      if args.follow ~= false then
        compositorFocus = owner.name
        owner.specialWorkspace = { id = -99, name = args.workspace }
        focusedWindow = window.address
      end
    else
      check("move coordinates are absolute", false, args.relative)
      window.x, window.y = args.x, args.y
    end
  end
end
hl.dsp.window.resize = function(args)
  return function()
    check("resize dimensions are absolute", false, args.relative)
    local window = windowFor(args.window)
    window.width, window.height = args.x, args.y
  end
end
hl.dsp.window.float = function(args)
  return function() windowFor(args.window).floating = args.action == "set" end
end
noctalia.runAsync = function(argv, callback)
  if argv[2] ~= "dispatch" then return originalRunAsync(argv, callback) end
  table.insert(launches, copy(argv))
  if mutationDeclined then return false end
  local function complete()
    if mutationFailure then callback(copy(mutationFailure)); return end
    assert(loadstring("return " .. argv[3]))()()
    modelSnapshots()
    callback({ exitCode = 0, stdout = "ok\n" })
  end
  if deferMutation then pendingMutation = complete else complete() end
  return true
end
local function modelStart(preferences)
  windows = {
    { class = "noctalia-sidepad-terminal", address = "0x1", monitor = 0, workspace = { id = 1, name = "1" } },
    { class = "unconfigured-app", address = "0x2", monitor = 1, workspace = { id = -98, name = "special:noctalia-sidepad-orphan" } },
  }
  monitors = {
    { id = 0, name = "DP-1", specialWorkspace = { id = 0, name = "" } },
    { id = 1, name = "DP-2", specialWorkspace = { id = -98, name = "special:noctalia-sidepad-orphan" } },
  }
  compositorFocus, focusedWindow = focusedOutput, nil
  mutationFailure, mutationDeclined, deferMutation, pendingMutation = nil, false, false, nil
  modelSnapshots()
  startWith(VALID_PADS, preferences)
end
-- A different client can keep the selected pad's workspace on its old output
-- while the unique selected window itself is on a normal workspace.
modelStart()
monitors[2].specialWorkspace = { id = -99, name = "special:noctalia-sidepad-terminal" }
windows[2].workspace = { id = -99, name = "special:noctalia-sidepad-terminal" }
modelSnapshots()
onIpc("refresh")
onIpc("show", "terminal")
check("adoption does not follow a retained workspace to its old output", "DP-1", status().pads[1].output)
check("adoption focuses the unique selected window", "0x1", focusedWindow)
check("adoption leaves no old-output pad visible", 0, monitors[2].specialWorkspace.id)
modelStart()
serviceShared.request("show", "terminal")
check("show hides an unconfigured reserved workspace on another output", 0, monitors[2].specialWorkspace.id)
check("show makes selected workspace visible", "special:noctalia-sidepad-terminal", monitors[1].specialWorkspace.name)
check("show adopts the unique address and focuses it", "0x1", focusedWindow)
check("show floats the selected window", true, windows[1].floating)
check("default left placement", 10, windows[1].x)
check("default top placement", 100, windows[1].y)
check("configured width", 900, windows[1].width)
check("height excludes both gaps", 880, windows[1].height)
check("published visible state comes from final snapshot", true, status().pads[1].visible)
windows[1].floating, windows[1].x = false, 500
onIpc("show", "terminal")
check("repeated show reapplies floating", true, windows[1].floating)
check("repeated show reapplies geometry", 10, windows[1].x)
check("repeated show does not toggle a visible pad off", true, status().pads[1].visible)
focusedOutput = "DP-2"
onIpc("show", "terminal")
check("show follows newly focused output", "DP-2", status().pads[1].output)
check("show removes old output visibility", 0, monitors[1].specialWorkspace.id)
check("negative output x is preserved", -1270, windows[1].x)
check("negative output y is preserved", -100, windows[1].y)
check("second output height", 520, windows[1].height)
-- Hide uses the pad's output, not the newly focused output or another workspace.
focusedOutput = "DP-1"
monitors[1].specialWorkspace = { id = -97, name = "special:unrelated" }
modelSnapshots()
onIpc("toggle")
check("toggle hides the selected workspace on its actual output", false, status().pads[1].visible)
check("hide leaves unrelated visibility untouched", "special:unrelated", monitors[1].specialWorkspace.name)
check("hide preserves the application window", 2, #windows)
check("hide publishes the surviving application", true, status().pads[1].running)
onIpc("toggle")
check("next toggle shows again", true, status().pads[1].visible)
check("show never writes runtime or focus files", 0, #writes)
check("show leaves selection unchanged", "terminal", status().selectedPadId)
-- Right placement comes from the durable preference, not a new side action.
focusedOutput = "DP-2"
modelStart([[{"selectedPadId":"terminal","side":"right"}]])
onIpc("show", "terminal")
check("right edge on a negative output", -910, windows[1].x)
outputs[2] = { name = "DP-2", x = -50, y = -40, width = 5, height = 3 }
onIpc("show", "terminal")
check("tiny output clamps width", 1, windows[1].width)
check("tiny output clamps height", 1, windows[1].height)
checkTrue("tiny output contains horizontal bounds", windows[1].x >= -50 and windows[1].x + windows[1].width <= -45)
checkTrue("tiny output contains vertical bounds", windows[1].y >= -40 and windows[1].y + windows[1].height <= -37)
for _, invalid in ipairs({ {}, { width = 0 }, { width = 0/0 }, { height = math.huge }, { x = false } }) do
  outputs[2] = { name = "DP-2", x = -1280, y = -200, width = 1280, height = 720 }
  if next(invalid) == nil then outputs[2] = nil else for key, value in pairs(invalid) do outputs[2][key] = value end end
  local count = nonQueryLaunchCount()
  onIpc("show", "terminal")
  checkContains("invalid output produces recoverable geometry error", "invalid focused-output geometry", status().error)
  check("invalid output performs no mutation", count, nonQueryLaunchCount())
  check("invalid output clears busy", false, status().busy)
end
outputs[2] = { name = "DP-2", x = -1280, y = -200, width = 1280, height = 720 }
onIpc("show", "terminal")
check("valid geometry recovers on the next show", nil, status().error)
for _, failure in ipairs({
  { declined = true }, { result = { exitCode = 4 } },
  { result = { exitCode = 0, timedOut = true } },
  { result = { exitCode = 0, stdoutTruncated = true } },
  { result = { exitCode = 0, stderrTruncated = true } },
  { result = { exitCode = 0, stdout = "error: dispatcher rejected" } },
}) do
  mutationDeclined, mutationFailure = failure.declined, failure.result
  local previous = #notifications
  onIpc("hide", "terminal")
  checkTrue("mutation failure is actionable", type(status().error) == "string")
  check("mutation failure clears busy", false, status().busy)
  check("mutation failure notifies once", previous + 1, #notifications)
  check("mutation failure reconciles actual visibility", true, status().pads[1].visible)
  mutationDeclined, mutationFailure = false, nil
  onIpc("show", "terminal")
  check("next action recovers after mutation failure", nil, status().error)
end
deferMutation = true
onIpc("show", "terminal")
check("mutation remains busy while a command is pending", true, status().busy)
local commandCount = nonQueryLaunchCount()
onIpc("hide", "terminal")
onIpc("close", "terminal")
check("hide and close cannot interrupt a pending show", commandCount, nonQueryLaunchCount())
streamCallbacks[1]("activespecial>>noctalia-sidepad-terminal,DP-2")
check("events cannot interrupt mutation busy state", true, status().busy)
deferMutation = false
pendingMutation()
check("mutation and queued reconciliation finish", false, status().busy)
check("successful actions keep one client per application", 2, #windows)
windows[#windows + 1] = copy(windows[1])
windows[#windows].address = "0x3"
modelSnapshots()
onIpc("refresh")
local beforeDuplicate = nonQueryLaunchCount()
onIpc("show", "terminal")
checkContains("duplicate selected windows are refused", "unique valid window address", status().error)
check("duplicates cannot cause any mutation", beforeDuplicate, nonQueryLaunchCount())
-- Width uses the same request/IPC and serialized window path, but must never
-- change visibility or durable preferences, even on a different focused output.
do
  local savedOutputs = copy(outputs)
  for _, output in ipairs({
    { name = "DP-1", x = 200, y = 120, width = 1920, height = 1080 },
    { name = "DP-1", x = -1920, y = -1080, width = 1920, height = 1080 },
    { name = "DP-1", x = -50, y = -40, width = 500, height = 150 },
  }) do
    outputs[1], focusedOutput = output, "DP-1"
    for _, side in ipairs({ "left", "right" }) do
      modelStart('{"selectedPadId":"terminal","side":"' .. side .. '"}')
      onIpc("show", "terminal")
      for _, mode in ipairs({ "wide", "narrow" }) do
        serviceShared.request("toggle_width", "terminal")
        local window = windows[1]
        check("width toggles through the UI request", mode, status().widthMode)
        check("toggle preserves chosen edge", side, status().side)
        check("toggle preserves visibility", true, status().pads[1].visible)
        check("toggle applies configured or clamped width", math.min(settings[mode .. "_width"], output.width - 10), window.width)
        check("toggle keeps selected edge aligned", side == "left" and output.x + 10 or output.x + output.width - 10, side == "left" and window.x or window.x + window.width)
        checkTrue("toggle stays within output bounds", window.x >= output.x and window.x + window.width <= output.x + output.width
          and window.y >= output.y and window.y + window.height <= output.y + output.height)
        check("width is not persisted", 0, #writes)
      end
    end
  end
  outputs = savedOutputs
  focusedOutput = "DP-1"
  modelStart()
  onIpc("toggle_width")
  check("width adopts an already-running tiled window as floating", true, windows[1].floating)
  check("width applies geometry without a prior show", 1200, windows[1].width)
  check("width does not move the adopted window into another workspace", "1", windows[1].workspace.name)
  check("width leaves another managed workspace visible", "special:noctalia-sidepad-orphan", monitors[2].specialWorkspace.name)
  modelStart()
  onIpc("show", "terminal")
  onIpc("hide", "terminal")
  focusedOutput, compositorFocus, focusedWindow = "DP-2", "DP-2", "0x2"
  onIpc("toggle_width")
  check("IPC without a pad ID toggles selected width", "wide", status().widthMode)
  check("hidden width remains on its owning output", 10, windows[1].x)
  check("hidden pad stays hidden", false, status().pads[1].visible)
  check("hidden workspace is not revealed on its owner", 0, monitors[1].specialWorkspace.id)
  check("hidden workspace is not revealed on the focused output", 0, monitors[2].specialWorkspace.id)
  check("hidden toggle does not change focus", "DP-2", compositorFocus)
  check("hidden toggle does not focus its client", "0x2", focusedWindow)
  check("hidden toggle preserves application", 2, #windows)
  local count = nonQueryLaunchCount()
  onIpc("toggle_width", "browser")
  check("unselected pad cannot be resized", count, nonQueryLaunchCount())
  outputs[1].width = 0
  onIpc("toggle_width")
  checkContains("invalid width geometry is actionable", "invalid focused-output geometry", status().error)
  check("invalid geometry retains mode", "wide", status().widthMode)
  check("invalid geometry clears busy", false, status().busy)
  outputs[1].width = 1920
  for _, failure in ipairs({
    { declined = true }, { result = { exitCode = 4 } },
    { result = { exitCode = 0, timedOut = true } },
    { result = { exitCode = 0, stdoutTruncated = true } },
    { result = { exitCode = 0, stdout = "error: dispatcher rejected" } },
  }) do
    mutationDeclined, mutationFailure = failure.declined, failure.result
    local previous = #notifications
    onIpc("toggle_width")
    checkTrue("width failure remains actionable", type(status().error) == "string")
    check("width failure notifies once", previous + 1, #notifications)
    check("width failure clears busy", false, status().busy)
    check("width failure retains last completed mode", "wide", status().widthMode)
  end
  mutationDeclined, mutationFailure, deferMutation = false, nil, true
  onIpc("toggle_width")
  check("width mutation holds busy", true, status().busy)
  count = nonQueryLaunchCount()
  onIpc("toggle_width")
  onIpc("show", "terminal")
  check("width blocks competing mutations", count, nonQueryLaunchCount())
  deferMutation = false
  pendingMutation()
  check("width retry recovers", nil, status().error)
  check("width retry completes narrow mode", "narrow", status().widthMode)
  check("width retry clears busy", false, status().busy)
  windows = {}
  modelSnapshots()
  count = nonQueryLaunchCount()
  onIpc("toggle_width")
  checkContains("newly stopped pad is refused after fresh lookup", "not running", status().error)
  check("stopped pad is not launched or mutated", count, nonQueryLaunchCount())
  check("stopped pad retains mode", "narrow", status().widthMode)
  onIpc("toggle_width")
  check("known stopped pad is not launched", count, nonQueryLaunchCount())
  focusedOutput = "DP-1"
end
noctalia.runAsync = originalRunAsync
queryReplies = { clients = { exitCode = 0, stdout = "[]" }, monitors = { exitCode = 0, stdout = "[]" } }

-- An active asynchronous operation owns busy state. A second IPC action is
-- rejected before it starts another command; failed refreshes retain the last
-- reconciled pad state until a later refresh succeeds.
queryReplies = {
  clients = { exitCode = 0, stdout = [[
    [{"class":"noctalia-sidepad-terminal","address":"0x1","monitor":0,"workspace":{"id":-99,"name":"special:noctalia-sidepad-terminal"}}]
  ]], stderr = "" },
  monitors = { exitCode = 0, stdout = [[
    [{"id":0,"name":"DP-1","specialWorkspace":{"id":-99,"name":"noctalia-sidepad-terminal"}}]
  ]], stderr = "" },
}
local operationStart = startWith(VALID_PADS)
check("operation fixture starts ready", "ready", operationStart.phase)
check("operation fixture has a reconciled running pad", true, operationStart.pads[1].running)
deferQueries = true
local queriesBeforeOperation = queryCount()
onIpc("refresh")
check("an IPC operation publishes busy while pending", true, status().busy)
check("a pending operation starts one snapshot pair", queriesBeforeOperation + 2, queryCount())
local activeStatus = status()
activeStatus.selectedPadId = "terminal"
noctalia.state.set(serviceShared.STATUS_KEY, activeStatus)
local activeNonce = request() and request().nonce or 0
onClick()
check("the widget suppresses a second request while busy", activeNonce, request() and request().nonce or 0)
onIpc("toggle")
check("a duplicate IPC operation cannot start another command", queriesBeforeOperation + 2, queryCount())
check("a duplicate leaves the active operation busy", true, status().busy)
check("a rejected duplicate does not notify", 0, #notifications)
finishQuery("clients")
finishQuery("monitors")
check("busy clears after operation results", false, status().busy)
check("successful operation leaves status recoverable", "ready", status().phase)
deferQueries = false

-- Startup refreshes are silent; the explicit IPC refresh reports a safe error,
-- clears busy, and permits a later request to recover.
queryReplies.clients = { exitCode = 4, stdout = "", stderr = "private details" }
onIpc("refresh")
checkContains("explicit failure remains actionable in status", "hyprctl -j clients failed (exit 4)", status().error)
check("explicit failure notifies once", 1, #notifications)
check("notification omits command stderr", false, notifications[1]:find("private details", 1, true) ~= nil)
check("failed refresh retains the last reconciled pad state", true, status().pads[1].running)
check("a failed operation clears busy for recovery", false, status().busy)
for _, failure in ipairs({
  { name = "failed start", decline = true },
  { name = "timeout", result = { exitCode = 0, stdout = "[]", stderr = "", timedOut = true } },
  { name = "truncated stdout", result = { exitCode = 0, stdout = "[]", stderr = "", stdoutTruncated = true } },
  { name = "truncated stderr", result = { exitCode = 0, stdout = "[]", stderr = "", stderrTruncated = true } },
}) do
  queryReplies.clients = failure.result or { exitCode = 0, stdout = "[]", stderr = "" }
  declinedQueries.clients = failure.decline or nil
  local previousNotifications = #notifications
  onIpc("refresh")
  check(failure.name .. " clears busy", false, status().busy)
  check(failure.name .. " remains actionable", true, type(status().error) == "string")
  check(failure.name .. " notifies explicit action", previousNotifications + 1, #notifications)
end
declinedQueries.clients = nil
queryReplies.clients = { exitCode = 0, stdout = "[]", stderr = "" }
onIpc("refresh")
check("a later successful operation recovers", "ready", status().phase)
check("successful recovery clears the operation error", nil, status().error)
deferQueries = false

-- A fixture the controller must refuse: no pads, one actionable reason, and
-- nothing launched, notified or mutated on the way.
local function refusedAtStartup(name, padsJson, expected)
  local snapshot = startWith(padsJson)
  checkContains(name .. ": reason", expected, snapshot.error)
  check(name .. ": publishes no pads", 0, #snapshot.pads)
  check(name .. ": issues no compositor queries", 0, #compositorQueries)
  check(name .. ": starts no application", 0, nonQueryLaunchCount())
  check(name .. ": writes nothing", 0, #writes)
  check(name .. ": notifies nobody", 0, #notifications)
end

-- The shipped example is a configuration the controller must accept, so the
-- file users copy can never be one their own controller refuses.
local example = startWith(EXAMPLE_PADS)
check("the shipped example starts ready", "ready", example.phase)
check("the shipped example reports no error", nil, example.error)
check("the shipped example loads its pads", 2, #example.pads)
check("the shipped example names its first pad", "terminal", example.pads[1].id)
check("the example's optional icon is kept", "terminal-symbolic", example.pads[1].icon)
check("the example derives its workspace", "special:noctalia-sidepad-terminal", example.pads[1].workspace)
check("the example's second pad is accepted too", "browser", example.pads[2].id)
check("the example queries one snapshot pair", 2, #compositorQueries)
check("the example starts no application", 0, nonQueryLaunchCount())
check("the example writes nothing", 0, #writes)

-- A single pair of asynchronous snapshots adopts existing clients and derives
-- visibility from the monitor's active special workspace.
queryReplies = {
  clients = { exitCode = 0, stdout = [[
    [
      {"class":"noctalia-sidepad-terminal","address":"0x1","monitor":0,"workspace":{"id":-99,"name":"special:noctalia-sidepad-terminal"}},
      {"class":"noctalia-sidepad-browser","address":"0x2","monitor":1,"workspace":{"id":1,"name":"1"}}
    ]
  ]], stderr = "" },
  monitors = { exitCode = 0, stdout = [[
    [
      {"id":0,"name":"DP-1","specialWorkspace":{"id":-99,"name":"noctalia-sidepad-terminal"}},
      {"id":1,"name":"DP-2","specialWorkspace":{"id":0,"name":""}}
    ]
  ]], stderr = "" },
}
local reconciled = startWith(VALID_PADS)
check("one pair queries clients and monitors", 2, #compositorQueries)
check("the snapshot reconciles before startup is ready", "ready", reconciled.phase)
check("an existing client is adopted as running", true, reconciled.pads[1].running)
check("the adopted address is retained for controller actions", "0x1", reconciled.pads[1].address)
check("an active special workspace makes the pad visible", true, reconciled.pads[1].visible)
check("the active monitor is published as the output", "DP-1", reconciled.pads[1].output)
check("a unique client on an ordinary workspace stays hidden", false, reconciled.pads[2].visible)
check("a hidden running client keeps its address", "0x2", reconciled.pads[2].address)
check("a configured class with no client is stopped", false, reconciled.pads[3].running)
check("reconciliation launches no application or dispatcher", 0, nonQueryLaunchCount())

queryReplies.clients.stdout = [[
  [
    {"class":"noctalia-sidepad-terminal","address":"0x1","monitor":0,"workspace":{"id":-99,"name":"special:noctalia-sidepad-terminal"}},
    {"class":"noctalia-sidepad-terminal","address":"0x3","monitor":1,"workspace":{"id":2,"name":"2"}},
    {"class":"noctalia-sidepad-notes","address":"0x4","monitor":0,"workspace":{"id":2,"name":"2"}},
    {"class":"noctalia-sidepad-notes","address":"0x5","monitor":1,"workspace":{"id":3,"name":"3"}}
  ]
]]
local duplicate = startWith(VALID_PADS)
checkContains("duplicate matches report a recoverable error", "duplicate windows for pad 'terminal'", duplicate.error)
checkContains("all ambiguous classes are reported", "duplicate windows for pad 'notes'", duplicate.error)
check("duplicate matches never adopt an ambiguous address", nil, duplicate.pads[1].address)
check("duplicate matches are reported as running", true, duplicate.pads[1].running)
check("duplicate visibility still comes from monitor state", true, duplicate.pads[1].visible)
check("duplicate output identifies its active monitor", "DP-1", duplicate.pads[1].output)
check("duplicate snapshots remain observational", 0, nonQueryLaunchCount())

queryReplies.clients.stdout = [[
  [
    {"class":"noctalia-sidepad-terminal","address":"0x1","monitor":0,"workspace":{"id":7,"name":"noctalia-sidepad-terminal"}}
  ]
]]
local nameCollision = startWith(VALID_PADS)
check("a regular workspace cannot match by special-workspace name", false, nameCollision.pads[1].visible)
check("the regular workspace still resolves its monitor name", "DP-1", nameCollision.pads[1].output)

-- A refresh never publishes ready from just one half of the snapshot. Either
-- callback order is accepted, and each cycle queries each endpoint once.
queryReplies.clients.stdout = "[]"
queryReplies.monitors.stdout = "[]"
deferQueries = true
local pending = startWith(VALID_PADS)
check("a pending startup snapshot is not prematurely ready", "starting", pending.phase)
check("startup waits for both asynchronous results", true, pending.busy)
check("startup starts exactly one pair", 2, #compositorQueries)
check("monitor reply alone does not publish ready", true, finishQuery("monitors"))
check("one missing result keeps startup pending", true, status().busy)
check("client reply completes startup", true, finishQuery("clients"))
check("startup becomes ready only after both results", "ready", status().phase)
check("both callbacks are consumed", 0, #pendingQueries)
deferQueries = false

-- Failures preserve a recoverable error, and a later explicit refresh rebuilds
-- truth from a new pair without any compositor mutation.
queryReplies.clients = { exitCode = 7, stdout = "", stderr = "untrusted output" }
queryReplies.monitors = { exitCode = 0, stdout = "[]", stderr = "" }
local failedCommand = startWith(VALID_PADS)
checkContains("a failed snapshot query is visible", "hyprctl -j clients failed (exit 7)", failedCommand.error)
check("command stderr is not exposed", false, failedCommand.error:find("untrusted output", 1, true) ~= nil)
for _, flag in ipairs({ "timedOut", "stdoutTruncated", "stderrTruncated" }) do
  local result = { exitCode = 0, stdout = "[]", stderr = "" }
  result[flag] = true
  queryReplies.clients = result
  local incomplete = startWith(VALID_PADS)
  check(flag .. " prevents a ready snapshot", "error", incomplete.phase)
  check(flag .. " remains visible", true, type(incomplete.error) == "string")
end
queryReplies.clients = { exitCode = 0, stdout = "not json", stderr = "" }
local invalidSnapshot = startWith(VALID_PADS)
checkContains("invalid JSON remains recoverable", "hyprctl -j clients returned an invalid snapshot", invalidSnapshot.error)
queryReplies.clients = { exitCode = 0, stdout = "{}", stderr = "" }
local wrongShape = startWith(VALID_PADS)
checkContains("an object is not accepted as a snapshot array", "returned an invalid snapshot", wrongShape.error)
queryReplies.clients = { exitCode = 0, stdout = "[]", stderr = "" }
declinedQueries.clients = true
local declinedQuery = startWith(VALID_PADS)
checkContains("a declined async query remains recoverable", "hyprctl -j clients could not be started", declinedQuery.error)
check("a declined query still attempts the other half of the pair", 1, queryCount("monitors"))
declinedQueries.clients = nil
queryReplies.clients = { exitCode = 0, stdout = "[]", stderr = "" }
absentCommands.hyprctl = true
local missingHyprctl = startWith(VALID_PADS)
checkContains("missing hyprctl is visible", "hyprctl was not found", missingHyprctl.error)
check("missing hyprctl starts no query", 0, #compositorQueries)
absentCommands.hyprctl = nil
onRefresh()
check("panel refresh recovers status", "ready", status().phase)
check("panel refresh clears the previous error", nil, status().error)
check("panel refresh sends the refresh action", "refresh", request().action)
check("panel refresh queries one pair", 2, #compositorQueries)
onIpc("refresh")
check("IPC refresh also queries one pair", 4, #compositorQueries)
check("refresh and reconciliation remain observational", 0, nonQueryLaunchCount())
check("startup starts one event stream", 1, #streamCallbacks)
checkTrue("event stream uses Hyprland's socket and reconnects", type(launches[1]) == "string"
  and launches[1]:find("while true", 1, true) ~= nil
  and launches[1]:find("__sidepad_stream_connected__", 1, true) ~= nil
  and launches[1]:find("socat -d -d -U - UNIX-CONNECT:\"$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock\"", 1, true) ~= nil)
local streamCallback = streamCallbacks[1]
local beforeStreamEvent = #compositorQueries
streamCallback("openwindow>>0x1,terminal,1")
check("a relevant event invalidates one snapshot pair", beforeStreamEvent + 2, #compositorQueries)
queryReplies.clients.stdout = [=[[{"class":"noctalia-sidepad-terminal","address":"0x1","monitor":0,"workspace":{"id":1,"name":"1"}}]]=]
queryReplies.monitors.stdout = [=[[{"id":0,"name":"DP-1","specialWorkspace":{"id":0,"name":""}}]]=]
streamCallback("openwindow>>0x1,terminal,1")
check("an opened pad appears in refreshed state", true, status().pads[1].running)
queryReplies.clients.stdout = "[]"
streamCallback("closewindow>>0x1")
check("application exit updates the snapshot to stopped", false, status().pads[1].running)
queryReplies.clients.stdout = [=[[{"class":"noctalia-sidepad-terminal","address":"0x1","monitor":0,"workspace":{"id":-99,"name":"special:noctalia-sidepad-terminal"}}]]=]
queryReplies.monitors.stdout = [=[[{"id":1,"name":"DP-2","specialWorkspace":{"id":-99,"name":"noctalia-sidepad-terminal"}}]]=]
streamCallback("focusedmon>>DP-2,1")
check("output focus refreshes visible pad output", "DP-2", status().pads[1].output)
check("output-focus events issue no move or focus command", 0, nonQueryLaunchCount())
beforeStreamEvent = #compositorQueries
streamCallback("windowtitle>>0x1,title")
check("an irrelevant event does not refresh the snapshot", beforeStreamEvent, #compositorQueries)
check("event-driven refreshes do not issue compositor mutations", 0, nonQueryLaunchCount())
queryReplies.clients.stdout = "[]"
queryReplies.monitors.stdout = "[]"

deferQueries = true
beforeStreamEvent = #compositorQueries
streamCallback("closewindow>>0x1")
streamCallback("openwindow>>0x2,terminal,1")
streamCallback("workspacev2>>1,workspace")
check("an event burst during refresh starts one pair", beforeStreamEvent + 2, #compositorQueries)
check("event burst refresh is in flight", true, status().busy)
finishQuery("clients")
finishQuery("monitors")
check("events during refresh collapse to one follow-up pair", beforeStreamEvent + 4, #compositorQueries)
finishQuery("monitors")
finishQuery("clients")
check("coalesced refresh settles", false, status().busy)
check("coalesced refresh returns to ready", "ready", status().phase)
deferQueries = false

streamCallback("__sidepad_stream_disconnected__")
checkContains("stream disconnect is visible in status", "event stream disconnected", status().error)
check("background stream failures do not notify", 0, #notifications)
deferQueries = true
onIpc("refresh")
streamCallback("__sidepad_stream_disconnected__")
finishQuery("clients")
finishQuery("monitors")
checkContains("an older successful query cannot hide a newer disconnect", "event stream disconnected", status().error)
deferQueries = false
queryReplies.clients.stdout = [=[[{"class":"noctalia-sidepad-terminal","address":"0x1","monitor":0,"workspace":{"id":1,"name":"1"}}]]=]
queryReplies.monitors.stdout = [=[[{"id":0,"name":"DP-1","specialWorkspace":{"id":0,"name":""}}]]=]
streamCallback("__sidepad_stream_connected__")
check("a confirmed idle reconnect clears the disconnect error", nil, status().error)
check("a confirmed reconnect refreshes current pad state", true, status().pads[1].running)
streamCallback("__sidepad_stream_disconnected__")
queryReplies.clients = { exitCode = 7, stdout = "", stderr = "" }
streamCallback("__sidepad_stream_connected__")
checkContains("failed recovery remains visible", "hyprctl -j clients failed (exit 7)", status().error)
queryReplies.clients = { exitCode = 0, stdout = "[]", stderr = "" }
onIpc("refresh")
check("explicit retry completes recovery on the connected stream", nil, status().error)
check("explicit retry returns the controller to ready", "ready", status().phase)
queryReplies.clients.stdout = "[]"
streamCallback("__sidepad_stream_disconnected__")
streamCallback("__sidepad_stream_connected__")
check("an idle reconnect refreshes missed application exits", false, status().pads[1].running)
check("reconnected stream state is ready", "ready", status().phase)

queryReplies.clients.stdout = [=[[{"class":"noctalia-sidepad-terminal","address":"0x1","monitor":0,"workspace":{"id":7,"name":"7"}}]]=]
queryReplies.monitors.stdout = [=[[{"id":0,"name":"DP-1","specialWorkspace":{"id":0,"name":""}},{"id":1,"name":"DP-2","specialWorkspace":{"id":0,"name":""}}]]=]
streamCallback("workspace>>7")
check("pad output starts on its original monitor", "DP-1", status().pads[1].output)
queryReplies.clients.stdout = [=[[{"class":"noctalia-sidepad-terminal","address":"0x1","monitor":1,"workspace":{"id":7,"name":"7"}}]]=]
streamCallback("moveworkspacev2>>7,7,DP-2")
check("workspace-move events refresh inactive pad output", "DP-2", status().pads[1].output)

queryReplies = {
  clients = { exitCode = 0, stdout = "[]", stderr = "" },
  monitors = { exitCode = 0, stdout = "[]", stderr = "" },
}

absentCommands.socat = true
local missingSocat = startWith(VALID_PADS)
checkContains("missing socat remains visible", "socat was not found", missingSocat.error)
check("missing socat does not suppress snapshot refresh", 2, #compositorQueries)
absentCommands.socat = nil
onIpc("refresh")
check("refresh retries and starts a recovered event stream", 1, #streamCallbacks)
streamCallbacks[1]("__sidepad_stream_connected__")
check("a confirmed connection recovers missing-socat status", nil, status().error)

streamAccepted = false
local declinedStream = startWith(VALID_PADS)
checkContains("a rejected event stream is recoverable", "event stream could not be started", declinedStream.error)
streamAccepted = true
onIpc("refresh")
check("a later refresh retries a rejected event stream", 2, #streamCallbacks)
streamCallbacks[2]("__sidepad_stream_connected__")
check("a confirmed connection clears the rejected-stream error", nil, status().error)

-- No file at all: the message has to say where the file belongs and what to do.
local missing = startWith(nil)
check("a missing configuration refuses the pads", 0, #missing.pads)
checkContains("a missing configuration names the path", "/data/pads.json", missing.error)
checkContains("a missing configuration points at the example", "pads.example.json", missing.error)
onRefresh()
checkContains("refresh does not hide a configuration error", "pads.example.json", status().error)
check("refresh does not query without configured pads", 0, #compositorQueries)

-- Malformed or misshapen documents.
refusedAtStartup("malformed JSON", '{ "version": 1, "pads": [ }', "is not valid JSON")
refusedAtStartup("an unsupported version", '{ "version": 2, "pads": [] }', "version must be 1")
refusedAtStartup("a missing pads array", '{ "version": 1 }', "pads must be an array")
refusedAtStartup("an object instead of an array", '{ "version": 1, "pads": { "terminal": {} } }', "pads must be an array")

-- Uniqueness.
refusedAtStartup(
  "a duplicate id",
  '{ "version": 1, "pads": ['
    .. '{ "id": "terminal", "name": "One", "class": "class-one", "command": ["kitty"] },'
    .. '{ "id": "terminal", "name": "Two", "class": "class-two", "command": ["kitty"] }] }',
  "duplicate pad id 'terminal'"
)
refusedAtStartup(
  "a duplicate class",
  '{ "version": 1, "pads": ['
    .. '{ "id": "one", "name": "One", "class": "same-class", "command": ["kitty"] },'
    .. '{ "id": "two", "name": "Two", "class": "same-class", "command": ["kitty"] }] }',
  "duplicate pad class 'same-class'"
)

-- Values that must never reach a selector or a derived workspace name.
refusedAtStartup(
  "an id with unsafe characters",
  '{ "version": 1, "pads": [{ "id": "Terminal Pad", "name": "T", "class": "pad-terminal", "command": ["kitty"] }] }',
  "id must be a non-empty string of lowercase ASCII letters"
)
refusedAtStartup(
  "an id that is missing",
  '{ "version": 1, "pads": [{ "name": "T", "class": "pad-terminal", "command": ["kitty"] }] }',
  "id must be a non-empty string of lowercase ASCII letters"
)
refusedAtStartup(
  "a class with selector syntax",
  '{ "version": 1, "pads": [{ "id": "terminal", "name": "T", "class": "pad,class:^.*$", "command": ["kitty"] }] }',
  "class must be a non-empty Wayland class"
)
refusedAtStartup(
  "a class that is missing",
  '{ "version": 1, "pads": [{ "id": "terminal", "name": "T", "command": ["kitty"] }] }',
  "class must be a non-empty Wayland class"
)

-- Arguments stay argv: a value that is not a string would otherwise reach a
-- launch and be reinterpreted by whatever runs it.
refusedAtStartup(
  "a non-string argument",
  '{ "version": 1, "pads": [{ "id": "terminal", "name": "T", "class": "pad-terminal", "command": ["kitty", 2] }] }',
  "command[2] must be a string"
)
refusedAtStartup(
  "an empty command",
  '{ "version": 1, "pads": [{ "id": "terminal", "name": "T", "class": "pad-terminal", "command": [] }] }',
  "command must be a non-empty array"
)
refusedAtStartup(
  "a command given as a string",
  '{ "version": 1, "pads": [{ "id": "terminal", "name": "T", "class": "pad-terminal", "command": "kitty --class pad-terminal" }] }',
  "command must be an array"
)

-- The host leaves a JSON null as a hole that ipairs stops at, so a null would
-- hide the value behind it. Both lists are refused rather than half-validated.
refusedAtStartup(
  "a null in a command",
  '{ "version": 1, "pads": [{ "id": "terminal", "name": "T", "class": "pad-terminal", "command": ["kitty", null, 42] }] }',
  "command has no value at position 2"
)
refusedAtStartup(
  "a null in the pad list",
  '{ "version": 1, "pads": ['
    .. '{ "id": "one", "name": "One", "class": "class-one", "command": ["kitty"] },'
    .. 'null,'
    .. '{ "id": "two", "name": "Two", "class": "class-two", "command": ["kitty"] }] }',
  "pads has no value at position 2"
)

-- The executable check goes through the host, not through a guess about PATH.
absentCommands["absent-binary"] = true
refusedAtStartup(
  "a missing executable",
  '{ "version": 1, "pads": [{ "id": "terminal", "name": "T", "class": "pad-terminal", "command": ["absent-binary"] }] }',
  "executable 'absent-binary' was not found"
)
absentCommands["absent-binary"] = nil

-- A required field.
refusedAtStartup(
  "a missing name",
  '{ "version": 1, "pads": [{ "id": "terminal", "class": "pad-terminal", "command": ["kitty"] }] }',
  "name must be a non-empty string"
)

-- An empty pad list is a valid file: a user who has configured nothing is not in
-- an error state.
local empty = startWith('{ "version": 1, "pads": [] }')
check("an empty pad list starts ready", "ready", empty.phase)
check("an empty pad list reports no error", nil, empty.error)
check("an empty pad list publishes no pads", 0, #empty.pads)

-- ── Durable preferences ─────────────────────────────────────────────────────

for _, fixture in ipairs({
  { name = "absent preferences" },
  { name = "invalid JSON", raw = "{not json" },
  { name = "scalar preferences", raw = "false" },
  { name = "invalid side", raw = '{"selectedPadId":"browser","side":"top"}' },
  { name = "removed selection", raw = '{"selectedPadId":"removed","side":"right"}' },
  { name = "missing selection", raw = '{"side":"right"}' },
  { name = "missing side", raw = '{"selectedPadId":"browser"}' },
}) do
  local restored = startWith(VALID_PADS, fixture.raw)
  check(fixture.name .. ": first valid pad", "terminal", restored.selectedPadId)
  check(fixture.name .. ": default side", "left", restored.side)
  check(fixture.name .. ": no startup write", 0, #writes)
end

local restored = startWith(VALID_PADS, [[
  {"selectedPadId":"browser","side":"right","busy":true,"widthMode":"wide",
   "pads":[{"address":"0xdead","running":true,"visible":true,"output":"DP-9","pid":123}]}
]])
check("stored selection is restored", "browser", restored.selectedPadId)
check("stored side is restored", "right", restored.side)
check("stored width is not runtime truth", "narrow", restored.widthMode)
check("stored busy is not runtime truth", false, restored.busy)
check("stored visibility is not runtime truth", false, restored.pads[1].visible)
check("stored address is not runtime truth", nil, restored.pads[1].address)
check("stored output is not runtime truth", nil, restored.pads[1].output)

local function checkSaved(name, selectedPadId, side)
  check(name .. ": data directory path", "/data/preferences.json", writes[#writes])
  local document = assert(decodeJson(files["/data/preferences.json"]))
  check(name .. ": full selected pad", selectedPadId, document.selectedPadId)
  check(name .. ": full side", side, document.side)
  for key in pairs(document) do
    checkTrue(name .. ": only approved fields", key == "selectedPadId" or key == "side")
  end
  local reloaded = startWith(VALID_PADS, files["/data/preferences.json"])
  check(name .. ": selection survives reload", selectedPadId, reloaded.selectedPadId)
  check(name .. ": side survives reload", side, reloaded.side)
end

check("selection update succeeds", true, setPreferences("notes", "right"))
check("selection update writes once", 1, #writes)
checkSaved("selection update", "notes", "right")
check("side update succeeds", true, setPreferences("notes", "left"))
check("side update writes once", 1, #writes)
checkSaved("side update", "notes", "left")
check("unchanged preferences succeed", true, setPreferences("notes", "left"))
check("unchanged preferences do not write", 0, #writes)

for _, values in ipairs({ { "removed", "left" }, { "notes", "up" }, { false, "left" } }) do
  local saved, problem = setPreferences(values[1], values[2])
  check("invalid preference update fails", nil, saved)
  checkContains("invalid preference update reports why", "cannot save preferences", problem)
  check("invalid preference update writes nothing", 0, #writes)
end

writeFailure = "permission denied"
local saved, problem = setPreferences("browser", "right")
check("write failure does not claim success", nil, saved)
checkContains("write failure names the file", "/data/preferences.json", problem)
checkContains("write failure reports its cause", "permission denied", problem)
check("write failure keeps durable selection", "notes", status().selectedPadId)
check("write failure keeps durable side", "left", status().side)
writeFailure = nil
check("failed preference update is retryable", true, setPreferences("browser", "right"))
checkSaved("write retry", "browser", "right")

startWith('{"version":1,"pads":[]}', '{"selectedPadId":"removed","side":"right"}')
check("no pads leaves no unusable selection", nil, status().selectedPadId)
check("no pads and stale selection use left", "left", status().side)
check("side can be changed without configured pads", true, setPreferences(nil, "right"))
local noPads = startWith('{"version":1,"pads":[]}', files["/data/preferences.json"])
check("empty selection survives reload", nil, noPads.selectedPadId)
check("side survives reload without pads", "right", noPads.side)

-- ── Selected-window close ───────────────────────────────────────────────────
-- Execute the actual compositor expression against windows, not canned status
-- text. Closing a surface leaves its process and sibling surfaces alive.
local closeWindows, closeRequests, beforeCloseDispatch, pendingClose = {}, {}, nil, nil
local closeResult, declineClose, deferClose = nil, false, false
local function closeSnapshot()
  local clients = {}
  for _, window in ipairs(closeWindows) do
    if window.mapped then table.insert(clients, encodeJson(window)) end
  end
  queryReplies.clients = { exitCode = 0, stdout = "[" .. table.concat(clients, ",") .. "]", stderr = "" }
end
local function closeWindow(class, address)
  return { class = class, address = address, mapped = true, monitor = 0, pid = 123,
    workspace = { id = 1, name = "1" } }
end
local function finishCloseCommand(callback, expression)
  if beforeCloseDispatch then beforeCloseDispatch() end
  local hl = {
    get_windows = function(filters)
      local matches = {}
      for _, window in ipairs(closeWindows) do
        if window.mapped and window.class == filters.class then table.insert(matches, window) end
      end
      return matches
    end,
    dsp = { window = { close = function(arguments)
      assert(arguments.window ~= nil, "close must never fall back to the active window")
      return { window = arguments.window }
    end } },
    dispatch = function(operation)
      table.insert(closeRequests, operation.window.address)
      if not operation.window.refuses then operation.window.mapped = false end
      return { ok = true }
    end,
  }
  local chunk = assert(loadstring("return " .. expression))
  setfenv(chunk, { hl = hl, error = error })
  local ok = pcall(chunk())
  closeSnapshot()
  callback(closeResult or { exitCode = 0, stdout = ok and "ok" or "error: changed target", stderr = "" })
end
closeDispatch = function(argv, callback)
  if declineClose then return false end
  if deferClose then
    pendingClose = function() finishCloseCommand(callback, argv[3]) end
  elseif closeResult then
    callback(copy(closeResult))
  else
    finishCloseCommand(callback, argv[3])
  end
  return true
end
local function startCloseFixture()
  clock, closeRequests, beforeCloseDispatch, pendingClose = 0, {}, nil, nil
  closeResult, declineClose, deferClose = nil, false, false
  closeWindows = {
    closeWindow("noctalia-sidepad-terminal", "0xa1"),
    closeWindow("ordinary-terminal", "0xb2"),
    closeWindow("noctalia-sidepad-browser", "0xc3"),
  }
  queryReplies.monitors = { exitCode = 0, stdout = "[]", stderr = "" }
  closeSnapshot()
  startWith(VALID_PADS)
end

for _, via in ipairs({ "IPC", "panel" }) do
  startCloseFixture()
  if via == "IPC" then
    onIpc("close")
  else
    onOpen()
    buttonByKey(lastTree, "close").props.onClick()
  end
  check(via .. " close sends exactly one normal close", 1, #closeRequests)
  check(via .. " close targets selected address", "0xa1", closeRequests[1])
  check(via .. " closes the selected surface", false, closeWindows[1].mapped)
  check(via .. " preserves sibling surface from the same process", true, closeWindows[2].mapped)
  check(via .. " preserves the other configured pad", true, closeWindows[3].mapped)
  check(via .. " reconciles the closed pad", false, status().pads[1].running)
  check(via .. " close clears busy", false, status().busy)
  check(via .. " successful close reports no error", nil, status().error)
  check(via .. " close starts no process or signal command", 1, nonQueryLaunchCount())
end

startCloseFixture()
onIpc("close", "browser")
check("close refuses a pad other than the selected pad", 0, #closeRequests)
checkContains("nonselected close reports why", "selected pad", status().error)

for _, fixture in ipairs({
  { name = "stopped", change = function() closeWindows[1].mapped = false end },
  { name = "duplicate", change = function() table.insert(closeWindows, closeWindow("noctalia-sidepad-terminal", "0xd4")) end },
  { name = "invalid address", change = function() closeWindows[1].address = "0xa1';kill" end },
  { name = "null address", change = function() closeWindows[1].address = "0x0" end },
}) do
  startCloseFixture()
  fixture.change()
  closeSnapshot()
  onIpc("close", "terminal")
  check(fixture.name .. " sends no close", 0, #closeRequests)
  check(fixture.name .. " sends no mutation or signal command", 0, nonQueryLaunchCount())
  check(fixture.name .. " preserves unrelated surface", true, closeWindows[2].mapped)
  check(fixture.name .. " clears busy", false, status().busy)
  if fixture.name == "stopped" then
    check("zero matches reconcile to stopped", false, status().pads[1].running)
    check("zero matches are not a close failure", nil, status().error)
  else
    checkTrue(fixture.name .. " reports an error", status().error ~= nil)
  end
end

-- Changes between lookup and dispatch are checked atomically in Hyprland too.
for _, fixture in ipairs({
  { name = "vanished address", change = function() closeWindows[1].mapped = false end },
  { name = "reused address", change = function() closeWindows[1].class = "ordinary-terminal" end },
  { name = "replacement address", change = function() closeWindows[1].address = "0xe5" end },
  { name = "new duplicate", change = function() table.insert(closeWindows, closeWindow("noctalia-sidepad-terminal", "0xd4")) end },
}) do
  startCloseFixture()
  beforeCloseDispatch = fixture.change
  onIpc("close", "terminal")
  check(fixture.name .. " cannot fall back to focused/unrelated surface", 0, #closeRequests)
  check(fixture.name .. " preserves unrelated surface", true, closeWindows[2].mapped)
  check(fixture.name .. " clears busy", false, status().busy)
  checkTrue(fixture.name .. " reports rejected target", status().error ~= nil)
end

startCloseFixture()
closeWindows[1].refuses = true
closeSnapshot()
onIpc("close", "terminal")
check("refusal waits without blocking rendering", true, status().busy)
check("refusal keeps the surface mapped", true, closeWindows[1].mapped)
clock = 2000
update()
checkContains("refusal is reported after bounded wait", "still open", status().error)
check("refusal clears busy", false, status().busy)
check("refusal never retries or escalates", 1, #closeRequests)
check("refusal never starts a signal command", 1, nonQueryLaunchCount())
check("refusal notifies once", 1, #notifications)
closeWindows[1].refuses = false
closeSnapshot()
onIpc("close", "terminal")
check("close after refusal recovers", false, status().pads[1].running)
check("close after refusal clears error", nil, status().error)

startCloseFixture()
closeWindows[1].refuses = true
closeSnapshot()
onIpc("close", "terminal")
closeWindows[1].mapped = false
closeSnapshot()
clock = 1000
update()
check("delayed application close succeeds before deadline", nil, status().error)
check("delayed application close clears busy", false, status().busy)
check("delayed close sends only one request", 1, #closeRequests)

for _, fixture in ipairs({
  { name = "failed start", decline = true },
  { name = "nonzero exit", result = { exitCode = 1, stdout = "", stderr = "" } },
  { name = "timeout", result = { exitCode = 0, stdout = "ok", timedOut = true } },
  { name = "truncated stdout", result = { exitCode = 0, stdout = "ok", stdoutTruncated = true } },
  { name = "truncated stderr", result = { exitCode = 0, stdout = "ok", stderrTruncated = true } },
  { name = "compositor rejection", result = { exitCode = 0, stdout = "error: rejected" } },
}) do
  startCloseFixture()
  closeResult, declineClose = fixture.result, fixture.decline
  onIpc("close", "terminal")
  check(fixture.name .. " clears close busy", false, status().busy)
  checkTrue(fixture.name .. " reports close failure", status().error ~= nil)
  check(fixture.name .. " reconciles live running state", true, status().pads[1].running)
  check(fixture.name .. " never closes unrelated surface", true, closeWindows[2].mapped)
  closeResult, declineClose = nil, false
  onIpc("close", "terminal")
  check(fixture.name .. " allows a later close", false, status().pads[1].running)
end

startCloseFixture()
deferClose = true
onIpc("close", "terminal")
check("pending close owns busy", true, status().busy)
onIpc("close", "terminal")
serviceShared.request("close", "terminal")
onIpc("hide", "terminal")
serviceShared.request("show", "terminal")
streamCallbacks[1]("openwindow>>0xd4")
check("close, hide and show cannot interrupt a pending close", 1, nonQueryLaunchCount())
check("event during close does not release busy", true, status().busy)
pendingClose()
check("close completes after queued compositor event", false, status().busy)
check("queued event never duplicates close", 1, #closeRequests)

startCloseFixture()
queryReplies.clients = { exitCode = 4, stdout = "", stderr = "" }
onIpc("close", "terminal")
check("failed close lookup never sends a mutation", 0, nonQueryLaunchCount())
check("failed close lookup clears busy", false, status().busy)
checkTrue("failed close lookup reports failure", status().error ~= nil)
closeSnapshot()
onIpc("close", "terminal")
check("failed close lookup is recoverable", false, status().pads[1].running)

startCloseFixture()
deferClose = true
onIpc("close", "terminal")
deferQueries = true
pendingClose()
queryReplies.clients = { exitCode = 4, stdout = "", stderr = "" }
finishQuery("clients")
finishQuery("monitors")
check("failed post-close reconciliation clears busy", false, status().busy)
checkTrue("failed post-close reconciliation reports failure", status().error ~= nil)
check("failed post-close reconciliation retains last snapshot", true, status().pads[1].running)
check("failed post-close reconciliation never repeats close", 1, #closeRequests)
deferQueries = false
closeSnapshot()
onIpc("refresh")
check("refresh recovers failed close reconciliation", false, status().pads[1].running)
check("refresh clears failed close reconciliation error", nil, status().error)

-- Discarding/reloading the controller does not dispatch a close. Startup adopts
-- surviving surfaces, including one left open by an interrupted close operation.
startCloseFixture()
closeWindows[1].refuses = true
closeSnapshot()
onIpc("close", "terminal")
local sentBeforeReload = #closeRequests
local adopted = startWith(VALID_PADS)
check("controller reload sends no close or signal", 0, nonQueryLaunchCount())
check("controller reload preserves outstanding application", true, closeWindows[1].mapped)
check("controller reload preserves unrelated application", true, closeWindows[2].mapped)
check("controller reload adopts surviving pad", "0xa1", adopted.pads[1].address)
check("controller reload clears previous busy", false, adopted.busy)
check("reload does not add an application close request", sentBeforeReload, #closeRequests)

-- The check has to fail its process, not only print: a caller and any automation
-- reading the exit status must see a failed run.
if failures > 0 then
  error(("sidepad harness FAILED: %d"):format(failures), 0)
end
print("sidepad harness ok")
