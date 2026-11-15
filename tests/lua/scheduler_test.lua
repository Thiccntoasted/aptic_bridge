-- The snapshot schedule (D9) and its guards (D8, plan §5.1), and the
-- `aptic upload` commands.

dofile('tests/support/fake_aptic.lua')

local function run_cmd(...)
  Stub.prints = {}
  Aptic.status.command(0, { ... })
  return Stub.output()
end

local function starts(srv) return #srv:requests('start') end

test('slots are an interval apart at a minute kept per install', function()
  UP.setup()
  local offset = Aptic.scheduler.offset_s()
  between(offset, 0, 3599)
  eq(Aptic.store.get_number('snap.slot_offset') % 3600, offset, 'kept in KVP')
  local t = Aptic.time.now()
  local a = Aptic.scheduler.next_slot(t)
  local b = Aptic.scheduler.next_slot(a)
  eq(b - a, 3600)
  truthy(a > t and a - t <= 3600)
  eq((a - offset) % 3600, 0)
  eq(Aptic.scheduler.next_slot(a - 1), a, 'a slot is the first one strictly after')
end)

test('different installs pick different minutes', function()
  local seen = {}
  for i = 1, 6 do
    Stub.kvp = {}
    math.randomseed(i * 7919)
    seen[Aptic.scheduler.offset_s()] = true
  end
  local n = 0
  for _ in pairs(seen) do n = n + 1 end
  truthy(n >= 5, 'offsets should spread')
end)

test('a restart keeps the same minute', function()
  local srv, spec = UP.setup()
  local offset = Aptic.scheduler.offset_s()
  UP.restart(srv, spec)
  eq(Aptic.scheduler.offset_s(), offset)
end)

test('the interval stays within 30 and 240 minutes', function()
  Aptic.config.upload.interval_min = 5
  eq(Aptic.scheduler.interval_s(), 1800)
  Aptic.config.upload.interval_min = 1000
  eq(Aptic.scheduler.interval_s(), 14400)
  Aptic.config.upload.interval_min = 60
  eq(Aptic.scheduler.interval_s(), 3600)
end)

