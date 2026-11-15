// Real heartbeats against a running Aptic, sent by the resource's own Lua
// heartbeat logic (under Lua 5.4, FiveM natives stubbed) and its own JS
// transport over real HTTP. Only the five-line FiveM thread that joins
// prepare() and handle() is replaced, by the loop below.
//
// Needs a disposable workspace and its connection key. Environment:
//   APTIC_IT_ENDPOINT          default http://localhost:3300/api/ingest/v1
//   APTIC_IT_KEY_FILE          file holding the workspace's current key
//                              (APTIC_IT_KEY works too; a file keeps it out of
//                              shell history)
//   APTIC_IT_FRAMEWORK         the workspace's framework, default qbox
//   APTIC_IT_INVENTORY         the workspace's inventory, default ox_inventory
//   APTIC_IT_PHASE             basic (default): accepted heartbeat, wrong key
//                                -> 401, mismatched adapter -> 422
//                              rotation: APTIC_IT_KEY_FILE is a key that was
//                                rotated away (expect 401 and a hold), then
//                                APTIC_IT_NEW_KEY_FILE is pasted "in the
//                                console" (expect an immediate 200)
//   APTIC_IT_NEW_KEY_FILE      rotation phase only
//
// Prints one JSON line per heartbeat (status, code, state, payload without
// secrets) and exits non-zero on the first failed expectation. It never
// prints a key.

import assert from "node:assert/strict"
import { randomBytes } from "node:crypto"
import { readFileSync } from "node:fs"

import { createResource, withoutNulls } from "../support/fivem.mjs"

const endpoint =
  process.env.APTIC_IT_ENDPOINT ?? "http://localhost:3300/api/ingest/v1"
const readKey = (fileVar, valueVar) => {
  const value = process.env[fileVar]
    ? readFileSync(process.env[fileVar], "utf8").trim()
    : (process.env[valueVar] ?? "").trim()
  assert.match(value, /^apt_ing_[A-Za-z0-9_-]{43}$/, `${fileVar} must hold a connection key`)
  return value
}
const key = readKey("APTIC_IT_KEY_FILE", "APTIC_IT_KEY")
const phase = process.env.APTIC_IT_PHASE ?? "basic"
const framework = process.env.APTIC_IT_FRAMEWORK ?? "qbox"
const inventory = process.env.APTIC_IT_INVENTORY ?? "ox_inventory"

const RESOURCES = {
  qbox: ["qbx_core", "1.24.1"],
  qbcore: ["qb-core", "1.3.0"],
  ox_inventory: ["ox_inventory", "v2.44.1"],
  "qb-inventory": ["qb-inventory", "2.2.3"],
}
const OTHER = { qbox: "qbcore", qbcore: "qbox" }
const OTHER_INV = { ox_inventory: "qb-inventory", "qb-inventory": "ox_inventory" }

const r = await createResource()
const lua = (code) => r.run(code)
const setConvar = (name, value) => {
  r.lua.global.set("__v", value)
  lua(`Stub.convars[${JSON.stringify(name)}] = __v; __v = nil`)
}
const startPair = (fw, inv) => {
  for (const [res] of Object.values(RESOURCES)) lua(`Stub.stop(${JSON.stringify(res)})`)
  for (const id of [fw, inv]) {
    const [res, version] = RESOURCES[id]
    lua(`Stub.start(${JSON.stringify(res)}, ${JSON.stringify(version)})`)
  }
}

setConvar("aptic_dev", "1")
setConvar("aptic_endpoint", endpoint)
setConvar("aptic_api_key", key)
setConvar("aptic_salt", randomBytes(32).toString("hex"))
setConvar("sv_maxclients", "48")
startPair(framework, inventory)

const secrets = [key]
const mustNotLeak = (text, label) => {
  for (const s of secrets) assert.ok(!text.includes(s.slice(16)), `${label} contains a key`)
}

