-- A Lua port of the ingest contract's row rules (Aptic
-- apps/web/lib/ingest/contract.ts, validateRows, v1 frozen 15 Nov 2026), so
-- a bad row is skipped and counted here instead of failing a whole chunk on
-- the server (plan §3.1). tests/js/contract_parity.test.mjs feeds the rows
-- the collectors produce, plus deliberately broken ones, through the real
-- contract.ts and checks that both sides agree.
--
-- Rows are Lua tables as the uploader will JSON-encode them: an absent
-- field (nil) is JSON null/absent, which the contract treats the same.
--
-- validate.row(collection, row) -> true | false, '<field>' (the first rule
-- that failed, for counting; never the value).

Aptic = Aptic or {}
local M = {}
Aptic.validate = M

local common = Aptic.common

local Bad = {}
local function bad(field) error(setmetatable({ field = field }, Bad), 0) end

local function object(v, field)
  if type(v) ~= 'table' then bad(field) end
  return v
end

-- contract keys(): no property outside `fields`.
local function keys(o, fields, field)
  local allowed = {}
  for _, f in ipairs(fields) do allowed[f] = true end
  for k in pairs(o) do
    if type(k) ~= 'string' or not allowed[k] then bad(field or 'unknown_key') end
  end
end

-- contract str(): a string, non-empty after trim, at most `max` UTF-16
-- units, no character below U+0020. Invalid UTF-8 is refused too: it could
-- not reach the server as the same string.
local function str(v, max, field)
  max = max or 128
  if type(v) ~= 'string' then bad(field) end
  local cps = common.codepoints(v)
  local nonspace = false
  for _, cp in ipairs(cps) do
    if cp == false or cp < 32 then bad(field) end
    if not common.is_js_space(cp) then nonspace = true end
  end
  if not nonspace then bad(field) end
  if common.utf16_len_cps(cps) > max then bad(field) end
  return v
end

-- contract num(): a finite number in [min, max], an integer when asked.
local function num(v, max, integer, min, field)
  max, min = max or 1e12, min or 0
  if type(v) ~= 'number' or v ~= v or v == math.huge or v == -math.huge
    or v < min or v > max then
    bad(field)
  end
  if integer and v ~= math.floor(v) then bad(field) end
  return v
end

local function one(v, options, field)
  if type(v) ~= 'string' then bad(field) end
  for _, o in ipairs(options) do if v == o then return v end end
  bad(field)
end

local function absent(v) return v == nil end

local function optional_string(v, max, field)
  if absent(v) then return nil end
  return str(v, max, field)
end

