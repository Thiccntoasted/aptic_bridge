-- The heartbeat loop: one `heartbeat` request a minute, so the dashboard
-- shows the server online, plus the handling of every answer (policy.lua).
--
-- The loop wakes every tick (config.tick_ms) and does almost nothing unless
-- a request is due. Each wake re-reads the convars, so a key rotated from the
-- live console is noticed within a second and sent at once, even after a
-- 401 stopped all traffic.
--
-- prepare() and handle() hold all the logic and are what the tests drive;
-- step() joins them with the transport inside a FiveM thread.

Aptic = Aptic or {}
local M = {}
Aptic.heartbeat = M

local S = {
  next_at = 0,          -- monotonic ms of the next attempt
  failures = 0,         -- transient failures in a row
  hold = nil,           -- 'key_change': send nothing until the key changes
  state = 'starting',   -- see policy.heartbeat, plus starting/config/waiting
  last = nil,           -- last answer: { at, state, status, code, detail, elapsed_ms }
  last_ok_at = nil,     -- epoch of the last accepted heartbeat
  attempts = 0,
  blocked = nil,        -- { code, message } when a local problem stops sending
  key_id = nil,         -- key prefix (or 'missing'/'invalid') seen last
  pair = nil,           -- adapter pair sent last, e.g. 'qbox+ox_inventory'
  capability = nil,     -- last detection
  salt = nil,           -- last salt state (identity.salt)
  clock_offset_s = nil, -- Aptic server_time minus our clock
  min_agent_version = nil,
  latest_agent_version = nil,
  sending = nil,
}
M.state = S

local function hb() return Aptic.config.heartbeat end
local log = function() return Aptic.log end

--- Reset all state (tests, and `restart aptic_bridge` gets a fresh Lua state anyway).
function M.reset()
  for k in pairs(S) do S[k] = nil end
  S.next_at, S.failures, S.attempts, S.state = 0, 0, 0, 'starting'
end

local LOCAL_MESSAGES = {
  no_key = 'aptic_api_key is not set. Add `set aptic_api_key "apt_ing_..."` from Aptic (Settings -> Connection) to server.cfg, or paste it in the live console.',
  invalid_key = 'aptic_api_key is not a valid connection key (apt_ing_ followed by 43 characters). Copy it again from Aptic.',
}

local function block(code, message, now_ms)
  S.state = code == 'no_framework' and 'waiting' or 'config'
  S.blocked = { code = code, message = message }
  S.next_at = now_ms + hb().config_retry_s * 1000
  log().change('heartbeat', code == 'no_framework' and 'warn' or 'error', '%s', message)
end

local function note_key(cfg, now_ms)
  local id = cfg.key.state == 'ok' and cfg.key.prefix or cfg.key.state
  if S.key_id ~= nil and id ~= S.key_id then
    S.hold = nil
    S.failures = 0
    S.next_at = now_ms
    if cfg.key.state == 'ok' then
      log().info('aptic_api_key changed (now %s…); sending a heartbeat.', cfg.key.prefix)
    end
  end
  S.key_id = id
end

local function note_salt(cfg)
  local salt = Aptic.identity.salt(cfg.salt)
  local before = S.salt
  S.salt = salt
  if before == nil then
    if not salt.pinned then Aptic.identity.print_salt_instructions(salt) end
    return salt
  end
  if before.pinned and not salt.pinned then
    Aptic.identity.print_salt_instructions(salt)
  elseif salt.pinned and (not before.pinned or before.fp ~= salt.fp) then
    log().info('Hash salt pinned (fingerprint %s).', salt.fp or 'unavailable')
  end
  return salt
end

