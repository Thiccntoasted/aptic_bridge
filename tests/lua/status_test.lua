-- The `aptic` command.

local function run(source, ...)
  Stub.prints = {}
  Aptic.status.command(source, { ... })
  return Stub.output()
end

test('aptic status shows endpoint, last heartbeat, adapter, salt and instance id', function()
  H.server()
  H.fake_transport({ H.OK })
  H.tick(0)
  local out = run(0, 'status')
  contains(out, 'aptic_bridge 0.1.0')
  contains(out, 'endpoint        https://aptic.dev/api/ingest/v1 (default)')
  contains(out, 'key             set (apt_ing_TESTkeyA…)')
  contains(out, 'last heartbeat  ok, HTTP 200')
  contains(out, 'framework       qbox 1.24.1 [qbx_core]')
  contains(out, 'inventory       ox_inventory 2.44.1')
  contains(out, 'support         supported')
  contains(out, 'salt pinned     yes (fingerprint 49224dd5)')
  contains(out, 'instance id     ' .. Aptic.identity.instance_id())
  contains(out, 'next heartbeat  in ')
end)

test('aptic status never shows the key or the salt', function()
  H.server()
  H.fake_transport({ H.OK })
  H.tick(0)
  local out = run(0, 'status')
  not_contains(out, H.KEY)
  not_contains(out, H.KEY:sub(17))
  not_contains(out, H.SALT)
end)

test('aptic status without a pinned salt says no and does not show the suggestion', function()
  H.server({ salt = false })
  H.fake_transport({ H.OK })
  H.tick(0)
  local pending = Stub.kvp['salt.pending.v1']
  local out = run(0, 'status')
  contains(out, 'salt pinned     no')
  not_contains(out, pending)
end)

test('aptic status reports failures with their code', function()
  H.server()
  H.fake_transport({ H.err(401, 'invalid_credential') })
  H.tick(0)
  local out = run(0)
  contains(out, 'last heartbeat  unauthorized (invalid_credential), HTTP 401')
  contains(out, 'next heartbeat  when aptic_api_key changes')
end)

test('aptic status before anything was sent', function()
  local out = run(0, 'status')
  contains(out, 'last heartbeat  none sent yet')
  contains(out, 'key             not set')
  contains(out, 'framework       not detected')
end)

test('aptic salt prints the suggested line on the console only', function()
  H.server({ salt = false })
  local out = run(0, 'salt')
  contains(out, 'set aptic_salt "' .. Stub.kvp['salt.pending.v1'] .. '"')
  Stub.aces['5:command.aptic'] = true
  run(5, 'salt')
  local chat = Stub.chat[#Stub.chat].payload.args[2]
  contains(chat, 'only on the server console')
end)

test('aptic salt never prints a pinned salt', function()
  H.server()
  local out = run(0, 'salt')
  contains(out, 'The salt is pinned (fingerprint 49224dd5)')
  not_contains(out, H.SALT)
end)

test('players need the command.aptic ACE; allowed players get chat lines', function()
  H.server()
  run(7, 'status')
  eq(#Stub.chat, 0, 'no output for a player without the ACE')
  Stub.aces['7:command.aptic'] = true
  run(7, 'status')
  truthy(#Stub.chat > 5)
  for _, msg in ipairs(Stub.chat) do
    eq(msg.target, 7)
    not_contains(msg.payload.args[2], H.KEY:sub(9))
  end
end)

test('unknown subcommands print usage', function()
  contains(run(0, 'bogus'), 'usage: aptic status | aptic salt')
end)
