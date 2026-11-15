-- A Qbox (qbx_core 1.24.1) + ox_inventory 2.44.1 server, as the database
-- and qbx_core's exports would return it. Rows follow qbx_core.sql and
-- qbx_vehicles' vehicles.sql; JSON columns are the text qbx_core writes
-- (json.encode of PlayerData.money / charinfo / job / gang). Timestamps are
-- given as the UNIX_TIMESTAMP() aliases the collector selects. Columns the
-- collector must never read (name, position, phone_number, metadata,
-- inventory, mods, coords) are filled with recognisable values so the
-- privacy tests can look for them.
--
-- All identifiers below are made up.

local NOW = os.time()

local L = {
  marcus = 'license2:a1b2c3d4e5f60718293a4b5c6d7e8f9012345678',  -- two characters
  juniper = 'license2:c3d4e5f60718293a4b5c6d7e8f9012345678a1b2', -- online
  half = 'license2:d4e5f60718293a4b5c6d7e8f9012345678a1b2c3',    -- txAdmin playTime not an integer
  nobody = 'license2:e5f60718293a4b5c6d7e8f9012345678a1b2c3d4',  -- not in txAdmin
  fresh = 'license2:f60718293a4b5c6d7e8f9012345678a1b2c3d4e5',   -- online, not saved yet
  late = 'license2:0718293a4b5c6d7e8f9012345678a1b2c3d4e5f6',    -- joined txAdmin after this char was last seen
  ahead = 'license2:18293a4b5c6d7e8f9012345678a1b2c3d4e5f607',   -- DB clock ahead
}

local function job(name, label, level, grade_name)
  return ('{"name":"%s","label":"%s","payment":50,"type":"none","onduty":true,"isboss":false,"grade":{"name":"%s","level":%d}}')
    :format(name, label, grade_name, level)
end
local NO_GANG = '{"name":"none","label":"No Gang","isboss":false,"grade":{"name":"Unaffiliated","level":0}}'

local function player(t)
  local row = {
    id = t.id,
    userId = t.id,
    citizenid = t.citizenid,
    cid = 1,
    license = t.license,
    name = t.fivem_name or 'xXGamer' .. t.id .. 'Xx',
    money = t.money,
    charinfo = t.charinfo,
    job = t.job,
    gang = t.gang or NO_GANG,
    position = '{"x":215.31,"y":-810.12,"z":30.73,"w":160.0}',
    metadata = '{"phone":"5550142","bloodtype":"O+","fingerprint":"FP-77AC-1029","callsign":"NO CALLSIGN"}',
    inventory = '[{"name":"phone","count":1,"slot":1,"metadata":{"phone":"5550142"}}]',
    phone_number = '5550142',
    last_updated_ts = t.last_updated,
    last_logged_out_ts = t.last_logged_out,
  }
  return row
end

local F = { licenses = L, now = NOW }

F.columns = {
  players = { 'id', 'userId', 'citizenid', 'cid', 'license', 'name', 'money', 'charinfo', 'job', 'gang',
    'position', 'metadata', 'inventory', 'phone_number', 'last_updated', 'last_logged_out' },
  player_vehicles = { 'id', 'license', 'citizenid', 'vehicle', 'hash', 'mods', 'plate', 'fakeplate', 'garage',
    'fuel', 'engine', 'body', 'state', 'depotprice', 'drivingdistance', 'status', 'coords' },
  ox_inventory = { 'owner', 'name', 'data', 'lastupdated' },
  player_groups = { 'citizenid', 'group', 'type', 'grade' },
}

