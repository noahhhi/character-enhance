local ConjoinedFormComponentsModule = {}
ConjoinedFormComponentsModule.__index = ConjoinedFormComponentsModule

local SETTING_KEY = "conjoinedFamiliarComponents"
local LITTLE_GISH = CollectibleType.COLLECTIBLE_LITTLE_GISH
local LIL_MONSTRO = CollectibleType.COLLECTIBLE_LIL_MONSTRO
local BROTHER_BOBBY = CollectibleType.COLLECTIBLE_BROTHER_BOBBY

local COMPONENTS = {
    { collectible = LITTLE_GISH, bit = 1 },
    { collectible = LIL_MONSTRO, bit = 2 },
}

function ConjoinedFormComponentsModule.New(context)
    local self = setmetatable({
        Context = context,
        SavedData = {},
        PreservedData = {},
        Applied = {},
        RunSeed = nil,
        RunActive = false,
    }, ConjoinedFormComponentsModule)

    self:OnSaveDataLoaded(context:GetSavedModuleData(SETTING_KEY))

    context.Mod:AddCallback(
        ModCallbacks.MC_POST_GAME_STARTED,
        function(_, isContinued)
            self:OnGameStarted(isContinued)
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_PEFFECT_UPDATE,
        function(_, player)
            self:OnPlayerEffectUpdate(player)
        end
    )

    return self
end

function ConjoinedFormComponentsModule:OnSaveDataLoaded(savedData)
    self.SavedData = type(savedData) == "table" and savedData or {}
    self.PreservedData = self:SanitizeSavedData(self.SavedData)
end

function ConjoinedFormComponentsModule:SanitizeSavedData(savedData)
    local result = { applied = {} }

    if type(savedData) ~= "table" then
        return result
    end

    local runSeed = savedData.runSeed

    if type(runSeed) == "number" and runSeed == runSeed
        and runSeed ~= math.huge and runSeed ~= -math.huge
    then
        result.runSeed = math.floor(runSeed)
    end

    if type(savedData.applied) ~= "table" then
        return result
    end

    for playerKey, value in pairs(savedData.applied) do
        local playerIndex = tonumber(playerKey)

        if type(value) == "number"
            and value == math.floor(value)
            and value >= 1 and value <= 3
            and playerIndex
            and playerIndex == math.floor(playerIndex)
            and playerIndex >= 0 and playerIndex <= 15
        then
            result.applied[tostring(playerIndex)] = value
        end
    end

    return result
end

function ConjoinedFormComponentsModule:GetRunSeed()
    return Game():GetSeeds():GetStartSeed()
end

function ConjoinedFormComponentsModule:GetPlayerIndex(player)
    local playerHash = GetPtrHash(player)
    local game = Game()

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        if GetPtrHash(Isaac.GetPlayer(playerIndex)) == playerHash then
            return playerIndex
        end
    end

    return nil
end

function ConjoinedFormComponentsModule:LoadApplied(isContinued)
    self.Applied = {}

    if not isContinued
        or self.PreservedData.runSeed ~= self.RunSeed
    then
        return
    end

    for playerKey, value in pairs(self.PreservedData.applied) do
        self.Applied[playerKey] = value
    end
end

function ConjoinedFormComponentsModule:GetTargetMask(player)
    if not self.Context:IsEnabled(SETTING_KEY) or player:IsDead() then
        return 0
    end

    local mask = 0

    for _, component in ipairs(COMPONENTS) do
        if player:GetCollectibleNum(component.collectible, true) > 0 then
            mask = mask + component.bit
        end
    end

    return mask
end

function ConjoinedFormComponentsModule:AddContribution(player)
    -- The standard API has no form-counter setter. A first-pickup copy of a
    -- harmless native Conjoined component adds one count; removing only that
    -- temporary copy while preserving form progress leaves inventory intact.
    player:AddCollectible(BROTHER_BOBBY, 0, true)
    player:RemoveCollectible(
        BROTHER_BOBBY,
        true,
        ActiveSlot.SLOT_PRIMARY,
        false
    )
end

function ConjoinedFormComponentsModule:RemoveContribution(player)
    -- Mirror the synthetic addition without replaying first-pickup behavior,
    -- then remove that one copy from the form counter.
    player:AddCollectible(BROTHER_BOBBY, 0, false)
    player:RemoveCollectible(
        BROTHER_BOBBY,
        true,
        ActiveSlot.SLOT_PRIMARY,
        true
    )
end

function ConjoinedFormComponentsModule:ReconcilePlayer(player, playerIndex)
    if not self.RunActive or playerIndex == nil then
        return false
    end

    local playerKey = tostring(playerIndex)
    local current = self.Applied[playerKey] or 0
    local target = self:GetTargetMask(player)

    if current == target then
        return false
    end

    for _, component in ipairs(COMPONENTS) do
        local currentHas = current % (component.bit * 2) >= component.bit
        local targetHas = target % (component.bit * 2) >= component.bit

        if currentHas ~= targetHas then
            if targetHas then
                self:AddContribution(player)
            else
                self:RemoveContribution(player)
            end
        end
    end

    self.Applied[playerKey] = target ~= 0 and target or nil
    return true
end

function ConjoinedFormComponentsModule:ReconcileAll()
    if not self.RunActive then
        return false
    end

    local changed = false
    local game = Game()

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(playerIndex)

        if self:ReconcilePlayer(player, playerIndex) then
            changed = true
        end
    end

    return changed
end

function ConjoinedFormComponentsModule:OnGameStarted(isContinued)
    self.RunSeed = self:GetRunSeed()
    self.RunActive = true
    self:LoadApplied(isContinued)

    if self:ReconcileAll() or not isContinued then
        self.Context:Save()
    end
end

function ConjoinedFormComponentsModule:OnPlayerEffectUpdate(player)
    if not self.RunActive then
        return
    end

    local playerIndex = self:GetPlayerIndex(player)

    if self:ReconcilePlayer(player, playerIndex) then
        self.Context:Save()
    end
end

function ConjoinedFormComponentsModule:OnSettingChanged()
    if self:ReconcileAll() then
        self.Context:Save()
    end
end

function ConjoinedFormComponentsModule:GetSaveData()
    if self.RunSeed == nil then
        return self.PreservedData
    end

    return {
        runSeed = self.RunSeed,
        applied = self.Applied,
    }
end

function ConjoinedFormComponentsModule:OnPreGameExit()
    self.RunActive = false
end

return ConjoinedFormComponentsModule
