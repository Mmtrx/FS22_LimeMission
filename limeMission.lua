--=======================================================================================================
-- SCRIPT
--
-- Purpose:     Lime contracts.
-- Author:      Mmtrx
-- Changelog:
--  v1.0.0.0    10.10.2022  initial 
--  v1.0.0.1    20.10.2022  adjust mission vehicles, update missionTypeIdToType 
--  v1.1.0.0    20.09.2023  fix growth stop after accepting a lime contract (#161) 
--							remove offered lime contracts when crop grwos beyond seed stage (growth 1)
--=======================================================================================================
LimeMission = {
	REWARD_PER_HA = 500,
	REIMBURSEMENT_PER_HA = 2020, 
	-- price for 1000 sec: 	Fert: .006 l/s * 1920 = 11520
	-- 						Lime: .090 l/s *  225 = 20250
	debug = false,
}
function debugPrint(text, ...)
	if LimeMission.debug == true then
		Logging.info(text,...)
	end
end
-----------------------------------------------------------------------------------------------
local LimeMission_mt = Class(LimeMission, AbstractFieldMission)
InitObjectClass(LimeMission, "LimeMission")

function LimeMission.new(isServer, isClient, customMt)
	local self = AbstractFieldMission.new(isServer, isClient, customMt or LimeMission_mt)
	self.workAreaTypes = {
		[WorkAreaType.SPRAYER] = true
	}
	self.rewardPerHa = LimeMission.REWARD_PER_HA
	self.reimbursementPerHa = LimeMission.REIMBURSEMENT_PER_HA
	self.reimbursementPerDifficulty = true
	local sprayLevelMapId, sprayLevelFirstChannel, sprayLevelNumChannels = self.mission.fieldGroundSystem:getDensityMapData(FieldDensityMap.LIME_LEVEL)
	self.completionModifier = DensityMapModifier.new(sprayLevelMapId, sprayLevelFirstChannel, sprayLevelNumChannels, self.mission.terrainRootNode)
	self.completionFilter = DensityMapFilter.new(self.completionModifier)
	local groundTypeMapId, groundTypeFirstChannel, groundTypeNumChannels = self.mission.fieldGroundSystem:getDensityMapData(FieldDensityMap.GROUND_TYPE)
	self.completionMaskFilter = DensityMapFilter.new(groundTypeMapId, groundTypeFirstChannel, groundTypeNumChannels)
	self.completionMaskFilter:setValueCompareParams(DensityValueCompareType.GREATER, 0)
	return self
end

function LimeMission:completeField()
	for i = 1, table.getn(self.field.maxFieldStatusPartitions) do
		g_fieldManager:setFieldPartitionStatus(self.field, self.field.maxFieldStatusPartitions, i, 
	--		fruitIndex, 			fieldState, 	growthState, 	 sprayState, 
			self.field.fruitType, self.fieldState, self.growthState, nil, 
	--		setSpray, plowState, 			weedState, 			limeState)		
			true, 	self.fieldPlowFactor, self.weedState, self.limeLevelMaxValue)
	end
end

function getMaxGrowthState(field, fruitType)
	local fruitDesc = g_fruitTypeManager:getFruitTypeByIndex(fruitType)
	if fruitDesc == nil then return nil end
	local maxGrowthState = 0
	local maxArea = 0
	local x, z = FieldUtil.getMeasurementPositionOfField(field)

	for i = 0, fruitDesc.cutState do
		local area, _ = FieldUtil.getFruitArea(x - 1, z - 1, x + 1, z - 1, x - 1, z + 1, FieldUtil.FILTER_EMPTY, FieldUtil.FILTER_EMPTY, fruitType, i, i, 0, 0, 0, false)
		if maxArea < area then
			maxGrowthState = i
			maxArea = area
		end
	end
	return maxGrowthState
end

