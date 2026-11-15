-- `aptic validate [--verbose]` (server/selfcheck.lua): the real collector
-- over the fixture databases into the checking sink, with nothing uploaded;
-- the whole-snapshot rules on hand-made bad snapshots; and the automatic
-- run after a snapshot_invalid answer.

dofile('tests/support/collect.lua')

--- Run `aptic validate ...` from `source` and its thread; returns the output.
local function validate(source, ...)
  Stub.prints = {}
  Stub.chat = {}
  Aptic.status.command(source, { 'validate', ... })
  local thread = table.remove(Stub.threads)
  truthy(type(thread) == 'function', 'validate runs in a thread')
  thread()
  return Stub.output()
end

local function chat_text()
  local out = {}
  for _, m in ipairs(Stub.chat) do out[#out + 1] = m.payload.args[2] end
  return table.concat(out, '\n')
end

-- Values from the fixtures that must never be printed.
local IDENTIFIERS = {
  'ABC12345', 'BCD23456', 'CDE34567', 'DEF45678', 'QB000001', 'QB000002', 'license', 'a1b2c3d4e5f6',
  '1a2b3c4d5e6f', 'LENA 99', 'DUPE 01', 'THISPLATE', 'xXMarcusGamerXx', 'DarioFiveM', '5550142', '5550188',
  'FP-77AC', 'US0912345678', H.SALT, H.KEY:sub(17),
}
local NAMES = { 'Marcus Reyes', 'Lena Novak', 'Old Timer', 'Clock Skew', 'Dario Conti', 'Juniper Hale' }

local function no_identifiers(out)
  for _, needle in ipairs(IDENTIFIERS) do not_contains(out, needle) end
end

-- Real collector, fixture databases --------------------------------------------

test('Qbox: counts, chunks and skipped reasons; nothing sent, nothing cached, no upload state', function()
  C.qbox()
  local sent = H.fake_transport({ H.OK })
  local out = validate(0)
  contains(out, 'aptic validate  a local check: nothing was uploaded')
  contains(out, 'would send      41 rows (characters 8, balances 21, vehicles 6, jobs 6) in 4 chunks')
  contains(out, 'vehicles.state_unknown')
  contains(out, 'player_vehicles.state is not 0 (out), 1 (garaged) or 2 (impounded)')
  contains(out, 'last_seen_clamped')
  contains(out, 'snapshot rules  ok: no duplicate keys, missing references or time-order problems')
  contains(out, 'result          ok: Aptic would accept this snapshot')
  contains(out, 'Run `aptic validate --verbose` on the server console')
  eq(#sent, 0, 'no request')
  eq(#Aptic.store.list(), 0, 'no cache folder')
  eq(Aptic.uploader.state.rec, nil)
  eq(Stub.kvp['snap.current'], nil)
  eq(Aptic.selfcheck.state.running, false)
  eq(Aptic.selfcheck.state.last.ok, true)
  for _, name in ipairs(NAMES) do not_contains(out, name) end
  no_identifiers(out)
end)

test('the counts are the collector\'s, and every query was a SELECT', function()
  C.qbox()
  local report = Aptic.selfcheck.run({})
  local _, summary = C.run()
  for _, c in ipairs(Aptic.collector.COLLECTIONS) do eq(report.counts[c], summary.counts[c], c) end
  for _, q in ipairs(C.sql) do truthy(q.sql:match('^SELECT '), q.sql) end
end)

test('QBCore: duplicate plates, an over-long plate and a bad money code are reported', function()
  C.qbcore()
  local out = validate(0)
  contains(out, 'would send      26 rows (characters 4, balances 14, vehicles 3, jobs 5)')
  contains(out, 'skipped rows    3')
  contains(out, 'balances.currency_code_invalid')
  contains(out, 'vehicles.plate_duplicate')
  contains(out, 'vehicles.plate_invalid')
  contains(out, 'result          ok')
  no_identifiers(out)
  not_contains(out, 'Dario Conti')
end)

test('--verbose on the console names the characters behind each reason, never an identifier', function()
  C.qbox()
  local out = validate(0, '--verbose')
  contains(out, 'vehicles.state_unknown')
  contains(out, '      Lena Novak')
  contains(out, '      Old Timer')
  contains(out, '      Clock Skew')
  not_contains(out, 'Run `aptic validate --verbose`')
  no_identifiers(out)

  C.qbcore()
  out = validate(0, '-v')
  contains(out, '      Dario Conti')
  no_identifiers(out)
end)

test('pseudonymize on: --verbose shows the pseudonyms that are sent, not the RP names', function()
  C.qbox()
  Aptic.config.pseudonymize = true
  local out = validate(0, '--verbose')
  contains(out, 'vehicles.state_unknown')
  truthy(out:match('      Character %x%x%x%x%x%x%x%x'), out)
  not_contains(out, 'Lena Novak')
end)

test('in game: --verbose is refused, counts only, and only with the ACE', function()
  C.qbox()
  Stub.aces['5:command.aptic'] = true
  validate(5, '--verbose')
  local text = chat_text()
  contains(text, 'would send')
  contains(text, '--verbose works only on the server console')
  for _, name in ipairs(NAMES) do not_contains(text, name) end
  no_identifiers(text)

  Stub.chat = {}
  local before = #Stub.threads
  Aptic.status.command(6, { 'validate' })
  eq(#Stub.threads, before, 'no ACE, nothing runs')
  eq(#Stub.chat, 0)
end)

test('no pinned salt: not checked, and says what to do', function()
  C.qbox({ salt = false })
  local out = validate(0)
  contains(out, 'not checked: aptic_salt is not pinned')
  contains(out, '(salt_not_pinned)')
end)

test('a second run while one is going, or during a snapshot collection, is refused', function()
  C.qbox()
  Aptic.selfcheck.state.running = true
  eq(Aptic.selfcheck.run({}).error, 'already_running')
  Aptic.selfcheck.state.running = false
  Aptic.scheduler.state.collecting = true
  eq(Aptic.selfcheck.run({}).error, 'snapshot_collecting')
  Aptic.scheduler.state.collecting = false
end)

test('while it runs, the scheduler starts no snapshot', function()
  C.qbox()
  Aptic.selfcheck.state.running = true
  contains(Aptic.scheduler.guard() or '', 'aptic validate is running')
  Aptic.selfcheck.state.running = false
end)

-- The whole-snapshot rules -------------------------------------------------------

local TAKEN = '2026-11-15T12:00:00Z'
local function hash(i) return (('%08x'):format(i)):rep(8) end
local function char(id, name, extra)
  local row = { char_id = id, player_hash = hash(#id), name = name, job = 'unemployed', job_grade = 0,
    last_seen_at = '2026-11-15T11:00:00Z' }
  for k, v in pairs(extra or {}) do row[k] = v end
  return row
end

--- A collector that sends exactly `rows` ({ {collection, row}, ... }).
local function fake_collector(rows)
  Aptic.collector.run = function(sink)
    sink:begin({ taken_at = TAKEN, capabilities = Aptic.common.array({ 'characters', 'balances', 'vehicles', 'jobs' }),
      framework = 'qbox', inventory = 'ox_inventory', salt_fp = '49224dd5' })
    local counts = {}
    for _, c in ipairs(Aptic.collector.COLLECTIONS) do counts[c] = 0 end
    for _, r in ipairs(rows) do
      sink:add(r[1], r[2])
      counts[r[1]] = counts[r[1]] + 1
    end
    sink:finish(counts)
    return { skipped = { reasons = {} }, adjusted = {}, counts = counts, txadmin = { state = 'missing' } }
  end
end

test('duplicate keys, missing references and time order are found, as Aptic\'s finalize would', function()
  C.qbox()
  fake_collector({
    { 'characters', char('c1', 'Ann Able') },
    { 'characters', char('c1', 'Ann Again') },                                          -- duplicate char_id
    { 'characters', char('c2', 'Ben Late', { last_seen_at = '2026-11-15T12:05:00Z' }) }, -- > taken_at + 2 min
    { 'characters', char('c3', 'Cy Early', { created_at = '2026-11-15T11:30:00Z' }) },  -- created after last seen
    { 'characters', char('c4', 'Di Edge', { last_seen_at = '2026-11-15T12:02:00Z' }) },  -- exactly + 2 min: fine
    { 'balances', { char_id = 'c1', currency = 'cash', amount = 10 } },
    { 'balances', { char_id = 'c1', currency = 'cash', amount = 20 } },                -- duplicate (char_id, currency)
    { 'balances', { char_id = 'ghost', currency = 'bank', amount = 5 } },              -- no such character
    { 'vehicles', { plate = 'AB 1', model = 'adder', owner_char_id = 'c2', state = 'garaged' } },
    { 'vehicles', { plate = 'AB 1', model = 'adder', state = 'out' } },                 -- duplicate plate
    { 'vehicles', { plate = 'AB 2', model = 'adder', owner_char_id = 'nobody', state = 'out' } }, -- missing owner
    { 'jobs', { kind = 'job', name = 'police', label = 'LSPD', grades = {} } },
    { 'jobs', { kind = 'gang', name = 'police', label = 'Not a dup', grades = {} } },   -- different kind: fine
  })
  local report = Aptic.selfcheck.run({ verbose = true })
  eq(report.ok, false)
  local f = report.findings
  eq(f['characters.duplicate_key'], 1)
  eq(f['characters.time_order'], 2)
  eq(f['balances.duplicate_key'], 1)
  eq(f['balances.missing_reference'], 1)
  eq(f['vehicles.duplicate_key'], 1)
  eq(f['vehicles.missing_reference'], 1)
  eq(f['jobs.duplicate_key'], nil)
  eq(report.problems, 7)

  local out = table.concat(Aptic.selfcheck.lines(report, { verbose = true }), '\n')
  contains(out, 'snapshot rules  7 problems Aptic would reject (snapshot_invalid)')
  contains(out, 'characters.time_order')
  contains(out, 'Ben Late, Cy Early')
  contains(out, 'Ann Again')
  contains(out, 'Aptic would reject this snapshot. This is a bug in aptic_bridge')
  not_contains(out, 'ghost')
  not_contains(out, 'AB 1')
  not_contains(out, 'nobody')

  local plain = table.concat(Aptic.selfcheck.lines(report, {}), '\n')
  not_contains(plain, 'Ben Late')
  contains(plain, 'balances.missing_reference')
end)

test('a row that fails validate.lua and a chunker failure are findings too, the chunker one once', function()
  C.qbox()
  local rows = { { 'characters', char('c1', 'Ann Able', { job_grade = -1 }) } }
  -- Four chunks of characters with the index limit lowered to 2.
  for i = 2, 4 * 200 do rows[#rows + 1] = { 'characters', char('x' .. i, 'P ' .. i) } end
  fake_collector(rows)
  Aptic.config.upload.max_chunk_index = 2
  local report = Aptic.selfcheck.run({})
  eq(report.findings['characters.invalid_job_grade'], 1)
  eq(report.findings['characters.chunker_too_many_chunks'], 1)
end)

test('the chunk count matches what the upload engine writes for the same rows', function()
  dofile('tests/support/fake_aptic.lua')
  local srv = UP.setup({ collector = { characters = 500 } })
  local report = Aptic.selfcheck.run({})
  eq(report.chunks, 12)
  eq(report.total, 1919)
  UP.snapshot_now()
  eq(#srv.published, 1)
  local chunks = 0
  for _, r in ipairs(srv.log) do if r.op == 'chunk' then chunks = chunks + 1 end end
  eq(chunks, report.chunks)
end)

-- After snapshot_invalid -----------------------------------------------------------

test('snapshot_invalid runs the check by itself and logs counts and reasons, no names', function()
  dofile('tests/support/fake_aptic.lua')
  local srv = UP.setup({ collector = { characters = 40 } })
  srv:fault({ op = 'finalize', result = FakeAptic.err('snapshot_invalid', nil, { collection = 'vehicles', reason = 'duplicate_key' }) })
  UP.snapshot_now()
  contains(Stub.output(), 'snapshot_invalid, vehicles duplicate_key')
  local thread = table.remove(Stub.threads)
  truthy(type(thread) == 'function', 'a check was queued')
  local requests = #srv.log
  Stub.prints = {}
  thread()
  local out = Stub.output()
  contains(out, 'Checked the data locally after snapshot_invalid (vehicles duplicate_key) (aptic validate):')
  contains(out, 'would send      ')
  contains(out, 'snapshot rules  ok')
  not_contains(out, 'Test Person')
  not_contains(out, 'char-0')
  eq(#srv.log, requests, 'the check sent nothing')
  eq(#Aptic.store.list(), 0)
  eq(Aptic.selfcheck.after_rejection('vehicles') and Aptic.selfcheck.after_rejection('vehicles'), false,
    'one queued check at a time')
end)
