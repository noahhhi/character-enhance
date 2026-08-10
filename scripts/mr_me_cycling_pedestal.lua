local MrMeCyclingPedestalModule = {}
MrMeCyclingPedestalModule.__index = MrMeCyclingPedestalModule

local SETTING_KEY = "mrMeCyclingPedestalFix"
local COLLECTIBLE_PICKUP = PickupVariant.PICKUP_COLLECTIBLE
local MR_ME_EFFECT = EffectVariant.MR_ME

local function GetEntityKey(entity)
    if type(GetPtrHash) == "function" then
        return GetPtrHash(entity)
    end

    return entity
end

function MrMeCyclingPedestalModule.New(context)
    local self = setmetatable({
        Context = context,
        ActiveEffects = {},
        ActiveEffectCount = 0,
        ManagedPickups = setmetatable({}, { __mode = "k" }),
    }, MrMeCyclingPedestalModule)

    context.Mod:AddCallback(
        ModCallbacks.MC_POST_EFFECT_INIT,
        function(_, effect)
            self:OnMrMeEffect(effect)
        end,
        MR_ME_EFFECT
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_EFFECT_UPDATE,
        function(_, effect)
            self:OnMrMeEffect(effect)
        end,
        MR_ME_EFFECT
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_PICKUP_UPDATE,
        function(_, pickup)
            self:OnCollectibleUpdate(pickup)
        end,
        COLLECTIBLE_PICKUP
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_UPDATE,
        function()
            self:OnPostUpdate()
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_ENTITY_REMOVE,
        function(_, entity)
            self:OnEntityRemove(entity)
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_NEW_ROOM,
        function()
            self:ResetRoomState()
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_GAME_STARTED,
        function()
            self:ResetRoomState()
        end
    )

    return self
end

function MrMeCyclingPedestalModule:IsActive()
    return self.ActiveEffectCount > 0
        and self.Context:IsEnabled(SETTING_KEY)
end

function MrMeCyclingPedestalModule:ReleasePickups()
    self.ManagedPickups = setmetatable({}, { __mode = "k" })
end

function MrMeCyclingPedestalModule:PinPickup(pickup)
    if pickup.SubType <= 0 or self.ManagedPickups[pickup] then
        return
    end

    self.ManagedPickups[pickup] = {
        lockedSubtype = pickup.SubType,
    }
end

function MrMeCyclingPedestalModule:RestorePickup(pickup, state)
    if pickup.SubType > 0 and pickup.SubType ~= state.lockedSubtype then
        pickup.SubType = state.lockedSubtype
    end
end

function MrMeCyclingPedestalModule:PinCurrentPedestals()
    if not self:IsActive() then
        return
    end

    for _, entity in ipairs(Isaac.FindByType(
        EntityType.ENTITY_PICKUP,
        COLLECTIBLE_PICKUP
    )) do
        local pickup = entity:ToPickup()

        if pickup then
            self:PinPickup(pickup)
        end
    end
end

function MrMeCyclingPedestalModule:OnMrMeEffect(effect)
    local key = GetEntityKey(effect)

    if self.ActiveEffects[key] then
        return
    end

    local wasInactive = self.ActiveEffectCount == 0

    self.ActiveEffects[key] = true
    self.ActiveEffectCount = self.ActiveEffectCount + 1

    if wasInactive then
        self:PinCurrentPedestals()
    end
end

function MrMeCyclingPedestalModule:OnCollectibleUpdate(pickup)
    if not self:IsActive() then
        self.ManagedPickups[pickup] = nil
        return
    end

    self:PinPickup(pickup)

    local state = self.ManagedPickups[pickup]

    if state then
        self:RestorePickup(pickup, state)
    end
end

function MrMeCyclingPedestalModule:OnPostUpdate()
    if not self:IsActive() then
        return
    end

    for pickup, state in pairs(self.ManagedPickups) do
        if pickup:Exists() then
            self:RestorePickup(pickup, state)
        else
            self.ManagedPickups[pickup] = nil
        end
    end
end

function MrMeCyclingPedestalModule:OnEntityRemove(entity)
    if entity.Type ~= EntityType.ENTITY_EFFECT
        or entity.Variant ~= MR_ME_EFFECT
    then
        return
    end

    local key = GetEntityKey(entity)

    if not self.ActiveEffects[key] then
        return
    end

    self.ActiveEffects[key] = nil
    self.ActiveEffectCount = math.max(0, self.ActiveEffectCount - 1)

    if self.ActiveEffectCount == 0 then
        self:ReleasePickups()
    end
end

function MrMeCyclingPedestalModule:ResetRoomState()
    self.ActiveEffects = {}
    self.ActiveEffectCount = 0
    self:ReleasePickups()
end

function MrMeCyclingPedestalModule:OnSettingChanged(enabled)
    if enabled then
        self:PinCurrentPedestals()
    else
        self:ReleasePickups()
    end
end

return MrMeCyclingPedestalModule
