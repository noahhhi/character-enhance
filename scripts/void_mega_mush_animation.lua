local VoidMegaMushAnimationModule = {}
VoidMegaMushAnimationModule.__index = VoidMegaMushAnimationModule

local SETTING_KEY = "voidMegaMushAnimation"
local MEGA_MUSH = CollectibleType.COLLECTIBLE_MEGA_MUSH
local VOID_USE_FLAG = UseFlag.USE_VOID
local MAX_SAVED_PLAYERS = 8

function VoidMegaMushAnimationModule.New(context)
    local savedData = context:GetSavedModuleData(SETTING_KEY)
    local self = setmetatable({
        Context = context,
        VoidEffectByPlayerIndex = {},
        RepairScheduled = false,
    }, VoidMegaMushAnimationModule)

    if type(savedData.voidEffectPlayerIndices) == "table" then
        for _, playerIndex in ipairs(savedData.voidEffectPlayerIndices) do
            if type(playerIndex) == "number"
                and playerIndex == math.floor(playerIndex)
                and playerIndex >= 0
                and playerIndex < MAX_SAVED_PLAYERS
            then
                self.VoidEffectByPlayerIndex[playerIndex] = true
            end
        end
    end

    self.RepairCallback = function()
        self:OnPostUpdate()
    end

    context.Mod:AddCallback(
        ModCallbacks.MC_USE_ITEM,
        function(_, _, _, player, useFlags)
            self:OnUseMegaMush(player, useFlags)
        end,
        MEGA_MUSH
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_NEW_ROOM,
        function()
            self:OnNewRoom()
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_GAME_STARTED,
        function(_, isContinued)
            self:OnGameStarted(isContinued)
        end
    )

    return self
end

function VoidMegaMushAnimationModule:GetPlayerIndex(player)
    if not player then
        return nil
    end

    local playerHash = GetPtrHash(player)
    local game = Game()

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        local candidate = Isaac.GetPlayer(playerIndex)

        if candidate and GetPtrHash(candidate) == playerHash then
            return playerIndex
        end
    end

    return nil
end

function VoidMegaMushAnimationModule:GetSaveData()
    local playerIndices = {}

    for playerIndex = 0, MAX_SAVED_PLAYERS - 1 do
        if self.VoidEffectByPlayerIndex[playerIndex] then
            playerIndices[#playerIndices + 1] = playerIndex
        end
    end

    return {
        voidEffectPlayerIndices = playerIndices,
    }
end

function VoidMegaMushAnimationModule:SetVoidEffect(playerIndex, active)
    local previous = self.VoidEffectByPlayerIndex[playerIndex] == true
    self.VoidEffectByPlayerIndex[playerIndex] = active and true or nil

    if previous ~= active then
        self.Context:Save()
    end
end

function VoidMegaMushAnimationModule:OnUseMegaMush(player, useFlags)
    local playerIndex = self:GetPlayerIndex(player)

    if playerIndex == nil then
        return
    end

    local usedByVoid = type(useFlags) == "number"
        and (useFlags & VOID_USE_FLAG) ~= 0
    self:SetVoidEffect(playerIndex, usedByVoid)
end

function VoidMegaMushAnimationModule:CancelScheduledRepair()
    if not self.RepairScheduled then
        return
    end

    self.Context.Mod:RemoveCallback(
        ModCallbacks.MC_POST_UPDATE,
        self.RepairCallback
    )
    self.RepairScheduled = false
end

function VoidMegaMushAnimationModule:ScheduleRepair()
    if self.RepairScheduled then
        return
    end

    self.RepairScheduled = true
    self.Context.Mod:AddCallback(
        ModCallbacks.MC_POST_UPDATE,
        self.RepairCallback
    )
end

function VoidMegaMushAnimationModule:RepairPlayer(player)
    if not player or player:IsDead() then
        return false
    end

    local effects = player:GetEffects()

    if not effects:HasCollectibleEffect(MEGA_MUSH) then
        return false
    end

    local effect = effects:GetCollectibleEffect(MEGA_MUSH)

    if not effect or effect.Count <= 0 or effect.Cooldown <= 0 then
        return false
    end

    local itemConfig = Isaac.GetItemConfig():GetCollectible(MEGA_MUSH)

    if not itemConfig then
        return false
    end

    -- Void leaves Mega Mush's timed effect active across rooms, but the engine
    -- loses its costume-rendering state. Reattach only that state: do not use
    -- the active item again or mutate the read-only TemporaryEffect object.
    player:TryRemoveCollectibleCostume(MEGA_MUSH, false)
    player:AddCostume(itemConfig, true)
    return true
end

function VoidMegaMushAnimationModule:RepairAllPlayers()
    local game = Game()

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        if self.VoidEffectByPlayerIndex[playerIndex] then
            self:RepairPlayer(Isaac.GetPlayer(playerIndex))
        end
    end
end

function VoidMegaMushAnimationModule:OnPostUpdate()
    self:CancelScheduledRepair()

    if self.Context:IsEnabled(SETTING_KEY) then
        self:RepairAllPlayers()
    end
end

function VoidMegaMushAnimationModule:OnNewRoom()
    if self.Context:IsEnabled(SETTING_KEY) then
        self:ScheduleRepair()
    end
end

function VoidMegaMushAnimationModule:OnGameStarted(isContinued)
    self:CancelScheduledRepair()

    if not isContinued then
        self.VoidEffectByPlayerIndex = {}
    end
end

function VoidMegaMushAnimationModule:OnSettingChanged(enabled)
    if enabled then
        self:ScheduleRepair()
    else
        self:CancelScheduledRepair()
    end
end

return VoidMegaMushAnimationModule
