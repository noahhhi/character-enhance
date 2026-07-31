local LostSoulWhiteFireModule = {}
LostSoulWhiteFireModule.__index = LostSoulWhiteFireModule

local SETTING_KEY = "lostSoulWhiteFireFix"
local FAMILIAR_TYPE = EntityType.ENTITY_FAMILIAR
local LOST_SOUL_VARIANT = FamiliarVariant.LOST_SOUL
local LOST_SOUL_SUBTYPE = 0
local FIREPLACE_TYPE = EntityType.ENTITY_FIREPLACE
local WHITE_FIRE_VARIANT = 4
local WHITE_FIRE_SUBTYPE = 0

function LostSoulWhiteFireModule.New(context)
    local self = setmetatable({
        Context = context,
    }, LostSoulWhiteFireModule)

    context.Mod:AddCallback(
        ModCallbacks.MC_ENTITY_TAKE_DMG,
        function(_, entity, amount, flags, source, countdown)
            return self:OnEntityTakeDamage(
                entity,
                amount,
                flags,
                source,
                countdown
            )
        end,
        FAMILIAR_TYPE
    )

    return self
end

function LostSoulWhiteFireModule:IsLostSoul(entity)
    return entity
        and entity.Type == FAMILIAR_TYPE
        and entity.Variant == LOST_SOUL_VARIANT
        and entity.SubType == LOST_SOUL_SUBTYPE
end

function LostSoulWhiteFireModule:IsWhiteFireSource(source)
    local entity = source and source.Entity

    if entity then
        return entity.Type == FIREPLACE_TYPE
            and entity.Variant == WHITE_FIRE_VARIANT
            and entity.SubType == WHITE_FIRE_SUBTYPE
    end

    -- EntityRef retains Type and Variant if the live pointer disappears. White
    -- Fire Places have no nonzero subtype, so those fields still identify the
    -- vanilla 33.4.0 source without broadening this to other fireplaces.
    return source
        and source.Type == FIREPLACE_TYPE
        and source.Variant == WHITE_FIRE_VARIANT
end

function LostSoulWhiteFireModule:OnEntityTakeDamage(
    entity,
    amount,
    flags,
    source,
    countdown
)
    if self.Context:IsEnabled(SETTING_KEY)
        and self:IsLostSoul(entity)
        and self:IsWhiteFireSource(source)
    then
        return false
    end
end

return LostSoulWhiteFireModule
