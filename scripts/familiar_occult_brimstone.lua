local FamiliarOccultBrimstone = {}
FamiliarOccultBrimstone.__index = FamiliarOccultBrimstone

local SETTING_KEY = "familiarOccultBrimstone"
local FAMILIAR = EntityType.ENTITY_FAMILIAR
local PLAYER = EntityType.ENTITY_PLAYER
local OCCULT = TearFlags.TEAR_OCCULT

local COPIES_ATTACK = {
    [FamiliarVariant.INCUBUS] = true,
    [FamiliarVariant.TWISTED_BABY] = true,
    [FamiliarVariant.BLOOD_BABY] = true,
    [FamiliarVariant.UMBILICAL_BABY] = true,
    [FamiliarVariant.SPRINKLER] = true,
}

local BRIMSTONE_VARIANTS = {
    LaserVariant.THICK_RED,
    LaserVariant.GIANT_RED,
    LaserVariant.THICKER_RED,
    LaserVariant.BRIM_TECH,
    LaserVariant.THICKER_BRIM_TECH,
    LaserVariant.GIANT_BRIM_TECH,
}

function FamiliarOccultBrimstone.New(context)
    local self = setmetatable({
        Context = context,
        Reticles = {},
        Guided = {},
    }, FamiliarOccultBrimstone)
    local mod = context.Mod

    mod:AddCallback(ModCallbacks.MC_POST_EFFECT_UPDATE, function(_, effect)
        self:TrackReticle(effect)
    end, EffectVariant.OCCULT_TARGET)

    local function update(_, laser)
        self:Guide(laser)
    end
    for _, variant in ipairs(BRIMSTONE_VARIANTS) do
        mod:AddCallback(ModCallbacks.MC_POST_LASER_UPDATE, update, variant)
    end
    mod:AddCallback(ModCallbacks.MC_POST_ENTITY_REMOVE, function(_, laser)
        local hash = GetPtrHash(laser)
        local record = self.Guided[hash]
        if record and laser.InitSeed == record.Seed then
            self.Guided[hash] = nil
        end
    end, EntityType.ENTITY_LASER)

    local function reset()
        self:Reset()
    end
    mod:AddCallback(ModCallbacks.MC_POST_NEW_ROOM, reset)
    mod:AddCallback(ModCallbacks.MC_PRE_MOD_UNLOAD, reset)
    return self
end

function FamiliarOccultBrimstone:TrackReticle(effect)
    if not self.Context:IsEnabled(SETTING_KEY) then
        return
    end
    local owner = effect.SpawnerEntity
    if not owner or owner.Type ~= PLAYER or not owner:Exists() then
        return
    end

    local ownerHash = GetPtrHash(owner)
    local reticle = self.Reticles[ownerHash]
    if not reticle or reticle.Seed ~= effect.InitSeed or not reticle.Entity.Ref then
        reticle = { Entity = EntityPtr(effect), Seed = effect.InitSeed, OwnerSeed = owner.InitSeed }
        self.Reticles[ownerHash] = reticle
    end
    local position = effect.Position
    reticle.X, reticle.Y = position.X, position.Y
end

function FamiliarOccultBrimstone:Guide(laser)
    if not self.Context:IsEnabled(SETTING_KEY) or laser.SubType ~= 0 then
        return
    end
    local familiar = laser.SpawnerEntity
    if not familiar or familiar.Type ~= FAMILIAR
        or not COPIES_ATTACK[familiar.Variant] or not familiar:Exists()
        or not laser:HasTearFlags(OCCULT)
    then
        return
    end
    local parent = laser.Parent
    if not parent or GetPtrHash(parent) ~= GetPtrHash(familiar) then
        return
    end
    local owner = familiar:ToFamiliar().Player
    local reticle = owner and self.Reticles[GetPtrHash(owner)]
    local hash = GetPtrHash(laser)
    local record = self.Guided[hash]
    if record and record.Seed ~= laser.InitSeed then
        record = nil
        self.Guided[hash] = nil
    end
    if laser.IsActiveRotating then
        self.Guided[hash] = nil
        return
    end
    if not reticle or reticle.OwnerSeed ~= owner.InitSeed or owner:IsDead()
        or not reticle.Entity.Ref
    then
        self:RestoreAngle(hash, record)
        return
    end

    local position = laser.Position
    local dx, dy = reticle.X - position.X, reticle.Y - position.Y
    if dx == 0 and dy == 0 then
        return
    end

    -- Keep the familiar as the spawner. The stock player-only curvature path
    -- recalculates familiar damage as player damage when given a player spawner.
    local angle = math.deg(math.atan(dy, dx))
    local currentAngle = laser.AngleDegrees
    if math.abs((angle - currentAngle + 180) % 360 - 180) < 0.05 then
        return
    end
    if not record then
        record = { Entity = EntityPtr(laser), Seed = laser.InitSeed, OriginalAngle = currentAngle }
        self.Guided[hash] = record
    end
    laser.AngleDegrees = angle
    record.AppliedAngle = laser.AngleDegrees
end

function FamiliarOccultBrimstone:RestoreAngle(hash, record)
    if not record then
        return
    end
    local laser = record.Entity.Ref
    if laser and laser:Exists() and laser.AngleDegrees == record.AppliedAngle
        and not laser.IsActiveRotating
    then
        laser.AngleDegrees = record.OriginalAngle
    end
    self.Guided[hash] = nil
end

function FamiliarOccultBrimstone:Reset()
    for hash, record in pairs(self.Guided) do
        self:RestoreAngle(hash, record)
    end
    self.Reticles = {}
end

function FamiliarOccultBrimstone:OnSettingChanged(enabled)
    if not enabled then
        self:Reset()
    end
end

function FamiliarOccultBrimstone:OnSaveDataLoaded()
    self:Reset()
end

function FamiliarOccultBrimstone:OnPreGameExit()
    self:Reset()
end

return FamiliarOccultBrimstone
