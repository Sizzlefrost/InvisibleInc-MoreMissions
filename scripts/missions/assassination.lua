local array = include( "modules/array" )
local binops = include( "modules/binary_ops" )
local util = include( "modules/util" )
local cdefs = include( "client_defs" )
local simdefs = include( "sim/simdefs" )
local unitdefs = include( "sim/unitdefs" )
local inventory = include( "sim/inventory" )
local simfactory = include( "sim/simfactory" )
local simquery = include( "sim/simquery" )
local mission_util = include( "sim/missions/mission_util" )
local escape_mission = include( "sim/missions/escape_mission" )
local SCRIPTS = include("client/story_scripts")

---------------------------------------------------------------------------------------------
-- Local helpers

----
-- Trigger Definitions

local CEO_DEAD =
{
	trigger = simdefs.TRG_UNIT_KILLED,
	fn = function( sim, evData )
		if evData.unit:hasTag("assassination") then
			evData.corpse:addTag("assassination") --track the body; no rest for the dead -M
			return evData.corpse
		end
	end,
}
local CEO_KO =
{
	trigger = simdefs.TRG_UNIT_KO,
	fn = function( sim, evData )
		if evData.unit:hasTag("assassination") then
			return evData.unit
		end
	end,
}
local CEO_ALERTED =
{
	trigger = simdefs.TRG_UNIT_ALERTED,
	fn = function( sim, evData )
		if evData.unit:hasTag("assassination") then
			return evData.unit
		end
	end,
}
local CEO_ARMING =
{
	trigger = "MM-VIP-ARMING",
	fn = function( sim, evData )
		if evData.unit:hasTag("assassination") then
			return evData.unit
		end
	end,
}
local CEO_ESCAPED =
{
	trigger = "vip_escaped",
	fn = function( sim, evData )
		if evData.unit:hasTag("assassination") then
			return true
		end
	end,
}
local BODYGUARD_ALERTED =
{
	trigger = simdefs.TRG_UNIT_ALERTED,
	fn = function( sim, evData )
		if evData.unit:hasTag("bodyguard") then
			return evData.unit
		end
	end,
}
local BODYGUARD_DEAD =
{
	trigger = simdefs.TRG_UNIT_KILLED,
	fn = function( sim, evData )
		if evData.unit:hasTag("bodyguard") then
			evData.corpse:addTag("bodyguard")
			return evData.corpse
		end
	end,
}
local BODYGUARD_KO =
{
	trigger = simdefs.TRG_UNIT_KO,
	fn = function( sim, evData )
		if evData.unit:hasTag("bodyguard") then
			return evData.unit
		end
	end,
}
local function canUseSaferoomKey( unit )
	return unit:getPlayerOwner() and unit:getPlayerOwner():isPC() and not unit:getTraits().isDrone
end
local function isSaferoomKey( unit )
	return unit:isDown() and (unit:hasTag("assassination") or unit:hasTag("bodyguard"))
end
local PC_UNLOCK_SAFEROOM =
{
	trigger = simdefs.TRG_UNIT_WARP,
	fn = function( sim, evData )
		local unit = evData.unit
		if not simquery.cellHasTag(sim, evData.to_cell, "saferoom_unlock") then
			return false
		end
		-- Check if a player agent has moved onto a body that was already at the door
		if unit and canUseSaferoomKey(unit) then
			for _, cellUnit in ipairs(evData.to_cell.units) do
				if cellUnit and isSaferoomKey( unit ) then
					return unit, cellUnit
				end
			end
		-- Check if a body has moved to or with a player agent, to the door.
		elseif unit and  isSaferoomKey(unit) then
			for _, cellUnit in ipairs(evData.to_cell.units) do
				if cellUnit and canUseSaferoomKey(cellUnit) then
					return cellUnit, unit
				end
			end
		end
	end,
}
local ESCAPE_WITH_BODY =
{
	trigger = simdefs.TRG_UNIT_ESCAPED,
	fn = function( sim, triggerData )
		for unitID, unit in pairs(sim:getAllUnits()) do
			if unit:hasTag("assassination") then
				local cell = sim:getCell( unit:getLocation() )
				if cell and cell.exitID == simdefs.DEFAULT_EXITID then
					return unit
				end
			end
		end
	end,
}

