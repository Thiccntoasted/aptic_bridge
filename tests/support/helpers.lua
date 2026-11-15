-- Shared setup for the Lua tests.

H = {}

-- Test-only values in the right shape. Not real credentials.
H.KEY = 'apt_ing_TESTkeyAAAAbbbbCCCCddddEEEEffffGGGGhhhh1234'
H.KEY2 = 'apt_ing_ROTATEDzzzzYYYYxxxxWWWWvvvvUUUUttttSSSS9876'
H.SALT = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'

assert(#H.KEY == 51 and #H.KEY2 == 51, 'test keys must be 51 characters')

--- A configured server: Qbox + ox_inventory, key and salt set.
function H.server(opts)
  opts = opts or {}
  if opts.key ~= false then Stub.convars.aptic_api_key = opts.key or H.KEY end
  if opts.salt ~= false then Stub.convars.aptic_salt = opts.salt or H.SALT end
  if opts.endpoint then Stub.convars.aptic_endpoint = opts.endpoint end
  Stub.convars.sv_maxclients = opts.max_clients or 48
  local fw = opts.framework or 'qbox'
  local inv = opts.inventory or 'ox_inventory'
  if fw == 'qbox' then Stub.start('qbx_core', opts.framework_version or '1.24.1') end
  if fw == 'qbcore' then Stub.start('qb-core', opts.framework_version or '1.3.0') end
  if inv == 'ox_inventory' then Stub.start('ox_inventory', opts.inventory_version or 'v2.44.1') end
  if inv == 'qb-inventory' then Stub.start('qb-inventory', opts.inventory_version or '2.2.3') end
end

--- Replace the transport with a scripted one. Each answer is a result table
--- (see transport.js); the last answer repeats. Returns the request log.
function H.fake_transport(answers)
  local sent = {}
  local i = 0
  Aptic.transport.post = function(request)
    sent[#sent + 1] = request
    i = math.min(i + 1, #answers)
    return answers[i]
  end
  return sent
end

H.OK = { ok = true, status = 200, json = { ok = true, server_time = '2026-11-15T12:00:00+00:00',
  min_agent_version = '0.1.0', latest_agent_version = '0.1.0' }, elapsed_ms = 40 }

function H.err(status, code, extra)
  local r = { ok = false, status = status, code = code, json = { error = code } }
  for k, v in pairs(extra or {}) do r[k] = v end
  return r
end

--- Advance the fake clock and run one loop wake. Returns true if a request went out.
function H.tick(ms)
  Stub.timer = Stub.timer + (ms or 0)
  return Aptic.heartbeat.step()
end

--- Advance in 1 s wakes until a request goes out or `max_s` passes.
--- Returns the seconds waited, or nil.
function H.until_sent(max_s)
  for s = 1, max_s do
    if H.tick(1000) then return s end
  end
  return nil
end
