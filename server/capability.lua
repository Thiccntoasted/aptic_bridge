-- Which framework and inventory this server runs, their versions, and
-- whether aptic_bridge supports the pair (plan §1, §3.3; decisions D1, D11).
--
-- qbx_core is checked before qb-core because qbx_core declares
-- `provide 'qb-core'`; ox_inventory is checked before qb-inventory.
-- Detection is cheap and runs again before every heartbeat, so a framework
-- that starts after aptic_bridge (or is restarted) is picked up.

Aptic = Aptic or {}
local M = {}
Aptic.capability = M

M.FRAMEWORKS = {
  { id = 'qbox', resource = 'qbx_core', label = 'Qbox' },
  { id = 'qbcore', resource = 'qb-core', label = 'QBCore' },
}

M.INVENTORIES = {
  { id = 'ox_inventory', resource = 'ox_inventory', label = 'ox_inventory' },
  { id = 'qb-inventory', resource = 'qb-inventory', label = 'qb-inventory' },
}

-- The pairs the ingest contract accepts, and what v1 does with each.
M.SUPPORT = {
  ['qbox+ox_inventory'] = { state = 'supported', note = 'pilot, first adapter' },
  ['qbcore+qb-inventory'] = { state = 'supported', note = 'second adapter' },
  ['qbox+qb-inventory'] = {
    state = 'unsupported',
    reason = 'Qbox requires ox_inventory; Aptic does not support Qbox with qb-inventory',
  },
  ['qbcore+ox_inventory'] = {
    state = 'unsupported',
    reason = 'QBCore with ox_inventory (2.41 or older) is supported only on request',
  },
}

local VERSION_MAX = 32

--- A version string the contract accepts (^[0-9A-Za-z][0-9A-Za-z._+-]{0,31}$),
--- with a leading "v" dropped ("v2.44.1" -> "2.44.1"), or nil.
function M.clean_version(value)
  if type(value) ~= 'string' then return nil end
  local v = value:gsub('^%s+', ''):gsub('%s+$', '')
  v = v:gsub('^[vV](%d)', '%1')
  if #v < 1 or #v > VERSION_MAX then return nil end
  if not v:match('^[%w][%w%._%+%-]*$') then return nil end
  return v
end

local function started(resource)
  return GetResourceState(resource) == 'started'
end

local function pick(list)
  for _, entry in ipairs(list) do
    if started(entry.resource) then
      return entry, M.clean_version(GetResourceMetadata(entry.resource, 'version', 0))
    end
  end
  return nil
end

--- Detect now. Returns:
---   framework, framework_resource, framework_version (nil when absent/unreadable)
---   inventory, inventory_resource, inventory_version
---   support  'supported' | 'unsupported' | 'incomplete'
---   reason   why, when not supported
function M.detect()
  local fw, fw_version = pick(M.FRAMEWORKS)
  local inv, inv_version = pick(M.INVENTORIES)
  local result = {
    framework = fw and fw.id,
    framework_resource = fw and fw.resource,
    framework_version = fw_version,
    inventory = inv and inv.id,
    inventory_resource = inv and inv.resource,
    inventory_version = inv_version,
  }
  if not fw or not inv then
    local missing = {}
    if not fw then missing[#missing + 1] = 'framework (qbx_core or qb-core)' end
    if not inv then missing[#missing + 1] = 'inventory (ox_inventory or qb-inventory)' end
    result.support = 'incomplete'
    result.reason = 'no started ' .. table.concat(missing, ' or ')
      .. '; ensure aptic_bridge after them in server.cfg'
    return result
  end
  local support = M.SUPPORT[fw.id .. '+' .. inv.id]
  result.support = support.state
  result.reason = support.reason
  result.note = support.note
  return result
end

--- "qbox 1.24.1 + ox_inventory 2.44.1" for logs and status.
function M.describe(cap)
  if not cap.framework and not cap.inventory then return 'none detected' end
  local function part(id, version)
    if not id then return '?' end
    return version and (id .. ' ' .. version) or (id .. ' (version unknown)')
  end
  return part(cap.framework, cap.framework_version) .. ' + '
    .. part(cap.inventory, cap.inventory_version)
end

--- The adapter pair as one comparable string, or nil.
function M.pair(cap)
  if cap.framework and cap.inventory then return cap.framework .. '+' .. cap.inventory end
  return nil
end

return M
