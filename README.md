# aptic_bridge

The FiveM server resource that connects a roleplay server to [Aptic](https://aptic.dev). Once an hour it reads the server's economy (characters, balances, vehicles, jobs and gangs) and uploads it to Aptic as one snapshot. A heartbeat every minute keeps the dashboard's "online" status current.

- **Read-only.** It runs `SELECT` queries through your existing oxmysql connection, paged and with a `LIMIT`. It never writes to your database.
- **No raw player identifiers leave the server.** Licenses are replaced with a salted HMAC before anything is sent. Steam, Discord, IPs, hardware ids and FiveM account names are never sent. See [what is sent](#what-is-sent-and-what-never-is).
- **Verified TLS.** Requests go through a small Node.js file (`server/transport.js`) that checks certificates. FiveM's `PerformHttpRequest` doesn't check them, so the bridge never uses it.
- **Server-side only.** Nothing runs on players' machines.
- **Open source** under the MIT license, so anyone can check what it reads and sends.

Version 0.1.0. Short install steps for server owners are in [INSTALL.md](INSTALL.md).

## Supported frameworks and inventories

| Framework | Inventory | Status in 0.1.0 |
| --- | --- | --- |
| Qbox (`qbx_core`) | `ox_inventory` | Supported |
| QBCore (`qb-core`) | `qb-inventory` 2.x | Supported |
| Qbox | `qb-inventory` | Not supported: Qbox requires ox_inventory |
| QBCore | `ox_inventory` (2.41 or older) | Only on request |

"Supported" means there's an adapter for it and it's tested against fixture databases. **It hasn't been tested on a live game server yet.** [COMPATIBILITY.md](COMPATIBILITY.md) lists exactly which versions were tested and how. Aptic's dashboard shows every version as "untested" until a pilot server confirms it.

On an unsupported combination the bridge still sends heartbeats, so the dashboard shows the server, but it never uploads snapshots.

0.1.0 doesn't send inventories (containers and item stacks). Item contents are left out on purpose, because a real server's item stacks don't fit within Aptic's current 50,000-row limit per snapshot.

## Requirements

- **FXServer** with a recent server build. Snapshots run in Lua 5.4. `transport.js` runs on FXServer's built-in Node.js runtime, so you don't install Node yourself. No minimum build is pinned yet, because none has been tested on a live server.
- **oxmysql**, started before aptic_bridge. The bridge loads `@oxmysql/lib/MySQL.lua` and uses `MySQL.query.await`.
- **One supported framework and its inventory**, started before aptic_bridge (see the table above).
- **txAdmin** is optional. When txAdmin runs the server, the bridge reads txAdmin's player database to fill in each character's `created_at` (the player's first join) and `playtime_minutes`. Without txAdmin both are sent as unknown, never guessed.
- **An Aptic workspace** whose framework and inventory settings match the server, and a connection key for it.

## Install

1. **Get the files.** Download `aptic_bridge-0.1.0.zip` from the releases page and extract it into your `resources` folder, for example `resources/[aptic]/aptic_bridge`. Keep the folder name `aptic_bridge`: FiveM stores the resource's saved state under that name.
2. **Get a connection key.** In Aptic, open **Settings → Connection** and create a key. Aptic shows it only once.
3. **Add to `server.cfg`**, after oxmysql, your framework and your inventory:

   ```cfg
   # aptic_bridge: server-only. Use `set`, never `setr` or `sets`.
   set aptic_api_key "apt_ing_..."
   ensure aptic_bridge
   ```

4. **Start it** with `ensure aptic_bridge` in the live console, or restart the server. The first start prints a hash salt line. Add that line to `server.cfg` as well, then restart (see [the hash salt](#the-hash-salt)).

When everything is set up, the console shows:

```
[aptic] aptic_bridge 0.1.0 starting. Framework/inventory: qbox 1.24.1 + ox_inventory 2.44.1.
[aptic] heartbeat ok: qbox 1.24.1 + ox_inventory 2.44.1, key apt_ing_xxxxxxxx…, endpoint aptic.dev.
```

The dashboard shows the server as online within about a minute. The first snapshot uploads at this server's slot within the hour. To send one straight away, run `aptic upload now`.

## Configuration

These convars go in `server.cfg`. **Always use `set`.** `setr` sends the value to every player who joins. `sets` publishes it in the server list. Either one would leak your key or your salt, and the resource can't tell which command you used.

| Convar | Required | Meaning |
| --- | --- | --- |
| `aptic_api_key` | yes | The connection key from Settings → Connection: `apt_ing_` followed by 43 characters. It's read again before every request, so a key you paste in the live console takes effect without a restart. |
| `aptic_salt` | yes, for snapshots | 64 hex characters. Heartbeats run without it, but snapshots don't upload until it's set. See below. |
| `aptic_endpoint` | no | The ingest URL. Defaults to `https://aptic.dev/api/ingest/v1`. Must use `https://`. |
| `aptic_dev` | no | `1` also allows `http://localhost` endpoints, for testing against a local Aptic. Leave it unset on a live server. |
| `aptic_debug` | no | `1` prints extra detail, such as each retry. Keys and identifiers stay redacted. |

```cfg
set aptic_api_key "apt_ing_..."
set aptic_salt "<64 hex characters printed on first start>"
# optional
set aptic_endpoint "https://aptic.dev/api/ingest/v1"
```

Everything else is in `config.lua`: timings, the snapshot interval (60 minutes, kept between 30 and 240), money-type renames, pseudonymized names and the txAdmin file path. The defaults suit most servers.

### The hash salt

Aptic never receives a player's license, only an HMAC of it keyed with your salt (the format is [below](#how-player_hash-is-computed)). The salt must stay the same for good. If it changes, every player looks new to Aptic. Characters keep their history, because they're identified by citizenid, but the link between a player's characters breaks at that point.

So the salt is **pinned in `server.cfg`**. On the first start without `aptic_salt`, the bridge generates one and prints the line to add:

```
[aptic] warn: No hash salt is pinned (aptic_salt).
[aptic] warn: Add this line to server.cfg, keep a backup of it, and restart:
[aptic] warn:   set aptic_salt "3f9c…"
[aptic] warn: Snapshots will not upload until the salt is pinned. Heartbeats continue.
```

Add the line, keep a copy of it somewhere safe (a password manager, for example), and restart. Run `aptic salt` in the server console to see the line again. Once the salt is pinned, the bridge never prints it. Only its 8-character fingerprint appears, in `aptic status` and on the dashboard. If you move the server to another machine, take the line with you.

Treat the salt like a password. Anyone who has it and a list of licenses can work out which `player_hash` belongs to whom.

### Pseudonymized names

By default Aptic receives each character's roleplay name from `charinfo` (first and last name), so staff can recognise characters on the dashboard. To send stable pseudonyms instead, set this in `config.lua`:

```lua
pseudonymize = true,
```

Each character is then sent as `Character 1a2b3c4d`. The tag is the first 8 hex characters of HMAC-SHA256(salt, `aptic.v1.name|` + the lowercased citizenid). It stays the same from one snapshot to the next, and nobody can turn it back into a name without your salt. Characters with no readable name in `charinfo` get a pseudonym in either mode. The FiveM account name in `players.name` is never used.

## Console commands

The commands work in the server console and in txAdmin's live console. To let staff run them in game, grant the ACE:

```cfg
add_ace group.admin command.aptic allow
```

| Command | What it does |
| --- | --- |
| `aptic status` | Endpoint, key prefix, last heartbeat result, clock offset, detected framework and inventory with versions, whether the salt is pinned (and its fingerprint), instance id, and snapshot state. It never shows the key or the salt. |
| `aptic salt` | Console only. While no salt is pinned, prints the `set aptic_salt` line to add. Once a salt is pinned, it only confirms the fingerprint. |
| `aptic validate` | Collects a snapshot and checks it locally, **without uploading**. Prints the rows it would send per collection, the chunk count and size, each skipped or adjusted row's reason with a hint, and whether Aptic would accept it (no duplicate keys, missing references or time-order problems). |
| `aptic validate --verbose` | Console only. Also lists the character names behind each reason, so you can find and fix them. It shows names only, never citizenids, licenses, plates or other identifiers. |
| `aptic upload now` | Starts a snapshot now, if nothing blocks it (key, salt, adapter, quota). |
| `aptic upload status` | The current upload's state, the last result, the last published snapshot, the next slot and the quotas used. |

If Aptic ever rejects a snapshot with `snapshot_invalid`, the bridge runs `aptic validate` by itself and logs what it found.

Sample `aptic validate` output:

```
aptic validate  a local check: nothing was uploaded
would send      9310 rows (characters 2101, balances 5403, vehicles 1800, jobs 6) in 49 chunks, 916.7 KiB, collected in 412 ms
txAdmin         found: created_at and playtime are sent
skipped rows    300
  vehicles.state_unknown                   300  player_vehicles.state is not 0 (out), 1 (garaged) or 2 (impounded)
adjusted        300 values, sent anyway
  money_unreadable                         300  players.money is not valid JSON; the character is sent with no balances
snapshot rules  ok: no duplicate keys, missing references or time-order problems
result          ok: Aptic would accept this snapshot; the skipped rows above are left out
```

## Rotating or revoking the key

1. Create a new key in Aptic (Settings → Connection). The old key stops working immediately.
2. Paste the new key into the live console, in txAdmin or the server console: `set aptic_api_key "apt_ing_..."`. The bridge picks it up within a second and sends a heartbeat. No restart is needed.
3. Put the new key in `server.cfg` too, so it's still there after the next restart.

An upload that was running when the key changed is dropped (`credential_rotated`), and the next slot starts a fresh one. If Aptic refuses a key because it was rotated, revoked or mistyped, or because the workspace was archived, the bridge sends nothing more until `aptic_api_key` changes. Revoking works the same way, without step 2.

## What is sent, and what never is

**Sent to Aptic** in each snapshot:

| Collection | Fields |
| --- | --- |
| characters | `char_id` (the citizenid), `player_hash` (HMAC of the license, below), `name` (charinfo first and last name, or a pseudonym), `job` and `job_grade`, `gang`, `last_seen_at`, and from txAdmin, when available, `created_at` and `playtime_minutes` |
| balances | one row per character and money type (`cash`, `bank`, `crypto` and custom types under their own code), with the amount. Negative amounts are kept. |
| vehicles | `plate`, `model`, owner `char_id`, `garage`, and state (garaged, out or impounded) |
| jobs | job and gang definitions: name, label and grade names |
| | the number of players online when the snapshot was taken |

The snapshot also carries the framework, inventory and their versions, the bridge version, the salt fingerprint and a random instance id. The heartbeat sends the same identifying fields plus `sv_maxclients`.

**Never sent:** licenses (`license:`, `license2:`), Steam, Discord, FiveM, Xbox and Live ids, IP addresses, txAdmin hardware ids, `players.name` (the FiveM account name), phone numbers, bank account numbers, birthdates, nationality and any other `charinfo` field beyond first and last name, player metadata (fingerprints, blood type and so on), positions and coordinates, vehicle mods, inventories and item metadata, and the salt.

**Never read:** `players.position`, `players.phone_number`, `players.metadata`, `players.inventory`, `players.name`, and the `mods`, coords, fake plate and finance columns of `player_vehicles`. Licenses are read so they can be hashed on the server; the hashing happens in `transport.js`, and the license itself is never sent anywhere. From txAdmin's `playersDB.json`, only each player's license identifiers (to match the player), first join time and playtime are used.

Logs follow the same rules. Every line goes through `server/log.lua`, which cuts connection keys to their 16-character prefix, replaces the configured key and salt outright, and masks license, Steam, Discord, FiveM, Xbox, Live and IP identifiers and IPv4 addresses. Rows, request bodies and Aptic's error bodies are never logged. The only time character names are printed is `aptic validate --verbose`, on the server console.

### How `player_hash` is computed

```
player_hash = hex( HMAC-SHA256( key = the salt's 32 raw bytes,
                                message = "aptic.v1|" + lowercase(players.license) ) )
```

The key is the 32 bytes the 64-hex salt encodes, not the hex text. The message is the whole `players.license` value as stored, prefix included (`license:…` on QBCore; `license2:…` or `license:…` on Qbox), lowercased. To compute one yourself, for example to find a player's hash on the dashboard:

```sh
printf '%s' 'aptic.v1|license2:a1b2c3d4e5f60718293a4b5c6d7e8f9012345678' \
  | openssl dgst -sha256 -mac HMAC -macopt hexkey:<your 64-hex salt>
```

The salt fingerprint shown in `aptic status` and on the dashboard is the first 8 hex characters of SHA-256 of `aptic-fp` followed by the salt's hex text:

```sh
printf 'aptic-fp%s' '<your 64-hex salt>' | sha256sum | cut -c1-8
```

## Troubleshooting

Every problem the bridge reports has a code. `aptic status` shows the last heartbeat's code, and `aptic upload status` shows the last snapshot's.

**Before anything is sent**

| Code | Meaning and fix |
| --- | --- |
| `no_key`, `invalid_key` | `aptic_api_key` isn't set, or isn't `apt_ing_` followed by 43 characters. Copy the key again from Settings → Connection. |
| `invalid_endpoint`, `insecure_endpoint` | `aptic_endpoint` isn't a valid `https://` URL. Remove it to use the default. |
| `salt_not_pinned` | No `aptic_salt` yet. Run `aptic salt`, add the line it prints and restart. Heartbeats continue meanwhile. |
| `framework_not_detected`, `unsupported_combination` | No supported framework and inventory pair is started, or the pair isn't supported. Start aptic_bridge after them. |
| `oxmysql_unavailable`, `players_table_unreadable`, `query_failed` | oxmysql isn't started, or the `players` table doesn't have the expected columns. |

**Heartbeat answers**

| Code | Meaning and fix |
| --- | --- |
| `invalid_credential` (401) | The key was rotated, revoked or mistyped, or the workspace was archived. Paste the current key with `set aptic_api_key "..."`. Nothing is sent until the key changes. |
| `adapter_mismatch` (422) | The Aptic workspace is set to a different framework or inventory than the server runs. Fix the workspace settings, or check which resources are started. The bridge retries every 10 minutes. |
| `workspace_locked` (403) | The workspace is locked, usually until a plan covers it. Retries every 10 minutes. |
| `plan_limit_exceeded` (403) | `sv_maxclients` is above the slots your plan covers. Upgrade the plan or lower `sv_maxclients`. |
| `unsupported_version` (400) | This bridge version is too old for Aptic. Update aptic_bridge. Snapshots stop until you do. |
| `rate_limited` (429) | Too many requests for this key. The bridge waits the time Aptic asks for (60 s if it doesn't say). |
| `tls` | The endpoint's certificate didn't verify. Check the machine's clock and any proxy or TLS interception. The key is never sent without a valid certificate. |
| `timeout`, `network`, 5xx | Aptic is unreachable. The bridge backs off (5 s, 10 s, 20 s … up to 5 minutes) and resumes on its own. |

**Snapshot answers**

| Code | Meaning and fix |
| --- | --- |
| `snapshot_invalid` | Aptic's final checks rejected the snapshot (duplicate key, missing reference or time order). The bridge runs `aptic validate` by itself and logs the result. Please report it with those lines: the bridge should never send such a snapshot. |
| `snapshot_too_large` | More than 50,000 rows. 0.1.0 can't split a snapshot, so tell us your row counts from `aptic validate`. |
| `snapshot_clock_invalid` | The snapshot time was too far off Aptic's clock. The bridge measures the offset again. Fix the machine's clock (NTP). |
| `snapshot_out_of_order` | Aptic already has a newer snapshot. Twice in a row means a wrong clock, or **two servers using the same key**. Give each server its own workspace and key. |
| `start_rate_limited`, `daily_snapshot_limit`, `upload_quota_exceeded` | A per-hour, per-day or concurrent-upload limit. The schedule waits, and nothing is lost. |
| `storage_quota_exceeded` | The workspace's snapshot storage is full. Snapshots stop until aptic_bridge restarts. Heartbeats continue. |
| `credential_rotated`, `upload_expired`, `upload_unavailable`, `upload_incomplete`, `chunk_gap` | The upload was interrupted. The bridge drops it or resumes it, and the next slot collects a new one. |
| `request_conflict` | The cached chunks didn't match what Aptic already had. The cache is deleted and the next slot starts over. Report it if it repeats. |
| `body_too_large` | A chunk was too large. The next snapshot uses chunks 25% smaller. Please report it. |
| `cache_missing`, `cache_write_failed` | The `cache/` folder inside the resource was deleted or isn't writable. The bridge writes chunk files there while uploading and deletes them afterwards. |
| `invalid_payload`, `invalid_manifest`, `invalid_chunk`, `unsupported_media_type` | A bug in aptic_bridge. Please report it with the log line. |

If the dashboard shows the server as offline, check `aptic status` first: it shows the last heartbeat, its code and when the next one is due.

## Updating and uninstalling

**Update:** stop the resource, replace the folder's contents with the new release (keep the folder name `aptic_bridge`), and start it. Your convars stay in `server.cfg`. An interrupted upload resumes if it's recent enough, and is dropped cleanly otherwise.

**Uninstall:** remove `ensure aptic_bridge` and the `aptic_` lines from `server.cfg`, delete the folder, and revoke the key in Aptic. The bridge leaves a few small values in FiveM's resource storage (instance id, schedule minute, upload state). They do nothing once the resource is gone. Data already sent to Aptic is deleted from the dashboard, not by the bridge.

## Development and tests

The tests need Node.js 22.13 or newer. They run the resource's real Lua under Lua 5.4 ([wasmoon](https://github.com/ceifa/wasmoon), the reference interpreter compiled to WebAssembly), with the FiveM natives stubbed and the scripts loaded in `fxmanifest.lua` order. `transport.js` runs as is.

```sh
npm ci
npm test            # unit, Lua, transport and source-rule tests
npm run release     # builds dist/aptic_bridge-<version>.zip
```

`npm test` includes:

- unit tests for every module, including the error policy, the chunker and resume;
- the collectors over fixture databases for Qbox and QBCore (`tests/fixtures/`);
- source rules: nothing prints except `server/log.lua`, nothing uses `PerformHttpRequest`, no SQL write statement anywhere in the shipped files, docs only show `set`;
- a contract-parity test that runs the collected rows through Aptic's own `contract.ts`. It looks for the Aptic repository next to this one, or at `APTIC_CONTRACT_TS`. Without it, the test is **skipped**: it's reported as skipped, not passed.

### Integration tests (need a local Aptic)

These run against a real Aptic: the web app's dev server and its local Supabase stack. Each needs a disposable workspace whose framework and inventory match the test, with a plan and a connection key. Environment variables point the tests at it:

| Variable | Meaning |
| --- | --- |
| `APTIC_IT_ENDPOINT` | Ingest URL, default `http://localhost:3300/api/ingest/v1` |
| `APTIC_IT_KEY_FILE` | A file holding the workspace's connection key (or `APTIC_IT_KEY`) |
| `APTIC_IT_FRAMEWORK` | `qbox` (with ox_inventory, the default) or `qbcore` (with qb-inventory) |
| `APTIC_IT_COPIES` | How many times the fixture database is repeated (default 150) |
| `APTIC_IT_PSQL` | Optional. A command that runs one SQL statement against Aptic's database, for example `docker exec supabase_db_Aptic psql -U postgres -d postgres -Atc`. Without it, the database checks are skipped and the output says so. |
| `APTIC_IT_SERVER_ID` | The workspace id (needed with `APTIC_IT_PSQL`) |

```sh
npm run test:integration:qbox      # or :qbcore, with that workspace's key and id
npm run test:integration:heartbeat # heartbeat and key rotation only
npm run test:integration:upload    # the upload engine with synthetic rows, incl. resume
```

`tests/integration/e2e.integration.mjs` runs the real collector over the fixture database, through the real upload engine and `transport.js`, into Aptic. It checks that:

- the heartbeat gets a 200;
- `aptic validate` counts the same rows as the upload;
- the snapshot is published and `data_snapshots` marks it complete;
- the normalized tables hold exactly the rows that were sent;
- Aptic's preparation and analysis jobs complete;
- no stored row in the workspace contains a license, account name, phone number or other identifier from the fixture, nor the salt or the key.

Creating and deleting the throwaway owner, workspace, plan and key needs access to the Aptic checkout and its local Supabase, so that setup script isn't part of this repository.

## License

MIT. See [LICENSE](LICENSE). Security reports: see [SECURITY.md](SECURITY.md).