function LimeMission.canRunOnField(field, sprayFactor, fieldSpraySet, fieldPlowFactor, limeFactor, maxWeedState, stubbleFactor, rollerFactor)
	if not g_currentMission.missionInfo.limeRequired or limeFactor > 0 then 
		-- no lime required, or already limed
		return false 
	end
	-- we can run on an empty field (no fruit defined)
	local fruitType = field.fruitType
	local fruitDesc = g_fruitTypeManager:getFruitTypeByIndex(fruitType)
	if fruitDesc == nil then 
		return field.plannedFruit ~= nil, FieldManager.FIELDSTATE_CULTIVATED, maxWeedState
	end

	-- we cann run on a seeded field (growth 1), or a stubble field (growth = cutState)
	local maxGrowthState = getMaxGrowthState(field, fruitType)
	debugPrint("f%d, growth %d, sprayF %s, spraySet %s, plowF %s, limeF %s, maxWeed %d, stubbleF %s, rollerF %s",
		field.fieldId, maxGrowthState, sprayFactor, fieldSpraySet, fieldPlowFactor, limeFactor, maxWeedState, stubbleFactor, rollerFactor)
	if maxGrowthState < 2 then
		debugPrint("* can run")
		return true, FieldManager.FIELDSTATE_GROWING, maxGrowthState, maxWeedState
	elseif maxGrowthState == fruitDesc.cutState then
		debugPrint("* can run (stubble)")
		return true, FieldManager.FIELDSTATE_HARVESTED, maxGrowthState, maxWeedState
	end
	return false
end

function LimeMission:getData()
	return {
		location = string.format(g_i18n:getText("fieldJob_number"), self.field.fieldId),
		jobType = g_i18n:getText("fieldJob_jobType_lime"),
		action = g_i18n:getText("fieldJob_desc_action_lime"),
		description = string.format(g_i18n:getText("fieldJob_desc_lime"), self.field.fieldId),
		extraText = string.format(g_i18n:getText("fieldJob_desc_fillTheUnit"), g_fillTypeManager:getFillTypeByIndex(FillType.LIME).title)
	}
end

function LimeMission:getIsAvailable()
	-- can lime in winter, if no snow
	if g_currentMission.snowSystem.height >= SnowSystem.MIN_LAYER_HEIGHT then
		return false
	end
	return LimeMission:superClass().getIsAvailable(self)
end

function LimeMission:partitionCompletion(x, z, widthX, widthZ, heightX, heightZ)
	local _, area, totalArea = nil
	self.completionModifier:setParallelogramWorldCoords(x, z, widthX, widthZ, heightX, heightZ, DensityCoordType.POINT_VECTOR_VECTOR)

	local limeLevel = self.limeFactor * self.limeLevelMaxValue
	self.completionFilter:setValueCompareParams(DensityValueCompareType.GREATER, limeLevel)

	_, area, totalArea = self.completionModifier:executeGet(self.completionFilter, self.completionMaskFilter)
	return area, totalArea
end

function LimeMission:validate(event)
	return event ~= FieldManager.FIELDEVENT_GROWN 
	and event ~= FieldManager.FIELDEVENT_LIMED
	and (event ~= FieldManager.FIELDEVENT_GROWING or self.growthState == 1)
end

function adjustMissionTypes(index)
	-- move last missiontype to pos index in g_missionManager.missionTypes
	-- before: mow, plow, cult, sow, harv, weed, spray, fert, trans, lime
	-- after : mow, lime, plow, cult, sow, harv, weed, spray, fert, trans
	local types = g_missionManager.missionTypes
	local type = table.remove(types)
	local idToType = g_missionManager.missionTypeIdToType
	table.insert(types, index, type)

	for i = 1, g_missionManager.nextMissionTypeId -1 do
		types[i].typeId = i
		idToType[i] = types[i]
	end
end

g_missionManager:registerMissionType(LimeMission, "lime")

-- move lime mission type before plow, cultivate: at index 2
adjustMissionTypes(2)
addConsoleCommand("lmGenerateFieldMission", "Force generating a new mission for given field", "consoleGenerateFieldMission", g_missionManager)
