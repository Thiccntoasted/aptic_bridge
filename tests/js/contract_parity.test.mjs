// validate.lua against Aptic's real ingest contract (apps/web/lib/ingest/
// contract.ts, frozen 15 Nov 2026).
//
// 1. The collector runs end to end under wasmoon (both frameworks, names
//    real and pseudonymized, with and without txAdmin). Its recorded rows go
//    through contract.ts's validateRequest as chunk bodies, and its meta and
//    counts as a start body.
// 2. The finalize rules the database enforces (foreign keys, primary keys,
//    created_at <= last_seen_at <= taken_at + 2 min) are checked on the
//    recorded rows, independently of the Lua code.
// 3. Every case in tests/fixtures/contract_cases.lua goes through both
//    validate.lua and contract.ts; they must agree with each other and with
//    the expectation.
//
// contract.ts is imported read-only from the Aptic web app, not copied:
// set APTIC_CONTRACT_TS to its path, or keep the Aptic repository next to
// this one. Where it can't be found the test is skipped (reported as
// skipped, never as passed). The JSON encoding of rows here is the test
// encoder's (tests/support/json.lua); the uploader's encoder is tested on
// its own.

import assert from "node:assert/strict"
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import * as nodeModule from "node:module"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"
import { after, before, describe, test } from "node:test"
import { pathToFileURL } from "node:url"

import { ROOT, createResource } from "../support/fivem.mjs"

const CANDIDATES = [
  process.env.APTIC_CONTRACT_TS,
  join(ROOT, "..", "Aptic", ".claude", "worktrees", "agent-a227ef15c608f8b1b", "apps", "web", "lib", "ingest", "contract.ts"),
  join(ROOT, "..", "Aptic", "apps", "web", "lib", "ingest", "contract.ts"),
].filter(Boolean)

/** The frozen v1 contract: has the C2/C5/C11 shapes. */
function findContract() {
  for (const file of CANDIDATES) {
    const path = resolve(file)
    if (!existsSync(path)) continue
    const text = readFileSync(path, "utf8")
    if (text.includes("VEHICLE_STATES") && text.includes("export function validateRequest")) return { path, text }
  }
  return null
}

const found = findContract()
const canStrip = typeof nodeModule.stripTypeScriptTypes === "function"
const skip = !found
  ? "Aptic's contract.ts not found (set APTIC_CONTRACT_TS)"
  : !canStrip
    ? "this Node has no module.stripTypeScriptTypes (Node 22.13+)"
    : false

let contract
let dir
before(async () => {
  if (skip) return
  dir = mkdtempSync(join(tmpdir(), "aptic-contract-"))
  const js = nodeModule.stripTypeScriptTypes(found.text, { mode: "transform" })
  const file = join(dir, "contract.mjs")
  writeFileSync(file, js)
  contract = await import(pathToFileURL(file).href)
})
after(() => {
  if (dir) rmSync(dir, { recursive: true, force: true })
})

/** Run the Lua collector for a scenario and return what the sink recorded. */
async function collect(setup) {
  const resource = await createResource()
  try {
    const out = resource.run(`
      dofile('tests/support/collect.lua')
      ${setup}
      local sink, summary, err = C.run()
      if not summary then error('collector failed: ' .. tostring(err)) end
      return C.recorded_json(sink, summary)
    `)
    return JSON.parse(out)
  } finally {
    resource.close()
  }
}

const SCENARIOS = {
  "Qbox + ox_inventory": "C.qbox()",
  "Qbox, pseudonymized": "C.qbox(); Aptic.config.pseudonymize = true",
  "Qbox without txAdmin": "C.qbox({ txadmin = false })",
  "QBCore + qb-inventory": "C.qbcore()",
  "QBCore, pseudonymized, renamed currency": `C.qbcore(); Aptic.config.pseudonymize = true
      Aptic.config.currencies = { rename = { BlackMoney = 'dirty' }, skip = {} }`,
}

