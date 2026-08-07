local VoidMegaMushAnimationModule = {}
VoidMegaMushAnimationModule.__index = VoidMegaMushAnimationModule

local SETTING_KEY = "voidMegaMushAnimation"
local MEGA_MUSH = CollectibleType.COLLECTIBLE_MEGA_MUSH
local VOID_USE_FLAG = UseFlag.USE_VOID
local MAX_SAVED_PLAYERS = 8
local ROOM_REPAIR_WAIT_FRAMES = 6
local LEVEL_REPAIR_WAIT_FRAMES = 12

function VoidMegaMushAnimationModule.New(context)
    local savedData = context:GetSavedModuleData(SETTING_KEY)
    local self = setmetatable({
        Context = context,
        VoidEffectByPlayerIndex = {},
        RoomRepairByPlayerIndex = {},
        RepairCallbackRegistered = false,
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

    self.RepairCallback = function(_, player)
        self:OnPostPlayerUpdate(player)
    end

    context.Mod:AddCallback(
        ModCallbacks.MC_PRE_USE_ITEM,
        function(_, _, _, player, useFlags)
            self:OnPreUseMegaMush(player, useFlags)
        end,
        MEGA_MUSH
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_USE_ITEM,
        function(_, _, _, player, useFlags)
            self:OnUseMegaMush(player, useFlags)
        end,
        MEGA_MUSH
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_NEW_LEVEL,
        function()
            self:OnNewLevel()
        end
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

function VoidMegaMushAnimationModule:CancelRepairCallbacks()
    self.RoomRepairByPlayerIndex = {}

    if not self.RepairCallbackRegistered then
        return
    end

    self.Context.Mod:RemoveCallback(
        ModCallbacks.MC_POST_PLAYER_UPDATE,
        self.RepairCallback
    )
    self.RepairCallbackRegistered = false
end

function VoidMegaMushAnimationModule:EnsureRepairCallback()
    if self.RepairCallbackRegistered then
        return
    end

    self.RepairCallbackRegistered = true
    self.Context.Mod:AddCallback(
        ModCallbacks.MC_POST_PLAYER_UPDATE,
        self.RepairCallback
    )
end

function VoidMegaMushAnimationModule:RemoveRepairCallbackIfIdle()
    if next(self.RoomRepairByPlayerIndex) ~= nil then
        return
    end

    self:CancelRepairCallbacks()
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

function VoidMegaMushAnimationModule:IsVoidUse(useFlags)
    return type(useFlags) == "number"
        and (useFlags & VOID_USE_FLAG) ~= 0
end

function VoidMegaMushAnimationModule:OnPreUseMegaMush(player, useFlags)
    if not player
        or not self.Context:IsEnabled(SETTING_KEY)
        or not self:IsVoidUse(useFlags)
    then
        return
    end

    -- Mega Mush's active costume is persistent. KeepPersistent=true leaves an
    -- old giant idle state registered, so Void's next indirect activation can
    -- skip the beginning of the native Transform animation. Remove it before
    -- vanilla handles the nested use; vanilla then owns the full animation.
    player:TryRemoveCollectibleCostume(MEGA_MUSH, false)
end

function VoidMegaMushAnimationModule:OnUseMegaMush(player, useFlags)
    local playerIndex = self:GetPlayerIndex(player)

    if playerIndex == nil then
        return
    end

    local usedByVoid = self:IsVoidUse(useFlags)
    self:SetVoidEffect(playerIndex, usedByVoid)

    -- A real activation must remain entirely in vanilla's hands after the
    -- pre-use cleanup. In particular, do not add the costume again from a
    -- player-update callback: that restarts or skips Transform.
    self.RoomRepairByPlayerIndex[playerIndex] = nil
    self:RemoveRepairCallbackIfIdle()
end

function VoidMegaMushAnimationModule:HasActiveMegaMushEffect(player)
    if not player or player:IsDead() then
        return false
    end

    local effects = player:GetEffects()

    if not effects:HasCollectibleEffect(MEGA_MUSH) then
        return false
    end

    local effect = effects:GetCollectibleEffect(MEGA_MUSH)
    return effect ~= nil and effect.Count > 0 and effect.Cooldown > 0
end

function VoidMegaMushAnimationModule:RepairPlayer(player)
    if not self:HasActiveMegaMushEffect(player) then
        return false
    end

    local itemConfig = Isaac.GetItemConfig():GetCollectible(MEGA_MUSH)

    if not itemConfig then
        return false
    end

    -- This is a visual-only repair. KeepPersistent=false really removes Mega
    -- Mush's persistent active costume; true was the original bug and merely
    -- stacked another reference. StopExtraAnimation settles the newly rebuilt
    -- costume immediately so a room/floor transition never replays Transform.
    player:TryRemoveCollectibleCostume(MEGA_MUSH, false)
    player:AddCostume(itemConfig, true)
    player:StopExtraAnimation()
    return true
end

function VoidMegaMushAnimationModule:ScheduleRoomRepair(playerIndex, frames)
    self.RoomRepairByPlayerIndex[playerIndex] = math.max(
        frames,
        self.RoomRepairByPlayerIndex[playerIndex] or 0
    )
    self:EnsureRepairCallback()
end

function VoidMegaMushAnimationModule:ScheduleAllPlayerRepairs(frames)
    local game = Game()

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        if self.VoidEffectByPlayerIndex[playerIndex] then
            self:ScheduleRoomRepair(playerIndex, frames)
        end
    end
end

function VoidMegaMushAnimationModule:FinishRoomRepair(playerIndex)
    self.RoomRepairByPlayerIndex[playerIndex] = nil
    self:RemoveRepairCallbackIfIdle()
end

function VoidMegaMushAnimationModule:OnPostPlayerUpdate(player)
    local playerIndex = self:GetPlayerIndex(player)
    local framesLeft = playerIndex ~= nil
        and self.RoomRepairByPlayerIndex[playerIndex]

    if not framesLeft then
        return
    end

    if self:RepairPlayer(player) then
        self:FinishRoomRepair(playerIndex)
        return
    end

    framesLeft = framesLeft - 1

    if framesLeft <= 0 then
        self:FinishRoomRepair(playerIndex)
    else
        self.RoomRepairByPlayerIndex[playerIndex] = framesLeft
    end
end

function VoidMegaMushAnimationModule:OnNewRoom()
    if self.Context:IsEnabled(SETTING_KEY) then
        -- Defer until the first completed player update. New-room and new-level
        -- initialization can overwrite active costumes after MC_POST_NEW_ROOM,
        -- but this callback still runs before the first visible player render.
        self:ScheduleAllPlayerRepairs(ROOM_REPAIR_WAIT_FRAMES)
    end
end

function VoidMegaMushAnimationModule:OnNewLevel()
    if self.Context:IsEnabled(SETTING_KEY) then
        self:ScheduleAllPlayerRepairs(LEVEL_REPAIR_WAIT_FRAMES)
    end
end

function VoidMegaMushAnimationModule:OnGameStarted(isContinued)
    self:CancelRepairCallbacks()

    if not isContinued then
        self.VoidEffectByPlayerIndex = {}
    end
end

function VoidMegaMushAnimationModule:OnSettingChanged(enabled)
    if enabled then
        self:ScheduleAllPlayerRepairs(LEVEL_REPAIR_WAIT_FRAMES)
    else
        self:CancelRepairCallbacks()
    end
end

return VoidMegaMushAnimationModule
