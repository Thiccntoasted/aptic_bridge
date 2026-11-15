# Security

## Reporting a problem

If you find a way aptic_bridge could leak a connection key, the hash salt or a player identifier, write to a game database, or send data it shouldn't, please report it **privately**. Use GitHub's private vulnerability reporting on this repository (**Security → Report a vulnerability**). Don't open a public issue, and leave the details out of public channels until a fix is released.

Include the aptic_bridge version, the framework and inventory with their versions, and what you saw. If you include console output, check it for anything you'd rather not share. The bridge redacts its own lines, but other resources don't.

Only the latest release gets security fixes.

## What the bridge guarantees

These rules are enforced in code and checked by the tests in `tests/`:

- **The connection key is never printed.** Every console line goes through `server/log.lua`. Keys are cut to their 16-character prefix (`apt_ing_` plus 8), and the configured key and salt are replaced outright wherever they appear. A test sends output through every scenario and searches it for the key.
- **The salt is never printed once it's pinned.** Before it's pinned, `aptic salt` (server console only) and the first start print the line to add. After that, only the 8-character fingerprint appears.
- **Player identifiers are masked in logs:** `license:`, `license2:`, `steam:`, `discord:`, `fivem:`, `xbl:`, `live:`, `ip:` and IPv4 addresses (except loopback).
- **Rows, request bodies and Aptic's error bodies are never logged.** Only error codes, counts and the collection or chunk index are. Character names appear only in `aptic validate --verbose`, which is limited to the server console. It shows names, never identifiers.
- **No raw identifier is sent to Aptic.** Licenses become `player_hash` = HMAC-SHA256 keyed with the salt, inside `transport.js`. Steam, Discord, FiveM, Xbox and Live ids, IPs, hardware ids, `players.name`, phone numbers and other `charinfo` and metadata fields are never sent. The end-to-end test scans every row Aptic stored for the fixture's identifiers.
- **Read-only database access.** Only `SELECT` queries, paged with a `LIMIT`, through `MySQL.query.await`. A test fails if any SQL write keyword appears in a shipped file.
- **TLS is verified.** HTTPS uses Node's `https` with certificate checks on and no redirects. `PerformHttpRequest`, which doesn't verify certificates, is never used, and a test enforces this. Plain `http://` is refused except for `localhost` with `set aptic_dev 1`.
- **Server-side only.** The manifest is `server_only` and has no client scripts. Configure it with `set`, never `setr` (which sends the value to every player) or `sets` (which publishes it).