----
-- Utility Functions

local function findCell(sim, tag)
	local cells = sim:getCells( tag )
	return cells and cells[1]
end

-- Like mission_util.findUnitByTag, but returns nil if the unit isn't found
local function safeFindUnitByTag(sim, tag)
	for _, unit in pairs( sim:getAllUnits() ) do
		if unit:hasTag( tag ) then
			return unit
		end
	end
end

----
-- Actions

local function spawnCeoWeapon( sim )
	local safe = mission_util.findUnitByTag( sim, "saferoom_safe" )
	local newWeapon = simfactory.createUnit( unitdefs.lookupTemplate( "item_light_pistol" ), sim )
	newWeapon:addTag("saferoom_weapon")
	sim:spawnUnit( newWeapon )
	safe:addChild( newWeapon )
end

local function authorizeCeoAccess( sim )
	local ceo = mission_util.findUnitByTag( sim, "assassination" )
	-- Allowed to walk in and out of the saferoom
	if ceo:getTraits().npcPassiveKeybits then
		ceo:getTraits().npcPassiveKeybits = binops.b_or( ceo:getTraits().npcPassiveKeybits, simdefs.DOOR_KEYS.BLAST_DOOR )
	else
		ceo:getTraits().npcPassiveKeybits = simdefs.DOOR_KEYS.BLAST_DOOR
	end
end

local function doAlertCeo( sim )
	ceo = safeFindUnitByTag( sim, "assassination" )
	if ceo and ceo:isValid() and not ceo:isDown() then
		local x,y = ceo:getLocation()
		-- Create an ephemeral interest to be forgotten later
		ceo:getBrain():getSenses():addInterest(x, y, simdefs.SENSE_RADIO, simdefs.REASON_SHARED)  -- REASON_SHARED is alerting
		sim:processReactions( ceo )
	end
end

local function doAlertBodyguard( sim, ceo )
	local bodyguard = safeFindUnitByTag( sim, "bodyguard" )
	if bodyguard and bodyguard:isValid() and not bodyguard:isDown() then
		local x,y = ceo:getLocation()
		-- spawnInterest creates a sticky interest
		bodyguard:getBrain():spawnInterest(x, y, simdefs.SENSE_RADIO, simdefs.REASON_SHARED)  -- REASON_SHARED is alerting
	end
end

local function doUnlockSaferoom( sim, agent )
	local c = findCell( sim, "saferoom_door" )
	assert( c )
	for i, exit in pairs( c.exits ) do
		if exit.door and exit.keybits == simdefs.DOOR_KEYS.BLAST_DOOR then
			if exit.locked and exit.closed then
				-- Unlock, but don't open. Just in case the CEO is pointing a gun this way and the player stood in front of the door.
				sim:modifyExit( c, i, simdefs.EXITOP_UNLOCK)
			elseif not exit.locked and exit.temporaryLockEndTurn then
				-- Temporarily unlocked. Don't let it re-lock.
				local reverseExit = exit.cell.exits[simquery.getReverseDirection( dir )]
				exit.temporaryCloseEndTurn, reverseExit.temporaryCloseEndTurn = nil, nil
				exit.temporaryLockEndTurn, reverseExit.temporaryLockEndTurn = nil, nil
			end
			-- Make the UI sound at the player's location. The tagged cell may be the wrong side of the door from the player.
			local x0,y0 = agent:getLocation()
			sim:emitSound( simdefs.SOUND_DOOR_UNLOCK, x0, y0 )
		end
	end
end

----
-- Script hooks

