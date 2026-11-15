-- Lua side of the JS transport (server/transport.js). Lua never does HTTP or
-- crypto itself, and never calls PerformHttpRequest (decision D4): it would
-- send the key over TLS without checking the certificate.

Aptic = Aptic or {}
local M = {}
Aptic.transport = M

local function js()
  return exports[GetCurrentResourceName()]
end

--- POST one request and wait for the answer (yields the calling thread).
--- `request` is { endpoint, payload, timeout_ms }. See transport.js for the
--- result fields.
function M.post(request)
  local p = promise.new()
  local ok = pcall(function()
    js():httpPost(request, function(result) p:resolve(result) end)
  end)
  if not ok then
    return { ok = false, status = 0, transport_error = 'transport_unavailable' }
  end
  local result = Citizen.Await(p)
  if type(result) ~= 'table' then
    return { ok = false, status = 0, transport_error = 'transport_unavailable' }
  end
  return result
end

--- `n` random bytes as hex, from Node's crypto.randomBytes. nil if the JS
--- side is unavailable.
function M.random_hex(n)
  local ok, value = pcall(function() return js():randomHex(n) end)
  if ok and type(value) == 'string' and #value == n * 2 then return value end
  return nil
end

--- The 8-hex salt fingerprint (C9), or nil.
function M.salt_fingerprint(salt)
  local ok, value = pcall(function() return js():saltFingerprint(salt) end)
  if ok and type(value) == 'string' and value:match('^%x%x%x%x%x%x%x%x$') then
    return value
  end
  return nil
end

return M
