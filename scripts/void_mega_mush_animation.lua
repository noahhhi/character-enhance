local VoidMegaMushAnimationModule = {}
VoidMegaMushAnimationModule.__index = VoidMegaMushAnimationModule

local SETTING_KEY = "voidMegaMushAnimation"
local MEGA_MUSH = CollectibleType.COLLECTIBLE_MEGA_MUSH
local VOID_USE_FLAG = UseFlag.USE_VOID
local MAX_SAVED_PLAYERS = 8
local TRANSFORM_SKIP_FRAMES = 3
local NATIVE_TRANSFORM_WAIT_FRAMES = 3

function VoidMegaMushAnimationModule.New(context)
    local savedData = context:GetSavedModuleData(SETTING_KEY)
    local self = setmetatable({
        Context = context,
        VoidEffectByPlayerIndex = {},
        TransformSkipByPlayerIndex = {},
        NativeTransformByPlayerIndex = {},
        AnimationCallbackRegistered = false,
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

    self.TransformSkipCallback = function(_, player)
        self:OnPostPlayerUpdate(player)
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

function VoidMegaMushAnimationModule:CancelAnimationCallbacks()
    self.TransformSkipByPlayerIndex = {}
    self.NativeTransformByPlayerIndex = {}

    if not self.AnimationCallbackRegistered then
        return
    end

    self.Context.Mod:RemoveCallback(
        ModCallbacks.MC_POST_PLAYER_UPDATE,
        self.TransformSkipCallback
    )
    self.AnimationCallbackRegistered = false
end

function VoidMegaMushAnimationModule:EnsureAnimationCallback()
    if self.AnimationCallbackRegistered then
        return
    end

    self.AnimationCallbackRegistered = true
    self.Context.Mod:AddCallback(
        ModCallbacks.MC_POST_PLAYER_UPDATE,
        self.TransformSkipCallback
    )
end

function VoidMegaMushAnimationModule:RemoveAnimationCallbackIfIdle()
    if next(self.TransformSkipByPlayerIndex) ~= nil
        or next(self.NativeTransformByPlayerIndex) ~= nil
    then
        return
    end

    self:CancelAnimationCallbacks()
end

function VoidMegaMushAnimationModule:ScheduleTransformSkip(playerIndex)
    if self.NativeTransformByPlayerIndex[playerIndex] then
        return
    end

    self.TransformSkipByPlayerIndex[playerIndex] = TRANSFORM_SKIP_FRAMES
    self:EnsureAnimationCallback()
end

function VoidMegaMushAnimationModule:FinishTransformSkip(playerIndex)
    self.TransformSkipByPlayerIndex[playerIndex] = nil
    self:RemoveAnimationCallbackIfIdle()
end

function VoidMegaMushAnimationModule:StartNativeTransform(playerIndex)
    self.TransformSkipByPlayerIndex[playerIndex] = nil
    self.NativeTransformByPlayerIndex[playerIndex] = {
        Started = false,
        Seen = false,
        FramesLeft = NATIVE_TRANSFORM_WAIT_FRAMES,
    }
    self:EnsureAnimationCallback()
end

function VoidMegaMushAnimationModule:FinishNativeTransform(playerIndex)
    self.NativeTransformByPlayerIndex[playerIndex] = nil
    self:RemoveAnimationCallbackIfIdle()
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

    if usedByVoid and self.Context:IsEnabled(SETTING_KEY) then
        -- Physical active-item input can finish Void's indirect Mega Mush use
        -- on its giant idle frame without exposing Transform to the room-only
        -- skip callback. Give the real activation priority and guarantee that
        -- the native transformation starts on the next player update.
        self:StartNativeTransform(playerIndex)
    else
        self.TransformSkipByPlayerIndex[playerIndex] = nil
        self.NativeTransformByPlayerIndex[playerIndex] = nil
        self:RemoveAnimationCallbackIfIdle()
    end
end

function VoidMegaMushAnimationModule:ReplaceMegaMushCostume(player)
    local itemConfig = Isaac.GetItemConfig():GetCollectible(MEGA_MUSH)

    if not itemConfig then
        return false
    end

    player:TryRemoveCollectibleCostume(MEGA_MUSH, true)
    player:AddCostume(itemConfig, true)
    return true
end

function VoidMegaMushAnimationModule:RepairPlayer(player, playerIndex)
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

    -- Void leaves Mega Mush's timed effect active across rooms, but the engine
    -- loses its costume-rendering state. Fully replace the persistent active
    -- costume instead of stacking another copy. Do not use the active item
    -- again or mutate the read-only TemporaryEffect object.
    if not self:ReplaceMegaMushCostume(player) then
        return false
    end

    self:ScheduleTransformSkip(playerIndex)
    return true
end

function VoidMegaMushAnimationModule:RepairAllPlayers()
    local game = Game()

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        if self.VoidEffectByPlayerIndex[playerIndex] then
            self:RepairPlayer(Isaac.GetPlayer(playerIndex), playerIndex)
        end
    end
end

function VoidMegaMushAnimationModule:OnPostPlayerUpdate(player)
    local playerIndex = self:GetPlayerIndex(player)
    local nativeTransform = playerIndex ~= nil
        and self.NativeTransformByPlayerIndex[playerIndex]

    if nativeTransform then
        local sprite = player:GetSprite()

        if not sprite then
            nativeTransform.FramesLeft = nativeTransform.FramesLeft - 1

            if nativeTransform.FramesLeft <= 0 then
                self:FinishNativeTransform(playerIndex)
            end

            return
        end

        if not nativeTransform.Started then
            nativeTransform.Started = true

            if sprite:IsPlaying("Transform") then
                nativeTransform.Seen = true
            elseif not self:ReplaceMegaMushCostume(player) then
                self:FinishNativeTransform(playerIndex)
            end

            return
        end

        if sprite:IsPlaying("Transform") then
            nativeTransform.Seen = true
            return
        end

        if nativeTransform.Seen then
            self:FinishNativeTransform(playerIndex)
            return
        end

        nativeTransform.FramesLeft = nativeTransform.FramesLeft - 1

        if nativeTransform.FramesLeft <= 0 then
            self:FinishNativeTransform(playerIndex)
        end

        return
    end

    local framesLeft = playerIndex ~= nil
        and self.TransformSkipByPlayerIndex[playerIndex]

    if not framesLeft then
        return
    end

    local sprite = player:GetSprite()

    if sprite and sprite:IsPlaying("Transform") then
        sprite:Play("WalkIdle", true)
        self:FinishTransformSkip(playerIndex)
        return
    end

    framesLeft = framesLeft - 1

    if framesLeft <= 0 then
        self:FinishTransformSkip(playerIndex)
    else
        self.TransformSkipByPlayerIndex[playerIndex] = framesLeft
    end
end

function VoidMegaMushAnimationModule:OnNewRoom()
    if self.Context:IsEnabled(SETTING_KEY) then
        -- Match vanilla held-Mega-Mush timing: rebuild the active costume
        -- during room initialization, before the first visible player frame.
        self:RepairAllPlayers()
    end
end

function VoidMegaMushAnimationModule:OnGameStarted(isContinued)
    self:CancelAnimationCallbacks()

    if not isContinued then
        self.VoidEffectByPlayerIndex = {}
    end
end

function VoidMegaMushAnimationModule:OnSettingChanged(enabled)
    if enabled then
        self:RepairAllPlayers()
    else
        self:CancelAnimationCallbacks()
    end
end

return VoidMegaMushAnimationModule
