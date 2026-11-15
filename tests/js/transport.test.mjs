// server/transport.js under plain Node: real sockets against local test
// servers, FiveM's GetConvar stubbed.

import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import { createHash } from "node:crypto"
import { mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs"
import http from "node:http"
import https from "node:https"
import { createRequire } from "node:module"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { after, before, describe, test } from "node:test"
import vm from "node:vm"

import { ROOT } from "../support/fivem.mjs"

const require = createRequire(import.meta.url)
const transportJs = require("../../server/transport.js")

const KEY = "apt_ing_TESTkeyAAAAbbbbCCCCddddEEEEffffGGGGhhhh1234"

function convars(values) {
  return (name, fallback) => (name in values ? values[name] : fallback)
}

function make(values = {}, extra = {}) {
  return transportJs.createTransport({
    getConvar: convars({ aptic_api_key: KEY, aptic_dev: "1", ...values }),
    userAgent: "aptic_bridge/0.1.0",
    ...extra,
  })
}

const post = (transport, request) =>
  new Promise((resolve) => transport.post(request, resolve))

/** A local HTTP server; `handler(req, body, res)` answers. */
async function serve(handler, { tls } = {}) {
  const requests = []
  const onRequest = (req, res) => {
    const chunks = []
    req.on("data", (c) => chunks.push(c))
    req.on("end", () => {
      const body = Buffer.concat(chunks).toString("utf8")
      requests.push({ method: req.method, url: req.url, headers: req.headers, body })
      handler(req, body, res)
    })
  }
  const server = tls ? https.createServer(tls, onRequest) : http.createServer(onRequest)
  await new Promise((r) => server.listen(0, "127.0.0.1", r))
  const { port } = server.address()
  return {
    url: `${tls ? "https" : "http"}://${tls ? "localhost" : "127.0.0.1"}:${port}/api/ingest/v1`,
    requests,
    close: () =>
      new Promise((r) => {
        server.closeAllConnections?.()
        server.close(r)
      }),
  }
}

const json = (res, status, body, headers = {}) => {
  res.writeHead(status, { "Content-Type": "application/json", ...headers })
  res.end(JSON.stringify(body))
}

const HEARTBEAT = { version: 1, operation: "heartbeat", framework: "qbox" }

describe("http requests", () => {
  let server
  before(async () => {
    server = await serve((req, body, res) => {
      const route = JSON.parse(body).route ?? "ok"
      if (route === "ok") return json(res, 200, { ok: true, server_time: "2026-11-15T12:00:00Z" })
      if (route === "401") return json(res, 401, { error: "invalid_credential" })
      if (route === "422") return json(res, 422, { error: "adapter_mismatch" })
      if (route === "429")
        return json(res, 429, { error: "rate_limited", retry_after: 17 }, { "Retry-After": "17" })
      if (route === "429-null")
        return json(res, 429, { error: "start_rate_limited", retry_after: null }, { "Retry-After": "60" })
      if (route === "echo-key")
        return json(res, 400, { error: req.headers.authorization })
      if (route === "html") {
        res.writeHead(502, { "Content-Type": "text/html" })
        return res.end("<html>bad gateway</html>")
      }
      if (route === "redirect") {
        res.writeHead(302, { Location: "https://evil.example/steal" })
        return res.end()
      }
      if (route === "huge") {
        res.writeHead(200, { "Content-Type": "application/json" })
        return res.end("x".repeat(1024 * 1024 + 10))
      }
      if (route === "hang") return // never answers
      json(res, 500, { error: "ingest_unavailable" })
    })
  })
  after(() => server.close())

  test("sends the key as a bearer token, JSON body, no redirects", async () => {
    const result = await post(make(), { endpoint: server.url, payload: HEARTBEAT })
    assert.equal(result.ok, true)
    assert.equal(result.status, 200)
    assert.equal(result.json.server_time, "2026-11-15T12:00:00Z")
    assert.equal(result.transport_error, null)
    const req = server.requests.at(-1)
    assert.equal(req.method, "POST")
    assert.equal(req.url, "/api/ingest/v1")
    assert.equal(req.headers.authorization, `Bearer ${KEY}`)
    assert.equal(req.headers["content-type"], "application/json")
    assert.equal(req.headers["user-agent"], "aptic_bridge/0.1.0")
    assert.equal(req.headers["content-encoding"], undefined)
    assert.deepEqual(JSON.parse(req.body), HEARTBEAT)
  })

  test("reads the key from the convar at send time (rotation)", async () => {
    const values = { aptic_api_key: KEY, aptic_dev: "1" }
    const t = transportJs.createTransport({ getConvar: convars(values) })
    await post(t, { endpoint: server.url, payload: HEARTBEAT })
    values.aptic_api_key = KEY.replace("TEST", "ROTA")
    await post(t, { endpoint: server.url, payload: HEARTBEAT })
    const [a, b] = server.requests.slice(-2)
    assert.notEqual(a.headers.authorization, b.headers.authorization)
    assert.ok(b.headers.authorization.includes("ROTA"))
  })

  test("a raw body string is sent byte for byte", async () => {
    const body = '{"version":1,"operation":"status","snapshot_id":"x"}'
    await post(make(), { endpoint: server.url, body })
    assert.equal(server.requests.at(-1).body, body)
  })

  test("401 and 422 come back with their codes", async () => {
    const r401 = await post(make(), { endpoint: server.url, payload: { route: "401" } })
    assert.equal(r401.status, 401)
    assert.equal(r401.code, "invalid_credential")
    assert.equal(r401.ok, false)
    const r422 = await post(make(), { endpoint: server.url, payload: { route: "422" } })
    assert.equal(r422.code, "adapter_mismatch")
  })

  test("429 retry_after is read from the JSON body and the header", async () => {
    const r = await post(make(), { endpoint: server.url, payload: { route: "429" } })
    assert.equal(r.status, 429)
    assert.equal(r.retry_after_body, 17)
    assert.equal(r.retry_after_header, 17)
    const n = await post(make(), { endpoint: server.url, payload: { route: "429-null" } })
    assert.equal(n.retry_after_body, null, "null means waiting will not help")
    assert.equal(n.retry_after_header, 60)
  })

  test("an error code that is not a safe code is not passed on", async () => {
    const r = await post(make(), { endpoint: server.url, payload: { route: "echo-key" } })
    assert.equal(r.status, 400)
    assert.equal(r.code, null)
  })

  test("non-JSON answers have json null", async () => {
    const r = await post(make(), { endpoint: server.url, payload: { route: "html" } })
    assert.equal(r.status, 502)
    assert.equal(r.json, null)
    assert.equal(r.code, null)
  })

  test("redirects are not followed", async () => {
    const before = server.requests.length
    const r = await post(make(), { endpoint: server.url, payload: { route: "redirect" } })
    assert.equal(r.status, 302)
    assert.equal(r.ok, false)
    assert.equal(server.requests.length, before + 1)
  })

  test("oversized answers are cut off", async () => {
    const r = await post(make(), { endpoint: server.url, payload: { route: "huge" } })
    assert.equal(r.transport_error, "response_too_large")
  })

  test("a server that never answers times out", async () => {
    const started = Date.now()
    const r = await post(make(), {
      endpoint: server.url,
      payload: { route: "hang" },
      timeout_ms: 1000,
    })
    assert.equal(r.transport_error, "timeout")
    assert.equal(r.status, 0)
    assert.ok(Date.now() - started < 5000)
  })

  test("results never contain the key", async () => {
    for (const route of ["ok", "401", "429", "echo-key", "html", "redirect"]) {
      const r = await post(make(), { endpoint: server.url, payload: { route } })
      assert.ok(!JSON.stringify(r).includes(KEY.slice(8)), route)
    }
  })

  test("the callback is called exactly once", async () => {
    let calls = 0
    await new Promise((resolve) => {
      make().post({ endpoint: server.url, payload: { route: "hang" }, timeout_ms: 1000 }, () => {
        calls++
        setTimeout(resolve, 300)
      })
    })
    assert.equal(calls, 1)
  })
})

describe("refusals before any request", () => {
  let server
  before(async () => {
    server = await serve((_req, _body, res) => json(res, 200, { ok: true }))
  })
  after(() => server.close())

  const cases = [
    ["no key", { aptic_api_key: "" }, () => server.url, "no_key"],
    ["malformed key", { aptic_api_key: KEY + "x" }, () => server.url, "invalid_key"],
    ["http without aptic_dev", { aptic_dev: "0" }, () => server.url, "insecure_endpoint"],
    ["http to a non-local host", {}, () => "http://aptic.dev/api/ingest/v1", "insecure_endpoint"],
    ["credentials in the URL", {}, () => "https://u:p@aptic.dev/x", "invalid_endpoint"],
    ["not a URL", {}, () => "aptic.dev", "invalid_endpoint"],
  ]
  for (const [name, values, url, code] of cases) {
    test(name, async () => {
      const before = server.requests.length
      const r = await post(make(values), { endpoint: url(), payload: HEARTBEAT })
      assert.equal(r.transport_error, code)
      assert.equal(server.requests.length, before, "nothing was sent")
    })
  }

  test("bodies over 256 KiB are refused", async () => {
    const r = await post(make(), { endpoint: server.url, body: "x".repeat(256 * 1024 + 1) })
    assert.equal(r.transport_error, "body_too_large")
  })

  test("a request without payload or body is refused", async () => {
    const r = await post(make(), { endpoint: server.url })
    assert.equal(r.transport_error, "invalid_request")
  })

  test("connection refused is a network error with its Node code", async () => {
    const r = await post(make(), { endpoint: "http://127.0.0.1:1/api/ingest/v1", payload: HEARTBEAT })
    assert.equal(r.transport_error, "network")
    assert.equal(r.detail, "ECONNREFUSED")
  })
})

// TLS: a self-signed certificate made with openssl for this run only.
const openssl = (() => {
  try {
    execFileSync("openssl", ["version"], { stdio: "ignore" })
    return true
  } catch {
    return false
  }
})()

describe("TLS verification", { skip: openssl ? false : "openssl not found" }, () => {
  let dir, cert, key, server
  before(async () => {
    dir = mkdtempSync(join(tmpdir(), "aptic-tls-"))
    execFileSync(
      "openssl",
      [
        "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
        "-keyout", join(dir, "key.pem"), "-out", join(dir, "cert.pem"),
        "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost",
      ],
      { stdio: "ignore", env: { ...process.env, MSYS_NO_PATHCONV: "1" } }
    )
    cert = readFileSync(join(dir, "cert.pem"))
    key = readFileSync(join(dir, "key.pem"))
    server = await serve((_req, _body, res) => json(res, 200, { ok: true }), {
      tls: { cert, key },
    })
  })
  after(async () => {
    await server?.close()
    if (dir) rmSync(dir, { recursive: true, force: true })
  })

  test("an untrusted certificate is refused and the key is not sent", async () => {
    const r = await post(make({ aptic_dev: "0" }), { endpoint: server.url, payload: HEARTBEAT })
    assert.equal(r.transport_error, "tls")
    assert.equal(r.detail, "DEPTH_ZERO_SELF_SIGNED_CERT")
    assert.equal(server.requests.length, 0)
  })

  test("a trusted certificate works over https", async () => {
    const r = await post(make({ aptic_dev: "0" }, { tls: { ca: cert } }), {
      endpoint: server.url,
      payload: HEARTBEAT,
    })
    assert.equal(r.ok, true)
    assert.equal(server.requests.at(-1).headers.authorization, `Bearer ${KEY}`)
  })

  test("a certificate for another name is refused", async () => {
    const url = server.url.replace("localhost", "127.0.0.1")
    const r = await post(make({ aptic_dev: "0" }, { tls: { ca: cert } }), {
      endpoint: url,
      payload: HEARTBEAT,
    })
    assert.equal(r.transport_error, "tls")
  })
})

describe("crypto", () => {
  test("saltFingerprint is the first 8 hex of SHA-256('aptic-fp' + salt)", () => {
    const salt = "0123456789abcdef".repeat(4)
    assert.equal(transportJs.saltFingerprint(salt), "49224dd5")
    const other = "f".repeat(64)
    assert.equal(
      transportJs.saltFingerprint(other),
      createHash("sha256").update(`aptic-fp${other}`).digest("hex").slice(0, 8)
    )
    assert.throws(() => transportJs.saltFingerprint("ABC"))
    assert.throws(() => transportJs.saltFingerprint("0123456789ABCDEF".repeat(4)))
  })

  test("randomHex gives n random bytes as hex", () => {
    const a = transportJs.randomHex(16)
    assert.match(a, /^[0-9a-f]{32}$/)
    assert.notEqual(a, transportJs.randomHex(16))
    assert.throws(() => transportJs.randomHex(0))
    assert.throws(() => transportJs.randomHex(65))
    assert.throws(() => transportJs.randomHex(1.5))
  })
})

describe("FiveM wiring", () => {
  test("loaded as a FiveM script it registers httpPost, randomHex, saltFingerprint and the cache", async (t) => {
    const resourceDir = mkdtempSync(join(tmpdir(), "aptic-res-"))
    t.after(() => rmSync(resourceDir, { recursive: true, force: true }))
    const registered = {}
    const context = vm.createContext({
      require,
      Buffer,
      URL,
      setTimeout,
      clearTimeout,
      exports: (name, fn) => {
        registered[name] = fn
      },
      GetConvar: (name, fallback) => (name === "aptic_api_key" ? "" : fallback),
      GetCurrentResourceName: () => "aptic_bridge",
      GetResourceMetadata: () => "0.1.0",
      GetResourcePath: () => resourceDir,
    })
    vm.runInContext(readFileSync(join(ROOT, "server", "transport.js"), "utf8"), context)
    assert.deepEqual(Object.keys(registered).sort(), [
      "cacheList", "cacheRead", "cacheRemove", "cacheWrite", "httpPost", "randomHex", "saltFingerprint",
    ])
    assert.equal(registered.cacheWrite("snap-1/start.json", "{}"), 2)
    assert.equal(readFileSync(join(resourceDir, "cache", "snap-1", "start.json"), "utf8"), "{}")
    assert.equal(registered.cacheRemove("snap-1"), true)
    assert.match(registered.randomHex(4), /^[0-9a-f]{8}$/)
    const result = await new Promise((resolve) =>
      registered.httpPost({ endpoint: "https://aptic.dev/api/ingest/v1", payload: HEARTBEAT }, resolve)
    )
    assert.equal(result.transport_error, "no_key")
  })
})

describe("chunk cache", () => {
  let dir
  let cache
  before(() => {
    dir = mkdtempSync(join(tmpdir(), "aptic-cache-"))
    cache = transportJs.createCache(join(dir, "cache"))
  })
  after(() => rmSync(dir, { recursive: true, force: true }))

  test("writes, reads back byte for byte, lists and removes a snapshot folder", () => {
    const text = '[{"name":"José 😀","amount":-250}]'
    assert.equal(cache.write("apb-1/balances.0.json", text), Buffer.byteLength(text))
    assert.equal(cache.read("apb-1/balances.0.json"), text)
    assert.deepEqual(readFileSync(join(dir, "cache", "apb-1", "balances.0.json")), Buffer.from(text, "utf8"))
    assert.deepEqual(cache.list(), ["apb-1"])
    assert.equal(cache.remove("apb-1"), true)
    assert.equal(cache.read("apb-1/balances.0.json"), null)
    assert.deepEqual(cache.list(), [])
  })

  test("an overwrite replaces the whole file and leaves no temporary file", () => {
    cache.write("apb-2/a.json", "x".repeat(1000))
    cache.write("apb-2/a.json", "short")
    assert.equal(cache.read("apb-2/a.json"), "short")
    assert.deepEqual(readdirSync(join(dir, "cache", "apb-2")), ["a.json"])
    cache.remove("apb-2")
  })

  test("only names inside cache/ are reachable", () => {
    for (const bad of ["../x", "a/../../x", "a/b/c", "", ".hidden", "a\b", "C:/x", "/abs", "a/", "a:b"]) {
      assert.equal(cache.write(bad, "x"), false, bad)
      assert.equal(cache.read(bad), null, bad)
      assert.equal(cache.remove(bad), false, bad)
    }
    assert.equal(cache.write("ok", 5), false, "non-string content")
  })

  test("files over 1 MiB are refused", () => {
    assert.equal(cache.write("apb-3/big.json", "x".repeat(1024 * 1024 + 1)), false)
  })

  test("a missing root folder reads as empty", () => {
    const none = transportJs.createCache(() => null)
    assert.deepEqual(none.list(), [])
    assert.equal(none.write("a/b.json", "x"), false)
    assert.equal(none.read("a/b.json"), null)
  })
})
