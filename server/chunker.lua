-- The chunker (plan §5.2 step 1): the sink the collector writes rows into.
-- Rows are encoded to JSON as they arrive and grouped per collection into
-- chunks of at most 200 rows whose whole `chunk` request body stays under the
-- byte budget (about 240 KiB, 16 KiB under the API's 256 KiB). A chunk is
-- written to the chunk store the moment it closes, so memory holds one open
-- chunk per collection, never the snapshot. Indexes are zero-based and
-- contiguous per collection, at most 249 (contract.ts).
--
-- Also here: the JSON encoder every snapshot byte goes through. It is
-- deterministic (object keys sorted, shortest round-trip numbers), so the
-- size counted is the size sent, and it repairs invalid UTF-8 so the bytes in
-- a chunk file are exactly what Aptic stores and compares on a replay.
--
-- The collector interface (collector.lua calls these):
--   sink:begin(meta)          meta = { taken_at, capabilities, framework, inventory,
--                             framework_version, inventory_version, salt_fp,
--                             online_count (only with the online_count capability) }
--   sink:add(collection, row) -> true | false, code   (stop collecting on false)
--   sink:finish(counts)       -> true | false, code   counts = { [collection] = n }
-- Rows are Lua tables in the contract's exact shape. A table with no keys is
-- encoded as [] (allowed_jobs = {}), so empty objects can't be expressed;
-- the contract has none. Absent (nil) fields are left out, which the contract
-- reads as null. Aptic.chunker.NULL forces an explicit null.

Aptic = Aptic or {}
local M = {}
Aptic.chunker = M

M.COLLECTIONS = {
  'characters', 'balances', 'containers', 'item_stacks',
  'vehicles', 'activity', 'registry', 'jobs',
}
M.CAPABILITIES = {
  'characters', 'balances', 'inventory', 'vehicles',
  'activity', 'registry', 'jobs', 'online_count',
}
local IS_COLLECTION, IS_CAPABILITY = {}, {}
for _, c in ipairs(M.COLLECTIONS) do IS_COLLECTION[c] = true end
for _, c in ipairs(M.CAPABILITIES) do IS_CAPABILITY[c] = true end

--- The capability a collection needs (containers and item_stacks: inventory).
function M.capability_of(collection)
  if collection == 'containers' or collection == 'item_stacks' then return 'inventory' end
  return collection
end

local function ucfg() return Aptic.config.upload end

-- JSON ----------------------------------------------------------------------

M.NULL = setmetatable({}, { __tostring = function() return 'null' end })

local ESCAPES = {
  ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
  ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}
for b = 0, 31 do
  local c = string.char(b)
  if not ESCAPES[c] then ESCAPES[c] = ('\\u%04x'):format(b) end
end

local REPLACEMENT = '\239\191\189' -- U+FFFD

--- `s` with every invalid UTF-8 sequence replaced by U+FFFD.
function M.fix_utf8(s)
  if utf8.len(s) then return s end
  local out, i, n = {}, 1, #s
  while i <= n do
    local c = s:byte(i)
    local len = c < 0x80 and 1
      or (c >= 0xC2 and c <= 0xDF) and 2
      or (c >= 0xE0 and c <= 0xEF) and 3
      or (c >= 0xF0 and c <= 0xF4) and 4
      or 0
    local piece = len > 0 and s:sub(i, i + len - 1) or nil
    if piece and #piece == len and utf8.len(piece) == 1 then
      out[#out + 1] = piece
      i = i + len
    else
      out[#out + 1] = REPLACEMENT
      i = i + 1
    end
  end
  return table.concat(out)
end

local function encode_string(s)
  return '"' .. M.fix_utf8(s):gsub('[\0-\31"\\]', ESCAPES) .. '"'
end

local function encode_number(x)
  if math.type(x) == 'integer' then return ('%d'):format(x) end
  if x ~= x or x == math.huge or x == -math.huge then error('json: non-finite number', 0) end
  if x == math.floor(x) and math.abs(x) < 2 ^ 53 then
    return ('%d'):format(math.tointeger(x))
  end
  for p = 14, 17 do
    local s = ('%.' .. p .. 'g'):format(x)
    if tonumber(s) == x then return s end
  end
  return ('%.17g'):format(x)
end

local encode_value

local function encode_table(t, depth)
  if depth > 32 then error('json: nested too deeply', 0) end
  local n, count = #t, 0
  for _ in pairs(t) do count = count + 1 end
  if count == n then -- an array (or empty: [])
    local out = {}
    for i = 1, n do out[i] = encode_value(t[i], depth + 1) end
    return '[' .. table.concat(out, ',') .. ']'
  end
  local keys = {}
  for k in pairs(t) do
    if type(k) ~= 'string' then error('json: mixed or non-string keys', 0) end
    keys[#keys + 1] = k
  end
  table.sort(keys)
  local out = {}
  for i, k in ipairs(keys) do out[i] = encode_string(k) .. ':' .. encode_value(t[k], depth + 1) end
  return '{' .. table.concat(out, ',') .. '}'
end

encode_value = function(v, depth)
  local kind = type(v)
  if v == nil or rawequal(v, M.NULL) then return 'null' end
  if kind == 'string' then return encode_string(v) end
  if kind == 'number' then return encode_number(v) end
  if kind == 'boolean' then return v and 'true' or 'false' end
  if kind == 'table' then return encode_table(v, depth) end
  -- FiveM's json.null, if a collector uses it.
  if json ~= nil and type(json) == 'table' and rawequal(v, json.null) then return 'null' end
  error('json: cannot encode a ' .. kind, 0)
end

--- Encode a value. Raises on NaN/inf, functions, cycles and mixed tables.
function M.encode(value)
  return encode_value(value, 0)
end

--- Decode JSON text (the bridge's own state files and KVP). Returns the value,
--- or nil and an error. null decodes to nil.
function M.decode(text)
  if type(text) ~= 'string' then return nil, 'not a string' end
  local pos = 1
  local function fail(msg) error({ json = msg .. ' at ' .. pos }, 0) end
  local function ws() pos = text:find('[^ \t\r\n]', pos) or (#text + 1) end
  local value
  local function str()
    local out = {}
    pos = pos + 1
    while true do
      local i = text:find('["\\]', pos)
      if not i then fail('unterminated string') end
      out[#out + 1] = text:sub(pos, i - 1)
      if text:sub(i, i) == '"' then pos = i + 1; break end
      local e = text:sub(i + 1, i + 1)
      local simple = ({ ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' })[e]
      if simple then
        out[#out + 1] = simple
        pos = i + 2
      elseif e == 'u' then
        local hex = text:sub(i + 2, i + 5)
        if not hex:match('^%x%x%x%x$') then fail('bad \\u escape') end
        local cp = tonumber(hex, 16)
        pos = i + 6
        if cp >= 0xD800 and cp <= 0xDBFF and text:sub(pos, pos + 1) == '\\u' then
          local lo = tonumber(text:sub(pos + 2, pos + 5), 16)
          if lo and lo >= 0xDC00 and lo <= 0xDFFF then
            cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
            pos = pos + 6
          end
        end
        out[#out + 1] = (cp >= 0xD800 and cp <= 0xDFFF) and REPLACEMENT or utf8.char(cp)
      else
        fail('bad escape')
      end
    end
    return table.concat(out)
  end
  value = function()
    ws()
    local c = text:sub(pos, pos)
    if c == '{' then
      local obj = {}
      pos = pos + 1
      ws()
      if text:sub(pos, pos) == '}' then pos = pos + 1; return obj end
      while true do
        ws()
        if text:sub(pos, pos) ~= '"' then fail('expected a key') end
        local k = str()
        ws()
        if text:sub(pos, pos) ~= ':' then fail('expected :') end
        pos = pos + 1
        obj[k] = value()
        ws()
        local d = text:sub(pos, pos)
        pos = pos + 1
        if d == '}' then return obj end
        if d ~= ',' then fail('expected , or }') end
      end
    elseif c == '[' then
      local arr, n = {}, 0
      pos = pos + 1
      ws()
      if text:sub(pos, pos) == ']' then pos = pos + 1; return arr end
      while true do
        n = n + 1
        arr[n] = value()
        ws()
        local d = text:sub(pos, pos)
        pos = pos + 1
        if d == ']' then return arr end
        if d ~= ',' then fail('expected , or ]') end
      end
    elseif c == '"' then
      return str()
    elseif text:sub(pos, pos + 3) == 'true' then pos = pos + 4; return true
    elseif text:sub(pos, pos + 4) == 'false' then pos = pos + 5; return false
    elseif text:sub(pos, pos + 3) == 'null' then pos = pos + 4; return nil
    end
    local num = text:match('^-?%d+%.?%d*[eE]?[-+]?%d*', pos)
    if not num or num == '' or num == '-' then fail('unexpected character') end
    pos = pos + #num
    local v = math.tointeger(tonumber(num)) or tonumber(num)
    if v == nil then fail('bad number') end
    return v
  end
  local ok, result = pcall(function()
    local v = value()
    ws()
    if pos <= #text then fail('trailing data') end
    return v
  end)
  if ok then return result end
  return nil, type(result) == 'table' and result.json or tostring(result)
end

-- Request bodies --------------------------------------------------------------

--- The exact `chunk` request body for already-encoded rows (a JSON array).
--- Field order is fixed, so a body rebuilt from the same file is the same bytes.
function M.chunk_body(snapshot_id, collection, index, rows_json)
  return ('{"version":1,"operation":"chunk","snapshot_id":%s,"collection":%s,"index":%d,"rows":%s}')
    :format(encode_string(snapshot_id), encode_string(collection), index, rows_json)
end

-- Meta checks -------------------------------------------------------------------

local VERSION_RE = '^[%w][%w%._%+%-]*$'
local FRAMEWORKS = { qbcore = true, qbox = true }
local INVENTORIES = { ['qb-inventory'] = true, ox_inventory = true }

local function valid_stamp(s)
  if type(s) ~= 'string' or #s > 40 then return false end
  local frac_ok = s:match('^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d(.*)$')
  if not frac_ok then return false end
  local zone = frac_ok:match('^%.%d%d?%d?%d?%d?%d?(.*)$') or frac_ok
  if not (zone == 'Z' or zone:match('^[+-]%d%d:%d%d$')) then return false end
  return Aptic.time.parse_iso(s) ~= nil
end
M.valid_stamp = valid_stamp

--- Check the collector's meta. Returns a cleaned copy, or nil and a code.
function M.check_meta(meta)
  if type(meta) ~= 'table' then return nil, 'invalid_meta' end
  if not valid_stamp(meta.taken_at) then return nil, 'invalid_taken_at' end
  if not FRAMEWORKS[meta.framework] or not INVENTORIES[meta.inventory] then
    return nil, 'invalid_adapter'
  end
  local caps, seen = {}, {}
  if type(meta.capabilities) ~= 'table' then return nil, 'invalid_capabilities' end
  for _, c in ipairs(meta.capabilities) do
    if not IS_CAPABILITY[c] or seen[c] then return nil, 'invalid_capabilities' end
    seen[c] = true
    caps[#caps + 1] = c
  end
  if not seen.characters or #caps > 8 then return nil, 'invalid_capabilities' end
  local out = {
    taken_at = meta.taken_at,
    framework = meta.framework,
    inventory = meta.inventory,
    capabilities = caps,
    has = seen,
  }
  for _, k in ipairs({ 'framework_version', 'inventory_version' }) do
    local v = meta[k]
    if type(v) == 'string' and #v <= 32 and v:match(VERSION_RE) then out[k] = v end
  end
  if meta.salt_fp ~= nil then
    if type(meta.salt_fp) ~= 'string' or not meta.salt_fp:match('^%x%x%x%x%x%x%x%x$') then
      return nil, 'invalid_salt_fp'
    end
    out.salt_fp = meta.salt_fp:lower()
  end
  if seen.online_count then
    local n = meta.online_count
    if math.type(n) ~= 'integer' and not (type(n) == 'number' and n == math.floor(n)) then
      return nil, 'invalid_online_count'
    end
    if n < 0 or n > 100000 then return nil, 'invalid_online_count' end
    out.online_count = math.tointeger(n)
  end
  return out
end

-- The sink ----------------------------------------------------------------------

local Sink = {}
Sink.__index = Sink

--- A new sink for one snapshot. opts:
---   snapshot_id
---   write(name, text) -> truthy   stores one file of the snapshot
---   max_bytes                     body budget (default config.upload.chunk_max_bytes)
function M.new(opts)
  local c = ucfg()
  local self = setmetatable({
    snapshot_id = opts.snapshot_id,
    write = opts.write,
    max_rows = opts.max_rows or c.chunk_max_rows,
    max_bytes = opts.max_bytes or c.chunk_max_bytes,
    max_index = opts.max_index or c.max_chunk_index,
    max_total = opts.max_total_rows or c.max_rows,
    open = {},       -- collection -> { parts, bytes, rows, index }
    counts = {},     -- collection -> rows added
    chunks = {},     -- collection -> chunks written
    total = 0,
    bytes = 0,       -- request bytes of all chunk bodies written
    meta = nil,
    failed = nil,    -- { code, collection, index }
    finished = false,
  }, Sink)
  return self
end

function Sink:fail(code, collection, index)
  if not self.failed then self.failed = { code = code, collection = collection, index = index } end
  return false, self.failed.code
end

function Sink:overhead(collection, index)
  return #M.chunk_body(self.snapshot_id, collection, index, '[]')
end

function Sink:flush(collection)
  local o = self.open[collection]
  if not o or o.rows == 0 then return true end
  if o.index > self.max_index then return self:fail('too_many_chunks', collection, o.index) end
  local rows_json = '[' .. table.concat(o.parts, ',') .. ']'
  local name = ('%s.%d.json'):format(collection, o.index)
  if not self.write(name, rows_json) then return self:fail('cache_write_failed', collection, o.index) end
  self.bytes = self.bytes + self:overhead(collection, o.index) - 2 + #rows_json
  self.chunks[collection] = o.index + 1
  self.open[collection] = { parts = {}, bytes = 0, rows = 0, index = o.index + 1 }
  return true
end

function Sink:begin(meta)
  if self.failed then return false, self.failed.code end
  if self.meta then return self:fail('begin_twice') end
  local checked, code = M.check_meta(meta)
  if not checked then return self:fail(code) end
  self.meta = checked
  return true
end

function Sink:add(collection, row)
  if self.failed then return false, self.failed.code end
  if not self.meta then return self:fail('add_before_begin', collection) end
  if self.finished then return self:fail('add_after_finish', collection) end
  if not IS_COLLECTION[collection] then return self:fail('unknown_collection') end
  if not self.meta.has[M.capability_of(collection)] then
    return self:fail('capability_not_declared', collection)
  end
  if type(row) ~= 'table' then return self:fail('invalid_row', collection) end
  local ok, encoded = pcall(M.encode, row)
  if not ok or encoded:sub(1, 1) ~= '{' then
    local o = self.open[collection]
    return self:fail('unencodable_row', collection, o and o.index or 0)
  end
  if self.total >= self.max_total then return self:fail('snapshot_too_large', collection) end

  local o = self.open[collection]
  if not o then
    o = { parts = {}, bytes = 0, rows = 0, index = 0 }
    self.open[collection] = o
  end
  -- Body size if this row joined the open chunk: overhead + rows + commas.
  local function size_with(chunk)
    return self:overhead(collection, chunk.index) + chunk.bytes + #encoded + (chunk.rows > 0 and 1 or 0)
  end
  if o.rows > 0 and (o.rows >= self.max_rows or size_with(o) > self.max_bytes) then
    local flushed, code = self:flush(collection)
    if not flushed then return false, code end
    o = self.open[collection]
  end
  if size_with(o) > self.max_bytes then return self:fail('row_too_large', collection, o.index) end
  o.parts[#o.parts + 1] = encoded
  o.bytes = o.bytes + #encoded + (o.rows > 0 and 1 or 0)
  o.rows = o.rows + 1
  self.counts[collection] = (self.counts[collection] or 0) + 1
  self.total = self.total + 1
  return true
end

--- Close every open chunk and check the collector's counts against ours.
function Sink:finish(counts)
  if self.failed then return false, self.failed.code end
  if not self.meta then return self:fail('finish_before_begin') end
  if self.finished then return true end
  for _, c in ipairs(M.COLLECTIONS) do
    local flushed, code = self:flush(c)
    if not flushed then return false, code end
  end
  if counts ~= nil then
    if type(counts) ~= 'table' then return self:fail('count_mismatch') end
    for k in pairs(counts) do
      if not IS_COLLECTION[k] then return self:fail('count_mismatch', tostring(k)) end
    end
    for _, c in ipairs(M.COLLECTIONS) do
      if (tonumber(counts[c]) or 0) ~= (self.counts[c] or 0) then return self:fail('count_mismatch', c) end
    end
  end
  self.finished = true
  return true
end

--- The manifest: every collection with its row count (0 when absent).
function Sink:manifest()
  local out = {}
  for _, c in ipairs(M.COLLECTIONS) do out[c] = self.counts[c] or 0 end
  return out
end

--- Chunks written per collection (collections with rows only).
function Sink:chunk_counts()
  local out = {}
  for c, n in pairs(self.chunks) do out[c] = n end
  return out
end

--- The `start` request payload. `envelope` adds agent_version, instance_id
--- and salt_fp, which Aptic records but leaves out of the replay definition.
function Sink:start_payload(envelope)
  local m = self.meta
  local p = {
    version = 1,
    operation = 'start',
    snapshot_id = self.snapshot_id,
    taken_at = m.taken_at,
    source = 'bridge',
    framework = m.framework,
    inventory = m.inventory,
    framework_version = m.framework_version,
    inventory_version = m.inventory_version,
    capabilities = m.capabilities,
    manifest = self:manifest(),
    online_count = m.online_count,
  }
  for k, v in pairs(envelope or {}) do p[k] = v end
  if m.salt_fp then p.salt_fp = m.salt_fp end
  return p
end

return M
