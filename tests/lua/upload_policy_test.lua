-- uploader.decide(): every row of the plan §5.3 error-code table, as the
-- transport would report each answer.

dofile('tests/support/fake_aptic.lua')

local function decide(op, result, ctx)
  return Aptic.uploader.decide(op, result, ctx or {}, function() return 0.5 end)
end
local E = FakeAptic.err

test('200 ok proceeds; a 2xx that is not ok is transient', function()
  eq(decide('chunk', FakeAptic.ok({})).action, 'ok')
  local d = decide('chunk', { ok = true, status = 200, json = { hello = 1 } })
  eq(d.action, 'transient')
  eq(d.code, 'unexpected_answer')
end)

test('400 invalid_json / invalid_payload: abandon, no hold', function()
  for _, code in ipairs({ 'invalid_json', 'invalid_payload' }) do
    local d = decide('chunk', E(code))
    eq(d.action, 'abandon', code)
    eq(d.code, code)
    eq(d.hold, nil)
  end
end)

test('400 unsupported_version: abandon and stop uploads (update aptic_bridge)', function()
  local d = decide('start', E('unsupported_version'))
  eq(d.action, 'abandon')
  eq(d.hold, 'outdated')
end)

test('400/409 snapshot_clock_invalid: abandon and re-measure the clock at once', function()
  for _, r in ipairs({ E('snapshot_clock_invalid'), { status = 409, code = 'snapshot_clock_invalid', json = {} } }) do
    local d = decide('start', r)
    eq(d.action, 'abandon')
    eq(d.heartbeat, true)
  end
end)

test('401 invalid_credential: abandon and let the heartbeat stop all traffic', function()
  local d = decide('chunk', E('invalid_credential'))
  eq(d.action, 'abandon')
  eq(d.code, 'invalid_credential')
  eq(d.heartbeat, true)
end)

test('404 upload_unavailable: abandon', function()
  local d = decide('status', E('upload_unavailable'))
  eq(d.action, 'abandon')
  eq(d.code, 'upload_unavailable')
end)

test('409 request_conflict: abandon, delete the cache, raise a diagnostic', function()
  local d = decide('chunk', E('request_conflict'))
  eq(d.action, 'abandon')
  eq(d.conflict, true)
end)

test('409 upload_incomplete / chunk_gap at finalize: resync once, then abandon', function()
  for _, code in ipairs({ 'upload_incomplete', 'chunk_gap' }) do
    eq(decide('finalize', E(code), { finalize_retries = 0 }).action, 'resync', code)
    eq(decide('finalize', E(code), { finalize_retries = 1 }).action, 'abandon', code)
    eq(decide('chunk', E(code)).action, 'abandon', code .. ' outside finalize')
  end
end)

test('409 upload_expired and credential_rotated: abandon', function()
  for _, code in ipairs({ 'upload_expired', 'credential_rotated' }) do
    local d = decide('chunk', E(code))
    eq(d.action, 'abandon')
    eq(d.code, code)
  end
end)

test('409 snapshot_out_of_order: abandon and count it', function()
  local d = decide('finalize', E('snapshot_out_of_order'))
  eq(d.action, 'abandon')
  eq(d.out_of_order, true)
end)

test('409 snapshot_invalid: abandon with the allowlisted collection and reason only', function()
  local d = decide('finalize', E('snapshot_invalid', nil, { collection = 'vehicles', reason = 'duplicate_key' }))
  eq(d.action, 'abandon')
  eq(d.collection, 'vehicles')
  eq(d.reason, 'duplicate_key')
  local odd = decide('finalize', E('snapshot_invalid', nil, { collection = 'Robert\'); DROP', reason = 'value 42' }))
  eq(odd.collection, nil)
  eq(odd.reason, nil)
end)

test('409 invalid_manifest / invalid_chunk / manifest_count_exceeded: abandon (bug)', function()
  for _, code in ipairs({ 'invalid_manifest', 'invalid_chunk', 'manifest_count_exceeded' }) do
    local d = decide('chunk', E(code))
    eq(d.action, 'abandon')
    eq(d.code, code)
  end
end)

test('413 body_too_large: abandon and lower the byte budget', function()
  local d = decide('chunk', E('body_too_large', nil))
  eq(d.action, 'abandon')
  eq(d.lower_budget, true)
  local local_refusal = decide('chunk', { status = 0, transport_error = 'body_too_large' })
  eq(local_refusal.lower_budget, true, 'the transport refusing a body over 256 KiB counts too')
end)

