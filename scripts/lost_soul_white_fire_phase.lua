local LostSoulWhiteFireModule = {}
LostSoulWhiteFireModule.__index = LostSoulWhiteFireModule

local SETTING_KEY = "lostSoulWhiteFireFix"
local MANTLE_SETTING_KEY = "lostSoulWhiteFireMantle"
local MANTLE_DATA_KEY = "CharacterEnhanceLostSoulWhiteFireMantle"
local MANTLE_VISUAL_DATA_KEY =
    "CharacterEnhanceLostSoulWhiteFireMantleVisual"
local CONTACT_DATA_KEY = "CharacterEnhanceLostSoulWhiteFireContact"
local PHASING_DATA_KEY = "CharacterEnhanceLostSoulWhiteFirePhasing"
local COLLISION_DATA_KEY =
    "CharacterEnhanceLostSoulWhiteFireCollisionClass"
local FAMILIAR_TYPE = EntityType.ENTITY_FAMILIAR
local LOST_SOUL_VARIANT = FamiliarVariant.LOST_SOUL
local LOST_SOUL_SUBTYPE = 0
local FIREPLACE_TYPE = EntityType.ENTITY_FIREPLACE
local WHITE_FIRE_VARIANT = 4
local ANY_SUBTYPE = -1
local PHASE_MARGIN = 16
local MANTLE_ANIMATION = "Mantle"
local HOLY_MANTLE_EFFECT = "gfx/1000.016_poof02_holymantle.anm2"

