-- What to do after a heartbeat answer (plan §5.3). Pure: no natives, no
-- logging, so every row of the table is unit-tested.
--
-- Every outcome waits at least a second; nothing retries tight.
--   200 ok                         next heartbeat in interval +/- jitter
--   401 invalid_credential         stop; send nothing until the key changes
--   422 adapter_mismatch           retry every 10 min, or at once when the
--                                  detected framework/inventory changes
--   429 rate_limited (and other    wait retry_after from the JSON body, else
--       429/413 limits)            the Retry-After header, else 60 s
--   403 workspace_locked /         retry every 10 min
--       plan_limit_exceeded
--   400 unsupported_version        retry every 10 min, tell the owner to update
--   other 4xx                      retry every 10 min (a bug: report it)
--   5xx, timeout, network, TLS     exponential backoff 5, 10, 20 ... 300 s with
--                                  jitter in the upper half of each step
--   local config problems          look again in 30 s

Aptic = Aptic or {}
local M = {}
Aptic.policy = M

local function cfg() return Aptic.config.heartbeat end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function positive_int(v)
  if type(v) ~= 'number' or v ~= v or v < 1 or v > 86400 then return nil end
  return math.floor(v)
end

--- The wait (s) a 413/429 asks for: retry_after from the JSON body (C6),
--- else the Retry-After header, else the default. nil body value from the
--- server means "waiting will not help"; the caller decides what that means.
function M.retry_after(result)
  local wait = positive_int(result.retry_after_body)
    or positive_int(result.retry_after_header)
    or cfg().rate_limit_default_s
  return clamp(wait, 1, cfg().max_wait_s)
end

--- Exponential backoff with jitter: step n (1-based) waits between half and
--- all of min(cap, base * 2^(n-1)).
function M.backoff(failures, rand)
  rand = rand or math.random
  local n = math.max(1, failures)
  local step = math.min(cfg().backoff_cap_s, cfg().backoff_base_s * 2 ^ (n - 1))
  return math.max(1, step / 2 + rand() * step / 2)
end

--- The next regular heartbeat: interval +/- jitter.
function M.interval(rand)
  rand = rand or math.random
  local c = cfg()
  return math.max(1, c.interval_s + (rand() * 2 - 1) * c.jitter_s)
end

local CONFIG_ERRORS = {
  no_key = true, invalid_key = true, invalid_endpoint = true,
  insecure_endpoint = true, invalid_request = true, body_too_large = true,
}

--- Decide after one heartbeat. `failures` counts transient failures in a row
--- before this one. Returns:
---   state     ok | unauthorized | adapter_mismatch | rate_limited | locked |
---             plan_limit | outdated | rejected | unavailable | config
---   delay_s   seconds until the next attempt (always >= 1)
---   hold      'key_change' when nothing may be sent until the key changes
---   failures  the new transient-failure count
---   code      the error code (API code or transport error), for status
function M.heartbeat(result, failures, rand)
  failures = failures or 0
  local c = cfg()
  local status = tonumber(result.status) or 0
  local code = result.code

  if result.transport_error then
    local te = result.transport_error
    if CONFIG_ERRORS[te] then
      return { state = 'config', delay_s = c.config_retry_s, failures = 0, code = te }
    end
    local n = failures + 1
    return { state = 'unavailable', delay_s = M.backoff(n, rand), failures = n, code = te }
  end

  if status >= 200 and status < 300 then
    if type(result.json) == 'table' and result.json.ok == true then
      return { state = 'ok', delay_s = M.interval(rand), failures = 0 }
    end
    local n = failures + 1
    return { state = 'unavailable', delay_s = M.backoff(n, rand), failures = n, code = 'unexpected_answer' }
  end

  if status == 401 then
    return { state = 'unauthorized', delay_s = c.config_retry_s, hold = 'key_change',
      failures = 0, code = code or 'invalid_credential' }
  end
  if status == 422 then
    return { state = 'adapter_mismatch', delay_s = c.slow_retry_s, failures = 0,
      code = code or 'adapter_mismatch' }
  end
  if status == 429 or status == 413 then
    return { state = 'rate_limited', delay_s = M.retry_after(result) + (rand or math.random)() * 2,
      failures = 0, code = code or 'rate_limited' }
  end
  if status == 403 then
    local state = code == 'plan_limit_exceeded' and 'plan_limit' or 'locked'
    return { state = state, delay_s = c.slow_retry_s, failures = 0, code = code or 'forbidden' }
  end
  if status == 400 and code == 'unsupported_version' then
    return { state = 'outdated', delay_s = c.slow_retry_s, failures = 0, code = code }
  end
  if status >= 400 and status < 500 then
    return { state = 'rejected', delay_s = c.slow_retry_s, failures = 0,
      code = code or ('http_' .. math.floor(status)) }
  end

  -- 5xx, 3xx (redirects are not followed), anything else: transient.
  local n = failures + 1
  return { state = 'unavailable', delay_s = M.backoff(n, rand), failures = n,
    code = code or ('http_' .. math.floor(status)) }
end

--- Compare two "x.y.z" versions; -1, 0 or 1. Missing parts count as 0 and
--- anything after "-" or "+" is ignored.
function M.compare_versions(a, b)
  local function parts(v)
    v = tostring(v or ''):gsub('^[vV]', ''):gsub('[-+].*$', '')
    local out = {}
    for n in v:gmatch('%d+') do out[#out + 1] = tonumber(n) end
    return out
  end
  local pa, pb = parts(a), parts(b)
  for i = 1, math.max(#pa, #pb, 3) do
    local x, y = pa[i] or 0, pb[i] or 0
    if x < y then return -1 end
    if x > y then return 1 end
  end
  return 0
end

return M