local function presawfn( script, sim, ceo )
	if not ceo:isDown() then
		--create that big white arrow pointing to the target
		ceo:createTab( STRINGS.MISSIONS.UTIL.HEAT_SIGNATURE_DETECTED, "" )
	end
	sim:removeObjective( "find" )
end

local function pstsawfn( script, sim, ceo )
	if not ceo:isDown() then
		sim:addObjective( STRINGS.MOREMISSIONS.MISSIONS.ASSASSINATION.OBJ_KILL, "kill" )
	end
end

local function bodyguardAlertsCeo(script, sim)
	local _, bodyguard = script:waitFor( BODYGUARD_DEAD, BODYGUARD_KO, BODYGUARD_ALERTED )

	local ceo = safeFindUnitByTag( sim, "assassination" )
	if ceo:isAlerted() then  -- Done
		return
	end

	if ( bodyguard:isDown() ) then
		-- delay 1 full CORP turn before the CEO notices, unless the bodyguard wakes up first.
		local ev, _ = script:waitFor( mission_util.PC_END_TURN, BODYGUARD_ALERTED )
		if ev == mission_util.PC_END_TURN then
			script:waitFor( mission_util.PC_START_TURN, BODYGUARD_ALERTED )
		end
	end

	doAlertCeo( sim )
end

local function playerUnlockSaferoom(script, sim)
	local _, agent, body = script:waitFor( PC_UNLOCK_SAFEROOM )

	doUnlockSaferoom(sim, agent)

	-- TODO: central line
end

local function ceoalertedFlee(script, sim)
	script:addHook( playerUnlockSaferoom )

	local _, ceo = script:waitFor( CEO_ALERTED )
	local safe = mission_util.findUnitByTag( sim, "saferoom_safe" )

	-- Send the CEO to the safe
	local xSafe,ySafe = safe:getLocation()
	local finalCell = findCell( sim, "saferoom_flee" )
	assert( finalCell )
	local finalFacing = simquery.getDirectionFromDelta(xSafe - finalCell.x, ySafe - finalCell.y)
	ceo:getTraits().patrolPath = { { x = finalCell.x, y = finalCell.y, facing = finalFacing } }

	-- Alert the bodyguard
	doAlertBodyguard(sim, ceo)

	script:waitFor( CEO_ARMING )
	local weapon = safeFindUnitByTag( sim, "saferoom_weapon" )
	if weapon and weapon:isValid() and safe and safe:isValid() and safe:hasChild( weapon:getID() ) then
		local sound = simdefs.SOUNDPATH_SAFE_OPEN
		--sound = "SpySociety/Objects/securitysafe_open" --is there a difference?
		safe:getTraits().open = true --this is a flag for anim, not sure if setting it to open and then closed again before/after the event will look good but worth a try -Hek
		sim:dispatchEvent( simdefs.EV_UNIT_USEDOOR, { unitID = ceo:getID(), facing = finalFacing, sound = sound, soundFrame = 1 } )
		safe:getTraits().open = false		
		inventory.giveItem( safe, ceo, weapon )
		sim:emitSound( { path = weapon:getUnitData().sounds.reload, range = simdefs.SOUND_RANGE_0 }, finalCell.x, finalCell.y, ceo )
		ceo:getTraits().pacifist = false
	end
end

