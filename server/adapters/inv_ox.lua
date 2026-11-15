-- ox_inventory adapter (pairs with Qbox).
--
-- Decision D3: v1 sends no inventory. No containers or item_stacks are
-- collected and the `inventory` capability is never declared, so this
-- adapter only reports what the probe saw, for diagnostics.
--
-- Balances don't need the inventory: ox_inventory's qbx bridge mirrors
-- players.money.cash into a `money` item, and the collectors read money from
-- the framework (players.money / PlayerData.money), never from items, so
-- cash is counted once. When inventory returns (M4), player containers must
-- exclude ox's account items for the same reason (plan §2.2).

Aptic = Aptic or {}
Aptic.adapters = Aptic.adapters or {}

local M = { id = 'ox_inventory', resource = 'ox_inventory' }
Aptic.adapters.ox_inventory = M

--- What storage the probe found: 'ox' (the ox_inventory table) or 'unknown'.
function M.storage(schema)
  return (schema.tables.ox_inventory and 'ox') or 'unknown'
end

-- Item reference prices (decision D6): PAUSED. v1 builds no price handling.
-- When the registry collection returns, ox item definitions come from
-- exports.ox_inventory:Items(), and reference_price is sent as null (C4)
-- with prices kept in the dashboard. Do not read prices from config here.

return M
