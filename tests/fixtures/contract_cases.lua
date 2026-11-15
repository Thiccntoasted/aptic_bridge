-- Rows on both sides of each ingest v1 row rule. tests/lua/validate_test.lua
-- checks validate.lua against `valid`; tests/js/contract_parity.test.mjs
-- checks Aptic's contract.ts against the same expectations, so the Lua port
-- and the real contract are held to one list. `lua_only` cases can't be
-- written as JSON (invalid UTF-8, NaN) and are checked on the Lua side only.

local function with(base, changes)
  local out = {}
  for k, v in pairs(base) do out[k] = v end
  for k, v in pairs(changes) do
    if v == 'NIL' then out[k] = nil else out[k] = v end
  end
  return out
end

local function array(t) return setmetatable(t, Aptic.common.ARRAY_MT) end

local HASH = ('0123456789abcdef'):rep(4)

local char = {
  char_id = 'ABC12345', player_hash = HASH, name = 'Marcus Reyes', job = 'police', job_grade = 2,
  gang = 'ballas', created_at = '2026-03-01T00:00:00Z', playtime_minutes = 1290,
  last_seen_at = '2026-11-10T21:05:00Z',
}
local bal = { char_id = 'ABC12345', currency = 'bank', amount = 48200 }
local veh = { plate = 'LSPD 042', model = 'police3', owner_char_id = 'ABC12345', garage = 'mrpd', stored = true,
  state = 'garaged' }
local function grades(n, from)
  local g = {}
  for i = 1, n do g[i] = { level = (from or 0) + i - 1, name = 'G' .. i } end
  return array(g)
end
local job = { kind = 'job', name = 'police', label = 'LSPD', grades = grades(5) }

