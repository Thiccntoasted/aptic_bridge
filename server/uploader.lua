-- The upload engine (plan §5.2, §5.3): one snapshot at a time, from a
-- collection run to a published snapshot, through a state machine kept in
-- KVP so a restart resumes where it stopped.
--
--   idle -> collecting -> collected -> started -> uploading -> finalizing
--        -> complete | abandoned        (both end back at idle)
--
-- collecting  the collector writes rows into the chunker; chunk files land
--             in cache/<snapshot_id>/ as they close
-- collected   start.json and manifest.json written; ready to send `start`
-- started     Aptic accepted `start`
-- uploading   `status` read; sending the chunks Aptic doesn't have yet, one
--             a second, each rebuilt byte for byte from its file
-- finalizing  `finalize` sent
--
-- After a restart (init): collecting is dropped; collected is started again
-- if taken_at is under 23 h old; started/uploading/finalizing ask `status`
-- and continue if the upload began under 55 min ago with the same key.
--
-- next_request() and handle() hold the logic and are what the tests drive;
-- step() joins them with the transport. decide() is the error-code table,
-- pure so every row is tested.

Aptic = Aptic or {}
local M = {}
Aptic.uploader = M

local function cfg() return Aptic.config.upload end
local function log() return Aptic.log end
local K = function() return Aptic.store.KVP end

local U = {}
M.state = U

function M.reset()
  for k in pairs(U) do U[k] = nil end
  U.next_at = 0
  U.failures = 0
  U.finalize_retries = 0
end
M.reset()

-- Phases in which Aptic holds an upload for this snapshot.
local LIVE = { started = true, uploading = true, finalizing = true }
M.LIVE = LIVE

-- Policy ------------------------------------------------------------------------

local SNAPSHOT_INVALID_REASONS = { duplicate_key = true, missing_reference = true, time_order = true }
local COLLECTION_SET = {}
for _, c in ipairs({ 'characters', 'balances', 'containers', 'item_stacks', 'vehicles', 'activity', 'registry', 'jobs' }) do
  COLLECTION_SET[c] = true
end

local LOCAL_CONFIG = { no_key = true, invalid_key = true, invalid_endpoint = true, insecure_endpoint = true }

--- Full-jitter exponential backoff: anywhere from 1 s to min(cap, base * 2^(n-1)).
function M.backoff(failures, rand)
  rand = rand or math.random
  local c = cfg()
  local step = math.min(c.backoff_cap_s, c.backoff_base_s * 2 ^ (math.max(1, failures) - 1))
  return math.max(1, rand() * step)
end

local function abandon(code, extra)
  local d = { action = 'abandon', code = code }
  for k, v in pairs(extra or {}) do d[k] = v end
  return d
end

