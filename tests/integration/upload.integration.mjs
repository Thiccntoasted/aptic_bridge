// Real snapshots against a running Aptic, through the resource's own Lua
// (scheduler, chunker, chunk store, uploader, heartbeat) under Lua 5.4 with
// FiveM natives stubbed, its JS transport over real HTTP and its chunk files
// on disk. The collector is the test stand-in (tests/support/fake_collector.lua):
// synthetic, contract-valid rows, accents and emoji in names included. Only
// the FiveM thread loop is replaced, by wake() below, which runs one
// heartbeat check, one scheduler check and at most one upload request, with
// the game timer following the real clock (so pacing is real).
//
// Needs a disposable workspace (qbox + ox_inventory unless told otherwise)
// and its key. Environment:
//   APTIC_IT_ENDPOINT     default http://localhost:3300/api/ingest/v1
//   APTIC_IT_KEY_FILE     file holding the workspace's key (or APTIC_IT_KEY)
//   APTIC_IT_FRAMEWORK    default qbox
//   APTIC_IT_INVENTORY    default ox_inventory
//   APTIC_IT_CHARACTERS   characters in the synthetic snapshot, default 600
//   APTIC_IT_PHASE        full (default): one snapshot, heartbeat to finalize
//                         resume: a snapshot interrupted after some chunks (the
//                           last one sent but its answer never read), then a
//                           fresh resource on the same folder with the same KVP
//                           finishes it
//
// Prints one JSON line per request (operation, collection/index, HTTP status,
// code; never a body) and, last, a line `published <snapshot_id> <rows>`
// for each published snapshot. Exits non-zero on the first failed
// expectation. It never prints a key.

