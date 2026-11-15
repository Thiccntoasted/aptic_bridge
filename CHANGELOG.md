# Changelog

## 0.1.0 (2026-11-15)

The first release. It uploads a server's economy to Aptic once an hour and keeps a heartbeat every minute. It has been tested against fixture databases and a local Aptic, not yet on a live game server (see [COMPATIBILITY.md](COMPATIBILITY.md)).

### Supported

- Qbox (`qbx_core`) + `ox_inventory`, and QBCore (`qb-core`) + `qb-inventory` 2.x. Both are detected along with their versions. Qbox + qb-inventory and QBCore + ox_inventory are recognised and reported as unsupported. They still send heartbeats but never upload snapshots.
- Server-only resource (`fx_version 'cerulean'`, Lua 5.4). It needs oxmysql. txAdmin is optional.

### Snapshots

- Collected collections: characters, balances, vehicles, and jobs and gangs, plus the online player count. Inventories (containers and item stacks) are not sent in this version.
- Characters: citizenid, `player_hash`, the charinfo name (or a pseudonym with `pseudonymize = true`), job and grade, gang, and `last_seen_at`. `created_at` and `playtime_minutes` come from txAdmin's player database when txAdmin runs the server, and are otherwise sent as unknown.
- Balances: every money type under its own code. Negative amounts are kept. Types can be renamed or skipped in `config.lua`.
- Vehicles: plate (trimmed and uppercased; on QBCore, duplicates keep the highest id), model, owner, garage, and state (garaged, out or impounded).
- Online players' live data overrides the saved row. Characters that are loaded but not yet saved are included.
- Reads are `SELECT` only, paged by key with a `LIMIT`, and spread across ticks. Every row is checked against a Lua port of the ingest contract, and bad rows are skipped and counted rather than failing the snapshot.

### Upload

- Snapshots are split into chunks of up to 200 rows and about 240 KiB, written to `cache/` as they close, then sent with start, chunk and finalize, at most one request a second.
- The state is saved in KVP, so a restart resumes an interrupted upload (asking Aptic which chunks it already has) or drops it cleanly.
- A snapshot runs every 60 minutes, at a random minute per server, with guards: one upload at a time, at most 3 starts an hour, and a stop at 90 published snapshots in 24 hours.
- Every error code in the ingest contract has its own handling: backoff with jitter, `retry_after`, resync before a final retry, smaller chunks after `body_too_large`, a stop on `unsupported_version` or full storage, and clock re-measurement.

### Heartbeat

- A heartbeat every 60 s ± 5 s. It reports the bridge, framework and inventory versions, `sv_maxclients`, a per-install `instance_id` and, once a salt is pinned, the salt fingerprint.
- 401 stops all traffic until the key changes. A key rotated from the live console is picked up at once. 422 `adapter_mismatch`, 403 and outdated versions retry every 10 minutes. 429 waits `retry_after`. Network errors and 5xx back off exponentially, up to 5 minutes.

### Privacy and security

- `player_hash` = HMAC-SHA256 keyed with the salt's 32 bytes, over `aptic.v1|` + the lowercased license. Raw licenses, Steam, Discord, FiveM, Xbox and Live ids, IPs, FiveM account names, phone numbers and metadata are never sent.
- The salt has to be pinned in `server.cfg` (`set aptic_salt`). Until it is, the bridge prints the line to add and doesn't upload snapshots.
- HTTPS goes through `server/transport.js` (Node `https`, certificates verified, no redirects), never `PerformHttpRequest`.
- Every log line is redacted: keys are cut to their prefix, the configured key and salt are replaced, and identifiers and IPs are masked.

### Console

- `aptic status`, `aptic salt`, `aptic upload now` and `aptic upload status`.
- `aptic validate [--verbose]` collects and checks a snapshot locally without uploading anything. It prints the counts, chunk size, and skipped and adjusted reasons with hints, and checks Aptic's finalize rules (duplicate keys, missing references, time order). `--verbose`, which works only on the server console, names the characters behind each reason. A `snapshot_invalid` answer from Aptic runs the same check automatically and logs the result.
- Players need the ACE `command.aptic` to run `aptic` in game.

### Development

- Lua 5.4 tests (wasmoon) over the real resource scripts, transport tests, source rules (only `log.lua` prints, no `PerformHttpRequest`, no SQL writes, docs show only `set`), and contract parity with Aptic's `contract.ts`, which is skipped when the Aptic repository isn't next to this one.
- Integration tests against a local Aptic: heartbeat and rotation, the upload engine with resume, and an end-to-end run of the real collector for each framework.
- `npm run release` builds `dist/aptic_bridge-<version>.zip`. CI runs the tests and the release build.
