-- The `aptic` command: `aptic status`, `aptic salt`, `aptic validate
-- [--verbose]`, `aptic upload now` and `aptic upload status`.
--
-- Registered as restricted, so FiveM allows the server console (and txAdmin's
-- live console) and players with the ACE `command.aptic`:
--   add_ace group.admin command.aptic allow
-- Output never contains the key or the salt: the key shows as the
-- 16-character prefix the dashboard also shows, the salt as yes/no plus its
-- fingerprint. `aptic salt` (console only) repeats the server.cfg line for a
-- salt that is not pinned yet; a pinned salt is never printed.

Aptic = Aptic or {}
local M = {}
Aptic.status = M

local CONSOLE = 0

--- The `aptic status` lines.
function M.lines()
  local hb = Aptic.heartbeat.state
  local cfg = Aptic.convars.read()
  local cap = Aptic.capability.detect()
  local salt = Aptic.identity.salt(cfg.salt)
  local now = Aptic.time.now()
  local out = {}
  local function add(label, value) out[#out + 1] = ('%-15s %s'):format(label, value) end

  out[#out + 1] = ('aptic_bridge %s'):format(Aptic.identity.version())

  local ep = cfg.endpoint
  add('endpoint', ep.state == 'ok'
    and (ep.url .. (ep.secure and '' or ' (dev, plain http)') .. (ep.custom and '' or ' (default)'))
    or ('invalid: ' .. (ep.reason or '?')))

  if cfg.key.state == 'ok' then
    add('key', ('set (%s…)'):format(cfg.key.prefix))
  else
    add('key', cfg.key.state == 'missing' and 'not set' or 'set, but not a valid apt_ing_ key')
  end

  local last = hb.last
  if last then
    local result = last.state == 'ok' and 'ok' or (last.state .. ' (' .. tostring(last.code) .. ')')
    add('last heartbeat', ('%s, HTTP %d, %s ago'):format(result, last.status or 0, Aptic.time.human(now - last.at)))
  else
    add('last heartbeat', 'none sent yet')
  end
  if hb.blocked then add('not sending', hb.blocked.code) end
  if hb.last_ok_at and (not last or last.state ~= 'ok') then
    add('last accepted', Aptic.time.iso(hb.last_ok_at))
  end
  if hb.hold == 'key_change' then
    add('next heartbeat', 'when aptic_api_key changes')
  elseif hb.next_at and hb.state ~= 'starting' then
    local wait = math.max(0, (hb.next_at - Aptic.time.monotonic_ms()) / 1000)
    add('next heartbeat', 'in ' .. Aptic.time.human(wait))
  end
  if hb.clock_offset_s then add('clock offset', ('%+d s'):format(hb.clock_offset_s)) end

  add('framework', cap.framework
    and (cap.framework .. ' ' .. (cap.framework_version or '(version unknown)') .. ' [' .. cap.framework_resource .. ']')
    or 'not detected')
  add('inventory', cap.inventory
    and (cap.inventory .. ' ' .. (cap.inventory_version or '(version unknown)'))
    or 'not detected')
  if cap.support == 'supported' then
    add('support', 'supported (' .. cap.note .. ')')
  else
    add('support', cap.support .. ': ' .. (cap.reason or '?'))
  end

  if salt.pinned then
    add('salt pinned', 'yes (fingerprint ' .. (salt.fp or 'unavailable') .. ')')
  else
    add('salt pinned', (salt.invalid and 'no (aptic_salt is not 64 hex)' or 'no')
      .. '; run `aptic salt` on the console for the line to add')
  end
  add('instance id', Aptic.identity.instance_id() or 'unavailable')

  add('snapshots', M.snapshot_line())
  if hb.latest_agent_version
    and Aptic.policy.compare_versions(Aptic.identity.version(), hb.latest_agent_version) < 0 then
    add('update', 'aptic_bridge ' .. hb.latest_agent_version .. ' is available')
  end
  return out
end

local function ago(epoch)
  return Aptic.time.human(math.max(0, Aptic.time.now() - epoch)) .. ' ago'
end

local function last_published_text()
  local lp = Aptic.store.get_json(Aptic.store.KVP.last_published)
  if type(lp) ~= 'table' or type(lp.at) ~= 'number' then return nil, nil end
  return ('%s (%s)'):format(Aptic.time.iso(lp.at), ago(lp.at)), lp
end

local function next_slot_text()
  local wait = Aptic.scheduler.next_slot_in()
  if not wait then return 'not scheduled yet' end
  return ('in %s (%s)'):format(Aptic.time.human(wait), Aptic.time.iso(Aptic.time.now() + wait))
end

--- The one-line snapshot summary in `aptic status`.
function M.snapshot_line()
  if not Aptic.scheduler.has_collector() then
    local blockers = Aptic.heartbeat.snapshot_blockers()
    return 'collection not available in this version'
      .. (#blockers > 0 and ('; would be blocked by: ' .. table.concat(blockers, ', ')) or '')
  end
  local published = last_published_text()
  local parts = {
    'last published ' .. (published or 'never'),
    'state ' .. (Aptic.scheduler.state.collecting and 'collecting' or Aptic.uploader.describe()),
    'next slot ' .. next_slot_text(),
  }
  local blockers = Aptic.heartbeat.snapshot_blockers()
  if #blockers > 0 then parts[#parts + 1] = 'blocked by: ' .. table.concat(blockers, ', ') end
  return table.concat(parts, '; ')
end

local function describe_outcome(last)
  if type(last) ~= 'table' or type(last.at) ~= 'number' then return 'none yet' end
  if last.result == 'published' then
    return ('published %s, %d rows, %s'):format(tostring(last.snapshot_id), tonumber(last.rows) or 0, ago(last.at))
  end
  local where = ''
  if last.collection then
    where = ', ' .. tostring(last.collection) .. (last.index and (' ' .. tostring(last.index)) or '')
      .. (last.reason and (' ' .. tostring(last.reason)) or '')
  end
  return ('dropped %s (%s%s), %s'):format(tostring(last.snapshot_id or '-'), tostring(last.code), where, ago(last.at))
end

--- The `aptic upload status` lines.
function M.upload_lines()
  local U = Aptic.uploader.state
  local c = Aptic.config.upload
  local now = Aptic.time.now()
  local out = {}
  local function add(label, value) out[#out + 1] = ('%-15s %s'):format(label, value) end
  add('upload state', Aptic.scheduler.state.collecting and 'collecting' or Aptic.uploader.describe())
  if U.rec and U.rec.taken_at then add('taken at', U.rec.taken_at) end
  if U.rec and U.need and not U.waiting then
    local wait = math.max(0, (U.next_at - Aptic.time.monotonic_ms()) / 1000)
    add('next request', U.need .. ' in ' .. Aptic.time.human(wait))
  end
  add('last result', describe_outcome(U.last))
  local published, lp = last_published_text()
  add('last published', published and (published .. (', %d rows'):format(tonumber(lp.rows) or 0)) or 'never')
  add('next slot', Aptic.scheduler.has_collector() and next_slot_text() or 'none: collection is not available in this version')
  add('quota', ('%d/%d published in 24 h, %d/%d starts this hour'):format(
    (Aptic.store.count(Aptic.store.KVP.published, now, 86400)), c.daily_guard,
    (Aptic.store.count(Aptic.store.KVP.starts, now, 3600)), c.starts_per_hour))
  local why = not U.rec and Aptic.scheduler.guard(now) or nil
  if why then add('not running', why) end
  return out
end

local function upload_now_lines()
  local ok, why = Aptic.scheduler.request_now()
  if ok then return { 'Snapshot queued; it starts within a second. `aptic upload status` shows progress.' } end
  return { 'Not starting a snapshot: ' .. why .. '.' }
end

local function reply(source, lines)
  for _, line in ipairs(lines) do
    if source == CONSOLE then
      Aptic.log.info('%s', line)
    else
      TriggerClientEvent('chat:addMessage', source, { args = { 'aptic', Aptic.log.redact(line) } })
    end
  end
end

local function salt_lines(source)
  if source ~= CONSOLE then
    return { '`aptic salt` works only on the server console.' }
  end
  local salt = Aptic.identity.salt(Aptic.convars.read().salt)
  if salt.pinned then
    return { ('The salt is pinned (fingerprint %s). Its value is never printed; it is in your server.cfg.')
      :format(salt.fp or 'unavailable') }
  end
  if not salt.pending then return { 'Could not generate a salt: transport.js is not loaded.' } end
  return {
    'Add this line to server.cfg, keep a backup of it, and restart:',
    ('  set aptic_salt "%s"'):format(salt.pending),
  }
end

--- The command handler.
function M.command(source, args)
  source = tonumber(source) or CONSOLE
  if source ~= CONSOLE and not IsPlayerAceAllowed(source, 'command.' .. Aptic.config.command) then
    return
  end
  local sub = args and args[1] and tostring(args[1]):lower() or 'status'
  if sub == 'status' then
    reply(source, M.lines())
  elseif sub == 'salt' then
    reply(source, salt_lines(source))
  elseif sub == 'validate' then
    M.validate(source, args)
  elseif sub == 'upload' then
    local what = args[2] and tostring(args[2]):lower() or 'status'
    if what == 'now' then
      reply(source, upload_now_lines())
    elseif what == 'status' then
      reply(source, M.upload_lines())
    else
      reply(source, { 'usage: aptic upload now | aptic upload status' })
    end
  else
    reply(source, { 'usage: aptic status | aptic salt | aptic validate [--verbose] | aptic upload now | aptic upload status' })
  end
end

--- `aptic validate [--verbose]`: collect and check without uploading, in a
--- thread (the collector yields). Names only on the server console.
function M.validate(source, args)
  local verbose = false
  for i = 2, #(args or {}) do
    local a = tostring(args[i]):lower()
    if a == '--verbose' or a == '-v' or a == 'verbose' then verbose = true end
  end
  local notes = {}
  if verbose and source ~= CONSOLE then
    verbose = false
    notes[1] = '--verbose works only on the server console; showing counts only.'
  end
  if Aptic.selfcheck.state.running then
    reply(source, { 'aptic validate is already running.' })
    return
  end
  reply(source, { 'Checking a snapshot locally (nothing is uploaded)...' })
  CreateThread(function()
    local report = Aptic.selfcheck.run({ verbose = verbose })
    local lines = Aptic.selfcheck.lines(report, { verbose = verbose, console = source == CONSOLE })
    for _, n in ipairs(notes) do lines[#lines + 1] = n end
    reply(source, lines)
  end)
end

function M.register()
  RegisterCommand(Aptic.config.command, function(source, args) M.command(source, args) end, true)
end

return M