/** One loop wake at the current fake time; sends if a heartbeat is due. */
async function wake() {
  const request = lua("return Aptic.heartbeat.prepare(Stub.timer)")
  if (!request) return null
  const result = await new Promise((resolve) => r.jsExports.httpPost(request, resolve))
  r.lua.global.set("__result", withoutNulls(result))
  lua("Aptic.heartbeat.handle(__result, Stub.timer); __result = nil")
  const state = lua("return Aptic.heartbeat.state.state")
  const line = {
    status: result.status,
    code: result.code,
    transport_error: result.transport_error,
    state,
    payload: request.payload,
  }
  const text = JSON.stringify(line)
  mustNotLeak(text, "heartbeat line")
  console.log(text)
  return { result, state, payload: request.payload }
}

/** Jump the fake clock to the next scheduled heartbeat and wake. */
async function next() {
  lua("Stub.timer = math.max(Stub.timer, Aptic.heartbeat.state.next_at)")
  return wake()
}

if (phase === "basic") {
  // 1. Accepted.
  const ok = await next()
  assert.equal(ok.result.status, 200, `expected 200, got ${ok.result.status} ${ok.result.code}`)
  assert.equal(ok.state, "ok")
  assert.equal(ok.result.json.ok, true)
  assert.equal(typeof ok.result.json.server_time, "string")
  assert.equal(typeof ok.result.json.min_agent_version, "string")
  assert.equal(ok.payload.agent_version, "aptic_bridge/0.1.0")
  assert.match(ok.payload.salt_fp, /^[0-9a-f]{8}$/)

  // 2. The heartbeat after it, on schedule, is accepted too.
  const second = await next()
  assert.equal(second.result.status, 200)

  // 3. A wrong (well-formed) key: 401, then nothing is sent.
  const wrong = `apt_ing_${randomBytes(32).toString("base64url")}`
  secrets.push(wrong)
  setConvar("aptic_api_key", wrong)
  const refused = await wake()
  assert.ok(refused, "a changed key is sent at once")
  assert.equal(refused.result.status, 401)
  assert.equal(refused.result.code, "invalid_credential")
  assert.equal(refused.state, "unauthorized")
  lua("Stub.timer = Stub.timer + 3600 * 1000")
  assert.equal(await wake(), null, "nothing is sent while the key is refused")

  // 4. The right key again: sent at once, accepted.
  setConvar("aptic_api_key", key)
  const back = await wake()
  assert.equal(back?.result.status, 200)

  // 5. A server running the other adapter: 422 adapter_mismatch.
  startPair(OTHER[framework], OTHER_INV[inventory])
  const mismatch = await next()
  assert.equal(mismatch.result.status, 422)
  assert.equal(mismatch.result.code, "adapter_mismatch")
  assert.equal(mismatch.state, "adapter_mismatch")
  assert.equal(mismatch.payload.framework, OTHER[framework])

  // 6. Put the right adapter back: retried at once, accepted.
  startPair(framework, inventory)
  const fixed = await wake()
  assert.equal(fixed?.result.status, 200)
  assert.equal(fixed.state, "ok")
} else if (phase === "rotation") {
  const fresh = readKey("APTIC_IT_NEW_KEY_FILE", "APTIC_IT_NEW_KEY")
  secrets.push(fresh)
  const old = await next()
  assert.equal(old.result.status, 401, "the rotated-away key is refused")
  assert.equal(old.state, "unauthorized")
  lua("Stub.timer = Stub.timer + 600 * 1000")
  assert.equal(await wake(), null, "held until the key changes")
  setConvar("aptic_api_key", fresh)
  const rotated = await wake()
  assert.equal(rotated?.result.status, 200, "the new key is used at once")
  assert.equal(rotated.state, "ok")
} else {
  throw new Error(`unknown APTIC_IT_PHASE ${phase}`)
}

lua("Aptic.status.command(0, { 'status' })")
const output = lua("return Stub.output()")
mustNotLeak(output, "console output")
console.log("--- console output (redacted, as the server would print it) ---")
console.log(output)
console.log(`--- ${phase}: all expectations met ---`)
r.close()
