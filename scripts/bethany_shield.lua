local BethanyShieldModule = {}
BethanyShieldModule.__index = BethanyShieldModule

local SETTING_KEY = "bethanyDamageShield"
local BETHANY = PlayerType.PLAYER_BETHANY
local PERFECTION = TrinketType.TRINKET_PERFECTION
local FLOOR_DAMAGED = LevelStateFlag.STATE_DAMAGED

function BethanyShieldModule.New(context)
    local self = setmetatable({
        Context = context,
        ApplyingAbsorbedDamage = {},
    }, BethanyShieldModule)

    context.Mod:AddCallback(
        ModCallbacks.MC_POST_GAME_STARTED,
        function()
            self.ApplyingAbsorbedDamage = {}
        end
    )
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

    local playerHash = GetPtrHash(player)

    if self.ApplyingAbsorbedDamage[playerHash] then
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

    self.ApplyingAbsorbedDamage[playerHash] = true
    player:TakeDamage(
        damageAmount,
        damageFlags | DamageFlag.DAMAGE_FAKE | DamageFlag.DAMAGE_NO_PENALTIES,
        source,
        damageCountdownFrames
    )
    self.ApplyingAbsorbedDamage[playerHash] = nil

    Game():GetLevel():SetStateFlag(FLOOR_DAMAGED, true)

    if player:HasTrinket(PERFECTION) then
        player:TryRemoveTrinket(PERFECTION)
    end

    return false
end

function BethanyShieldModule:OnSettingChanged()
    self.ApplyingAbsorbedDamage = {}
end

function BethanyShieldModule:OnPreGameExit()
    self.ApplyingAbsorbedDamage = {}
end

return BethanyShieldModule
