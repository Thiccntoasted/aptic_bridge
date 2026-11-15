-- Redaction (plan §4.4).

test('a full connection key keeps only the 8-character dashboard prefix', function()
  local out = Aptic.log.redact('key is ' .. H.KEY .. ' ok')
  eq(out, 'key is apt_ing_TESTkeyA… ok')
  not_contains(out, H.KEY:sub(17))
end)

test('a key-shaped value of any length is cut to the prefix', function()
  eq(Aptic.log.redact('apt_ing_abcdefghijklmnop'), 'apt_ing_abcdefgh…')
  eq(Aptic.log.redact('apt_ing_abc'), 'apt_ing_abc')
  eq(Aptic.log.redact('apt_ing_abcdefgh…'), 'apt_ing_abcdefgh…', 'an already shortened prefix stays')
end)

test('registered secrets are replaced wherever they appear, whatever their shape', function()
  Aptic.log.add_secret('not-a-key-format-secret')
  Aptic.log.add_secret(H.SALT)
  local out = Aptic.log.redact('a=not-a-key-format-secret b=' .. H.SALT .. ' c=' .. H.SALT:upper())
  eq(out, 'a=[redacted] b=[redacted] c=' .. H.SALT:upper():sub(1, 64))
end)

test('the upper-case form of a lower-case secret is not assumed, but the lower-case form of any secret is', function()
  Aptic.log.add_secret('MixedCaseSecret1')
  eq(Aptic.log.redact('MixedCaseSecret1 mixedcasesecret1'), '[redacted] [redacted]')
end)

test('short values are never registered as secrets', function()
  Aptic.log.add_secret('abc')
  eq(Aptic.log.redact('abc'), 'abc')
end)

test('player identifiers are masked', function()
  local out = Aptic.log.redact(
    'license:abc123def license2:ffee steam:110000112345678 discord:123456789012 fivem:4242 xbl:99 live:77 ip:10.1.2.3')
  eq(out, 'license:[redacted] license:[redacted] steam:[redacted] discord:[redacted] fivem:[redacted] xbl:[redacted] live:[redacted] ip:[redacted]')
end)

test('IPv4 addresses are masked except loopback', function()
  eq(Aptic.log.redact('from 203.0.113.9 to 127.0.0.1:3300'), 'from [ip] to 127.0.0.1:3300')
end)

test('version numbers are not mistaken for addresses', function()
  eq(Aptic.log.redact('qbox 1.24.1 + ox_inventory 2.44.1'), 'qbox 1.24.1 + ox_inventory 2.44.1')
end)

test('every log level prints through redaction with an [aptic] tag', function()
  Aptic.log.info('one %s', H.KEY)
  Aptic.log.warn('two %s', H.KEY)
  Aptic.log.error('three %s', H.KEY)
  local out = Stub.output()
  contains(out, '[aptic] one apt_ing_TESTkeyA…')
  contains(out, '[aptic] warn: two')
  contains(out, '[aptic] error: three')
  not_contains(out, H.KEY)
end)

test('debug lines print only with aptic_debug 1', function()
  Aptic.log.debug('hidden')
  eq(#Stub.prints, 0)
  Stub.convars.aptic_debug = '1'
  Aptic.log.debug('shown')
  contains(Stub.output(), 'debug: shown')
end)

test('change() prints a topic once until its message changes', function()
  Aptic.log.change('t', 'warn', 'same')
  Aptic.log.change('t', 'warn', 'same')
  eq(#Stub.prints, 1)
  Aptic.log.change('t', 'warn', 'different')
  eq(#Stub.prints, 2)
  Aptic.log.reset('t')
  Aptic.log.change('t', 'warn', 'different')
  eq(#Stub.prints, 3)
end)

test('a bad format string never throws', function()
  Aptic.log.info('%d', 'not a number')
  contains(Stub.output(), '%d')
end)