test('413 snapshot_too_large: next slot when retry_after is null', function()
  local d = decide('start', E('snapshot_too_large', nil))
  eq(d.action, 'abandon')
  eq(d.defer_s, nil)
end)

test('429 start_rate_limited / daily_snapshot_limit: wait retry_after from the body', function()
  for _, code in ipairs({ 'start_rate_limited', 'daily_snapshot_limit' }) do
    local soon = decide('start', E(code, 120))
    eq(soon.action, 'wait_start', code)
    between(soon.delay_s, 120, 122)
    local later = decide('start', E(code, 7200))
    eq(later.action, 'abandon', code .. ' long wait')
    eq(later.defer_s, 7200, 'no new snapshot before the limit frees up')
    local null = decide('start', E(code, nil))
    eq(null.action, 'abandon', code .. ' null')
    eq(null.defer_s, nil)
  end
end)

test('413 upload_quota_exceeded: abandon, next slot, never a third upload', function()
  local d = decide('start', E('upload_quota_exceeded', 1800))
  eq(d.action, 'abandon')
  eq(d.defer_s, 1800)
  local staging = decide('chunk', E('upload_quota_exceeded', nil))
  eq(staging.action, 'abandon')
end)

test('413 storage_quota_exceeded: stop snapshots, keep heartbeats', function()
  local d = decide('start', E('storage_quota_exceeded', nil))
  eq(d.action, 'abandon')
  eq(d.hold, 'storage_full')
  eq(d.heartbeat, nil)
end)

test('415: stop uploads (header bug)', function()
  local d = decide('start', { status = 415, code = 'unsupported_media_type', json = {} })
  eq(d.action, 'abandon')
  eq(d.hold, 'unsupported_media_type')
end)

test('422 adapter_mismatch: abandon; the heartbeat takes over (every 10 min)', function()
  local d = decide('start', E('adapter_mismatch'))
  eq(d.action, 'abandon')
  eq(d.heartbeat, true)
end)

test('403 workspace_locked / plan_limit_exceeded: abandon; the heartbeat takes over', function()
  for _, code in ipairs({ 'workspace_locked', 'plan_limit_exceeded' }) do
    local d = decide('start', E(code))
    eq(d.action, 'abandon')
    eq(d.heartbeat, true)
  end
end)

test('429 rate_limited: the same request after retry_after, or 60 s', function()
  local d = decide('chunk', E('rate_limited', 17))
  eq(d.action, 'retry')
  between(d.delay_s, 17, 19)
  local header_only = decide('chunk', { status = 429, code = 'rate_limited', json = {}, retry_after_header = 30 })
  between(header_only.delay_s, 30, 32)
  local none = decide('chunk', { status = 429, code = 'rate_limited', json = {} })
  between(none.delay_s, 60, 62)
end)

test('503, timeout, network, TLS: exponential backoff with full jitter, capped at 5 min', function()
  for _, r in ipairs({ E('ingest_unavailable'), { status = 0, transport_error = 'timeout' },
    { status = 0, transport_error = 'network' }, { status = 0, transport_error = 'tls' }, { status = 502 } }) do
    eq(decide('chunk', r).action, 'transient')
  end
  local max = function() return 1 end
  local function cap(n)
    return Aptic.uploader.decide('chunk', { status = 503 }, { failures = n - 1 }, max).delay_s
  end
  eq(cap(1), 5); eq(cap(2), 10); eq(cap(3), 20); eq(cap(4), 40); eq(cap(7), 300); eq(cap(20), 300)
  local low = Aptic.uploader.decide('chunk', { status = 503 }, { failures = 3 }, function() return 0 end)
  eq(low.delay_s, 1, 'full jitter, but never under a second')
  eq(decide('chunk', { status = 503 }, { failures = 2 }).failures, 3)
end)

test('a missing key or endpoint pauses the same request; the heartbeat explains', function()
  local d = decide('chunk', { status = 0, transport_error = 'no_key' })
  eq(d.action, 'retry')
  eq(d.delay_s, 30)
end)

test('any other 4xx is abandoned, never retried in a loop', function()
  local d = decide('chunk', { status = 418, json = {} })
  eq(d.action, 'abandon')
  eq(d.code, 'http_418')
end)
