local VoidMegaMushAnimationModule = {}
VoidMegaMushAnimationModule.__index = VoidMegaMushAnimationModule

local SETTING_KEY = "voidMegaMushAnimation"
local MEGA_MUSH = CollectibleType.COLLECTIBLE_MEGA_MUSH
local OWNED_USE_FLAG = UseFlag.USE_OWNED
local VOID_USE_FLAG = UseFlag.USE_VOID
local SUPPRESSED_PRESENTATION_FLAGS = UseFlag.USE_NOANIM
    | UseFlag.USE_NOCOSTUME
local VOID_REPLAY_FLAGS = SUPPRESSED_PRESENTATION_FLAGS | VOID_USE_FLAG
local MAX_SAVED_PLAYERS = 8
local MAX_NATIVE_REPLAY_WAIT_FRAMES = 120

function VoidMegaMushAnimationModule.New(context)
    local savedData = context:GetSavedModuleData(SETTING_KEY)
    local self = setmetatable({
        Context = context,
        VoidEffectByPlayerIndex = {},
        PendingNativeUseByPlayerIndex = {},
        NativeReplayByPlayerHash = {},
        ReplayCallbackRegistered = false,
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

    self.ReplayCallback = function(_, player)
        self:OnPostPlayerUpdate(player)
    end

    context.Mod:AddCallback(
        ModCallbacks.MC_PRE_USE_ITEM,
        function(_, _, _, player, useFlags)
            return self:OnPreUseMegaMush(player, useFlags)
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

function VoidMegaMushAnimationModule:IsVoidUse(useFlags)
    return type(useFlags) == "number"
        and (useFlags & VOID_USE_FLAG) ~= 0
end

function VoidMegaMushAnimationModule:IsPresentationSuppressed(useFlags)
    return type(useFlags) == "number"
        and (useFlags & SUPPRESSED_PRESENTATION_FLAGS) ~= 0
end

function VoidMegaMushAnimationModule:EnsureReplayCallback()
    if self.ReplayCallbackRegistered then
        return
    end

    self.ReplayCallbackRegistered = true
    self.Context.Mod:AddCallback(
        ModCallbacks.MC_POST_PLAYER_UPDATE,
        self.ReplayCallback
    )
end

function VoidMegaMushAnimationModule:RemoveReplayCallbackIfIdle()
    if next(self.PendingNativeUseByPlayerIndex) ~= nil
        or not self.ReplayCallbackRegistered
    then
        return
    end

    self.Context.Mod:RemoveCallback(
        ModCallbacks.MC_POST_PLAYER_UPDATE,
        self.ReplayCallback
    )
    self.ReplayCallbackRegistered = false
end

function VoidMegaMushAnimationModule:CancelPendingNativeUses()
    self.PendingNativeUseByPlayerIndex = {}
    self.NativeReplayByPlayerHash = {}
    self:RemoveReplayCallbackIfIdle()
end

function VoidMegaMushAnimationModule:QueueNativeUse(
    player,
    playerIndex,
    useFlags
)
    local pending = self.PendingNativeUseByPlayerIndex[playerIndex]

    if not pending or pending.PlayerHash ~= GetPtrHash(player) then
        pending = {
            PlayerHash = GetPtrHash(player),
            UseFlags = {},
            WaitFrames = 0,
        }
        self.PendingNativeUseByPlayerIndex[playerIndex] = pending
    end

    pending.UseFlags[#pending.UseFlags + 1] = (useFlags & ~VOID_REPLAY_FLAGS)
        | OWNED_USE_FLAG
    self:EnsureReplayCallback()
end

function VoidMegaMushAnimationModule:OnPreUseMegaMush(player, useFlags)
    if not player
        or not self.Context:IsEnabled(SETTING_KEY)
        or not self:IsVoidUse(useFlags)
        or not self:IsPresentationSuppressed(useFlags)
    then
        return
    end

    local playerHash = GetPtrHash(player)

    if self.NativeReplayByPlayerHash[playerHash] then
        return
    end

    local playerIndex = self:GetPlayerIndex(player)

    if playerIndex == nil then
        return
    end

    -- Void invokes absorbed actives with USE_NOANIM, USE_NOCOSTUME, and
    -- USE_VOID. Cancel only that suppressed Mega Mush use before it creates an
    -- effect, then wait for Void's own extra animation to finish before
    -- replaying it with the same USE_OWNED semantics as a direct Mega Mush
    -- activation. Starting Transform while Void is still lowering the held
    -- item makes the two native player animations alternately flatten and
    -- stretch the body before the giant costume snaps into place. The engine
    -- still owns the one real timed effect, complete animation, sounds,
    -- costume, and transition behavior.
    self:QueueNativeUse(player, playerIndex, useFlags)
    return true
end

function VoidMegaMushAnimationModule:OnUseMegaMush(player, useFlags)
    local playerIndex = self:GetPlayerIndex(player)

    if playerIndex == nil then
        return
    end

    local playerHash = GetPtrHash(player)
    local isVoidReplay = self.NativeReplayByPlayerHash[playerHash] == true

    self:SetVoidEffect(
        playerIndex,
        self:IsVoidUse(useFlags) or isVoidReplay
    )
end

function VoidMegaMushAnimationModule:OnPostPlayerUpdate(player)
    local playerIndex = self:GetPlayerIndex(player)
    local pending = playerIndex ~= nil
        and self.PendingNativeUseByPlayerIndex[playerIndex]

    if not pending then
        return
    end

    local playerHash = GetPtrHash(player)

    if pending.PlayerHash ~= playerHash then
        self.PendingNativeUseByPlayerIndex[playerIndex] = nil
        self:RemoveReplayCallbackIfIdle()
        return
    end

    pending.WaitFrames = pending.WaitFrames + 1

    if not player:IsExtraAnimationFinished()
        and pending.WaitFrames < MAX_NATIVE_REPLAY_WAIT_FRAMES
    then
        return
    end

    -- Remove this batch before re-entering UseActiveItem. The per-player guard
    -- lets the replacement call pass through MC_PRE_USE_ITEM without allowing
    -- unrelated suppressed uses to recurse.
    self.PendingNativeUseByPlayerIndex[playerIndex] = nil
    self.NativeReplayByPlayerHash[playerHash] = true

    for _, useFlags in ipairs(pending.UseFlags) do
        player:UseActiveItem(MEGA_MUSH, useFlags)
    end

    self.NativeReplayByPlayerHash[playerHash] = nil
    self:RemoveReplayCallbackIfIdle()
end

function VoidMegaMushAnimationModule:OnGameStarted(isContinued)
    self:CancelPendingNativeUses()

    if not isContinued then
        self.VoidEffectByPlayerIndex = {}
    end
end

function VoidMegaMushAnimationModule:OnSettingChanged(_)
    -- A replacement already queued here represents a Void effect that this
    -- module cancelled before the setting changed. It must still complete
    -- exactly once; future uses immediately follow the new setting value.
end

return VoidMegaMushAnimationModule
