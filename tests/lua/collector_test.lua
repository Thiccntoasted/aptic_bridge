-- The collector end to end under Lua 5.4: fixture databases for Qbox and
-- QBCore behind a fake oxmysql, the frameworks' exports, txAdmin's file
-- read by the real transport.js, and a recording sink.

dofile('tests/support/collect.lua')

local function all_valid(sink)
  for collection, rows in pairs(sink.by) do
    for i, row in ipairs(rows) do
      local ok, field = Aptic.validate.row(collection, row)
      if not ok then error(('%s row %d fails validate.lua (%s)'):format(collection, i, field), 2) end
    end
  end
end

local function count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

-- ---------------------------------------------------------------------------
-- Whole runs
-- ---------------------------------------------------------------------------

test('Qbox + ox_inventory: begin, rows, finish, and every row passes validate.lua', function()
  C.qbox()
  local sink, summary, err = C.run()
  eq(err, nil)
  truthy(summary, 'summary')
  eq(table.concat(sink.calls, ','), 'begin,finish')
  local m = sink.meta
  eq(table.concat(m.capabilities, ','), 'characters,balances,vehicles,jobs,online_count')
  eq(m.framework, 'qbox'); eq(m.inventory, 'ox_inventory')
  eq(m.framework_version, '1.24.1'); eq(m.inventory_version, '2.44.1')
  eq(m.salt_fp, '49224dd5')
  eq(m.online_count, 2)
  truthy(m.taken_at:match('^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$'), m.taken_at)
  eq(keys_of(m), 'capabilities,framework,framework_version,inventory,inventory_version,online_count,salt_fp,taken_at')
  eq(sink.counts.characters, 8)
  eq(sink.counts.balances, 21)
  eq(sink.counts.vehicles, 6)
  eq(sink.counts.jobs, 6)
  for _, c in ipairs({ 'containers', 'item_stacks', 'activity', 'registry' }) do eq(sink.counts[c], 0, c) end
  eq(sink.by.containers, nil); eq(sink.by.item_stacks, nil)
  all_valid(sink)
  eq(summary.counts, sink.counts)
  eq(summary.inventory_storage, 'ox')
  eq(summary.txadmin.state, 'ok')
  eq(summary.online.state, 'ok')
end)

test('QBCore + qb-inventory: the same contract, from QBCore storage and QBCore.Functions', function()
  C.qbcore()
  local sink, summary = C.run()
  truthy(summary)
  eq(sink.meta.framework, 'qbcore'); eq(sink.meta.inventory, 'qb-inventory')
  eq(sink.meta.online_count, 1)
  eq(sink.counts.characters, 4)
  eq(sink.counts.balances, 14)
  eq(sink.counts.vehicles, 3)
  eq(sink.counts.jobs, 5)
  all_valid(sink)
  eq(summary.inventory_storage, 'inventories')
end)

