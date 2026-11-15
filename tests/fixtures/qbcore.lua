-- A QBCore (qb-core 1.3.0) + qb-inventory 2.2.3 server, as the database and
-- QBCore's core object would return it. Rows follow qbcore.sql and
-- qb-garages' player_vehicles.sql (plate not unique). JSON columns are the
-- text QBCore writes. players.license is `license:<hex>`. QBCore has no
-- last_logged_out column. Columns the collector must never read are filled
-- with recognisable values for the privacy tests.
--
-- All identifiers below are made up.

local L = {
  dario = 'license:1a2b3c4d5e6f708192a3b4c5d6e7f80910111213',
  newcomer = 'license:2b3c4d5e6f708192a3b4c5d6e7f8091011121314',
  regular = 'license:3c4d5e6f708192a3b4c5d6e7f809101112131415',
  unknown = 'license:4d5e6f708192a3b4c5d6e7f80910111213141516',
}

local function player(t)
  return {
    id = t.id,
    citizenid = t.citizenid,
    cid = 1,
    license = t.license,
    name = t.fivem_name or ('QBGamer' .. t.id),
    money = t.money,
    charinfo = t.charinfo,
    job = t.job,
    gang = t.gang,
    position = '{"x":-269.4,"y":-955.3,"z":31.2,"w":205.8}',
    metadata = '{"phone":"5550188","fingerprint":"FP-99AA","walletid":"QB-WALLET-1"}',
    inventory = '[{"name":"id_card","amount":1,"info":{"citizenid":"' .. t.citizenid .. '","firstname":"X"},"slot":1,"type":"item"}]',
    phone_number = '5550188',
    last_updated_ts = t.last_updated,
  }
end

local F = { licenses = L }

F.columns = {
  players = { 'id', 'citizenid', 'cid', 'license', 'name', 'money', 'charinfo', 'job', 'gang', 'position',
    'metadata', 'inventory', 'phone_number', 'last_updated' },
  player_vehicles = { 'id', 'license', 'citizenid', 'vehicle', 'hash', 'mods', 'plate', 'fakeplate', 'garage',
    'fuel', 'engine', 'body', 'state', 'depotprice', 'drivingdistance', 'status', 'balance', 'paymentamount',
    'paymentsleft', 'financetime' },
  inventories = { 'id', 'identifier', 'items' },
}

F.players = {
  player({
    id = 1, citizenid = 'QB000001', license = L.dario, fivem_name = 'DarioFiveM',
    -- negative bank (MinusLimit), a custom money type and two codes the contract can't take as-is
    money = '{"cash":350,"bank":-2350,"crypto":0,"casino_chips":500,"BlackMoney":120,"dirty-money":40}',
    charinfo = '{"firstname":"Dario","lastname":"Conti","birthdate":"1990-07-21","gender":0,"nationality":"Italian","phone":"5550188","account":"US06QBCore0001","cid":1}',
    job = '{"name":"police","label":"Law Enforcement","payment":100,"type":"leo","onduty":true,"isboss":false,"grade":{"name":"Sergeant","level":2}}',
    gang = '{"name":"none","label":"No Gang","isboss":false,"grade":{"name":"Unaffiliated","level":0}}',
    last_updated = 1794344700,
  }),
  player({
    id = 2, citizenid = 'QB000002', license = L.newcomer,
    money = '{"cash":500,"bank":5000,"crypto":0}',
    charinfo = '{"firstname":"Ama","lastname":"Mensah"}',
    job = '{"name":"police","label":"Law Enforcement","grade":1}',  -- older rows: grade as a number
    gang = '{"name":"lostmc","label":"The Lost MC","isboss":false,"grade":{"name":"Enforcer","level":1}}',
    last_updated = 1793557800,
  }),
  player({
    id = 3, citizenid = 'QB000003', license = L.regular,
    money = '{"cash":1,"bank":1,"crypto":0}',                       -- stale: the live values win
    charinfo = '{"firstname":"Rosa","lastname":"Diaz"}',
    job = '{"name":"unemployed","label":"Civilian","grade":{"name":"Freelancer","level":0}}',
    gang = nil,
    last_updated = 1792515600,
  }),
  player({
    id = 4, citizenid = 'QB000004', license = L.unknown,
    money = '{"cash":0,"bank":0,"crypto":0}',
    charinfo = '{"firstname":"","lastname":""}',                    -- empty names
    job = '{"name":"mechanic","label":"Mechanic","grade":{"name":"Lead","level":"3"}}', -- level as a string
    gang = '{"name":"none"}',
    last_updated = 1794474900,
  }),
}