--- What to do with one answer. `op` is start|status|chunk|finalize; `ctx`
--- has failures (transient ones in a row before this) and finalize_retries.
--- Returns { action, code, delay_s, ... } where action is:
---   ok         proceed
---   retry      send the same request again after delay_s
---   transient  back off delay_s, then start again (op start) or ask status
---   resync     ask status, resend what is missing, finalize once more
---   wait_start send start again after delay_s (a start limit frees up soon)
---   abandon    drop the snapshot; flags: hold (stop uploads, with why),
---              defer_s (no new snapshot before then), heartbeat (re-check
---              at once: key, adapter, lock, clock), lower_budget, conflict,
---              out_of_order, collection/reason (snapshot_invalid)
function M.decide(op, result, ctx, rand)
  ctx = ctx or {}
  rand = rand or math.random
  local c = cfg()
  local status = math.floor(tonumber(result.status) or 0)
  local code = result.code
  local te = result.transport_error
  local function transient(why)
    local n = (ctx.failures or 0) + 1
    return { action = 'transient', code = why, failures = n, delay_s = M.backoff(n, rand) }
  end

  if te then
    if LOCAL_CONFIG[te] then
      -- The heartbeat reports these; look again shortly, same request.
      return { action = 'retry', code = te, delay_s = Aptic.config.heartbeat.config_retry_s }
    end
    if te == 'body_too_large' then return abandon('body_too_large', { lower_budget = true }) end
    if te == 'invalid_request' then return abandon('invalid_request') end
    return transient(te)
  end

  if status >= 200 and status < 300 then
    if type(result.json) == 'table' and result.json.ok == true then return { action = 'ok' } end
    return transient('unexpected_answer')
  end

  if status == 400 then
    if code == 'unsupported_version' then
      return abandon(code, { hold = 'outdated' })
    end
    if code == 'snapshot_clock_invalid' then return abandon(code, { heartbeat = true }) end
    return abandon(code or 'http_400')
  end
  if status == 401 then return abandon(code or 'invalid_credential', { heartbeat = true }) end
  if status == 403 then return abandon(code or 'forbidden', { heartbeat = true }) end
  if status == 404 then return abandon(code or 'upload_unavailable') end
  if status == 409 then
    if code == 'upload_incomplete' or code == 'chunk_gap' then
      if op == 'finalize' and (ctx.finalize_retries or 0) < 1 then
        return { action = 'resync', code = code }
      end
      return abandon(code)
    end
    if code == 'request_conflict' then return abandon(code, { conflict = true }) end
    if code == 'snapshot_out_of_order' then return abandon(code, { out_of_order = true }) end
    if code == 'snapshot_clock_invalid' then return abandon(code, { heartbeat = true }) end
    if code == 'snapshot_invalid' then
      local j = type(result.json) == 'table' and result.json or {}
      return abandon(code, {
        collection = COLLECTION_SET[j.collection] and j.collection or nil,
        reason = SNAPSHOT_INVALID_REASONS[j.reason] and j.reason or nil,
      })
    end
    -- upload_expired, credential_rotated, invalid_manifest, invalid_chunk,
    -- manifest_count_exceeded and anything new: this snapshot is done.
    return abandon(code or 'http_409')
  end
  if status == 413 then
    if code == 'body_too_large' then return abandon(code, { lower_budget = true }) end
    if code == 'storage_quota_exceeded' then return abandon(code, { hold = 'storage_full' }) end
    local wait = result.retry_after_body
    if code == 'snapshot_too_large' and op == 'start' and type(wait) == 'number' and wait <= c.wait_max_s then
      return { action = 'wait_start', code = code, delay_s = math.max(1, wait) + rand() * 2 }
    end
    -- snapshot_too_large (null: the snapshot itself is too big), and
    -- upload_quota_exceeded (another live upload or 32 MiB of staging): the
    -- next slot, and never before the limit frees up.
    return abandon(code or 'http_413', { defer_s = type(wait) == 'number' and wait or nil })
  end
  if status == 415 then return abandon(code or 'unsupported_media_type', { hold = 'unsupported_media_type' }) end
  if status == 422 then return abandon(code or 'adapter_mismatch', { heartbeat = true }) end
  if status == 429 then
    if code == 'start_rate_limited' or code == 'daily_snapshot_limit' then
      local wait = result.retry_after_body
      if type(wait) ~= 'number' then return abandon(code) end
      if op == 'start' and wait <= c.wait_max_s then
        return { action = 'wait_start', code = code, delay_s = math.max(1, wait) + rand() * 2 }
      end
      return abandon(code, { defer_s = wait })
    end
    -- rate_limited (120 requests/min): the same request after retry_after.
    return { action = 'retry', code = code or 'rate_limited',
      delay_s = Aptic.policy.retry_after(result) + rand() * 2 }
  end
  if status >= 400 and status < 500 then return abandon(code or ('http_' .. status)) end
  -- 5xx (ingest_unavailable), 3xx (redirects are not followed), anything else.
  return transient(code or ('http_' .. status))
end

-- Helpers -----------------------------------------------------------------------

local function now() return Aptic.time.now() end

local function key_prefix()
  local k = Aptic.convars.read().key
  return k.state == 'ok' and k.prefix or nil
end