test('counts match the rows the sink received', function()
  for _, setup in ipairs({ C.qbox, C.qbcore }) do
    Stub.reset()
    setup()
    local sink = C.run()
    for _, c in ipairs(Aptic.collector.COLLECTIONS) do
      eq(sink.counts[c], #C.rows(sink, c), c)
    end
  end
end)

-- ---------------------------------------------------------------------------
-- Characters
-- ---------------------------------------------------------------------------

test('player_hash is HMAC-SHA256(salt, "aptic.v1|" .. lower(license)), shared by a player\'s characters', function()
  C.qbcore()
  local sink = C.run()
  -- printf 'aptic.v1|license:1a2b...1213' | openssl dgst -sha256 -mac HMAC -macopt hexkey:<H.SALT>
  eq(C.find(sink, 'characters', 'char_id', 'QB000001').player_hash,
    '97cdbd471deed5a11474f2b54c4cb376447c680d6dd1ca855c1c98f2dd3aed5f')
  Stub.reset()
  C.qbox()
  sink = C.run()
  local a = C.find(sink, 'characters', 'char_id', 'ABC12345')
  local b = C.find(sink, 'characters', 'char_id', 'BCD23456')
  eq(a.player_hash, b.player_hash, 'two characters of one license')
  truthy(a.player_hash ~= C.find(sink, 'characters', 'char_id', 'CDE34567').player_hash)
end)

test('a different salt gives different hashes and fingerprint', function()
  C.qbcore({ salt = ('f'):rep(64) })
  local sink = C.run()
  truthy(sink.meta.salt_fp ~= '49224dd5')
  truthy(C.find(sink, 'characters', 'char_id', 'QB000001').player_hash
    ~= '97cdbd471deed5a11474f2b54c4cb376447c680d6dd1ca855c1c98f2dd3aed5f')
end)

test('real character names by default, from charinfo, cleaned', function()
  C.qbox()
  local sink = C.run()
  eq(C.find(sink, 'characters', 'char_id', 'ABC12345').name, 'Marcus Reyes')
  eq(C.find(sink, 'characters', 'char_id', 'EFG56789').name, 'Zoë \u{1F31F} Star Light', 'emoji kept, newline cleaned')
end)

test('missing charinfo or empty names get the stable pseudonym, never players.name', function()
  C.qbox()
  local sink, summary = C.run()
  local row = C.find(sink, 'characters', 'char_id', 'DEF45678')
  truthy(row.name:match('^Character %x%x%x%x%x%x%x%x$'), row.name)
  not_contains(C.recorded_json(sink), 'xXGamer')
  eq(summary.adjusted.name_missing, 1)
  Stub.reset()
  C.qbcore()
  sink = C.run()
  truthy(C.find(sink, 'characters', 'char_id', 'QB000004').name:match('^Character %x+$'))
end)

test('pseudonymize on: every name is "Character <tag>", stable across runs and distinct per character', function()
  C.qbox()
  Aptic.config.pseudonymize = true
  local first = C.run()
  local second = C.run()
  local seen = {}
  for i, row in ipairs(C.rows(first, 'characters')) do
    truthy(row.name:match('^Character %x%x%x%x%x%x%x%x$'), row.name)
    eq(C.rows(second, 'characters')[i].name, row.name, 'stable')
    falsy(seen[row.name], 'distinct per character')
    seen[row.name] = true
  end
  local text = C.recorded_json(first)
  for _, real in ipairs({ 'Marcus', 'Reyes', 'Lena', 'Juniper', 'Okafor', 'Zoë' }) do not_contains(text, real) end
  -- the tag is the first 8 hex of HMAC(salt, "aptic.v1.name|" .. lower(char_id)); see collector_exports.test.mjs
  eq(C.find(first, 'characters', 'char_id', 'ABC12345').name, 'Character 16d278ef')
  Aptic.config.pseudonymize = false
end)

test('jobs and gangs: grade levels from JSON, bare-number grades, string levels, none is no gang', function()
  C.qbcore()
  local sink, summary = C.run()
  local dario = C.find(sink, 'characters', 'char_id', 'QB000001')
  eq(dario.job, 'police'); eq(dario.job_grade, 2); eq(dario.gang, nil)
  local ama = C.find(sink, 'characters', 'char_id', 'QB000002')
  eq(ama.job_grade, 1, 'bare-number grade'); eq(ama.gang, 'lostmc')
  eq(math.type(C.find(sink, 'characters', 'char_id', 'QB000004').job_grade), 'integer')
  eq(C.find(sink, 'characters', 'char_id', 'QB000004').job_grade, 3, '"3" read as 3')
end)

test('malformed job JSON: unemployed 0, counted', function()
  C.qbox()
  local sink, summary = C.run()
  local row = C.find(sink, 'characters', 'char_id', 'DEF45678')
  eq(row.job, 'unemployed'); eq(row.job_grade, 0)
  eq(summary.adjusted.job_unreadable, 1)
end)

test('last_seen_at: Qbox last_logged_out, else last_updated; clamped to taken_at', function()
  C.qbox()
  local sink, summary = C.run()
  eq(C.find(sink, 'characters', 'char_id', 'ABC12345').last_seen_at, '2026-11-10T21:05:00Z')
  eq(C.find(sink, 'characters', 'char_id', 'BCD23456').last_seen_at, '2026-11-01T18:30:00Z', 'logout, not the later row touch')
  eq(C.find(sink, 'characters', 'char_id', 'DEF45678').last_seen_at, '2026-11-12T09:15:00Z', 'no logout: last_updated')
  eq(C.find(sink, 'characters', 'char_id', 'GHI00002').last_seen_at, sink.meta.taken_at, 'DB clock ahead: clamped')
  eq(summary.adjusted.last_seen_clamped, 1)
end)

test('QBCore last_seen_at is last_updated', function()
  C.qbcore()
  local sink = C.run()
  eq(C.find(sink, 'characters', 'char_id', 'QB000002').last_seen_at, '2026-11-01T18:30:00Z')
end)

test('taken_at uses the heartbeat clock offset', function()
  C.qbcore()
  local sink = C.run({ clock_offset_s = -7200 })
  local taken = Aptic.time.parse_iso(sink.meta.taken_at)
  between(os.time() - taken, 7198, 7202)
  for _, row in ipairs(C.rows(sink, 'characters')) do
    truthy(Aptic.time.parse_iso(row.last_seen_at) <= taken, 'last_seen_at <= taken_at')
  end
end)

-- ---------------------------------------------------------------------------
-- Online overlay
-- ---------------------------------------------------------------------------

test('online players: live money, job and gang win over the DB row, last_seen_at is taken_at', function()
  C.qbox()
  local sink = C.run()
  local row = C.find(sink, 'characters', 'char_id', 'CDE34567')
  eq(row.job, 'mechanic'); eq(row.job_grade, 1); eq(row.gang, 'ballas')
  eq(row.last_seen_at, sink.meta.taken_at)
  local money = C.balances(sink, 'CDE34567')
  eq(money.cash, 7300); eq(money.bank, 91000); eq(money.crypto, 12)
end)

test('QBCore online overlay through QBCore.Functions.GetQBPlayers', function()
  C.qbcore()
  local sink = C.run()
  local row = C.find(sink, 'characters', 'char_id', 'QB000003')
  eq(row.job, 'mechanic'); eq(row.job_grade, 3)
  eq(C.balances(sink, 'QB000003').bank, 64000)
end)

test('an online character the DB does not have yet is still sent', function()
  C.qbox()
  local sink = C.run()
  local row = C.find(sink, 'characters', 'char_id', 'ZZZ99999')
  truthy(row, 'online-only character')
  eq(row.name, 'Nia Okafor')
  eq(C.balances(sink, 'ZZZ99999').bank, 5000)
end)

test('offline characters use the DB values', function()
  C.qbox()
  local sink = C.run()
  eq(C.balances(sink, 'ABC12345').bank, 48200)
  eq(C.find(sink, 'characters', 'char_id', 'ABC12345').job, 'police')
end)

test('when the framework export fails, DB values are used and the summary says so', function()
  C.qbox()
  Stub.export_overrides.GetPlayersData = function() error('qbx_core not ready') end
  local sink, summary = C.run()
  truthy(summary)
  eq(summary.online.state, 'unavailable')
  eq(C.balances(sink, 'CDE34567').bank, 100, 'stale DB value')
  eq(C.find(sink, 'characters', 'char_id', 'ZZZ99999'), nil)
end)

-- ---------------------------------------------------------------------------
-- Balances
-- ---------------------------------------------------------------------------

test('negative bank, custom money types and bad codes', function()
  C.qbcore()
  local sink, summary = C.run()
  local money = C.balances(sink, 'QB000001')
  eq(money.bank, -2350)
  eq(money.casino_chips, 500)
  eq(money.blackmoney, 120, 'lowercased')
  eq(money['dirty-money'], nil)
  eq(summary.skipped.reasons['balances.currency_code_invalid'], 1)
  eq(money.crypto, 0, 'zero balances are sent')
end)

test('Config.currencies rename and skip money types', function()
  C.qbcore()
  Aptic.config.currencies = { rename = { BlackMoney = 'dirty' }, skip = { casino_chips = true } }
  local sink = C.run()
  local money = C.balances(sink, 'QB000001')
  eq(money.dirty, 120)
  eq(money.blackmoney, nil)
  eq(money.casino_chips, nil)
  Aptic.config.currencies = { rename = {}, skip = {} }
end)

test('malformed money JSON: the character is kept with no balances, and counted', function()
  C.qbox()
  local sink, summary = C.run()
  truthy(C.find(sink, 'characters', 'char_id', 'EFG56789'))
  eq(count(C.balances(sink, 'EFG56789')), 0)
  eq(summary.adjusted.money_unreadable, 1)
end)

test('every balance belongs to a character in the snapshot, and (char_id, currency) is unique', function()
  for _, setup in ipairs({ C.qbox, C.qbcore }) do
    Stub.reset()
    setup()
    local sink = C.run()
    local chars, seen = {}, {}
    for _, r in ipairs(C.rows(sink, 'characters')) do
      falsy(chars[r.char_id], 'duplicate char_id ' .. r.char_id)
      chars[r.char_id] = true
    end
    for _, r in ipairs(C.rows(sink, 'balances')) do
      truthy(chars[r.char_id], 'balance for a missing character')
      local key = r.char_id .. '|' .. r.currency
      falsy(seen[key], 'duplicate balance ' .. key)
      seen[key] = true
    end
  end
end)

-- ---------------------------------------------------------------------------
-- txAdmin: created_at and playtime_minutes (D2)
-- ---------------------------------------------------------------------------

test('created_at and playtime from txAdmin, per player, applied to each character', function()
  C.qbox()
  local sink = C.run()
  local a = C.find(sink, 'characters', 'char_id', 'ABC12345')
  local b = C.find(sink, 'characters', 'char_id', 'BCD23456')
  eq(a.created_at, '2026-03-01T00:00:00Z'); eq(a.playtime_minutes, 1290)
  eq(b.created_at, '2026-03-01T00:00:00Z'); eq(b.playtime_minutes, 1290)
  local c = C.find(sink, 'characters', 'char_id', 'CDE34567')
  eq(c.created_at, '2026-04-01T00:00:00Z'); eq(c.playtime_minutes, 845)
end)

test('QBCore license: and txAdmin playTime 0 is a real zero', function()
  C.qbcore()
  local sink = C.run()
  local d = C.find(sink, 'characters', 'char_id', 'QB000001')
  eq(d.created_at, '2025-10-09T00:00:00Z'); eq(d.playtime_minutes, 5400)
  eq(C.find(sink, 'characters', 'char_id', 'QB000002').playtime_minutes, 0)
end)

test('unknown stays unknown: not in txAdmin, non-integer playTime, first join after last seen', function()
  C.qbox()
  local sink, summary = C.run()
  local e = C.find(sink, 'characters', 'char_id', 'EFG56789')
  eq(e.created_at, nil); eq(e.playtime_minutes, nil)
  local d = C.find(sink, 'characters', 'char_id', 'DEF45678')
  eq(d.playtime_minutes, nil, 'playTime 12.5 is not sent')
  eq(d.created_at, '2026-02-14T12:00:00Z')
  local old = C.find(sink, 'characters', 'char_id', 'FGH00001')
  eq(old.created_at, nil, 'joined txAdmin after this character was last seen')
  eq(old.playtime_minutes, 30)
  eq(summary.adjusted.created_at_after_last_seen, 1)
  for _, row in ipairs(C.rows(sink, 'characters')) do
    if row.created_at then
      truthy(Aptic.time.parse_iso(row.created_at) <= Aptic.time.parse_iso(row.last_seen_at), 'created_at <= last_seen_at')
    end
  end
end)

local function no_txadmin_values(sink)
  for _, row in ipairs(C.rows(sink, 'characters')) do
    eq(row.created_at, nil, row.char_id)
    eq(row.playtime_minutes, nil, row.char_id)
  end
end

test('txAdmin not running: created_at and playtime are null for everyone', function()
  C.qbox({ txadmin = false })
  local sink, summary = C.run()
  eq(summary.txadmin.state, 'not_running')
  no_txadmin_values(sink)
  contains(Stub.output(), 'txAdmin player data not available (not_running)')
end)

test('txAdmin running but its file is missing or unreadable: null, never invented', function()
  C.qbox()
  Stub.convars.txDataPath = 'tests/fixtures/no-such-txData'
  local sink, summary = C.run()
  eq(summary.txadmin.state, 'absent')
  no_txadmin_values(sink)
  Stub.reset()
  C.qbox()
  Stub.convars.txDataPath = 'tests/fixtures'
  Stub.convars.serverProfile = 'txData'   -- tests/fixtures/txData/data/playersDB.json does not exist
  sink, summary = C.run()
  eq(summary.txadmin.state, 'absent')
  no_txadmin_values(sink)
end)

test('Config.txadmin: disabled, or an explicit players_db path', function()
  C.qbox({ txadmin = false })
  Aptic.config.txadmin = { enabled = true, players_db = 'tests/fixtures/txData/default/data/playersDB.json' }
  local sink, summary = C.run()
  eq(summary.txadmin.state, 'ok')
  eq(summary.txadmin.source, 'config')
  eq(C.find(sink, 'characters', 'char_id', 'ABC12345').playtime_minutes, 1290)
  Aptic.config.txadmin = { enabled = false, players_db = '' }
  sink, summary = C.run()
  eq(summary.txadmin.state, 'disabled')
  no_txadmin_values(sink)
  Aptic.config.txadmin = { enabled = true, players_db = '' }
end)

-- ---------------------------------------------------------------------------
-- Vehicles
-- ---------------------------------------------------------------------------

test('vehicle state codes, nullable garage, impounded', function()
  C.qbox()
  local sink = C.run()
  local garaged = C.find(sink, 'vehicles', 'plate', 'LSPD 042')
  eq(garaged.state, 'garaged'); eq(garaged.stored, true); eq(garaged.garage, 'mrpd')
  local out = C.find(sink, 'vehicles', 'plate', 'MRC 1994')
  eq(out.state, 'out'); eq(out.stored, false); eq(out.garage, nil)
  local impounded = C.find(sink, 'vehicles', 'plate', 'JUN 77')
  eq(impounded.state, 'impounded'); eq(impounded.stored, false); eq(impounded.garage, nil)
  eq(C.find(sink, 'vehicles', 'plate', 'HASH 01').model, '3078201489', 'model falls back to hash')
end)

test('unknown state codes are skipped and counted', function()
  C.qbox()
  local sink, summary = C.run()
  eq(C.find(sink, 'vehicles', 'plate', 'LENA 99'), nil)
  eq(summary.skipped.reasons['vehicles.state_unknown'], 1)
end)

test('duplicate plates (QBCore): trimmed and uppercased, the highest id kept, counted', function()
  C.qbcore()
  local sink, summary = C.run()
  local n = 0
  for _, r in ipairs(C.rows(sink, 'vehicles')) do if r.plate == 'DUPE 01' then n = n + 1 end end
  eq(n, 1)
  local kept = C.find(sink, 'vehicles', 'plate', 'DUPE 01')
  eq(kept.model, 'zentorno', 'id 14 beats id 10')
  eq(kept.state, 'impounded')
  eq(kept.owner_char_id, 'QB000002')
  eq(summary.skipped.reasons['vehicles.plate_duplicate'], 1)
  eq(summary.skipped.reasons['vehicles.plate_invalid'], 1, 'a 36-character plate')
end)

test('vehicle owners always reference a sent character (case-insensitive match, else null)', function()
  C.qbox()
  local sink, summary = C.run()
  eq(C.find(sink, 'vehicles', 'plate', 'BATI 01').owner_char_id, 'ABC12345', 'abc12345 resolved as MySQL would')
  eq(C.find(sink, 'vehicles', 'plate', 'GONE 01').owner_char_id, nil, 'deleted owner')
  eq(summary.adjusted.vehicle_owner_not_in_snapshot, 1)
  local chars, plates = {}, {}
  for _, r in ipairs(C.rows(sink, 'characters')) do chars[r.char_id] = true end
  for _, r in ipairs(C.rows(sink, 'vehicles')) do
    if r.owner_char_id then truthy(chars[r.owner_char_id], 'owner in snapshot') end
    falsy(plates[r.plate], 'unique plate')
    plates[r.plate] = true
  end
end)

test('a character skipped by validation takes its vehicles\' owner with it, never a dangling reference', function()
  local F = C.qbox()
  F.players[1].citizenid = ('X'):rep(129)  -- too long for the contract
  local sink = C.run()
  eq(C.find(sink, 'characters', 'char_id', F.players[1].citizenid), nil)
  for _, r in ipairs(C.rows(sink, 'balances')) do truthy(r.char_id ~= F.players[1].citizenid) end
end)

test('no player_vehicles table: no vehicles capability, nothing fabricated', function()
  C.qbox({ drop = { player_vehicles = true } })
  local sink = C.run()
  eq(table.concat(sink.meta.capabilities, ','), 'characters,balances,jobs,online_count')
  eq(sink.counts.vehicles, 0)
end)

-- ---------------------------------------------------------------------------
-- Jobs
-- ---------------------------------------------------------------------------

test('Qbox job definitions: integer-keyed, sparse grades kept, a nameless grade defaulted', function()
  C.qbox()
  local sink = C.run()
  local mech = C.find(sink, 'jobs', 'name', 'mechanic')
  eq(mech.kind, 'job'); eq(mech.label, 'Mechanic')
  local levels = {}
  for i, g in ipairs(mech.grades) do levels[i] = g.level end
  eq(table.concat(levels, ','), '0,1,2,4')
  local ems = C.find(sink, 'jobs', 'name', 'ambulance')
  eq(ems.grades[2].level, 3); eq(ems.grades[2].name, 'Grade 3')
  local ballas = C.find(sink, 'jobs', 'name', 'ballas')
  eq(ballas.kind, 'gang'); eq(#ballas.grades, 4)
end)

test('QBCore job definitions: string-keyed grades, a key that is not a level dropped', function()
  C.qbcore()
  local sink, summary = C.run()
  local mech = C.find(sink, 'jobs', 'name', 'mechanic')
  local levels = {}
  for i, g in ipairs(mech.grades) do levels[i] = g.level end
  eq(table.concat(levels, ','), '0,1,3')
  eq(summary.adjusted.grade_level_invalid, 1)
  eq(C.find(sink, 'jobs', 'name', 'police').grades[5].name, 'Chief')
end)

test('(kind, name) is unique and job definitions are not declared when unreadable', function()
  C.qbox()
  local sink = C.run()
  local seen = {}
  for _, r in ipairs(C.rows(sink, 'jobs')) do
    local key = r.kind .. '|' .. r.name
    falsy(seen[key], key)
    seen[key] = true
  end
  Stub.reset()
  C.qbox()
  Stub.export_overrides.GetJobs = function() error('no jobs export') end
  sink = C.run()
  eq(table.concat(sink.meta.capabilities, ','), 'characters,balances,vehicles,online_count')
  eq(sink.counts.jobs, 0)
end)

-- ---------------------------------------------------------------------------
-- Refusals and failures
-- ---------------------------------------------------------------------------

test('no pinned salt: collection refuses before reading anything', function()
  C.qbox({ salt = false })
  Stub.convars.aptic_salt = nil
  local sink, summary, err = C.run()
  eq(summary, nil); eq(err, 'salt_not_pinned')
  eq(#sink.calls, 0, 'sink never started')
  eq(#C.sql, 0, 'no query ran')
  Stub.convars.aptic_salt = 'not a salt'
  sink, summary, err = C.run()
  eq(err, 'salt_not_pinned')
end)

test('unsupported combinations and missing frameworks are refused', function()
  H.server({ framework = 'qbox', inventory = 'qb-inventory' })
  local _, _, err = C.run()
  eq(err, 'unsupported_combination')
  Stub.reset()
  H.server({ framework = 'qbcore', inventory = 'ox_inventory' })
  _, _, err = C.run()
  eq(err, 'unsupported_combination')
  Stub.reset()
  H.server({ framework = 'none', inventory = 'ox_inventory' })
  _, _, err = C.run()
  eq(err, 'framework_not_detected')
end)

test('oxmysql not started: refused', function()
  C.qbox()
  Stub.stop('oxmysql')
  local sink, _, err = C.run()
  eq(err, 'oxmysql_unavailable')
  eq(#sink.calls, 0)
end)

test('a failing query aborts the run and tells the sink to discard', function()
  C.qbox({ fail = 'player_vehicles' })
  local sink, summary, err = C.run()
  eq(summary, nil); eq(err, 'query_failed')
  eq(table.concat(sink.calls, ','), 'begin,abort')
  eq(sink.aborted, 'query_failed')
end)

test('a snapshot over max_rows is not finished', function()
  C.qbox()
  local sink, summary, err = C.run({ max_rows = 10 })
  eq(err, 'snapshot_too_large')
  eq(sink.aborted, 'snapshot_too_large')
  eq(#sink.order, 10)
end)

test('the salt changing mid-run abandons it rather than mixing hash epochs', function()
  C.qbox()
  local hooks = { add = function(collection)
    if collection == 'characters' then Stub.convars.aptic_salt = ('e'):rep(64) end
  end }
  local sink, summary, err = C.run({ page_size = 2 }, hooks)
  eq(summary, nil); eq(err, 'salt_changed')
  eq(sink.aborted, 'salt_changed')
end)

-- ---------------------------------------------------------------------------
-- Paging, yielding, SQL
-- ---------------------------------------------------------------------------

test('keyset pagination: small pages give the same snapshot as one big page', function()
  C.qbox()
  local big = C.run({ page_size = 500 })
  local small = C.run({ page_size = 2 })
  local function strip(sink)
    local copy = json.decode(C.recorded_json(sink))
    copy.meta.taken_at = nil
    for _, r in ipairs(copy.rows.characters) do
      if r.last_seen_at == sink.meta.taken_at then r.last_seen_at = 'taken' end
    end
    return json.encode(copy)
  end
  eq(strip(small), strip(big))
end)

test('every query is a SELECT with a LIMIT, paged by key, and the thread yields per page', function()
  C.qbox()
  local waits = 0
  local real = Wait
  Wait = function(ms) waits = waits + 1; eq(ms, 0) end
  C.run({ page_size = 2 })
  Wait = real
  local players, vehicles = {}, {}
  for _, q in ipairs(C.sql) do
    truthy(q.sql:match('^SELECT '), q.sql)
    truthy(q.sql:find(' LIMIT ', 1, true), q.sql)
    falsy(q.sql:find('*', 1, true), 'no SELECT *')
    if q.sql:find(' FROM players ', 1, true) then players[#players + 1] = q.params end
    if q.sql:find(' FROM player_vehicles ', 1, true) then vehicles[#vehicles + 1] = q.params end
  end
  eq(#players, 4, '7 players in pages of 2')
  eq(players[1][1], ''); eq(players[1][2], 2)
  eq(players[2][1], 'BCD23456', 'cursor = last citizenid of the previous page')
  eq(#vehicles, 4, '7 vehicles in pages of 2')
  eq(vehicles[2][1], 2, 'cursor = last id')
  truthy(waits >= #players + #vehicles, 'yielded after every page: ' .. waits)
end)

test('the players query never reads position, phone, metadata, inventory or the account name', function()
  C.qbox()
  C.run()
  for _, q in ipairs(C.sql) do
    if q.sql:find(' FROM players ', 1, true) then
      for _, col in ipairs({ 'position', 'phone_number', 'metadata', 'inventory', ' name' }) do
        not_contains(q.sql, col)
      end
      contains(q.sql, 'UNIX_TIMESTAMP(last_logged_out)')
    end
    if q.sql:find(' FROM player_vehicles ', 1, true) then
      for _, col in ipairs({ 'mods', 'coords', 'fakeplate', 'license' }) do not_contains(q.sql, col) end
    end
  end
  Stub.reset()
  C.qbcore()
  C.run()
  for _, q in ipairs(C.sql) do not_contains(q.sql, 'last_logged_out') end
end)

-- ---------------------------------------------------------------------------
-- Privacy (§4.2)
-- ---------------------------------------------------------------------------

local SECRETS = {
  'license', 'steam:', 'discord:', 'fivem:', 'xbl:', 'live:', 'ip:',
  -- license hex from the fixtures
  'a1b2c3d4e5f6', 'c3d4e5f60718', '1a2b3c4d5e6f', '2b3c4d5e6f70', '99887766',
  -- phone, bank account, coordinates, fingerprint, FiveM account names
  '5550142', '5550123', '5550188', '5550177', 'US09', 'US06', '215.31', '-810.12', '-269.4', 'FP-',
  'xXMarcusGamerXx', 'DarioFiveM', 'RosaFiveM', 'JuniperTx', 'MarcusTx', 'QBGamer',
  -- txAdmin notes and actions
  'VDM', 'warned',
}

test('no license, identifier, IP, phone or coordinate in any row, meta or log line', function()
  for _, setup in ipairs({ C.qbox, C.qbcore }) do
    Stub.reset()
    setup()
    Stub.convars.aptic_debug = '1'
    local sink, summary = C.run()
    local text = C.recorded_json(sink, summary) .. '\n' .. Stub.output()
    for _, s in ipairs(SECRETS) do not_contains(text, s) end
    falsy(text:match('%d+%.%d+%.%d+%.%d+'), 'no IPv4')
    truthy(Stub.output():find('Collected', 1, true), 'the summary was logged')
  end
end)

test('the log shows counts and reason codes only, never names or citizenids', function()
  C.qbox()
  Stub.convars.aptic_debug = '1'
  C.run()
  local out = Stub.output()
  contains(out, 'Collected 8 characters, 21 balances, 6 vehicles, 6 jobs/gangs')
  contains(out, 'vehicles.state_unknown=1')
  for _, s in ipairs({ 'Marcus', 'ABC12345', 'LSPD 042', 'Zoë' }) do not_contains(out, s) end
end)

-- ---------------------------------------------------------------------------
-- Scaled fixtures (the end-to-end test repeats the fixture databases)
-- ---------------------------------------------------------------------------

local function scaled(case)
  local F = case.setup({ copies = 3 })
  eq(F.copies, 3)
  local sink, summary = C.run()
  all_valid(sink)
  eq(summary.counts.characters, case.characters)
  eq(summary.counts.vehicles, case.vehicles)
  eq(keys_of(summary.skipped.reasons), keys_of(case.reasons))
  for k, n in pairs(case.reasons) do eq(summary.skipped.reasons[k], n, k) end
  local ids, plates, hashes = {}, {}, {}
  for _, row in ipairs(C.rows(sink, 'characters')) do
    falsy(ids[row.char_id], row.char_id)
    ids[row.char_id] = true
    hashes[row.player_hash] = true
  end
  for _, row in ipairs(C.rows(sink, 'vehicles')) do falsy(plates[row.plate], row.plate); plates[row.plate] = true end
  -- Licenses differ per copy, so each copy is a different set of players.
  eq(count(hashes), case.players)
  local list = C.identifiers(F)
  truthy(#list > 10, 'identifiers listed')
  local recorded = C.recorded_json(sink)
  for _, v in ipairs(list) do not_contains(recorded, v) end
end

test('Qbox fixture repeated 3 times: every edge case once per copy, keys still unique', function()
  scaled({ setup = C.qbox, characters = 8 + 7 * 2, vehicles = 6 * 3, players = 7 + 6 * 2,
    reasons = { ['vehicles.state_unknown'] = 3 } })
end)

test('QBCore fixture repeated 3 times: every edge case once per copy, keys still unique', function()
  scaled({ setup = C.qbcore, characters = 4 * 3, vehicles = 3 * 3, players = 4 * 3,
    reasons = { ['balances.currency_code_invalid'] = 3, ['vehicles.plate_duplicate'] = 3, ['vehicles.plate_invalid'] = 3 } })
end)
