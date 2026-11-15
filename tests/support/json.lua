-- A small JSON library standing in for FiveM's global `json` in tests.
-- decode: objects/arrays become tables (arrays 1-based), null becomes nil,
-- whole numbers without '.'/exponent become Lua integers, bad input raises.
-- encode: deterministic (sorted keys), for recording rows; a table is an
-- array when it is a non-empty sequence or carries Aptic's array marker.

json = {}

local function decode_error(s, i, what)
  error(('json.decode: %s at character %d'):format(what, i), 0)
end

local ESCAPES = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }

local function skip_ws(s, i)
  local _, e = s:find('^[ \t\r\n]*', i)
  return e + 1
end

local parse

local function parse_string(s, i)
  local out, j = {}, i + 1
  while true do
    local c = s:sub(j, j)
    if c == '' then decode_error(s, j, 'unterminated string') end
    if c == '"' then return table.concat(out), j + 1 end
    if c == '\\' then
      local e = s:sub(j + 1, j + 1)
      if e == 'u' then
        local hex = s:sub(j + 2, j + 5)
        if not hex:match('^%x%x%x%x$') then decode_error(s, j, 'bad \\u escape') end
        local cp = tonumber(hex, 16)
        j = j + 6
        if cp >= 0xD800 and cp <= 0xDBFF and s:sub(j, j + 1) == '\\u' then
          local lo = tonumber(s:sub(j + 2, j + 5), 16)
          if lo and lo >= 0xDC00 and lo <= 0xDFFF then
            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
            j = j + 6
          end
        end
        out[#out + 1] = utf8.char(cp)
      elseif ESCAPES[e] then
        out[#out + 1] = ESCAPES[e]
        j = j + 2
      else
        decode_error(s, j, 'bad escape')
      end
    else
      if c:byte() < 32 then decode_error(s, j, 'control character in string') end
      out[#out + 1] = c
      j = j + 1
    end
  end
end

local function parse_number(s, i)
  local text = s:match('^-?%d+%.?%d*[eE]?[+-]?%d*', i)
  if not text or text == '' or text == '-' then decode_error(s, i, 'bad number') end
  local n = tonumber(text)
  if n == nil then decode_error(s, i, 'bad number') end
  if not text:find('[.eE]') then n = math.tointeger(n) or n end
  return n, i + #text
end

parse = function(s, i)
  i = skip_ws(s, i)
  local c = s:sub(i, i)
  if c == '{' then
    local obj = {}
    i = skip_ws(s, i + 1)
    if s:sub(i, i) == '}' then return obj, i + 1 end
    while true do
      i = skip_ws(s, i)
      if s:sub(i, i) ~= '"' then decode_error(s, i, 'expected key') end
      local key
      key, i = parse_string(s, i)
      i = skip_ws(s, i)
      if s:sub(i, i) ~= ':' then decode_error(s, i, 'expected :') end
      local value
      value, i = parse(s, i + 1)
      obj[key] = value
      i = skip_ws(s, i)
      local d = s:sub(i, i)
      if d == '}' then return obj, i + 1 end
      if d ~= ',' then decode_error(s, i, 'expected , or }') end
      i = i + 1
    end
  elseif c == '[' then
    local arr, n = {}, 0
    i = skip_ws(s, i + 1)
    if s:sub(i, i) == ']' then return arr, i + 1 end
    while true do
      local value
      value, i = parse(s, i)
      n = n + 1
      arr[n] = value
      i = skip_ws(s, i)
      local d = s:sub(i, i)
      if d == ']' then return arr, i + 1 end
      if d ~= ',' then decode_error(s, i, 'expected , or ]') end
      i = i + 1
    end
  elseif c == '"' then
    return parse_string(s, i)
  elseif s:sub(i, i + 3) == 'true' then
    return true, i + 4
  elseif s:sub(i, i + 4) == 'false' then
    return false, i + 5
  elseif s:sub(i, i + 3) == 'null' then
    return nil, i + 4
  elseif c:match('[-%d]') then
    return parse_number(s, i)
  end
  decode_error(s, i, 'unexpected character')
end

function json.decode(s)
  if type(s) ~= 'string' then error('json.decode: expected a string', 0) end
  local value, i = parse(s, 1)
  i = skip_ws(s, i)
  if i <= #s then decode_error(s, i, 'trailing characters') end
  return value
end

local function encode_string(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    if c == '"' then return '\\"' end
    if c == '\\' then return '\\\\' end
    return ('\\u%04x'):format(c:byte())
  end) .. '"'
end

local function is_sequence(t)
  local n = 0
  for k in pairs(t) do
    if math.type(k) ~= 'integer' or k < 1 then return false end
    n = n + 1
  end
  for i = 1, n do if t[i] == nil then return false end end
  return n > 0, n
end

local function encode(v)
  local tv = type(v)
  if v == nil then return 'null' end
  if tv == 'boolean' then return tostring(v) end
  if tv == 'number' then
    if v ~= v or v == math.huge or v == -math.huge then error('json.encode: non-finite number', 0) end
    if math.type(v) == 'integer' then return tostring(v) end
    return ('%.17g'):format(v)
  end
  if tv == 'string' then return encode_string(v) end
  if tv == 'table' then
    local mt = getmetatable(v)
    local seq, n = is_sequence(v)
    if seq or (mt and mt.__name == 'aptic.array') then
      local parts = {}
      for i = 1, (n or 0) do parts[i] = encode(v[i]) end
      return '[' .. table.concat(parts, ',') .. ']'
    end
    local keys = {}
    for k in pairs(v) do
      if type(k) ~= 'string' then error('json.encode: non-string key', 0) end
      keys[#keys + 1] = k
    end
    table.sort(keys)
    local parts = {}
    for i, k in ipairs(keys) do parts[i] = encode_string(k) .. ':' .. encode(v[k]) end
    return '{' .. table.concat(parts, ',') .. '}'
  end
  error('json.encode: cannot encode ' .. tv, 0)
end

function json.encode(v)
  return encode(v)
end
