-- A fake Aptic ingest API for the upload tests: start, chunk, status and
-- finalize with the rules of receive_ingest that matter to the bridge
-- (replay vs conflict, credential binding, expiry, counts, contiguity, out
-- of order, two live uploads). Stricter than the real one in one way: a
-- replayed chunk must be the same bytes, not merely the same JSON.
--
-- Also the helpers that drive the whole resource on a fake clock (game timer
-- and wall clock together) and play a restart.

dofile('tests/support/fake_collector.lua')

FakeAptic = {}

local function ok(json)
  json.ok = true
  return { ok = true, status = 200, json = json, elapsed_ms = 20 }
end
FakeAptic.ok = ok

local STATUS = {
  invalid_json = 400, invalid_payload = 400, unsupported_version = 400, snapshot_clock_invalid = 400,
  invalid_credential = 401, workspace_locked = 403, plan_limit_exceeded = 403,
  upload_unavailable = 404, body_too_large = 413, snapshot_too_large = 413, upload_quota_exceeded = 413,
  storage_quota_exceeded = 413, unsupported_media_type = 415, adapter_mismatch = 422,
  rate_limited = 429, start_rate_limited = 429, daily_snapshot_limit = 429, ingest_unavailable = 503,
}

--- An error answer as transport.js would report it. `retry` is the body's
--- retry_after (413/429 carry it, number or null).
function FakeAptic.err(code, retry, extra)
  local status = STATUS[code] or 409
  local json = { error = code }
  if status == 413 or status == 429 then json.retry_after = retry end
  for k, v in pairs(extra or {}) do json[k] = v end
  return { ok = false, status = status, code = code, json = json,
    retry_after_body = (status == 413 or status == 429) and retry or nil,
    retry_after_header = status == 429 and (retry or 60) or nil }
end
local err = FakeAptic.err

local ENVELOPE = { 'version', 'operation', 'framework', 'inventory', 'instance_id', 'salt_fp',
  'agent_version', 'framework_version', 'inventory_version' }

