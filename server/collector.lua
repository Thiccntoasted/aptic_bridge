-- One snapshot's worth of rows, read from the game database and the
-- framework, shaped and validated for ingest v1 (plan §2, §6.1).
--
-- v1 collections (decision D3: no inventory): characters, balances,
-- vehicles, jobs, plus the online_count measurement. containers,
-- item_stacks, activity and registry are always empty and their
-- capabilities are never declared.
--
--   Aptic.collector.run(sink, opts) -> summary | nil, err
--
-- Call it inside a thread: it yields with Wait(0) after every page and
-- whenever one tick's work passes config.collector.yield_ms. The sink gets:
--   sink:begin(meta)          meta = { taken_at, capabilities, framework,
--                             inventory, framework_version,
--                             inventory_version, salt_fp, online_count }
--   sink:add(collection, row) a contract-shaped row that passed validate.lua
--   sink:finish(counts)       counts = { [collection] = n } for all eight
--                             collections, zeros included (the manifest)
--   sink:abort(err)           optional; called when a run fails after begin.
--                             The rows added so far must be discarded.
--
-- Within one snapshot every balance and vehicle owner references a
-- character that was sent, char_ids, plates and (kind, name) are unique,
-- and last_seen_at <= taken_at, created_at <= last_seen_at (or null).
--
-- Rows hold names and citizenids; they are never logged. The summary and
-- log lines carry counts and reason codes only.

Aptic = Aptic or {}
local M = {}
Aptic.collector = M

M.COLLECTIONS = { 'characters', 'balances', 'containers', 'item_stacks', 'vehicles', 'activity', 'registry', 'jobs' }

local Abort = {}
local function abort(code) error(setmetatable({ code = code }, Abort), 0) end

local function bump(t, k, n) t[k] = (t[k] or 0) + (n or 1) end

local AMBIGUOUS = false

-- ---------------------------------------------------------------------------
-- Run state helpers
-- ---------------------------------------------------------------------------

local function skip(ctx, collection, reason)
  bump(ctx.skipped, collection)
  bump(ctx.skipped.reasons, collection .. '.' .. reason)
end

local function adjust(ctx, reason)
  bump(ctx.adjusted, reason)
end

--- Validate and hand one row to the sink.
local function emit(ctx, collection, row)
  local ok, field = Aptic.validate.row(collection, row)
  if not ok then
    skip(ctx, collection, 'invalid_' .. field)
    return false
  end
  if ctx.total >= ctx.max_rows then abort('snapshot_too_large') end
  ctx.sink:add(collection, row)
  ctx.counts[collection] = ctx.counts[collection] + 1
  ctx.total = ctx.total + 1
  return true
end

local function yielder(budget_ms)
  local y = { count = 0 }
  local slice = GetGameTimer()
  function y.now()
    Wait(0)
    y.count = y.count + 1
    slice = GetGameTimer()
  end
  function y.maybe()
    if GetGameTimer() - slice >= budget_ms then y.now() end
  end
  return y
end

local function sorted_keys(t)
  local out = {}
  for k in pairs(t) do if type(k) == 'string' then out[#out + 1] = k end end
  table.sort(out)
  return out
end

-- ---------------------------------------------------------------------------
-- Characters and balances
-- ---------------------------------------------------------------------------

--- Online players' live data wins over the DB row (QBCore saves only every
--- few minutes). Read-only: these are copies from the framework's exports.
local function overlay(rec, live)
  rec.online = true
  if live.charinfo then rec.charinfo, rec.problems.charinfo = live.charinfo, nil end
  if live.money then rec.money, rec.problems.money = live.money, nil end
  if live.job then rec.job, rec.problems.job = live.job, nil end
  if live.gang then rec.gang = live.gang end
  if not (type(rec.license) == 'string' and rec.license ~= '') then rec.license = live.license end
end

local function note_char(ctx, id)
  ctx.chars[id] = true
  local lower = id:lower()
  if ctx.chars_ci[lower] == nil then
    ctx.chars_ci[lower] = id
  elseif ctx.chars_ci[lower] ~= id then
    ctx.chars_ci[lower] = AMBIGUOUS
  end
end