function LostSoulWhiteFireModule.New(context)
    local self = setmetatable({
        Context = context,
        Sfx = type(SFXManager) == "function" and SFXManager() or nil,
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

    context.Mod:AddCallback(
        ModCallbacks.MC_PRE_FAMILIAR_COLLISION,
        function(_, familiar, collider, low)
            return self:OnPreFamiliarCollision(familiar, collider, low)
        end,
        LOST_SOUL_VARIANT
    )

    context.Mod:AddCallback(
        ModCallbacks.MC_PRE_NPC_COLLISION,
        function(_, npc, collider, low)
            return self:OnPreNpcCollision(npc, collider, low)
        end,
        FIREPLACE_TYPE
    )

    context.Mod:AddCallback(
        ModCallbacks.MC_FAMILIAR_UPDATE,
        function(_, familiar)
            self:OnFamiliarUpdate(familiar)
        end,
        LOST_SOUL_VARIANT
    )

    return self
end

function LostSoulWhiteFireModule:IsLostSoul(entity)
    return entity
        and entity.Type == FAMILIAR_TYPE
        and entity.Variant == LOST_SOUL_VARIANT
        and entity.SubType == LOST_SOUL_SUBTYPE
end

function LostSoulWhiteFireModule:IsWhiteFire(entity)
    return entity
        and entity.Type == FIREPLACE_TYPE
        and entity.Variant == WHITE_FIRE_VARIANT
end

function LostSoulWhiteFireModule:IsLiveWhiteFire(entity)
    if not self:IsWhiteFire(entity) then
        return false
    end

    if type(entity.IsDead) == "function" and entity:IsDead() then
        return false
    end

    return entity.HitPoints == nil or entity.HitPoints > 0
end

function LostSoulWhiteFireModule:IsWhiteFireSource(source)
    local entity = source and source.Entity

    if entity then
        return self:IsWhiteFire(entity)
    end

    -- EntityRef retains Type and Variant if the live pointer disappears.
    -- White Fire Places spawn as 33.4.0 but change their runtime subtype while
    -- active (observed as 33.4.2 in Repentance+ 1.9.7.15), so Type and Variant
    -- are the stable identity fields.
    return source
        and source.Type == FIREPLACE_TYPE
        and source.Variant == WHITE_FIRE_VARIANT
end

function LostSoulWhiteFireModule:IsWithin(familiar, fire, margin)
    if not familiar.Position or not fire.Position then
        return false
    end

    local familiarSize = type(familiar.Size) == "number" and familiar.Size or 0
    local fireSize = type(fire.Size) == "number" and fire.Size or 0
    local radius = familiarSize + fireSize + (margin or 0)
    local offsetX = familiar.Position.X - fire.Position.X
    local offsetY = familiar.Position.Y - fire.Position.Y

    return offsetX * offsetX + offsetY * offsetY <= radius * radius
end

function LostSoulWhiteFireModule:IsTouching(familiar, fire)
    return self:IsWithin(familiar, fire, 0)
end

function LostSoulWhiteFireModule:GetData(familiar)
    if type(familiar.GetData) == "function" then
        return familiar:GetData()
    end

    familiar.CharacterEnhanceData = familiar.CharacterEnhanceData or {}
    return familiar.CharacterEnhanceData
end

function LostSoulWhiteFireModule:GrantMantle(familiar)
    if not self.Context:IsEnabled(MANTLE_SETTING_KEY) then
        return
    end

    local data = self:GetData(familiar)
    data[MANTLE_DATA_KEY] = true
    self:EnsureMantleVisual(familiar)
end

function LostSoulWhiteFireModule:OnWhiteFireContact(familiar)
    local data = self:GetData(familiar)

    if not data[CONTACT_DATA_KEY] then
        self:GrantMantle(familiar)
    end

    data[CONTACT_DATA_KEY] = true
end

function LostSoulWhiteFireModule:HasMantle(familiar)
    return self:GetData(familiar)[MANTLE_DATA_KEY] == true
end

function LostSoulWhiteFireModule:EnsureMantleVisual(familiar)
    local data = self:GetData(familiar)

    if data[MANTLE_DATA_KEY] ~= true
        or type(familiar.GetSprite) ~= "function"
    then
        return
    end

    local sprite = familiar:GetSprite()

    if not sprite or sprite:IsOverlayPlaying(MANTLE_ANIMATION) then
        return
    end

    sprite:PlayOverlay(MANTLE_ANIMATION, true)
    data[MANTLE_VISUAL_DATA_KEY] = true
end

function LostSoulWhiteFireModule:RemoveMantleVisual(familiar)
    local data = self:GetData(familiar)

    if data[MANTLE_VISUAL_DATA_KEY] ~= true
        or type(familiar.GetSprite) ~= "function"
    then
        data[MANTLE_VISUAL_DATA_KEY] = nil
        return
    end

    local sprite = familiar:GetSprite()

    if sprite and sprite:IsOverlayPlaying(MANTLE_ANIMATION) then
        sprite:RemoveOverlay()
    end

    data[MANTLE_VISUAL_DATA_KEY] = nil
end

function LostSoulWhiteFireModule:PlayMantleBreak(familiar)
    if self.Sfx and SoundEffect and SoundEffect.SOUND_HOLY_MANTLE then
        self.Sfx:Play(
            SoundEffect.SOUND_HOLY_MANTLE,
            1,
            0,
            false,
            1
        )
    end

    if not Isaac.Spawn or not EffectVariant or not EffectVariant.POOF02 then
        return
    end

    local effect = Isaac.Spawn(
        EntityType.ENTITY_EFFECT,
        EffectVariant.POOF02,
        0,
        familiar.Position,
        Vector.Zero,
        familiar
    )
    local effectSprite = effect and effect:GetSprite()

    if effectSprite then
        effectSprite:Load(HOLY_MANTLE_EFFECT, true)
        effectSprite:Play("Poof", true)
    end
end

function LostSoulWhiteFireModule:ConsumeMantle(familiar)
    local data = self:GetData(familiar)

    if data[MANTLE_DATA_KEY] ~= true then
        return false
    end

    data[MANTLE_DATA_KEY] = nil
    self:RemoveMantleVisual(familiar)
    self:PlayMantleBreak(familiar)
    return true
end

function LostSoulWhiteFireModule:FindWhiteFireWithin(familiar, margin)
    local fires = Isaac.FindByType(
        FIREPLACE_TYPE,
        WHITE_FIRE_VARIANT,
        ANY_SUBTYPE,
        false,
        false
    )

    for _, fire in ipairs(fires) do
        if self:IsLiveWhiteFire(fire)
            and self:IsWithin(familiar, fire, margin)
        then
            return fire
        end
    end
end

function LostSoulWhiteFireModule:BeginPhasing(familiar)
    local data = self:GetData(familiar)

    if data[PHASING_DATA_KEY] ~= true then
        data[PHASING_DATA_KEY] = true
        data[COLLISION_DATA_KEY] = familiar.EntityCollisionClass
    end

    familiar.EntityCollisionClass = EntityCollisionClass.ENTCOLL_NONE
end

function LostSoulWhiteFireModule:EndPhasing(familiar)
    local data = self:GetData(familiar)

    if data[PHASING_DATA_KEY] ~= true then
        return
    end

    if familiar.EntityCollisionClass == EntityCollisionClass.ENTCOLL_NONE
        and data[COLLISION_DATA_KEY] ~= nil
    then
        familiar.EntityCollisionClass = data[COLLISION_DATA_KEY]
    end

    data[PHASING_DATA_KEY] = nil
    data[COLLISION_DATA_KEY] = nil
end

function LostSoulWhiteFireModule:OnFamiliarUpdate(familiar)
    if not self:IsLostSoul(familiar) then
        return
    end

    local data = self:GetData(familiar)
    self:EnsureMantleVisual(familiar)

    if not self.Context:IsEnabled(SETTING_KEY) then
        data[CONTACT_DATA_KEY] = nil
        self:EndPhasing(familiar)
        return
    end

    local nearbyFire = self:FindWhiteFireWithin(familiar, PHASE_MARGIN)

    if nearbyFire then
        self:BeginPhasing(familiar)
    else
        self:EndPhasing(familiar)
    end

    if nearbyFire and self:IsTouching(familiar, nearbyFire) then
        self:OnWhiteFireContact(familiar)
    else
        data[CONTACT_DATA_KEY] = nil
    end
end

function LostSoulWhiteFireModule:OnPreFamiliarCollision(familiar, collider, low)
    if self.Context:IsEnabled(SETTING_KEY)
        and self:IsLostSoul(familiar)
        and self:IsLiveWhiteFire(collider)
    then
        self:BeginPhasing(familiar)
        self:OnWhiteFireContact(familiar)
        return false
    end
end

function LostSoulWhiteFireModule:OnPreNpcCollision(npc, collider, low)
    if self.Context:IsEnabled(SETTING_KEY)
        and self:IsLiveWhiteFire(npc)
        and self:IsLostSoul(collider)
    then
        self:BeginPhasing(collider)
        self:OnWhiteFireContact(collider)
        return false
    end
end

function LostSoulWhiteFireModule:OnEntityTakeDamage(
    entity,
    amount,
    flags,
    source,
    countdown
)
    if not self:IsLostSoul(entity) then
        return
    end

    if self.Context:IsEnabled(SETTING_KEY)
        and self:IsWhiteFireSource(source)
    then
        self:BeginPhasing(entity)
        self:OnWhiteFireContact(entity)
        return false
    end

    if self:ConsumeMantle(entity) then
        return false
    end
end

return LostSoulWhiteFireModule
