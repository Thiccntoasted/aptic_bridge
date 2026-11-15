-- The chunker and its JSON encoder: row and byte limits, indexes, the
-- interface checks, and that what is counted is what is sent.

local C = function() return Aptic.chunker end

local function memory_sink(opts)
  opts = opts or {}
  local files = {}
  opts.snapshot_id = opts.snapshot_id or 'apb-20261115T120000Z-abcd'
  opts.write = function(name, text) files[name] = text; return true end
  local sink = C().new(opts)
  return sink, files
end

local META = {
  taken_at = '2026-11-15T12:00:00Z',
  capabilities = { 'characters', 'balances', 'vehicles', 'jobs' },
  framework = 'qbox', inventory = 'ox_inventory',
  framework_version = '1.24.1', inventory_version = '2.44.1', salt_fp = '49224dd5',
}

local function balance(i, extra)
  return { char_id = ('char-%05d'):format(i), currency = 'bank', amount = i, pad = extra }
end

local function body_size(sink, collection, index, files)
  return #C().chunk_body(sink.snapshot_id, collection, index, files[('%s.%d.json'):format(collection, index)])
end

-- JSON ------------------------------------------------------------------------

test('encode sorts object keys and leaves nil fields out', function()
  eq(C().encode({ b = 1, a = 'x', c = nil, d = true }), '{"a":"x","b":1,"d":true}')
end)

test('an empty table is [] (allowed_jobs), arrays keep order, NULL is null', function()
  eq(C().encode({ allowed_jobs = {} }), '{"allowed_jobs":[]}')
  eq(C().encode({ 3, 1, 2 }), '[3,1,2]')
  eq(C().encode({ gang = C().NULL }), '{"gang":null}')
  eq(C().encode({ grades = { { level = 0, name = 'A' }, { level = 4, name = 'B' } } }),
    '{"grades":[{"level":0,"name":"A"},{"level":4,"name":"B"}]}')
end)

test('numbers: integers stay integers, floats round-trip in the fewest digits', function()
  eq(C().encode({ 1, 1.0, -250.5, 0.1, 1e12, -0.0, 12345678901 }), '[1,1,-250.5,0.1,1000000000000,0,12345678901]')
  eq(C().encode({ 1 / 3 }), '[0.3333333333333333]')
  for _, bad in ipairs({ 0 / 0, math.huge, -math.huge }) do
    falsy(pcall(C().encode, { amount = bad }), 'non-finite numbers are refused')
  end
end)

test('strings escape quotes, backslashes and control characters; UTF-8 passes through', function()
  eq(C().encode('a"b\\c\n\t\1\31'), '"a\\"b\\\\c\\n\\t\\u0001\\u001f"')
  local name = 'Jos\195\169 \240\159\152\128'
  eq(C().encode(name), '"' .. name .. '"')
end)

test('invalid UTF-8 becomes U+FFFD, so the cached bytes are what Aptic stores', function()
  eq(C().fix_utf8('ok\255x\192\128y'), 'ok\239\191\189x\239\191\189\239\191\189y')
  eq(C().fix_utf8('\237\160\128'), '\239\191\189\239\191\189\239\191\189', 'a UTF-16 surrogate is not valid UTF-8')
  local encoded = C().encode('caf\233')
  truthy(utf8.len(encoded), 'encoded text is valid UTF-8')
end)

test('functions, mixed tables and deep nesting are refused', function()
  falsy(pcall(C().encode, { f = function() end }))
  falsy(pcall(C().encode, { 1, 2, x = 3 }))
  local t = {}
  local cur = t
  for _ = 1, 40 do cur.x = {}; cur = cur.x end
  falsy(pcall(C().encode, t))
end)

test('decode reads back what encode wrote', function()
  local value = { id = 'apb-1', phase = 'uploading', chunks = { characters = 3, balances = 1 },
    list = { 1, 2.5, -3 }, flag = false, name = 'Jos\195\169 \240\159\152\128 "q"\n' }
  local back = C().decode(C().encode(value))
  eq(C().encode(back), C().encode(value))
  eq(math.type(back.chunks.characters), 'integer')
  eq(C().decode('"\\u00e9\\ud83d\\ude00"'), '\195\169\240\159\152\128')
  eq(C().decode('[]')[1], nil)
end)

