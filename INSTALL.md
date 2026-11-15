# Installing aptic_bridge

About ten minutes, one restart. You need access to the server's files, `server.cfg` and the server console (txAdmin's live console works).

**Before you start:** the server runs **Qbox + ox_inventory** or **QBCore + qb-inventory**, and **oxmysql**. Your Aptic workspace's framework and inventory (in its settings) must match the server.

## 1. Get a connection key

In Aptic, open **Settings → Connection** and create a connection key. It starts with `apt_ing_`. Copy it now: Aptic shows it only once.

## 2. Put the resource on the server

Download `aptic_bridge-<version>.zip` and extract it into your `resources` folder. You should end up with:

```
resources/[aptic]/aptic_bridge/fxmanifest.lua
resources/[aptic]/aptic_bridge/server/...
```

Keep the folder name `aptic_bridge`.

## 3. Edit server.cfg

Add these lines **after** oxmysql, your framework and your inventory:

```cfg
# aptic_bridge: server-only. Use `set`, never `setr` or `sets`.
set aptic_api_key "apt_ing_..."
ensure aptic_bridge
```

Use `set` only. `setr` would send your key to every player, and `sets` would publish it in the server list.

## 4. Start it and pin the salt

Run `ensure aptic_bridge` in the console, or restart the server. The first time, it prints:

```
[aptic] warn: Add this line to server.cfg, keep a backup of it, and restart:
[aptic] warn:   set aptic_salt "…64 characters…"
```

Copy that `set aptic_salt` line into `server.cfg` next to the key, **save a copy of it somewhere safe**, and restart. The salt must never change: if it's lost, every player looks new to Aptic. You can print the line again with `aptic salt` until it's pinned.

## 5. Check it works

In the console:

```
aptic status
```

You should see `last heartbeat  ok, HTTP 200`, your framework and inventory, and `salt pinned  yes`. The dashboard shows the server as online within a minute.

Then check what would be sent, without sending anything:

```
aptic validate
```

It should end with `result  ok: Aptic would accept this snapshot`. Skipped rows are listed with a reason. Add `--verbose` to see which characters they belong to.

The first snapshot uploads within the hour. To send one now:

```
aptic upload now
aptic upload status
```

## Optional

- **Let staff run `aptic` in game:** `add_ace group.admin command.aptic allow`.
- **Send pseudonyms instead of character names:** set `pseudonymize = true` in `config.lua`.
- **txAdmin:** if txAdmin runs the server, character creation dates and playtime are filled in automatically. Nothing to set up.

## Changing the key later

Create a new key in Aptic, paste `set aptic_api_key "apt_ing_..."` into the live console (no restart needed), and put the new key in `server.cfg`.

## Something's wrong?

Run `aptic status` and look up the code in the README's [troubleshooting section](README.md#troubleshooting).
