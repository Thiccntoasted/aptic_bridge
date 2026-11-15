// The collectors are read-only (plan §3.2, §8.2): no write statement and no
// write API anywhere in the shipped source. The Lua collector tests also
// record every query the fake oxmysql receives and check each one is a
// SELECT with a LIMIT.

import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { test } from "node:test"

import { ROOT, manifestEntries, manifestScripts } from "../support/fivem.mjs"

const shipped = manifestScripts()
const source = (file) => readFileSync(join(ROOT, file), "utf8")
const stripComments = (file) =>
  file.endsWith(".js")
    ? source(file).replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/.*$/gm, "")
    : source(file).replace(/--\[\[[\s\S]*?\]\]/g, "").replace(/--.*$/gm, "")

test("no SQL write keyword appears in any shipped file", () => {
  const keywords = /\b(INSERT|UPDATE|DELETE|REPLACE|ALTER|DROP|CREATE|TRUNCATE|GRANT)\b/
  for (const file of shipped) {
    // Uppercase anywhere, comments included: SQL keywords have no business here.
    assert.doesNotMatch(source(file), keywords, file)
  }
})

test("no write statement in any casing inside code", () => {
  const statements =
    /\b(insert\s+(ignore\s+)?into|update\s+[`\w]+\s+set|delete\s+from|replace\s+into|alter\s+table|drop\s+(table|database)|create\s+(table|database|index)|truncate\s+table)\b/i
  for (const file of shipped) assert.doesNotMatch(stripComments(file), statements, file)
})

test("oxmysql is used through MySQL.query.await only", () => {
  for (const file of shipped) {
    const code = stripComments(file)
    for (const m of code.matchAll(/\bMySQL\.(\w+)(?:\.(\w+))?/g))
      assert.equal(`${m[1]}.${m[2]}`, "query.await", `${file} uses MySQL.${m[1]}${m[2] ? "." + m[2] : ""}`)
  }
})

test("every SQL string in the adapters is a SELECT with a LIMIT", () => {
  const common = stripComments("server/adapters/common.lua")
  // Each assembled statement starts with 'SELECT ' and ends with 'LIMIT ...'.
  const starts = [...common.matchAll(/'SELECT [^']*'/g)].map((m) => m[0])
  assert.ok(starts.length >= 3, "the column probe, players and vehicles queries")
  const limits = [...common.matchAll(/LIMIT (\?|\d+)'/g)]
  assert.equal(limits.length, starts.length, "one LIMIT per SELECT")
  assert.doesNotMatch(common, /SELECT \*/)
})

test("the manifest depends on oxmysql and loads its library", () => {
  const manifest = source("fxmanifest.lua")
  assert.match(manifest, /^dependency 'oxmysql'$/m)
  assert.ok(manifestEntries().includes("@oxmysql/lib/MySQL.lua"))
})
