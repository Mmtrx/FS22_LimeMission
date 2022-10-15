--=======================================================================================================
-- SCRIPT
--
-- Purpose:     Lime contracts.
-- Author:      Mmtrx
-- Changelog:
--  v1.0.0.0    10.10.2022  initial 
--  v1.0.0.1    15.10.2022  adjust mission vehicles, update missionTypeIdToType 
--=======================================================================================================
AddLime = {
	filename = g_currentModDirectory .. "missionVehicles/limeMissions.xml",
	debug = "false"
}
function AddLime:loadMapFinished()
	g_missionManager:loadMissionVehicles(AddLime.filename)
end
BaseMission.loadMapFinished = Utils.appendedFunction(BaseMission.loadMapFinished, AddLime.loadMapFinished)
addConsoleCommand("lmFieldGenerateMission", "Force generating a new mission for given field", "consoleGenerateFieldMission", g_missionManager)

function debugPrint(text, ...)
	if AddLime.debug == "true" then
		Logging.info(text,...)
	end
end
-----------------------------------------------------------------------------------------------
LimeMission = {
	REWARD_PER_HA = 500,
	REIMBURSEMENT_PER_HA = 2020 
	-- price for 1000 sec: 	Fert: .006 l/s * 1920 = 11520
	-- 						Lime: .090 l/s *  225 = 20250
}
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
	-- 					field, fieldPartitions, fieldPartitionIndex, 
		g_fieldManager:setFieldPartitionStatus(self.field, self.field.maxFieldStatusPartitions, i, 
	--		fruitIndex, fieldState, growthState, 
			self.field.fruitType, self.fieldState, self.growthState, 
	--		sprayState, 
			nil, 
	--		setSpray, plowState, weedState, limeState)		
			true, self.fieldPlowFactor, self.weedState, self.limeLevelMaxValue)
	end
end

function LimeMission.canRunOnField(field, sprayFactor, fieldSpraySet, fieldPlowFactor, limeFactor, maxWeedState, stubbleFactor, rollerFactor)
	debugPrint("field %d, sprayFactor %s, fieldSpraySet %s, fieldPlowFactor %s, limeFactor %s, maxWeedState %d, stubbleFactor %s, rollerFactor %s",
		field.fieldId, sprayFactor, fieldSpraySet, fieldPlowFactor, limeFactor, maxWeedState, stubbleFactor, rollerFactor)
	if not g_currentMission.missionInfo.limeRequired or limeFactor > 0 then 
		-- no lime required, or already limed
		return false 
	end

	local fruitType = field.fruitType
	local fruitDesc = g_fruitTypeManager:getFruitTypeByIndex(fruitType)
	if fruitDesc == nil then 
		return field.plannedFruit ~= nil, FieldManager.FIELDSTATE_PLOWED 
	end

	local maxGrowthState = FieldUtil.getMaxGrowthState(field, fruitType)
	if maxGrowthState < 2 then
		return true, FieldManager.FIELDSTATE_GROWING, maxGrowthState
	elseif maxGrowthState == fruitDesc.cutState then
		return true, FieldManager.FIELDSTATE_HARVESTED, maxGrowthState
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
	local environment = g_currentMission.environment
	if environment ~= nil and environment.currentSeason == Environment.SEASON.WINTER then
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

function LimeMission:start(...)
	if not LimeMission:superClass().start(self, ...) then
		return false
	end
	if self.growthState and self.growthState ~= 1 then 
		self:setSown(self.field)
	end
	return true
end

function LimeMission:validate(event)
	return event ~= FieldManager.FIELDEVENT_GROWN 
	and event ~= FieldManager.FIELDEVENT_LIMED
end

function LimeMission:setSown(field)
	if field == nil or field.fieldDimensions == nil or field.farmland == nil or field.fruitType == nil then
		return false
	end
	local fruitType = g_fruitTypeManager:getFruitTypeByIndex(field.fruitType)
	local growthState = 1

	if fruitType == nil then
		return false 
	end
	
	local defaultModifier, preparingModifier = g_fieldManager:getFruitModifier(fruitType)
	if defaultModifier == nil then
		return false 
	end

	local numAreasSet = 0
	for i = 1, getNumOfChildren(field.fieldDimensions) do
		local dimWidth = getChildAt(field.fieldDimensions, i - 1)
		local dimStart = getChildAt(dimWidth, 0)
		local dimHeight = getChildAt(dimWidth, 1)
		local startX, _, startZ = getWorldTranslation(dimStart)
		local widthX, _, widthZ = getWorldTranslation(dimWidth)
		local heightX, _, heightZ = getWorldTranslation(dimHeight)

		defaultModifier:setParallelogramWorldCoords(startX, startZ, widthX, widthZ, heightX, heightZ, DensityCoordType.POINT_POINT_POINT)
		defaultModifier:executeSet(growthState)
		numAreasSet = i
	end
	return numAreasSet > 0
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
