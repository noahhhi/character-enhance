local PillRewindIdentificationModule = {}
PillRewindIdentificationModule.__index = PillRewindIdentificationModule

local SETTING_KEY = "pillRewindIdentification"
local GLOWING_HOUR_GLASS = CollectibleType.COLLECTIBLE_GLOWING_HOUR_GLASS
local PILL_ACTION = ButtonAction.ACTION_PILLCARD
local TRIGGERED_INPUT = InputHook.IS_ACTION_TRIGGERED
local COLOR_MASK = PillColor.PILL_COLOR_MASK
local FIRST_PILL_COLOR = 1
local LAST_PILL_COLOR = PillColor.NUM_PILLS - 1

function PillRewindIdentificationModule.New(context)
    local self = setmetatable({
        Context = context,
        SavedData = context.GetSavedModuleData
            and context:GetSavedModuleData(SETTING_KEY)
            or {},
        KnownPillColors = {},
        PendingPills = {},
        RestoreFrames = 0,
        UpdateCallbackRegistered = false,
        RunActive = false,
    }, PillRewindIdentificationModule)

    self.UpdateCallback = function()
        self:OnUpdate()
    end

    context.Mod:AddCallback(
        ModCallbacks.MC_POST_GAME_STARTED,
        function(_, isContinued)
            self:OnGameStarted(isContinued)
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_INPUT_ACTION,
        function(_, entity, inputHook, buttonAction)
            self:OnInputAction(entity, inputHook, buttonAction)
        end,
        EntityType.ENTITY_PLAYER
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_USE_PILL,
        function(_, pillEffect, player, useFlags)
            self:OnUsePill(pillEffect, player, useFlags)
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_PRE_USE_ITEM,
        function(_, collectibleType)
            self:OnPreUseItem(collectibleType)
        end
    )

    return self
end

function PillRewindIdentificationModule:GetRunSeed()
    local seeds = Game():GetSeeds()

    return seeds and seeds:GetStartSeed() or 0
end

function PillRewindIdentificationModule:GetPlayerKey(player)
    return tostring(GetPtrHash(player))
end

function PillRewindIdentificationModule:NormalizePillColor(pillColor)
    local numericColor = tonumber(pillColor)

    if type(numericColor) ~= "number"
        or numericColor ~= numericColor
        or numericColor == math.huge
        or numericColor == -math.huge
    then
        return nil
    end

    local color = math.floor(numericColor) & COLOR_MASK

    if color < FIRST_PILL_COLOR or color > LAST_PILL_COLOR then
        return nil
    end

    return color
end

function PillRewindIdentificationModule:SanitizeSavedColors(savedData)
    local colors = {}

    if type(savedData) ~= "table"
        or type(savedData.knownPillColors) ~= "table"
    then
        return colors
    end

    for savedColor, identified in pairs(savedData.knownPillColors) do
        local color = self:NormalizePillColor(savedColor)

        if color and identified == true then
            colors[color] = true
        end
    end

    return colors
end

function PillRewindIdentificationModule:SetUpdateCallbackEnabled(enabled)
    if enabled and not self.UpdateCallbackRegistered then
        self.Context.Mod:AddCallback(
            ModCallbacks.MC_POST_UPDATE,
            self.UpdateCallback
        )
        self.UpdateCallbackRegistered = true
    elseif not enabled and self.UpdateCallbackRegistered then
        self.Context.Mod:RemoveCallback(
            ModCallbacks.MC_POST_UPDATE,
            self.UpdateCallback
        )
        self.UpdateCallbackRegistered = false
    end
end

function PillRewindIdentificationModule:HasKnownPillColors()
    return next(self.KnownPillColors) ~= nil
end

function PillRewindIdentificationModule:IdentifyKnownPills()
    local itemPool = Game():GetItemPool()

    for pillColor in pairs(self.KnownPillColors) do
        itemPool:IdentifyPill(pillColor)
    end
end

function PillRewindIdentificationModule:OnInputAction(
    entity,
    inputHook,
    buttonAction
)
    if not self.RunActive
        or not self.Context:IsEnabled(SETTING_KEY)
        or inputHook ~= TRIGGERED_INPUT
        or buttonAction ~= PILL_ACTION
    then
        return
    end

    local player = entity and entity:ToPlayer()
    local pillColor = player and self:NormalizePillColor(player:GetPill(0))

    if not pillColor then
        return
    end

    self.PendingPills[self:GetPlayerKey(player)] = {
        color = pillColor,
        frame = Game():GetFrameCount(),
    }
end

function PillRewindIdentificationModule:OnUsePill(_, player)
    if not self.RunActive
        or not self.Context:IsEnabled(SETTING_KEY)
        or not player
    then
        return
    end

    local key = self:GetPlayerKey(player)
    local pending = self.PendingPills[key]
    self.PendingPills[key] = nil

    if not pending
        or Game():GetFrameCount() - pending.frame > 1
    then
        return
    end

    self.KnownPillColors[pending.color] = true
    Game():GetItemPool():IdentifyPill(pending.color)

    if self.Context.Save then
        self.Context:Save()
    end
end

function PillRewindIdentificationModule:OnPreUseItem(collectibleType)
    if not self.RunActive
        or collectibleType ~= GLOWING_HOUR_GLASS
        or not self.Context:IsEnabled(SETTING_KEY)
        or not self:HasKnownPillColors()
    then
        return
    end

    -- The room rewind happens after the pre-use callback. Reapply on the next
    -- two completed updates so both the native HUD and description providers
    -- observe the restored ItemPool identification state.
    self.RestoreFrames = 2
    self:SetUpdateCallbackEnabled(true)
end

function PillRewindIdentificationModule:OnUpdate()
    if not self.RunActive
        or not self.Context:IsEnabled(SETTING_KEY)
        or self.RestoreFrames <= 0
    then
        self.RestoreFrames = 0
        self:SetUpdateCallbackEnabled(false)
        return
    end

    self:IdentifyKnownPills()
    self.RestoreFrames = self.RestoreFrames - 1

    if self.RestoreFrames <= 0 then
        self:SetUpdateCallbackEnabled(false)
    end
end

function PillRewindIdentificationModule:OnGameStarted(isContinued)
    self:SetUpdateCallbackEnabled(false)
    self.RunActive = true
    self.RunSeed = self:GetRunSeed()
    self.PendingPills = {}
    self.RestoreFrames = 0
    self.KnownPillColors = {}

    local savedRunSeed = type(self.SavedData) == "table"
        and tonumber(self.SavedData.runSeed)

    if isContinued and savedRunSeed == self.RunSeed then
        self.KnownPillColors = self:SanitizeSavedColors(self.SavedData)
        self:IdentifyKnownPills()
    end
end

function PillRewindIdentificationModule:OnSettingChanged(enabled)
    if enabled then
        return
    end

    self.PendingPills = {}
    self.RestoreFrames = 0
    self:SetUpdateCallbackEnabled(false)
end

function PillRewindIdentificationModule:GetSaveData()
    if self.RunSeed == nil then
        return self.SavedData
    end

    local colors = {}

    for pillColor in pairs(self.KnownPillColors) do
        colors[tostring(pillColor)] = true
    end

    return {
        runSeed = self.RunSeed,
        knownPillColors = colors,
    }
end

function PillRewindIdentificationModule:OnPreGameExit()
    self.SavedData = self:GetSaveData()
    self.RunSeed = nil
    self.RunActive = false
    self.PendingPills = {}
    self.RestoreFrames = 0
    self:SetUpdateCallbackEnabled(false)
end

return PillRewindIdentificationModule
