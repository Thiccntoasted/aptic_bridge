// Builds the release zip: dist/aptic_bridge-<version>.zip, holding one
// top-level aptic_bridge/ folder with only what a server needs:
//
//   fxmanifest.lua, config.lua, server/ (every file), LICENSE, README.md,
//   INSTALL.md, CHANGELOG.md
//
// Nothing else: no tests/, scripts/, node_modules/, package*.json, cache/,
// dist/ or dotfiles. The version comes from fxmanifest.lua and must match
// package.json and have a CHANGELOG.md section.
//
// Plain Node, no dependencies: entries are deflated with node:zlib and
// written in the ZIP format by hand. The zip is reproducible: entries are
// sorted and every timestamp is the last commit's time (or
// SOURCE_DATE_EPOCH, or 2026-01-01 outside git).
//
//   npm run release            writes dist/aptic_bridge-<version>.zip
//   node scripts/release.mjs --list   also prints the entries

import { execFileSync } from "node:child_process"
import { mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs"
import { dirname, join, relative } from "node:path"
import { fileURLToPath, pathToFileURL } from "node:url"
import zlib from "node:zlib"

export const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..")
export const FOLDER = "aptic_bridge"
const TOP_FILES = ["fxmanifest.lua", "config.lua", "LICENSE", "README.md", "INSTALL.md", "CHANGELOG.md"]
const TOP_DIRS = ["server"]

const posix = (p) => p.split("\\").join("/")

/** The resource version from fxmanifest.lua, checked against package.json and CHANGELOG.md. */
export function releaseVersion(root = ROOT) {
  const manifest = readFileSync(join(root, "fxmanifest.lua"), "utf8")
  const m = manifest.match(/^version '([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?)'$/m)
  if (!m) throw new Error("fxmanifest.lua has no version 'x.y.z' line")
  const version = m[1]
  const pkg = JSON.parse(readFileSync(join(root, "package.json"), "utf8"))
  if (pkg.version !== version) throw new Error(`package.json is ${pkg.version}, fxmanifest.lua is ${version}`)
  const changelog = readFileSync(join(root, "CHANGELOG.md"), "utf8")
  if (!new RegExp(`^## ${version.replace(/\./g, "\\.")}\\b`, "m").test(changelog))
    throw new Error(`CHANGELOG.md has no "## ${version}" section`)
  return version
}

/** Repository-relative paths of every file that goes in the zip, sorted. */
export function releaseFiles(root = ROOT) {
  const out = []
  const walk = (dir) => {
    for (const entry of readdirSync(join(root, dir), { withFileTypes: true })) {
      if (entry.name.startsWith(".")) continue
      const path = posix(join(dir, entry.name))
      if (entry.isDirectory()) walk(path)
      else if (entry.isFile()) out.push(path)
    }
  }
  for (const f of TOP_FILES) {
    if (!statSync(join(root, f), { throwIfNoEntry: false })?.isFile()) throw new Error(`${f} is missing`)
    out.push(f)
  }
  for (const d of TOP_DIRS) walk(d)
  return out.sort()
}

function sourceDate(root) {
  if (process.env.SOURCE_DATE_EPOCH) return new Date(Number(process.env.SOURCE_DATE_EPOCH) * 1000)
  try {
    const t = execFileSync("git", ["log", "-1", "--format=%ct"], { cwd: root, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim()
    if (/^\d+$/.test(t)) return new Date(Number(t) * 1000)
  } catch {}
  return new Date(Date.UTC(2026, 0, 1))
}

// ZIP writing -----------------------------------------------------------------

const CRC_TABLE = (() => {
  const t = new Uint32Array(256)
  for (let n = 0; n < 256; n++) {
    let c = n
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1
    t[n] = c >>> 0
  }
  return t
})()

export function crc32(buf) {
  let c = 0xffffffff
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8)
  return (c ^ 0xffffffff) >>> 0
}

function dosTime(date) {
  const year = Math.max(1980, date.getUTCFullYear())
  return {
    time: (date.getUTCHours() << 11) | (date.getUTCMinutes() << 5) | Math.floor(date.getUTCSeconds() / 2),
    date: ((year - 1980) << 9) | ((date.getUTCMonth() + 1) << 5) | date.getUTCDate(),
  }
}

/** A ZIP archive (deflate, UTF-8 names, Unix permissions) of `entries`:
 *  [{ name, data?: Buffer }] where a name ending in "/" is a folder. */
export function zip(entries, date) {
  const { time, date: day } = dosTime(date)
  const locals = []
  const centrals = []
  let offset = 0
  for (const e of entries) {
    const dir = e.name.endsWith("/")
    const data = dir ? Buffer.alloc(0) : e.data
    const packed = dir ? data : zlib.deflateRawSync(data, { level: 9 })
    const method = dir ? 0 : 8
    const crc = dir ? 0 : crc32(data)
    const name = Buffer.from(e.name, "utf8")
    const local = Buffer.alloc(30)
    local.writeUInt32LE(0x04034b50, 0)
    local.writeUInt16LE(20, 4)        // version needed
    local.writeUInt16LE(0x0800, 6)    // UTF-8 names
    local.writeUInt16LE(method, 8)
    local.writeUInt16LE(time, 10)
    local.writeUInt16LE(day, 12)
    local.writeUInt32LE(crc, 14)
    local.writeUInt32LE(packed.length, 18)
    local.writeUInt32LE(data.length, 22)
    local.writeUInt16LE(name.length, 26)
    local.writeUInt16LE(0, 28)
    locals.push(local, name, packed)

    const central = Buffer.alloc(46)
    central.writeUInt32LE(0x02014b50, 0)
    central.writeUInt16LE((3 << 8) | 20, 4) // made by Unix, so the permissions below apply
    central.writeUInt16LE(20, 6)
    central.writeUInt16LE(0x0800, 8)
    central.writeUInt16LE(method, 10)
    central.writeUInt16LE(time, 12)
    central.writeUInt16LE(day, 14)
    central.writeUInt32LE(crc, 16)
    central.writeUInt32LE(packed.length, 20)
    central.writeUInt32LE(data.length, 24)
    central.writeUInt16LE(name.length, 28)
    central.writeUInt16LE(0, 30)  // extra
    central.writeUInt16LE(0, 32)  // comment
    central.writeUInt16LE(0, 34)  // disk
    central.writeUInt16LE(0, 36)  // internal attributes
    central.writeUInt32LE((((dir ? 0o40755 : 0o100644) << 16) | (dir ? 0x10 : 0)) >>> 0, 38)
    central.writeUInt32LE(offset, 42)
    centrals.push(central, name)
    offset += local.length + name.length + packed.length
  }
  const cd = Buffer.concat(centrals)
  const end = Buffer.alloc(22)
  end.writeUInt32LE(0x06054b50, 0)
  end.writeUInt16LE(0, 4)
  end.writeUInt16LE(0, 6)
  end.writeUInt16LE(entries.length, 8)
  end.writeUInt16LE(entries.length, 10)
  end.writeUInt32LE(cd.length, 12)
  end.writeUInt32LE(offset, 16)
  end.writeUInt16LE(0, 20)
  return Buffer.concat([...locals, cd, end])
}

/** Read a ZIP: [{ name, data, crc, method }] from its central directory. */
export function unzip(buf) {
  let eocd = -1
  for (let i = buf.length - 22; i >= Math.max(0, buf.length - 22 - 65535); i--) {
    if (buf.readUInt32LE(i) === 0x06054b50) { eocd = i; break }
  }
  if (eocd < 0) throw new Error("not a zip: no end of central directory")
  const count = buf.readUInt16LE(eocd + 10)
  let p = buf.readUInt32LE(eocd + 16)
  const out = []
  for (let n = 0; n < count; n++) {
    if (buf.readUInt32LE(p) !== 0x02014b50) throw new Error("bad central directory entry")
    const method = buf.readUInt16LE(p + 10)
    const crc = buf.readUInt32LE(p + 16)
    const packedSize = buf.readUInt32LE(p + 20)
    const size = buf.readUInt32LE(p + 24)
    const nameLen = buf.readUInt16LE(p + 28)
    const extraLen = buf.readUInt16LE(p + 30)
    const commentLen = buf.readUInt16LE(p + 32)
    const mode = buf.readUInt32LE(p + 38) >>> 16
    const local = buf.readUInt32LE(p + 42)
    const name = buf.subarray(p + 46, p + 46 + nameLen).toString("utf8")
    if (buf.readUInt32LE(local) !== 0x04034b50) throw new Error(`bad local header for ${name}`)
    const start = local + 30 + buf.readUInt16LE(local + 26) + buf.readUInt16LE(local + 28)
    const packed = buf.subarray(start, start + packedSize)
    const data = method === 8 ? zlib.inflateRawSync(packed) : Buffer.from(packed)
    if (data.length !== size) throw new Error(`size mismatch for ${name}`)
    if (crc32(data) !== crc) throw new Error(`crc mismatch for ${name}`)
    out.push({ name, data, crc, method, mode })
    p += 46 + nameLen + extraLen + commentLen
  }
  return out
}

// Build ----------------------------------------------------------------------

/** Build the zip into `outDir` (default dist/). Returns { path, version, entries }. */
export function buildRelease({ root = ROOT, outDir = join(root, "dist") } = {}) {
  const version = releaseVersion(root)
  const files = releaseFiles(root)
  const dirs = new Set([`${FOLDER}/`])
  for (const f of files) {
    const parts = f.split("/")
    for (let i = 1; i < parts.length; i++) dirs.add(`${FOLDER}/${parts.slice(0, i).join("/")}/`)
  }
  const entries = [
    ...[...dirs].map((name) => ({ name })),
    ...files.map((f) => ({ name: `${FOLDER}/${f}`, data: readFileSync(join(root, f)) })),
  ].sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0))
  const buf = zip(entries, sourceDate(root))
  mkdirSync(outDir, { recursive: true })
  const path = join(outDir, `${FOLDER}-${version}.zip`)
  writeFileSync(path, buf)
  return { path, version, entries: entries.map((e) => e.name), bytes: buf.length }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const { path, version, entries, bytes } = buildRelease()
  if (process.argv.includes("--list")) for (const e of entries) console.log(e)
  console.log(`aptic_bridge ${version}: ${posix(relative(ROOT, path))} (${entries.length} entries, ${(bytes / 1024).toFixed(1)} KiB)`)
}