test('snapshots run by themselves, once an hour, at the slot', function()
  local srv = UP.setup()
  UP.until_(function() return #srv.published == 3 end, 4 * 3600)
  eq(#srv.published, 3)
  local s = srv:requests('start')
  local offset = Aptic.scheduler.offset_s()
  for i = 1, 3 do
    local taken = Aptic.time.parse_iso(__json_parse(s[i].body).taken_at)
    between((taken - offset) % 3600, 0, 2, 'starts on its minute')
  end
  between((s[2].at_ms - s[1].at_ms) / 1000, 3598, 3602)
end)

test('no snapshot while the salt is not pinned (D8); heartbeats carry on', function()
  local srv = UP.setup({ server = { salt = false } })
  UP.until_(function() return false end, 2 * 3600 + 60)
  eq(starts(srv), 0)
  truthy(srv.heartbeats > 100)
  contains(Stub.output(), 'Snapshot slot skipped: salt not pinned')
  local _, n = Stub.output():gsub('Snapshot slot skipped', '')
  eq(n, 1, 'said once, not every slot')
  Stub.convars.aptic_salt = H.SALT
  UP.until_(function() return #srv.published == 1 end, 3700)
  eq(#srv.published, 1, 'the next slot after pinning runs')
end)

test('no snapshot on an unsupported framework + inventory', function()
  local srv = UP.setup({ server = { framework = 'qbox', inventory = 'qb-inventory' } })
  UP.until_(function() return false end, 3700)
  eq(starts(srv), 0)
  contains(Stub.output(), 'unsupported combination')
end)

test('no snapshot while Aptic refuses the heartbeat (adapter mismatch)', function()
  local srv = UP.setup()
  srv:fault({ op = 'heartbeat', times = 999, result = FakeAptic.err('adapter_mismatch') })
  UP.until_(function() return false end, 3700)
  eq(starts(srv), 0)
  local ok, why = Aptic.scheduler.request_now()
  falsy(ok)
  eq(why, 'last heartbeat not accepted')
end)

test('the daily guard skips slots at 90 published in 24 h', function()
  local srv = UP.setup()
  UP.tick(0)
  local t = Aptic.time.now()
  local list = {}
  for i = 1, 90 do list[i] = t - 80000 + i * 60 end
  Aptic.store.set_json('snap.published', list)
  local ok, why = Aptic.scheduler.request_now()
  falsy(ok)
  contains(why, '90 snapshots published in the last 24 h')
  table.remove(list, 1)
  Aptic.store.set_json('snap.published', list)
  truthy(Aptic.scheduler.request_now(), '89 is fine')
  UP.until_(function() return #srv.published == 1 end, 30)
  eq(#srv.published, 1)
end)

test('the daily guard frees up as old snapshots age out of the 24 h', function()
  local srv = UP.setup()
  local t = Aptic.time.now()
  local list = {}
  for i = 1, 90 do list[i] = t - 86400 + 1800 + i end -- the oldest ages out in about 30 min
  Aptic.store.set_json('snap.published', list)
  UP.until_(function() return #srv.published == 1 end, 2 * 3600)
  eq(#srv.published, 1)
  truthy(Aptic.time.now() - t >= 1800)
end)

test('the starts guard skips a slot after 3 starts in the hour', function()
  local srv = UP.setup()
  UP.tick(0)
  local t = Aptic.time.now()
  Aptic.store.set_json('snap.starts', { t - 600, t - 300, t - 100 })
  local ok, why = Aptic.scheduler.request_now()
  falsy(ok)
  contains(why, '3 starts sent in the last hour')
end)

test('a slot that comes during an upload is skipped, never a second upload', function()
  Stub.kvp['snap.slot_offset'] = '600' -- the slot comes at 12:10
  local srv = UP.setup({ collector = { characters = 500 } })
  srv:fault({ op = 'chunk', times = 9999, result = { ok = false, status = 0, transport_error = 'network' } })
  UP.tick(0)
  truthy(Aptic.scheduler.request_now())
  UP.until_(function() return Aptic.scheduler.state.last_skip ~= nil end, 700)
  contains(Aptic.scheduler.state.last_skip.reason, 'is still uploading')
  eq(starts(srv), 1)
  srv.faults = {}
  UP.until_(function() return #srv.published == 1 end, 900)
  eq(starts(srv), 1, 'the same upload finished')
end)

test('without a collector: said once at boot, heartbeats run, status says so', function()
  local srv = UP.setup({ collector = false })
  Aptic.collector = nil
  UP.until_(function() return false end, 3 * 3600)
  eq(starts(srv), 0)
  truthy(srv.heartbeats > 150)
  local _, n = Stub.output():gsub('Snapshot collection is not available in this version', '')
  eq(n, 1)
  not_contains(Stub.output(), 'slot skipped')
  contains(run_cmd('status'), 'snapshots       collection not available in this version')
  contains(run_cmd('upload', 'now'), 'Not starting a snapshot: collection is not available in this version.')
  contains(run_cmd('upload', 'status'), 'next slot       none: collection is not available in this version')
end)

test('a collector loaded by the boot thread order is picked up (main.lua)', function()
  H.server()
  UP.freeze()
  local srv = FakeAptic.new()
  UP.connect(srv)
  FakeCollector.install({})
  Stub.threads[1]() -- the boot thread: heartbeat and snapshot loops
  not_contains(Stub.output(), 'Snapshot collection is not available')
  truthy(Aptic.scheduler.state.running)
  eq(#Stub.threads, 3)
end)

-- Commands ------------------------------------------------------------------------

test('aptic upload now runs a snapshot at once', function()
  local srv = UP.setup()
  UP.tick(0)
  contains(run_cmd('upload', 'now'), 'Snapshot queued')
  UP.until_(function() return #srv.published == 1 end, 30)
  eq(#srv.published, 1)
end)

test('aptic upload now respects the guards and says why', function()
  local srv = UP.setup({ server = { salt = false } })
  UP.tick(0)
  contains(run_cmd('upload', 'now'), 'Not starting a snapshot: salt not pinned.')
  UP.tick(1000)
  eq(starts(srv), 0)
end)

test('aptic upload now during an upload says it is busy', function()
  local srv = UP.setup({ collector = { characters = 500 } })
  UP.tick(0)
  run_cmd('upload', 'now')
  UP.tick(1000)
  UP.tick(1000)
  contains(run_cmd('upload', 'now'), 'is still uploading')
end)

test('aptic upload status: state, progress, last result, next slot, quota', function()
  local srv = UP.setup({ collector = { characters = 500 } })
  UP.tick(0)
  local idle = run_cmd('upload', 'status')
  contains(idle, 'upload state    idle')
  contains(idle, 'last result     none yet')
  contains(idle, 'last published  never')
  contains(idle, 'next slot       in ')
  contains(idle, 'quota           0/90 published in 24 h, 0/3 starts this hour')
  run_cmd('upload', 'now')
  for _ = 1, 5 do UP.tick(1000) end
  local busy = run_cmd('upload', 'status')
  truthy(busy:match('upload state    uploading apb%-[%w%-]+ %(%d/12 chunks%)'), busy)
  contains(busy, 'taken at        2026-11-15T12:00:01Z')
  contains(busy, 'next request    chunk in 1 s')
  UP.until_(function() return #srv.published == 1 end, 60)
  local done = run_cmd('upload', 'status')
  truthy(done:match('last result     published apb%-[%w%-]+, 1919 rows, 0 s ago'), done)
  contains(done, 'last published  2026-11-15T12:00:')
  contains(done, ', 1919 rows')
  contains(done, '1/90 published in 24 h, 1/3 starts this hour')
end)

test('aptic upload status shows a dropped snapshot with its code and where', function()
  local srv = UP.setup({ collector = { characters = 500 } })
  srv:fault({ op = 'chunk', collection = 'balances', index = 3, result = FakeAptic.err('invalid_payload') })
  UP.snapshot_now()
  local out = run_cmd('upload', 'status')
  truthy(out:match('last result     dropped apb%-[%w%-]+ %(invalid_payload, balances 3%)'), out)
end)

test('aptic status has the snapshot line', function()
  local srv = UP.setup()
  UP.tick(0)
  contains(run_cmd('status'), 'snapshots       last published never; state idle; next slot in ')
  UP.snapshot_now()
  local out = run_cmd('status')
  truthy(out:match('snapshots       last published 2026%-11%-15T12:00:0%dZ %(%d+ s ago%); state idle; next slot in %d+ min'), out)
end)

test('aptic status lists what blocks snapshots', function()
  UP.setup({ server = { salt = false } })
  UP.tick(0)
  contains(run_cmd('status'), 'blocked by: salt not pinned')
end)

test('aptic upload needs the same ACE as aptic status', function()
  local srv = UP.setup()
  UP.tick(0)
  Aptic.status.command(9, { 'upload', 'now' })
  eq(#Stub.chat, 0)
  eq(Aptic.scheduler.state.requested, nil, 'nothing queued for a player without the ACE')
  Stub.aces['9:command.aptic'] = true
  Aptic.status.command(9, { 'upload', 'now' })
  contains(Stub.chat[1].payload.args[2], 'Snapshot queued')
end)

test('unknown upload subcommands print usage', function()
  UP.setup()
  contains(run_cmd('upload', 'later'), 'usage: aptic upload now | aptic upload status')
  contains(run_cmd('bogus'), 'aptic upload now | aptic upload status')
end)
