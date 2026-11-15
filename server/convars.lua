-- Server configuration from convars. Read again before every request, so a
-- key rotated with `set aptic_api_key "..."` in the live console is picked up
-- without a restart.
--
-- The key itself never leaves this function: callers get its state and the
-- 16-character prefix the dashboard also shows. The transport reads the key
-- from the convar on its own. The salt value is returned (identity needs it
-- for the fingerprint) and registered with the log as a secret.

Aptic = Aptic or {}
local M = {}
Aptic.convars = M

local KEY_LENGTH = 51 -- 'apt_ing_' + 43 base64url characters
local LOCAL_HOSTS = { ['localhost'] = true, ['127.0.0.1'] = true, ['[::1]'] = true }

local function trim(s)
  return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end
M.trim = trim

local function read_key()
  local raw = trim(GetConvar('aptic_api_key', ''))
  if raw == '' then return { state = 'missing' } end
  Aptic.log.add_secret(raw)
  if #raw == KEY_LENGTH and raw:match('^apt_ing_[%w_%-]+$') then
    return { state = 'ok', prefix = raw:sub(1, 16) }
  end
  return { state = 'invalid' }
end

local function read_salt()
  local raw = trim(GetConvar('aptic_salt', ''))
  if raw == '' then return { state = 'missing' } end
  Aptic.log.add_secret(raw)
  local value = raw:lower()
  if #value == 64 and value:match('^%x+$') then
    return { state = 'pinned', value = value }
  end
  return { state = 'invalid' }
end

--- Check an endpoint URL. https only; http for localhost when dev is on.
function M.check_endpoint(raw, dev)
  local url = trim(raw):gsub('/+$', '')
  local scheme, rest = url:match('^(%a[%w+.-]*)://(.+)$')
  if not scheme then return { state = 'invalid', url = url, reason = 'not a URL' } end
  scheme = scheme:lower()
  local authority = rest:match('^([^/?#]*)')
  if authority == '' or authority:find('@', 1, true) or url:find('#', 1, true) then
    return { state = 'invalid', url = url, reason = 'not a valid endpoint URL' }
  end
  local host = authority:match('^(%[[^%]]+%])') or authority:match('^([^:]+)')
  host = host and host:lower() or ''
  if scheme == 'https' then
    return { state = 'ok', url = url, host = host, secure = true }
  end
  if scheme == 'http' and LOCAL_HOSTS[host] then
    if dev then return { state = 'ok', url = url, host = host, secure = false } end
    return { state = 'invalid', url = url, host = host,
      reason = 'http is only allowed for localhost with `set aptic_dev 1`' }
  end
  return { state = 'invalid', url = url, host = host, reason = 'the endpoint must use https://' }
end

--- Everything the bridge reads from server.cfg, freshly.
function M.read()
  local dev = trim(GetConvar('aptic_dev', '0')) == '1'
  local endpoint = trim(GetConvar('aptic_endpoint', ''))
  local custom = endpoint ~= ''
  if not custom then endpoint = Aptic.config.default_endpoint end
  local checked = M.check_endpoint(endpoint, dev)
  checked.custom = custom
  return {
    key = read_key(),
    salt = read_salt(),
    endpoint = checked,
    dev = dev,
  }
end

return M
