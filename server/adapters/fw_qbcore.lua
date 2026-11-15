-- QBCore (qb-core) framework adapter (plan §2, §3.2). Read-only.
--
-- Storage (qbcore.sql): `players` keyed by citizenid, with JSON text in
-- charinfo / money / job / gang and `last_updated` (set by MySQL on every
-- write to the row: a proxy for the last save, not a login time). There
-- is no logout column. players.license is `license:<hex>`. Vehicles:
-- qb-garages' `player_vehicles` (plate varchar 50, not unique).
--
-- Online players are saved only every few minutes (UpdateInterval), so live
-- PlayerData from QBCore.Functions.GetQBPlayers() overrides the DB row.
-- Job and gang definitions are QBCore.Shared.Jobs / .Gangs, with grades
-- keyed by strings '0', '1' ...

Aptic = Aptic or {}
Aptic.adapters = Aptic.adapters or {}
local common = Aptic.common

local M = { id = 'qbcore', resource = 'qb-core' }
Aptic.adapters.qbcore = M

local core_cache

--- The QBCore object (read once per run; reset() drops it).
local function core()
  if core_cache then return core_cache end
  local ok, obj = pcall(function() return exports['qb-core']:GetCoreObject() end)
  if ok and type(obj) == 'table' then core_cache = obj end
  return core_cache
end

function M.reset()
  core_cache = nil
end

function M.page_characters(schema, cursor, limit)
  local rows, next_cursor = common.page_players(schema, cursor, limit)
  if not rows then return nil, next_cursor end
  local out = {}
  for i, row in ipairs(rows) do
    local rec = common.player_record(row)
    rec.last_seen_ts = common.epoch(row.last_updated_ts)
    out[i] = rec
  end
  return out, next_cursor
end

function M.online_players()
  local qb = core()
  if not qb or type(qb.Functions) ~= 'table' or not qb.Functions.GetQBPlayers then
    return nil, 'online_unavailable'
  end
  local ok, players = pcall(function() return qb.Functions.GetQBPlayers() end)
  if not ok or type(players) ~= 'table' then return nil, 'online_unavailable' end
  local out = {}
  for _, player in pairs(players) do
    local data = type(player) == 'table' and player.PlayerData
    if type(data) == 'table' and type(data.citizenid) == 'string' then
      out[data.citizenid] = common.player_record(data)
    end
  end
  return out
end

function M.group_definitions()
  local qb = core()
  local shared = qb and qb.Shared
  if type(shared) ~= 'table' or type(shared.Jobs) ~= 'table' or type(shared.Gangs) ~= 'table' then
    return nil, 'groups_unavailable'
  end
  return { jobs = shared.Jobs, gangs = shared.Gangs }
end

function M.page_vehicles(schema, cursor, limit)
  return common.page_vehicles(schema, cursor, limit)
end

return M
