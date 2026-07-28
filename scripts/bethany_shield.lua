local BethanyShieldModule = {}
BethanyShieldModule.__index = BethanyShieldModule

local SETTING_KEY = "bethanyDamageShield"
local BETHANY = PlayerType.PLAYER_BETHANY
local PERFECTION = TrinketType.TRINKET_PERFECTION
local BLIND_RAGE = TrinketType.TRINKET_BLIND_RAGE
local FLOOR_DAMAGED = LevelStateFlag.STATE_DAMAGED
local HALF_HEART_DAMAGE_COOLDOWN = 60
local FULL_HEART_DAMAGE_COOLDOWN = 120
local BLIND_RAGE_COOLDOWN_BONUS = 120

function BethanyShieldModule.New(context)
    local self = setmetatable({
        Context = context,
    }, BethanyShieldModule)

    context.Mod:AddCallback(
        ModCallbacks.MC_ENTITY_TAKE_DMG,
        function(_, entity, damageAmount, damageFlags, source, countdown)
            return self:OnPlayerDamage(
                entity,
                damageAmount,
                damageFlags,
                source,
                countdown
            )
        end,
        EntityType.ENTITY_PLAYER
    )

    return self
end

function BethanyShieldModule:IsExcludedDamage(damageFlags, source)
    return self.Context.DamagePolicy:IsNonPenaltyDamage(
        damageFlags,
        source
    )
end

function BethanyShieldModule:GetDamageCooldown(player, damageAmount)
    local baseCooldown = damageAmount >= 2
        and FULL_HEART_DAMAGE_COOLDOWN
        or HALF_HEART_DAMAGE_COOLDOWN
    local blindRageMultiplier = math.max(
        0,
        player:GetTrinketMultiplier(BLIND_RAGE)
    )

    return baseCooldown
        + blindRageMultiplier * BLIND_RAGE_COOLDOWN_BONUS
end

function BethanyShieldModule:OnSettingChanged(enabled)
    local feedbackModule = self.Context.Modules.bethanyShieldFeedback

    if feedbackModule and feedbackModule.OnShieldSettingChanged then
        feedbackModule:OnShieldSettingChanged(enabled)
    end
end

function BethanyShieldModule:OnPlayerDamage(
    entity,
    damageAmount,
    damageFlags,
    source,
    damageCountdownFrames
)
    if not self.Context:IsEnabled(SETTING_KEY) then
        return
    end

    local player = entity:ToPlayer()

    if not player or player:GetPlayerType() ~= BETHANY then
        return
    end

    -- The charge module is optional. If enabled, synchronize same-frame gains;
    -- if disabled, the shield continues to use the player's vanilla charge.
    local chargeModule = self.Context.Modules.bethanySoulCharge

    if chargeModule then
        chargeModule:SyncPlayer(player)
    end

    local soulCharge = player:GetSoulCharge()

    if soulCharge <= 0 or self:IsExcludedDamage(damageFlags, source) then
        return
    end

    local chargeCost = math.max(1, math.floor(damageAmount * 2 + 0.5))
    player:SetSoulCharge(math.max(0, soulCharge - chargeCost))

    if chargeModule then
        chargeModule:AdoptCurrentCharge(player)
    end

    local feedbackModule = self.Context.Modules.bethanyShieldFeedback

    if feedbackModule and feedbackModule:IsEnabled() then
        -- Feedback is visual/audio only. A second TakeDamage call would enter
        -- the engine's normal hurt voice and full hit-animation path even with
        -- zero damage and DAMAGE_FAKE.
        feedbackModule:OnAbsorbedHit(player)
    end

    player:SetMinDamageCooldown(
        self:GetDamageCooldown(player, damageAmount)
    )

    Game():GetLevel():SetStateFlag(FLOOR_DAMAGED, true)

    if player:HasTrinket(PERFECTION) then
        player:TryRemoveTrinket(PERFECTION)
    end

    return false
end

return BethanyShieldModule