test('decode refuses broken JSON', function()
  for _, bad in ipairs({ '{', '{"a":}', '[1,]', '"x', 'tru', '{"a":1} x', '' }) do
    local v, why = C().decode(bad)
    eq(v, nil, bad)
    truthy(why, bad)
  end
end)

-- Limits ------------------------------------------------------------------------

test('a chunk closes at 200 rows', function()
  local sink, files = memory_sink()
  sink:begin(META)
  for i = 1, 401 do truthy(sink:add('balances', balance(i))) end
  truthy(sink:finish({ balances = 401 }))
  eq(sink:chunk_counts().balances, 3)
  local rows0 = C().decode(files['balances.0.json'])
  local rows2 = C().decode(files['balances.2.json'])
  eq(#rows0, 200)
  eq(#rows2, 1)
  eq(rows2[1].char_id, 'char-00401', 'rows keep their order')
end)

test('a chunk closes before its request body passes the byte budget', function()
  local sink, files = memory_sink()
  sink:begin(META)
  local pad = ('p'):rep(3000)
  for i = 1, 200 do truthy(sink:add('characters', { char_id = ('c%d'):format(i), name = pad })) end
  truthy(sink:finish())
  local n = sink:chunk_counts().characters
  truthy(n >= 3, 'split by size, not rows: ' .. n)
  for i = 0, n - 1 do
    local size = body_size(sink, 'characters', i, files)
    truthy(size <= 240 * 1024, ('chunk %d body is %d bytes'):format(i, size))
    if i < n - 1 then
      truthy(size > 240 * 1024 - 3100, ('chunk %d is filled close to the budget (%d)'):format(i, size))
    end
  end
  eq(sink.bytes, (function()
    local total = 0
    for i = 0, n - 1 do total = total + body_size(sink, 'characters', i, files) end
    return total
  end)(), 'counted bytes equal the bodies that will be sent')
end)

test('the byte budget is the whole body, envelope included', function()
  local sink, files = memory_sink({ max_bytes = 1000 })
  sink:begin(META)
  for i = 1, 50 do sink:add('balances', balance(i)) end
  sink:finish()
  for i = 0, sink:chunk_counts().balances - 1 do
    between(body_size(sink, 'balances', i, files), 1, 1000)
  end
end)

test('a lowered budget gives smaller chunks', function()
  local big, small = memory_sink(), memory_sink({ max_bytes = 180 * 1024 })
  for _, sink in ipairs({ big, small }) do
    sink:begin(META)
    for i = 1, 200 do sink:add('characters', { char_id = ('c%d'):format(i), name = ('p'):rep(2000) }) end
    sink:finish()
  end
  truthy(small:chunk_counts().characters > big:chunk_counts().characters)
end)

test('a row too big for any chunk fails the snapshot', function()
  local sink = memory_sink({ max_bytes = 500 })
  sink:begin(META)
  local ok, code = sink:add('characters', { char_id = 'c1', name = ('x'):rep(600) })
  falsy(ok)
  eq(code, 'row_too_large')
  eq(sink.failed.collection, 'characters')
end)

test('indexes are contiguous per collection and stop at 249', function()
  local sink, files = memory_sink({ max_rows = 1 })
  sink:begin(META)
  for i = 1, 250 do truthy(sink:add('balances', balance(i))) end
  truthy(sink:finish())
  eq(sink:chunk_counts().balances, 250)
  truthy(files['balances.249.json'])
  local sink2 = memory_sink({ max_rows = 1 })
  sink2:begin(META)
  for i = 1, 251 do sink2:add('balances', balance(i)) end
  local ok, code = sink2:finish()
  falsy(ok)
  eq(code, 'too_many_chunks')
  eq(sink2.failed.index, 250)
end)

test('collections chunk independently when rows arrive interleaved', function()
  local sink, files = memory_sink({ max_rows = 2 })
  sink:begin(META)
  for i = 1, 3 do
    sink:add('characters', { char_id = 'c' .. i })
    sink:add('balances', balance(i))
  end
  sink:finish()
  eq(C().encode(sink:chunk_counts()), '{"balances":2,"characters":2}')
  eq(#C().decode(files['characters.1.json']), 1)
end)

test('empty collections write no chunks and count 0 in the manifest', function()
  local sink, files = memory_sink()
  sink:begin(META)
  sink:add('characters', { char_id = 'c1' })
  sink:finish({ characters = 1 })
  eq(C().encode(sink:chunk_counts()), '{"characters":1}')
  eq(C().encode(sink:manifest()),
    '{"activity":0,"balances":0,"characters":1,"containers":0,"item_stacks":0,"jobs":0,"registry":0,"vehicles":0}')
  local n = 0
  for _ in pairs(files) do n = n + 1 end
  eq(n, 1)
end)

test('more than 50,000 rows fails the snapshot before it is sent', function()
  local sink = memory_sink({ max_total_rows = 5 })
  sink:begin(META)
  for i = 1, 5 do truthy(sink:add('balances', balance(i))) end
  local ok, code = sink:add('balances', balance(6))
  falsy(ok)
  eq(code, 'snapshot_too_large')
  eq(Aptic.config.upload.max_rows, 50000)
end)

test('the same rows always give the same files', function()
  local function run()
    local sink, files = memory_sink()
    sink:begin(META)
    for _, row in ipairs(FakeCollector.rows({ characters = 40 }, META.taken_at).characters) do
      sink:add('characters', row)
    end
    sink:finish()
    return files
  end
  dofile('tests/support/fake_collector.lua')
  local a, b = run(), run()
  eq(a['characters.0.json'], b['characters.0.json'])
end)

-- The interface ---------------------------------------------------------------------

test('meta is checked: time, adapter, capabilities, versions, salt fingerprint', function()
  local function meta(over)
    local m = {}
    for k, v in pairs(META) do m[k] = v end
    for k, v in pairs(over) do m[k] = v end
    return m
  end
  local cases = {
    { { taken_at = '2026-11-15 12:00:00' }, 'invalid_taken_at' },
    { { taken_at = '2026-11-15T12:00:00' }, 'invalid_taken_at' },
    { { framework = 'esx' }, 'invalid_adapter' },
    { { capabilities = { 'balances' } }, 'invalid_capabilities' },
    { { capabilities = { 'characters', 'characters' } }, 'invalid_capabilities' },
    { { capabilities = { 'characters', 'money' } }, 'invalid_capabilities' },
    { { salt_fp = 'nothex!!' }, 'invalid_salt_fp' },
    { { capabilities = { 'characters', 'online_count' } }, 'invalid_online_count' },
  }
  for _, case in ipairs(cases) do
    local sink = memory_sink()
    local ok, code = sink:begin(meta(case[1]))
    falsy(ok)
    eq(code, case[2])
  end
  local sink = memory_sink()
  truthy(sink:begin(meta({ taken_at = '2026-11-15T12:00:00.123+01:00', framework_version = 'dev build' })))
  eq(sink.meta.framework_version, nil, 'a version the contract would refuse is dropped')
  local s2 = memory_sink()
  truthy(s2:begin(meta({ capabilities = { 'characters', 'online_count' }, online_count = 37 })))
  eq(s2:start_payload({}).online_count, 37)
end)

test('rows for an undeclared capability or unknown collection are refused', function()
  local sink = memory_sink()
  sink:begin(META)
  local ok, code = sink:add('item_stacks', { container_id = 'x' })
  falsy(ok)
  eq(code, 'capability_not_declared')
  local s2 = memory_sink()
  s2:begin(META)
  eq(select(2, s2:add('money', {})), 'unknown_collection')
end)

test('after a failure every call says so and nothing more is written', function()
  local sink, files = memory_sink({ max_bytes = 300 })
  sink:begin(META)
  sink:add('characters', { char_id = 'c', name = ('x'):rep(400) })
  local ok, code = sink:add('characters', { char_id = 'd' })
  falsy(ok)
  eq(code, 'row_too_large')
  eq(select(2, sink:finish()), 'row_too_large')
  eq(next(files), nil)
end)

test('the collector\'s counts must match the rows it added', function()
  local sink = memory_sink()
  sink:begin(META)
  sink:add('characters', { char_id = 'c1' })
  local ok, code = sink:finish({ characters = 2 })
  falsy(ok)
  eq(code, 'count_mismatch')
  eq(sink.failed.collection, 'characters')
end)

test('add before begin and a row that is not a table are refused', function()
  local sink = memory_sink()
  eq(select(2, sink:add('characters', { char_id = 'c' })), 'add_before_begin')
  local s2 = memory_sink()
  s2:begin(META)
  eq(select(2, s2:add('characters', 'c')), 'invalid_row')
  local s3 = memory_sink()
  s3:begin(META)
  eq(select(2, s3:add('characters', { name = 0 / 0 })), 'unencodable_row')
end)

test('the start payload has the frozen shape', function()
  local sink = memory_sink()
  sink:begin(META)
  sink:add('characters', { char_id = 'c1' })
  sink:finish()
  local p = sink:start_payload({ agent_version = 'aptic_bridge/0.1.0', instance_id = 'abcdefgh12' })
  eq(C().encode(p), '{"agent_version":"aptic_bridge/0.1.0","capabilities":["characters","balances","vehicles","jobs"],'
    .. '"framework":"qbox","framework_version":"1.24.1","instance_id":"abcdefgh12","inventory":"ox_inventory",'
    .. '"inventory_version":"2.44.1","manifest":{"activity":0,"balances":0,"characters":1,"containers":0,'
    .. '"item_stacks":0,"jobs":0,"registry":0,"vehicles":0},"operation":"start","salt_fp":"49224dd5",'
    .. '"snapshot_id":"apb-20261115T120000Z-abcd","source":"bridge","taken_at":"2026-11-15T12:00:00Z","version":1}')
end)

test('chunk bodies have a fixed field order', function()
  eq(C().chunk_body('apb-1', 'jobs', 3, '[{"a":1}]'),
    '{"version":1,"operation":"chunk","snapshot_id":"apb-1","collection":"jobs","index":3,"rows":[{"a":1}]}')
end)

-- The collector's conventions (collector.lua, M2) ---------------------------------

test('tables marked with Aptic.common.ARRAY_MT encode as arrays, [] when empty', function()
  Aptic.common = Aptic.common or {}
  Aptic.common.ARRAY_MT = Aptic.common.ARRAY_MT or { __name = 'array' }
  local arr = function(t) return setmetatable(t, Aptic.common.ARRAY_MT) end
  eq(C().encode({ grades = arr({}) }), '{"grades":[]}')
  eq(C().encode({ grades = arr({ { level = 0, name = 'A' }, { level = 4, name = 'B' } }) }),
    '{"grades":[{"level":0,"name":"A"},{"level":4,"name":"B"}]}')
end)

test('collector-style meta: ARRAY_MT capabilities, online_count, all 8 counts with zeros', function()
  Aptic.common = Aptic.common or {}
  Aptic.common.ARRAY_MT = Aptic.common.ARRAY_MT or {}
  local sink = memory_sink()
  truthy(sink:begin({
    taken_at = '2026-11-15T12:00:00Z', framework = 'qbox', inventory = 'ox_inventory',
    capabilities = setmetatable({ 'characters', 'balances', 'online_count' }, Aptic.common.ARRAY_MT),
    online_count = 12, salt_fp = '49224dd5',
  }))
  sink:add('characters', { char_id = 'c1' })
  truthy(sink:finish({ characters = 1, balances = 0, containers = 0, item_stacks = 0,
    vehicles = 0, activity = 0, registry = 0, jobs = 0 }))
  local p = sink:start_payload({})
  eq(p.online_count, 12)
  contains(C().encode(p), '"capabilities":["characters","balances","online_count"]')
end)

test('sink:abort discards the run and records the collector\'s code', function()
  local sink, files = memory_sink()
  sink:begin(META)
  sink:add('characters', { char_id = 'c1' })
  sink:abort('query_failed')
  eq(sink.failed.code, 'query_failed')
  eq(select(2, sink:finish()), 'query_failed', 'finish after abort does nothing')
  eq(next(files), nil, 'the open chunk was never written')
  local s2 = memory_sink()
  s2:begin(META)
  s2:abort('a message with spaces and a name')
  eq(s2.failed.code, 'collector_failed', 'only code-shaped errors are kept')
end)
