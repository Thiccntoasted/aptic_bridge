-- Console output. Every line the bridge prints goes through here, and every
-- line is redacted first (plan §4.4):
--   * connection keys: `apt_ing_` keeps at most the 8 characters the
--     dashboard shows as the prefix, never the rest;
--   * any value registered with add_secret (the configured key and the
--     pinned salt, whatever their format) is replaced outright;
--   * player identifiers (license, steam, discord, fivem, xbl, live, ip) and
--     IPv4 addresses other than loopback.
-- A test greps everything printed in every scenario for the key.

Aptic = Aptic or {}
local M = {}
Aptic.log = M

local secrets = {}
local last_by_topic = {}

local COLORS = { error = '^1', warn = '^3', info = '^5', debug = '^8' }

--- Register a value that must never be printed (at least 8 characters).
function M.add_secret(value)
  if type(value) == 'string' and #value >= 8 then
    secrets[value] = true
    secrets[value:lower()] = true
  end
end

local function replace_plain(s, needle, repl)
  local out, start = {}, 1
  while true do
    local i, j = s:find(needle, start, true)
    if not i then break end
    out[#out + 1] = s:sub(start, i - 1)
    out[#out + 1] = repl
    start = j + 1
  end
  out[#out + 1] = s:sub(start)
  return table.concat(out)
end

local function mask_ipv4(ip)
  if ip:match('^127%.') then return nil end
  return '[ip]'
end

--- Redact a string. Safe to call on anything.
function M.redact(value)
  local s = tostring(value)
  for secret in pairs(secrets) do
    if s:find(secret, 1, true) then s = replace_plain(s, secret, '[redacted]') end
  end
  s = s:gsub('apt_ing_([%w_%-]+)', function(rest)
    if #rest <= 8 then return nil end
    return 'apt_ing_' .. rest:sub(1, 8) .. '…'
  end)
  s = s:gsub('license2?:%x+', 'license:[redacted]')
  s = s:gsub('steam:%x+', 'steam:[redacted]')
  s = s:gsub('discord:%d+', 'discord:[redacted]')
  s = s:gsub('fivem:%d+', 'fivem:[redacted]')
  s = s:gsub('xbl:%d+', 'xbl:[redacted]')
  s = s:gsub('live:%d+', 'live:[redacted]')
  s = s:gsub('ip:[%d%.:]+', 'ip:[redacted]')
  s = s:gsub('%d+%.%d+%.%d+%.%d+', mask_ipv4)
  return s
end

local function debug_enabled()
  return GetConvar('aptic_debug', '0') == '1'
end

local function format(fmt, ...)
  if select('#', ...) == 0 then return tostring(fmt) end
  local ok, text = pcall(string.format, fmt, ...)
  return ok and text or tostring(fmt)
end

--- Print one line at a level. The only function in the resource that prints.
function M.write(level, text)
  if level == 'debug' and not debug_enabled() then return end
  local color = COLORS[level] or ''
  local tag = level == 'info' and '' or (level .. ': ')
  print(('%s[aptic]^7 %s%s'):format(color, tag, M.redact(text)))
end

function M.error(fmt, ...) M.write('error', format(fmt, ...)) end
function M.warn(fmt, ...) M.write('warn', format(fmt, ...)) end
function M.info(fmt, ...) M.write('info', format(fmt, ...)) end
function M.debug(fmt, ...) M.write('debug', format(fmt, ...)) end

--- Log only when the message for `topic` differs from the last one, so a
--- repeating failure prints once instead of every minute.
function M.change(topic, level, fmt, ...)
  local text = format(fmt, ...)
  if last_by_topic[topic] == text then return false end
  last_by_topic[topic] = text
  M.write(level, text)
  return true
end

--- Forget the last message for `topic`, so the next change() prints again.
function M.reset(topic)
  last_by_topic[topic] = nil
end

return M
