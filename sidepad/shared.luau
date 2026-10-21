-- The contract the controller, the bar widget and the selector panel share: the
-- two state keys, the command names, and the request helper. Every entry runs in
-- its own VM with its own module instance, so the nonce is read back from shared
-- state instead of being counted here: two identical requests from two entries
-- still change the request the controller sees.

local M = {}

M.REQUEST_KEY = "sidepad.request"
M.STATUS_KEY = "sidepad.status"

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
function M.request(action, padId)
  if not M.isAction(action) then
    return nil, "unsupported action: " .. tostring(action)
  end
  local previous = noctalia.state.get(M.REQUEST_KEY)
  local nonce = type(previous) == "table" and tonumber(previous.nonce) or 0
  local request = { nonce = nonce + 1, action = action }
  if padId ~= nil then
    request.padId = padId
  end
  noctalia.state.set(M.REQUEST_KEY, request)
  return request
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