local cases = {}
local function add(collection, note, valid, row, lua_only)
  cases[#cases + 1] = { collection = collection, note = note, valid = valid, row = row, lua_only = lua_only }
end

-- characters
add('characters', 'baseline', true, char)
add('characters', 'gang, created_at and playtime null', true, with(char, { gang = 'NIL', created_at = 'NIL', playtime_minutes = 'NIL' }))
add('characters', 'name of 120 UTF-16 units with an emoji', true, with(char, { name = ('a'):rep(118) .. '\u{1F31F}' }))
add('characters', 'timestamp with fraction and offset', true, with(char, { created_at = '2026-03-01T02:00:00.123456+02:00' }))
add('characters', 'job_grade 10000', true, with(char, { job_grade = 10000 }))
add('characters', 'job_grade as a whole float', true, with(char, { job_grade = 2.0 }))
add('characters', 'player_hash uppercase', false, with(char, { player_hash = HASH:upper() }))
add('characters', 'player_hash 63 hex', false, with(char, { player_hash = HASH:sub(2) }))
add('characters', 'player_hash a raw license', false, with(char, { player_hash = 'license:1a2b3c4d5e6f708192a3b4c5d6e7f80910111213' }))
add('characters', 'empty name', false, with(char, { name = '' }))
add('characters', 'blank name', false, with(char, { name = '   ' }))
add('characters', 'name of 121 units', false, with(char, { name = ('a'):rep(121) }))
add('characters', 'name 119 + emoji = 121 units', false, with(char, { name = ('a'):rep(119) .. '\u{1F31F}' }))
add('characters', 'name with a newline', false, with(char, { name = 'Star\nLight' }))
add('characters', 'job_grade -1', false, with(char, { job_grade = -1 }))
add('characters', 'job_grade 10001', false, with(char, { job_grade = 10001 }))
add('characters', 'job_grade 2.5', false, with(char, { job_grade = 2.5 }))
add('characters', 'job missing', false, with(char, { job = 'NIL' }))
add('characters', 'timestamp with a space', false, with(char, { created_at = '2026-03-01 00:00:00Z' }))
add('characters', 'timestamp without a zone', false, with(char, { created_at = '2026-03-01T00:00:00' }))
add('characters', 'timestamp with 7 fraction digits', false, with(char, { created_at = '2026-03-01T00:00:00.1234567Z' }))
add('characters', 'timestamp month 13', false, with(char, { last_seen_at = '2026-13-01T00:00:00Z' }))
add('characters', 'timestamp lowercase z', false, with(char, { last_seen_at = '2026-11-01T00:00:00z' }))
add('characters', 'last_seen_at missing', false, with(char, { last_seen_at = 'NIL' }))
add('characters', 'playtime -1', false, with(char, { playtime_minutes = -1 }))
add('characters', 'playtime 1.5', false, with(char, { playtime_minutes = 1.5 }))
add('characters', 'char_id of 129', false, with(char, { char_id = ('C'):rep(129) }))
add('characters', 'unknown key license', false, with(char, { license = 'license:abc' }))
add('characters', 'name with invalid UTF-8', false, with(char, { name = 'Bad\xffName' }), true)
add('characters', 'job_grade NaN', false, with(char, { job_grade = 0 / 0 }), true)

-- balances
add('balances', 'baseline', true, bal)
add('balances', 'negative bank', true, with(bal, { amount = -2350 }))
add('balances', 'lower bound', true, with(bal, { amount = -1e12 }))
add('balances', 'upper bound', true, with(bal, { amount = 1e12 }))
add('balances', 'fractional amount', true, with(bal, { amount = 12.5 }))
add('balances', 'custom code', true, with(bal, { currency = 'casino_chips' }))
add('balances', '32-character code', true, with(bal, { currency = ('a'):rep(32) }))
add('balances', 'uppercase code', false, with(bal, { currency = 'Bank' }))
add('balances', 'dash in code', false, with(bal, { currency = 'dirty-money' }))
add('balances', '33-character code', false, with(bal, { currency = ('a'):rep(33) }))
add('balances', 'above 1e12', false, with(bal, { amount = 1e12 + 1 }))
add('balances', 'below -1e12', false, with(bal, { amount = -1e12 - 1 }))
add('balances', 'amount missing', false, with(bal, { amount = 'NIL' }))
add('balances', 'amount as text', false, with(bal, { amount = '100' }))
add('balances', 'unknown key', false, with(bal, { label = 'Bank' }))

-- vehicles
add('vehicles', 'baseline', true, veh)
add('vehicles', 'impounded, no garage, no owner', true, with(veh, { state = 'impounded', stored = false, garage = 'NIL', owner_char_id = 'NIL' }))
add('vehicles', 'state only', true, with(veh, { stored = 'NIL', state = 'out' }))
add('vehicles', 'stored only (v1 clients)', true, with(veh, { state = 'NIL', stored = false }))
add('vehicles', 'state and stored disagree', false, with(veh, { state = 'out', stored = true }))
add('vehicles', 'neither state nor stored', false, with(veh, { state = 'NIL', stored = 'NIL' }))
add('vehicles', 'state not in the enum', false, with(veh, { state = 'stored' }))
add('vehicles', 'stored as text', false, with(veh, { stored = 'yes', state = 'NIL' }))
add('vehicles', 'plate of 33', false, with(veh, { plate = ('P'):rep(33) }))
add('vehicles', 'empty plate', false, with(veh, { plate = '' }))
add('vehicles', 'model missing', false, with(veh, { model = 'NIL' }))
add('vehicles', 'unknown key mods', false, with(veh, { mods = '{}' }))

-- jobs
add('jobs', 'baseline', true, job)
add('jobs', 'sparse levels', true, with(job, { grades = array({ { level = 0, name = 'A' }, { level = 1, name = 'B' }, { level = 4, name = 'E' } }) }))
add('jobs', 'no grades', true, with(job, { grades = array({}) }))
add('jobs', '100 grades', true, with(job, { grades = grades(100) }))
add('jobs', 'gang kind', true, with(job, { kind = 'gang', name = 'ballas' }))
add('jobs', '101 grades', false, with(job, { grades = grades(101) }))
add('jobs', 'duplicate level', false, with(job, { grades = array({ { level = 1, name = 'A' }, { level = 1, name = 'B' } }) }))
add('jobs', 'level 10001', false, with(job, { grades = array({ { level = 10001, name = 'A' } }) }))
add('jobs', 'level 1.5', false, with(job, { grades = array({ { level = 1.5, name = 'A' } }) }))
add('jobs', 'empty grade name', false, with(job, { grades = array({ { level = 0, name = '' } }) }))
add('jobs', 'extra key in a grade', false, with(job, { grades = array({ { level = 0, name = 'A', payment = 10 } }) }))
add('jobs', 'grades as strings (pre-freeze shape)', false, with(job, { grades = array({ 'Recruit', 'Officer' }) }))
add('jobs', 'unknown kind', false, with(job, { kind = 'org' }))
add('jobs', 'label of 257', false, with(job, { label = ('L'):rep(257) }))

-- the collections v1 does not send, for completeness of the port
add('activity', 'baseline', true, { char_id = 'ABC12345', playtime_minutes = 30 })
add('activity', 'playtime missing', false, { char_id = 'ABC12345' })
add('containers', 'baseline', true, { container_id = 'player:ABC12345', type = 'player', owner_char_id = 'ABC12345', label = 'Pockets' })
add('containers', 'unknown type', false, { container_id = 'x', type = 'bag', label = 'Bag' })
add('item_stacks', 'baseline', true, { container_id = 'player:ABC12345', item_name = 'water', count = 3, slot = 1, metadata_json = '{"quality":90}' })
add('item_stacks', 'count 0', false, { container_id = 'player:ABC12345', item_name = 'water', count = 0, slot = 1 })
add('item_stacks', 'metadata not JSON', false, { container_id = 'p', item_name = 'water', count = 1, slot = 1, metadata_json = '{nope' })
add('registry', 'baseline', true, { item_name = 'water', label = 'Water', category = 'food', reference_price = 0, is_restricted = false, allowed_jobs = array({}) })
add('registry', 'restricted to jobs', true, { item_name = 'weapon_pistol', label = 'Pistol', category = 'weapon', reference_price = 500, is_restricted = true, allowed_jobs = array({ 'police' }) })
add('registry', 'category not in the enum', false, { item_name = 'water', label = 'Water', category = 'drink', reference_price = 0, is_restricted = false, allowed_jobs = array({}) })

return cases
