"use strict"
// aptic_bridge transport (decision D4): the only code that talks to the
// network. Lua builds requests and decides what to do with answers; this file
// sends them with Node's https module, which verifies TLS certificates
// (FiveM's PerformHttpRequest does not, and hides headers on errors).
//
// Rules this file keeps:
// - It reads the connection key from the aptic_api_key convar itself, right
//   before each request, so the key never travels through Lua tables and a
//   key rotated from the live console is used at once.
// - It never logs. Results carry status codes and allowlisted error codes,
//   never the key, the request body or raw server error text.
// - https only. Plain http is allowed for localhost alone, and only when
//   `set aptic_dev 1` is set, for testing against a local Aptic.
// - Redirects are not followed, so the key is never sent to another host.
//
// Written for the Node 16 runtime FXServer ships by default.
//
// The collectors (M2) also use this file for local work Lua can't do: HMAC
// player hashes from the pinned salt, and reading txAdmin's playersDB.json.
// See the second half of the file.

const https = require("https")
const http = require("http")
const crypto = require("crypto")

const KEY_RE = /^apt_ing_[A-Za-z0-9_-]{43}$/
const CODE_RE = /^[a-z][a-z0-9_]{0,63}$/
const NODE_CODE_RE = /^[A-Z][A-Z0-9_]{0,63}$/
const MAX_REQUEST_BYTES = 256 * 1024
const MAX_RESPONSE_BYTES = 1024 * 1024
const DEFAULT_TIMEOUT_MS = 15000
const MIN_TIMEOUT_MS = 1000
const MAX_TIMEOUT_MS = 120000
const LOCAL_HOSTS = ["localhost", "127.0.0.1", "[::1]", "::1"]

// Node error codes that mean the certificate or TLS handshake failed.
const TLS_CODES = [
  "CERT_HAS_EXPIRED",
  "CERT_NOT_YET_VALID",
  "CERT_REVOKED",
  "CERT_UNTRUSTED",
  "DEPTH_ZERO_SELF_SIGNED_CERT",
  "SELF_SIGNED_CERT_IN_CHAIN",
  "UNABLE_TO_GET_ISSUER_CERT",
  "UNABLE_TO_GET_ISSUER_CERT_LOCALLY",
  "UNABLE_TO_VERIFY_LEAF_SIGNATURE",
  "ERR_TLS_CERT_ALTNAME_INVALID",
  "HOSTNAME_MISMATCH",
]

function isTlsError(code) {
  return (
    typeof code === "string" &&
    (TLS_CODES.indexOf(code) !== -1 ||
      code.indexOf("ERR_SSL_") === 0 ||
      code.indexOf("ERR_TLS_") === 0)
  )
}

/** Integer seconds in 1..86400, or null. */
function seconds(value) {
  const n = typeof value === "string" && value.trim() !== "" ? Number(value) : value
  return typeof n === "number" && Number.isInteger(n) && n > 0 && n <= 86400
    ? n
    : null
}

/** A copy of a parsed answer with every occurrence of `secret` removed. */
function scrub(value, secret, depth) {
  if (depth > 20) return null
  if (typeof value === "string") return value.split(secret).join("[redacted]")
  if (Array.isArray(value)) return value.map((v) => scrub(v, secret, depth + 1))
  if (value && typeof value === "object") {
    const out = {}
    Object.keys(value).forEach(function (k) {
      out[scrub(k, secret, depth + 1)] = scrub(value[k], secret, depth + 1)
    })
    return out
  }
  return value
}

/**
 * Builds the transport. `deps.getConvar(name, fallback)` is FiveM's GetConvar;
 * tests pass a stub. `deps.tls` exists for tests only (a private CA); the
 * FiveM wiring at the bottom never sets it.
 */