local function emit_balances(ctx, char_id, rec)
  if type(rec.money) ~= 'table' then
    -- The character is kept; with no balance rows Aptic reads its money as
    -- 0 (the contract's absent-means-zero rule), so this is counted.
    adjust(ctx, 'money_unreadable')
    return
  end
  local cur = Aptic.config.currencies or {}
  local list, problems = Aptic.common.parse_money(rec.money, cur.rename, cur.skip)
  for _, p in ipairs(problems) do skip(ctx, 'balances', p) end
  for _, b in ipairs(list) do
    emit(ctx, 'balances', { char_id = char_id, currency = b.currency, amount = b.amount })
  end
end

local function license_of(rec)
  if type(rec.license) == 'string' and rec.license ~= '' then return rec.license end
  return nil
end

local function emit_characters(ctx, recs)
  local common = Aptic.common
  local licenses = {}
  for _, rec in ipairs(recs) do
    local license = license_of(rec)
    if license then licenses[#licenses + 1] = license end
  end
  local hashes, err = ctx.hasher:player_hashes(licenses)
  if not hashes then abort(err) end
  local tx = ctx.txadmin.state == 'ok' and Aptic.txadmin.lookup(licenses) or {}

  local pending = {}
  for _, rec in ipairs(recs) do
    local id = rec.citizenid
    local license = license_of(rec)
    if type(id) ~= 'string' then
      skip(ctx, 'characters', 'char_id_invalid')
    elseif ctx.chars[id] then
      skip(ctx, 'characters', 'char_id_duplicate')
    elseif not license then
      skip(ctx, 'characters', 'license_missing')
    elseif not hashes[license] then
      skip(ctx, 'characters', 'player_hash_unavailable')
    else
      local last_seen = rec.online and ctx.taken or rec.last_seen_ts
      if not last_seen then
        skip(ctx, 'characters', 'last_seen_unknown')
      else
        if last_seen > ctx.taken then
          last_seen = ctx.taken
          adjust(ctx, 'last_seen_clamped')
        end
        local job, grade, job_problem = common.parse_job(rec.job)
        if job_problem then adjust(ctx, job_problem) end
        local name
        if not ctx.pseudonymize then
          name = common.char_name(rec.charinfo, 120)
          if not name then adjust(ctx, 'name_missing') end
        end
        local created, playtime
        local t = tx[license]
        if t then
          playtime = t.playtime_minutes
          created = t.joined_ts
          -- txAdmin's first join belongs to the player; a character last
          -- seen before it (played before txAdmin was installed) did not
          -- start then, so its creation time stays unknown.
          if created and created > last_seen then
            created = nil
            adjust(ctx, 'created_at_after_last_seen')
          end
        end
        pending[#pending + 1] = {
          rec = rec,
          row = {
            char_id = id,
            player_hash = hashes[license],
            name = name,
            job = job,
            job_grade = grade,
            gang = common.parse_gang(rec.gang),
            created_at = created and Aptic.time.iso(created) or nil,
            playtime_minutes = playtime,
            last_seen_at = Aptic.time.iso(last_seen),
          },
        }
      end
    end
  end

  -- Pseudonymized names, and the fallback for characters without a
  -- readable charinfo name. players.name (the FiveM account name) is never
  -- used: it identifies the person, not the character.
  local need = {}
  for _, p in ipairs(pending) do
    if not p.row.name then need[#need + 1] = p.row.char_id end
  end
  local tags = {}
  if #need > 0 then
    tags, err = ctx.hasher:pseudonym_tags(need)
    if not tags then abort(err) end
  end

  for _, p in ipairs(pending) do
    local row = p.row
    if not row.name and tags[row.char_id] then row.name = Aptic.hashing.pseudonym(tags[row.char_id]) end
    if not row.name then
      skip(ctx, 'characters', 'name_unavailable')
    elseif emit(ctx, 'characters', row) then
      note_char(ctx, row.char_id)
      emit_balances(ctx, row.char_id, p.rec)
    end
    ctx.y.maybe()
  end
end

local function collect_characters(ctx)
  local cursor = ''
  local used = {}
  while true do
    local recs, next_cursor = ctx.fw.page_characters(ctx.schema, cursor, ctx.page)
    if not recs then abort(next_cursor or 'query_failed') end
    for _, rec in ipairs(recs) do
      local live = ctx.online and type(rec.citizenid) == 'string' and ctx.online[rec.citizenid]
      if live then
        overlay(rec, live)
        used[rec.citizenid] = true
      end
    end
    emit_characters(ctx, recs)
    ctx.y.now()
    if #recs < ctx.page then break end
    if next_cursor == nil or next_cursor == cursor then abort('pagination_stuck') end
    cursor = next_cursor
  end

  -- Loaded characters the database doesn't have yet (created this session
  -- and not saved). Their live data is all there is.
  local extra = {}
  for _, id in ipairs(sorted_keys(ctx.online or {})) do
    if not used[id] then
      local rec = ctx.online[id]
      rec.online = true
      extra[#extra + 1] = rec
    end
  end
  for i = 1, #extra, ctx.page do
    emit_characters(ctx, { table.unpack(extra, i, math.min(#extra, i + ctx.page - 1)) })
    ctx.y.now()
  end
end

-- ---------------------------------------------------------------------------
-- Vehicles
-- ---------------------------------------------------------------------------

--- The emitted char_id a player_vehicles.citizenid points at. MySQL
--- compares citizenids case-insensitively (utf8mb4_unicode_ci) and Aptic
--- does not, so a case-only difference is resolved here.
local function resolve_owner(ctx, citizenid)
  if not Aptic.common.present(citizenid) or citizenid == '' then return nil, false end
  if type(citizenid) ~= 'string' then return nil, true end
  if ctx.chars[citizenid] then return citizenid, false end
  local ci = ctx.chars_ci[citizenid:lower()]
  if ci then return ci, false end
  return nil, true
end

local function collect_vehicles(ctx)
  local common = Aptic.common
  local best = {}
  local cursor = 0
  while true do
    local recs, next_cursor = ctx.fw.page_vehicles(ctx.schema, cursor, ctx.page)
    if not recs then abort(next_cursor or 'query_failed') end
    for _, rec in ipairs(recs) do
      local plate = common.plate(rec.plate)
      local state = common.vehicle_state(rec.state)
      local model = common.clean_text(rec.vehicle, 128) or common.clean_text(rec.hash, 128)
      if not plate then
        skip(ctx, 'vehicles', 'plate_invalid')
      elseif not state then
        skip(ctx, 'vehicles', 'state_unknown')
      elseif not model then
        skip(ctx, 'vehicles', 'model_missing')
      else
        local owner, dropped = resolve_owner(ctx, rec.citizenid)
        local row = {
          plate = plate,
          model = model,
          owner_char_id = owner,
          garage = common.clean_text(rec.garage, 128),
          stored = state == 'garaged',
          state = state,
        }
        -- Validate before de-duplicating, so a broken newer row can't hide
        -- a good older one.
        local ok, field = Aptic.validate.row('vehicles', row)
        if not ok then
          skip(ctx, 'vehicles', 'invalid_' .. field)
        else
          local id = common.integer(rec.id) or -1
          local current = best[plate]
          if current then
            -- Plates repeat on QBCore (not unique there): keep the highest
            -- player_vehicles.id, as the contract's D5 notes say.
            skip(ctx, 'vehicles', 'plate_duplicate')
            if id > current.id then best[plate] = { id = id, row = row, dropped = dropped } end
          else
            best[plate] = { id = id, row = row, dropped = dropped }
          end
        end
      end
      ctx.y.maybe()
    end
    ctx.y.now()
    if #recs < ctx.page then break end
    if next_cursor == nil or next_cursor == cursor then abort('pagination_stuck') end
    cursor = next_cursor
  end
  for _, plate in ipairs(sorted_keys(best)) do
    local entry = best[plate]
    if emit(ctx, 'vehicles', entry.row) and entry.dropped then
      adjust(ctx, 'vehicle_owner_not_in_snapshot')
    end
  end
end

-- ---------------------------------------------------------------------------
-- Jobs and gangs
-- ---------------------------------------------------------------------------

local function collect_jobs(ctx)
  local common = Aptic.common
  for _, kind in ipairs({ 'job', 'gang' }) do
    local defs = kind == 'job' and ctx.groups.jobs or ctx.groups.gangs
    for _, name in ipairs(sorted_keys(defs)) do
      local def = defs[name]
      if type(def) ~= 'table' then
        skip(ctx, 'jobs', 'definition_unreadable')
      else
        local grades, problems = common.grades(def.grades)
        for _, p in ipairs(problems) do adjust(ctx, p) end
        emit(ctx, 'jobs', {
          kind = kind,
          name = name,
          label = common.clean_text(def.label, 256) or common.clean_text(name, 256),
          grades = grades,
        })
      end
    end
    ctx.y.now()
  end
end

-- ---------------------------------------------------------------------------
-- Run
-- ---------------------------------------------------------------------------

local function online_count()
  local ok, players = pcall(GetPlayers)
  local n = (ok and type(players) == 'table') and #players or 0
  return math.max(0, math.min(100000, n))
end

local function log_summary(summary)
  local L = Aptic.log
  local c, s = summary.counts, summary.skipped
  local skipped = 0
  for _, name in ipairs(M.COLLECTIONS) do skipped = skipped + s[name] end
  L.info('Collected %d characters, %d balances, %d vehicles, %d jobs/gangs in %d ms (%d rows skipped).',
    c.characters, c.balances, c.vehicles, c.jobs, summary.duration_ms, skipped)
  local parts = {}
  for _, k in ipairs(sorted_keys(s.reasons)) do parts[#parts + 1] = k .. '=' .. s.reasons[k] end
  for _, k in ipairs(sorted_keys(summary.adjusted)) do parts[#parts + 1] = k .. '=' .. summary.adjusted[k] end
  if #parts > 0 then L.debug('collector details: %s', table.concat(parts, ', ')) end
  local tx = summary.txadmin
  if tx.state == 'ok' then
    L.change('txadmin', 'info', 'txAdmin player data found (%s location): created_at and playtime come from it.',
      tx.source or '?')
  else
    L.change('txadmin', 'info',
      'txAdmin player data not available (%s): created_at and playtime are sent as unknown.', tx.state)
  end
end

--- Collect one snapshot into `sink`. See the top of this file.
function M.run(sink, opts)
  opts = opts or {}
  local started = GetGameTimer()
  local conf = Aptic.config.collector or {}

  local cap = Aptic.capability.detect()
  if cap.support == 'incomplete' then return nil, 'framework_not_detected' end
  if cap.support ~= 'supported' then return nil, 'unsupported_combination' end
  local fw = Aptic.adapters[cap.framework]
  local inv = Aptic.adapters[cap.inventory]
  if not fw or not inv then return nil, 'no_adapter' end

  local hasher, herr = Aptic.hashing.session()
  if not hasher then return nil, herr end

  if GetResourceState('oxmysql') ~= 'started' or type(MySQL) ~= 'table' then
    return nil, 'oxmysql_unavailable'
  end
  if fw.reset then fw.reset() end
  local schema, perr = Aptic.common.probe()
  if not schema then return nil, perr end
  if not schema.players then return nil, 'players_table_unreadable' end

  local groups = fw.group_definitions()
  local online = fw.online_players()
  local txadmin = Aptic.txadmin.load()

  local offset = opts.clock_offset_s
  if offset == nil then offset = Aptic.heartbeat and Aptic.heartbeat.state.clock_offset_s or 0 end
  local taken = math.floor(Aptic.time.now() + (tonumber(offset) or 0))

  local capabilities = { 'characters', 'balances' }
  if schema.vehicles then capabilities[#capabilities + 1] = 'vehicles' end
  if groups then capabilities[#capabilities + 1] = 'jobs' end
  capabilities[#capabilities + 1] = 'online_count'

  local meta = {
    taken_at = Aptic.time.iso(taken),
    capabilities = Aptic.common.array(capabilities),
    framework = cap.framework,
    inventory = cap.inventory,
    framework_version = cap.framework_version,
    inventory_version = cap.inventory_version,
    salt_fp = hasher.fp,
    online_count = online_count(),
  }

  local counts, skipped = {}, { reasons = {} }
  for _, name in ipairs(M.COLLECTIONS) do
    counts[name] = 0
    skipped[name] = 0
  end
  local ctx = {
    sink = sink,
    fw = fw,
    schema = schema,
    groups = groups,
    online = online,
    txadmin = txadmin,
    hasher = hasher,
    taken = taken,
    page = math.max(1, math.floor(tonumber(opts.page_size or conf.page_size) or 250)),
    max_rows = tonumber(opts.max_rows or conf.max_rows) or 50000,
    pseudonymize = Aptic.config.pseudonymize == true,
    counts = counts,
    skipped = skipped,
    adjusted = {},
    total = 0,
    chars = {},
    chars_ci = {},
    y = yielder(tonumber(conf.yield_ms) or 2),
  }

  local ok, err = pcall(function()
    sink:begin(meta)
    collect_characters(ctx)
    if schema.vehicles then collect_vehicles(ctx) end
    if groups then collect_jobs(ctx) end
    sink:finish(counts)
  end)
  if not ok then
    local code = getmetatable(err) == Abort and err.code or 'collector_error'
    if code == 'collector_error' then Aptic.log.error('Snapshot collection failed: %s', tostring(err)) end
    if type(sink.abort) == 'function' then pcall(sink.abort, sink, code) end
    return nil, code
  end

  local summary = {
    counts = counts,
    skipped = skipped,
    adjusted = ctx.adjusted,
    duration_ms = math.max(0, GetGameTimer() - started),
    taken_at = meta.taken_at,
    capabilities = meta.capabilities,
    txadmin = txadmin,
    online = { state = online and 'ok' or 'unavailable' },
    inventory_storage = inv.storage(schema),
    yields = ctx.y.count,
  }
  log_summary(summary)
  return summary
end

return M
