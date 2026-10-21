-- Drives the plugin's entries against a stubbed Noctalia runtime, so entry
-- loading, the shared request/status contract and both UI consumers are checked
-- here rather than only on a host with Noctalia and Hyprland. ./selftest.sh
-- injects the entry sources as the global SOURCES table and runs this file.
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

local function hold() held = {} end
local function release()
  local pending = held
  held = nil
  for _, notify in ipairs(pending) do notify() end
end

local lastGlyph, lastTooltip, lastTree = nil, nil, nil

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

panel = { render = function(tree) lastTree = tree end, close = function() end }
barWidget = {
  setGlyph = function(name) lastGlyph = name end,
  setTooltip = function(content) lastTooltip = content end,
  clearTooltip = function() lastTooltip = nil end,
}

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
checkTrue("the snapshot carries a pad list", type(initial.pads) == "table" and #initial.pads == 0)

-- A consumer gets a copy: editing what it read cannot rewrite the controller.
initial.revision = 99
initial.pads[1] = { id = "mutated" }
local reread = status()
check("a caller cannot rewrite the published snapshot", 1, reread.revision)
check("a caller cannot add a pad to the snapshot", 0, #reread.pads)

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

local before = status().revision
onClick()
check("a widget click takes the next nonce", 2, request().nonce)
check("the widget's request names its action", "toggle", request().action)
check("the controller answers the widget's request", before + 1, status().revision)
check("a declared but unimplemented action is refused", "toggle is not available yet", status().error)

-- The panel runs in its own VM with its own module instance. The nonce still
-- increases, because the controller owns it and no caller can allocate one.
before = status().revision
onToggle()
check("a later request from another entry VM takes the next nonce", 3, request().nonce)
check("the controller answers the panel's request too", before + 1, status().revision)

-- Overlapping publications must never step the nonce back. Two intents are held
-- before the controller answers either, which is the overlap this API allows.
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
check("the bar tooltip reports the shown state", "shown", tooltipValue("State"))

onOpen()
checkTrue("the panel renders the pad list", type(lastTree) == "table")
check("the panel marks the selected pad", true, buttonByKey(lastTree, "terminal").props.selected)
check("the panel marks another pad as unselected", false, buttonByKey(lastTree, "browser").props.selected)
checkTrue("the panel names a pad with its state", hasText(lastTree, "Terminal · shown on DP-1"))
checkTrue("the panel reports a stopped pad", hasText(lastTree, "Notes · stopped"))
check("the panel shows a pad's icon", "terminal-2", buttonByKey(lastTree, "terminal").props.glyph)

-- Selecting a pad from the panel carries the pad id on the same action path.
buttonByKey(lastTree, "browser").props.onClick()
check("a panel selection publishes a select request", "select", request().action)
check("the request carries the chosen pad", "browser", request().padId)
check("an unimplemented selection is refused truthfully", "select is not available yet", status().error)
-- The controller republishes its own snapshot, so the fixture cannot outlive it.
check("the controller owns the snapshot after an action", 0, #status().pads)

-- A busy snapshot reaches the bar without inventing a pad state.
noctalia.state.set(serviceShared.STATUS_KEY, {
  revision = 41,
  phase = "ready",
  selectedPadId = nil,
  side = "right",
  widthMode = "wide",
  busy = true,
  error = nil,
  pads = {},
})
check("a busy controller shows the busy glyph", "loader", lastGlyph)
check("an empty snapshot reports no selection", "None selected", tooltipValue("Pad"))

-- The check has to fail its process, not only print: a caller and any automation
-- reading the exit status must see a failed run.
if failures > 0 then
  error(("sidepad harness FAILED: %d"):format(failures), 0)
end
print("sidepad harness ok")