function createTransport(deps) {
  const getConvar = deps.getConvar
  const userAgent = deps.userAgent || "aptic_bridge"
  const tls = deps.tls || {}

  function checkEndpoint(raw) {
    let url
    try {
      url = new URL(String(raw))
    } catch (e) {
      return { error: "invalid_endpoint" }
    }
    if (url.username || url.password || url.hash)
      return { error: "invalid_endpoint" }
    if (url.protocol === "https:") return { url: url }
    if (
      url.protocol === "http:" &&
      LOCAL_HOSTS.indexOf(url.hostname) !== -1 &&
      String(getConvar("aptic_dev", "0")).trim() === "1"
    )
      return { url: url }
    return { error: "insecure_endpoint" }
  }

  /**
   * POST one JSON body. `request` is { endpoint, payload | body, timeout_ms }.
   * `done(result)` is called exactly once with:
   *   ok              true for a 2xx answer
   *   status          HTTP status, 0 when no answer arrived
   *   code            the answer's `error` code when it is a safe code
   *   json            the parsed answer (null when it was not JSON)
   *   retry_after_body    `retry_after` from the JSON body (C6), or null
   *   retry_after_header  the Retry-After header in seconds, or null
   *   transport_error     why no answer arrived: no_key, invalid_key,
   *                       invalid_endpoint, insecure_endpoint, invalid_request,
   *                       body_too_large, timeout, tls, network,
   *                       response_too_large
   *   detail          a Node error code such as ECONNREFUSED, when known
   *   elapsed_ms
   */
  function post(request, done) {
    const started = Date.now()
    let finished = false
    const finish = function (fields) {
      if (finished) return
      finished = true
      const result = {
        ok: false,
        status: 0,
        code: null,
        json: null,
        retry_after_body: null,
        retry_after_header: null,
        transport_error: null,
        detail: null,
        elapsed_ms: Date.now() - started,
      }
      Object.keys(fields).forEach(function (k) {
        result[k] = fields[k]
      })
      try {
        done(result)
      } catch (e) {
        // The caller's callback failed; nothing safe to report from here.
      }
    }

    try {
      if (!request || typeof request !== "object")
        return finish({ transport_error: "invalid_request" })

      const key = String(getConvar("aptic_api_key", "") || "").trim()
      if (key === "") return finish({ transport_error: "no_key" })
      if (!KEY_RE.test(key)) return finish({ transport_error: "invalid_key" })

      const target = checkEndpoint(request.endpoint)
      if (target.error) return finish({ transport_error: target.error })

      let body
      if (typeof request.body === "string") body = request.body
      else if (request.payload && typeof request.payload === "object")
        body = JSON.stringify(request.payload)
      else return finish({ transport_error: "invalid_request" })
      const bytes = Buffer.from(body, "utf8")
      if (bytes.length > MAX_REQUEST_BYTES)
        return finish({ transport_error: "body_too_large" })

      let timeout = Number(request.timeout_ms)
      if (!Number.isFinite(timeout)) timeout = DEFAULT_TIMEOUT_MS
      timeout = Math.min(MAX_TIMEOUT_MS, Math.max(MIN_TIMEOUT_MS, timeout))

      const url = target.url
      const secure = url.protocol === "https:"
      const lib = secure ? deps.https || https : deps.http || http
      const options = {
        method: "POST",
        protocol: url.protocol,
        hostname: url.hostname.replace(/^\[|\]$/g, ""),
        port: url.port || (secure ? 443 : 80),
        path: url.pathname + url.search,
        headers: {
          Authorization: "Bearer " + key,
          "Content-Type": "application/json",
          Accept: "application/json",
          "Content-Length": bytes.length,
          "User-Agent": userAgent,
        },
        // A fresh connection per request: no stale keep-alive sockets
        // between heartbeats a minute apart.
        agent: new lib.Agent({ keepAlive: false }),
      }
      if (secure) {
        options.rejectUnauthorized = true
        options.minVersion = "TLSv1.2"
        options.servername = options.hostname
        if (tls.ca) options.ca = tls.ca
      }

      let timedOut = false
      const req = lib.request(options, function (res) {
        const chunks = []
        let size = 0
        res.on("data", function (chunk) {
          size += chunk.length
          if (size > MAX_RESPONSE_BYTES) {
            res.destroy()
            req.destroy()
            finish({
              status: res.statusCode || 0,
              transport_error: "response_too_large",
            })
            return
          }
          chunks.push(chunk)
        })
        res.on("error", function () {
          finish({ status: res.statusCode || 0, transport_error: "network" })
        })
        res.on("end", function () {
          const status = res.statusCode || 0
          let json = null
          try {
            const parsed = JSON.parse(Buffer.concat(chunks).toString("utf8"))
            // A broken or hostile server echoing the key must not get it
            // into anything Lua could print.
            if (parsed && typeof parsed === "object" && !Array.isArray(parsed))
              json = scrub(parsed, key, 0)
          } catch (e) {
            json = null
          }
          const code =
            json && typeof json.error === "string" && CODE_RE.test(json.error)
              ? json.error
              : null
          finish({
            ok: status >= 200 && status < 300,
            status: status,
            code: code,
            json: json,
            retry_after_body: json ? seconds(json.retry_after) : null,
            retry_after_header: seconds(res.headers["retry-after"]),
          })
        })
      })

      const timer = setTimeout(function () {
        timedOut = true
        req.destroy()
        finish({ transport_error: "timeout" })
      }, timeout)
      req.setTimeout(timeout, function () {
        timedOut = true
        req.destroy()
        finish({ transport_error: "timeout" })
      })
      req.on("close", function () {
        clearTimeout(timer)
      })
      req.on("error", function (err) {
        clearTimeout(timer)
        if (timedOut) return finish({ transport_error: "timeout" })
        const code = err && typeof err.code === "string" ? err.code : null
        finish({
          transport_error: isTlsError(code) ? "tls" : "network",
          detail: code && NODE_CODE_RE.test(code) ? code : null,
        })
      })
      req.end(bytes)
    } catch (e) {
      finish({ transport_error: "network" })
    }
  }

  return { post: post, checkEndpoint: checkEndpoint }
}

