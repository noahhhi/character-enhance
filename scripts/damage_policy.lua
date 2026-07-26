local DamagePolicy = {}
DamagePolicy.__index = DamagePolicy

local ENTITY_SLOT = EntityType.ENTITY_SLOT
local ROOM_SACRIFICE = RoomType.ROOM_SACRIFICE
local DAMAGE_SPIKES = DamageFlag.DAMAGE_SPIKES

local NON_PENALTY_FLAGS = DamageFlag.DAMAGE_NO_PENALTIES
    | DamageFlag.DAMAGE_FAKE
    | DamageFlag.DAMAGE_CURSED_DOOR
    | DamageFlag.DAMAGE_IV_BAG

local function HasFlag(flags, flag)
    return type(flags) == "number"
        and flag ~= nil
        and (flags & flag) ~= 0
end

local function IsSlotEntity(entity)
    return entity and entity.Type == ENTITY_SLOT
end

function DamagePolicy.New()
    return setmetatable({}, DamagePolicy)
end

function DamagePolicy:IsSlotSource(source)
    if not source then
        return false
    end

    -- EntityRef exposes Type/Variant even when the referenced Entity is no
    -- longer available. Check both forms so a health-payment source is not
    -- missed merely because its live entity pointer disappeared.
    if IsSlotEntity(source.Entity) or source.Type == ENTITY_SLOT then
        return true
    end

    if source.SpawnerType == ENTITY_SLOT then
        return true
    end

    local sourceEntity = source.Entity

    return sourceEntity
        and (IsSlotEntity(sourceEntity.SpawnerEntity)
            or IsSlotEntity(sourceEntity.Parent))
end

function DamagePolicy:IsNonPenaltyDamage(flags, source)
    if HasFlag(flags, NON_PENALTY_FLAGS) then
        return true
    end

    if HasFlag(flags, DAMAGE_SPIKES)
        and Game():GetRoom():GetType() == ROOM_SACRIFICE
    then
        return true
    end

    -- Vanilla health-paying machines and beggars are all ENTITY_SLOT. This
    -- covers Blood Donation Machines (6.2), Devil Beggars (6.5), Hell Games
    -- (6.15), Confessionals (6.17), and future/custom slot variants without a
    -- fragile per-variant whitelist.
    return self:IsSlotSource(source)
end

return DamagePolicy
