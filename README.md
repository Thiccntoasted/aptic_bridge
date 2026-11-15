# aptic_bridge

The FiveM server resource that connects a roleplay server to [Aptic](https://aptic.dev). It reads the server's economy (characters, balances, vehicles, jobs) and uploads normalized snapshots to Aptic's ingest API.

**This version (0.1.0) only sends a heartbeat.** The dashboard shows the server as online, along with its framework and inventory versions. Snapshot collection and upload come in later versions.

- Server-side only. Nothing runs on players' machines.
- HTTPS with verified TLS certificates. Requests go through a small Node.js file (`server/transport.js`), not FiveM's `PerformHttpRequest`, which doesn't check certificates.
- The connection key never appears in the console or in logs. You only ever see its 16-character prefix, the same one the dashboard shows.

## Supported servers

| Framework | Inventory | Status |
| --- | --- | --- |
| Qbox (`qbx_core`) | `ox_inventory` | Supported (first adapter) |
| QBCore (`qb-core`) | `qb-inventory` | Supported (second adapter) |
| Qbox | `qb-inventory` | Not supported: Qbox requires ox_inventory |
| QBCore | `ox_inventory` (2.41 or older) | Only on request |

Unsupported combinations still send heartbeats, so the dashboard can show the server, but they will never upload snapshots.

## Install

1. **Get the files.** Put this folder in your server's `resources` directory, for example `resources/[aptic]/aptic_bridge`. The folder must be named `aptic_bridge`, because FiveM stores the resource's saved state (its instance id) under that name.
2. **Get your connection key.** In Aptic, open **Settings → Connection** and create a connection key. Aptic shows it only once.
3. **Add the lines from the Connection page to `server.cfg`**, after your framework and inventory:

   ```cfg
   # aptic_bridge: server-only. Use `set`, never `setr` or `sets`.
   set aptic_api_key "apt_ing_..."
   set aptic_salt "<64 hex characters>"
   ensure aptic_bridge
   ```

   Use `set` only. `setr` sends the value to every player who joins, and `sets` publishes it in the server list. Either would leak your key. The resource can't tell which one you used.

4. **Restart the server**, or run `ensure aptic_bridge` in the live console.

On start, the console prints what was found, then the first heartbeat result:

```
[aptic] aptic_bridge 0.1.0 starting. Framework/inventory: qbox 1.24.1 + ox_inventory 2.44.1.
[aptic] heartbeat ok: qbox 1.24.1 + ox_inventory 2.44.1, key apt_ing_xxxxxxxx…, endpoint aptic.dev.
```

The dashboard shows the server as online within about a minute.

### The hash salt

The salt protects player identity. Aptic never receives raw license identifiers, only salted hashes of them. The salt has to stay the same forever: if it changes, every player looks new to Aptic.

If `aptic_salt` isn't set, the bridge generates a salt and prints the exact line to add:

```
[aptic] warn: Add this line to server.cfg, keep a backup of it, and restart:
[aptic] warn:   set aptic_salt "3f9c…"
```

Add that line and keep a backup of it. Until a salt is pinned, the bridge sends heartbeats but won't upload snapshots. To print the line again, run `aptic salt` in the server console. Once the salt is pinned, the bridge never prints it again. Only its 8-character fingerprint appears, in `aptic status` and on the dashboard.

## Configuration

These convars go in `server.cfg`. Always use `set`.

| Convar | Required | Meaning |
| --- | --- | --- |
| `aptic_api_key` | yes | The connection key from Settings → Connection (`apt_ing_` followed by 43 characters). |
| `aptic_salt` | yes, before snapshots | 64 hex characters. See the hash salt section above. |
| `aptic_endpoint` | no | Ingest URL. Defaults to `https://aptic.dev/api/ingest/v1`. Must be `https://`. |
| `aptic_dev` | no | `1` allows `http://localhost` endpoints, for testing against a local Aptic. |
| `aptic_debug` | no | `1` prints extra detail, such as each retry. Keys stay redacted. |

Timings and other non-secret defaults are in `config.lua`. You shouldn't need to change them.

### Rotating the key

1. Create a new key in Aptic. The old key stops working immediately.
2. Paste the new key into the live console (txAdmin works): `set aptic_api_key "apt_ing_..."`. The bridge picks it up within a second and sends a heartbeat. You don't need to restart.
3. Put the new key in `server.cfg` too, so it's still there after the next restart.

If Aptic refuses the key (rotated, revoked or archived workspace), the bridge stops sending anything until the key changes.

## Console command

`aptic status` shows the endpoint, the last heartbeat result, the detected framework and inventory, whether the salt is pinned and the instance id. It never shows the key or the salt.

```
aptic status
aptic salt      # console only: prints the salt line to add, while no salt is pinned
```

The command works in the server console and the txAdmin live console. To let players run it in game, grant the ACE:

```cfg
add_ace group.admin command.aptic allow
```

## What the bridge does when Aptic says no

| Answer | What happens |
| --- | --- |
| 401 `invalid_credential` | Stops sending until `aptic_api_key` changes |
| 422 `adapter_mismatch` | The workspace in Aptic is set to a different framework or inventory. Retries every 10 minutes, or immediately if the detected framework or inventory changes |
| 429 | Waits for the `retry_after` in the answer, or 60 seconds |
| 403 `workspace_locked` / `plan_limit_exceeded` | Retries every 10 minutes |
| 400 `unsupported_version` | Asks you to update aptic_bridge, every 10 minutes |
| 5xx, timeout, network, TLS | Backs off 5, 10, 20 … up to 300 seconds, with jitter |

## Development

Tests run with Node 22 or newer. The Lua tests run the resource's real Lua under Lua 5.4 ([wasmoon](https://github.com/ceifa/wasmoon), the reference interpreter compiled to WebAssembly), with FiveM natives stubbed. They load the scripts in the order `fxmanifest.lua` lists them.

```sh
npm install
npm test                 # transport (JS) and Lua tests
```

The integration test sends real heartbeats through the same Lua logic and JS transport to a running Aptic:

```sh
APTIC_IT_KEY_FILE=/path/to/key.txt npm run test:integration
```

See `tests/integration/heartbeat.integration.mjs` for the environment variables it reads.

`node_modules/`, `tests/`, `package.json` and the lock file are for development only. A release zip needs just `fxmanifest.lua`, `config.lua` and `server/`.
