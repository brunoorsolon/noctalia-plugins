-- The contract the controller, the bar widget and the selector panel share: the
-- two state keys, the command names, the request helper and the accepted-request
-- shape. Every entry runs in its own VM with its own module instance, so the
-- helper works without shared memory: a caller publishes one request intent, and
-- the controller, its only writer of the nonce, stamps and dispatches it.

local M = {}

M.REQUEST_KEY = "sidepad.request"
M.STATUS_KEY = "sidepad.status"

-- The managed workspace a pad is shown on. It derives from the pad ID alone, so
-- the name is never configuration and two pads cannot share a workspace.
function M.workspaceName(id)
  return "special:noctalia-sidepad-" .. tostring(id)
end

-- Declared commands. A name belongs to the contract from here on, even while the
-- slice that implements it is still open: the controller refuses what it cannot
-- do yet, and a caller cannot invent a command the controller never learns.
M.ACTIONS = {
  "toggle",
  "show",
  "hide",
  "select",
  "toggle_width",
  "switch_side",
  "close",
  "refresh",
}

local DECLARED = {}
for _, action in ipairs(M.ACTIONS) do DECLARED[action] = true end

function M.isAction(action)
  return type(action) == "string" and DECLARED[action] == true
end

-- Publishes one request and returns it. `padId` is optional because only the
-- actions that name a pad carry one. An undeclared action is refused before it
-- reaches the controller, so a caller cannot publish a malformed command.
--
-- The caller publishes the intent only: the controller is the single writer of
-- the nonce (see M.stamp). The plugin API has no atomic increment, so a nonce a
-- caller sampled could be published after another entry published a newer one;
-- one writer removes that window entirely.
function M.request(action, padId)
  if not M.isAction(action) then
    return nil, "unsupported action: " .. tostring(action)
  end
  local request = { action = action }
  if padId ~= nil then
    request.padId = padId
  end
  noctalia.state.set(M.REQUEST_KEY, request)
  return request
end

-- The controller's half of the request contract: allocation and publication are
-- one operation by the only writer of the nonce, so the accepted sequence cannot
-- step back when two entries publish at once.
function M.stamp(request, nonce)
  local accepted = { nonce = nonce, action = request.action }
  if request.padId ~= nil then
    accepted.padId = request.padId
  end
  return accepted
end

-- The selected pad record from a status snapshot. Both UI entries read the pad's
-- identity, name, icon and running/visible/output state through this one lookup,
-- so neither has to know how the snapshot is laid out.
function M.selectedPad(status)
  if type(status) ~= "table" or type(status.pads) ~= "table" then
    return nil
  end
  for _, pad in ipairs(status.pads) do
    if type(pad) == "table" and pad.id == status.selectedPadId then
      return pad
    end
  end
  return nil
end

return M
