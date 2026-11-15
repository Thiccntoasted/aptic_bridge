# Changelog

## 0.1.0 (unreleased)

The first version, which sends heartbeats only (milestone M1).

- Server-only resource (`fx_version 'cerulean'`, Lua 5.4).
- Configured with `set` convars: `aptic_api_key`, `aptic_salt` and `aptic_endpoint` (default `https://aptic.dev/api/ingest/v1`).
- Detects Qbox + ox_inventory and QBCore + qb-inventory, along with their versions. Qbox + qb-inventory and QBCore + ox_inventory are recognised, reported as unsupported, and still heartbeat.
- HTTPS goes through `server/transport.js` (Node `https`, certificates verified, timeouts, no redirects). It never uses `PerformHttpRequest`.
- A heartbeat every 60 s ± 5 s. It reports the agent, framework and inventory versions, a per-install `instance_id` and, once a salt is pinned, its `salt_fp`.
- How the bridge handles answers:
  - 401: stops until the key changes, and picks up a key rotated from the live console at once.
  - 422 `adapter_mismatch`: retries every 10 minutes, or immediately when the detected adapter changes.
  - 429: waits `retry_after` from the JSON body.
  - 403 and outdated versions: retry every 10 minutes.
  - Network errors and 5xx: exponential backoff, capped at 5 minutes.
- Without `aptic_salt`, the bridge generates a salt, prints the exact `set aptic_salt` line, and blocks snapshot uploads until the salt is pinned.
- `aptic status` and `aptic salt` console commands. Players need the ACE `command.aptic` to run them.
- Every log line is redacted: connection keys are cut to their 16-character prefix, configured secrets are replaced, and player identifiers and IPs are masked.
