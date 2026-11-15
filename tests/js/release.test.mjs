// The release zip (scripts/release.mjs): built into a temporary folder,
// then read back entry by entry. It must hold exactly one aptic_bridge/
// folder with what a server needs, byte for byte, and nothing else.

import assert from "node:assert/strict"
import { mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { after, before, test } from "node:test"

import { ROOT, manifestScripts } from "../support/fivem.mjs"
import { buildRelease, crc32, releaseVersion, unzip, zip } from "../../scripts/release.mjs"

let dir
let built
let entries
before(() => {
  dir = mkdtempSync(join(tmpdir(), "aptic-release-"))
  built = buildRelease({ outDir: dir })
  entries = unzip(readFileSync(built.path))
})
after(() => rmSync(dir, { recursive: true, force: true }))

/** Every file under server/, as the zip should list it. */
function serverFiles(sub = "server") {
  return readdirSync(join(ROOT, sub), { withFileTypes: true }).flatMap((e) =>
    e.isDirectory() ? serverFiles(`${sub}/${e.name}`) : [`${sub}/${e.name}`])
}

test("the zip is dist/aptic_bridge-<fxmanifest version>.zip", () => {
  const version = readFileSync(join(ROOT, "fxmanifest.lua"), "utf8").match(/^version '([^']+)'$/m)[1]
  assert.equal(built.version, version)
  assert.equal(releaseVersion(), version)
  assert.equal(JSON.parse(readFileSync(join(ROOT, "package.json"), "utf8")).version, version)
  assert.ok(built.path.endsWith(`aptic_bridge-${version}.zip`), built.path)
})

test("it lists exactly the server's files under one aptic_bridge/ folder", () => {
  const files = entries.filter((e) => !e.name.endsWith("/")).map((e) => e.name).sort()
  const expected = ["fxmanifest.lua", "config.lua", "LICENSE", "README.md", "INSTALL.md", "CHANGELOG.md", ...serverFiles()]
    .map((f) => `aptic_bridge/${f}`).sort()
  assert.deepEqual(files, expected)
  const dirs = entries.filter((e) => e.name.endsWith("/")).map((e) => e.name).sort()
  assert.deepEqual(dirs, ["aptic_bridge/", "aptic_bridge/server/", "aptic_bridge/server/adapters/"])
  for (const e of entries) assert.ok(e.name.startsWith("aptic_bridge/"), `${e.name} is outside aptic_bridge/`)
})

test("nothing for development: no tests, scripts, node_modules, package files, cache, dist or dotfiles", () => {
  for (const e of entries) {
    const rel = e.name.slice("aptic_bridge/".length)
    assert.doesNotMatch(rel, /^(tests|scripts|node_modules|cache|dist|\.github)(\/|$)/, e.name)
    assert.doesNotMatch(rel, /(^|\/)package(-lock)?\.json$/, e.name)
    assert.doesNotMatch(rel, /(^|\/)\./, `${e.name} is a dotfile`)
    assert.doesNotMatch(rel, /\.(mjs|test\.\w+|zip)$/, e.name)
  }
})

test("every script fxmanifest.lua loads is in the zip, byte for byte", () => {
  const byName = new Map(entries.map((e) => [e.name, e]))
  for (const script of manifestScripts().concat(["fxmanifest.lua", "config.lua"])) {
    const entry = byName.get(`aptic_bridge/${script}`)
    assert.ok(entry, `${script} is missing`)
    assert.ok(entry.data.equals(readFileSync(join(ROOT, script))), `${script} differs`)
  }
  for (const e of entries.filter((x) => !x.name.endsWith("/"))) {
    assert.ok(e.data.equals(readFileSync(join(ROOT, e.name.slice("aptic_bridge/".length)))), `${e.name} differs`)
  }
})

test("entries are deflated, readable as files (0644) and folders (0755)", () => {
  for (const e of entries) {
    if (e.name.endsWith("/")) assert.equal(e.mode, 0o40755, e.name)
    else {
      assert.equal(e.method, 8, e.name)
      assert.equal(e.mode, 0o100644, e.name)
    }
  }
})

test("the build is reproducible", () => {
  const again = buildRelease({ outDir: join(dir, "again") })
  assert.ok(readFileSync(again.path).equals(readFileSync(built.path)), "two builds differ")
})

test("the zip writer round-trips and computes CRC-32 correctly", () => {
  assert.equal(crc32(Buffer.from("123456789")), 0xcbf43926) // the standard check value
  const data = Buffer.from("héllo ".repeat(1000), "utf8")
  const out = unzip(zip([{ name: "a/" }, { name: "a/b.txt", data }, { name: "a/empty", data: Buffer.alloc(0) }], new Date()))
  assert.deepEqual(out.map((e) => e.name), ["a/", "a/b.txt", "a/empty"])
  assert.ok(out[1].data.equals(data))
  assert.equal(out[2].data.length, 0)
})
