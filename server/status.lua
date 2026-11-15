-- The `aptic` command: `aptic status` and `aptic salt`.
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

  local blockers = Aptic.heartbeat.snapshot_blockers()
  add('snapshots', 'not in this version (heartbeat only)'
    .. (#blockers > 0 and ('; would be blocked by: ' .. table.concat(blockers, ', ')) or ''))
  if hb.latest_agent_version
    and Aptic.policy.compare_versions(Aptic.identity.version(), hb.latest_agent_version) < 0 then
    add('update', 'aptic_bridge ' .. hb.latest_agent_version .. ' is available')
  end
  return out
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
  else
    reply(source, { 'usage: aptic status | aptic salt' })
  end
end

function M.register()
  RegisterCommand(Aptic.config.command, function(source, args) M.command(source, args) end, true)
end

return M