/** `n` random bytes as lowercase hex (1..64 bytes). */
function randomHex(n) {
  const count = Number(n)
  if (!Number.isInteger(count) || count < 1 || count > 64)
    throw new Error("randomHex: byte count must be 1..64")
  return crypto.randomBytes(count).toString("hex")
}

/**
 * The salt fingerprint the ingest contract records (C9): the first 8 hex of
 * SHA-256("aptic-fp" || salt), where salt is the 64-character lowercase hex
 * string pinned in server.cfg. Owners can reproduce it with
 * `printf 'aptic-fp%s' "<salt>" | sha256sum`.
 */
function saltFingerprint(salt) {
  const value = String(salt || "")
  if (!/^[0-9a-f]{64}$/.test(value))
    throw new Error("saltFingerprint: salt must be 64 lowercase hex")
  return crypto
    .createHash("sha256")
    .update("aptic-fp" + value, "utf8")
    .digest("hex")
    .slice(0, 8)
}

// ---------------------------------------------------------------------------
// Collectors (M2): player identity hashing and txAdmin's playersDB.json.
// Both read local data only; neither touches the network or logs.
// ---------------------------------------------------------------------------

const SALT_RE = /^[0-9a-f]{64}$/
const MAX_ID_LENGTH = 256
const MAX_BATCH = 5000

/**
 * HMAC-SHA256 as lowercase hex. The key is the salt's 32 bytes (the pinned
 * value is 64 hex characters), so owners can reproduce a player_hash with
 * `printf 'aptic.v1|license:...' | openssl dgst -sha256 -mac HMAC -macopt hexkey:<salt>`.
 */
function hmacHex(saltHex, message) {
  const salt = String(saltHex || "")
  if (!SALT_RE.test(salt)) throw new Error("hmacHex: salt must be 64 lowercase hex")
  return crypto
    .createHmac("sha256", Buffer.from(salt, "hex"))
    .update(String(message), "utf8")
    .digest("hex")
}

/** Lua sequences arrive as arrays (FXServer) or as {1: .., 2: ..} objects. */
function listOf(value) {
  if (Array.isArray(value)) return value
  if (value && typeof value === "object") return Object.values(value)
  return []
}

/**
 * Hashing that reads the pinned salt from the aptic_salt convar itself, so
 * the salt never travels through Lua call arguments and nothing but the
 * pinned value can be used. Every answer carries the salt fingerprint, so
 * the caller can tell if the salt changed in the middle of a run.
 */
