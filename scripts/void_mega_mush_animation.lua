local VoidMegaMushAnimationModule = {}
VoidMegaMushAnimationModule.__index = VoidMegaMushAnimationModule

local SETTING_KEY = "voidMegaMushAnimation"
local MEGA_MUSH = CollectibleType.COLLECTIBLE_MEGA_MUSH
local VOID_USE_FLAG = UseFlag.USE_VOID
local VAMP_GULP_SOUND = SoundEffect.SOUND_VAMP_GULP
local THUMBS_UP_SOUND = SoundEffect.SOUND_THUMBSUP
local TRANSFORM_ANM2 = "gfx/characters/big_isaac.anm2"
local TRANSFORM_ANIMATION = "Transform"
local MAX_SAVED_PLAYERS = 8
local LEVEL_REPAIR_WAIT_FRAMES = 120
local THUMBS_UP_DELAY_FRAMES = 10

function VoidMegaMushAnimationModule.New(context)
    local savedData = context:GetSavedModuleData(SETTING_KEY)
    local self = setmetatable({
        Context = context,
        VoidEffectByPlayerIndex = {},
        RepairByPlayerIndex = {},
        RepairCallbackRegistered = false,
        TransformByPlayerIndex = {},
        TransformCallbackRegistered = false,
        TransformRenderCallbackRegistered = false,
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
        self:OnPostPlayerRender(player)
    end
    self.TransformCallback = function(_, player)
        self:OnPostPlayerUpdate(player)
    end
    self.TransformRenderCallback = function()
        self:OnPostRender()
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
            return self:OnUseMegaMush(player, useFlags)
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
        ModCallbacks.MC_POST_GAME_STARTED,
        function(_, isContinued)
            self:OnGameStarted(isContinued)
        end
    )

    return self
end

function VoidMegaMushAnimationModule:CancelRepairCallbacks()
    self.RepairByPlayerIndex = {}

    if not self.RepairCallbackRegistered then
        return
    end

    self.Context.Mod:RemoveCallback(
        ModCallbacks.MC_POST_PLAYER_RENDER,
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
        ModCallbacks.MC_POST_PLAYER_RENDER,
        self.RepairCallback
    )
end

function VoidMegaMushAnimationModule:RemoveRepairCallbackIfIdle()
    if next(self.RepairByPlayerIndex) ~= nil then
        return
    end

    self:CancelRepairCallbacks()
end

function VoidMegaMushAnimationModule:CancelTransformCallbacks()
    for playerIndex, transform in pairs(self.TransformByPlayerIndex) do
        local player = Isaac.GetPlayer(playerIndex)

        if player and GetPtrHash(player) == transform.PlayerHash then
            player.Visible = transform.WasVisible
        end
    end

    self.TransformByPlayerIndex = {}

    if self.TransformCallbackRegistered then
        self.Context.Mod:RemoveCallback(
            ModCallbacks.MC_POST_PLAYER_UPDATE,
            self.TransformCallback
        )
        self.TransformCallbackRegistered = false
    end

    if self.TransformRenderCallbackRegistered then
        self.Context.Mod:RemoveCallback(
            ModCallbacks.MC_POST_RENDER,
            self.TransformRenderCallback
        )
        self.TransformRenderCallbackRegistered = false
    end
end

function VoidMegaMushAnimationModule:EnsureTransformCallback()
    if self.TransformCallbackRegistered then
        return
    end

    self.TransformCallbackRegistered = true
    self.Context.Mod:AddCallback(
        ModCallbacks.MC_POST_PLAYER_UPDATE,
        self.TransformCallback
    )

    self.TransformRenderCallbackRegistered = true
    self.Context.Mod:AddCallback(
        ModCallbacks.MC_POST_RENDER,
        self.TransformRenderCallback
    )
end

function VoidMegaMushAnimationModule:FinishTransform(playerIndex, settleAppearance)
    local transform = self.TransformByPlayerIndex[playerIndex]

    if transform then
        local player = Isaac.GetPlayer(playerIndex)

        if player and GetPtrHash(player) == transform.PlayerHash then
            player.Visible = transform.WasVisible

            if settleAppearance then
                self:SettleTransformAppearance(player)
            end
        end
    end

    self.TransformByPlayerIndex[playerIndex] = nil

    if next(self.TransformByPlayerIndex) == nil then
        self:CancelTransformCallbacks()
    end
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

    -- Void invokes absorbed actives with USE_NOANIM and USE_NOCOSTUME. Clear
    -- the stale active-costume record before its one real effect activation;
    -- OnUseMegaMush then restores only the skipped presentation.
    player:TryRemoveCollectibleCostume(MEGA_MUSH, false)
end

function VoidMegaMushAnimationModule:StartVoidTransform(player, playerIndex)
    if not self:HasActiveMegaMushEffect(player) then
        return false
    end

    local transformSprite = Sprite()
    transformSprite:Load(TRANSFORM_ANM2, true)
    transformSprite:Play(TRANSFORM_ANIMATION, true)

    -- Void's USE_NOANIM and USE_NOCOSTUME flags make the engine skip the
    -- middle of Mega Mush's presentation. Render the untouched official
    -- Transform sprite independently while the real player and timed effect
    -- continue updating. Reusing the active item would duplicate the effect.
    self:FinishTransform(playerIndex, false)

    self.TransformByPlayerIndex[playerIndex] = {
        PlayerHash = GetPtrHash(player),
        Sprite = transformSprite,
        WasVisible = player.Visible,
        ThumbsUpFramesLeft = THUMBS_UP_DELAY_FRAMES,
    }
    player.Visible = false
    SFXManager():Play(VAMP_GULP_SOUND, 1, 2, false, 1)
    self:EnsureTransformCallback()
    return true
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
    -- transition-repair callback: that restarts or skips Transform.
    self.RepairByPlayerIndex[playerIndex] = nil
    self:RemoveRepairCallbackIfIdle()

    if usedByVoid and self.Context:IsEnabled(SETTING_KEY) then
        self:StartVoidTransform(player, playerIndex)
        return
    end

    self:FinishTransform(playerIndex, false)
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

    -- The floor transition leaves Mega Mush's persistent costume registered
    -- even when its giant sprite stops rendering. KeepPersistent=false clears
    -- that stale record so AddCostume can rebuild the native active costume.
    -- StopExtraAnimation settles it immediately instead of replaying Transform.
    player:TryRemoveCollectibleCostume(MEGA_MUSH, false)
    player:AddCostume(itemConfig, true)
    player:StopExtraAnimation()
    return true
end

function VoidMegaMushAnimationModule:SettleTransformAppearance(player)
    if not self:HasActiveMegaMushEffect(player) then
        return false
    end

    local itemConfig = Isaac.GetItemConfig():GetCollectible(MEGA_MUSH)

    if not itemConfig then
        return false
    end

    -- TemporaryEffects registers the native Mega Mush costume with
    -- ItemStateOnly=false. Match that path after the visual overlay so normal
    -- room transitions retain the complete giant body. The separate new-floor
    -- repair remains item-state-only because it rebuilds an existing effect.
    player:TryRemoveCollectibleCostume(MEGA_MUSH, false)
    player:AddCostume(itemConfig, false)
    player:StopExtraAnimation()
    return true
end

function VoidMegaMushAnimationModule:ScheduleRepair(playerIndex, frames)
    self.RepairByPlayerIndex[playerIndex] = math.max(
        frames,
        self.RepairByPlayerIndex[playerIndex] or 0
    )
    self:EnsureRepairCallback()
end

function VoidMegaMushAnimationModule:ScheduleAllPlayerRepairs(frames)
    local game = Game()

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        if self.VoidEffectByPlayerIndex[playerIndex] then
            self:ScheduleRepair(playerIndex, frames)
        end
    end
end

function VoidMegaMushAnimationModule:FinishRepair(playerIndex)
    self.RepairByPlayerIndex[playerIndex] = nil
    self:RemoveRepairCallbackIfIdle()
end

function VoidMegaMushAnimationModule:OnPostPlayerRender(player)
    local playerIndex = self:GetPlayerIndex(player)
    local framesLeft = playerIndex ~= nil
        and self.RepairByPlayerIndex[playerIndex]

    if not framesLeft then
        return
    end

    -- MC_POST_PLAYER_RENDER does not run for the separate nightmare cutscene.
    -- Its first call after MC_POST_NEW_LEVEL is therefore after the new floor
    -- has reset and actually rendered the real player entity. Rebuild after
    -- that render so the next visible frame uses the settled giant costume.
    if self:RepairPlayer(player) then
        self:FinishRepair(playerIndex)
        return
    end

    framesLeft = framesLeft - 1

    if framesLeft <= 0 then
        self:FinishRepair(playerIndex)
    else
        self.RepairByPlayerIndex[playerIndex] = framesLeft
    end
end

function VoidMegaMushAnimationModule:OnPostPlayerUpdate(player)
    local playerIndex = self:GetPlayerIndex(player)
    local transform = playerIndex ~= nil
        and self.TransformByPlayerIndex[playerIndex]

    if not transform then
        return
    end

    if not self:HasActiveMegaMushEffect(player) then
        self:FinishTransform(playerIndex, false)
        return
    end

    player.Visible = false
    transform.Sprite:Update()

    if transform.ThumbsUpFramesLeft then
        transform.ThumbsUpFramesLeft = transform.ThumbsUpFramesLeft - 1

        if transform.ThumbsUpFramesLeft <= 0 then
            SFXManager():Play(THUMBS_UP_SOUND, 1, 2, false, 1)
            transform.ThumbsUpFramesLeft = nil
        end
    end

    if transform.Sprite:IsFinished(TRANSFORM_ANIMATION) then
        self:FinishTransform(playerIndex, true)
    end
end

function VoidMegaMushAnimationModule:OnPostRender()
    for playerIndex, transform in pairs(self.TransformByPlayerIndex) do
        local player = Isaac.GetPlayer(playerIndex)

        if player and GetPtrHash(player) == transform.PlayerHash then
            local renderPosition = Isaac.WorldToScreen(player.Position)
                + player.PositionOffset
            transform.Sprite:Render(renderPosition)
        end
    end
end

function VoidMegaMushAnimationModule:OnNewLevel()
    if self.Context:IsEnabled(SETTING_KEY) then
        -- Ordinary room transitions preserve the native costume. Rebuilding it
        -- there causes a one-frame head/body split. Real floor transitions are
        -- the boundary that drops the rendered giant sprite, so repair only
        -- after their first completed real-player render.
        self:ScheduleAllPlayerRepairs(LEVEL_REPAIR_WAIT_FRAMES)
    end
end

function VoidMegaMushAnimationModule:OnGameStarted(isContinued)
    self:CancelRepairCallbacks()
    self:CancelTransformCallbacks()

    if not isContinued then
        self.VoidEffectByPlayerIndex = {}
    elseif self.Context:IsEnabled(SETTING_KEY) then
        self:ScheduleAllPlayerRepairs(LEVEL_REPAIR_WAIT_FRAMES)
    end
end

function VoidMegaMushAnimationModule:OnSettingChanged(enabled)
    if enabled then
        self:ScheduleAllPlayerRepairs(LEVEL_REPAIR_WAIT_FRAMES)
    else
        self:CancelRepairCallbacks()
        self:CancelTransformCallbacks()
    end
end

return VoidMegaMushAnimationModule