function finalizeChecks(rec) {
  const rows = rec.rows
  const taken = Date.parse(rec.meta.taken_at)
  const unique = (list, key, what) => {
    const seen = new Set()
    for (const r of list ?? []) {
      const k = key(r)
      assert.ok(!seen.has(k), `${what}: duplicate key ${k}`)
      seen.add(k)
    }
    return seen
  }
  const chars = unique(rows.characters, (r) => r.char_id, "characters")
  unique(rows.balances, (r) => `${r.char_id}|${r.currency}`, "balances")
  unique(rows.vehicles, (r) => r.plate, "vehicles")
  unique(rows.jobs, (r) => `${r.kind}|${r.name}`, "jobs")
  for (const b of rows.balances ?? []) assert.ok(chars.has(b.char_id), "balance references a sent character")
  for (const v of rows.vehicles ?? [])
    if (v.owner_char_id != null) assert.ok(chars.has(v.owner_char_id), "vehicle owner is a sent character")
  for (const c of rows.characters) {
    const last = Date.parse(c.last_seen_at)
    assert.ok(last <= taken + 120_000, "last_seen_at <= taken_at + 2 min")
    if (c.created_at != null) assert.ok(Date.parse(c.created_at) <= last, "created_at <= last_seen_at")
  }
}

describe("recorded snapshots pass Aptic's contract.ts", { skip }, () => {
  for (const [name, setup] of Object.entries(SCENARIOS)) {
    test(name, async () => {
      const rec = await collect(setup)
      const m = rec.meta
      const now = Date.parse(m.taken_at)
      const start = contract.validateRequest(
        {
          version: 1,
          operation: "start",
          snapshot_id: "apb-parity-0001",
          taken_at: m.taken_at,
          source: "bridge",
          capabilities: m.capabilities,
          online_count: m.online_count,
          manifest: rec.counts,
          framework: m.framework,
          inventory: m.inventory,
          framework_version: m.framework_version,
          inventory_version: m.inventory_version,
          salt_fp: m.salt_fp,
          agent_version: "aptic_bridge/0.1.0",
        },
        now
      )
      assert.deepEqual(start.capabilities, ["characters", "balances", "vehicles", "jobs", "online_count"])
      assert.ok(!start.capabilities.includes("inventory"), "D3: no inventory capability")

      let total = 0
      for (const [collection, rows] of Object.entries(rec.rows)) {
        assert.equal(rows.length, rec.counts[collection], `${collection} count`)
        for (let i = 0; i * 200 < rows.length; i++) {
          const body = {
            version: 1,
            operation: "chunk",
            snapshot_id: "apb-parity-0001",
            collection,
            index: i,
            rows: rows.slice(i * 200, i * 200 + 200),
          }
          const checked = contract.validateRequest(body, now)
          total += checked.rows.length
        }
      }
      assert.ok(total > 20, `rows checked: ${total}`)
      for (const c of ["containers", "item_stacks", "activity", "registry"]) {
        assert.equal(rec.counts[c], 0)
        assert.equal(rec.rows[c], undefined)
      }
      finalizeChecks(rec)
    })
  }
})

describe("validate.lua and contract.ts agree on every contract case", { skip }, () => {
  test("accept and reject the same rows", async () => {
    const resource = await createResource()
    let cases
    try {
      cases = JSON.parse(
        resource.run(`
          local out = {}
          for _, c in ipairs(dofile('tests/fixtures/contract_cases.lua')) do
            if not c.lua_only then
              local ok = Aptic.validate.row(c.collection, c.row)
              out[#out + 1] = { collection = c.collection, note = c.note, valid = c.valid, lua = ok, row = c.row }
            end
          end
          return json.encode(out)
        `)
      )
    } finally {
      resource.close()
    }
    assert.ok(cases.length > 70, `${cases.length} cases`)
    const disagreements = []
    for (const c of cases) {
      let ts = true
      try {
        contract.validateRows(c.collection, [c.row])
      } catch (e) {
        if (!(e instanceof contract.IngestError)) throw e
        ts = false
      }
      if (ts !== c.valid || c.lua !== c.valid)
        disagreements.push(`${c.collection} / ${c.note}: expected ${c.valid}, contract.ts ${ts}, validate.lua ${c.lua}`)
    }
    assert.deepEqual(disagreements, [])
  })
})
