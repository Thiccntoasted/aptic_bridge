-- The M1 "done when": the API key never appears in any log line.
--
-- Runs the resource through every path that prints (boot, each heartbeat
-- outcome, rotation, a malformed key, the status command, debug output)
-- with every line captured, then greps the whole capture for the key and
-- for any 12-character piece of its secret part. The pinned salt gets the
-- same treatment.

local function pieces(secret, size)
  local out = {}
  for i = 1, #secret - size + 1 do out[#out + 1] = secret:sub(i, i + size - 1) end
  return out
end

local function assert_clean(out, secret, label)
  not_contains(out, secret, label)
  -- The 8 characters after apt_ing_ are the dashboard prefix and may show;
  -- nothing past them may.
  local tail = secret:sub(17)
  for _, piece in ipairs(pieces(tail, 12)) do not_contains(out, piece, label .. ' fragment') end
end

test('no log line, in any scenario, contains the key or the pinned salt', function()
  Stub.convars.aptic_debug = '1'
  H.server()

  -- Boot.
  H.fake_transport({ H.OK })
  Stub.threads[1]()

  -- Every heartbeat outcome.
  local outcomes = {
    H.OK,
    H.err(401, 'invalid_credential'),
    H.err(422, 'adapter_mismatch'),
    H.err(429, 'rate_limited', { retry_after_body = 3 }),
    H.err(403, 'workspace_locked'),
    H.err(403, 'plan_limit_exceeded'),
    H.err(400, 'unsupported_version'),
    H.err(400, 'invalid_payload'),
    H.err(503, 'ingest_unavailable'),
    { ok = false, status = 0, transport_error = 'timeout' },
    { ok = false, status = 0, transport_error = 'tls', detail = 'CERT_HAS_EXPIRED' },
    { ok = false, status = 0, transport_error = 'network', detail = 'ECONNREFUSED' },
    { ok = false, status = 302 },
    -- A hostile or broken server echoing the key back must not get it printed.
    { ok = false, status = 400, code = 'invalid_payload', json = { error = H.KEY } },
  }
  for _, outcome in ipairs(outcomes) do
    Aptic.heartbeat.reset()
    Aptic.log.reset('heartbeat')
    H.fake_transport({ outcome })
    H.tick(1000)
    Aptic.status.command(0, { 'status' })
  end

  -- Rotation to a second key, and a malformed key.
  Aptic.heartbeat.reset()
  H.fake_transport({ H.err(401, 'invalid_credential'), H.OK })
  H.tick(1000)
  Stub.convars.aptic_api_key = H.KEY2
  H.until_sent(5)
  Stub.convars.aptic_api_key = 'oops ' .. H.KEY
  H.until_sent(40)
  Aptic.status.command(0, { 'status' })
  Aptic.status.command(0, { 'salt' })

  -- The heartbeat loop's crash handler.
  Aptic.heartbeat.reset()
  Aptic.transport.post = function() error('boom ' .. H.KEY) end
  Stub.convars.aptic_api_key = H.KEY
  Stub.threads[2] = nil
  local ok, err = pcall(Aptic.heartbeat.step)
  falsy(ok)
  Aptic.log.error('heartbeat loop error: %s', tostring(err))

  local out = Stub.output()
  truthy(#Stub.prints > 40, 'the scenario printed plenty: ' .. #Stub.prints .. ' lines')
  assert_clean(out, H.KEY, 'key')
  assert_clean(out, H.KEY2, 'rotated key')
  not_contains(out, H.SALT, 'salt')
  -- The prefix is what identifies the key to the owner.
  contains(out, 'apt_ing_TESTkeyA…')
end)

test('only log.lua prints: every other module goes through Aptic.log', function()
  -- Runtime check of the same rule the static grep in tests/js enforces:
  -- swap print for a tripwire and run the noisy paths.
  local real = print
  local raw = {}
  print = function(...) raw[#raw + 1] = select(1, ...) end
  H.server({ salt = false })
  H.fake_transport({ H.err(401, 'invalid_credential') })
  Stub.threads[1]()
  H.tick(0)
  Aptic.status.command(0, { 'status' })
  print = real
  truthy(#raw > 0)
  for _, line in ipairs(raw) do
    truthy(tostring(line):find('[aptic]', 1, true), 'unprefixed print: ' .. tostring(line))
  end
end)
