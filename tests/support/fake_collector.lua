-- A stand-in for Aptic.collector (collector.lua is built separately): it
-- writes synthetic, contract-valid rows into the sink exactly as the
-- interface says, a "page" at a time. Used by the Lua tests and by the
-- integration test against a real Aptic. Never real players.
--
-- spec (all optional):
--   characters  number of characters (default 30); each gets cash and bank,
--               every third a custom currency, every fifth a negative bank
--   vehicles    number of vehicles (default characters / 2)
--   jobs        include the jobs collection (default true)
--   pad         extra characters in each name, to make rows bigger
--   unicode     put accents and an emoji in names
--   fail        'error' raises inside run; a string is returned as the error
--   miscount    report one character more than was added
--   page        rows between yields (default 50)

FakeCollector = {}

local function hex64(i)
  return (('%08x'):format(i)):rep(8)
end

function FakeCollector.rows(spec, taken_at)
  spec = spec or {}
  local n = spec.characters or 30
  local out = { characters = {}, balances = {}, vehicles = {}, jobs = {} }
  local pad = spec.pad and (' ' .. ('x'):rep(spec.pad)) or ''
  for i = 1, n do
    local id = ('char-%05d'):format(i)
    local name = ('Test Person %d'):format(i) .. pad
    if spec.unicode then name = ('Jos\195\169 \240\159\152\128 %d'):format(i) .. pad end
    out.characters[#out.characters + 1] = {
      char_id = id,
      player_hash = hex64(math.ceil(i / 2)), -- two characters per player
      name = name,
      job = i % 4 == 0 and 'police' or 'unemployed',
      job_grade = i % 4 == 0 and 4 or 0,
      gang = i % 7 == 0 and 'ballas' or nil,
      created_at = nil,          -- unknown without txAdmin (C3)
      playtime_minutes = nil,
      last_seen_at = taken_at,
    }
    out.balances[#out.balances + 1] = { char_id = id, currency = 'cash', amount = i * 10 }
    out.balances[#out.balances + 1] = { char_id = id, currency = 'bank', amount = i % 5 == 0 and -250.5 or i * 1000 }
    if i % 3 == 0 then
      out.balances[#out.balances + 1] = { char_id = id, currency = 'casino_chips', amount = 25 }
    end
  end
  local v = spec.vehicles or math.floor(n / 2)
  local states = { 'garaged', 'out', 'impounded' }
  for i = 1, v do
    local state = states[(i % 3) + 1]
    out.vehicles[#out.vehicles + 1] = {
      plate = ('PLT%05d'):format(i),
      model = 'sultan',
      owner_char_id = ('char-%05d'):format(((i - 1) % n) + 1),
      garage = state == 'garaged' and 'pillboxgarage' or nil,
      stored = state == 'garaged',
      state = state,
    }
  end
  if spec.jobs ~= false then
    out.jobs[#out.jobs + 1] = { kind = 'job', name = 'unemployed', label = 'Civilian',
      grades = { { level = 0, name = 'Freelancer' } } }
    out.jobs[#out.jobs + 1] = { kind = 'job', name = 'police', label = 'LSPD',
      grades = { { level = 0, name = 'Recruit' }, { level = 1, name = 'Officer' }, { level = 4, name = 'Chief' } } }
    out.jobs[#out.jobs + 1] = { kind = 'gang', name = 'ballas', label = 'Ballas',
      grades = { { level = 0, name = 'Recruit' }, { level = 2, name = 'Boss' } } }
  end
  return out
end

FakeCollector.ORDER = { 'characters', 'balances', 'vehicles', 'jobs' }

--- Install the fake as Aptic.collector. Returns the spec table, which also
--- records each run's opts in spec.runs.
function FakeCollector.install(spec)
  spec = spec or {}
  spec.runs = {}
  Aptic.collector = {
    run = function(sink, opts)
      spec.runs[#spec.runs + 1] = opts
      if spec.fail == 'error' then error('collector blew up on a row for Jos\195\169') end
      if type(spec.fail) == 'string' then return nil, spec.fail end
      local caps = { 'characters', 'balances', 'vehicles' }
      if spec.jobs ~= false then caps[#caps + 1] = 'jobs' end
      local hb = Aptic.heartbeat.state
      local ok, code = sink:begin({
        taken_at = opts.taken_at,
        capabilities = caps,
        framework = spec.framework or 'qbox',
        inventory = spec.inventory or 'ox_inventory',
        framework_version = '1.24.1',
        inventory_version = '2.44.1',
        salt_fp = hb.salt and hb.salt.fp or nil,
      })
      if not ok then return nil, code end
      local rows = FakeCollector.rows(spec, opts.taken_at)
      local counts, added = {}, 0
      for _, c in ipairs(FakeCollector.ORDER) do
        for _, row in ipairs(rows[c]) do
          local fine, why = sink:add(c, row)
          if not fine then return nil, why end
          counts[c] = (counts[c] or 0) + 1
          added = added + 1
          if added % (spec.page or 50) == 0 then Wait(0) end
        end
      end
      if spec.miscount then counts.characters = (counts.characters or 0) + 1 end
      local fin, why = sink:finish(counts)
      if not fin then return nil, why end
      return { rows = added }
    end,
  }
  return spec
end
