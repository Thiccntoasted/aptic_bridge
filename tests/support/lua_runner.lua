-- A tiny test runner and assertions for the Lua tests. Test files call
-- test(name, fn); the JS side (tests/lua/lua.test.mjs) lists the names and
-- runs each case in a fresh Lua state.

T = { cases = {} }

function test(name, fn)
  T.cases[#T.cases + 1] = { name = name, fn = fn }
end

function T.names()
  local out = {}
  for i, c in ipairs(T.cases) do out[i] = c.name end
  return out
end

function T.run(index)
  local case = T.cases[index]
  local ok, err = xpcall(case.fn, debug.traceback)
  if ok then return 'ok' end
  return tostring(err)
end

local function show(v)
  if type(v) == 'string' then return string.format('%q', v) end
  return tostring(v)
end

function eq(actual, expected, message)
  if actual ~= expected then
    error(('%sexpected %s, got %s'):format(message and (message .. ': ') or '', show(expected), show(actual)), 2)
  end
end

function truthy(value, message)
  if not value then error(message or 'expected a truthy value', 2) end
end

function falsy(value, message)
  if value then error((message or 'expected a falsy value') .. ', got ' .. show(value), 2) end
end

function contains(haystack, needle, message)
  if not tostring(haystack):find(needle, 1, true) then
    error(('%sexpected to find %s in:\n%s'):format(message and (message .. ': ') or '', show(needle), haystack), 2)
  end
end

function not_contains(haystack, needle, message)
  if tostring(haystack):find(needle, 1, true) then
    error(('%sdid not expect %s in:\n%s'):format(message and (message .. ': ') or '', show(needle), haystack), 2)
  end
end

function between(value, lo, hi, message)
  if type(value) ~= 'number' or value < lo or value > hi then
    error(('%sexpected %s..%s, got %s'):format(message and (message .. ': ') or '', lo, hi, show(value)), 2)
  end
end

function keys_of(t)
  local out = {}
  for k in pairs(t) do out[#out + 1] = k end
  table.sort(out)
  return table.concat(out, ',')
end