F.players = {
  player({
    id = 1, citizenid = 'ABC12345', license = L.marcus, fivem_name = 'xXMarcusGamerXx',
    money = '{"cash":2500,"bank":48200,"crypto":0}',
    charinfo = '{"firstname":"Marcus","lastname":"Reyes","birthdate":"1994-05-12","gender":0,"nationality":"American","phone":"5550142","account":"US0912345678"}',
    job = job('police', 'LSPD', 2, 'Sergeant'),
    last_updated = 1794344700, last_logged_out = 1794344700,         -- 2026-11-10T21:05:00Z
  }),
  player({
    id = 2, citizenid = 'BCD23456', license = L.marcus,
    money = '{"cash":120,"bank":3100,"crypto":0}',
    charinfo = '{"firstname":"Lena","lastname":"Novak","birthdate":"1999-01-02","gender":1,"nationality":"Czech","phone":"5550199","account":"US0999999999"}',
    job = job('unemployed', 'Civilian', 0, 'Freelancer'),
    last_updated = 1794474900, last_logged_out = 1793557800,         -- logged out 2026-11-01T18:30:00Z, row touched later
  }),
  player({
    id = 3, citizenid = 'CDE34567', license = L.juniper,
    money = '{"cash":10,"bank":100,"crypto":0}',                       -- stale: the live values win
    charinfo = '{"firstname":"Juniper","lastname":"Hale"}',
    job = job('unemployed', 'Civilian', 0, 'Freelancer'),
    last_updated = 1792515600, last_logged_out = 1792515600,
  }),
  player({
    id = 4, citizenid = 'DEF45678', license = L.half,
    money = '{"cash":0,"bank":640,"crypto":0}',
    charinfo = nil,                                                   -- missing charinfo
    job = '{not json',                                                -- malformed job
    last_updated = 1794474900, last_logged_out = nil,                 -- never logged out: last_updated
  }),
  player({
    id = 5, citizenid = 'EFG56789', license = L.nobody,
    money = '{"cash":5,',                                             -- malformed money
    charinfo = '{"firstname":"  Zo\\u00eb \\ud83c\\udf1f","lastname":"Star\\nLight"}', -- emoji, control char
    job = job('ambulance', 'EMS', 3, ''),
    last_updated = 1794696000, last_logged_out = 1794696000,
  }),
  player({
    id = 6, citizenid = 'FGH00001', license = L.late,
    money = '{"cash":1,"bank":2,"crypto":0}',
    charinfo = '{"firstname":"Old","lastname":"Timer"}',
    job = job('unemployed', 'Civilian', 0, 'Freelancer'),
    last_updated = 1768003200, last_logged_out = 1768003200,          -- 2026-01-10, before txAdmin's first join
  }),
  player({
    id = 7, citizenid = 'GHI00002', license = L.ahead,
    money = '{"cash":3,"bank":4,"crypto":0}',
    charinfo = '{"firstname":"Clock","lastname":"Skew"}',
    job = job('unemployed', 'Civilian', 0, 'Freelancer'),
    last_updated = NOW + 3600, last_logged_out = NOW + 3600,          -- DB host clock an hour ahead
  }),
}

-- exports.qbx_core:GetPlayersData(): PlayerData of loaded players.
F.online = {
  {
    citizenid = 'CDE34567', license = L.juniper, cid = 1, source = 3, name = 'JuniperTx',
    charinfo = { firstname = 'Juniper', lastname = 'Hale', phone = '5550123', account = 'US0911111111' },
    money = { cash = 7300, bank = 91000, crypto = 12 },
    job = { name = 'mechanic', label = 'Mechanic', payment = 75, onduty = true, isboss = false,
      grade = { name = 'Mechanic', level = 1 } },
    gang = { name = 'ballas', label = 'Ballas', isboss = false, grade = { name = 'Recruit', level = 0 } },
    position = { x = 215.31, y = -810.12, z = 30.73 },
    metadata = { phone = '5550123', fingerprint = 'FP-1111' },
  },
  {
    citizenid = 'ZZZ99999', license = L.fresh, cid = 1, source = 7, name = 'FreshTx',
    charinfo = { firstname = 'Nia', lastname = 'Okafor' },
    money = { cash = 500, bank = 5000, crypto = 0 },
    job = { name = 'unemployed', label = 'Civilian', grade = { name = 'Freelancer', level = 0 } },
    gang = { name = 'none', label = 'No Gang', grade = { name = 'Unaffiliated', level = 0 } },
  },
}

