-- Controller entry: the single place an action is accepted. This slice owns the
-- request/status contract and the dispatch wiring only, so every declared
-- command is refused here instead of half-working: the name exists, no
-- compositor operation is behind it yet. Later slices add their handler to this
-- one path, which is what keeps the widget, the panel and IPC from disagreeing
-- about what exists.

local shared = require("./shared.luau")

local status = {
  revision = 0,
  phase = "ready",
  selectedPadId = nil,
  -- Defaults until the durable preference slice restores the user's own.
  side = "left",
  widthMode = "narrow",
  busy = false,
  error = nil,
  -- Filled once pad definitions are loaded; the field is already part of the
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

-- The one action path: the request watcher below and onIpc both land here, so a
-- UI click and a `noctalia msg plugin` call cannot take different routes.
local function dispatch(action, padId)
  if not shared.isAction(action) then
    refuse("unknown action: " .. tostring(action))
    return
  end
  if padId ~= nil and type(padId) ~= "string" then
    refuse("malformed request: padId must be a string")
    return
  end
  -- Every declared action belongs to a later slice. Naming the action is the
  -- truthful answer for this build: it is in the contract, it is not available.
  refuse(action .. " is not available yet")
end

noctalia.state.watch(shared.REQUEST_KEY, function(request)
  if type(request) ~= "table" or type(request.action) ~= "string" or type(request.nonce) ~= "number" then
    refuse("malformed request")
    return
  end
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

publish()
