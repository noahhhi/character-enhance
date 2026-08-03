local SoulOfEveAltarModule = {}
SoulOfEveAltarModule.__index = SoulOfEveAltarModule

local SETTING_KEY = "soulOfEveBirdFixes"
local SACRIFICIAL_ALTAR = CollectibleType.COLLECTIBLE_SACRIFICIAL_ALTAR
local SOUL_OF_EVE_BIRD = EffectVariant.DEAD_BIRD
local SACRIFICIAL_DEAD_BIRD = FamiliarVariant.DEAD_BIRD
local CHILD_LEASH = TrinketType.TRINKET_CHILD_LEASH
local BFFS = CollectibleType.COLLECTIBLE_BFFS
local FAMILIAR_HARD_LIMIT = 64
local PROXY_DATA_KEY = "CharacterEnhanceSoulOfEveAltarProxy"
local EFFECT_STATE_KEY = "CharacterEnhanceSoulOfEveBirdState"
local CHILD_LEASH_DAMAGE_STEP = 0.25
local FAMILIAR_SIZE_MULTIPLIER = 1.25
local FLOAT_EPSILON = 0.0001

function SoulOfEveAltarModule.New(context)
    local self = setmetatable({
        Context = context,
        ProxyRecords = {},
        CleanupCallbackRegistered = false,
    }, SoulOfEveAltarModule)

    self.CleanupCallback = function()
        self:CleanupProxies()
    end

    context.Mod:AddCallback(
        ModCallbacks.MC_PRE_USE_ITEM,
        function(_, collectibleType, rng, player, useFlags, activeSlot,
            customVarData)
            self:OnPreUseItem(
                collectibleType,
                rng,
                player,
                useFlags,
                activeSlot,
                customVarData
            )
        end,
        SACRIFICIAL_ALTAR
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_ENTITY_REMOVE,
        function(_, entity)
            self:OnEntityRemove(entity)
        end,
        EntityType.ENTITY_FAMILIAR
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_EFFECT_INIT,
        function(_, effect)
            self:OnEffectUpdate(effect)
        end,
        SOUL_OF_EVE_BIRD
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_EFFECT_UPDATE,
        function(_, effect)
            self:OnEffectUpdate(effect)
        end,
        SOUL_OF_EVE_BIRD
    )

    return self
end

function SoulOfEveAltarModule:GetData(entity)
    if entity and type(entity.GetData) == "function" then
        return entity:GetData()
    end

    entity.CharacterEnhanceData = entity.CharacterEnhanceData or {}
    return entity.CharacterEnhanceData
end

function SoulOfEveAltarModule:IsEntityAlive(entity)
    if not entity then
        return false
    end

    if type(entity.Exists) == "function" and not entity:Exists() then
        return false
    end

    return type(entity.IsDead) ~= "function" or not entity:IsDead()
end

function SoulOfEveAltarModule:ToPlayer(entity)
    if not entity then
        return nil
    end

    if type(entity.ToPlayer) == "function" then
        local player = entity:ToPlayer()

        if player then
            return player
        end
    end

    if entity.Type == EntityType.ENTITY_PLAYER then
        return entity
    end

    return nil
end

function SoulOfEveAltarModule:ResolveOwner(effect)
    local owner = self:ToPlayer(effect and effect.SpawnerEntity)
        or self:ToPlayer(effect and effect.Parent)

    if owner then
        return owner
    end

    if Game():GetNumPlayers() == 1 then
        return Isaac.GetPlayer(0)
    end

    return nil
end

function SoulOfEveAltarModule:IsOwnedBy(effect, player)
    local owner = self:ResolveOwner(effect)

    return owner
        and player
        and GetPtrHash(owner) == GetPtrHash(player)
end

