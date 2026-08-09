local KidsDrawingFormModule = {}
KidsDrawingFormModule.__index = KidsDrawingFormModule

local SETTING_KEY = "kidsDrawingFormFix"
local KIDS_DRAWING = TrinketType.TRINKET_KIDS_DRAWING
local MOMS_BOX = CollectibleType.COLLECTIBLE_MOMS_BOX
local GUPPYS_TAIL = CollectibleType.COLLECTIBLE_GUPPYS_TAIL

function KidsDrawingFormModule.New(context)
    local self = setmetatable({
        Context = context,
        SavedData = {},
        PreservedData = {},
        Applied = {},
        RunSeed = nil,
        RunActive = false,
    }, KidsDrawingFormModule)

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

function KidsDrawingFormModule:OnSaveDataLoaded(savedData)
    self.SavedData = type(savedData) == "table" and savedData or {}
    self.PreservedData = self:SanitizeSavedData(self.SavedData)
end

function KidsDrawingFormModule:SanitizeSavedData(savedData)
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

        if value == 1 and playerIndex
            and playerIndex == math.floor(playerIndex)
            and playerIndex >= 0 and playerIndex <= 15
        then
            result.applied[tostring(playerIndex)] = 1
        end
    end

    return result
end

function KidsDrawingFormModule:GetRunSeed()
    return Game():GetSeeds():GetStartSeed()
end

function KidsDrawingFormModule:GetPlayerIndex(player)
    local playerHash = GetPtrHash(player)
    local game = Game()

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        if GetPtrHash(Isaac.GetPlayer(playerIndex)) == playerHash then
            return playerIndex
        end
    end

    return nil
end

function KidsDrawingFormModule:LoadApplied(isContinued)
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

function KidsDrawingFormModule:GetTargetContribution(player)
    if not self.Context:IsEnabled(SETTING_KEY)
        or player:IsDead()
        or not player:HasTrinket(KIDS_DRAWING, true)
        or player:GetCollectibleNum(MOMS_BOX, true) <= 0
    then
        return 0
    end

    -- The vanilla multiplier is additive: Mom's Box contributes one extra
    -- application whether Kid's Drawing is normal (1 + 1) or golden (2 + 1).
    return 1
end

function KidsDrawingFormModule:AddContribution(player)
    -- The standard API has no direct form-counter setter. Add a passive Guppy
    -- item as a first pickup so it counts, then remove only the temporary copy
    -- while preserving that form progress. Guppy's Tail has no pickup grant.
    player:AddCollectible(GUPPYS_TAIL, 0, true)
    player:RemoveCollectible(
        GUPPYS_TAIL,
        true,
        ActiveSlot.SLOT_PRIMARY,
        false
    )
end

function KidsDrawingFormModule:RemoveContribution(player)
    -- Add a non-first-pickup copy, then remove it from the player form. This
    -- reverses only the contribution previously owned by this module.
    player:AddCollectible(GUPPYS_TAIL, 0, false)
    player:RemoveCollectible(
        GUPPYS_TAIL,
        true,
        ActiveSlot.SLOT_PRIMARY,
        true
    )
end

function KidsDrawingFormModule:ReconcilePlayer(player, playerIndex)
    if not self.RunActive or playerIndex == nil then
        return false
    end

    local playerKey = tostring(playerIndex)
    local current = self.Applied[playerKey] == 1 and 1 or 0
    local target = self:GetTargetContribution(player)

    if current == target then
        return false
    end

    if target == 1 then
        self:AddContribution(player)
        self.Applied[playerKey] = 1
    else
        self:RemoveContribution(player)
        self.Applied[playerKey] = nil
    end

    return true
end

function KidsDrawingFormModule:ReconcileAll()
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

function KidsDrawingFormModule:OnGameStarted(isContinued)
    self.RunSeed = self:GetRunSeed()
    self.RunActive = true
    self:LoadApplied(isContinued)

    if self:ReconcileAll() or not isContinued then
        -- SaveData is safe here and keeps hot reloads from applying the same
        -- synthetic form contribution twice.
        self.Context:Save()
    end
end

function KidsDrawingFormModule:OnPlayerEffectUpdate(player)
    if not self.RunActive then
        return
    end

    local playerIndex = self:GetPlayerIndex(player)

    if self:ReconcilePlayer(player, playerIndex) then
        -- Trinket and active-item changes are infrequent; persist immediately
        -- so a later luamod reload can restore exact ownership.
        self.Context:Save()
    end
end

function KidsDrawingFormModule:OnSettingChanged()
    if self:ReconcileAll() then
        self.Context:Save()
    end
end

function KidsDrawingFormModule:GetSaveData()
    -- MCM can save settings from the main menu before a run is loaded. Keep
    -- the sanitized continuation state intact until MC_POST_GAME_STARTED tells
    -- us whether it belongs to the run being opened.
    if self.RunSeed == nil then
        return self.PreservedData
    end

    return {
        runSeed = self.RunSeed,
        applied = self.Applied,
    }
end

function KidsDrawingFormModule:OnPreGameExit()
    self.RunActive = false
end

return KidsDrawingFormModule
