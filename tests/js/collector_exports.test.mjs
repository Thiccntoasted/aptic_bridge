// transport.js collector exports under plain Node: player hashing from the
// pinned salt, and txAdmin's playersDB.json (path discovery, reading,
// lookups).

import assert from "node:assert/strict"
import { mkdtempSync, mkdirSync, rmSync, utimesSync, writeFileSync } from "node:fs"
import { createRequire } from "node:module"
import { tmpdir } from "node:os"
import path from "node:path"
import fs from "node:fs"
import { after, describe, test } from "node:test"

import { ROOT } from "../support/fivem.mjs"

const require = createRequire(import.meta.url)
const transportJs = require("../../server/transport.js")

const SALT = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
const convars = (values) => (name, fallback) => (name in values ? values[name] : fallback)

describe("player hashing", () => {
  test("hmacHex matches openssl with the salt as a hex key", () => {
    // printf 'aptic.v1|license:1a2b...1213' | openssl dgst -sha256 -mac HMAC -macopt hexkey:<SALT>
    assert.equal(
      transportJs.hmacHex(SALT, "aptic.v1|license:1a2b3c4d5e6f708192a3b4c5d6e7f80910111213"),
      "97cdbd471deed5a11474f2b54c4cb376447c680d6dd1ca855c1c98f2dd3aed5f"
    )
    // printf 'aptic.v1.name|abc12345' | openssl dgst -sha256 -mac HMAC -macopt hexkey:<SALT>
    assert.equal(
      transportJs.hmacHex(SALT, "aptic.v1.name|abc12345"),
      "16d278ef896eb887acb823838a23fbeaa9a4d6c68b5bd4dd121c14504463ad00"
    )
    assert.throws(() => transportJs.hmacHex("abc", "x"))
  })

  test("playerHashes uses the pinned aptic_salt convar and lowercases the license", () => {
    const id = transportJs.createIdentity({ getConvar: convars({ aptic_salt: ` ${SALT.toUpperCase()} ` }) })
    const result = id.playerHashes(["LICENSE:1A2B3C4D5E6F708192A3B4C5D6E7F80910111213", "license2:ff"])
    assert.equal(result.salt_fp, "49224dd5")
    assert.equal(
      result.hashes["LICENSE:1A2B3C4D5E6F708192A3B4C5D6E7F80910111213"],
      "97cdbd471deed5a11474f2b54c4cb376447c680d6dd1ca855c1c98f2dd3aed5f"
    )
    assert.match(result.hashes["license2:ff"], /^[0-9a-f]{64}$/)
  })

  test("Lua sequences that arrive as objects are accepted", () => {
    const id = transportJs.createIdentity({ getConvar: convars({ aptic_salt: SALT }) })
    const result = id.playerHashes({ 1: "license:aa", 2: "license:bb" })
    assert.deepEqual(Object.keys(result.hashes).sort(), ["license:aa", "license:bb"])
  })

  test("no pinned salt: nothing is hashed", () => {
    for (const salt of ["", "not-hex", SALT.slice(1)]) {
      const id = transportJs.createIdentity({ getConvar: convars({ aptic_salt: salt }) })
      assert.deepEqual(id.playerHashes(["license:aa"]), { error: "salt_not_pinned" })
      assert.deepEqual(id.pseudonymTags(["ABC"]), { error: "salt_not_pinned" })
    }
  })

  test("pseudonym tags are 8 hex, stable, and differ per character", () => {
    const id = transportJs.createIdentity({ getConvar: convars({ aptic_salt: SALT }) })
    const a = id.pseudonymTags(["ABC12345", "BCD23456"])
    assert.equal(a.tags.ABC12345, "16d278ef")
    assert.notEqual(a.tags.ABC12345, a.tags.BCD23456)
    assert.deepEqual(id.pseudonymTags(["ABC12345"]).tags, { ABC12345: "16d278ef" })
  })

  test("over-long or non-string ids are skipped, not hashed", () => {
    const id = transportJs.createIdentity({ getConvar: convars({ aptic_salt: SALT }) })
    const result = id.playerHashes(["x".repeat(257), 42, null, "license:ok"])
    assert.deepEqual(Object.keys(result.hashes), ["license:ok"])
  })
})

