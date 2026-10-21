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
noctalia.json = { decode = decodeJson }

-- Every process the controller starts, every file it writes and every
-- notification it raises is recorded: reading configuration must produce none of
-- them.
local launches, writes, notifications = {}, {}, {}
noctalia.runAsync = function(argv) table.insert(launches, argv); return true end
noctalia.runStream = function(command) table.insert(launches, command); return true end
noctalia.writeFile = function(path) table.insert(writes, path); return true end
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
local function loadEntry(entry)
  entryShared = assert(loadstring(SOURCES.shared, "shared.luau"))()
  assert(loadstring(SOURCES[entry], entry .. ".luau"))()
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
check("the initial revision", 1, initial.revision)
check("the initial side", "left", initial.side)
check("the initial width mode", "narrow", initial.widthMode)
check("the initial busy flag", false, initial.busy)
check("the initial error", nil, initial.error)
check("the initial selected pad", nil, initial.selectedPadId)
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
check("loading a configuration starts nothing", 0, #launches)
check("loading a configuration writes nothing", 0, #writes)
check("loading a configuration notifies nobody", 0, #notifications)

-- A consumer gets a copy: editing what it read cannot rewrite the controller.
initial.revision = 99
initial.pads[1] = { id = "mutated" }
local reread = status()
check("a caller cannot rewrite the published snapshot", 1, reread.revision)
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
check("a declared but unimplemented action is refused", "toggle is not available yet", status().error)

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
check("IPC's answer matches the UI's answer", "toggle is not available yet", status().error)
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
checkTrue("the panel names a pad with its state", hasText(lastTree, "Terminal · shown on DP-1"))
checkTrue("the panel reports a stopped pad", hasText(lastTree, "Notes · stopped"))
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
check("the panel displays the controller failure", true, hasText(lastTree, "hide is not available yet"))

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
check("the bar renders the snapshot the controller publishes", "None selected", tooltipValue("Pad"))

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
local function startWith(padsJson)
  files = {}
  if padsJson ~= nil then files["/data/pads.json"] = padsJson end
  stateStore, watchers, held = {}, {}, nil
  launches, writes, notifications = {}, {}, {}
  loadEntry("service")
  return status()
end

-- A fixture the controller must refuse: no pads, one actionable reason, and
-- nothing launched, notified or mutated on the way.
local function refusedAtStartup(name, padsJson, expected)
  local snapshot = startWith(padsJson)
  checkContains(name .. ": reason", expected, snapshot.error)
  check(name .. ": publishes no pads", 0, #snapshot.pads)
  check(name .. ": starts nothing", 0, #launches)
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
check("the example starts nothing", 0, #launches)
check("the example writes nothing", 0, #writes)

-- No file at all: the message has to say where the file belongs and what to do.
local missing = startWith(nil)
check("a missing configuration refuses the pads", 0, #missing.pads)
checkContains("a missing configuration names the path", "/data/pads.json", missing.error)
checkContains("a missing configuration points at the example", "pads.example.json", missing.error)

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

-- The check has to fail its process, not only print: a caller and any automation
-- reading the exit status must see a failed run.
if failures > 0 then
  error(("sidepad harness FAILED: %d"):format(failures), 0)
end
print("sidepad harness ok")
