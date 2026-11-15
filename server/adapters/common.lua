-- Shared helpers for the framework and inventory adapters (plan §2, §3.2):
-- text cleaning that matches the ingest contract's string rules, defensive
-- JSON decoding, money/job/gang parsing, vehicle state codes, and the
-- SELECT-only queries both frameworks share (they use the same `players`
-- and `player_vehicles` tables).
--
-- Every SQL string in the resource is a SELECT with keyset pagination and a
-- LIMIT. tests/js/sql_rules.test.mjs fails if a write statement appears.

Aptic = Aptic or {}
local M = {}
Aptic.common = M

-- Mark tables that must encode as JSON arrays even when empty (for example
-- a job with no grades): `[]`, never `{}`. The uploader's encoder checks it.
M.ARRAY_MT = { __name = 'aptic.array' }

function M.array(t)
  return setmetatable(t or {}, M.ARRAY_MT)
end

-- ---------------------------------------------------------------------------
-- Text
-- ---------------------------------------------------------------------------

--- UTF-8 decode. Returns a list of code points, with `false` for every byte
--- that is not part of a valid sequence (overlong forms and surrogates
--- count as invalid).
function M.codepoints(s)
  local out, i, n = {}, 1, #s
  while i <= n do
    local c = s:byte(i)
    local len, cp
    if c < 0x80 then
      len, cp = 1, c
    elseif c >= 0xC2 and c <= 0xDF then
      len, cp = 2, c & 0x1F
    elseif c >= 0xE0 and c <= 0xEF then
      len, cp = 3, c & 0x0F
    elseif c >= 0xF0 and c <= 0xF4 then
      len, cp = 4, c & 0x07
    end
    if len and len > 1 then
      if i + len - 1 > n then
        cp = nil
      else
        for k = 1, len - 1 do
          local b = s:byte(i + k)
          if b < 0x80 or b > 0xBF then cp = nil break end
          cp = (cp << 6) | (b & 0x3F)
        end
      end
      if cp and ((len == 3 and cp < 0x800) or (len == 4 and (cp < 0x10000 or cp > 0x10FFFF))
        or (cp >= 0xD800 and cp <= 0xDFFF)) then
        cp = nil
      end
    end
    if cp then
      out[#out + 1] = cp
      i = i + len
    else
      out[#out + 1] = false
      i = i + 1
    end
  end
  return out
end

--- Whitespace as JavaScript's String.prototype.trim() sees it.
function M.is_js_space(cp)
  return (cp >= 9 and cp <= 13) or cp == 32 or cp == 0xA0 or cp == 0x1680
    or (cp >= 0x2000 and cp <= 0x200A) or cp == 0x2028 or cp == 0x2029
    or cp == 0x202F or cp == 0x205F or cp == 0x3000 or cp == 0xFEFF
end

--- Length in UTF-16 code units (JavaScript's .length): code points above
--- U+FFFF, such as most emoji, count as 2.
function M.utf16_len_cps(cps)
  local n = 0
  for _, cp in ipairs(cps) do
    n = n + ((cp and cp > 0xFFFF) and 2 or 1)
  end
  return n
end

--- Make a value safe for a contract string field, or nil when nothing is
--- left: invalid UTF-8 dropped, control characters (< 32) turned into
--- spaces, trimmed, cut to `max` UTF-16 units on a code point boundary.
function M.clean_text(value, max)
  if type(value) == 'number' then
    if value ~= value or value == math.huge or value == -math.huge then return nil end
    value = math.tointeger(value) and tostring(math.tointeger(value)) or tostring(value)
  end
  if type(value) ~= 'string' or value == '' then return nil end
  local cps = {}
  for _, cp in ipairs(M.codepoints(value)) do
    if cp then cps[#cps + 1] = cp < 32 and 32 or cp end
  end
  local first, last = 1, #cps
  while first <= last and M.is_js_space(cps[first]) do first = first + 1 end
  while last >= first and M.is_js_space(cps[last]) do last = last - 1 end
  local out, units = {}, 0
  for i = first, last do
    local w = cps[i] > 0xFFFF and 2 or 1
    if units + w > max then break end
    units = units + w
    out[#out + 1] = cps[i]
  end
  while #out > 0 and M.is_js_space(out[#out]) do out[#out] = nil end
  if #out == 0 then return nil end
  return utf8.char(table.unpack(out))
end

-- ---------------------------------------------------------------------------
-- Values from the database or a framework
-- ---------------------------------------------------------------------------

--- A real value: not nil and not a JSON-null sentinel (some json libraries
--- decode null to a userdata).
local function present(v)
  return v ~= nil and type(v) ~= 'userdata' and type(v) ~= 'function'
end
M.present = present

--- A JSON column as a table. oxmysql returns TEXT columns as strings and a
--- MySQL JSON column already decoded, so both are accepted. Returns the
--- table, or nil and 'missing' | 'malformed'.
function M.decode(value)
  if type(value) == 'table' then return value end
  if not present(value) or value == '' then return nil, 'missing' end
  if type(value) ~= 'string' then return nil, 'malformed' end
  local ok, decoded = pcall(json.decode, value)
  if ok and type(decoded) == 'table' then return decoded end
  return nil, 'malformed'
end

--- A finite number from a number or a numeric string, else nil.
function M.number(v)
  if type(v) == 'string' then v = tonumber(v) end
  if type(v) ~= 'number' or v ~= v or v == math.huge or v == -math.huge then return nil end
  return v
end

--- An integer (Lua integer subtype) when `v` is a whole number, else nil.
function M.integer(v)
  v = M.number(v)
  if not v or v ~= math.floor(v) or math.abs(v) > 2 ^ 53 then return nil end
  return math.tointeger(v)
end

--- Epoch seconds (integer) from UNIX_TIMESTAMP(), which oxmysql returns as a
--- number, or as a string for DECIMAL results. nil when absent or <= 0.
function M.epoch(v)
  v = M.number(v)
  if not v or v <= 0 then return nil end
  return math.floor(v)
end

--- Character name from charinfo (`firstname lastname`), or nil.
function M.char_name(charinfo, max)
  if type(charinfo) ~= 'table' then return nil end
  local first = M.clean_text(charinfo.firstname, max)
  local last = M.clean_text(charinfo.lastname, max)
  local joined = table.concat({ first or '', last or '' }, ' ')
  return M.clean_text(joined, max)
end

--- Primary job: name and grade level. The JSON is
--- { name, label, grade = { name, level } }; older rows store the grade as
--- a bare number. Returns name, level, problem: when the job can't be read
--- the character gets `unemployed` 0 (plan §2.1) and problem says why.
function M.parse_job(job)
  if type(job) ~= 'table' then return 'unemployed', 0, 'job_unreadable' end
  local name = M.clean_text(job.name, 120)
  if not name then return 'unemployed', 0, 'job_unreadable' end
  local grade = job.grade
  local level
  if type(grade) == 'table' then level = M.integer(grade.level) else level = M.integer(grade) end
  if not level or level < 0 or level > 10000 then return name, 0, 'job_grade_unreadable' end
  return name, level
end

--- Gang name, or nil for no gang (`none`, missing or unreadable).
function M.parse_gang(gang)
  if type(gang) ~= 'table' then return nil end
  local name = M.clean_text(gang.name, 120)
  if not name or name == 'none' then return nil end
  return name
end

local CURRENCY = '^[a-z0-9_]+$'

--- Balances from the `money` JSON ({ cash, bank, crypto, ...custom types }).
--- Codes are free-form in the contract (D5), lowercased; Config rename and
--- skip lists apply. Returns a sorted list of { currency, amount } and a
--- list of problem codes (unreadable amounts, invalid codes, duplicates).
function M.parse_money(money, rename, skip)
  rename, skip = rename or {}, skip or {}
  local out, problems = {}, {}
  if type(money) ~= 'table' then return out, problems end
  local keys = {}
  for k in pairs(money) do
    if type(k) == 'string' then keys[#keys + 1] = k else problems[#problems + 1] = 'currency_code_invalid' end
  end
  -- Exact lowercase codes first, so `bank` wins over a stray `Bank`.
  table.sort(keys, function(a, b)
    local ea, eb = a == a:lower(), b == b:lower()
    if ea ~= eb then return ea end
    return a < b
  end)
  local used = {}
  for _, key in ipairs(keys) do
    local code = rename[key] or rename[key:lower()] or key:lower()
    local amount = M.number(money[key])
    if skip[key] or skip[code] then
      -- the owner excluded this money type
    elseif type(code) ~= 'string' or #code > 32 or not code:match(CURRENCY) then
      problems[#problems + 1] = 'currency_code_invalid'
    elseif amount == nil then
      problems[#problems + 1] = 'amount_unreadable'
    elseif used[code] then
      problems[#problems + 1] = 'currency_duplicate'
    else
      used[code] = true
      out[#out + 1] = { currency = code, amount = math.tointeger(amount) or amount }
    end
  end
  table.sort(out, function(a, b) return a.currency < b.currency end)
  return out, problems
end

--- player_vehicles.state: 0 out, 1 garaged, 2 impounded, in both QBCore
--- (qb-garages) and Qbox (qbx_vehicles server/main.lua `State` enum:
--- OUT = 0, GARAGED = 1, IMPOUNDED = 2). Anything else is nil.
local VEHICLE_STATES = { [0] = 'out', [1] = 'garaged', [2] = 'impounded' }
function M.vehicle_state(v)
  local n = M.integer(v)
  return n and VEHICLE_STATES[n] or nil
end

--- Plates are trimmed and uppercased (contract D5 notes). nil when empty or
--- longer than the contract's 32.
function M.plate(v)
  if type(v) == 'number' then v = tostring(math.tointeger(v) or v) end
  if type(v) ~= 'string' then return nil end
  local p = M.clean_text(v, 64)
  if not p then return nil end
  p = p:upper()
  if M.utf16_len_cps(M.codepoints(p)) > 32 then return nil end
  return p
end

--- Grades of a job or gang definition, keyed by level ('0', '1' ... on
--- QBCore; 0, 1 ... on Qbox), as the contract's sorted
--- [{ level, name }] (levels may be sparse). Returns the list and the
--- number of grades dropped or renamed, by problem.
function M.grades(defs)
  local out, problems = M.array({}), {}
  if type(defs) ~= 'table' then return out, problems end
  for key, grade in pairs(defs) do
    local level = M.integer(key)
    if not level or level < 0 or level > 10000 then
      problems[#problems + 1] = 'grade_level_invalid'
    else
      local name = type(grade) == 'table' and M.clean_text(grade.name, 120) or nil
      if not name then
        name = 'Grade ' .. level
        problems[#problems + 1] = 'grade_name_defaulted'
      end
      out[#out + 1] = { level = level, name = name }
    end
  end
  table.sort(out, function(a, b) return a.level < b.level end)
  return out, problems
end

-- ---------------------------------------------------------------------------
-- SQL (SELECT only, keyset pagination, always LIMIT)
-- ---------------------------------------------------------------------------

local function query(sql, params)
  local ok, rows = pcall(function() return MySQL.query.await(sql, params) end)
  if not ok then return nil, 'query_failed' end
  if type(rows) ~= 'table' then return nil, 'query_failed' end
  return rows
end
M.query = query

M.SQL_COLUMNS = 'SELECT TABLE_NAME AS table_name, COLUMN_NAME AS column_name'
  .. ' FROM information_schema.COLUMNS'
  .. ' WHERE TABLE_SCHEMA = DATABASE()'
  .. " AND TABLE_NAME IN ('players', 'player_vehicles', 'ox_inventory', 'inventories', 'stashitems')"
  .. ' ORDER BY TABLE_NAME, COLUMN_NAME LIMIT 2000'

local PLAYER_REQUIRED = { 'citizenid', 'license', 'charinfo', 'money', 'job', 'last_updated' }
local VEHICLE_REQUIRED = { 'id', 'plate', 'vehicle', 'citizenid', 'garage', 'state' }

--- Which tables and columns exist (plan §3.3). Returns
--- { tables = { [name] = { [column] = true } }, players = bool,
---   vehicles = bool } or nil, err.
function M.probe()
  local rows, err = query(M.SQL_COLUMNS, {})
  if not rows then return nil, err end
  local tables = {}
  for _, r in ipairs(rows) do
    local t = r.table_name or r.TABLE_NAME
    local c = r.column_name or r.COLUMN_NAME
    if type(t) == 'string' and type(c) == 'string' then
      t, c = t:lower(), c:lower()
      tables[t] = tables[t] or {}
      tables[t][c] = true
    end
  end
  local function has_all(t, cols)
    if not tables[t] then return false end
    for _, c in ipairs(cols) do if not tables[t][c] then return false end end
    return true
  end
  return {
    tables = tables,
    players = has_all('players', PLAYER_REQUIRED),
    vehicles = has_all('player_vehicles', VEHICLE_REQUIRED),
  }
end

--- One page of `players`, ordered by citizenid, after `cursor`. Only the
--- columns the collectors need: never position, phone_number, inventory,
--- metadata or `name` (the FiveM account name). Timestamps are read as
--- UNIX_TIMESTAMP() so the MySQL session timezone can't shift them (§2.1).
--- `opts.last_logged_out` adds Qbox's column when the probe found it.
--- Returns raw rows and the next cursor, or nil, err.
function M.page_players(schema, cursor, limit, opts)
  local cols = schema.tables.players
  local sql = 'SELECT citizenid, license, charinfo, money, job'
    .. (cols.gang and ', gang' or '')
    .. ', UNIX_TIMESTAMP(last_updated) AS last_updated_ts'
    .. ((opts and opts.last_logged_out and cols.last_logged_out)
      and ', UNIX_TIMESTAMP(last_logged_out) AS last_logged_out_ts' or '')
    .. ' FROM players WHERE citizenid > ? ORDER BY citizenid LIMIT ?'
  local rows, err = query(sql, { cursor, limit })
  if not rows then return nil, err end
  local last = rows[#rows]
  return rows, last and last.citizenid or nil
end

--- One page of `player_vehicles`, ordered by id, after `cursor`. mods,
--- coords, fakeplate and finance columns are never read.
function M.page_vehicles(schema, cursor, limit)
  local cols = schema.tables.player_vehicles
  local sql = 'SELECT id, plate, vehicle' .. (cols.hash and ', hash' or '')
    .. ', citizenid, garage, state'
    .. ' FROM player_vehicles WHERE id > ? ORDER BY id LIMIT ?'
  local rows, err = query(sql, { cursor, limit })
  if not rows then return nil, err end
  local last = rows[#rows]
  return rows, last and M.integer(last.id) or nil
end

--- A `players` row (or live PlayerData) as the collector's plain record.
--- `last_seen_ts` is filled by the framework adapter.
function M.player_record(row)
  local charinfo, ci_problem = M.decode(row.charinfo)
  local money, money_problem = M.decode(row.money)
  local job, job_problem = M.decode(row.job)
  local gang = M.decode(row.gang)
  return {
    citizenid = row.citizenid,
    license = row.license,
    charinfo = charinfo,
    money = money,
    job = job,
    gang = gang,
    problems = {
      charinfo = ci_problem,
      money = money_problem,
      job = job_problem,
    },
  }
end

return M
