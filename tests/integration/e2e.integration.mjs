// End to end against a running Aptic, for one framework at a time: the real
// collector (server/collector.lua and the framework adapter) reads a fixture
// database (tests/fixtures/<framework>.lua, repeated APTIC_IT_COPIES times
// behind a fake oxmysql), the real upload engine (chunker, chunk files,
// uploader, scheduler, heartbeat) sends it through the real transport.js
// over HTTP, and, when given database access, the test checks what Aptic
// stored. Only the FiveM natives and the thread loop are stand-ins (see
// tests/support/fivem.mjs); txAdmin's player file is the fixture one.
//
// It proves, per framework:
//   1. a heartbeat answered 200;
//   2. `aptic validate` and the upload count the same rows;
//   3. the snapshot published (every upload request answered 200);
// and with APTIC_IT_PSQL:
//   4. data_snapshots has it as complete;
//   5. the normalized tables hold exactly the rows the collector sent;
//   6. aptic_private.prepare_ingest_jobs() and run_analysis_jobs() complete
//      it (analysis_status complete);
//   7. no stored row for the workspace, in any table that has a server_id,
//      holds a license, a FiveM account name, a phone number or any other
//      identifier from the fixture database, the salt or the key.
//
// Needs a local Aptic (apps/web dev server plus its Supabase stack) and a
// disposable workspace whose framework and inventory match, with a plan
// and a connection key. Environment:
//   APTIC_IT_ENDPOINT    default http://localhost:3300/api/ingest/v1
//   APTIC_IT_KEY_FILE    file holding the workspace's key (or APTIC_IT_KEY)
//   APTIC_IT_FRAMEWORK   qbox (default; with ox_inventory) or qbcore (with
//                        qb-inventory); the first argument wins, as in
//                        `npm run test:integration:qbcore`
//   APTIC_IT_COPIES      how many times the fixture database is repeated,
//                        default 150
//   APTIC_IT_PSQL        optional: a command that runs one SQL string given as
//                        its last argument and prints unaligned tuples, e.g.
//                        `docker exec supabase_db_Aptic psql -U postgres -d postgres -Atc`.
//                        Without it, steps 4-7 are skipped (and say so).
//   APTIC_IT_SERVER_ID   the workspace id (needed with APTIC_IT_PSQL)
//
// Prints one JSON line per request (operation, collection/index, HTTP
// status, code; never a body), the counts, and the checks. Exits non-zero
// on the first failed expectation. It never prints the key or a row.

import assert from "node:assert/strict"
import { randomBytes } from "node:crypto"
import { execFileSync } from "node:child_process"
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { ROOT, createResource, fromLua, withoutNulls } from "../support/fivem.mjs"

const endpoint = process.env.APTIC_IT_ENDPOINT ?? "http://localhost:3300/api/ingest/v1"
const key = (process.env.APTIC_IT_KEY_FILE
  ? readFileSync(process.env.APTIC_IT_KEY_FILE, "utf8")
  : process.env.APTIC_IT_KEY ?? ""
).trim()
assert.match(key, /^apt_ing_[A-Za-z0-9_-]{43}$/, "APTIC_IT_KEY_FILE must hold a connection key")
const framework = process.argv[2] ?? process.env.APTIC_IT_FRAMEWORK ?? "qbox"
assert.ok(["qbox", "qbcore"].includes(framework), "APTIC_IT_FRAMEWORK is qbox or qbcore")
const inventory = framework === "qbox" ? "ox_inventory" : "qb-inventory"
const copies = Number(process.env.APTIC_IT_COPIES ?? 150)
assert.ok(Number.isInteger(copies) && copies >= 1 && copies <= 2000, "APTIC_IT_COPIES is 1..2000")
const psqlCommand = (process.env.APTIC_IT_PSQL ?? "").trim().split(/\s+/).filter(Boolean)
const serverId = process.env.APTIC_IT_SERVER_ID ?? ""
if (psqlCommand.length) assert.match(serverId, /^[A-Za-z0-9_-]+$/, "APTIC_IT_SERVER_ID is needed with APTIC_IT_PSQL")

