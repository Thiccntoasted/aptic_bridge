-- Whole snapshots through the engine: fake collector -> chunker -> chunk
-- files -> uploader -> fake Aptic, on a fake clock. Covers the plan §5.2
-- state machine, restart resume, pacing, key rotation and the §5.3 answers
-- that need more than one request to show.

dofile('tests/support/fake_aptic.lua')

local BIG = { characters = 500 } -- 1919 rows, 12 chunks: characters 3, balances 6, vehicles 2, jobs 1

local function U() return Aptic.uploader.state end
local function ops(srv)
  local out = {}
  for _, r in ipairs(srv.log) do
    if r.op ~= 'heartbeat' then out[#out + 1] = r.op .. (r.collection and (':' .. r.collection .. '.' .. r.index) or '') end
  end
  return table.concat(out, ' ')
end
local function chunk_keys(srv, from)
  local out = {}
  for i = from or 1, #srv.log do
    local r = srv.log[i]
    if r.op == 'chunk' then out[#out + 1] = r.collection .. '.' .. r.index end
  end
  return out
end
local function count(list, pred)
  local n = 0
  for _, v in ipairs(list) do if pred(v) then n = n + 1 end end
  return n
end
local function codes(srv)
  local out = {}
  for _, r in ipairs(srv.log) do out[#out + 1] = r.op end
  return out
end
local function cache_folders() return Aptic.store.list() end
local function start_now()
  UP.tick(0)
  truthy(Aptic.scheduler.request_now())
end

-- The happy path ----------------------------------------------------------------

test('heartbeat, start, every chunk once, finalize: published', function()
  local srv = UP.setup({ collector = BIG })
  truthy(UP.snapshot_now())
  eq(#srv.published, 1)
  local seq = ops(srv)
  truthy(seq:match('^start chunk:characters%.0 '), seq)
  truthy(seq:match(' finalize$'), seq)
  local keys = chunk_keys(srv)
  eq(#keys, 12, seq)
  local seen = {}
  for _, k in ipairs(keys) do falsy(seen[k], 'sent twice: ' .. k); seen[k] = true end
  eq(srv.heartbeats >= 1, true)
  local out = Stub.output()
  contains(out, 'collected in 0 s: 1919 rows in 12 chunks (characters 500, balances 1166, vehicles 250, jobs 3). Uploading.')
  contains(out, 'published: 1919 rows in 12 chunks')
end)

test('the start body has the frozen fields and the bridge envelope', function()
  local srv = UP.setup()
  UP.snapshot_now()
  local start = __json_parse(srv:requests('start')[1].body)
  eq(start.version, 1)
  eq(start.source, 'bridge')
  eq(start.framework, 'qbox')
  eq(start.inventory, 'ox_inventory')
  eq(start.agent_version, 'aptic_bridge/0.1.0')
  eq(start.salt_fp, '49224dd5')
  eq(start.instance_id, Aptic.identity.instance_id())
  truthy(start.snapshot_id:match('^apb%-%d%d%d%d%d%d%d%dT%d%d%d%d%d%dZ%-%x%x%x%x$'), start.snapshot_id)
  eq(start.taken_at, '2026-11-15T12:00:01Z')
  eq(start.manifest.characters, 30)
  eq(start.manifest.containers, 0)
  eq(start.online_count, nil)
  eq(srv:requests('start')[1].timeout_ms, 30000)
  eq(srv:requests('finalize')[1].timeout_ms, 120000)
end)

test('after publishing, the cache folder and the KVP state are gone', function()
  UP.setup()
  UP.snapshot_now()
  eq(#cache_folders(), 0)
  eq(Stub.kvp['snap.current'], nil)
  eq(Stub.kvp['snap.state'], nil)
  local lp = Aptic.store.get_json('snap.last_published')
  eq(lp.rows, 118)
  eq(Aptic.store.count('snap.published', Aptic.time.now(), 86400), 1)
end)

test('chunk files hold exactly the rows array the request carries', function()
  local srv = UP.setup({ collector = BIG })
  start_now()
  UP.until_(function() return #srv:requests('chunk') >= 1 end, 20)
  local id = U().rec.id
  local file = Aptic.store.read(id, 'characters.0.json')
  eq(srv:requests('chunk')[1].body, Aptic.chunker.chunk_body(id, 'characters', 0, file))
  local manifest = Aptic.chunker.decode(Aptic.store.read(id, 'manifest.json'))
  eq(manifest.chunks.balances, 6)
  eq(manifest.rows, 1919)
  eq(Aptic.store.read(id, 'start.json'), srv:requests('start')[1].body)
end)

test('pacing: never more than one upload request a second', function()
  local srv = UP.setup({ collector = BIG })
  UP.snapshot_now()
  local last
  for _, r in ipairs(srv.log) do
    if r.op ~= 'heartbeat' then
      if last then truthy(r.at_ms - last >= 1000, ('requests %d ms apart'):format(r.at_ms - last)) end
      last = r.at_ms
    end
  end
end)

test('a run of 12 chunks takes about 14 s of upload requests', function()
  local srv = UP.setup({ collector = BIG })
  local took = UP.snapshot_now()
  between(took, 14, 16)
end)

test('snapshot ids are new for every run, and taken_at strictly increases', function()
  local srv = UP.setup()
  UP.snapshot_now()
  UP.until_(function() return #srv.published == 2 end, 2 * 3600)
  local a = __json_parse(srv:requests('start')[1].body)
  local b = __json_parse(srv:requests('start')[2].body)
  truthy(a.snapshot_id ~= b.snapshot_id)
  truthy(Aptic.time.parse_iso(b.taken_at) > Aptic.time.parse_iso(a.taken_at))
  eq(#srv.published, 2)
end)

test('taken_at follows Aptic\'s clock when this machine\'s clock is off', function()
  local srv, spec = UP.setup()
  Stub.epoch = Stub.epoch - 300 -- local clock 5 min slow
  srv.apply_orig = srv.apply
  local real_now = function() return Stub.epoch + 300 end
  function srv:apply(p, body)
    if p.operation == 'heartbeat' then
      self.heartbeats = self.heartbeats + 1
      return FakeAptic.ok({ server_time = Aptic.time.iso(real_now()) })
    end
    return self:apply_orig(p, body)
  end
  UP.tick(0)
  between(Aptic.heartbeat.state.clock_offset_s, 299, 301)
  truthy(Aptic.scheduler.request_now())
  UP.tick(1000)
  local opts = spec.runs[1]
  between(Aptic.time.parse_iso(opts.taken_at) - real_now(), -2, 2)
  between(opts.clock_offset_s, 299, 301)
  local start = __json_parse(srv:requests('start')[1].body)
  eq(start.taken_at, opts.taken_at, 'what the collector was given is what start says')
end)

-- Restart resume (plan §5.2) -------------------------------------------------------

test('killed mid-upload: resumes from KVP and files, sends only what is missing, same bytes', function()
  local srv, spec = UP.setup({ collector = BIG })
  start_now()
  UP.until_(function() return #srv:requests('chunk') >= 4 end, 60)
  local id = U().rec.id
  local first_run = #srv.log
  local sent_before = chunk_keys(srv)
  -- Every body this snapshot may ever send, from its files on disk.
  local expected = {}
  for c, n in pairs(U().rec.chunks) do
    for i = 0, n - 1 do
      expected[c .. '.' .. i] = Aptic.chunker.chunk_body(id, c, i, Aptic.store.read(id, ('%s.%d.json'):format(c, i)))
    end
  end

  UP.restart(srv, spec)
  eq(U().rec.id, id, 'the same snapshot')
  eq(U().need, 'status')
  contains(Stub.output(), 'Resuming snapshot ' .. id .. ' (uploading): asking Aptic which chunks it has.')
  UP.until_(function() return #srv.published == 1 end, 120)

  local after = {}
  for i = first_run + 1, #srv.log do
    if srv.log[i].op ~= 'heartbeat' then after[#after + 1] = srv.log[i] end
  end
  eq(after[1].op, 'status', 'status first after a restart')
  local resent = chunk_keys(srv, first_run + 1)
  eq(#resent, 12 - #sent_before, 'only the missing chunks')
  for _, k in ipairs(resent) do
    for _, b in ipairs(sent_before) do truthy(k ~= b, 'resent an acknowledged chunk ' .. k) end
  end
  for _, r in ipairs(srv:requests('chunk')) do
    eq(r.body, expected[r.collection .. '.' .. r.index], 'body of ' .. r.collection .. '.' .. r.index)
  end
  eq(count(codes(srv), function(c) return c == 'start' end), 1, 'no second start')
  eq(#srv.published, 1)
  eq(#cache_folders(), 0)
end)

test('killed with a chunk applied but its answer lost: no resend, no conflict', function()
  local srv, spec = UP.setup({ collector = BIG })
  srv:fault({ op = 'chunk', collection = 'balances', index = 1, after = true,
    result = { ok = false, status = 0, transport_error = 'timeout' } })
  start_now()
  UP.until_(function() return #srv:requests('chunk') >= 5 end, 60) -- balances.1 is the 5th
  local id = U().rec.id
  UP.restart(srv, spec)
  UP.until_(function() return #srv.published == 1 end, 120)
  eq(count(chunk_keys(srv), function(k) return k == 'balances.1' end), 1)
  eq(#srv.published, 1)
end)

test('every chunk resent after a restart is the same bytes as before (replay, not conflict)', function()
  -- The fake Aptic refuses a replay that differs by a single byte.
  local srv, spec = UP.setup({ collector = BIG })
  start_now()
  UP.until_(function() return #srv:requests('chunk') >= 3 end, 60)
  local first = {}
  for _, r in ipairs(srv:requests('chunk')) do first[r.collection .. r.index] = r.body end
  -- Status "forgets" the acknowledgements once, so the restarted bridge
  -- resends the three Aptic already holds. Aptic keeps them and compares.
  UP.restart(srv, spec)
  srv:fault({ op = 'status', times = 1, result = FakeAptic.ok({ status = 'uploading', received = {} }) })
  UP.until_(function() return #srv.published == 1 end, 120)
  local replays = 0
  for i, r in ipairs(srv:requests('chunk')) do
    if i > 3 and first[r.collection .. r.index] then
      replays = replays + 1
      eq(r.body, first[r.collection .. r.index], r.collection .. r.index)
    end
  end
  eq(replays, 3, 'the three acknowledged chunks were sent again')
  eq(#srv:requests('chunk'), 15)
  eq(#srv.published, 1, 'no request_conflict')
end)

test('killed after collecting, before start: the restart sends the same start', function()
  local srv, spec = UP.setup({ collector = BIG })
  srv:fault({ op = 'start', result = { ok = false, status = 0, transport_error = 'network' } })
  start_now()
  UP.tick(1000)
  eq(U().rec.phase, 'collected')
  local body = Aptic.store.read(U().rec.id, 'start.json')
  UP.restart(srv, spec)
  eq(U().need, 'start')
  contains(Stub.output(), 'collected, not yet started')
  UP.until_(function() return #srv.published == 1 end, 120)
  eq(srv:requests('start')[2].body, body)
end)

test('killed after start was applied but before the answer: start replays, then status', function()
  local srv, spec = UP.setup({ collector = BIG })
  srv:fault({ op = 'start', after = true, result = { ok = false, status = 0, transport_error = 'timeout' } })
  start_now()
  UP.tick(1000)
  UP.restart(srv, spec)
  UP.until_(function() return #srv.published == 1 end, 120)
  local seq = ops(srv)
  truthy(seq:match('^start start status chunk'), seq)
end)

test('killed while collecting: the partial snapshot is dropped and its files deleted', function()
  local srv, spec = UP.setup({ collector = BIG })
  UP.tick(0)
  -- A collector that stops half way, as a crash would.
  Aptic.collector = { run = function(sink, opts)
    sink:begin({ taken_at = opts.taken_at, capabilities = { 'characters' }, framework = 'qbox', inventory = 'ox_inventory' })
    for i = 1, 450 do sink:add('characters', { char_id = 'c' .. i }) end
    error('server stopped')
  end }
  -- Play the crash: record the state that would be on disk mid-collection.
  local id
  local inner = Aptic.collector.run
  Aptic.collector.run = function(sink, opts)
    id = opts.snapshot_id
    pcall(inner, sink, opts)
    UP.restart(srv, spec)
    error('never reached')
  end
  pcall(Aptic.uploader.collect, {})
  eq(U().rec, nil)
  eq(#cache_folders(), 0)
  contains(Stub.output(), 'Snapshot ' .. id .. ' dropped (interrupted_collection)')
end)

test('a collected snapshot older than 23 h is dropped on restart', function()
  local srv, spec = UP.setup()
  srv:fault({ op = 'start', times = 99, result = { ok = false, status = 0, transport_error = 'network' } })
  start_now()
  UP.tick(1000)
  eq(U().rec.phase, 'collected')
  Stub.epoch = Stub.epoch + 23 * 3600 + 60
  srv.faults = {}
  UP.restart(srv, spec)
  eq(U().rec, nil)
  eq(Aptic.uploader.state.last.code, 'stale_snapshot')
end)

test('an upload started more than 55 min before the restart is dropped', function()
  local srv, spec = UP.setup({ collector = BIG })
  start_now()
  UP.until_(function() return #srv:requests('chunk') >= 2 end, 30)
  Stub.epoch = Stub.epoch + 56 * 60
  UP.restart(srv, spec)
  eq(U().rec, nil)
  eq(U().last.code, 'resume_expired')
  eq(#cache_folders(), 0)
end)

test('an upload started under 55 min before the restart resumes', function()
  local srv, spec = UP.setup({ collector = BIG })
  start_now()
  UP.until_(function() return #srv:requests('chunk') >= 2 end, 30)
  Stub.epoch = Stub.epoch + 50 * 60
  UP.restart(srv, spec)
  truthy(U().rec)
  UP.until_(function() return #srv.published == 1 end, 120)
  eq(#srv.published, 1)
end)

test('a restart with a different key drops the interrupted upload', function()
  local srv, spec = UP.setup({ collector = BIG })
  start_now()
  UP.until_(function() return #srv:requests('chunk') >= 2 end, 30)
  Stub.convars.aptic_api_key = H.KEY2
  UP.restart(srv, spec)
  eq(U().rec, nil)
  eq(U().last.code, 'key_changed')
end)

test('a salt changed between collection and resume drops the snapshot', function()
  local srv, spec = UP.setup({ collector = BIG })
  start_now()
  UP.until_(function() return #srv:requests('chunk') >= 2 end, 30)
  Stub.convars.aptic_salt = ('f'):rep(64)
  UP.restart(srv, spec)
  UP.until_(function() return U().rec == nil end, 90)
  eq(U().last.code, 'salt_changed')
  eq(#srv.published, 0)
end)

test('stray cache folders are deleted at boot', function()
  local srv, spec = UP.setup()
  Aptic.store.write('apb-old-1', 'characters.0.json', '[]')
  Aptic.store.write('apb-old-2', 'start.json', '{}')
  eq(#cache_folders(), 2)
  UP.restart(srv, spec)
  eq(#cache_folders(), 0)
end)

test('a missing chunk file drops the snapshot instead of sending something else', function()
  local srv = UP.setup({ collector = BIG })
  start_now()
  UP.until_(function() return #srv:requests('chunk') >= 1 end, 30)
  Aptic.store.remove(U().rec.id)
  UP.until_(function() return U().rec == nil end, 30)
  eq(U().last.code, 'cache_missing')
end)

test('a resumed upload waits for an accepted heartbeat', function()
  local srv, spec = UP.setup({ collector = BIG })
  start_now()
  UP.until_(function() return #srv:requests('chunk') >= 2 end, 30)
  srv:fault({ op = 'heartbeat', times = 3, result = { ok = false, status = 0, transport_error = 'network' } })
  local before = #srv.log
  UP.restart(srv, spec)
  UP.tick(1000)
  UP.tick(1000)
  for i = before + 1, #srv.log do eq(srv.log[i].op, 'heartbeat') end
  contains(Aptic.uploader.describe(), 'waiting for the first accepted heartbeat')
  UP.until_(function() return #srv.published == 1 end, 200)
  eq(#srv.published, 1)
end)

-- Finalize ------------------------------------------------------------------------------

test('finalize times out: status says complete, so nothing is sent again', function()
  local srv = UP.setup()
  srv:fault({ op = 'finalize', after = true, result = { ok = false, status = 0, transport_error = 'timeout' } })
  UP.snapshot_now()
  eq(#srv.published, 1)
  truthy(ops(srv):match('finalize status$'), ops(srv))
  eq(U().last.result, 'published')
end)

test('finalize times out before committing: status, then finalize again', function()
  local srv = UP.setup()
  srv:fault({ op = 'finalize', result = { ok = false, status = 0, transport_error = 'timeout' } })
  UP.snapshot_now()
  eq(#srv.published, 1)
  truthy(ops(srv):match('finalize status finalize$'), ops(srv))
end)

test('upload_incomplete at finalize: status, resend the missing chunk, finalize once more', function()
  local srv = UP.setup({ collector = BIG })
  srv:fault({ op = 'finalize', result = FakeAptic.err('upload_incomplete') })
  -- Aptic lost one chunk (say, staging cleanup): drop it before finalize.
  local orig = srv.handle
  function srv:handle(req)
    local r = orig(self, req)
    local p = __json_parse(req.body or Aptic.chunker.encode(req.payload))
    if p.operation == 'chunk' and p.collection == 'vehicles' and p.index == 1 and not self.dropped then
      self.dropped = true
      self.uploads[p.snapshot_id].chunks['vehicles:001'] = nil
    end
    return r
  end
  UP.snapshot_now()
  eq(#srv.published, 1)
  truthy(ops(srv):match('finalize status chunk:vehicles%.1 finalize$'), ops(srv))
end)

test('upload_incomplete twice: dropped', function()
  local srv = UP.setup()
  srv:fault({ op = 'finalize', times = 2, result = FakeAptic.err('chunk_gap') })
  UP.snapshot_now()
  eq(#srv.published, 0)
  eq(U().last.code, 'chunk_gap')
  eq(count(codes(srv), function(c) return c == 'finalize' end), 2)
end)

-- Transient failures ------------------------------------------------------------------

test('429 rate_limited on a chunk: the same chunk again after retry_after, nothing in between', function()
  local srv = UP.setup({ collector = BIG })
  srv:fault({ op = 'chunk', collection = 'balances', index = 2, result = FakeAptic.err('rate_limited', 20) })
  UP.snapshot_now()
  local log = srv.log
  for i, r in ipairs(log) do
    if r.op == 'chunk' and r.collection == 'balances' and r.index == 2 then
      local nxt
      for j = i + 1, #log do if log[j].op ~= 'heartbeat' then nxt = log[j]; break end end
      eq(nxt.op .. nxt.collection .. nxt.index, 'chunkbalances2')
      between(nxt.at_ms - r.at_ms, 20000, 23000)
      break
    end
  end
  eq(#srv.published, 1)
end)

test('503 on a chunk: back off, ask status, carry on', function()
  local srv = UP.setup({ collector = BIG })
  srv:fault({ op = 'chunk', collection = 'balances', index = 0, times = 2, result = FakeAptic.err('ingest_unavailable') })
  UP.snapshot_now()
  local seq = ops(srv)
  truthy(seq:find('chunk:balances.0 status chunk:balances.0 status chunk:balances.0', 1, true), seq)
  eq(#srv.published, 1)
  local _, n = Stub.output():gsub('Aptic is unreachable', '')
  eq(n, 1, 'one line per outage')
end)

test('the backoff keeps growing while chunks fail, even when status answers', function()
  local srv = UP.setup({ collector = { characters = 500 } })
  srv:fault({ op = 'chunk', collection = 'balances', index = 0, times = 4, result = FakeAptic.err('ingest_unavailable') })
  local seen = {}
  local orig = Aptic.uploader.handle
  Aptic.uploader.handle = function(result, now_ms)
    local d = orig(result, now_ms)
    if d and d.action == 'transient' then seen[#seen + 1] = d.failures end
    return d
  end
  UP.snapshot_now()
  eq(table.concat(seen, ','), '1,2,3,4')
  eq(#srv.published, 1)
end)

test('a chunk file changed on disk is caught as request_conflict, never published', function()
  local srv, spec = UP.setup({ collector = { characters = 500 } })
  start_now()
  UP.until_(function() return #srv:requests('chunk') >= 2 end, 30)
  local id = U().rec.id
  local rows = Aptic.store.read(id, 'characters.0.json')
  Aptic.store.write(id, 'characters.0.json', (rows:gsub('Test Person 1"', 'Test Person 1!"', 1)))
  UP.restart(srv, spec)
  srv:fault({ op = 'status', times = 1, result = FakeAptic.ok({ status = 'uploading', received = {} }) })
  UP.until_(function() return U().rec == nil end, 60)
  eq(U().last.code, 'request_conflict')
  eq(#srv.published, 0)
  eq(#Aptic.store.list(), 0)
end)

test('network failures on start retry start, at most 3 starts an hour', function()
  local srv = UP.setup()
  srv:fault({ op = 'start', times = 99, result = { ok = false, status = 0, transport_error = 'network' } })
  start_now()
  UP.until_(function() return false end, 1800)
  eq(#srv:requests('start'), 3)
  contains(Aptic.uploader.describe(), 'start budget (3 an hour)')
  srv.faults = {}
  UP.until_(function() return #srv.published == 1 end, 2400)
  eq(#srv:requests('start'), 4)
end)

-- Key rotation and refusals ---------------------------------------------------------------

test('key rotated mid-upload: the old upload is dropped, the new key starts fresh', function()
  local srv = UP.setup({ collector = BIG })
  start_now()
  UP.until_(function() return #srv:requests('chunk') >= 3 end, 30)
  local old = U().rec.id
  Stub.convars.aptic_api_key = H.KEY2
  local before = #srv.log
  UP.tick(1000)
  eq(U().rec, nil)
  eq(U().last.code, 'credential_rotated')
  contains(Stub.output(), 'The connection key changed during the upload')
  for i = before + 1, #srv.log do
    local r = srv.log[i]
    falsy(r.op == 'chunk', 'no chunk of the old upload goes out with the new key')
  end
  eq(srv.log[#srv.log].op, 'heartbeat', 'a heartbeat with the new key')
  eq(srv.log[#srv.log].key, H.KEY2)
  UP.snapshot_now()
  eq(#srv.published, 1)
  truthy(srv.published[1] ~= old)
  eq(srv.uploads[srv.published[1]].key, H.KEY2)
end)

test('credential_rotated from Aptic: dropped, next snapshot is new', function()
  local srv = UP.setup({ collector = BIG })
  srv:fault({ op = 'chunk', collection = 'balances', index = 0, result = FakeAptic.err('credential_rotated') })
  UP.snapshot_now()
  eq(U().last.code, 'credential_rotated')
  UP.snapshot_now()
  eq(#srv.published, 1)
end)

test('401 during an upload stops all traffic until the key changes', function()
  local srv = UP.setup({ collector = BIG })
  UP.tick(0)
  srv:fault({ op = 'chunk', collection = 'balances', index = 0, result = FakeAptic.err('invalid_credential') })
  srv:fault({ op = 'heartbeat', times = 999, result = FakeAptic.err('invalid_credential') })
  UP.snapshot_now()
  eq(U().last.code, 'invalid_credential')
  UP.tick(1000)
  local n = #srv.log
  eq(srv.log[n].op, 'heartbeat', 'the heartbeat checked at once')
  eq(Aptic.heartbeat.state.hold, 'key_change')
  UP.until_(function() return false end, 3 * 3600)
  eq(#srv.log, n, 'nothing sent for three hours, slots included')
  contains(Aptic.scheduler.state.last_skip.reason, 'last heartbeat not accepted')
  srv.faults = {}
  Stub.convars.aptic_api_key = H.KEY2
  UP.tick(1000)
  eq(Aptic.heartbeat.state.state, 'ok')
end)

test('422 adapter_mismatch at start: snapshots stop while the heartbeat says so', function()
  local srv = UP.setup()
  UP.tick(0)
  srv:fault({ op = 'start', result = FakeAptic.err('adapter_mismatch') })
  srv:fault({ op = 'heartbeat', times = 999, result = FakeAptic.err('adapter_mismatch') })
  UP.snapshot_now()
  eq(U().last.code, 'adapter_mismatch')
  UP.tick(1000)
  eq(Aptic.heartbeat.state.state, 'adapter_mismatch')
  local ok, why = Aptic.scheduler.request_now()
  falsy(ok)
  contains(why, 'last heartbeat not accepted')
end)

test('snapshot_clock_invalid: dropped and the clock is measured again at once', function()
  local srv = UP.setup()
  srv:fault({ op = 'start', result = FakeAptic.err('snapshot_clock_invalid') })
  UP.snapshot_now()
  eq(U().last.code, 'snapshot_clock_invalid')
  local n = #srv.log
  UP.tick(1000)
  eq(#srv.log, n + 1)
  eq(srv.log[#srv.log].op, 'heartbeat', 'a heartbeat on the next wake, not a minute later')
end)

test('request_conflict: cache deleted, error shown, the next snapshot is fine', function()
  local srv = UP.setup({ collector = BIG })
  srv:fault({ op = 'chunk', collection = 'characters', index = 1, result = FakeAptic.err('request_conflict') })
  UP.snapshot_now()
  eq(U().last.code, 'request_conflict')
  eq(#cache_folders(), 0)
  contains(Stub.output(), 'error: Snapshot ')
  contains(Stub.output(), 'dropped (request_conflict, characters 1). The cached chunks differ')
  UP.snapshot_now()
  eq(#srv.published, 1)
end)

test('snapshot_out_of_order twice in a row warns about the clock or a shared key', function()
  local srv = UP.setup()
  srv:fault({ op = 'start', times = 2, result = FakeAptic.err('snapshot_out_of_order') })
  UP.snapshot_now()
  not_contains(Stub.output(), 'Two snapshots in a row')
  UP.snapshot_now()
  contains(Stub.output(), 'Two snapshots in a row were older than the latest one Aptic already published')
  contains(Stub.output(), 'no second server uses this connection key')
  UP.snapshot_now()
  eq(#srv.published, 1)
  eq(Aptic.store.get_number('snap.out_of_order'), 0, 'reset by a publish')
end)

test('snapshot_invalid names the collection and reason, never a value', function()
  local srv = UP.setup()
  srv:fault({ op = 'finalize', result = FakeAptic.err('snapshot_invalid', nil, { collection = 'vehicles', reason = 'duplicate_key' }) })
  UP.snapshot_now()
  contains(Stub.output(), 'snapshot_invalid, vehicles duplicate_key')
  eq(U().last.reason, 'duplicate_key')
end)

test('413 body_too_large: the next snapshot uses chunks 25% smaller', function()
  local srv = UP.setup({ collector = { characters = 300, pad = 2000 } })
  srv:fault({ op = 'chunk', result = FakeAptic.err('body_too_large', nil) })
  UP.snapshot_now()
  eq(U().last.code, 'body_too_large')
  eq(Aptic.uploader.byte_budget(), math.floor(240 * 1024 * 0.75))
  UP.snapshot_now()
  eq(#srv.published, 1)
  for _, r in ipairs(srv:requests('chunk')) do
    if r.at_ms > srv:requests('start')[2].at_ms then truthy(#r.body <= 180 * 1024, #r.body) end
  end
  UP.restart(srv)
  eq(Aptic.uploader.byte_budget(), 184320, 'kept across restarts')
end)

test('storage_quota_exceeded: snapshots stop, heartbeats continue, status says why', function()
  local srv = UP.setup()
  srv:fault({ op = 'start', result = FakeAptic.err('storage_quota_exceeded', nil) })
  UP.snapshot_now()
  local hb = srv.heartbeats
  UP.until_(function() return false end, 2 * 3600)
  truthy(srv.heartbeats > hb + 100, 'heartbeats carry on')
  eq(#srv:requests('start'), 1, 'no more snapshots')
  contains(Aptic.uploader.describe(), 'stopped: storage_quota_exceeded')
  Stub.prints = {}
  Aptic.status.command(0, { 'upload', 'status' })
  contains(Stub.output(), 'uploads are stopped (storage_quota_exceeded)')
end)

test('unsupported_version: uploads stop and the owner is told to update', function()
  local srv = UP.setup()
  srv:fault({ op = 'start', result = FakeAptic.err('unsupported_version') })
  UP.snapshot_now()
  contains(Stub.output(), 'Update aptic_bridge')
  falsy(Aptic.scheduler.request_now())
end)

test('start_rate_limited with a short retry_after: the same start is sent after the wait', function()
  local srv = UP.setup()
  srv:fault({ op = 'start', result = FakeAptic.err('start_rate_limited', 90) })
  UP.snapshot_now()
  local starts = srv:requests('start')
  eq(#starts, 2)
  eq(starts[1].body, starts[2].body)
  between(starts[2].at_ms - starts[1].at_ms, 90000, 93000)
  eq(#srv.published, 1)
end)

test('daily_snapshot_limit with a long retry_after: dropped, no snapshot until it frees up', function()
  local srv = UP.setup()
  srv:fault({ op = 'start', result = FakeAptic.err('daily_snapshot_limit', 3 * 3600) })
  UP.snapshot_now()
  eq(U().last.code, 'daily_snapshot_limit')
  local ok, why = Aptic.scheduler.request_now()
  falsy(ok)
  contains(why, 'Aptic asked to wait until')
  UP.until_(function() return #srv.published == 1 end, 5 * 3600)
  truthy(srv:requests('start')[2].at_ms - srv:requests('start')[1].at_ms >= 3 * 3600 * 1000)
end)

test('upload_quota_exceeded: dropped, the next slot tries again', function()
  local srv = UP.setup()
  srv:fault({ op = 'start', result = FakeAptic.err('upload_quota_exceeded', 600) })
  UP.snapshot_now()
  eq(U().last.code, 'upload_quota_exceeded')
  falsy(Aptic.scheduler.request_now(), 'not before retry_after')
  UP.until_(function() return #srv.published == 1 end, 2 * 3600)
  eq(#srv.published, 1)
end)

-- Collector problems -----------------------------------------------------------------------

test('a collector that raises: dropped with a code; the message (which may hold a value) is never printed', function()
  Stub.convars.aptic_debug = '1'
  local srv = UP.setup({ collector = { fail = 'error' } })
  UP.snapshot_now()
  eq(U().last.code, 'collector_error')
  not_contains(Stub.output(), 'Jos')
  not_contains(Stub.output(), 'blew up')
  eq(#cache_folders(), 0)
  eq(#srv:requests('start'), 0)
end)

test('a collector that returns an error code: dropped with that code', function()
  UP.setup({ collector = { fail = 'oxmysql_unavailable' } })
  UP.snapshot_now()
  eq(U().last.code, 'oxmysql_unavailable')
end)

test('counts that do not match the rows: dropped before anything is sent', function()
  local srv = UP.setup({ collector = { miscount = true } })
  UP.snapshot_now()
  eq(U().last.code, 'count_mismatch')
  eq(#srv:requests('start'), 0)
end)

test('a collector reporting another adapter than the server runs: dropped', function()
  local srv = UP.setup({ collector = { framework = 'qbcore', inventory = 'qb-inventory' } })
  UP.snapshot_now()
  eq(U().last.code, 'adapter_changed')
  eq(#srv:requests('start'), 0)
end)

-- Logs ---------------------------------------------------------------------------------------

test('no log line ever holds a row, a body or a server error body', function()
  Stub.convars.aptic_debug = '1'
  local srv = UP.setup({ collector = { characters = 300, unicode = true } })
  srv:fault({ op = 'chunk', collection = 'balances', index = 0, result = FakeAptic.err('rate_limited', 3) })
  srv:fault({ op = 'chunk', collection = 'balances', index = 1, result = { status = 503, code = 'ingest_unavailable',
    json = { error = 'ingest_unavailable', detail = 'char-00042 Jos\195\169' } } })
  srv:fault({ op = 'finalize', result = FakeAptic.err('snapshot_invalid', nil, { collection = 'characters', reason = 'time_order' }) })
  UP.snapshot_now()
  srv:fault({ op = 'chunk', result = FakeAptic.err('request_conflict') })
  UP.snapshot_now()
  -- Both dropped uploads stay live on Aptic for an hour: the next start
  -- gets upload_quota_exceeded, and a later slot publishes.
  UP.until_(function() return #srv.published == 1 end, 3 * 3600)
  Aptic.status.command(0, { 'upload', 'status' })
  Aptic.status.command(0, { 'status' })
  local out = Stub.output()
  for _, needle in ipairs({ 'char-0', 'Jos', 'Test Person', '00000001000000', 'casino_chips', 'PLT0', '"rows"',
    'sultan', 'pillbox', 'detail', H.SALT, H.KEY:sub(17) }) do
    not_contains(out, needle)
  end
  eq(#srv.published, 1)
end)
