-- Player identity for snapshots (plan §4.1-4.2, decision D8).
--
--   player_hash = hex(HMAC-SHA256(salt, "aptic.v1|" .. lower(license)))
--
-- computed by transport.js with Node's crypto. The JS side reads the pinned
-- `aptic_salt` convar itself, so the salt is never passed around in Lua and
-- only the pinned value can be used: with no pinned salt there is no
-- session and nothing is collected. Every answer carries the salt
-- fingerprint; if it stops matching the one this run started with (the
-- salt was changed from the console mid-run), the run is abandoned rather
-- than mixing two hash epochs in one snapshot.
--
-- Licenses go to the JS side and hashes come back; neither is ever logged.

Aptic = Aptic or {}
local M = {}
Aptic.hashing = M

local function js()
  return exports[GetCurrentResourceName()]
end

local HASH = '^' .. ('[0-9a-f]'):rep(64) .. '$'
local TAG = '^' .. ('[0-9a-f]'):rep(8) .. '$'

local Session = {}
Session.__index = Session

--- Start a hashing session for one collection run. Returns the session, or
--- nil and 'salt_not_pinned' | 'hashing_unavailable'.
function M.session()
  local cfg = Aptic.convars.read()
  if cfg.salt.state ~= 'pinned' then return nil, 'salt_not_pinned' end
  local salt = Aptic.identity.salt(cfg.salt)
  if not (salt.pinned and salt.fp) then return nil, 'hashing_unavailable' end
  return setmetatable({ fp = salt.fp, hashes = {}, tags = {} }, Session)
end

local function call(export, list)
  local ok, result = pcall(function() return js()[export](js(), list) end)
  if not ok or type(result) ~= 'table' then return nil, 'hashing_unavailable' end
  if result.error == 'salt_not_pinned' then return nil, 'salt_not_pinned' end
  if result.error then return nil, 'hashing_unavailable' end
  return result
end

local function fill(self, cache, export, field, pattern, values)
  local missing, seen = {}, {}
  for _, v in ipairs(values) do
    if type(v) == 'string' and cache[v] == nil and not seen[v] then
      seen[v] = true
      missing[#missing + 1] = v
    end
  end
  if #missing > 0 then
    local result, err = call(export, missing)
    if not result then return nil, err end
    if result.salt_fp ~= self.fp then return nil, 'salt_changed' end
    local got = type(result[field]) == 'table' and result[field] or {}
    for _, v in ipairs(missing) do
      local h = got[v]
      cache[v] = (type(h) == 'string' and h:match(pattern)) and h or false
    end
  end
  local out = {}
  for _, v in ipairs(values) do
    if cache[v] then out[v] = cache[v] end
  end
  return out
end

--- player_hash for each license string. Returns { [license] = hash } (a
--- license the JS side refused, such as an over-long one, is left out), or
--- nil and an error code.
function Session:player_hashes(licenses)
  return fill(self, self.hashes, 'playerHashes', 'hashes', HASH, licenses)
end

--- 8-hex pseudonym tags per char_id (D7). Same return shape.
function Session:pseudonym_tags(char_ids)
  return fill(self, self.tags, 'pseudonymTags', 'tags', TAG, char_ids)
end

--- The display name used when pseudonymize is on, or a character has no
--- readable charinfo name.
function M.pseudonym(tag)
  return 'Character ' .. tag
end

return M
