-- Install identity and hash-salt state (decision D8, contract C9).
--
-- instance_id: random per install, kept in KVP, sent on every heartbeat so
--   Aptic can tell when two servers share one key.
-- salt: must be pinned in server.cfg as `set aptic_salt "<64 hex>"`. Without
--   it the bridge generates one, keeps it in KVP (so every restart suggests
--   the same value), prints the exact line to add, and refuses to upload
--   snapshots. Heartbeats still run so the dashboard shows the server. The
--   fingerprint (salt_fp) is sent only once a salt is pinned. The pinned
--   salt is never printed.

Aptic = Aptic or {}
local M = {}
Aptic.identity = M

M.KVP_INSTANCE = 'instance_id.v1'
M.KVP_PENDING_SALT = 'salt.pending.v1'

local instance_cache
local fp_cache = {}

--- This resource's version, from `version` in fxmanifest.lua.
function M.version()
  local v = Aptic.capability.clean_version(
    GetResourceMetadata(GetCurrentResourceName(), 'version', 0))
  return v or '0.0.0'
end

--- agent_version as the contract wants it (1-32 chars): aptic_bridge/0.1.0
function M.agent_version()
  return ('aptic_bridge/' .. M.version()):sub(1, 32)
end

local function valid_instance(v)
  return type(v) == 'string' and #v >= 8 and #v <= 64 and v:match('^[%w_%-]+$') ~= nil
end

--- The install's instance id, created on first use. nil only if the JS side
--- can't produce random bytes.
function M.instance_id()
  if instance_cache then return instance_cache end
  local stored = GetResourceKvpString(M.KVP_INSTANCE)
  if valid_instance(stored) then
    instance_cache = stored
    return stored
  end
  local fresh = Aptic.transport.random_hex(16)
  if not fresh then return nil end
  SetResourceKvp(M.KVP_INSTANCE, fresh)
  instance_cache = fresh
  return fresh
end

--- The salt state from the convars read by Aptic.convars.read():
---   { pinned = true, fp = '4f1c09ab' }
---   { pinned = false, invalid = bool, pending = '<64 hex>' }  (pending: the
---     generated value to suggest; never sent anywhere)
function M.salt(salt_cfg)
  if salt_cfg.state == 'pinned' then
    local fp = fp_cache[salt_cfg.value]
    if not fp then
      fp = Aptic.transport.salt_fingerprint(salt_cfg.value)
      if fp then fp_cache[salt_cfg.value] = fp end
    end
    -- Pinned now: the suggested value has no further use, so don't keep it.
    if GetResourceKvpString(M.KVP_PENDING_SALT) then DeleteResourceKvp(M.KVP_PENDING_SALT) end
    return { pinned = true, fp = fp }
  end
  local pending = GetResourceKvpString(M.KVP_PENDING_SALT)
  if not (type(pending) == 'string' and #pending == 64 and pending:match('^%x+$')) then
    pending = Aptic.transport.random_hex(32)
    if pending then SetResourceKvp(M.KVP_PENDING_SALT, pending) end
  end
  return { pinned = false, invalid = salt_cfg.state == 'invalid', pending = pending }
end

--- Print what the owner must do about the salt. Called at start and when the
--- salt stops being pinned; `aptic salt` prints it again on the console.
function M.print_salt_instructions(salt)
  local log = Aptic.log
  if salt.pinned then return end
  if salt.invalid then
    log.warn('aptic_salt is set but is not 64 hex characters, so it is ignored.')
  else
    log.warn('No hash salt is pinned (aptic_salt).')
  end
  if salt.pending then
    log.warn('Add this line to server.cfg, keep a backup of it, and restart:')
    log.warn('  set aptic_salt "%s"', salt.pending)
  else
    log.warn('Could not generate a salt (transport.js not loaded). Add `set aptic_salt "<64 hex>"` to server.cfg.')
  end
  log.warn('Snapshots will not upload until the salt is pinned. Heartbeats continue.')
end

return M
