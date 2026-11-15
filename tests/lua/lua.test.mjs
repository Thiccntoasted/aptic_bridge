// Runs every tests/lua/*_test.lua case under real Lua 5.4, each case in a
// fresh Lua state with the whole resource loaded.

import assert from "node:assert/strict"
import { readdirSync } from "node:fs"
import { join } from "node:path"
import { test } from "node:test"

import { ROOT, createResource } from "../support/fivem.mjs"

const files = readdirSync(join(ROOT, "tests", "lua"))
  .filter((f) => f.endsWith("_test.lua"))
  .sort()

for (const file of files) {
  const path = `tests/lua/${file}`
  test(file, async (t) => {
    const lister = await createResource({ extra: [path] })
    const names = lister.run("return T.names()")
    lister.close()
    assert.ok(Array.isArray(names) && names.length > 0, `${file} has no tests`)
    for (let i = 0; i < names.length; i++) {
      await t.test(names[i], async () => {
        const resource = await createResource({ extra: [path] })
        try {
          const outcome = resource.run(`return T.run(${i + 1})`)
          assert.equal(outcome, "ok", outcome)
        } finally {
          resource.close()
        }
      })
    }
  })
}