--- Decide whether a heartbeat is due and build it. Returns the request for
--- the transport ({ endpoint, payload, timeout_ms }) or nil.
function M.prepare(now_ms)
  local cfg = Aptic.convars.read()
  note_key(cfg, now_ms)
  local salt = note_salt(cfg)

  -- While Aptic rejects our adapter, a change on this side is worth an
  -- immediate retry (the owner may have fixed the ensure order).
  if S.state == 'adapter_mismatch' then
    local pair = Aptic.capability.pair(Aptic.capability.detect())
    if pair and pair ~= S.pair then S.next_at = now_ms end
  end

  if S.hold == 'key_change' then return nil end
  if now_ms < S.next_at then return nil end

  if cfg.key.state ~= 'ok' then
    local code = cfg.key.state == 'missing' and 'no_key' or 'invalid_key'
    block(code, LOCAL_MESSAGES[code], now_ms)
    return nil
  end
  if cfg.endpoint.state ~= 'ok' then
    block('invalid_endpoint', ('aptic_endpoint %s is not usable: %s.'):format(
      cfg.endpoint.url, cfg.endpoint.reason or 'invalid'), now_ms)
    return nil
  end

  local cap = Aptic.capability.detect()
  S.capability = cap
  if cap.support == 'incomplete' then
    block('no_framework', 'Not sending heartbeats: ' .. cap.reason .. '.', now_ms)
    return nil
  end
  S.blocked = nil

  local payload = {
    version = 1,
    operation = 'heartbeat',
    agent_version = Aptic.identity.agent_version(),
    framework = cap.framework,
    inventory = cap.inventory,
    framework_version = cap.framework_version,
    inventory_version = cap.inventory_version,
    instance_id = Aptic.identity.instance_id(),
  }
  if salt.pinned and salt.fp then payload.salt_fp = salt.fp end
  local max_clients = GetConvarInt('sv_maxclients', 0)
  if max_clients >= 1 and max_clients <= 4096 then payload.max_clients = max_clients end

  S.sending = { key_id = S.key_id, pair = Aptic.capability.pair(cap), host = cfg.endpoint.host }
  return { endpoint = cfg.endpoint.url, payload = payload, timeout_ms = hb().timeout_ms }
end

local function note_versions(json)
  local min, latest = json.min_agent_version, json.latest_agent_version
  S.min_agent_version = type(min) == 'string' and min or nil
  S.latest_agent_version = type(latest) == 'string' and latest or nil
  local mine = Aptic.identity.version()
  if S.min_agent_version and Aptic.policy.compare_versions(mine, S.min_agent_version) < 0 then
    log().change('version', 'warn',
      'aptic_bridge %s is older than the oldest version Aptic supports (%s). Update aptic_bridge.',
      mine, S.min_agent_version)
  elseif S.latest_agent_version and Aptic.policy.compare_versions(mine, S.latest_agent_version) < 0 then
    log().change('version', 'info', 'aptic_bridge %s is available (running %s).',
      S.latest_agent_version, mine)
  end
end

local function note_clock(json, elapsed_ms)
  local server = Aptic.time.parse_iso(json.server_time)
  if not server then return end
  local local_mid = Aptic.time.now() - (tonumber(elapsed_ms) or 0) / 2000
  S.clock_offset_s = math.floor(server - local_mid + 0.5)
  if math.abs(S.clock_offset_s) > 60 then
    log().change('clock', 'warn',
      'This machine\'s clock is %d s off Aptic\'s. Snapshot times will be corrected, but fix the clock (NTP).',
      S.clock_offset_s)
  end
end

local function describe_failure(d, result)
  local te = result.transport_error
  if te == 'tls' then
    return ('TLS certificate verification failed for %s (%s). The key is never sent without a valid certificate.')
      :format(S.sending and S.sending.host or 'the endpoint', result.detail or 'tls')
  end
  return ('Aptic is unreachable (%s%s). Retrying with backoff, up to every %d s.'):format(
    d.code, result.detail and (', ' .. result.detail) or '', hb().backoff_cap_s)
end

