fx_version 'cerulean'
game 'gta5'
lua54 'yes'
server_only 'yes'

name 'aptic_bridge'
description 'Reports a roleplay server\'s economy to Aptic (heartbeat in this version).'
author 'Aptic Analytics'
version '0.1.0'

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
  'server/main.lua',
}
