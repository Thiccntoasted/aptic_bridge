# Compatibility

This file lists only what has actually been tested, and how. Anything not listed here is untested.

**State for 0.1.0 (15 November 2026): no live game server has run aptic_bridge yet.** The pilot is still to come. Until it confirms a combination, Aptic's dashboard shows every framework and inventory version as "untested", and so does this file.

## Tested against fixture databases

The resource's real Lua (collectors, upload engine) and `transport.js` were run under Lua 5.4 and Node.js, with the FiveM natives and oxmysql replaced by stand-ins. The database is a fixture shaped like each framework's published schema. These runs cover the code; they don't cover a live server.

| Framework | Inventory | Versions the fixtures model | Unit and collector tests | End to end into a local Aptic |
| --- | --- | --- | --- | --- |
| Qbox (`qbx_core`) | `ox_inventory` | qbx_core 1.24.1, ox_inventory 2.44.1, qbx_vehicles `player_vehicles` | yes | yes (15 Nov 2026) |
| QBCore (`qb-core`) | `qb-inventory` | qb-core 1.3.0, qb-inventory 2.2.3, qb-garages `player_vehicles` | yes | yes (15 Nov 2026) |

**End to end** means `tests/integration/e2e.integration.mjs`. The fixture database was repeated 300 times (Qbox: 2,101 characters and 9,310 rows; QBCore: 1,200 characters and 6,305 rows). It went through the real upload engine over HTTP into a local Aptic: Next.js dev server plus the local Supabase stack, running the frozen ingest v1 contract. The snapshot was published, the stored row counts matched what was sent, Aptic's preparation and analysis completed, and no stored row contained a license or other identifier from the fixture.

The fixtures include the edge cases the collectors handle: negative bank balances, custom and invalid money types, malformed JSON in `money`, `job` and `charinfo`, emoji and control characters in names, sparse job grades, impounded vehicles and unknown vehicle states, duplicate and over-long plates (QBCore), case-only citizenid mismatches, owners missing from `players`, a database clock running ahead, and online players not yet saved.

txAdmin was tested only through a fixture `playersDB.json` (format `version: 5`), read by the real `transport.js`. The file layout was checked against txAdmin's source, not against a running txAdmin.

## Not tested yet

- **Any live FXServer.** This covers resource load order, FXServer's bundled Node.js runtime and its certificate store, KVP persistence across restarts, `SaveResourceFile` in `cache/`, real oxmysql against MySQL or MariaDB, `GetResourceMetadata` versions, ACEs and txAdmin's live console. There's no minimum FXServer build yet.
- **Real framework exports at runtime:** `exports.qbx_core:GetPlayersData/GetJobs/GetGangs`, QBCore's `GetCoreObject().Functions.GetQBPlayers()`, and their shapes on versions other than the ones above.
- **Performance on a real server** (tick time, memory, hitch warnings) at 64 or 256 slots.
- **Other versions** of any framework or inventory. The bridge uploads on untested versions and shows a warning (decision D10).
- **QBCore + ox_inventory 2.41 or older:** recognised, but not supported (only on request).
- **Qbox + qb-inventory:** not supported. Qbox requires ox_inventory.
- **qb-inventory 1.x** (the `stashitems` / `trunkitems` tables) and any inventory data. 0.1.0 doesn't send inventories at all.

## How to add a row here

A combination moves to "tested on a live server" only with evidence from a real server: console logs from install, restart and key rotation; `aptic validate` counts compared with SQL `COUNT(*)`; money totals that reconcile with the dashboard; a profiler capture; and a clean uninstall. Record the FXServer build, the exact resource versions and the date.