describe("txAdmin playersDB.json", () => {
  const dirs = []
  const tmp = () => {
    const d = mkdtempSync(path.join(tmpdir(), "aptic-tx-"))
    dirs.push(d)
    return d
  }
  after(() => dirs.forEach((d) => rmSync(d, { recursive: true, force: true })))

  const make = (values = {}, extra = {}) =>
    transportJs.createTxAdmin({ fs, path, getConvar: convars(values), env: {}, platform: "linux", ...extra })

  test("path discovery follows txAdmin's order: TXHOST_DATA_PATH, txDataPath, citizen_root", () => {
    const winRoot = "C:\\fx\\artifacts\\citizen"
    const p = path.win32
    const win = transportJs.createTxAdmin({
      fs,
      path: p,
      getConvar: convars({ citizen_root: winRoot }),
      env: {},
      platform: "win32",
    })
    assert.deepEqual(win.locate(), {
      file: p.join(winRoot, "..", "txData", "default", "data", "playersDB.json"),
      source: "default",
    })
    const linux = transportJs.createTxAdmin({
      fs,
      path: path.posix,
      getConvar: convars({ citizen_root: "/opt/fx/alpine/opt/cfx-server/citizen", serverProfile: "rp-main!" }),
      env: {},
      platform: "linux",
    })
    assert.deepEqual(linux.locate(), {
      // same join as txAdmin: three levels above citizen_root
      file: "/opt/fx/alpine/txData/rp-main/data/playersDB.json",
      source: "default",
    })
    const conv = transportJs.createTxAdmin({
      fs,
      path: path.posix,
      getConvar: convars({ txDataPath: "/srv/txData", citizen_root: "/x" }),
      env: {},
      platform: "linux",
    })
    assert.equal(conv.locate().file, "/srv/txData/default/data/playersDB.json")
    assert.equal(conv.locate().source, "convar")
    const envd = transportJs.createTxAdmin({
      fs,
      path: path.posix,
      getConvar: convars({ txDataPath: "/srv/txData" }),
      env: { TXHOST_DATA_PATH: "/data/tx" },
      platform: "linux",
    })
    assert.deepEqual(envd.locate(), { file: "/data/tx/default/data/playersDB.json", source: "env" })
    assert.deepEqual(make().locate(), { error: "no_path" })
    assert.equal(make().locate("/custom/playersDB.json").source, "config")
  })

  test("a relative txDataPath resolves against the working directory, as txAdmin does", () => {
    const tx = make({ txDataPath: "tests/fixtures/txData" })
    assert.equal(tx.locate().file, path.resolve("tests/fixtures/txData/default/data/playersDB.json"))
  })

  test("reads the fixture: playtime in minutes and first join in seconds, by license and license2", () => {
    const tx = make({ txDataPath: path.join(ROOT, "tests/fixtures/txData") })
    assert.deepEqual(tx.load(), { state: "ok", source: "convar", players: 7 })
    const found = tx.lookup([
      "license2:a1b2c3d4e5f60718293a4b5c6d7e8f9012345678",
      "license:1a2b3c4d5e6f708192a3b4c5d6e7f80910111213",
      "1A2B3C4D5E6F708192A3B4C5D6E7F80910111213",
      "license2:d4e5f60718293a4b5c6d7e8f9012345678a1b2c3",
      "license:ffffffffffffffffffffffffffffffffffffffff",
    ])
    assert.deepEqual(found, {
      "license2:a1b2c3d4e5f60718293a4b5c6d7e8f9012345678": { playtime_minutes: 1290, joined_ts: 1772323200 },
      "license:1a2b3c4d5e6f708192a3b4c5d6e7f80910111213": { playtime_minutes: 5400, joined_ts: 1759968000 },
      "1A2B3C4D5E6F708192A3B4C5D6E7F80910111213": { playtime_minutes: 5400, joined_ts: 1759968000 },
      // playTime 12.5 is not a minute count: left out, never rounded
      "license2:d4e5f60718293a4b5c6d7e8f9012345678a1b2c3": { joined_ts: 1771070400 },
    })
  })

  test("only playtime and first join come back: no names, ids, notes or actions", () => {
    const tx = make({ txDataPath: path.join(ROOT, "tests/fixtures/txData") })
    tx.load()
    const text = JSON.stringify(tx.lookup(["license2:a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"]))
    for (const leak of ["MarcusTx", "discord", "steam", "99887766", "VDM", "hwid", "2:aa11"])
      assert.ok(!text.includes(leak), leak)
  })

  test("missing, unreadable and malformed files are reported, and lookups find nothing", () => {
    const dir = tmp()
    const file = path.join(dir, "default", "data", "playersDB.json")
    const tx = make({ txDataPath: dir })
    assert.deepEqual(tx.load(), { state: "absent", source: "convar", players: 0 })
    mkdirSync(path.dirname(file), { recursive: true })
    writeFileSync(file, '{"version":5,"players":[{"license":"aa"')
    assert.equal(tx.load().state, "unreadable")
    assert.deepEqual(tx.lookup(["license:aa"]), {})
    writeFileSync(file, '{"version":5,"players":{}}')
    assert.equal(tx.load().state, "invalid")
    mkdirSync(path.join(dir, "dirprofile", "data", "playersDB.json"), { recursive: true })
    assert.equal(make({ txDataPath: dir, serverProfile: "dirprofile" }).load().state, "unreadable")
  })

  test("the file is re-read only when it changes", () => {
    const dir = tmp()
    const file = path.join(dir, "default", "data", "playersDB.json")
    mkdirSync(path.dirname(file), { recursive: true })
    const write = (minutes, when) => {
      writeFileSync(
        file,
        JSON.stringify({ version: 5, players: [{ license: "aa", ids: [], playTime: minutes, tsJoined: 1700000000 }] })
      )
      utimesSync(file, when, when)
    }
    let reads = 0
    const countingFs = { ...fs, readFileSync: (...a) => (reads++, fs.readFileSync(...a)) }
    const tx = make({ txDataPath: dir }, { fs: countingFs })
    write(10, 1700000000)
    tx.load()
    tx.load()
    assert.equal(reads, 1)
    assert.equal(tx.lookup(["license:aa"])["license:aa"].playtime_minutes, 10)
    write(11, 1700000100)
    tx.load()
    assert.equal(reads, 2)
    assert.equal(tx.lookup(["license:aa"])["license:aa"].playtime_minutes, 11)
  })

  test("an id two txAdmin players both claim is unknown, not guessed", () => {
    const dir = tmp()
    const file = path.join(dir, "default", "data", "playersDB.json")
    mkdirSync(path.dirname(file), { recursive: true })
    writeFileSync(
      file,
      JSON.stringify({
        version: 5,
        players: [
          { license: "aa", ids: ["license2:shared"], playTime: 5, tsJoined: 1700000000 },
          { license: "bb", ids: ["license2:shared"], playTime: 9, tsJoined: 1700000500 },
        ],
      })
    )
    const tx = make({ txDataPath: dir })
    tx.load()
    assert.deepEqual(tx.lookup(["license2:shared", "license:aa"]), {
      "license:aa": { playtime_minutes: 5, joined_ts: 1700000000 },
    })
  })
})
