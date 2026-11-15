-- Test setup for the collectors: a fake oxmysql over fixture tables, the
-- framework exports, txAdmin, and a sink that records what it is given.
-- Load with dofile('tests/support/collect.lua').

C = {}

local function copy(v)
  if type(v) ~= 'table' then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = copy(x) end
  return out
end
C.copy = copy

--- The columns a SELECT asks for: `a, b, UNIX_TIMESTAMP(c) AS c_ts` -> {a, b, c_ts}.
local function selected(sql)
  local list = sql:match('^SELECT (.-) FROM ')
  local out = {}
  for expr in (list .. ','):gmatch('%s*(.-),') do
    out[#out + 1] = expr:match(' AS ([%w_]+)$') or expr
  end
  return out
end

local function page(rows, key, after, limit, sql)
  local sorted = copy(rows)
  table.sort(sorted, function(a, b) return a[key] < b[key] end)
  local cols = selected(sql)
  local out = {}
  for _, row in ipairs(sorted) do
    if row[key] > after then
      local picked = {}
      for _, c in ipairs(cols) do picked[c] = row[c] end
      out[#out + 1] = picked
      if #out >= limit then break end
    end
  end
  return out
end

--- Install MySQL.query.await over the fixture `F`. opts.drop = { table = true }
--- removes a table; opts.fail = 'players' makes that table's query fail.
function C.install_db(F, opts)
  opts = opts or {}
  C.sql = {}
  local tables = { players = F.players, player_vehicles = F.vehicles }
  MySQL = {
    query = {
      await = function(sql, params)
        C.sql[#C.sql + 1] = { sql = sql, params = copy(params) }
        if sql:find('information_schema', 1, true) then
          local out = {}
          local names = {}
          for t in pairs(F.columns) do names[#names + 1] = t end
          table.sort(names)
          for _, t in ipairs(names) do
            if not (opts.drop and opts.drop[t]) then
              for _, c in ipairs(F.columns[t]) do out[#out + 1] = { table_name = t, column_name = c } end
            end
          end
          return out
        end
        local name = sql:match(' FROM ([%w_]+) ')
        if opts.fail == name then error('oxmysql: simulated failure') end
        if name == 'players' then return page(tables.players, 'citizenid', params[1], params[2], sql) end
        if name == 'player_vehicles' then return page(tables.player_vehicles, 'id', params[1], params[2], sql) end
        error('fake oxmysql: unexpected query ' .. sql)
      end,
    },
  }
  Stub.start('oxmysql', '2.13.0')
end

local function txadmin_on()
  Stub.start('monitor', '8.0.1')
  Stub.convars.txDataPath = 'tests/fixtures/txData'
end

--- A Qbox + ox_inventory server with the qbox fixture. Returns the fixture.
function C.qbox(opts)
  opts = opts or {}
  H.server({ framework = 'qbox', inventory = 'ox_inventory', salt = opts.salt })
  local F = dofile('tests/fixtures/qbox.lua')
  C.install_db(F, opts)
  Stub.export_overrides.GetPlayersData = function() return copy(F.online) end
  Stub.export_overrides.GetJobs = function() return copy(F.jobs) end
  Stub.export_overrides.GetGangs = function() return copy(F.gangs) end
  Stub.players = { 3, 7 }
  if opts.txadmin ~= false then txadmin_on() end
  return F
end

--- A QBCore + qb-inventory server with the qbcore fixture.
function C.qbcore(opts)
  opts = opts or {}
  H.server({ framework = 'qbcore', inventory = 'qb-inventory', salt = opts.salt })
  local F = dofile('tests/fixtures/qbcore.lua')
  C.install_db(F, opts)
  local core = {
    Functions = { GetQBPlayers = function() return copy(F.online) end },
    Shared = { Jobs = copy(F.jobs), Gangs = copy(F.gangs) },
  }
  Stub.export_overrides.GetCoreObject = function() return core end
  Stub.players = { 12 }
  if opts.txadmin ~= false then txadmin_on() end
  return F
end

--- A sink that records everything.
function C.sink(hooks)
  hooks = hooks or {}
  local s = { by = {}, order = {}, calls = {} }
  function s:begin(meta)
    self.calls[#self.calls + 1] = 'begin'
    self.meta = meta
  end
  function s:add(collection, row)
    self.by[collection] = self.by[collection] or {}
    table.insert(self.by[collection], row)
    self.order[#self.order + 1] = collection
    if hooks.add then hooks.add(collection, row) end
  end
  function s:finish(counts)
    self.calls[#self.calls + 1] = 'finish'
    self.counts = counts
  end
  function s:abort(err)
    self.calls[#self.calls + 1] = 'abort'
    self.aborted = err
  end
  return s
end

--- Run the collector into a fresh recording sink.
function C.run(opts, hooks)
  local sink = C.sink(hooks)
  local summary, err = Aptic.collector.run(sink, opts)
  return sink, summary, err
end

function C.rows(sink, collection)
  return sink.by[collection] or {}
end

--- The row of `collection` whose `field` equals `value`, or nil.
function C.find(sink, collection, field, value)
  for _, row in ipairs(C.rows(sink, collection)) do
    if row[field] == value then return row end
  end
  return nil
end

--- { [currency] = amount } for one character.
function C.balances(sink, char_id)
  local out = {}
  for _, row in ipairs(C.rows(sink, 'balances')) do
    if row.char_id == char_id then out[row.currency] = row.amount end
  end
  return out
end

--- Everything the sink received, as JSON (for the Node contract test).
function C.recorded_json(sink, summary)
  return json.encode({ meta = sink.meta, counts = sink.counts, rows = sink.by, summary = summary and {
    skipped = summary.skipped, adjusted = summary.adjusted } or nil })
end
