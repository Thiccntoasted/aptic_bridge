-- created_at and playtime_minutes from txAdmin (decision D2).
--
-- Neither QBCore nor Qbox stores when a character was created or how long
-- it was played. txAdmin keeps, per player license, the first join time
-- and total minutes played in txData/<profile>/data/playersDB.json; the
-- file is read by transport.js (see createTxAdmin there for what was
-- checked in txAdmin's source: playTime is minutes, tsJoined is unix
-- seconds, how the path is found).
--
-- These are per player, not per character: every character of a license
-- gets the player's values. When txAdmin isn't running, the file can't be
-- found or read, or a license isn't in it, both fields are null (unknown).
-- Nothing is estimated.

Aptic = Aptic or {}
local M = {}
Aptic.txadmin = M

-- txAdmin runs inside FXServer as the `monitor` resource.
M.RESOURCE = 'monitor'

local function js()
  return exports[GetCurrentResourceName()]
end

local function cfg()
  return Aptic.config.txadmin or {}
end

--- Load (or reuse) txAdmin's player database for this run. Returns
--- { state, source, players }: state is ok | disabled | not_running |
--- absent | unreadable | invalid | unavailable; source is env | convar |
--- default | config (never the path, which can contain a user name).
function M.load()
  if cfg().enabled == false then return { state = 'disabled', players = 0 } end
  local override = cfg().players_db
  if type(override) ~= 'string' or override == '' then override = nil end
  if not override and GetResourceState(M.RESOURCE) ~= 'started' then
    return { state = 'not_running', players = 0 }
  end
  local ok, status = pcall(function() return js():txadminLoad(override) end)
  if not ok or type(status) ~= 'table' or type(status.state) ~= 'string' then
    return { state = 'unavailable', players = 0 }
  end
  return { state = status.state, source = status.source, players = tonumber(status.players) or 0 }
end

--- Values for these license strings (as stored in players.license).
--- Returns { [license] = { playtime_minutes = int|nil, joined_ts = int|nil } }.
function M.lookup(licenses)
  if #licenses == 0 then return {} end
  local ok, found = pcall(function() return js():txadminLookup(licenses) end)
  if not ok or type(found) ~= 'table' then return {} end
  local out = {}
  for _, license in ipairs(licenses) do
    local v = found[license]
    if type(v) == 'table' then
      local minutes = Aptic.common.integer(v.playtime_minutes)
      local joined = Aptic.common.integer(v.joined_ts)
      out[license] = {
        playtime_minutes = (minutes and minutes >= 0 and minutes <= 2147483647) and minutes or nil,
        joined_ts = (joined and joined > 0) and joined or nil,
      }
    end
  end
  return out
end

return M
