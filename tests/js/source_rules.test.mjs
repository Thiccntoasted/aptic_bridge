// Grep-style rules over the shipped source. They back the runtime tests:
// output goes through log.lua only, transport.js never logs, nothing uses
// PerformHttpRequest (D4), and config uses `set`, never `setr`/`sets`.

import assert from "node:assert/strict"
import { readFileSync, readdirSync } from "node:fs"
import { join } from "node:path"
import { test } from "node:test"

import { ROOT, manifestScripts } from "../support/fivem.mjs"

const shipped = manifestScripts().concat(["fxmanifest.lua"])
const source = (file) => readFileSync(join(ROOT, file), "utf8")
// Comments may mention what the code avoids; only code counts.
const code = (file) =>
  file.endsWith(".js")
    ? source(file).replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/.*$/gm, "")
    : source(file).replace(/--\[\[[\s\S]*?\]\]/g, "").replace(/--.*$/gm, "")

test("every server script is listed in fxmanifest.lua", () => {
  const onDisk = readdirSync(join(ROOT, "server"))
    .filter((f) => f.endsWith(".lua") || f.endsWith(".js"))
    .map((f) => `server/${f}`)
  for (const file of onDisk) assert.ok(shipped.includes(file), `${file} is not in server_scripts`)
})

test("only server/log.lua calls print", () => {
  for (const file of shipped.filter((f) => f.endsWith(".lua") && f !== "server/log.lua")) {
    assert.doesNotMatch(code(file), /(^|[^\w.:])print\s*\(/, file)
  }
})

test("transport.js never logs", () => {
  assert.doesNotMatch(code("server/transport.js"), /console\.|process\.stdout|process\.stderr/)
})

test("nothing uses PerformHttpRequest", () => {
  for (const file of shipped) assert.doesNotMatch(code(file), /PerformHttpRequest/, file)
})

test("the manifest is server-only Lua 5.4 on cerulean", () => {
  const manifest = source("fxmanifest.lua")
  assert.match(manifest, /^fx_version 'cerulean'$/m)
  assert.match(manifest, /^lua54 'yes'$/m)
  assert.match(manifest, /^server_only 'yes'$/m)
  assert.doesNotMatch(manifest, /client_script/)
})

test("docs and config tell owners to use set, never setr or sets", () => {
  for (const file of ["README.md", "config.lua"]) {
    const text = source(file)
    assert.match(text, /set aptic_api_key "/, file)
    assert.doesNotMatch(text, /^\s*sets?r\s+aptic_/m, `${file} shows setr`)
    assert.doesNotMatch(text, /^\s*sets\s+aptic_/m, `${file} shows sets`)
  }
})

test("no file in the repository holds a real-looking key", () => {
  // Test keys are spelled out in tests; anything else matching the key shape
  // would be a leaked credential.
  const allowed = new Set([
    "apt_ing_TESTkeyAAAAbbbbCCCCddddEEEEffffGGGGhhhh1234",
    "apt_ing_ROTATEDzzzzYYYYxxxxWWWWvvvvUUUUttttSSSS9876",
  ])
  const walk = (dir) =>
    readdirSync(join(ROOT, dir), { withFileTypes: true }).flatMap((e) => {
      if ([".git", "node_modules", "cache"].includes(e.name)) return []
      const path = dir ? `${dir}/${e.name}` : e.name
      return e.isDirectory() ? walk(path) : [path]
    })
  for (const file of walk("")) {
    if (!/\.(lua|js|mjs|md|cfg|json)$/.test(file)) continue
    for (const match of source(file).matchAll(/apt_ing_[A-Za-z0-9_-]{43}/g))
      assert.ok(allowed.has(match[0]), `${file} contains a key-shaped value`)
  }
})