local function report(d, result)
  local cap = S.capability or {}
  local described = Aptic.capability.describe(cap)
  local L = log()
  if d.state == 'ok' then
    L.change('heartbeat', 'info', 'heartbeat ok: %s, key %s…, endpoint %s.',
      described, S.key_id or '?', S.sending and S.sending.host or '?')
  elseif d.state == 'unauthorized' then
    L.change('heartbeat', 'error',
      'Aptic refused the connection key (%s): it was rotated, revoked or mistyped, or the workspace was archived. '
      .. 'Nothing more is sent until aptic_api_key changes: paste the current key with `set aptic_api_key "..."` '
      .. 'in the live console, and update server.cfg.', d.code)
  elseif d.state == 'adapter_mismatch' then
    L.change('heartbeat', 'error',
      'Aptic\'s workspace is set to a different framework or inventory than this server runs (%s). '
      .. 'Change the workspace\'s framework and inventory in Aptic, or check which resources are started. '
      .. 'Retrying every %d min.', described, hb().slow_retry_s // 60)
  elseif d.state == 'rate_limited' then
    L.warn('Aptic is rate-limiting this key (%s); next heartbeat in %s.', d.code, Aptic.time.human(d.delay_s))
    L.reset('heartbeat')
  elseif d.state == 'locked' then
    L.change('heartbeat', 'warn',
      'Aptic refused the heartbeat (%s): the workspace is locked, usually until a plan covers it. Retrying every %d min.',
      d.code, hb().slow_retry_s // 60)
  elseif d.state == 'plan_limit' then
    L.change('heartbeat', 'warn',
      'sv_maxclients (%s) is above the slots your Aptic plan covers (plan_limit_exceeded). '
      .. 'Upgrade the plan or lower sv_maxclients. Retrying every %d min.',
      tostring(GetConvarInt('sv_maxclients', 0)), hb().slow_retry_s // 60)
  elseif d.state == 'outdated' then
    -- Printed every time (every 10 min) on purpose.
    L.error('Aptic no longer accepts this aptic_bridge version (%s). Update aptic_bridge.', Aptic.identity.version())
  elseif d.state == 'rejected' then
    L.change('heartbeat', 'error',
      'Aptic rejected the heartbeat (%s, HTTP %s). This is likely a bug in aptic_bridge; please report it. Retrying every %d min.',
      d.code, tostring(math.floor(tonumber(result.status) or 0)), hb().slow_retry_s // 60)
  elseif d.state == 'config' then
    L.change('heartbeat', 'error', 'Heartbeat not sent (%s). Check aptic_api_key and aptic_endpoint.', d.code)
  else
    L.change('heartbeat', 'warn', '%s', describe_failure(d, result))
    L.debug('heartbeat failed (%s); next try in %s', d.code, Aptic.time.human(d.delay_s))
  end
end

--- Apply the transport's answer to the loop state.
function M.handle(result, now_ms)
  result = type(result) == 'table' and result or { status = 0, transport_error = 'transport_unavailable' }
  local d = Aptic.policy.heartbeat(result, S.failures, math.random)
  S.failures = d.failures or 0
  S.hold = d.hold
  S.state = d.state
  S.next_at = now_ms + math.floor(d.delay_s * 1000)
  S.attempts = S.attempts + 1
  S.last = {
    at = Aptic.time.now(),
    state = d.state,
    status = math.floor(tonumber(result.status) or 0),
    code = d.code,
    detail = result.detail,
    elapsed_ms = result.elapsed_ms,
  }
  if S.sending then S.pair = S.sending.pair end
  if d.state == 'ok' then
    S.last_ok_at = S.last.at
    note_clock(result.json, result.elapsed_ms)
    note_versions(result.json)
  end
  report(d, result)
  S.sending = nil
  return d
end

--- One wake of the loop: send a heartbeat if one is due.
function M.step()
  local request = M.prepare(Aptic.time.monotonic_ms())
  if not request then return false end
  local result = Aptic.transport.post(request)
  M.handle(result, Aptic.time.monotonic_ms())
  return true
end

--- Why a snapshot upload could not start right now (for M3 and `aptic
--- status`). An empty list means nothing on this side blocks one.
function M.snapshot_blockers()
  local out = {}
  if not (S.salt and S.salt.pinned) then out[#out + 1] = 'salt not pinned' end
  local cap = S.capability
  if not cap or cap.support == 'incomplete' then
    out[#out + 1] = 'framework/inventory not detected'
  elseif cap.support ~= 'supported' then
    out[#out + 1] = 'unsupported combination'
  end
  if S.state ~= 'ok' then out[#out + 1] = 'last heartbeat not accepted' end
  return out
end

local running = false
function M.start()
  if running then return end
  running = true
  CreateThread(function()
    while true do
      local ok, err = pcall(M.step)
      if not ok then
        log().error('heartbeat loop error: %s', tostring(err))
        S.next_at = Aptic.time.monotonic_ms() + hb().config_retry_s * 1000
      end
      Wait(Aptic.config.tick_ms)
    end
  end)
end

return M