function createIdentity(deps) {
  const getConvar = deps.getConvar

  function pinnedSalt() {
    const salt = String(getConvar("aptic_salt", "") || "")
      .trim()
      .toLowerCase()
    return SALT_RE.test(salt) ? salt : null
  }

  function many(values, prefix, field, transform) {
    const salt = pinnedSalt()
    if (!salt) return { error: "salt_not_pinned" }
    const list = listOf(values)
    if (list.length > MAX_BATCH) return { error: "batch_too_large" }
    const out = {}
    list.forEach(function (value) {
      if (typeof value !== "string" || value.length < 1 || value.length > MAX_ID_LENGTH) return
      out[value] = transform(hmacHex(salt, prefix + value.toLowerCase()))
    })
    const result = { salt_fp: saltFingerprint(salt) }
    result[field] = out
    return result
  }

  return {
    /**
     * player_hash for each license string:
     * hex(HMAC-SHA256(salt, "aptic.v1|" + lower(license))).
     * Returns { salt_fp, hashes: { [license]: hash } } or { error }.
     */
    playerHashes: function (licenses) {
      return many(licenses, "aptic.v1|", "hashes", function (h) {
        return h
      })
    },
    /**
     * A stable 8-hex tag per character for pseudonymized names (D7):
     * the first 8 hex of HMAC-SHA256(salt, "aptic.v1.name|" + lower(char_id)).
     * Returns { salt_fp, tags: { [char_id]: tag } } or { error }.
     */
    pseudonymTags: function (charIds) {
      return many(charIds, "aptic.v1.name|", "tags", function (h) {
        return h.slice(0, 8)
      })
    },
  }
}

// Snapshot chunk files (M3). FiveM's SaveResourceFile can't create folders
// or delete anything, so the chunk store keeps its files here instead, under
// <resource>/cache/ (gitignored). Paths are one or two names joined by "/"
// ("<snapshot_id>" or "<snapshot_id>/<file>"); nothing else is reachable.
// File contents never leave this function except back to Lua.
const CACHE_NAME_RE = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/
const MAX_CACHE_FILE_BYTES = 1024 * 1024

/**
 * The cache under `root` (an absolute path, or a function returning one, so
 * the folder is looked up only when first used). Every method returns a
 * plain value and never throws:
 *   write(path, text)  bytes written, or false. Written to a temporary file
 *                      and renamed, so a crash never leaves half a file.
 *   read(path)         the text, or null when missing or unreadable
 *   remove(path)       true when nothing is left at path (a folder goes
 *                      with everything in it)
 *   list()             the names directly under cache/
 */
function createCache(root) {
  const fs = require("fs")
  const path = require("path")
  const base = function () {
    const value = typeof root === "function" ? root() : root
    return typeof value === "string" && value !== "" ? value : null
  }
  function resolve(rel) {
    const dir = base()
    if (!dir || typeof rel !== "string") return null
    const parts = rel.split("/")
    if (parts.length < 1 || parts.length > 2) return null
    for (let i = 0; i < parts.length; i++)
      if (!CACHE_NAME_RE.test(parts[i]) || parts[i].indexOf("..") !== -1)
        return null
    return path.join.apply(path, [dir].concat(parts))
  }
  return {
    write: function (rel, text) {
      try {
        const file = resolve(rel)
        if (!file || typeof text !== "string") return false
        const bytes = Buffer.from(text, "utf8")
        if (bytes.length > MAX_CACHE_FILE_BYTES) return false
        fs.mkdirSync(path.dirname(file), { recursive: true })
        const tmp = file + ".tmp"
        fs.writeFileSync(tmp, bytes)
        fs.renameSync(tmp, file)
        return bytes.length
      } catch (e) {
        return false
      }
    },
    read: function (rel) {
      try {
        const file = resolve(rel)
        if (!file) return null
        return fs.readFileSync(file).toString("utf8")
      } catch (e) {
        return null
      }
    },
    remove: function (rel) {
      try {
        const file = resolve(rel)
        if (!file) return false
        fs.rmSync(file, { recursive: true, force: true })
        return true
      } catch (e) {
        return false
      }
    },
    list: function () {
      try {
        const dir = base()
        if (!dir || !fs.existsSync(dir)) return []
        return fs.readdirSync(dir).filter(function (n) {
          return CACHE_NAME_RE.test(n)
        })
      } catch (e) {
        return []
      }
    },
  }
}

