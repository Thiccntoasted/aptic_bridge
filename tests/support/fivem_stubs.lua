-- Stand-ins for the FiveM natives aptic_bridge uses, so the resource's Lua
-- runs unchanged under plain Lua 5.4 (wasmoon). State lives in `Stub`.

Stub = {}

function Stub.reset()
  Stub.convars = {}
  Stub.resources = {}
  Stub.kvp = {}
  Stub.prints = {}
  Stub.timer = 0
  Stub.commands = {}
  Stub.chat = {}
  Stub.aces = {}
  Stub.threads = {}
  Stub.export_overrides = {}
  Stub.self_version = '0.1.0'
end
Stub.reset()

function Stub.start(resource, version)
  Stub.resources[resource] = { state = 'started', meta = { version = version } }
end

function Stub.stop(resource)
  if Stub.resources[resource] then Stub.resources[resource].state = 'stopped' end
end

--- Everything printed so far, with FiveM colour codes removed.
function Stub.output()
  return (table.concat(Stub.prints, '\n'):gsub('%^%d', ''))
end

function GetConvar(name, default)
  local v = Stub.convars[name]
  if v == nil then return default end
  return tostring(v)
end

function GetConvarInt(name, default)
  local v = tonumber(Stub.convars[name])
  if v == nil then return default end
  return math.tointeger(v) or default
end

function GetResourceState(name)
  local r = Stub.resources[name]
  return r and r.state or 'missing'
end

function GetResourceMetadata(name, key, index)
  if name == 'aptic_bridge' and key == 'version' then return Stub.self_version end
  local r = Stub.resources[name]
  return r and r.meta and r.meta[key] or nil
end

function GetCurrentResourceName() return 'aptic_bridge' end

function GetResourceKvpString(key) return Stub.kvp[key] end
function SetResourceKvp(key, value) Stub.kvp[key] = value end
function DeleteResourceKvp(key) Stub.kvp[key] = nil end

function GetGameTimer() return Stub.timer end

function print(...)
  local parts = {}
  for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
  Stub.prints[#Stub.prints + 1] = table.concat(parts, ' ')
end

function RegisterCommand(name, handler, restricted)
  Stub.commands[name] = { handler = handler, restricted = restricted }
end

function IsPlayerAceAllowed(source, ace)
  return Stub.aces[tostring(source) .. ':' .. ace] == true
end

function TriggerClientEvent(name, target, payload)
  Stub.chat[#Stub.chat + 1] = { name = name, target = target, payload = payload }
end

function CreateThread(fn) Stub.threads[#Stub.threads + 1] = fn end
function Wait() end
Citizen = { CreateThread = CreateThread, Wait = Wait }

-- A synchronous promise: enough for callbacks that answer at once.
promise = {}
function promise.new()
  local p = { done = false }
  function p:resolve(value) self.done, self.value = true, value end
  return p
end
function Citizen.Await(p)
  if not p.done then error('promise never resolved (the stub resolves synchronously only)') end
  return p.value
end

-- exports['aptic_bridge']:fn(...) reaches transport.js (loaded by the JS
-- harness through __js_export) unless a test overrides the export.
exports = setmetatable({}, {
  __index = function(_, resource)
    return setmetatable({}, {
      __index = function(_, name)
        return function(_self, ...)
          local override = Stub.export_overrides[name]
          if override then return override(...) end
          if not __js_export then error('no JS export bridge') end
          return __js_export(name, ...)
        end
      end,
    })
  end,
})