local function current_salt_fp()
  local hb = Aptic.heartbeat.state
  if hb.salt and hb.salt.pinned then return hb.salt.fp end
  local salt = Aptic.identity.salt(Aptic.convars.read().salt)
  return salt.pinned and salt.fp or nil
end

local function chunk_total(rec)
  local n = 0
  for _, c in pairs(rec.chunks or {}) do n = n + c end
  return n
end

local function all_chunks(rec)
  local out = {}
  for _, c in ipairs(Aptic.chunker.COLLECTIONS) do
    for i = 0, ((rec.chunks or {})[c] or 0) - 1 do out[#out + 1] = { collection = c, index = i } end
  end
  return out
end

local function describe_counts(manifest)
  local parts = {}
  for _, c in ipairs(Aptic.chunker.COLLECTIONS) do
    local n = (manifest or {})[c] or 0
    if n > 0 then parts[#parts + 1] = ('%s %d'):format(c, n) end
  end
  return #parts > 0 and table.concat(parts, ', ') or 'no rows'
end

local function save()
  if U.rec then Aptic.store.save(U.rec) end
end

local function set_phase(phase)
  U.rec.phase = phase
  save()
end

local function remember(outcome)
  U.last = outcome
  Aptic.store.set_json(K().last, outcome)
end

local function clear_current()
  if U.rec then Aptic.store.remove(U.rec.id) end
  Aptic.store.clear()
  U.rec, U.need, U.missing, U.inflight, U.waiting = nil, nil, nil, nil, nil
  U.failures, U.finalize_retries = 0, 0
  U.next_at = 0
end

local function poke_heartbeat()
  -- The heartbeat learns the real state (refused key, adapter, lock, clock
  -- offset) and its own policy holds or warns from there.
  local hb = Aptic.heartbeat.state
  if hb.hold ~= 'key_change' then hb.next_at = 0 end
end

--- The byte budget for the next snapshot's chunks.
function M.byte_budget()
  local stored = Aptic.store.get_number(K().byte_budget)
  local c = cfg()
  if not stored then return c.chunk_max_bytes end
  return math.max(c.chunk_min_bytes, math.min(c.chunk_max_bytes, stored))
end

-- Outcomes ----------------------------------------------------------------------

local ADVICE = {
  request_conflict = 'The cached chunks differ from what Aptic already holds for this snapshot. '
    .. 'The cache was deleted and the next slot collects a new snapshot. If this repeats, please report it.',
  upload_expired = 'Aptic dropped the unfinished upload after an hour. The next slot collects a new snapshot.',
  credential_rotated = 'The connection key changed during the upload. The new key starts a fresh snapshot at the next slot.',
  invalid_credential = 'Aptic refused the connection key; nothing more is sent until aptic_api_key changes.',
  adapter_mismatch = 'Aptic\'s workspace is set to a different framework or inventory; snapshots stop until it matches.',
  workspace_locked = 'The workspace is locked, usually until a plan covers it; snapshots resume once it is unlocked.',
  plan_limit_exceeded = 'sv_maxclients is above the slots your plan covers; snapshots resume once it fits.',
  snapshot_clock_invalid = 'Aptic rejected the snapshot time. The clock offset is measured again and the next slot uses it.',
  unsupported_version = 'Aptic no longer accepts this aptic_bridge version. Update aptic_bridge; snapshots are stopped until then.',
  storage_quota_exceeded = 'Aptic\'s snapshot storage for this workspace is full. Snapshots are stopped until aptic_bridge restarts; heartbeats continue.',
  unsupported_media_type = 'Aptic refused the request headers. This is a bug in aptic_bridge; please report it. Snapshots are stopped until aptic_bridge restarts.',
  body_too_large = 'A chunk was too large for Aptic. The next snapshot uses chunks 25% smaller. Please report it.',
  upload_quota_exceeded = 'Another upload for this workspace is still open, or staging is full. The next slot tries again.',
  start_rate_limited = 'Too many snapshot starts in the last hour for this key. The next slot tries again.',
  daily_snapshot_limit = 'The workspace reached its published snapshots for 24 hours. The schedule waits until a slot frees up.',
  snapshot_too_large = 'The snapshot has more rows than Aptic accepts (50,000).',
  stale_snapshot = 'The collected snapshot is too old to send.',
  resume_expired = 'The upload was interrupted too long ago to resume.',
  key_changed = 'The connection key changed while the upload was interrupted.',
  salt_changed = 'The hash salt changed since the snapshot was collected.',
  adapter_changed = 'The framework or inventory changed since the snapshot was collected.',
  interrupted_collection = 'aptic_bridge stopped while collecting.',
  cache_missing = 'A cached chunk file is missing (was the cache folder deleted?).',
}

local function out_of_order(id)
  local n = (Aptic.store.get_number(K().out_of_order) or 0) + 1
  Aptic.store.set_number(K().out_of_order, n)
  if n >= 2 then
    log().warn('Two snapshots in a row were older than the latest one Aptic already published (snapshot_out_of_order). '
      .. 'Check this machine\'s clock (NTP), and that no second server uses this connection key; '
      .. 'the Connection page shows "multiple instances" when one does.')
  else
    log().warn('Snapshot %s is older than the latest one Aptic already published (snapshot_out_of_order); dropped.', id)
  end
end

--- Drop the current snapshot. `d` is a decide() result or { code }.
function M.abandon(code, d)
  d = d or {}
  local rec = U.rec
  local id = rec and rec.id or '?'
  local where = ''
  if d.collection then
    where = ', ' .. d.collection .. (d.reason and (' ' .. d.reason) or '')
  elseif U.inflight and U.inflight.collection then
    where = (', %s %d'):format(U.inflight.collection, U.inflight.index)
  end
  remember({ at = now(), result = 'abandoned', code = code, snapshot_id = rec and rec.id,
    collection = d.collection or (U.inflight and U.inflight.collection),
    index = (not d.collection and U.inflight) and U.inflight.index or nil, reason = d.reason })

  if d.out_of_order then
    out_of_order(id)
  else
    Aptic.store.set_number(K().out_of_order, 0)
    if code == 'snapshot_invalid' then
      log().error('Aptic rejected snapshot %s at finalize (snapshot_invalid%s): a row breaks a key, reference or time rule. '
        .. 'Dropped; the next slot collects a new one. If this repeats, please report it with this line.', id, where)
      -- Look for it locally (§5.3): the same collection, checked, never uploaded.
      if Aptic.selfcheck then Aptic.selfcheck.after_rejection(d.collection, d.reason) end
    elseif d.conflict then
      log().error('Snapshot %s dropped (request_conflict%s). %s', id, where, ADVICE.request_conflict)
    else
      local level = (d.hold or code == 'invalid_payload' or code == 'invalid_json' or code == 'invalid_manifest'
        or code == 'invalid_chunk' or code == 'manifest_count_exceeded') and 'error' or 'warn'
      log().write(level, ('Snapshot %s dropped (%s%s). %s'):format(id, code, where,
        ADVICE[code] or (level == 'error' and 'This is likely a bug in aptic_bridge; please report it with this line.' or 'The next slot tries again.')))
    end
  end

  if d.lower_budget then
    local budget = math.max(cfg().chunk_min_bytes, math.floor(M.byte_budget() * 0.75))
    Aptic.store.set_number(K().byte_budget, budget)
  end
  if d.hold then U.hold = { code = d.hold, cause = code, at = now() } end
  if d.defer_s then Aptic.scheduler.defer(d.defer_s) end
  if d.heartbeat then poke_heartbeat() end
  clear_current()
  return false, code
end

local function published(json)
  local rec = U.rec
  local secs = rec.started_at and math.max(0, now() - rec.started_at) or nil
  Aptic.store.note(K().published, now(), 86400)
  Aptic.store.set_number(K().out_of_order, 0)
  local info = { at = now(), snapshot_id = rec.id, taken_at = rec.taken_at, rows = rec.rows, chunks = chunk_total(rec) }
  Aptic.store.set_json(K().last_published, info)
  remember({ at = now(), result = 'published', snapshot_id = rec.id, rows = rec.rows })
  log().info('Snapshot %s published: %d rows in %d chunks (%s)%s.', rec.id, rec.rows or 0, chunk_total(rec),
    describe_counts(rec.manifest), secs and (', upload took ' .. Aptic.time.human(secs)) or '')
  Aptic.log.reset('upload')
  clear_current()
end

-- Boot ----------------------------------------------------------------------------

--- On start: pick up (or drop) the snapshot a previous run left (plan §5.2),
--- and delete cache folders that belong to no snapshot.
function M.init()
  M.reset()
  U.last = Aptic.store.get_json(K().last)
  local rec = Aptic.store.load()
  Aptic.store.prune(rec and rec.id or nil)
  if not rec then return nil end
  U.rec = rec
  local t = now()
  if rec.phase == 'collected' then
    local taken = Aptic.time.parse_iso(rec.taken_at)
    if not taken or t - taken > cfg().resume_collected_max_s or not Aptic.store.read(rec.id, 'start.json') then
      return M.abandon(taken and 'stale_snapshot' or 'cache_missing')
    end
    U.need = 'start'
    log().info('Resuming snapshot %s: collected, not yet started.', rec.id)
    return rec
  end
  if LIVE[rec.phase] then
    if not rec.started_at or t - rec.started_at > cfg().resume_started_max_s then
      return M.abandon('resume_expired')
    end
    if rec.key_prefix ~= key_prefix() then return M.abandon('key_changed') end
    U.need = 'status'
    log().info('Resuming snapshot %s (%s): asking Aptic which chunks it has.', rec.id, rec.phase)
    return rec
  end
  -- collecting, or a record that can't be read: start over.
  return M.abandon(rec.phase == 'collecting' and 'interrupted_collection' or 'broken_state')
end

-- Collection ------------------------------------------------------------------------

--- A new snapshot id: apb-<yyyymmddThhmmssZ>-<4 hex>.
function M.new_snapshot_id(epoch)
  local hex = Aptic.transport.random_hex(2) or ('%04x'):format(math.random(0, 0xffff))
  return ('apb-%s-%s'):format(os.date('!%Y%m%dT%H%M%SZ', math.floor(epoch)), hex)
end

local SAFE_CODE = '^[%a][%w_%.%-]*$'

--- Run the collector into a fresh snapshot (inside a thread: the collector
--- yields per page). Returns true once the snapshot is collected, or false
--- and a code when it was dropped.
function M.collect(opts)
  opts = opts or {}
  if U.rec then return false, 'busy' end
  local collector = Aptic.collector
  if not (collector and type(collector.run) == 'function') then return false, 'no_collector' end

  local hb = Aptic.heartbeat.state
  local offset = hb.clock_offset_s or 0
  local t = now() + offset -- Aptic's clock, as measured by the heartbeat
  local id = M.new_snapshot_id(t)
  U.rec = { id = id, phase = 'collecting', created_at = now() }
  save()
  U.collect_started_ms = Aptic.time.monotonic_ms()

  local sink = Aptic.chunker.new({
    snapshot_id = id,
    max_bytes = M.byte_budget(),
    write = function(name, text) return Aptic.store.write(id, name, text) end,
  })
  local run_opts = {
    snapshot_id = id,
    taken_at = Aptic.time.iso(t),
    now = t,
    clock_offset_s = offset,
    max_rows = cfg().max_rows,
    manual = opts.manual == true,
  }
  local ok, summary, err = pcall(collector.run, sink, run_opts)
  if not ok then
    -- Only where it failed: an error message could quote a row value.
    log().debug('collector error at %s', tostring(summary):match('^([^:\n]+:%d+):') or 'unknown location')
    return M.abandon('collector_error')
  end
  if sink.failed then
    return M.abandon(sink.failed.code, { collection = sink.failed.collection })
  end
  if summary == nil then
    local code = type(err) == 'string' and #err <= 64 and err:match(SAFE_CODE) and err or 'collector_failed'
    return M.abandon(code)
  end
  if not sink.meta then return M.abandon('collector_incomplete') end
  if not sink.finished then
    local fin, code = sink:finish(nil)
    if not fin then return M.abandon(code) end
  end

  local meta = sink.meta
  local salt_fp = current_salt_fp()
  if meta.salt_fp and salt_fp and meta.salt_fp ~= salt_fp then return M.abandon('salt_changed') end
  if not salt_fp then return M.abandon('salt_not_pinned') end
  local cap = Aptic.capability.detect()
  local pair = meta.framework .. '+' .. meta.inventory
  if Aptic.capability.pair(cap) ~= pair then return M.abandon('adapter_changed') end

  local payload = sink:start_payload({
    agent_version = Aptic.identity.agent_version(),
    instance_id = Aptic.identity.instance_id(),
    salt_fp = salt_fp,
  })
  local start_json = Aptic.chunker.encode(payload)
  local manifest = sink:manifest()
  local chunks = sink:chunk_counts()
  local rows = sink.total
  local info = {
    snapshot_id = id, taken_at = meta.taken_at, capabilities = meta.capabilities,
    manifest = manifest, chunks = chunks, rows = rows, bytes = sink.bytes,
    salt_fp = salt_fp, adapter = pair, agent_version = Aptic.identity.agent_version(),
  }
  if not Aptic.store.write(id, 'start.json', start_json)
    or not Aptic.store.write(id, 'manifest.json', Aptic.chunker.encode(info)) then
    return M.abandon('cache_write_failed')
  end

  U.rec = {
    id = id, phase = 'collected', created_at = U.rec.created_at, taken_at = meta.taken_at,
    salt_fp = salt_fp, adapter = pair, manifest = manifest, chunks = chunks,
    rows = rows, bytes = sink.bytes,
  }
  save()
  U.need = 'start'
  U.next_at = 0
  local secs = (Aptic.time.monotonic_ms() - U.collect_started_ms) / 1000
  log().info('Snapshot %s collected in %s: %d rows in %d chunks (%s). Uploading.', id, Aptic.time.human(secs),
    rows, chunk_total(U.rec), describe_counts(manifest))
  return true
end

-- Readiness ---------------------------------------------------------------------------

-- Heartbeat states in which no upload request may go out.
local HB_STOP = {
  unauthorized = 'connection key refused', adapter_mismatch = 'adapter mismatch',
  locked = 'workspace locked', plan_limit = 'plan slot limit', outdated = 'aptic_bridge outdated',
  rejected = 'heartbeat rejected', config = 'key or endpoint not usable', waiting = 'framework not started',
}

--- Why an upload request can't go out right now, or nil. A heartbeat that
--- merely failed (network, 429) doesn't stop an upload: it has its own backoff.
function M.not_ready()
  if U.hold then return 'stopped (' .. U.hold.cause .. ')' end
  local hb = Aptic.heartbeat.state
  if HB_STOP[hb.state] then return HB_STOP[hb.state] end
  if not hb.last_ok_at then return 'waiting for the first accepted heartbeat' end
  for _, b in ipairs(Aptic.heartbeat.snapshot_blockers()) do
    if b ~= 'last heartbeat not accepted' then return b end
  end
  return nil
end

-- Requests ------------------------------------------------------------------------------

local function request(endpoint, body, timeout_ms)
  return { endpoint = endpoint, body = body, timeout_ms = timeout_ms }
end

local function simple_body(op, id)
  return Aptic.chunker.encode({ version = 1, operation = op, snapshot_id = id })
end

--- Decide whether an upload request is due and build it ({ endpoint, body,
--- timeout_ms }), or nil. Local transitions (dropping a snapshot that can no
--- longer be sent) happen here too.
function M.next_request(now_ms)
  local rec = U.rec
  if not rec or not U.need then return nil end
  local t = now()
  local prefix = key_prefix()

  -- Rules that drop the snapshot whatever else is going on.
  if LIVE[rec.phase] then
    if prefix and rec.key_prefix and prefix ~= rec.key_prefix then
      return M.abandon('credential_rotated', { heartbeat = true })
    end
    if rec.started_at and t - rec.started_at > cfg().resume_started_max_s then
      return M.abandon('upload_expired')
    end
  elseif rec.phase == 'collected' then
    local taken = Aptic.time.parse_iso(rec.taken_at)
    if not taken or t - taken > cfg().resume_collected_max_s then return M.abandon('stale_snapshot') end
  end

  if now_ms < U.next_at then return nil end

  local why = M.not_ready()
  if why then
    U.waiting = why
    U.next_at = now_ms + cfg().not_ready_retry_s * 1000
    return nil
  end
  -- What was collected must still match this server.
  local cap = Aptic.capability.detect()
  if rec.adapter and Aptic.capability.pair(cap) ~= rec.adapter then return M.abandon('adapter_changed') end
  local fp = current_salt_fp()
  if rec.salt_fp and fp and rec.salt_fp ~= fp then return M.abandon('salt_changed') end
  U.waiting = nil

  local endpoint = Aptic.convars.read().endpoint
  if endpoint.state ~= 'ok' then
    U.waiting = 'endpoint not usable'
    U.next_at = now_ms + Aptic.config.heartbeat.config_retry_s * 1000
    return nil
  end
  local c = cfg()

  if U.need == 'start' then
    local n, oldest = Aptic.store.count(K().starts, t, 3600)
    if n >= c.starts_per_hour then
      U.waiting = ('start budget (%d an hour)'):format(c.starts_per_hour)
      U.next_at = now_ms + math.max(1, oldest + 3600 - t) * 1000
      return nil
    end
    local body = Aptic.store.read(rec.id, 'start.json')
    if not body then return M.abandon('cache_missing') end
    Aptic.store.note(K().starts, t, 3600)
    U.inflight = { op = 'start', key_prefix = prefix }
    return request(endpoint.url, body, c.request_timeout_ms)
  end
  if U.need == 'status' then
    U.inflight = { op = 'status' }
    return request(endpoint.url, simple_body('status', rec.id), c.request_timeout_ms)
  end
  if U.need == 'chunk' then
    local item = U.missing and U.missing[1]
    if not item then
      U.need = 'finalize'
      return M.next_request(now_ms)
    end
    local rows = Aptic.store.read(rec.id, ('%s.%d.json'):format(item.collection, item.index))
    if not rows then
      U.inflight = { op = 'chunk', collection = item.collection, index = item.index }
      return M.abandon('cache_missing')
    end
    U.inflight = { op = 'chunk', collection = item.collection, index = item.index }
    return request(endpoint.url, Aptic.chunker.chunk_body(rec.id, item.collection, item.index, rows),
      c.request_timeout_ms)
  end
  if U.need == 'finalize' then
    if rec.phase ~= 'finalizing' then set_phase('finalizing') end
    U.inflight = { op = 'finalize' }
    return request(endpoint.url, simple_body('finalize', rec.id), c.finalize_timeout_ms)
  end
  return nil
end

local function after_status(json, now_ms)
  local st = json.status
  if st == 'complete' then return published(json) end
  if st == 'expired' then return M.abandon('upload_expired') end
  if st ~= 'uploading' then return M.abandon('unexpected_status') end
  local have = {}
  if type(json.received) == 'table' then
    for _, r in ipairs(json.received) do
      if type(r) == 'table' and r.collection and r.index then
        have[tostring(r.collection) .. ':' .. tostring(math.floor(tonumber(r.index) or -1))] = true
      end
    end
  end
  local missing = {}
  for _, item in ipairs(all_chunks(U.rec)) do
    if not have[item.collection .. ':' .. item.index] then missing[#missing + 1] = item end
  end
  U.missing = missing
  U.acked = chunk_total(U.rec) - #missing
  if U.rec.phase ~= 'uploading' then set_phase('uploading') end
  U.need = #missing > 0 and 'chunk' or 'finalize'
end

--- Apply the answer to the request next_request() built.
function M.handle(result, now_ms)
  result = type(result) == 'table' and result or { status = 0, transport_error = 'transport_unavailable' }
  local inflight = U.inflight
  if not U.rec or not inflight then return nil end
  local op = inflight.op
  local d = M.decide(op, result, { failures = U.failures, finalize_retries = U.finalize_retries })
  U.last_answer = { at = now(), op = op, status = math.floor(tonumber(result.status) or 0),
    code = d.code, collection = inflight.collection, index = inflight.index }
  -- Pacing: never more than one upload request a second.
  U.next_at = now_ms + cfg().pace_ms

  if d.action == 'ok' then
    -- A status answer alone doesn't end an outage: the backoff keeps growing
    -- until a start, chunk or finalize gets through.
    if op ~= 'status' then U.failures = 0 end
    local json = result.json
    if op == 'start' then
      if json.status == 'complete' then
        published(json)
      else
        if not U.rec.started_at then U.rec.started_at = now() end
        U.rec.key_prefix = inflight.key_prefix
        U.rec.phase = 'started'
        save()
        if json.replayed then
          U.need = 'status'
        else
          U.missing = all_chunks(U.rec)
          U.acked = 0
          set_phase('uploading')
          U.need = #U.missing > 0 and 'chunk' or 'finalize'
        end
      end
    elseif op == 'status' then
      after_status(json, now_ms)
    elseif op == 'chunk' then
      if U.missing and U.missing[1] and U.missing[1].collection == inflight.collection
        and U.missing[1].index == inflight.index then
        table.remove(U.missing, 1)
      end
      U.acked = (U.acked or 0) + 1
      if not U.missing or #U.missing == 0 then U.need = 'finalize' end
    elseif op == 'finalize' then
      if json.status == 'complete' then
        published(json)
      else
        U.need = 'status'
      end
    end
  elseif d.action == 'retry' then
    U.next_at = now_ms + math.floor(d.delay_s * 1000)
    log().change('upload', 'warn', 'Aptic is rate-limiting this key (%s); the upload waits %s and sends the same request again.',
      d.code, Aptic.time.human(d.delay_s))
  elseif d.action == 'transient' then
    U.failures = d.failures
    U.next_at = now_ms + math.floor(d.delay_s * 1000)
    U.need = op == 'start' and 'start' or 'status'
    log().change('upload', 'warn', 'Snapshot upload paused: Aptic is unreachable (%s). Retrying with backoff; '
      .. 'the upload resumes from the chunks Aptic already has.', d.code)
    log().debug('upload %s failed (%s); next try in %s', op, d.code, Aptic.time.human(d.delay_s))
  elseif d.action == 'resync' then
    U.finalize_retries = U.finalize_retries + 1
    U.need = 'status'
    log().warn('Aptic says snapshot %s is incomplete (%s); sending the missing chunks and finalizing once more.',
      U.rec.id, d.code)
  elseif d.action == 'wait_start' then
    U.next_at = now_ms + math.floor(d.delay_s * 1000)
    U.need = 'start'
    log().warn('Snapshot %s waits %s before starting (%s).', U.rec.id, Aptic.time.human(d.delay_s), d.code)
  elseif d.action == 'abandon' then
    M.abandon(d.code, d)
  end
  U.inflight = nil
  return d
end

--- One wake: send an upload request if one is due.
function M.step()
  local req = M.next_request(Aptic.time.monotonic_ms())
  if not req then return false end
  local result = Aptic.transport.post(req)
  M.handle(result, Aptic.time.monotonic_ms())
  return true
end

-- Status ----------------------------------------------------------------------------------

--- A short description of the current state, for `aptic status`.
function M.describe()
  local rec = U.rec
  if U.hold then return 'stopped: ' .. U.hold.cause end
  if not rec then return 'idle' end
  if rec.phase == 'collecting' then return 'collecting ' .. rec.id end
  local total = chunk_total(rec)
  local text = ('%s %s'):format(rec.phase, rec.id)
  if rec.phase == 'uploading' or rec.phase == 'finalizing' then
    text = text .. (' (%d/%d chunks)'):format(math.min(total, U.acked or 0), total)
  end
  if U.waiting then text = text .. '; waiting: ' .. U.waiting end
  return text
end

return M