import assert from "node:assert/strict"
import { randomBytes } from "node:crypto"
import { mkdtempSync, readFileSync, readdirSync, rmSync, existsSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { createResource, fromLua, withoutNulls } from "../support/fivem.mjs"

const endpoint = process.env.APTIC_IT_ENDPOINT ?? "http://localhost:3300/api/ingest/v1"
const key = (process.env.APTIC_IT_KEY_FILE
  ? readFileSync(process.env.APTIC_IT_KEY_FILE, "utf8")
  : process.env.APTIC_IT_KEY ?? ""
).trim()
assert.match(key, /^apt_ing_[A-Za-z0-9_-]{43}$/, "APTIC_IT_KEY_FILE must hold a connection key")
const phase = process.env.APTIC_IT_PHASE ?? "full"
const framework = process.env.APTIC_IT_FRAMEWORK ?? "qbox"
const inventory = process.env.APTIC_IT_INVENTORY ?? "ox_inventory"
const characters = Number(process.env.APTIC_IT_CHARACTERS ?? 600)
const RESOURCES = {
  qbox: ["qbx_core", "1.24.1"],
  qbcore: ["qb-core", "1.3.0"],
  ox_inventory: ["ox_inventory", "v2.44.1"],
  "qb-inventory": ["qb-inventory", "2.2.3"],
}
const salt = randomBytes(32).toString("hex")
const folder = mkdtempSync(join(tmpdir(), "aptic-it-resource-"))
const t0 = Date.now()

async function boot(kvpJson) {
  const r = await createResource({ extra: ["tests/support/fake_collector.lua"], resourcePath: folder })
  const lua = (code) => r.run(code)
  const set = (name, value) => {
    r.lua.global.set("__v", value)
    lua(`${name} = __v; __v = nil`)
  }
  for (const [name, value] of Object.entries({
    aptic_dev: "1", aptic_endpoint: endpoint, aptic_api_key: key, aptic_salt: salt, sv_maxclients: "48",
  })) set(`Stub.convars[${JSON.stringify(name)}]`, value)
  for (const id of [framework, inventory]) {
    const [res, version] = RESOURCES[id]
    lua(`Stub.start(${JSON.stringify(res)}, ${JSON.stringify(version)})`)
  }
  if (kvpJson) set("__kvp", kvpJson), lua("Stub.kvp = Aptic.chunker.decode(__kvp); __kvp = nil")
  lua(`Stub.timer = ${Date.now() - t0}`)
  lua(`FakeCollector.install({ characters = ${characters}, unicode = true, framework = ${JSON.stringify(framework)}, inventory = ${JSON.stringify(inventory)} })`)
  lua("Aptic.status.register(); Aptic.scheduler.start()")
  return { r, lua }
}

const post = (r, request) =>
  new Promise((resolve) => r.jsExports.httpPost(fromLua(request), resolve))

const mustNotLeak = (text, label) => assert.ok(!text.includes(key.slice(16)), `${label} contains the key`)
const log = []

/** One wake: heartbeat if due, scheduler, then at most one upload request.
 *  With `drop`, the upload request reaches Aptic but its answer is never
 *  handled, as when the game server dies mid-request. */
async function wake(env, { drop = false } = {}) {
  const { r, lua } = env
  lua(`Stub.timer = ${Date.now() - t0}`)
  const hb = lua("return Aptic.heartbeat.prepare(Stub.timer)")
  if (hb) {
    const result = await post(r, hb)
    r.lua.global.set("__result", withoutNulls(result))
    lua("Aptic.heartbeat.handle(__result, Stub.timer); __result = nil")
    const line = JSON.stringify({ op: "heartbeat", status: result.status, code: result.code ?? undefined })
    console.log(line)
  }
  lua("Aptic.scheduler.step()")
  lua(`Stub.timer = ${Date.now() - t0}`)
  const request = lua("return Aptic.uploader.next_request(Stub.timer)")
  if (!request) return null
  const body = JSON.parse(fromLua(request.body))
  const result = await post(r, request)
  const entry = {
    op: body.operation, collection: body.collection, index: body.index,
    status: result.status, code: result.code ?? result.transport_error ?? undefined,
    json_status: result.json?.status, replayed: result.json?.replayed,
  }
  log.push(entry)
  console.log(JSON.stringify(entry))
  if (drop) return entry
  r.lua.global.set("__result", withoutNulls(result))
  lua(`Aptic.uploader.handle(__result, ${Date.now() - t0}); __result = nil`)
  return entry
}

const sleep = (ms) => new Promise((res) => setTimeout(res, ms))
const published = () => log.filter((e) => e.op === "finalize" && e.json_status === "complete").length

async function until(env, pred, maxMs, label) {
  const end = Date.now() + maxMs
  while (Date.now() < end) {
    await wake(env)
    if (pred()) return
    await sleep(250)
  }
  throw new Error(`timed out: ${label}`)
}

function queue(env) {
  const queued = env.lua("local ok, why = Aptic.scheduler.request_now(); return ok and 'ok' or why")
  assert.equal(queued, "ok", `upload now refused: ${queued}`)
}

let env = await boot()
try {
  // An accepted heartbeat first: the D8 guards need it.
  await until(env, () => env.lua("return Aptic.heartbeat.state.state") === "ok", 15000, "first heartbeat")
  const finalized = () => env.lua(`return Aptic.uploader.state.last and Aptic.uploader.state.last.result or ''`)

  if (phase === "full") {
    queue(env)
    await until(env, () => published() === 1 || env.lua("return Aptic.uploader.state.last ~= nil and Aptic.uploader.state.rec == nil"), 180000, "snapshot")
    assert.equal(finalized(), "published", `not published: ${env.lua("return Aptic.chunker.encode(Aptic.uploader.state.last)")}`)
    const ops = log.map((e) => e.op)
    assert.equal(ops[0], "start")
    assert.equal(ops.at(-1), "finalize")
    assert.ok(log.every((e) => e.status === 200), "every upload request answered 200")
  } else if (phase === "resume") {
    queue(env)
    await until(env, () => log.filter((e) => e.op === "chunk" && e.status === 200).length >= 5, 120000, "five chunks")
    // The sixth chunk reaches Aptic, but the bridge dies before reading the answer.
    let dropped = null
    while (!dropped) {
      await sleep(1000)
      const e = await wake(env, { drop: true })
      if (e?.op === "chunk") dropped = e
      else if (e) throw new Error(`expected a chunk, got ${e.op}`)
    }
    const id = env.lua("return Aptic.uploader.state.rec.id")
    const phaseBefore = env.lua("return Aptic.uploader.state.rec.phase")
    const kvp = env.lua("return Aptic.chunker.encode(Stub.kvp)")
    const files = readdirSync(join(folder, "cache", id)).length
    console.log(`--- killed during ${phaseBefore} of ${id} (${files} files in cache/${id}); restarting from KVP + files ---`)
    env.r.close()
    const before = log.length

    env = await boot(kvp)
    assert.equal(env.lua("return Aptic.uploader.state.rec and Aptic.uploader.state.rec.id"), id, "the same snapshot resumes")
    await until(env, () => env.lua("return Aptic.uploader.state.last ~= nil and Aptic.uploader.state.rec == nil"), 180000, "resumed snapshot")
    assert.equal(finalized(), "published", `not published: ${env.lua("return Aptic.chunker.encode(Aptic.uploader.state.last)")}`)
    const after = log.slice(before)
    assert.equal(after[0].op, "status", "status first after the restart")
    assert.ok(after.every((e) => e.status === 200), "no conflict or other refusal after the restart")
    const firstKeys = new Set(log.slice(0, before).filter((e) => e.op === "chunk").map((e) => `${e.collection}.${e.index}`))
    const resent = after.filter((e) => e.op === "chunk").map((e) => `${e.collection}.${e.index}`)
    for (const k of resent) assert.ok(!firstKeys.has(k), `chunk ${k} was sent again although Aptic had it`)
    assert.equal(after.filter((e) => e.op === "start").length, 0, "no second start")
    console.log(`--- resumed: ${resent.length} chunks sent after the restart, none repeated ---`)
  } else {
    throw new Error(`unknown APTIC_IT_PHASE ${phase}`)
  }

  assert.ok(!existsSync(join(folder, "cache")) || readdirSync(join(folder, "cache")).length === 0, "cache folder emptied")
  assert.ok(env.lua("return Stub.kvp['snap.current']") == null, "snap.current cleared")
  env.lua("Aptic.status.command(0, { 'upload', 'status' }); Aptic.status.command(0, { 'status' })")
  const output = env.lua("return Stub.output()")
  mustNotLeak(output, "console output")
  for (const needle of ["char-0", "Test Person", "José", "PLT0"]) assert.ok(!output.includes(needle), `console shows a row value (${needle})`)
  console.log("--- console output (redacted, as the server would print it) ---")
  console.log(output)
  const lp = JSON.parse(env.lua("return Aptic.chunker.encode(Aptic.store.get_json('snap.last_published'))"))
  console.log(`published ${lp.snapshot_id} ${lp.rows}`)
  console.log(`--- ${phase}: all expectations met ---`)
} finally {
  env.r.close()
  rmSync(folder, { recursive: true, force: true })
}