-- QBCore.Functions.GetQBPlayers(): source -> Player (PlayerData plus methods).
F.online = {
  [12] = {
    PlayerData = {
      citizenid = 'QB000003', license = L.regular, cid = 1, source = 12, name = 'RosaFiveM',
      charinfo = { firstname = 'Rosa', lastname = 'Diaz', phone = '5550177', account = 'US06QBCore0003' },
      money = { cash = 2200, bank = 64000, crypto = 3 },
      job = { name = 'mechanic', label = 'Mechanic', payment = 75, onduty = true, isboss = true,
        grade = { name = 'Owner', level = 3 } },
      gang = { name = 'none', label = 'No Gang', isboss = false, grade = { name = 'Unaffiliated', level = 0 } },
      position = { x = -269.4, y = -955.3, z = 31.2 },
      metadata = { phone = '5550177' },
      items = { { name = 'id_card', amount = 1, slot = 1 } },
    },
    Functions = {},
  },
}

-- QBCore.Shared.Jobs / .Gangs: grades keyed by strings.
F.jobs = {
  unemployed = { label = 'Civilian', defaultDuty = true, offDutyPay = false,
    grades = { ['0'] = { name = 'Freelancer', payment = 10 } } },
  police = { label = 'Law Enforcement', type = 'leo', defaultDuty = true, offDutyPay = false,
    grades = {
      ['0'] = { name = 'Recruit', payment = 50 }, ['1'] = { name = 'Officer', payment = 75 },
      ['2'] = { name = 'Sergeant', payment = 100 }, ['3'] = { name = 'Lieutenant', payment = 125 },
      ['4'] = { name = 'Chief', isboss = true, payment = 150 },
    } },
  mechanic = { label = 'Mechanic', type = 'mechanic', defaultDuty = true, offDutyPay = false,
    grades = { ['0'] = { name = 'Recruit' }, ['1'] = { name = 'Novice' }, ['3'] = { name = 'Owner', isboss = true },
      ['boss'] = { name = 'Not a level' } } },                       -- sparse, plus a key that isn't a level
}
F.gangs = {
  none = { label = 'No Gang', grades = { ['0'] = { name = 'Unaffiliated' } } },
  lostmc = { label = 'The Lost MC', grades = { ['0'] = { name = 'Recruit' }, ['1'] = { name = 'Enforcer' },
    ['2'] = { name = 'Shot Caller' }, ['3'] = { name = 'Boss', isboss = true } } },
}

local function vehicle(t)
  return {
    id = t.id, license = L.dario, citizenid = t.citizenid, vehicle = t.vehicle, hash = t.hash,
    mods = '{"modEngine":2}', plate = t.plate, fakeplate = nil, garage = t.garage, fuel = 100, engine = 1000.0,
    body = 1000.0, state = t.state, depotprice = 0, drivingdistance = nil, status = nil,
    balance = 0, paymentamount = 0, paymentsleft = 0, financetime = 0,
  }
end

F.vehicles = {
  vehicle({ id = 10, citizenid = 'QB000001', vehicle = 'adder', hash = '3078201489', plate = 'DUPE 01', garage = 'pillboxgarage', state = 1 }),
  vehicle({ id = 11, citizenid = 'QB000002', vehicle = 'bison', hash = '4278019151', plate = 'AMA 2025', garage = nil, state = 0 }),
  vehicle({ id = 14, citizenid = 'QB000002', vehicle = 'zentorno', hash = '2891838741', plate = 'dupe 01 ', garage = nil, state = 2 }), -- same plate, newer id: kept
  vehicle({ id = 15, citizenid = 'QB000003', vehicle = 'rumpo', hash = '1162065741', plate = 'ROSA 3', garage = 'pillboxgarage', state = 1 }),
  vehicle({ id = 16, citizenid = 'QB000001', vehicle = 'faggio', hash = '55628203', plate = 'THISPLATEISWAYTOOLONGFORTHECONTRACT1', garage = 'legion', state = 1 }),
}

return F
