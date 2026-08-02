local BethanyWispExplosionProtectionModule = {}
BethanyWispExplosionProtectionModule.__index =
    BethanyWispExplosionProtectionModule

local SETTING_KEY = "bethanyWispExplosionProtection"
local FAMILIAR_TYPE = EntityType.ENTITY_FAMILIAR
local VIRTUES_WISP = FamiliarVariant.WISP
local ITEM_WISP = FamiliarVariant.ITEM_WISP
local PYROMANIAC = CollectibleType.COLLECTIBLE_PYROMANIAC
local HOST_HAT = CollectibleType.COLLECTIBLE_HOST_HAT
local EXPLOSION_DAMAGE = DamageFlag.DAMAGE_EXPLOSION

local function SameEntity(left, right)
    return left ~= nil
        and right ~= nil
        and (left == right or GetPtrHash(left) == GetPtrHash(right))
end

local function IsExplosionProofCollectible(collectibleType)
    return collectibleType == PYROMANIAC or collectibleType == HOST_HAT
end

function BethanyWispExplosionProtectionModule.New(context)
    local self = setmetatable({
        Context = context,
    }, BethanyWispExplosionProtectionModule)

    context.Mod:AddCallback(
        ModCallbacks.MC_ENTITY_TAKE_DMG,
        function(_, entity, damageAmount, damageFlags, source, countdown)
            return self:OnWispDamage(
                entity,
                damageAmount,
                damageFlags,
                source,
                countdown
            )
        end,
        FAMILIAR_TYPE
    )

    return self
end

function BethanyWispExplosionProtectionModule:IsWisp(familiar)
    return familiar ~= nil
        and (familiar.Variant == VIRTUES_WISP
            or familiar.Variant == ITEM_WISP)
end

function BethanyWispExplosionProtectionModule:OwnerHasProtection(player)
    return player:HasCollectible(PYROMANIAC)
        or player:HasCollectible(HOST_HAT)
end

function BethanyWispExplosionProtectionModule:HasProtectiveItemWisp(player)
    for _, entity in ipairs(Isaac.FindByType(
        FAMILIAR_TYPE,
        ITEM_WISP,
        -1,
        false,
        false
    )) do
        local itemWisp = entity:ToFamiliar()

        if itemWisp
            and SameEntity(itemWisp.Player, player)
            and IsExplosionProofCollectible(itemWisp.SubType)
        then
            return true
        end
    end

    return false
end

function BethanyWispExplosionProtectionModule:OnWispDamage(
    entity,
    _,
    damageFlags
)
    if not self.Context:IsEnabled(SETTING_KEY)
        or (damageFlags & EXPLOSION_DAMAGE) == 0
    then
        return
    end

    local familiar = entity:ToFamiliar()

    if not self:IsWisp(familiar) or familiar.Player == nil then
        return
    end

    if self:OwnerHasProtection(familiar.Player)
        or self:HasProtectiveItemWisp(familiar.Player)
    then
        return false
    end
end

return BethanyWispExplosionProtectionModule