const salt = randomBytes(32).toString("hex")
const folder = mkdtempSync(join(tmpdir(), "aptic-e2e-resource-"))
const t0 = Date.now()
const sleep = (ms) => new Promise((res) => setTimeout(res, ms))

// The resource ------------------------------------------------------------------

process.chdir(ROOT) // txAdmin's fixture path is relative to the repository
const r = await createResource({ extra: ["tests/support/collect.lua"], resourcePath: folder })
const lua = (code) => r.run(code)
const set = (name, value) => {
  r.lua.global.set("__v", value)
  lua(`${name} = __v; __v = nil`)
}
const json = (expr) => JSON.parse(fromLua(lua(`return Aptic.chunker.encode(${expr})`)))

lua(`E2E = { fixture = C.${framework}({ copies = ${copies} }) }`)
for (const [name, value] of Object.entries({
  aptic_dev: "1", aptic_endpoint: endpoint, aptic_api_key: key, aptic_salt: salt, sv_maxclients: "48",
})) set(`Stub.convars[${JSON.stringify(name)}]`, value)
// Keep the summary of every collector run (counts and skipped reasons only).
lua(`
  local run = Aptic.collector.run
  Aptic.collector.run = function(sink, opts)
    local summary, err = run(sink, opts)
    E2E.summary = summary and { counts = summary.counts, skipped = summary.skipped.reasons,
      adjusted = summary.adjusted, txadmin = summary.txadmin.state } or { error = err }
    return summary, err
  end
`)
lua(`Stub.timer = ${Date.now() - t0}`)
lua("Aptic.status.register(); Aptic.scheduler.start()")

const post = (request) => new Promise((resolve) => r.jsExports.httpPost(fromLua(request), resolve))
const log = []

/** One wake: heartbeat if due, scheduler, then at most one upload request. */
async function wake() {
  lua(`Stub.timer = ${Date.now() - t0}`)
  const hb = lua("return Aptic.heartbeat.prepare(Stub.timer)")
  if (hb) {
    const result = await post(hb)
    r.lua.global.set("__result", withoutNulls(result))
    lua("Aptic.heartbeat.handle(__result, Stub.timer); __result = nil")
    const entry = { op: "heartbeat", status: result.status, code: result.code ?? result.transport_error ?? undefined }
    log.push(entry)
    console.log(JSON.stringify(entry))
  }
  lua("Aptic.scheduler.step()")
  lua(`Stub.timer = ${Date.now() - t0}`)
  const request = lua("return Aptic.uploader.next_request(Stub.timer)")
  if (!request) return null
  const body = JSON.parse(fromLua(request.body))
  const result = await post(request)
  const entry = {
    op: body.operation, collection: body.collection, index: body.index,
    status: result.status, code: result.code ?? result.transport_error ?? undefined, json_status: result.json?.status,
  }
  log.push(entry)
  if (entry.op !== "chunk" || entry.status !== 200 || entry.index === 0) console.log(JSON.stringify(entry))
  r.lua.global.set("__result", withoutNulls(result))
  lua(`Aptic.uploader.handle(__result, ${Date.now() - t0}); __result = nil`)
  return entry
}

async function until(pred, maxMs, label) {
  const end = Date.now() + maxMs
  while (Date.now() < end) {
    await wake()
    if (pred()) return
    await sleep(200)
  }
  throw new Error(`timed out: ${label}`)
}

// Database checks -------------------------------------------------------------------

function psql(sql) {
  return execFileSync(psqlCommand[0], [...psqlCommand.slice(1), sql], {
    env: { ...process.env, MSYS_NO_PATHCONV: "1" },
    encoding: "utf8",
    maxBuffer: 512 * 1024 * 1024,
  }).trim()
}
const lit = (s) => `'${String(s).replace(/'/g, "''")}'`