/**
 * txAdmin's player database (decision D2), read from disk.
 *
 * Checked against txAdmin's source (github.com/tabarra/txAdmin, master @
 * 1db5eb0d, 23 Oct 2026):
 * - File: `${profilePath}/data/playersDB.json`, where profilePath is
 *   `<dataPath>/<profile>` (core/modules/Database/instance.ts).
 * - dataPath (core/globalData.ts): the TXHOST_DATA_PATH environment
 *   variable, else the deprecated `txDataPath` convar (relative values are
 *   resolved with path.resolve, core/boot/getNativeVars.ts), else
 *   `<citizen_root>/../txData` on Windows and `<citizen_root>/../../../txData`
 *   elsewhere. profile: the deprecated `serverProfile` convar with
 *   [^a-z0-9._-] removed, else "default".
 * - Shape (core/modules/Database/databaseTypes.ts): { version, players: [
 *   { license, ids, hwids, displayName, pureName, playTime,
 *   tsLastConnection, tsJoined, ... } ], actions, ... }.
 * - playTime is in MINUTES: ServerPlayer#minuteCron adds 1 every 60_000 ms
 *   (core/lib/player/playerClasses.ts).
 * - tsJoined is the first join, in unix SECONDS: it is set from
 *   tsConnected = now(), and now() is Math.round(Date.now() / 1000)
 *   (core/lib/misc.ts).
 * - license is the lowercased hex value without the "license:" prefix
 *   (parsePlayerIds, core/lib/player/idUtils.ts); `ids` holds the full
 *   prefixed identifiers, including license2:.
 * - txAdmin writes the file through lowdb's TextFile (steno: write a temp
 *   file, then rename), so a read sees a whole old or whole new file. A read
 *   that still fails (a Windows rename race) counts as unreadable for that
 *   run: values are sent as null, never guessed.
 *
 * Only playtime and first-join time leave this module. Display names, hwids,
 * other identifiers, notes and actions are never returned.
 */
function createTxAdmin(deps) {
  const fs = deps.fs
  const path = deps.path
  const getConvar = deps.getConvar
  const env = deps.env || {}
  const platform = deps.platform || "linux"
  let cache = null

  function convar(name) {
    const v = String(getConvar(name, "") || "").trim()
    return v === "" ? null : v
  }

  /** Where the file should be: { file, source } or { error }. */
  function locate(override) {
    if (typeof override === "string" && override.trim() !== "")
      return { file: path.resolve(override.trim()), source: "config" }
    let dataPath
    let source
    if (typeof env.TXHOST_DATA_PATH === "string" && env.TXHOST_DATA_PATH.trim() !== "") {
      dataPath = env.TXHOST_DATA_PATH.trim()
      source = "env"
    } else if (convar("txDataPath")) {
      dataPath = path.resolve(convar("txDataPath"))
      source = "convar"
    } else if (convar("citizen_root")) {
      dataPath = path.join(
        convar("citizen_root"),
        platform === "win32" ? ".." : "../../../",
        "txData"
      )
      source = "default"
    } else {
      return { error: "no_path" }
    }
    const profile = (convar("serverProfile") || "").replace(/[^a-z0-9._-]/gi, "") || "default"
    return { file: path.join(dataPath, profile, "data", "playersDB.json"), source: source }
  }

  function entryOf(p) {
    const playtime =
      Number.isInteger(p.playTime) && p.playTime >= 0 && p.playTime <= 2147483647
        ? p.playTime
        : null
    const joined =
      typeof p.tsJoined === "number" && Number.isFinite(p.tsJoined) && p.tsJoined > 0
        ? Math.floor(p.tsJoined)
        : null
    return { playtime_minutes: playtime, joined_ts: joined }
  }

  function buildIndex(players) {
    const index = new Map()
    const add = function (key, entry) {
      if (!index.has(key)) index.set(key, entry)
      else if (index.get(key) !== entry) index.set(key, null) // two players claim one id: unknown
    }
    players.forEach(function (p) {
      if (!p || typeof p !== "object") return
      const entry = entryOf(p)
      if (typeof p.license === "string" && p.license.trim() !== "")
        add("license:" + p.license.trim().toLowerCase(), entry)
      listOf(p.ids).forEach(function (id) {
        if (typeof id !== "string") return
        const lower = id.trim().toLowerCase()
        if (lower.indexOf("license:") === 0 || lower.indexOf("license2:") === 0) add(lower, entry)
      })
    })
    return index
  }

  /**
   * Read (or reuse) the file. Returns { state, source, players }, state one
   * of ok | absent | unreadable | invalid. Never the path or any content.
   */
  function load(override) {
    const where = locate(override)
    if (where.error) {
      cache = null
      return { state: "absent", players: 0 }
    }
    let stat
    try {
      stat = fs.statSync(where.file)
    } catch (e) {
      cache = null
      const missing = e && (e.code === "ENOENT" || e.code === "ENOTDIR")
      return { state: missing ? "absent" : "unreadable", source: where.source, players: 0 }
    }
    if (
      cache &&
      cache.file === where.file &&
      cache.mtimeMs === stat.mtimeMs &&
      cache.size === stat.size
    )
      return { state: "ok", source: where.source, players: cache.players }
    let parsed
    try {
      parsed = JSON.parse(fs.readFileSync(where.file, "utf8"))
    } catch (e) {
      cache = null
      return { state: "unreadable", source: where.source, players: 0 }
    }
    if (!parsed || typeof parsed !== "object" || !Array.isArray(parsed.players)) {
      cache = null
      return { state: "invalid", source: where.source, players: 0 }
    }
    cache = {
      file: where.file,
      mtimeMs: stat.mtimeMs,
      size: stat.size,
      players: parsed.players.length,
      index: buildIndex(parsed.players),
    }
    return { state: "ok", source: where.source, players: cache.players }
  }

  /**
   * Values for the given license strings as the game DB stores them
   * ("license:<hex>", "license2:<hex>", or bare hex). Returns
   * { [license]: { playtime_minutes?, joined_ts? } } for the ones txAdmin
   * knows; a field txAdmin has no valid value for is left out.
   */
  function lookup(licenses) {
    const out = {}
    if (!cache) return out
    const list = listOf(licenses)
    if (list.length > MAX_BATCH) return out
    list.forEach(function (value) {
      if (typeof value !== "string" || value.length > MAX_ID_LENGTH) return
      const lower = value.trim().toLowerCase()
      const key = lower.indexOf(":") === -1 ? "license:" + lower : lower
      const entry = cache.index.get(key)
      if (!entry) return
      // Unknown fields are left out rather than null: Lua has no null.
      const found = {}
      if (entry.playtime_minutes !== null) found.playtime_minutes = entry.playtime_minutes
      if (entry.joined_ts !== null) found.joined_ts = entry.joined_ts
      out[value] = found
    })
    return out
  }

  function forget() {
    cache = null
  }

  return { locate: locate, load: load, lookup: lookup, forget: forget }
}

