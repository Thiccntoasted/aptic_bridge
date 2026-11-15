-- Time helpers. Scheduling uses the monotonic game timer (milliseconds since
-- the server started), so a wall-clock jump can't stall or burst the loop.
-- Wall-clock UTC is for display and for the clock offset Aptic reports.

Aptic = Aptic or {}
local M = {}
Aptic.time = M

--- Milliseconds from a monotonic clock.
function M.monotonic_ms()
  return GetGameTimer()
end

--- Seconds since the Unix epoch (UTC).
function M.now()
  return os.time()
end

--- ISO 8601 UTC, second precision: 2026-11-15T12:00:00Z
function M.iso(epoch)
  return os.date('!%Y-%m-%dT%H:%M:%SZ', math.floor(epoch or M.now()))
end

-- Days from 1970-01-01 to a civil date (proleptic Gregorian, UTC).
local function days_from_civil(y, m, d)
  if m <= 2 then y = y - 1 end
  local era = (y >= 0 and y or y - 399) // 400
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = (153 * mp + 2) // 5 + d - 1
  local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
  return era * 146097 + doe - 719468
end

--- Parse an ISO 8601 timestamp with a zone (Z or +hh:mm) to epoch seconds.
--- Returns nil when the text is not one.
function M.parse_iso(text)
  if type(text) ~= 'string' then return nil end
  local y, mo, d, h, mi, s, rest =
    text:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)(.*)$')
  if not y then return nil end
  local frac = 0
  local f, after = rest:match('^%.(%d+)(.*)$')
  if f then
    frac = tonumber('0.' .. f)
    rest = after
  end
  local offset
  if rest == 'Z' or rest == 'z' then
    offset = 0
  else
    local sign, oh, om = rest:match('^([+-])(%d%d):?(%d%d)$')
    if not sign then return nil end
    offset = (tonumber(oh) * 3600 + tonumber(om) * 60) * (sign == '-' and -1 or 1)
  end
  y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
  h, mi, s = tonumber(h), tonumber(mi), tonumber(s)
  if mo < 1 or mo > 12 or d < 1 or d > 31 or h > 23 or mi > 59 or s > 60 then
    return nil
  end
  return days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + s + frac - offset
end

--- "12 s", "4 min", "2 h" for status output.
function M.human(seconds)
  seconds = math.floor(seconds + 0.5)
  if seconds < 120 then return ('%d s'):format(seconds) end
  if seconds < 7200 then return ('%d min'):format(seconds // 60) end
  return ('%d h'):format(seconds // 3600)
end

return M
