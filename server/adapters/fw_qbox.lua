-- Qbox (qbx_core) framework adapter (plan §2, §3.2). Read-only.
--
-- Storage (qbx_core.sql): `players` keyed by citizenid, with JSON text in
-- charinfo / money / job / gang, `last_updated` (set by MySQL on every
-- write to the row) and `last_logged_out`, written on logout. Qbox stores
-- license2 in players.license when the player has one, else license
-- (server/player.lua CheckPlayerData). Vehicles: qbx_vehicles'
-- `player_vehicles` (plate UNIQUE, varchar 15).
--
-- Live data comes from qbx_core's own exports: GetPlayersData() (every
-- loaded player's PlayerData), GetJobs() and GetGangs() (grades keyed by
-- integer level).

Aptic = Aptic or {}
Aptic.adapters = Aptic.adapters or {}
local common = Aptic.common

local M = { id = 'qbox', resource = 'qbx_core' }
Aptic.adapters.qbox = M

--- One page of characters as plain records (see common.player_record).
--- last_seen_ts: last_logged_out when set, else last_updated (plan §2.1).
function M.page_characters(schema, cursor, limit)
  local rows, next_cursor = common.page_players(schema, cursor, limit, { last_logged_out = true })
  if not rows then return nil, next_cursor end
  local out = {}
  for i, row in ipairs(rows) do
    local rec = common.player_record(row)
    rec.last_seen_ts = common.epoch(row.last_logged_out_ts) or common.epoch(row.last_updated_ts)
    out[i] = rec
  end
  return out, next_cursor
end

--- Loaded players: { [citizenid] = record }, or nil, err.
function M.online_players()
  local ok, list = pcall(function() return exports.qbx_core:GetPlayersData() end)
  if not ok or type(list) ~= 'table' then return nil, 'online_unavailable' end
  local out = {}
  for _, data in pairs(list) do
    if type(data) == 'table' and type(data.citizenid) == 'string' then
      out[data.citizenid] = common.player_record(data)
    end
  end
  return out
end

--- Job and gang definitions: { jobs = { [name] = def }, gangs = ... }, or
--- nil, err.
function M.group_definitions()
  local ok, jobs, gangs = pcall(function()
    return exports.qbx_core:GetJobs(), exports.qbx_core:GetGangs()
  end)
  if not ok or type(jobs) ~= 'table' or type(gangs) ~= 'table' then return nil, 'groups_unavailable' end
  return { jobs = jobs, gangs = gangs }
end

function M.page_vehicles(schema, cursor, limit)
  return common.page_vehicles(schema, cursor, limit)
end

return M
