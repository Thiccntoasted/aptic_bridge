-- Heartbeat error policy (plan §5.3) and backoff.

local P = function() return Aptic.policy end
local fixed = function(v) return function() return v end end

test('200 ok: next heartbeat in 60 s +/- 5 s', function()
  local d = P().heartbeat(H.OK, 3, fixed(0.5))
  eq(d.state, 'ok')
  eq(d.delay_s, 60)
  eq(d.failures, 0)
  between(P().heartbeat(H.OK, 0, fixed(0)).delay_s, 55, 55)
  between(P().heartbeat(H.OK, 0, fixed(1)).delay_s, 65, 65)
end)

test('200 without ok:true is treated as a transient failure', function()
  local d = P().heartbeat({ ok = true, status = 200, json = { hello = 1 } }, 0, fixed(1))
  eq(d.state, 'unavailable')
  eq(d.code, 'unexpected_answer')
end)

test('401 holds all traffic until the key changes', function()
  local d = P().heartbeat(H.err(401, 'invalid_credential'), 0)
  eq(d.state, 'unauthorized')
  eq(d.hold, 'key_change')
  eq(d.code, 'invalid_credential')
end)

test('422 adapter_mismatch retries every 10 minutes', function()
  local d = P().heartbeat(H.err(422, 'adapter_mismatch'), 0)
  eq(d.state, 'adapter_mismatch')
  eq(d.delay_s, 600)
  eq(d.hold, nil)
end)

test('429 waits retry_after from the JSON body first', function()
  local d = P().heartbeat(H.err(429, 'rate_limited', { retry_after_body = 17, retry_after_header = 99 }), 0, fixed(0))
  eq(d.state, 'rate_limited')
  eq(d.delay_s, 17)
end)

test('429 falls back to the Retry-After header, then 60 s', function()
  eq(P().heartbeat(H.err(429, 'rate_limited', { retry_after_header = 42 }), 0, fixed(0)).delay_s, 42)
  eq(P().heartbeat(H.err(429, 'rate_limited'), 0, fixed(0)).delay_s, 60)
end)

test('429 never waits less than a second or more than an hour', function()
  eq(P().heartbeat(H.err(429, 'rate_limited', { retry_after_body = 0 }), 0, fixed(0)).delay_s, 60, 'zero is not a valid wait')
  eq(P().heartbeat(H.err(429, 'rate_limited', { retry_after_body = 86400 }), 0, fixed(0)).delay_s, 3600)
  eq(P().heartbeat(H.err(429, 'rate_limited', { retry_after_body = 0.2 }), 0, fixed(0)).delay_s, 60)
end)

test('the other 429 and 413 limit codes use the same wait rule', function()
  for _, case in ipairs({ { 429, 'start_rate_limited' }, { 429, 'daily_snapshot_limit' }, { 413, 'snapshot_too_large' } }) do
    local d = P().heartbeat(H.err(case[1], case[2], { retry_after_body = 30 }), 0, fixed(0))
    eq(d.delay_s, 30, case[2])
    eq(d.code, case[2])
  end
end)

test('403 locked and plan limit retry every 10 minutes', function()
  local locked = P().heartbeat(H.err(403, 'workspace_locked'), 0)
  eq(locked.state, 'locked')
  eq(locked.delay_s, 600)
  local plan = P().heartbeat(H.err(403, 'plan_limit_exceeded'), 0)
  eq(plan.state, 'plan_limit')
end)

test('400 unsupported_version asks for an update, every 10 minutes', function()
  local d = P().heartbeat(H.err(400, 'unsupported_version'), 0)
  eq(d.state, 'outdated')
  eq(d.delay_s, 600)
end)

test('other 4xx are rejections retried slowly', function()
  for _, case in ipairs({ { 400, 'invalid_payload' }, { 415, 'unsupported_media_type' }, { 404, nil }, { 409, 'request_conflict' } }) do
    local d = P().heartbeat(H.err(case[1], case[2]), 0)
    eq(d.state, 'rejected', tostring(case[1]))
    eq(d.delay_s, 600)
  end
  eq(P().heartbeat({ status = 404 }, 0).code, 'http_404')
end)

test('503, 5xx, redirects and network failures back off exponentially', function()
  local mid = fixed(1) -- the top of each step
  local expected = { 5, 10, 20, 40, 80, 160, 300, 300 }
  local failures = 0
  for i, want in ipairs(expected) do
    local d = P().heartbeat({ status = 0, transport_error = 'timeout' }, failures, mid)
    eq(d.state, 'unavailable')
    eq(d.delay_s, want, 'step ' .. i)
    failures = d.failures
  end
  eq(failures, #expected)
  eq(P().heartbeat(H.err(503, 'ingest_unavailable'), 0, mid).delay_s, 5)
  eq(P().heartbeat({ status = 302 }, 0, mid).code, 'http_302')
  eq(P().heartbeat({ status = 0, transport_error = 'tls' }, 1, mid).delay_s, 10)
end)

test('backoff jitter stays in the upper half of each step', function()
  eq(P().backoff(1, fixed(0)), 2.5)
  eq(P().backoff(3, fixed(0)), 10)
  eq(P().backoff(20, fixed(0)), 150)
end)

test('success resets the failure count', function()
  local d = P().heartbeat({ status = 0, transport_error = 'network' }, 5, fixed(1))
  eq(d.failures, 6)
  eq(P().heartbeat(H.OK, d.failures, fixed(0.5)).failures, 0)
end)

test('local configuration problems are checked again in 30 s', function()
  for _, te in ipairs({ 'no_key', 'invalid_key', 'insecure_endpoint', 'invalid_endpoint' }) do
    local d = P().heartbeat({ status = 0, transport_error = te }, 0)
    eq(d.state, 'config', te)
    eq(d.delay_s, 30)
  end
end)

test('no outcome ever retries in under a second', function()
  local results = {
    H.OK, H.err(401, 'invalid_credential'), H.err(422, 'adapter_mismatch'),
    H.err(429, 'rate_limited', { retry_after_body = 1 }), H.err(403, 'workspace_locked'),
    H.err(400, 'unsupported_version'), H.err(400, 'invalid_payload'), H.err(503, 'ingest_unavailable'),
    { status = 0, transport_error = 'timeout' }, { status = 0, transport_error = 'no_key' },
    { status = 500 }, { status = 0 }, {},
  }
  for _, r in ipairs(results) do
    for _, roll in ipairs({ 0, 0.001, 0.5, 1 }) do
      for failures = 0, 12 do
        local d = P().heartbeat(r, failures, fixed(roll))
        truthy(d.delay_s >= 1, ('%s waited %s'):format(tostring(r.status), tostring(d.delay_s)))
      end
    end
  end
end)

test('version comparison', function()
  local c = P().compare_versions
  eq(c('0.1.0', '0.1.0'), 0)
  eq(c('0.1.0', '0.2.0'), -1)
  eq(c('0.10.0', '0.9.9'), 1)
  eq(c('1.0', '1.0.0'), 0)
  eq(c('v1.2.3', '1.2.3'), 0)
  eq(c('1.2.3-beta', '1.2.3'), 0)
end)
