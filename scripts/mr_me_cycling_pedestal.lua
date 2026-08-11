local MrMeCyclingPedestalModule = {}
MrMeCyclingPedestalModule.__index = MrMeCyclingPedestalModule

local SETTING_KEY = "mrMeCyclingPedestalFix"
local COLLECTIBLE_PICKUP = PickupVariant.PICKUP_COLLECTIBLE
local MR_ME_EFFECT = EffectVariant.MR_ME
local FALLBACK_TARGET_PADDING = 20
local STATE_TRAVELLING_TO_TARGET = 1
local STATE_CARRYING_TO_PLAYER = 2

local function GetEntityKey(entity)
    if type(GetPtrHash) == "function" then
        return GetPtrHash(entity)
    end

    return entity
end

local function GetCollectiblePickup(entity)
    if not entity
        or entity.Type ~= EntityType.ENTITY_PICKUP
        or entity.Variant ~= COLLECTIBLE_PICKUP
    then
        return nil
    end

    return entity:ToPickup()
end

local function IsLivePickup(pickup)
    return pickup
        and pickup:Exists()
end

function MrMeCyclingPedestalModule.New(context)
    local self = setmetatable({
        Context = context,
        ActiveEffects = {},
        ActivePickups = {},
    }, MrMeCyclingPedestalModule)

    context.Mod:AddCallback(
        ModCallbacks.MC_POST_EFFECT_INIT,
        function(_, effect)
            self:OnMrMeEffectInit(effect)
        end,
        MR_ME_EFFECT
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_EFFECT_UPDATE,
        function(_, effect)
            self:OnMrMeEffectUpdate(effect)
        end,
        MR_ME_EFFECT
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_PICKUP_UPDATE,
        function(_, pickup)
            self:OnCollectiblePickupUpdate(pickup)
        end,
        COLLECTIBLE_PICKUP
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_ENTITY_REMOVE,
        function(_, entity)
            self:OnEntityRemove(entity)
        end,
        EntityType.ENTITY_EFFECT
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

function MrMeCyclingPedestalModule:IsEnabled()
    return self.Context:IsEnabled(SETTING_KEY)
end

function MrMeCyclingPedestalModule:ReleasePickup(state)
    local pickup = state.Pickup
    local restoreVisibility = state.RestoreVisibility
    local anotherCarrier = false

    if state.PickupKey then
        local effects = self.ActivePickups[state.PickupKey]

        if effects then
            effects[state.EffectKey] = nil

            for _, otherState in pairs(effects) do
                if otherState.Effect
                    and otherState.Effect.State == STATE_CARRYING_TO_PLAYER
                    and IsLivePickup(otherState.Pickup)
                then
                    anotherCarrier = true

                    if restoreVisibility then
                        otherState.RestoreVisibility = true
                    end

                    break
                end
            end

            if next(effects) == nil then
                self.ActivePickups[state.PickupKey] = nil
            end
        end
    end

    state.Pickup = nil
    state.PickupKey = nil
    state.RestoreVisibility = nil

    if restoreVisibility
        and not anotherCarrier
        and IsLivePickup(pickup)
        and pickup.Visible == false
    then
        pickup.Visible = true
    end
end

function MrMeCyclingPedestalModule:RetainPickup(state, pickup)
    local pickupKey = GetEntityKey(pickup)

    if state.PickupKey == pickupKey then
        state.Pickup = pickup
        return
    end

    self:ReleasePickup(state)
    state.Pickup = pickup
    state.PickupKey = pickupKey

    local effects = self.ActivePickups[pickupKey]

    if not effects then
        effects = {}
        self.ActivePickups[pickupKey] = effects
    end

    effects[state.EffectKey] = state
end

function MrMeCyclingPedestalModule:HidePickupWhileCarried(state, pickup)
    if pickup.Visible then
        -- Native Mr. ME! hides the pedestal as soon as carrying begins. Item
        -- cycling re-enables its visibility during the pickup update, leaving
        -- a duplicate at the old position. Reapply only that native visual
        -- state; the effect will reveal and place the pickup on delivery.
        pickup.Visible = false
        state.RestoreVisibility = true
    end
end

function MrMeCyclingPedestalModule:FindPickupAtTarget(effect, state)
    local targetPosition = effect.TargetPosition

    if not targetPosition then
        return nil
    end

    if state.LastTargetX == targetPosition.X
        and state.LastTargetY == targetPosition.Y
    then
        return nil
    end

    state.LastTargetX = targetPosition.X
    state.LastTargetY = targetPosition.Y

    local nearest = nil
    local nearestDistanceSquared = nil

    for _, entity in ipairs(Isaac.FindByType(
        EntityType.ENTITY_PICKUP,
        COLLECTIBLE_PICKUP
    )) do
        local pickup = entity:ToPickup()

        if IsLivePickup(pickup) then
            local offsetX = pickup.Position.X - targetPosition.X
            local offsetY = pickup.Position.Y - targetPosition.Y
            local distanceSquared = offsetX * offsetX + offsetY * offsetY
            local radius = pickup.Size + FALLBACK_TARGET_PADDING

            if distanceSquared <= radius * radius
                and (not nearestDistanceSquared
                    or distanceSquared < nearestDistanceSquared)
            then
                nearest = pickup
                nearestDistanceSquared = distanceSquared
            end
        end
    end

    return nearest
end


function MrMeCyclingPedestalModule:ResolvePickupTarget(effect, state)
    if IsLivePickup(state.Pickup) then
        if effect.Child
            and GetEntityKey(effect.Child) ~= GetEntityKey(state.Pickup)
        then
            self:ReleasePickup(state)
            return nil
        end

        return state.Pickup
    end

    self:ReleasePickup(state)

    local nativeTarget = GetCollectiblePickup(effect.Child)

    if IsLivePickup(nativeTarget) then
        self:RetainPickup(state, nativeTarget)
        return nativeTarget
    end

    if effect.Child then
        return nil
    end

    local fallbackTarget = self:FindPickupAtTarget(effect, state)

    if fallbackTarget then
        self:RetainPickup(state, fallbackTarget)
    end

    return fallbackTarget
end

function MrMeCyclingPedestalModule:MaintainPickupTarget(effect, state)
    if not self:IsEnabled()
        or (effect.State ~= STATE_TRAVELLING_TO_TARGET
            and effect.State ~= STATE_CARRYING_TO_PLAYER)
    then
        self:ReleasePickup(state)
        return
    end

    if effect.State == STATE_CARRYING_TO_PLAYER
        and not IsLivePickup(state.Pickup)
    then
        return
    end

    local pickup = self:ResolvePickupTarget(effect, state)

    if pickup
        and (not effect.Child
            or GetEntityKey(effect.Child) ~= GetEntityKey(pickup))
    then
        -- Mr. ME!'s native state machine stores the selected task entity in
        -- Child while it travels. Cycling pedestals clear this link whenever
        -- their displayed subtype changes, so restore only the link and leave
        -- the pickup plus the targeting-reticle entity completely untouched.
        effect.Child = pickup
    end

    if pickup and effect.State == STATE_CARRYING_TO_PLAYER then
        self:HidePickupWhileCarried(state, pickup)
    end
end

function MrMeCyclingPedestalModule:OnCollectiblePickupUpdate(pickup)
    if not self:IsEnabled() then
        return
    end

    local effects = self.ActivePickups[GetEntityKey(pickup)]

    if not effects then
        return
    end

    for _, state in pairs(effects) do
        local effect = state.Effect

        if (effect.State == STATE_TRAVELLING_TO_TARGET
                or effect.State == STATE_CARRYING_TO_PLAYER)
            and IsLivePickup(state.Pickup)
        then
            if not effect.Child then
                -- Collectible cycling clears Child during the pickup's own
                -- update. Restore it here so Mr. ME!'s later native entity
                -- update still sees the selected task and can carry it.
                effect.Child = state.Pickup
            end

            if effect.State == STATE_CARRYING_TO_PLAYER then
                self:HidePickupWhileCarried(state, state.Pickup)
            end
        end
    end
end

function MrMeCyclingPedestalModule:OnMrMeEffectInit(effect)
    local key = GetEntityKey(effect)
    local state = {
        Effect = effect,
        EffectKey = key,
    }
    self.ActiveEffects[key] = state
    self:MaintainPickupTarget(effect, state)
end

function MrMeCyclingPedestalModule:OnMrMeEffectUpdate(effect)
    local key = GetEntityKey(effect)
    local state = self.ActiveEffects[key]

    if not state then
        state = {
            Effect = effect,
            EffectKey = key,
        }
        self.ActiveEffects[key] = state
    end

    self:MaintainPickupTarget(effect, state)
end

function MrMeCyclingPedestalModule:OnEntityRemove(entity)
    if entity.Type == EntityType.ENTITY_EFFECT
        and entity.Variant == MR_ME_EFFECT
    then
        local key = GetEntityKey(entity)
        local state = self.ActiveEffects[key]

        if state then
            self:ReleasePickup(state)
            self.ActiveEffects[key] = nil
        end
    end
end

function MrMeCyclingPedestalModule:ResetRoomState()
    for _, state in pairs(self.ActiveEffects) do
        self:ReleasePickup(state)
    end

    self.ActiveEffects = {}
    self.ActivePickups = {}
end

function MrMeCyclingPedestalModule:OnSettingChanged(enabled)
    if not enabled then
        self:ResetRoomState()
    end
end

return MrMeCyclingPedestalModule