-- exports.qbx_core:GetJobs() / GetGangs(): grades keyed by integer level.
F.jobs = {
  unemployed = { label = 'Civilian', defaultDuty = true, offDutyPay = false,
    grades = { [0] = { name = 'Freelancer', payment = 10 } } },
  police = { label = 'LSPD', type = 'leo', defaultDuty = true, offDutyPay = false,
    grades = {
      [0] = { name = 'Recruit', payment = 50 }, [1] = { name = 'Officer', payment = 75 },
      [2] = { name = 'Sergeant', payment = 100 }, [3] = { name = 'Lieutenant', payment = 125 },
      [4] = { name = 'Chief', isboss = true, bankAuth = true, payment = 150 },
    } },
  mechanic = { label = 'Mechanic', type = 'mechanic',
    grades = { [0] = { name = 'Trainee' }, [1] = { name = 'Mechanic' }, [2] = { name = 'Lead' },
      [4] = { name = 'Owner', isboss = true } } },                    -- sparse: no level 3
  ambulance = { label = 'EMS', type = 'ems',
    grades = { [0] = { name = 'Recruit' }, [3] = { payment = 120 } } }, -- a grade without a name
}
F.gangs = {
  none = { label = 'No Gang', grades = { [0] = { name = 'Unaffiliated' } } },
  ballas = { label = 'Ballas', grades = { [0] = { name = 'Recruit' }, [1] = { name = 'Enforcer' },
    [2] = { name = 'Shot Caller' }, [3] = { name = 'Boss', isboss = true } } },
}

local function vehicle(t)
  return {
    id = t.id, license = t.license or L.marcus, citizenid = t.citizenid, vehicle = t.vehicle, hash = t.hash,
    mods = '{"plate":"' .. tostring(t.plate) .. '","modEngine":3}', plate = t.plate, fakeplate = nil,
    garage = t.garage, fuel = 80, engine = 1000.0, body = 990.5, state = t.state, depotprice = 0,
    drivingdistance = 1200, status = '{}', coords = '{"x":-1037.2,"y":-2737.6,"z":20.2}',
  }
end

-- qbx_vehicles player_vehicles: plate UNIQUE; state 0 out, 1 garaged, 2 impounded.
F.vehicles = {
  vehicle({ id = 1, citizenid = 'ABC12345', vehicle = 'police3', hash = '1912215274', plate = 'LSPD 042', garage = 'mrpd', state = 1 }),
  vehicle({ id = 2, citizenid = 'ABC12345', vehicle = 'sultan', hash = '970598228', plate = 'MRC 1994', garage = nil, state = 0 }),
  vehicle({ id = 3, citizenid = 'CDE34567', vehicle = 'futo', hash = '2016857647', plate = ' jun 77 ', garage = nil, state = 2 }),
  vehicle({ id = 4, citizenid = 'abc12345', vehicle = 'bati', hash = '4180675781', plate = 'BATI 01', garage = 'pillboxgarage', state = 1 }), -- case-only citizenid mismatch
  vehicle({ id = 5, citizenid = 'GONE0001', vehicle = 'blista', hash = '1039032026', plate = 'GONE 01', garage = 'legion', state = 1 }),     -- owner deleted
  vehicle({ id = 6, citizenid = 'BCD23456', vehicle = 'faggio', hash = '55628203', plate = 'LENA 99', garage = 'legion', state = 5 }),     -- unknown state code
  vehicle({ id = 7, citizenid = 'DEF45678', vehicle = nil, hash = '3078201489', plate = 'HASH 01', garage = 'legion', state = 1 }),       -- model from hash
}

return F
