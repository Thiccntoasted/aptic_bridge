-- validate.lua against every case in tests/fixtures/contract_cases.lua (the
-- same list the Node parity test runs through Aptic's contract.ts).

test('validate.lua accepts and rejects exactly the contract cases', function()
  local cases = dofile('tests/fixtures/contract_cases.lua')
  truthy(#cases > 80, 'the case list loaded')
  local wrong = {}
  for _, case in ipairs(cases) do
    local ok, field = Aptic.validate.row(case.collection, case.row)
    if ok ~= case.valid then
      wrong[#wrong + 1] = ('%s / %s: expected %s, got %s (%s)'):format(
        case.collection, case.note, tostring(case.valid), tostring(ok), tostring(field))
    end
  end
  eq(#wrong, 0, table.concat(wrong, '\n'))
end)

test('a rejected row names the field that failed, never the value', function()
  local ok, field = Aptic.validate.row('characters', {
    char_id = 'ABC', player_hash = ('a'):rep(64), name = 'Secret Name\n', job = 'police', job_grade = 1,
    last_seen_at = '2026-11-10T21:05:00Z',
  })
  eq(ok, false)
  eq(field, 'name')
  ok, field = Aptic.validate.row('balances', { char_id = 'ABC', currency = 'bank', amount = 1, license = 'license:x' })
  eq(field, 'unknown_key')
end)

test('unknown collections and non-table rows are rejected', function()
  eq(Aptic.validate.row('players', {}), false)
  eq(Aptic.validate.row('characters', 'row'), false)
  eq(Aptic.validate.row('characters', nil), false)
end)

test('day-of-month is checked per month (stricter than V8, never looser)', function()
  local row = {
    char_id = 'ABC', player_hash = ('a'):rep(64), name = 'A', job = 'police', job_grade = 1,
    last_seen_at = '2026-02-30T00:00:00Z',
  }
  eq(Aptic.validate.row('characters', row), false)
  row.last_seen_at = '2028-02-29T00:00:00Z'
  eq(Aptic.validate.row('characters', row), true)
end)
