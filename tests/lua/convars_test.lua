-- Convars: key, salt, endpoint.

test('a valid key gives its 16-character prefix, never the key', function()
  Stub.convars.aptic_api_key = '  ' .. H.KEY .. ' '
  local cfg = Aptic.convars.read()
  eq(cfg.key.state, 'ok')
  eq(cfg.key.prefix, H.KEY:sub(1, 16))
  eq(keys_of(cfg.key), 'prefix,state')
end)

test('missing and malformed keys are told apart', function()
  eq(Aptic.convars.read().key.state, 'missing')
  Stub.convars.aptic_api_key = H.KEY:sub(1, 50)
  eq(Aptic.convars.read().key.state, 'invalid')
  Stub.convars.aptic_api_key = 'apt_live_' .. H.KEY:sub(9)
  eq(Aptic.convars.read().key.state, 'invalid')
  Stub.convars.aptic_api_key = H.KEY:sub(1, 50) .. '!'
  eq(Aptic.convars.read().key.state, 'invalid')
end)

test('a malformed key is still registered as a secret', function()
  Stub.convars.aptic_api_key = 'typo-' .. H.KEY
  Aptic.convars.read()
  eq(Aptic.log.redact('x typo-' .. H.KEY), 'x [redacted]')
end)

test('a 64-hex salt is pinned (lower-cased); anything else is not', function()
  Stub.convars.aptic_salt = H.SALT:upper()
  local salt = Aptic.convars.read().salt
  eq(salt.state, 'pinned')
  eq(salt.value, H.SALT)
  Stub.convars.aptic_salt = H.SALT:sub(2)
  eq(Aptic.convars.read().salt.state, 'invalid')
  Stub.convars.aptic_salt = ''
  eq(Aptic.convars.read().salt.state, 'missing')
end)

test('the salt is registered as a secret', function()
  Stub.convars.aptic_salt = H.SALT
  Aptic.convars.read()
  eq(Aptic.log.redact(H.SALT), '[redacted]')
end)

test('the default endpoint is aptic.dev (D13)', function()
  local ep = Aptic.convars.read().endpoint
  eq(ep.state, 'ok')
  eq(ep.url, 'https://aptic.dev/api/ingest/v1')
  eq(ep.custom, false)
  eq(ep.host, 'aptic.dev')
end)

test('aptic_endpoint overrides it, trailing slashes dropped', function()
  Stub.convars.aptic_endpoint = 'https://staging.aptic.dev/api/ingest/v1/'
  local ep = Aptic.convars.read().endpoint
  eq(ep.url, 'https://staging.aptic.dev/api/ingest/v1')
  eq(ep.custom, true)
end)

test('plain http is refused except localhost with aptic_dev 1', function()
  Stub.convars.aptic_endpoint = 'http://aptic.dev/api/ingest/v1'
  eq(Aptic.convars.read().endpoint.state, 'invalid')
  Stub.convars.aptic_endpoint = 'http://localhost:3300/api/ingest/v1'
  local ep = Aptic.convars.read().endpoint
  eq(ep.state, 'invalid')
  contains(ep.reason, 'aptic_dev')
  Stub.convars.aptic_dev = '1'
  ep = Aptic.convars.read().endpoint
  eq(ep.state, 'ok')
  eq(ep.secure, false)
  Stub.convars.aptic_endpoint = 'http://127.0.0.1:3300/api/ingest/v1'
  eq(Aptic.convars.read().endpoint.state, 'ok')
  Stub.convars.aptic_endpoint = 'http://[::1]:3300/api/ingest/v1'
  eq(Aptic.convars.read().endpoint.state, 'ok')
  Stub.convars.aptic_endpoint = 'http://10.0.0.5:3300/api/ingest/v1'
  eq(Aptic.convars.read().endpoint.state, 'invalid')
end)

test('URLs with credentials, fragments or no scheme are refused', function()
  for _, url in ipairs({ 'https://user:pw@aptic.dev/x', 'https://aptic.dev/x#y', 'aptic.dev/api', 'ftp://aptic.dev/x', 'https:///x' }) do
    Stub.convars.aptic_endpoint = url
    eq(Aptic.convars.read().endpoint.state, 'invalid', url)
  end
end)
