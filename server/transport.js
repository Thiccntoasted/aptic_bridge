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

const api = {
  createTransport: createTransport,
  createCache: createCache,
  randomHex: randomHex,
  saltFingerprint: saltFingerprint,
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