const api = {
  createTransport: createTransport,
  createCache: createCache,
  randomHex: randomHex,
  saltFingerprint: saltFingerprint,
  hmacHex: hmacHex,
  createIdentity: createIdentity,
  createTxAdmin: createTxAdmin,
  KEY_RE: KEY_RE,
}

// FiveM: register the exports Lua calls through
// exports[GetCurrentResourceName()]. Checked through globalThis because a
// CommonJS wrapper would shadow the global `exports` function with an object.
if (
  typeof globalThis.exports === "function" &&
  typeof globalThis.GetConvar === "function"
) {
  const resource = globalThis.GetCurrentResourceName()
  const version =
    globalThis.GetResourceMetadata(resource, "version", 0) || "0.0.0"
  const transport = createTransport({
    getConvar: function (name, fallback) {
      return globalThis.GetConvar(name, fallback)
    },
    userAgent: "aptic_bridge/" + version,
  })
  // Lua passes a callback; Node calls it once the answer (or failure) is in.
  globalThis.exports("httpPost", function (request, cb) {
    transport.post(request, function (result) {
      if (typeof cb === "function") cb(result)
    })
  })
  globalThis.exports("randomHex", randomHex)
  globalThis.exports("saltFingerprint", saltFingerprint)

  // Collectors (M2).
  const getConvar = function (name, fallback) {
    return globalThis.GetConvar(name, fallback)
  }
  const identity = createIdentity({ getConvar: getConvar })
  globalThis.exports("playerHashes", identity.playerHashes)
  globalThis.exports("pseudonymTags", identity.pseudonymTags)
  const proc = require("process")
  const txadmin = createTxAdmin({
    fs: require("fs"),
    path: require("path"),
    getConvar: getConvar,
    env: proc.env,
    platform: proc.platform,
  })
  globalThis.exports("txadminLoad", txadmin.load)
  globalThis.exports("txadminLookup", txadmin.lookup)
  const cache = createCache(function () {
    if (typeof globalThis.GetResourcePath !== "function") return null
    const dir = globalThis.GetResourcePath(resource)
    return dir ? require("path").join(dir, "cache") : null
  })
  globalThis.exports("cacheWrite", cache.write)
  globalThis.exports("cacheRead", cache.read)
  globalThis.exports("cacheRemove", cache.remove)
  globalThis.exports("cacheList", cache.list)
}

if (typeof module === "object" && module && module.exports) module.exports = api
