-- instance_id and salt state (D8, C9). These call the real transport.js
-- crypto through the exports bridge.

test('instance_id is generated once, stored in KVP and contract-shaped', function()
  local id = Aptic.identity.instance_id()
  truthy(id and id:match('^[%w_%-]+$') and #id >= 8 and #id <= 64, tostring(id))
  eq(#id, 32)
  eq(Stub.kvp['instance_id.v1'], id)
  eq(Aptic.identity.instance_id(), id)
end)

test('instance_id survives a restart (same KVP, fresh Lua state)', function()
  Stub.kvp['instance_id.v1'] = 'abcdef0123456789abcdef0123456789'
  eq(Aptic.identity.instance_id(), 'abcdef0123456789abcdef0123456789')
end)

test('a corrupt stored instance_id is replaced', function()
  Stub.kvp['instance_id.v1'] = 'bad id!'
  local id = Aptic.identity.instance_id()
  truthy(id ~= 'bad id!' and #id == 32)
end)

test('pinned salt: fingerprint is the first 8 hex of SHA-256("aptic-fp" .. salt)', function()
  local salt = Aptic.identity.salt({ state = 'pinned', value = H.SALT })
  eq(salt.pinned, true)
  -- printf 'aptic-fp%s' 0123456789abcdef...cdef | sha256sum
  eq(salt.fp, '49224dd5')
  eq(salt.pending, nil)
end)

test('no salt: one is generated, kept in KVP, and suggested again after a restart', function()
  local first = Aptic.identity.salt({ state = 'missing' })
  eq(first.pinned, false)
  truthy(first.pending and #first.pending == 64 and first.pending:match('^%x+$'))
  eq(Stub.kvp['salt.pending.v1'], first.pending)
  eq(Aptic.identity.salt({ state = 'missing' }).pending, first.pending)
end)

test('an invalid salt counts as not pinned', function()
  local salt = Aptic.identity.salt({ state = 'invalid' })
  eq(salt.pinned, false)
  eq(salt.invalid, true)
end)

test('pinning removes the suggested salt from KVP', function()
  Aptic.identity.salt({ state = 'missing' })
  truthy(Stub.kvp['salt.pending.v1'])
  Aptic.identity.salt({ state = 'pinned', value = H.SALT })
  eq(Stub.kvp['salt.pending.v1'], nil)
end)

test('the instructions print the exact server.cfg line', function()
  local salt = Aptic.identity.salt({ state = 'missing' })
  Aptic.identity.print_salt_instructions(salt)
  local out = Stub.output()
  contains(out, 'set aptic_salt "' .. salt.pending .. '"')
  contains(out, 'Snapshots will not upload until the salt is pinned')
end)

test('agent_version comes from the manifest version', function()
  eq(Aptic.identity.agent_version(), 'aptic_bridge/0.1.0')
  Stub.self_version = '0.2.0-rc.1'
  eq(Aptic.identity.agent_version(), 'aptic_bridge/0.2.0-rc.1')
  Stub.self_version = nil
  eq(Aptic.identity.agent_version(), 'aptic_bridge/0.0.0')
end)
