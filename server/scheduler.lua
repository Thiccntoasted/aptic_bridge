-- When snapshots run (decision D9, plan §5.1): every 60 minutes by default,
-- at a minute picked at random once per install and kept in KVP, so servers
-- don't all upload on the hour and a restart keeps the same minute. Slots
-- are on the UTC wall clock: slot k is at k * interval + offset.
--
-- A slot runs a snapshot only when nothing blocks it (decision D8):
--   * no snapshot is already in progress (one at a time, never re-collected
--     while an upload can still be resumed);
--   * heartbeat.snapshot_blockers() is empty: salt pinned, a supported
--     framework + inventory, and the last heartbeat accepted (so a refused
--     key, adapter mismatch or locked workspace stops snapshots too);
--   * uploads aren't stopped (outdated bridge, full storage, a header bug);
--   * fewer than 90 snapshots were published in the last 24 h (Aptic's limit
--     is 96) and fewer than 3 starts were sent in the last hour;
--   * an answer from Aptic didn't ask to wait longer (defer).
-- `aptic upload now` runs one at once, through the same checks.
--
-- start() runs the loop: each wake (config.tick_ms) asks the scheduler
-- whether a snapshot is due, then lets the uploader send at most one request.

Aptic = Aptic or {}
local M = {}
Aptic.scheduler = M

local function cfg() return Aptic.config.upload end
local function log() return Aptic.log end

local S = {}
M.state = S

function M.reset()
  for k in pairs(S) do S[k] = nil end
  S.not_before = 0
end
M.reset()

--- The interval in seconds, kept within the §5.1 bounds.
function M.interval_s()
  local c = cfg()
  local minutes = tonumber(c.interval_min) or 60
  minutes = math.max(c.min_interval_min, math.min(c.max_interval_min, minutes))
  return math.floor(minutes * 60)
end

--- This install's offset into each interval (seconds), random once, then kept.
function M.offset_s()
  local interval = M.interval_s()
  local key = Aptic.store.KVP.slot_offset
  local stored = Aptic.store.get_number(key)
  if not stored or stored < 0 then
    stored = math.random(0, 4 * 3600 - 1) -- covers any interval up to the 240 min maximum
    Aptic.store.set_number(key, stored)
  end
  return math.floor(stored) % interval
end

--- The first slot strictly after `epoch`.
function M.next_slot(epoch)
  local interval, offset = M.interval_s(), M.offset_s()
  local t = math.floor(epoch)
  return t - ((t - offset) % interval) + interval
end

function M.has_collector()
  return Aptic.collector ~= nil and type(Aptic.collector.run) == 'function'
end

--- Put off the next snapshot until at least `seconds` from now.
function M.defer(seconds)
  local until_at = Aptic.time.now() + math.max(0, tonumber(seconds) or 0)
  if until_at > (S.not_before or 0) then S.not_before = until_at end
end

--- Why a snapshot can't run now, or nil.
function M.guard(t)
  t = t or Aptic.time.now()
  local c = cfg()
  if not M.has_collector() then return 'collection is not available in this version' end
  local U = Aptic.uploader.state
  if S.collecting then return 'a snapshot is being collected' end
  if U.rec then return 'snapshot ' .. U.rec.id .. ' is still ' .. U.rec.phase end
  if U.hold then return 'uploads are stopped (' .. U.hold.cause .. ')' end
  local blockers = Aptic.heartbeat.snapshot_blockers()
  if #blockers > 0 then return table.concat(blockers, ', ') end
  local published = Aptic.store.count(Aptic.store.KVP.published, t, 86400)
  if published >= c.daily_guard then
    return ('%d snapshots published in the last 24 h (the bridge stops at %d)'):format(published, c.daily_guard)
  end
  local starts = Aptic.store.count(Aptic.store.KVP.starts, t, 3600)
  if starts >= c.starts_per_hour then
    return ('%d starts sent in the last hour (the bridge allows %d)'):format(starts, c.starts_per_hour)
  end
  if (S.not_before or 0) > t then
    return 'Aptic asked to wait until ' .. Aptic.time.iso(S.not_before)
  end
  return nil
end

local function run(manual)
  S.collecting = true
  S.last_run_at = Aptic.time.now()
  local ok, code = pcall(Aptic.uploader.collect, { manual = manual })
  S.collecting = false
  if not ok then
    log().error('snapshot collection error: %s', tostring(code):sub(1, 200))
    return false
  end
  return code
end

--- One wake: run a snapshot if a slot (or `aptic upload now`) is due.
function M.step()
  local t = Aptic.time.now()
  if not S.next_slot then S.next_slot = M.next_slot(t) end
  local due = t >= S.next_slot
  if due then S.next_slot = M.next_slot(t) end
  local manual = S.requested
  if not (due or manual) then return false end
  S.requested = nil

  local why = M.guard(t)
  if why then
    S.last_skip = { at = t, reason = why }
    if M.has_collector() then
      log().change('schedule', 'warn', 'Snapshot slot skipped: %s. Next slot %s.', why, Aptic.time.iso(S.next_slot))
    end
    return false
  end
  Aptic.log.reset('schedule')
  return run(manual)
end

--- `aptic upload now`: queue a snapshot for the next wake. Returns true, or
--- false and why it can't run.
function M.request_now()
  local why = M.guard()
  if why then return false, why end
  S.requested = true
  return true
end

--- Seconds until the next slot (nil before the first wake).
function M.next_slot_in()
  if not S.next_slot then return nil end
  return math.max(0, S.next_slot - Aptic.time.now())
end

--- Start the upload loop. Picks up a snapshot a previous run left behind.
function M.start()
  if S.running then return end
  S.running = true
  local ok, err = pcall(Aptic.uploader.init)
  if not ok then log().error('could not read the saved snapshot state: %s', tostring(err):sub(1, 200)) end
  S.next_slot = M.next_slot(Aptic.time.now())
  if not M.has_collector() then
    log().warn('Snapshot collection is not available in this version (no collector is loaded). Heartbeats continue.')
  end
  CreateThread(function()
    while true do
      local ok1, err1 = pcall(M.step)
      if not ok1 then log().error('snapshot scheduler error: %s', tostring(err1):sub(1, 200)) end
      local ok2, err2 = pcall(Aptic.uploader.step)
      if not ok2 then
        log().error('snapshot upload error: %s', tostring(err2):sub(1, 200))
        Aptic.uploader.state.next_at = Aptic.time.monotonic_ms() + Aptic.config.heartbeat.config_retry_s * 1000
      end
      Wait(Aptic.config.tick_ms)
    end
  end)
end

return M