local DAYS = { 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

-- contract stamp(): ^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d{1,6})?(Z|[+-]\d\d:\d\d)$
-- that Date.parse accepts. This side is slightly stricter than V8 (no
-- 24:00:00, days checked per month); the collectors only produce
-- second-precision UTC from os.date.
local function stamp(v, field)
  str(v, 40, field)
  local y, mo, d, h, mi, s, rest = v:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)$')
  if not y then bad(field) end
  local frac = rest:match('^%.(%d+)')
  if frac then
    if #frac > 6 then bad(field) end
    rest = rest:sub(#frac + 2)
  end
  if rest ~= 'Z' then
    local oh, om = rest:match('^[+-](%d%d):(%d%d)$')
    if not oh or tonumber(oh) > 23 or tonumber(om) > 59 then bad(field) end
  end
  mo, d, h, mi, s = tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(s)
  if mo < 1 or mo > 12 or d < 1 or d > DAYS[mo] or h > 23 or mi > 59 or s > 59 then bad(field) end
  return v
end

local function is_array(t)
  if type(t) ~= 'table' then return false end
  local n = 0
  for k in pairs(t) do
    if math.type(k) ~= 'integer' or k < 1 then return false end
    n = n + 1
  end
  for i = 1, n do if t[i] == nil then return false end end
  return true, n
end

local function strings(v, max, field)
  local ok, n = is_array(v)
  if not ok or n > (max or 100) then bad(field) end
  for i = 1, n do str(v[i], 120, field) end
  return v
end

M.CURRENCY = '^[a-z0-9_]+$'
M.VEHICLE_STATES = { 'garaged', 'out', 'impounded' }
M.MAX_GRADES = 100

local function grades(v)
  local ok, n = is_array(v)
  if not ok or n > M.MAX_GRADES then bad('grades') end
  local seen = {}
  for i = 1, n do
    local g = object(v[i], 'grades')
    keys(g, { 'level', 'name' }, 'grades')
    local level = num(g.level, 10000, true, 0, 'grades.level')
    str(g.name, 120, 'grades.name')
    if seen[level] then bad('grades.level') end
    seen[level] = true
  end
end

local RULES = {}

RULES.characters = function(r)
  keys(r, { 'char_id', 'player_hash', 'name', 'job', 'job_grade', 'gang', 'created_at',
    'playtime_minutes', 'last_seen_at' })
  str(r.player_hash, 64, 'player_hash')
  if not r.player_hash:match('^' .. ('[0-9a-f]'):rep(64) .. '$') then bad('player_hash') end
  str(r.char_id, 128, 'char_id')
  str(r.name, 120, 'name')
  str(r.job, 120, 'job')
  num(r.job_grade, 10000, true, 0, 'job_grade')
  optional_string(r.gang, 120, 'gang')
  if not absent(r.created_at) then stamp(r.created_at, 'created_at') end
  if not absent(r.playtime_minutes) then num(r.playtime_minutes, 2147483647, true, 0, 'playtime_minutes') end
  stamp(r.last_seen_at, 'last_seen_at')
end

RULES.balances = function(r)
  keys(r, { 'char_id', 'currency', 'amount' })
  str(r.char_id, 128, 'char_id')
  local currency = str(r.currency, 32, 'currency')
  if not currency:match(M.CURRENCY) then bad('currency') end
  num(r.amount, 1e12, false, -1e12, 'amount')
end

RULES.containers = function(r)
  keys(r, { 'container_id', 'type', 'owner_char_id', 'owner_job', 'label' })
  str(r.container_id, 256, 'container_id')
  one(r.type, { 'player', 'stash', 'trunk', 'glovebox', 'drop', 'business', 'evidence', 'other' }, 'type')
  optional_string(r.owner_char_id, 128, 'owner_char_id')
  optional_string(r.owner_job, 120, 'owner_job')
  str(r.label, 256, 'label')
end

RULES.item_stacks = function(r)
  keys(r, { 'container_id', 'item_name', 'count', 'slot', 'unique_id', 'metadata_json' })
  if not absent(r.metadata_json) then
    if type(r.metadata_json) ~= 'string' or #r.metadata_json > 8192 then bad('metadata_json') end
    local ok, decoded = pcall(json.decode, r.metadata_json)
    if not ok or (decoded == nil and r.metadata_json ~= 'null') then bad('metadata_json') end
  end
  if num(r.count, 2147483647, true, 0, 'count') == 0 then bad('count') end
  str(r.container_id, 256, 'container_id')
  str(r.item_name, 128, 'item_name')
  num(r.slot, 2147483647, true, 0, 'slot')
  optional_string(r.unique_id, 256, 'unique_id')
end

RULES.vehicles = function(r)
  keys(r, { 'plate', 'model', 'owner_char_id', 'garage', 'stored', 'state' })
  local state = nil
  if not absent(r.state) then state = one(r.state, M.VEHICLE_STATES, 'state') end
  if not absent(r.stored) and type(r.stored) ~= 'boolean' then bad('stored') end
  if state == nil and absent(r.stored) then bad('state') end
  local stored = r.stored
  if absent(stored) then stored = state == 'garaged' end
  if state ~= nil and stored ~= (state == 'garaged') then bad('stored') end
  str(r.plate, 32, 'plate')
  str(r.model, 128, 'model')
  optional_string(r.owner_char_id, 128, 'owner_char_id')
  optional_string(r.garage, 128, 'garage')
end

RULES.activity = function(r)
  keys(r, { 'char_id', 'playtime_minutes' })
  str(r.char_id, 128, 'char_id')
  num(r.playtime_minutes, 2147483647, true, 0, 'playtime_minutes')
end

RULES.registry = function(r)
  keys(r, { 'item_name', 'label', 'category', 'reference_price', 'is_restricted', 'allowed_jobs' })
  if type(r.is_restricted) ~= 'boolean' then bad('is_restricted') end
  str(r.item_name, 128, 'item_name')
  str(r.label, 256, 'label')
  one(r.category, { 'weapon', 'ammo', 'drug', 'valuable', 'food', 'tool', 'material', 'medical', 'misc' }, 'category')
  num(r.reference_price, 1e12, false, 0, 'reference_price')
  strings(r.allowed_jobs, 100, 'allowed_jobs')
end

RULES.jobs = function(r)
  keys(r, { 'kind', 'name', 'label', 'grades' })
  one(r.kind, { 'job', 'gang' }, 'kind')
  str(r.name, 128, 'name')
  str(r.label, 256, 'label')
  grades(r.grades)
end

M.COLLECTIONS = { 'characters', 'balances', 'containers', 'item_stacks', 'vehicles', 'activity', 'registry', 'jobs' }

--- Check one row. Returns true, or false and the failing field.
function M.row(collection, row)
  local rule = RULES[collection]
  if not rule then return false, 'collection' end
  if type(row) ~= 'table' then return false, 'row' end
  local ok, err = pcall(rule, row)
  if ok then return true end
  if getmetatable(err) == Bad then return false, err.field or 'row' end
  return false, 'row'
end

return M
