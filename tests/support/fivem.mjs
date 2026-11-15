// Runs aptic_bridge's Lua under real Lua 5.4 (wasmoon: the reference Lua
// interpreter compiled to WebAssembly) with FiveM natives stubbed, and loads
// server/transport.js the way FXServer would: as a script with FiveM globals
// (exports, GetConvar, ...) in scope. Lua's exports[...] calls reach the real
// transport.js exports.
//
// Scripts load in the order fxmanifest.lua lists them, so tests run the
// same files, in the same order, as the server.

import { readFileSync, readdirSync } from "node:fs"
import { createRequire } from "node:module"
import { dirname, join, relative } from "node:path"
import { fileURLToPath } from "node:url"
import vm from "node:vm"

import { LuaFactory } from "wasmoon"

export const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..")
const require = createRequire(import.meta.url)

/** Every server_scripts entry in fxmanifest.lua, in order, including
 * other resources' files (`@oxmysql/lib/MySQL.lua`). */
export function manifestEntries() {
  const manifest = readFileSync(join(ROOT, "fxmanifest.lua"), "utf8")
  const block = manifest.match(/server_scripts\s*\{([\s\S]*?)\}/)
  if (!block) throw new Error("fxmanifest.lua has no server_scripts block")
  return [...block[1].matchAll(/'([^']+)'/g)].map((m) => m[1])
}

/** This resource's own server_scripts, in order. Files from other
 * resources (`@oxmysql/...`) are left out: tests stub what they provide. */
export function manifestScripts() {
  return manifestEntries().filter((s) => !s.startsWith("@"))
}

const posix = (p) => p.split("\\").join("/")

function luaFiles(dir) {
  return readdirSync(join(ROOT, dir))
    .filter((f) => f.endsWith(".lua"))
    .map((f) => posix(join(dir, f)))
}

/**
 * A fresh Lua state with the stubs, the test helpers and every manifest
 * script loaded. `extra` lists more Lua files (relative to the repo) to load
 * afterwards, such as a test file.
 */
export async function createResource({ extra = [] } = {}) {
  const factory = new LuaFactory()
  const scripts = manifestScripts()
  // tests/fixtures holds Lua data files that tests load with dofile().
  const files = new Set([
    ...scripts.filter((s) => s.endsWith(".lua")),
    ...luaFiles("tests/support"),
    ...luaFiles("tests/fixtures"),
    ...extra,
  ])
  for (const file of files)
    await factory.mountFile(file, readFileSync(join(ROOT, file), "utf8"))

  const lua = await factory.createEngine({
    injectObjects: false,
    enableProxy: false,
  })
  lua.doStringSync('dofile("tests/support/fivem_stubs.lua")')
  lua.doStringSync('dofile("tests/support/lua_runner.lua")')
  lua.doStringSync('dofile("tests/support/helpers.lua")')

  // transport.js, with FiveM's globals backed by the Lua stubs so both
  // runtimes see the same convars, as they do on a real server.
  const jsExports = {}
  const luaGlobal = (name) => lua.global.get(name)
  const context = vm.createContext({
    require,
    Buffer,
    URL,
    setTimeout,
    clearTimeout,
    exports: (name, fn) => {
      jsExports[name] = fn
    },
    GetConvar: (name, fallback) => luaGlobal("GetConvar")(name, fallback),
    GetCurrentResourceName: () => "aptic_bridge",
    GetResourceMetadata: (res, key, i) =>
      luaGlobal("GetResourceMetadata")(res, key, i),
  })
  for (const script of scripts.filter((s) => s.endsWith(".js"))) {
    vm.runInContext(readFileSync(join(ROOT, script), "utf8"), context, {
      filename: script,
    })
  }
  lua.global.set("__js_export", (name, ...args) => {
    const fn = jsExports[name]
    if (!fn) throw new Error(`no JS export ${name}`)
    return fn(...args)
  })

  for (const script of scripts.filter((s) => s.endsWith(".lua")))
    lua.doStringSync(`dofile(${JSON.stringify(script)})`)
  for (const file of extra) lua.doStringSync(`dofile(${JSON.stringify(file)})`)

  return {
    lua,
    jsExports,
    /** Run Lua and return its value. */
    run: (code) => lua.doStringSync(code),
    close: () => lua.global.close(),
  }
}

/** Lua/JS values pass through wasmoon only without nulls. */
export function withoutNulls(value) {
  return JSON.parse(JSON.stringify(value), (_k, v) =>
    v === null ? undefined : v
  )
}

export const rel = (p) => posix(relative(ROOT, p))
