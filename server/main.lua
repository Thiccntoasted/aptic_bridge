-- Start-up: say what was found, warn about anything the owner must fix, then
-- run the heartbeat loop. Everything else lives in the other server/ files.

Aptic = Aptic or {}

local EXPECTED_NAME = 'aptic_bridge'

function Aptic.boot()
  local log = Aptic.log
  local name = GetCurrentResourceName()
  if name ~= EXPECTED_NAME then
    log.warn('This resource is named "%s". Keep the folder named %s: its stored state (instance id) is kept per resource name.',
      name, EXPECTED_NAME)
  end

  local cfg = Aptic.convars.read()
  local cap = Aptic.capability.detect()
  log.info('aptic_bridge %s starting. Framework/inventory: %s.', Aptic.identity.version(), Aptic.capability.describe(cap))
  if cap.support == 'unsupported' then
    log.warn('%s. Heartbeats still run so the dashboard shows the server, but snapshots will not upload.', cap.reason)
  end
  if cfg.endpoint.state ~= 'ok' then
    log.error('aptic_endpoint is not usable: %s.', cfg.endpoint.reason)
  elseif cfg.endpoint.custom then
    log.info('Endpoint: %s', cfg.endpoint.url)
  end
  if not Aptic.identity.instance_id() then
    log.error('transport.js did not load: no HTTP and no random ids. Check the server console for JavaScript errors.')
  end

  Aptic.status.register()
  Aptic.heartbeat.start()
end

CreateThread(function()
  -- Let transport.js register its exports before the first call.
  Wait(0)
  Aptic.boot()
end)