function FakeAptic.new()
  local srv = {
    uploads = {}, published = {}, log = {}, faults = {},
    latest = nil, -- latest published taken_at (epoch)
    heartbeats = 0,
  }

  function srv:key() return Stub.convars.aptic_api_key end

  --- Add a fault: { op, collection, index, result, after = bool, times = n }.
  --- `after` applies the request first and then answers with `result` (the
  --- answer is lost or wrong, the server did the work).
  function srv:fault(f)
    f.times = f.times or 1
    self.faults[#self.faults + 1] = f
  end

  function srv:take_fault(p)
    for i, f in ipairs(self.faults) do
      -- A fault without op never hits heartbeats.
      if ((f.op == nil and p.operation ~= 'heartbeat') or f.op == p.operation)
        and (f.collection == nil or f.collection == p.collection)
        and (f.index == nil or f.index == p.index) then
        f.times = f.times - 1
        if f.times <= 0 then table.remove(self.faults, i) end
        return f
      end
    end
    return nil
  end

  function srv:requests(op)
    local out = {}
    for _, r in ipairs(self.log) do if not op or r.op == op then out[#out + 1] = r end end
    return out
  end

  function srv:live()
    local n = 0
    for _, u in pairs(self.uploads) do
      if u.status == 'uploading' and u.expires > Aptic.time.now() then n = n + 1 end
    end
    return n
  end

  function srv:apply(p, body)
    local now = Aptic.time.now()
    if p.operation == 'heartbeat' then
      self.heartbeats = self.heartbeats + 1
      return ok({ server_time = Aptic.time.iso(now), min_agent_version = '0.1.0', latest_agent_version = '0.1.0' })
    end
    local u = self.uploads[p.snapshot_id]
    if u and u.status == 'uploading' and u.expires <= now then u.status = 'expired' end

    if p.operation == 'start' then
      local def = {}
      for k, v in pairs(p) do def[k] = v end
      for _, k in ipairs(ENVELOPE) do def[k] = nil end
      local def_json = Aptic.chunker.encode(def)
      if u then
        if u.def ~= def_json then return err('request_conflict') end
        if u.status == 'expired' then return err('upload_expired') end
        if u.key ~= self:key() and u.status ~= 'complete' then return err('credential_rotated') end
        return ok({ status = u.status, replayed = true })
      end
      local taken = Aptic.time.parse_iso(p.taken_at)
      if self.latest and taken <= self.latest then return err('snapshot_out_of_order') end
      if taken > now + 120 or taken < now - 86400 then return err('snapshot_clock_invalid') end
      if self:live() >= 2 then return err('upload_quota_exceeded', 1800) end
      self.uploads[p.snapshot_id] = { def = def_json, manifest = p.manifest, taken = taken, chunks = {},
        status = 'uploading', key = self:key(), expires = now + 3600, start = p }
      return ok({ status = 'uploading', expires_in = 3600 })
    end

    if not u then return err('upload_unavailable') end
    if p.operation == 'status' then
      local received = {}
      for k, c in pairs(u.chunks) do
        received[#received + 1] = { collection = c.collection, index = c.index, count = c.count, k = k }
      end
      table.sort(received, function(a, b) return a.k < b.k end)
      for _, r in ipairs(received) do r.k = nil end
      return ok({ status = u.status, received = received, job = u.status == 'complete' and 'pending' or nil })
    end
    if p.operation == 'finalize' and u.status == 'complete' then
      return ok({ status = 'complete', replayed = true })
    end
    if u.status ~= 'uploading' then return err('upload_expired') end
    if u.key ~= self:key() then return err('credential_rotated') end

    if p.operation == 'chunk' then
      if #body > 256 * 1024 then return err('body_too_large', nil) end
      local n = type(p.rows) == 'table' and #p.rows or 0
      if n < 1 or n > 200 or p.index < 0 or p.index > 249 then return err('invalid_chunk') end
      local k = ('%s:%03d'):format(p.collection, p.index)
      local prior = u.chunks[k]
      if prior then
        if prior.body ~= body then return err('request_conflict') end
        return ok({ replayed = true })
      end
      local have = 0
      for _, c in pairs(u.chunks) do if c.collection == p.collection then have = have + c.count end end
      if have + n > (u.manifest[p.collection] or 0) then return err('manifest_count_exceeded') end
      u.chunks[k] = { collection = p.collection, index = p.index, count = n, body = body }
      return ok({})
    end

    if p.operation == 'finalize' then
      for collection, expected in pairs(u.manifest) do
        local got, count, max = 0, 0, -1
        for _, c in pairs(u.chunks) do
          if c.collection == collection then
            got = got + c.count; count = count + 1
            if c.index > max then max = c.index end
          end
        end
        if got ~= expected then return err('upload_incomplete') end
        if count > 0 and max + 1 ~= count then return err('chunk_gap') end
      end
      if self.latest and u.taken <= self.latest then return err('snapshot_out_of_order') end
      u.status = 'complete'
      self.latest = u.taken
      self.published[#self.published + 1] = p.snapshot_id
      return ok({ status = 'complete', analysis_status = 'pending' })
    end
    return err('invalid_payload')
  end

  --- The transport: what Aptic.transport.post would return.
  function srv:handle(req)
    local body = req.body or Aptic.chunker.encode(req.payload)
    local p = __json_parse(body)
    self.log[#self.log + 1] = { op = p.operation, collection = p.collection, index = p.index, body = body,
      timeout_ms = req.timeout_ms, at_ms = Stub.timer, key = self:key() }
    local f = self:take_fault(p)
    if f and not f.after then return f.result end
    local result = self:apply(p, body)
    if f then return f.result end
    return result
  end

  return srv
end

-- Driving the resource -----------------------------------------------------------

UP = {}

local real_time = os.time
--- Freeze the wall clock at `epoch` (it then moves only with UP.tick).
function UP.freeze(epoch)
  Stub.epoch = epoch or 1794744000 -- 2026-11-15T12:00:00Z
  os.time = function(t)
    if t then return real_time(t) end
    return math.floor(Stub.epoch)
  end
end

--- Route every request (heartbeats too) to `srv`.
function UP.connect(srv)
  Aptic.transport.post = function(req) return srv:handle(req) end
end

--- A configured server with the fake Aptic and the fake collector, booted
--- (status command, saved state read). Returns srv, spec.
function UP.setup(opts)
  opts = opts or {}
  UP.freeze(opts.epoch)
  H.server(opts.server)
  local srv = opts.srv or FakeAptic.new()
  UP.connect(srv)
  local spec = opts.collector ~= false and FakeCollector.install(opts.collector) or nil
  Aptic.status.register()
  Aptic.scheduler.start()
  return srv, spec
end

--- Advance both clocks by `ms` and run one wake of each loop. Returns true
--- when the uploader sent a request.
function UP.tick(ms)
  ms = ms or 1000
  Stub.timer = Stub.timer + ms
  Stub.epoch = Stub.epoch + ms / 1000
  Aptic.heartbeat.step()
  Aptic.scheduler.step()
  return Aptic.uploader.step()
end

--- Tick a second at a time until `pred()` is true; the seconds it took, or nil.
function UP.until_(pred, max_s)
  for s = 1, max_s or 600 do
    UP.tick(1000)
    if pred() then return s end
  end
  return nil
end

--- Queue a snapshot now (as `aptic upload now` does) and run until it is
--- published or dropped. Returns the seconds it took.
function UP.snapshot_now(max_s)
  if not Aptic.heartbeat.state.last_ok_at then UP.tick(0) end
  local ok, why = Aptic.scheduler.request_now()
  if not ok then error('upload now refused: ' .. tostring(why)) end
  local before = Aptic.uploader.state.last
  return UP.until_(function()
    local U = Aptic.uploader.state
    return U.last ~= before and not U.rec
  end, max_s or 900)
end

--- Play a restart: KVP and cache files survive, everything in memory goes,
--- and the game timer starts again from zero. Loads the same scripts again.
function UP.restart(srv, spec)
  Stub.timer = 0
  Stub.threads = {}
  Stub.export_overrides = {}
  Aptic = nil
  for _, file in ipairs(__manifest_lua) do dofile(file) end
  UP.connect(srv)
  if spec then FakeCollector.install(spec) end
  Aptic.status.register()
  Aptic.scheduler.start()
end

--- Everything printed, for grep tests.
function UP.output() return Stub.output() end
