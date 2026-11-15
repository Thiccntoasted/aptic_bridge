-- `aptic validate [--verbose]` (plan §7.2): one collection run into a
-- checking sink. Nothing is uploaded, no chunk file is written and the
-- upload state is left alone.
--
-- The checking sink applies, on top of validate.lua's per-row rules, the
-- rules Aptic's finalize applies to a whole snapshot (D5 snapshot_invalid
-- reasons):
--   duplicate_key       a primary key repeats (char_id, char_id + currency,
--                       plate, kind + name, ...)
--   missing_reference   a balance or vehicle points at a character that is
--                       not in the snapshot (stacks: a container)
--   time_order          created_at after last_seen_at, or last_seen_at more
--                       than two minutes after taken_at
-- and feeds the real chunker with a write that discards, so the chunk count
-- and request bytes are the ones an upload would have.
--
-- Output is counts and reason codes. With --verbose (server console only)
-- it also lists the character names behind each skipped, adjusted or
-- rejected row: names only, never a citizenid, license, plate or any other
-- identifier.
--
-- After a snapshot_invalid answer the uploader calls after_rejection(),
-- which runs the same check in its own thread and logs the summary (plan
-- §5.3), without names.

Aptic = Aptic or {}
local M = {}
Aptic.selfcheck = M

local S = { running = false }
M.state = S

local TIME_SLACK_S = 120 -- last_seen_at may be up to two minutes after taken_at
local MAX_NAMES = 10      -- names listed per reason with --verbose

-- What each collection's primary key is, and what it must point at.
local KEYS = {
  characters = { 'char_id' },
  balances = { 'char_id', 'currency' },
  containers = { 'container_id' },
  item_stacks = { 'container_id', 'slot' },
  vehicles = { 'plate' },
  activity = { 'char_id' },
  registry = { 'item_name' },
  jobs = { 'kind', 'name' },
}
local REFS = {
  balances = { field = 'char_id', target = 'characters' },
  activity = { field = 'char_id', target = 'characters' },
  vehicles = { field = 'owner_char_id', target = 'characters', optional = true },
  containers = { field = 'owner_char_id', target = 'characters', optional = true },
  item_stacks = { field = 'container_id', target = 'containers' },
}

-- One line of advice per collector reason an owner can act on.
M.HINTS = {
  ['characters.license_missing'] = 'players.license is empty, so there is no player to hash',
  ['characters.last_seen_unknown'] = 'no last_updated or last_logged_out time in players',
  ['characters.char_id_duplicate'] = 'the same citizenid twice; the first is kept',
  ['characters.char_id_invalid'] = 'citizenid is not text',
  ['characters.player_hash_unavailable'] = 'the license could not be hashed (over 256 characters?)',
  ['characters.name_unavailable'] = 'no readable name and no pseudonym',
  ['balances.currency_code_invalid'] = 'a money type that is not a-z, 0-9 or _ (rename it in config.lua currencies.rename)',
  ['balances.amount_unreadable'] = 'a money value that is not a number',
  ['balances.currency_duplicate'] = 'two money types that end up with the same code',
  ['vehicles.plate_invalid'] = 'empty plate, or longer than 32 characters',
  ['vehicles.state_unknown'] = 'player_vehicles.state is not 0 (out), 1 (garaged) or 2 (impounded)',
  ['vehicles.model_missing'] = 'neither vehicle nor hash is set',
  ['vehicles.plate_duplicate'] = 'the same plate on more than one row; the highest id is kept',
  ['jobs.definition_unreadable'] = 'a job or gang definition that is not a table',
  money_unreadable = 'players.money is not valid JSON; the character is sent with no balances',
  name_missing = 'no first or last name in charinfo; a pseudonym is sent instead',
  job_unreadable = 'players.job is not valid JSON; sent as unemployed 0',
  job_grade_unreadable = 'the job grade is not a whole number from 0 to 10000; sent as 0',
  last_seen_clamped = 'last seen after the snapshot time (database clock ahead); sent as the snapshot time',
  created_at_after_last_seen = 'txAdmin first join is after this character was last seen; created_at sent as unknown',
  vehicle_owner_not_in_snapshot = 'the owner citizenid is not a character in the snapshot; sent without an owner',
  grade_name_defaulted = 'a job grade without a name; sent as "Grade N"',
  duplicate_key = 'Aptic refuses a snapshot whose primary key repeats',
  missing_reference = 'points at a character (or container) that is not in the snapshot',
  time_order = 'created_at after last_seen_at, or last_seen_at over two minutes after the snapshot time',
  grade_level_invalid = 'a job grade level that is not a whole number from 0 to 10000; left out',
}

