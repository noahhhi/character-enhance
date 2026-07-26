local ClogGroundDamageModule = {}
ClogGroundDamageModule.__index = ClogGroundDamageModule

local SETTING_KEY = "clogGroundDamage"
local CLOG_TYPE = EntityType.ENTITY_CLOG
local CLOG_VARIANT = 0
local CLOG_SUBTYPE = 0
local CREEP_DAMAGE_INTERVAL = 10
local CREEP_DAMAGE_FLAGS = 0

function ClogGroundDamageModule.New(context)
    local self = setmetatable({
        Context = context,
    }, ClogGroundDamageModule)

    context.Mod:AddCallback(
        ModCallbacks.MC_POST_EFFECT_UPDATE,
        function(_, effect)
            self:OnPostEffectUpdate(effect)
        end
    )

    return self
end

function ClogGroundDamageModule:IsDamagingPlayerCreep(effect)
    return effect
        and EntityEffect.IsPlayerCreep(effect.Variant)
        and type(effect.CollisionDamage) == "number"
        and effect.CollisionDamage > 0
        and effect:IsFrame(CREEP_DAMAGE_INTERVAL, 0)
end

function ClogGroundDamageModule:IsOverlapping(effect, clog)
    local effectSize = type(effect.Size) == "number" and effect.Size or 0
    local clogSize = type(clog.Size) == "number" and clog.Size or 0
    local radius = effectSize + clogSize

    return radius > 0
        and effect.Position:DistanceSquared(clog.Position) <= radius * radius
end

function ClogGroundDamageModule:OnPostEffectUpdate(effect)
    if not self.Context:IsEnabled(SETTING_KEY)
        or not self:IsDamagingPlayerCreep(effect)
    then
        return
    end

    for _, entity in ipairs(Isaac.FindByType(
        CLOG_TYPE,
        CLOG_VARIANT,
        CLOG_SUBTYPE,
        false,
        false
    )) do
        local clog = entity:ToNPC()

        if clog
            and clog:IsVulnerableEnemy()
            and self:IsOverlapping(effect, clog)
        then
            clog:TakeDamage(
                effect.CollisionDamage,
                CREEP_DAMAGE_FLAGS,
                EntityRef(effect),
                0
            )
        end
    end
end

return ClogGroundDamageModule