/** Identifiers that must never be stored: from the fixture database and txAdmin's file. */
function forbidden() {
  const values = new Set(fromLua(lua("return C.identifiers(E2E.fixture)")) ?? [])
  const tx = JSON.parse(readFileSync(join(ROOT, "tests", "fixtures", "txData", "default", "data", "playersDB.json"), "utf8"))
  for (const p of tx.players ?? []) {
    if (p.license) values.add(p.license)
    for (const id of p.ids ?? []) { values.add(id); values.add(id.replace(/^[a-z0-9]+:/, "")) }
    for (const hw of p.hwids ?? []) values.add(hw)
    // displayName is left out: in the fixture some equal a character's first
    // name. The FiveM account names in players.name are in the list above.
  }
  values.add(salt)
  values.add(key)
  values.add(key.slice(16))
  return [...values].filter((v) => typeof v === "string" && v.length >= 6)
}
const PATTERNS = [/license2?:/i, /\bsteam:/i, /\bdiscord:/i, /\bfivem:/i, /\bxbl:/i, /\blive:\d/i, /\bip:\d/i]

// Run ---------------------------------------------------------------------------------

try {
  // 1. Heartbeat.
  await until(() => lua("return Aptic.heartbeat.state.state") === "ok", 20000, "first accepted heartbeat")
  const hb = log.find((e) => e.op === "heartbeat")
  assert.equal(hb.status, 200, "the first heartbeat answered 200")
  console.log(`--- heartbeat 200 (${framework} + ${inventory}) ---`)

  // 2. aptic validate, before the upload: what it would send.
  lua("Stub.prints = {}; Aptic.status.command(0, { 'validate' }); table.remove(Stub.threads)()")
  const validateOut = fromLua(lua("return Stub.output()"))
  const validated = json("E2E.summary")
  assert.match(validateOut, /result {10}ok: Aptic would accept this snapshot/, validateOut)
  for (const v of forbidden()) assert.ok(!validateOut.includes(v), "aptic validate printed an identifier")
  console.log("--- aptic validate (console output, as the server prints it) ---")
  console.log(validateOut)

  // 3. Upload.
  const queued = lua("local ok, why = Aptic.scheduler.request_now(); return ok and 'ok' or why")
  assert.equal(queued, "ok", `upload now refused: ${queued}`)
  await until(() => lua("return Aptic.uploader.state.last ~= nil and Aptic.uploader.state.rec == nil"), 900000, "snapshot")
  const last = json("Aptic.uploader.state.last")
  assert.equal(last.result, "published", `not published: ${JSON.stringify(last)}`)
  const uploads = log.filter((e) => e.op !== "heartbeat")
  assert.equal(uploads[0].op, "start")
  assert.equal(uploads.at(-1).op, "finalize")
  for (const e of log) assert.equal(e.status, 200, `${e.op} answered ${e.status} ${e.code ?? ""}`)
  const sent = json("E2E.summary")
  assert.deepEqual(sent.counts, validated.counts, "aptic validate and the upload counted the same rows")
  const snapshotId = last.snapshot_id
  const total = Object.values(sent.counts).reduce((a, b) => a + b, 0)
  assert.equal(last.rows, total, "rows published = rows collected")
  const chunks = uploads.filter((e) => e.op === "chunk").length
  console.log(`--- published ${snapshotId}: ${total} rows in ${chunks} chunks ---`)
  console.log(`sent: ${JSON.stringify(sent.counts)}`)
  console.log(`skipped: ${JSON.stringify(sent.skipped)}`)
  console.log(`adjusted: ${JSON.stringify(sent.adjusted)}`)
  assert.ok(!existsSync(join(folder, "cache")) || readdirSync(join(folder, "cache")).length === 0, "cache folder emptied")

  const consoleOut = fromLua(lua("return Stub.output()"))
  for (const v of forbidden()) assert.ok(!consoleOut.includes(v), "the console shows an identifier")
  for (const p of PATTERNS) assert.doesNotMatch(consoleOut, p, "the console shows an identifier pattern")

  if (!psqlCommand.length) {
    console.log("--- database checks skipped: APTIC_IT_PSQL is not set ---")
  } else {
    const S = lit(serverId)
    const W = `server_id = ${S} and snapshot_id = ${lit(snapshotId)}`

    // 4. Published.
    const snap = JSON.parse(psql(`select row_to_json(s) from (select id, status, source, analysis_status, salt_fp,
      capabilities from public.data_snapshots where server_id = ${S} and id = ${lit(snapshotId)}) s`))
    assert.equal(snap.status, "complete", "data_snapshots.status")
    assert.equal(snap.source, "bridge")
    console.log(`data_snapshots: ${JSON.stringify(snap)}`)

    // 5. Row counts.
    const TABLES = { characters: "snapshot_characters", balances: "snapshot_balances", containers: "snapshot_containers",
      item_stacks: "snapshot_item_stacks", vehicles: "snapshot_vehicles", activity: "snapshot_activity",
      registry: "snapshot_registry", jobs: "snapshot_jobs" }
    const stored = JSON.parse(psql(`select json_build_object(${Object.entries(TABLES)
      .map(([c, t]) => `${lit(c)}, (select count(*) from public.${t} where ${W})`).join(", ")})`))
    console.log(`stored: ${JSON.stringify(stored)}`)
    for (const c of Object.keys(TABLES)) assert.equal(stored[c], sent.counts[c] ?? 0, `${c}: stored = sent`)

    // 6. Preparation and analysis.
    console.log(`prepare_ingest_jobs(): ${psql("select aptic_private.prepare_ingest_jobs()")}`)
    console.log(`run_analysis_jobs(): ${psql("select aptic_private.run_analysis_jobs()")}`)
    const job = JSON.parse(psql(`select row_to_json(j) from (select status, summary from aptic_private.ingest_jobs where ${W}) j`) || "null")
    const run = JSON.parse(psql(`select row_to_json(a) from (select status, engine_version, last_error_code from aptic_private.analysis_runs where ${W}) a`) || "null")
    const status = psql(`select analysis_status from public.data_snapshots where server_id = ${S} and id = ${lit(snapshotId)}`)
    console.log(`ingest_jobs: ${JSON.stringify(job)}`)
    console.log(`analysis_runs: ${JSON.stringify(run)}`)
    assert.equal(job?.status, "prepared", "ingest job prepared")
    assert.equal(run?.status, "complete", "analysis run complete")
    assert.equal(status, "complete", "data_snapshots.analysis_status")

    // 7. No identifier anywhere in the workspace's rows.
    const tables = psql(`select table_schema || '.' || table_name from information_schema.columns
      where column_name = 'server_id' and table_schema in ('public', 'aptic_private') order by 1`).split("\n").filter(Boolean)
    const values = forbidden()
    let rows = 0
    for (const table of tables) {
      const text = psql(`select coalesce(string_agg(t::text, E'\\n'), '') from ${table} t where t.server_id::text = ${S}`)
      rows += text ? text.split("\n").length : 0
      for (const v of values) assert.ok(!text.includes(v), `${table} holds an identifier from the fixture`)
      for (const p of PATTERNS) assert.doesNotMatch(text, p, `${table} holds an identifier pattern`)
    }
    console.log(`--- identifier scan: ${rows} rows in ${tables.length} tables, ${values.length} values and ${PATTERNS.length} patterns: none found ---`)
  }
  console.log(`--- e2e ${framework} + ${inventory}: all expectations met ---`)
} finally {
  r.close()
  rmSync(folder, { recursive: true, force: true })
}
