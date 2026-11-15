-- qb-inventory adapter (pairs with QBCore).
--
-- Decision D3: v1 sends no inventory. No containers or item_stacks are
-- collected and the `inventory` capability is never declared, so this
-- adapter only reports what the probe saw, for diagnostics: qb-inventory
-- 2.x keeps stashes, trunks and gloveboxes in one `inventories` table;
-- 1.x used `stashitems` / `trunkitems` / `gloveboxitems` (upstream ships a
-- migrate.sql).

Aptic = Aptic or {}
Aptic.adapters = Aptic.adapters or {}

local M = { id = 'qb-inventory', resource = 'qb-inventory' }
Aptic.adapters['qb-inventory'] = M

--- 'inventories' (2.x), 'legacy' (1.x tables only) or 'unknown'.
function M.storage(schema)
  if schema.tables.inventories then return 'inventories' end
  if schema.tables.stashitems then return 'legacy' end
  return 'unknown'
end

-- Item reference prices (decision D6): PAUSED. v1 builds no price handling.
-- When the registry collection returns, item definitions come from
-- QBCore.Shared.Items, and reference_price is sent as null (C4) with prices
-- kept in the dashboard. Do not read prices from config here.

return M
