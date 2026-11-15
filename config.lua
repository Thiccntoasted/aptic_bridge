-- aptic_bridge configuration: non-secret defaults only.
--
-- Secrets and per-server values are convars in server.cfg, set with `set`
-- (never `setr`, which sends the value to every player, or `sets`, which
-- publishes it in the server list):
--
--   set aptic_api_key "apt_ing_..."    connection key from Aptic, Settings -> Connection
--   set aptic_salt "<64 hex>"          hash salt; required before snapshots upload
--   set aptic_endpoint "https://..."   optional, defaults to default_endpoint below
--
-- Most owners never need to change anything in this file.

Aptic = Aptic or {}

Aptic.config = {
  default_endpoint = 'https://aptic.dev/api/ingest/v1',

  heartbeat = {
    interval_s = 60,        -- one heartbeat a minute; Aptic shows offline after 3 min
    jitter_s = 5,           -- +/- this much, so servers don't all send on the same second
    timeout_ms = 15000,     -- give up on one heartbeat request after 15 s
    backoff_base_s = 5,     -- network / 5xx retries: 5, 10, 20 ... seconds
    backoff_cap_s = 300,    -- ... capped at 5 minutes
    slow_retry_s = 600,     -- refused but not transient (adapter mismatch, locked, outdated): every 10 min
    config_retry_s = 30,    -- missing key, bad endpoint, no framework yet: look again every 30 s
    rate_limit_default_s = 60, -- 429 without a readable retry_after
    max_wait_s = 3600,      -- never trust a retry_after longer than an hour
  },

  -- How often the loop wakes to notice a rotated key or a newly started
  -- framework. Waking costs nothing measurable; requests follow the timings above.
  tick_ms = 1000,

  -- `aptic` console command. Players need this ACE to run it in game:
  --   add_ace group.admin command.aptic allow
  command = 'aptic',

  -- Character names (decision D7). false: send each character's RP name
  -- from charinfo. true: send "Character 1a2b3c4d" instead, a stable tag
  -- derived from the hash salt and the citizenid, the same every snapshot.
  pseudonymize = false,

  -- Snapshot collection. Reads are SELECT-only and paged.
  collector = {
    page_size = 250,        -- rows per query (keyset pagination)
    yield_ms = 2,           -- yield to the server after this much work in one tick
    max_rows = 50000,       -- Aptic's per-snapshot cap; a bigger snapshot is not sent
  },

  -- Money types (players.money keys). Every type is sent under its own
  -- lowercase code (cash, bank, crypto, and custom ones). Rename a type or
  -- leave one out here, for example:
  --   rename = { blackmoney = 'dirty' },
  --   skip = { casino_chips = true },
  currencies = {
    rename = {},
    skip = {},
  },

  -- created_at and playtime come from txAdmin's player database (decision
  -- D2), found automatically while txAdmin runs this server. Set players_db
  -- to the full path of playersDB.json only if it lives somewhere unusual.
  txadmin = {
    enabled = true,
    players_db = '',
  },
}