function SoulOfEveAltarModule:FindOwnedSoulBirds(player)
    local birds = {}

    for _, entity in ipairs(Isaac.FindByType(
        EntityType.ENTITY_EFFECT,
        SOUL_OF_EVE_BIRD,
        0,
        false,
        false
    )) do
        if self:IsEntityAlive(entity) and self:IsOwnedBy(entity, player) then
            birds[#birds + 1] = entity
        end
    end

    return birds
end

function SoulOfEveAltarModule:NumbersEqual(left, right)
    return type(left) == "number"
        and type(right) == "number"
        and math.abs(left - right) <= FLOAT_EPSILON
end

function SoulOfEveAltarModule:ScalesEqual(left, right)
    return left
        and right
        and self:NumbersEqual(left.X, right.X)
        and self:NumbersEqual(left.Y, right.Y)
end

function SoulOfEveAltarModule:CopyScale(scale)
    return scale and Vector(scale.X, scale.Y) or nil
end

function SoulOfEveAltarModule:RestoreBird(effect, state)
    if not state then
        return
    end

    if state.LastDamage
        and self:NumbersEqual(effect.CollisionDamage, state.LastDamage)
    then
        effect.CollisionDamage = state.BaseDamage
    end

    if state.LastScale
        and self:ScalesEqual(effect.SpriteScale, state.LastScale)
    then
        effect.SpriteScale = self:CopyScale(state.BaseScale)
    end

    self:GetData(effect)[EFFECT_STATE_KEY] = nil
end

function SoulOfEveAltarModule:OnEffectUpdate(effect)
    if not effect or effect.SubType ~= 0 then
        return
    end

    local data = self:GetData(effect)
    local state = data[EFFECT_STATE_KEY]
    local owner = self:ResolveOwner(effect)

    if not self.Context:IsEnabled(SETTING_KEY) or not owner then
        self:RestoreBird(effect, state)
        return
    end

    if not state then
        state = {}
        data[EFFECT_STATE_KEY] = state
    end

    -- Repentance+ already doubles effect 1000.197.0's damage for BFFS!, so
    -- preserve the live native value and add only Child Leash's missing 25%
    -- base-damage step per trinket multiplier. This yields the native additive
    -- 2.25x result for one leash plus BFFS!, rather than multiplying twice.
    local hasBFFS = owner:HasCollectible(BFFS)

    if not state.LastDamage
        or not self:NumbersEqual(effect.CollisionDamage, state.LastDamage)
        or state.HadBFFS ~= hasBFFS
    then
        state.BaseDamage = effect.CollisionDamage
        state.UnboostedBaseDamage = state.BaseDamage
            / (hasBFFS and 2 or 1)
    end

    local leashMultiplier = math.max(
        0,
        owner:GetTrinketMultiplier(CHILD_LEASH)
    )
    local targetDamage = state.BaseDamage
        + state.UnboostedBaseDamage
            * CHILD_LEASH_DAMAGE_STEP
            * leashMultiplier
    effect.CollisionDamage = targetDamage
    state.LastDamage = targetDamage
    state.HadBFFS = hasBFFS

    -- BFFS! and Child Leash each give a 25% cosmetic size increase, but their
    -- size effects do not stack. Neither native path scales Soul of Eve's
    -- effect entity, so apply one shared visual multiplier here.
    if not state.LastScale
        or not self:ScalesEqual(effect.SpriteScale, state.LastScale)
    then
        state.BaseScale = self:CopyScale(effect.SpriteScale)
    end

    local shouldEnlarge = leashMultiplier > 0 or hasBFFS
    local sizeMultiplier = shouldEnlarge and FAMILIAR_SIZE_MULTIPLIER or 1
    local targetScale = Vector(
        state.BaseScale.X * sizeMultiplier,
        state.BaseScale.Y * sizeMultiplier
    )
    effect.SpriteScale = targetScale
    state.LastScale = self:CopyScale(targetScale)
end

function SoulOfEveAltarModule:CountLiveFamiliars()
    local count = 0

    for _, entity in ipairs(Isaac.FindByType(
        EntityType.ENTITY_FAMILIAR,
        -1,
        -1,
        false,
        false
    )) do
        if self:IsEntityAlive(entity) then
            count = count + 1
        end
    end

    return count
end

function SoulOfEveAltarModule:SetCleanupCallbackEnabled(enabled)
    if enabled and not self.CleanupCallbackRegistered then
        self.Context.Mod:AddCallback(
            ModCallbacks.MC_POST_UPDATE,
            self.CleanupCallback
        )
        self.CleanupCallbackRegistered = true
    elseif not enabled and self.CleanupCallbackRegistered then
        self.Context.Mod:RemoveCallback(
            ModCallbacks.MC_POST_UPDATE,
            self.CleanupCallback
        )
        self.CleanupCallbackRegistered = false
    end
end

function SoulOfEveAltarModule:SpawnProxy(effect, owner)
    -- The real Soul of Eve bird is effect 1000.197, so Sacrificial Altar's
    -- native familiar scan cannot see it. A hidden variant-14 familiar exists
    -- only during the native use call and carries the entity's sacrifice slot.
    -- Keep the original effect alive unless the altar actually removes this
    -- proxy.
    local previousSpawnState = self.Context.CreatingSoulOfEveAltarProxy
    self.Context.CreatingSoulOfEveAltarProxy = true
    local succeeded, spawned = pcall(
        Isaac.Spawn,
        EntityType.ENTITY_FAMILIAR,
        SACRIFICIAL_DEAD_BIRD,
        0,
        effect.Position,
        Vector.Zero,
        owner
    )
    self.Context.CreatingSoulOfEveAltarProxy = previousSpawnState

    if not succeeded or not spawned then
        return nil
    end

    local familiar = type(spawned.ToFamiliar) == "function"
        and spawned:ToFamiliar()
        or nil

    if not familiar or not self:IsEntityAlive(familiar) then
        return nil
    end

    familiar.Visible = false
    self:GetData(familiar)[PROXY_DATA_KEY] = true

    local record = {
        Proxy = familiar,
        Original = effect,
        Sacrificed = false,
        Cleaning = false,
    }
    self.ProxyRecords[GetPtrHash(familiar)] = record
    return record
end

function SoulOfEveAltarModule:OnPreUseItem(collectibleType, _rng, player)
    if collectibleType ~= SACRIFICIAL_ALTAR
        or not self.Context:IsEnabled(SETTING_KEY)
        or not player
    then
        return
    end

    if next(self.ProxyRecords) then
        self:CleanupProxies()
    end

    local availableSlots = math.max(
        0,
        FAMILIAR_HARD_LIMIT - self:CountLiveFamiliars()
    )

    if availableSlots == 0 then
        return
    end

    for _, effect in ipairs(self:FindOwnedSoulBirds(player)) do
        if availableSlots <= 0 then
            break
        end

        -- Never request a protected 65th real familiar. When fewer than all
        -- fourteen slots are available, preserve the remaining effect birds
        -- instead of risking an engine-pool overwrite.
        availableSlots = availableSlots - 1
        self:SpawnProxy(effect, player)
    end

    if next(self.ProxyRecords) then
        self:SetCleanupCallbackEnabled(true)
    end
end

function SoulOfEveAltarModule:OnEntityRemove(entity)
    if not entity then
        return
    end

    local record = self.ProxyRecords[GetPtrHash(entity)]

    if record and not record.Cleaning then
        record.Sacrificed = true
    end
end

function SoulOfEveAltarModule:CleanupProxies()
    for proxyHash, record in pairs(self.ProxyRecords) do
        local proxyAlive = self:IsEntityAlive(record.Proxy)
        local sacrificed = record.Sacrificed or not proxyAlive

        if sacrificed and self:IsEntityAlive(record.Original) then
            record.Original:Remove()
        end

        if proxyAlive then
            record.Cleaning = true
            record.Proxy:Remove()
        end

        self.ProxyRecords[proxyHash] = nil
    end

    self:SetCleanupCallbackEnabled(false)
end

function SoulOfEveAltarModule:OnSettingChanged(value)
    if value == false and next(self.ProxyRecords) then
        self:CleanupProxies()
    end

    for _, effect in ipairs(Isaac.FindByType(
        EntityType.ENTITY_EFFECT,
        SOUL_OF_EVE_BIRD,
        0,
        false,
        false
    )) do
        self:OnEffectUpdate(effect)
    end
end

return SoulOfEveAltarModule
