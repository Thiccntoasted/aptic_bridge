fx_version 'cerulean'
game 'gta5'
lua54 'yes'
server_only 'yes'

dependency 'oxmysql'

name 'aptic_bridge'
description 'Uploads a roleplay server\'s economy (characters, balances, vehicles, jobs) to Aptic. Read-only, hashed player ids, verified TLS.'
author 'Aptic Analytics'
version '0.1.0'
license 'MIT'

-- Load order matters: transport.js registers the exports the Lua side calls,
-- config.lua defines defaults, and main.lua starts everything.
server_scripts {
  'server/transport.js',
  'config.lua',
  'server/log.lua',
  'server/time.lua',
  'server/convars.lua',
  'server/capability.lua',
  'server/transport.lua',
  'server/identity.lua',
  'server/policy.lua',
  'server/heartbeat.lua',
  'server/status.lua',
  -- collectors (M2)
  '@oxmysql/lib/MySQL.lua',
  'server/adapters/common.lua',
  'server/validate.lua',
  'server/hashing.lua',
  'server/txadmin.lua',
  'server/adapters/fw_qbox.lua',
  'server/adapters/fw_qbcore.lua',
  'server/adapters/inv_ox.lua',
  'server/adapters/inv_qb.lua',
  'server/collector.lua',
  -- upload engine (M3)
  'server/chunker.lua',
  'server/store.lua',
  'server/uploader.lua',
  'server/scheduler.lua',
  'server/selfcheck.lua',  -- aptic validate
  'server/main.lua',
}
