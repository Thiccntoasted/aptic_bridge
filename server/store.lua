-- The chunk store (plan §5.2): what survives a restart.
--
-- Files, under the resource's cache/ folder (through transport.js, decision
-- D4): one folder per snapshot holding
--   <collection>.<index>.json   the exact `rows` array of one chunk
--   start.json                  the exact `start` request body
--   manifest.json               ids, counts and chunk counts, for people
-- The folder is deleted once the snapshot is published or abandoned.
--
-- KVP: the state machine. `snap.current` holds the snapshot id and
-- `snap.state` its phase and everything resume needs; the rest are small
-- counters (published in 24 h, starts in the last hour, last outcome).
-- Nothing stored here is a secret: the key appears only as its 16-character
-- prefix, the salt only as its fingerprint.

Aptic = Aptic or {}
local M = {}
Aptic.store = M

M.KVP = {
  current = 'snap.current',
  state = 'snap.state',
  published = 'snap.published',
  starts = 'snap.starts',
  last = 'snap.last',
  last_published = 'snap.last_published',
  out_of_order = 'snap.out_of_order',
  byte_budget = 'snap.byte_budget',
  slot_offset = 'snap.slot_offset',
}

local function js()
  return exports[GetCurrentResourceName()]
end

local function call(name, ...)
  local args = table.pack(...)
  local ok, value = pcall(function() return js()[name](js(), table.unpack(args, 1, args.n)) end)
  if ok then return value end
  return nil
end

-- Files --------------------------------------------------------------------------

local function path(id, name)
  return name and (id .. '/' .. name) or id
end

--- Write one file of a snapshot. True on success.
function M.write(id, name, text)
  local n = call('cacheWrite', path(id, name), text)
  return type(n) == 'number' and n == #text
end

--- One file of a snapshot, or nil.
function M.read(id, name)
  local text = call('cacheRead', path(id, name))
  if type(text) == 'string' then return text end
  return nil
end

--- Delete a snapshot's folder.
function M.remove(id)
  return call('cacheRemove', id) == true
end

--- Names of the snapshot folders in cache/.
function M.list()
  local names = call('cacheList')
  if type(names) ~= 'table' then return {} end
  local out = {}
  for _, n in ipairs(names) do if type(n) == 'string' then out[#out + 1] = n end end
  return out
end

--- Delete every folder in cache/ except `keep`.
function M.prune(keep)
  local removed = 0
  for _, name in ipairs(M.list()) do
    if name ~= keep and M.remove(name) then removed = removed + 1 end
  end
  return removed
end

-- KVP ------------------------------------------------------------------------------

function M.get_json(key)
  local raw = GetResourceKvpString(key)
  if type(raw) ~= 'string' or raw == '' then return nil end
  return (Aptic.chunker.decode(raw))
end

function M.set_json(key, value)
  if value == nil then
    DeleteResourceKvp(key)
  else
    SetResourceKvp(key, Aptic.chunker.encode(value))
  end
end

function M.get_number(key)
  return tonumber(GetResourceKvpString(key))
end

function M.set_number(key, value)
  SetResourceKvp(key, tostring(math.floor(value)))
end

--- The current snapshot record, or nil. A record that can't be read back
--- comes back as { id, phase = 'broken' } so the caller drops it.
function M.load()
  local id = GetResourceKvpString(M.KVP.current)
  if type(id) ~= 'string' or id == '' then return nil end
  local rec = M.get_json(M.KVP.state)
  if type(rec) ~= 'table' or rec.id ~= id or type(rec.phase) ~= 'string' then
    return { id = id, phase = 'broken' }
  end
  return rec
end

function M.save(rec)
  SetResourceKvp(M.KVP.current, rec.id)
  M.set_json(M.KVP.state, rec)
end

function M.clear()
  DeleteResourceKvp(M.KVP.state)
  DeleteResourceKvp(M.KVP.current)
end

-- Rolling counters (epochs within a window) ------------------------------------

local function recent(key, now, window_s)
  local out = {}
  local list = M.get_json(key)
  if type(list) == 'table' then
    for _, t in ipairs(list) do
      if type(t) == 'number' and t > now - window_s and t <= now + 60 then out[#out + 1] = t end
    end
  end
  table.sort(out)
  return out
end

--- Record an event at `now`, keeping only the last `window_s`.
function M.note(key, now, window_s)
  local list = recent(key, now, window_s)
  list[#list + 1] = math.floor(now)
  M.set_json(key, list)
  return #list
end

--- How many events in the last `window_s`, and the oldest of them.
function M.count(key, now, window_s)
  local list = recent(key, now, window_s)
  return #list, list[1]
end

return M