-- Direct the bodyguard to the CEO everytime he goes down
-- And reward the player when he's down for good
local function ceoDownAlarm( script, sim, mission )
	local _, ceo
	repeat
		_, ceo = script:waitFor( CEO_KO, CEO_DEAD )

		if ceo:getTraits().iscorpse then
			mission.killedtarget = true
			sim:addMissionReward( simquery.scaleCredits( sim, mission.BOUNTY_VALUE ) )

			sim:removeObjective( "kill" )
			ceo:destroyTab() --Remove the big white arrow (if it is still there)
		end

		sim:setClimax(true)
		script:waitFrames( .5*cdefs.SECONDS )

		doAlertBodyguard( sim, ceo )
	until ceo:getTraits().iscorpse

	script:waitFrames( 1.5*cdefs.SECONDS )
	script:queue( { script=SCRIPTS.INGAME.ASSASSINATION.AFTERMATH[sim:nextRand(1, #SCRIPTS.INGAME.ASSASSINATION.AFTERMATH)], type="newOperatorMessage" } )
end

local function ceoalertedMessage(script, sim)
	local _, ceo = script:waitFor( CEO_ALERTED )
	if not ceo:isDown() then
	    script:queue( { script=SCRIPTS.INGAME.CENTRAL_CFO_RUNNING, type="newOperatorMessage" } )
		sim:getPC():glimpseUnit(sim, ceo:getID() )
	else
		script:addHook( script.hookFn )
	end
end

local function exitWarning(mission)
	if not mission.killedtarget then
		return STRINGS.MOREMISSIONS.UI.HUD_WARN_EXIT_MISSION_ASSASSINATION
	end
end

local function judgement(sim, mission)
	local scripts =
		mission.killedtarget and SCRIPTS.INGAME.ASSASSINATION.CENTRAL_JUDGEMENT.GOTBODY or
		SCRIPTS.INGAME.ASSASSINATION.CENTRAL_JUDGEMENT.NOTHING
	return scripts[sim:nextRand(1, #scripts)]
end

---------------------------------------------------------------------------------------------
-- Begin!

local mission = class( escape_mission )

function mission:init( scriptMgr, sim )
	escape_mission.init( self, scriptMgr, sim )

	-- Base credit value for a successful kill
	self.BOUNTY_VALUE = 1200

	sim:addObjective( STRINGS.MOREMISSIONS.MISSIONS.ASSASSINATION.OBJ_FIND, "find" )
	spawnCeoWeapon( sim )
	authorizeCeoAccess( sim )

	sim.exit_warning = function() return exitWarning(self) end

	scriptMgr:addHook( "SEE", mission_util.DoReportObject(mission_util.PC_SAW_UNIT("assassination"), SCRIPTS.INGAME.ASSASSINATION.OBJECTIVE_SIGHTED, presawfn, pstsawfn ) )
	scriptMgr:addHook( "KILL", ceoDownAlarm, nil, self )

	scriptMgr:addHook( "BODYGUARD", bodyguardAlertsCeo, nil, self)
	scriptMgr:addHook( "RUN", ceoalertedFlee, nil, self)

	--In case the target gets away, ripped straight from the CFO interrogation mission
	scriptMgr:addHook( "RUNMSG", ceoalertedMessage, nil, self)

	--This picks a reaction rant from Central on exit based upon whether or not the target is dead yet.
	scriptMgr:addHook( "FINAL", mission_util.CreateCentralReaction(function() judgement(sim, self) end))
end


function mission.pregeneratePrefabs( cxt, tagSet )
	escape_mission.pregeneratePrefabs( cxt, tagSet )
	table.insert( tagSet[1], "assassination" )


	-- local prefabs = include( "sim/prefabs" )

	-- table.insert( tagSet, { "entry_hotel_ground", makeTags( "struct", cxt.params.difficultyOptions.roomCount ) })
	-- -- table.insert( tagSet, { "entry", makeTags( "struct", cxt.params.difficultyOptions.roomCount ) })
	-- tagSet[1].fitnessSelect = prefabs.SELECT_HIGHEST

	-- --table.insert( tagSet, { "research_lab" })

	-- table.insert( tagSet, { "struct_small", "struct_small" })
	-- table.insert( tagSet, { { "exit", exitFitnessFn } })
end

-- function mission.generatePrefabs( cxt, candidates )
	-- local prefabs = include( "sim/prefabs" )
	-- prefabs.generatePrefabs( cxt, candidates, "switch", 2 )
-- end


return mission