local function bump(t, k) t[k] = (t[k] or 0) + 1 end

local function sorted_keys(t)
  local out = {}
  for k in pairs(t or {}) do out[#out + 1] = k end
  table.sort(out)
  return out
end

-- The checking sink ------------------------------------------------------------

local Sink = {}
Sink.__index = Sink

--- A sink that checks the whole-snapshot rules and counts what an upload
--- would send. `opts.names` (a table) collects names per finding.
function M.sink(opts)
  opts = opts or {}
  local seen = {}
  for c in pairs(KEYS) do seen[c] = {} end
  local budget = Aptic.uploader and Aptic.uploader.byte_budget and Aptic.uploader.byte_budget() or nil
  return setmetatable({
    chunker = Aptic.chunker.new({
      snapshot_id = 'apb-00000000T000000Z-0000', -- same length as a real id, so sizes match
      write = function() return true end,
      max_bytes = budget,
    }),
    seen = seen,
    refs = {},          -- collection -> { { value, name } } checked at finish
    findings = {},      -- '<collection>.<reason>' -> n
    names = opts.names, -- '<collection>.<reason>' -> { name, ... } (verbose only)
    char_names = opts.names and {} or nil,
    taken = nil,
  }, Sink)
end

function Sink:find(collection, reason, name)
  local key = collection .. '.' .. reason
  bump(self.findings, key)
  if self.names and name then
    local list = self.names[key] or {}
    self.names[key] = list
    list[#list + 1] = name
  end
end

function Sink:name_for(collection, row)
  if not self.char_names then return nil end
  if collection == 'characters' then return row.name end
  return self.char_names[row.char_id or row.owner_char_id or false]
end

--- The chunker stops at its first failure (too many chunks, a row too
--- large, a count mismatch); that one is a finding, the repeats are not.
function Sink:chunker_failed(ok, code)
  if ok or self.chunker_reported then return end
  self.chunker_reported = true
  local f = self.chunker.failed
  self:find(f and f.collection or 'snapshot', 'chunker_' .. tostring(f and f.code or code))
end

function Sink:begin(meta)
  self.taken = type(meta) == 'table' and Aptic.time.parse_iso(meta.taken_at) or nil
  local ok, code = self.chunker:begin(meta)
  self:chunker_failed(ok, code)
  return ok, code
end

local function stamp(v)
  if v == nil then return nil end
  return Aptic.time.parse_iso(v)
end

function Sink:add(collection, row)
  local keys = KEYS[collection]
  if type(row) == 'table' and keys then
    local name = self:name_for(collection, row)
    local ok, field = Aptic.validate.row(collection, row)
    if not ok then self:find(collection, 'invalid_' .. tostring(field), name) end

    local parts = {}
    for i, k in ipairs(keys) do parts[i] = tostring(row[k]) end
    local id = table.concat(parts, '\0')
    if self.seen[collection][id] then
      self:find(collection, 'duplicate_key', name)
    else
      self.seen[collection][id] = true
    end

    if collection == 'characters' then
      if self.char_names and type(row.char_id) == 'string' then self.char_names[row.char_id] = row.name end
      local last, created = stamp(row.last_seen_at), stamp(row.created_at)
      if (created and last and created > last)
        or (last and self.taken and last > self.taken + TIME_SLACK_S) then
        self:find(collection, 'time_order', name)
      end
    end

    local ref = REFS[collection]
    if ref then
      local value = row[ref.field]
      if value == nil then
        if not ref.optional then self:find(collection, 'missing_reference', name) end
      else
        local list = self.refs[collection] or {}
        self.refs[collection] = list
        list[#list + 1] = { value = tostring(value), name = name }
      end
    end
  end
  local ok, code = self.chunker:add(collection, row)
  self:chunker_failed(ok, code)
  return ok, code
end

function Sink:finish(counts)
  for collection, list in pairs(self.refs) do
    local target = self.seen[REFS[collection].target]
    for _, r in ipairs(list) do
      if not target[r.value] then self:find(collection, 'missing_reference', r.name) end
    end
  end
  self.refs = {}
  local ok, code = self.chunker:finish(counts)
  self:chunker_failed(ok, code)
  return ok, code
end

function Sink:abort(err)
  self.aborted = err
  return self.chunker:abort(err)
end

--- What the checks found: { counts, total, chunks, bytes, findings, problems }.
function Sink:result()
  local chunks = 0
  for _, n in pairs(self.chunker.chunks) do chunks = chunks + n end
  local problems = 0
  for _, n in pairs(self.findings) do problems = problems + n end
  return {
    counts = self.chunker:manifest(),
    total = self.chunker.total,
    chunks = chunks,
    bytes = self.chunker.bytes,
    findings = self.findings,
    problems = problems,
  }
end

-- Running it -------------------------------------------------------------------

local SAFE_CODE = '^[%a][%w_%.%-]*$'

local function safe_code(err)
  return type(err) == 'string' and #err <= 64 and err:match(SAFE_CODE) and err or 'collector_failed'
end

--- Run the check (inside a thread: the collector yields). opts.verbose keeps
--- the names behind each finding. Returns the report table M.lines() prints.
function M.run(opts)
  opts = opts or {}
  if S.running then return { error = 'already_running' } end
  if Aptic.scheduler and Aptic.scheduler.state.collecting then return { error = 'snapshot_collecting' } end
  if not (Aptic.collector and type(Aptic.collector.run) == 'function') then return { error = 'no_collector' } end

  S.running = true
  local started = Aptic.time.monotonic_ms()
  local names = opts.verbose and {} or nil
  local sink = M.sink({ names = names })
  local observe = nil
  if names then
    observe = function(kind, key, name)
      if not name then return end
      local list = names[key] or {}
      names[key] = list
      list[#list + 1] = name
    end
  end
  -- The same options an upload's run gets (uploader.collect), plus observe.
  local offset = Aptic.heartbeat and Aptic.heartbeat.state.clock_offset_s or 0
  local t = Aptic.time.now() + offset
  local ok, summary, err = pcall(Aptic.collector.run, sink, {
    snapshot_id = sink.chunker.snapshot_id,
    taken_at = Aptic.time.iso(t),
    now = t,
    clock_offset_s = offset,
    max_rows = Aptic.config.upload.max_rows,
    observe = observe,
  })
  S.running = false

  local report = sink:result()
  report.duration_ms = math.max(0, Aptic.time.monotonic_ms() - started)
  report.names = names
  if not ok then
    -- Only where it failed: an error message could quote a row value.
    Aptic.log.debug('validate: collector error at %s', tostring(summary):match('^([^:\n]+:%d+):') or 'unknown location')
    report.error = 'collector_error'
  elseif summary == nil then
    report.error = safe_code(err)
  else
    report.skipped = summary.skipped
    report.adjusted = summary.adjusted
    report.txadmin = summary.txadmin and summary.txadmin.state
  end
  report.ok = report.error == nil and report.problems == 0
  S.last = { at = Aptic.time.now(), ok = report.ok, error = report.error, problems = report.problems }
  return report
end

-- Output -----------------------------------------------------------------------

local ERRORS = {
  already_running = 'a check is already running',
  snapshot_collecting = 'a snapshot is being collected right now; try again in a minute',
  no_collector = 'snapshot collection is not available in this version',
  salt_not_pinned = 'aptic_salt is not pinned; run `aptic salt` for the line to add',
  hashing_unavailable = 'transport.js is not loaded, so nothing can be hashed',
  framework_not_detected = 'no started framework and inventory',
  unsupported_combination = 'this framework and inventory combination is not supported',
  oxmysql_unavailable = 'oxmysql is not started',
  players_table_unreadable = 'the players table was not found',
  snapshot_too_large = 'more rows than Aptic accepts in one snapshot (50,000)',
  pagination_stuck = 'a database page did not move forward',
  collector_error = 'the collector raised an error (set aptic_debug 1 for where)',
}

local function names_line(list)
  local shown, more = {}, 0
  for i, n in ipairs(list) do
    if i <= MAX_NAMES then shown[#shown + 1] = n else more = more + 1 end
  end
  return table.concat(shown, ', ') .. (more > 0 and (' and %d more'):format(more) or '')
end

--- The lines `aptic validate` prints for a report. opts.verbose adds names.
function M.lines(report, opts)
  opts = opts or {}
  local out = {}
  local function add(label, value) out[#out + 1] = ('%-15s %s'):format(label, value) end
  local function detail(key, n)
    local hint = M.HINTS[key] or M.HINTS[key:match('^[^.]+%.(.+)$') or ''] or ''
    out[#out + 1] = ('  %-38s %5d%s'):format(key, n, hint ~= '' and ('  ' .. hint) or '')
    if opts.verbose and report.names and report.names[key] then
      out[#out + 1] = '      ' .. names_line(report.names[key])
    end
  end

  add('aptic validate', 'a local check: nothing was uploaded')
  if report.error then
    add('result', 'not checked: ' .. (ERRORS[report.error] or report.error) .. ' (' .. report.error .. ')')
    return out
  end

  local parts = {}
  for _, c in ipairs(Aptic.chunker.COLLECTIONS) do
    local n = report.counts[c] or 0
    if n > 0 then parts[#parts + 1] = ('%s %d'):format(c, n) end
  end
  add('would send', ('%d rows (%s) in %d chunks, %.1f KiB, collected in %d ms'):format(
    report.total, #parts > 0 and table.concat(parts, ', ') or 'none', report.chunks,
    (report.bytes or 0) / 1024, report.duration_ms or 0))
  if report.txadmin then
    add('txAdmin', report.txadmin == 'ok' and 'found: created_at and playtime are sent'
      or ('not used (' .. report.txadmin .. '): created_at and playtime are sent as unknown'))
  end

  local skipped = report.skipped or { reasons = {} }
  local reasons = sorted_keys(skipped.reasons)
  local n_skipped = 0
  for _, k in ipairs(reasons) do n_skipped = n_skipped + skipped.reasons[k] end
  add('skipped rows', n_skipped == 0 and 'none' or tostring(n_skipped))
  for _, k in ipairs(reasons) do detail(k, skipped.reasons[k]) end

  local adjusted = sorted_keys(report.adjusted)
  local n_adjusted = 0
  for _, k in ipairs(adjusted) do n_adjusted = n_adjusted + report.adjusted[k] end
  add('adjusted', n_adjusted == 0 and 'none' or (n_adjusted .. ' values, sent anyway'))
  for _, k in ipairs(adjusted) do detail(k, report.adjusted[k]) end

  if report.problems == 0 then
    add('snapshot rules', 'ok: no duplicate keys, missing references or time-order problems')
  else
    add('snapshot rules', report.problems .. ' problems Aptic would reject (snapshot_invalid)')
    for _, k in ipairs(sorted_keys(report.findings)) do detail(k, report.findings[k]) end
  end

  if report.ok then
    add('result', 'ok: Aptic would accept this snapshot'
      .. (n_skipped > 0 and '; the skipped rows above are left out' or ''))
  else
    add('result', 'Aptic would reject this snapshot. This is a bug in aptic_bridge: please report these lines.')
  end
  if not opts.verbose and report.names == nil and (n_skipped > 0 or n_adjusted > 0) and opts.console then
    out[#out + 1] = 'Run `aptic validate --verbose` on the server console to see which characters.'
  end
  return out
end

--- After Aptic answered snapshot_invalid: run the check in its own thread
--- and log what it finds. Returns true if a check was queued.
function M.after_rejection(collection, reason)
  if S.running or S.queued then return false end
  S.queued = true
  CreateThread(function()
    S.queued = nil
    local report = M.run({})
    Aptic.log.warn('Checked the data locally after snapshot_invalid%s (aptic validate):',
      collection and (' (' .. collection .. (reason and (' ' .. reason) or '') .. ')') or '')
    for _, line in ipairs(M.lines(report)) do Aptic.log.info('%s', line) end
  end)
  return true
end

return M
