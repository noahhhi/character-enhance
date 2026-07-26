local BethanyShieldFeedbackModule = {}
BethanyShieldFeedbackModule.__index = BethanyShieldFeedbackModule

local SETTING_KEY = "bethanyShieldFeedback"
local SHIELD_SETTING_KEY = "bethanyDamageShield"
local BETHANY = PlayerType.PLAYER_BETHANY
local MAX_SOUL_CHARGE = 99
local HIT_FLASH_FRAMES = 10
local SHIELD_SPRITE_PATH = "gfx/1000.123_halo (static).anm2"

local HURT_SOUNDS = {
    SoundEffect.SOUND_ISAAC_HURT_GRUNT,
    SoundEffect.SOUND_CUTE_GRUNT,
    SoundEffect.SOUND_BABY_HURT,
}

local function Clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

function BethanyShieldFeedbackModule.New(context)
    local self = setmetatable({
        Context = context,
        Sfx = SFXManager(),
        ShieldSprites = {},
        HitUntilFrame = {},
    }, BethanyShieldFeedbackModule)

    context.Mod:AddCallback(
        ModCallbacks.MC_POST_GAME_STARTED,
        function()
            self:Reset()
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_PLAYER_RENDER,
        function(_, player, renderOffset)
            self:OnPlayerRender(player, renderOffset)
        end
    )

    return self
end

function BethanyShieldFeedbackModule:IsEnabled()
    return self.Context:IsEnabled(SETTING_KEY)
        and self.Context:IsEnabled(SHIELD_SETTING_KEY)
end

function BethanyShieldFeedbackModule:Reset()
    self.ShieldSprites = {}
    self.HitUntilFrame = {}
end

function BethanyShieldFeedbackModule:GetShieldSprite(playerHash)
    local sprite = self.ShieldSprites[playerHash]

    if sprite then
        return sprite
    end

    sprite = Sprite()
    sprite:Load(SHIELD_SPRITE_PATH, true)
    sprite:Play("Idle", true)
    self.ShieldSprites[playerHash] = sprite
    return sprite
end

function BethanyShieldFeedbackModule:SnapshotHurtSounds()
    local wasPlaying = {}

    for _, soundId in ipairs(HURT_SOUNDS) do
        wasPlaying[soundId] = self.Sfx:IsPlaying(soundId)
    end

    return wasPlaying
end

function BethanyShieldFeedbackModule:StopNewHurtSounds(wasPlaying)
    for _, soundId in ipairs(HURT_SOUNDS) do
        if not wasPlaying[soundId] and self.Sfx:IsPlaying(soundId) then
            self.Sfx:Stop(soundId)
        end
    end
end

function BethanyShieldFeedbackModule:PlayShieldSound(soulCharge)
    local strength = math.sqrt(Clamp(soulCharge, 0, MAX_SOUL_CHARGE)
        / MAX_SOUL_CHARGE)
    local pitch = 1.18 - strength * 0.36
    local volume = 0.54 + strength * 0.28

    self.Sfx:Play(
        SoundEffect.SOUND_FREEZE,
        volume,
        0,
        false,
        pitch
    )

    if strength >= 0.5 then
        self.Sfx:Play(
            SoundEffect.SOUND_STONE_IMPACT,
            0.12 + strength * 0.18,
            0,
            false,
            0.78 + strength * 0.08
        )
    end

    if soulCharge <= 0 then
        self.Sfx:Play(
            SoundEffect.SOUND_FREEZE_SHATTER,
            0.42,
            0,
            false,
            1.12
        )
    end
end

function BethanyShieldFeedbackModule:OnAbsorbedHit(
    player,
    damageAmount,
    damageFlags,
    source,
    damageCountdownFrames
)
    if not self:IsEnabled() then
        return false
    end

    local wasPlaying = self:SnapshotHurtSounds()

    player:TakeDamage(
        damageAmount,
        damageFlags | DamageFlag.DAMAGE_FAKE
            | DamageFlag.DAMAGE_NO_PENALTIES,
        source,
        damageCountdownFrames
    )

    self:StopNewHurtSounds(wasPlaying)
    self:PlayShieldSound(player:GetSoulCharge())

    local playerHash = GetPtrHash(player)
    self.HitUntilFrame[playerHash] = Game():GetFrameCount()
        + HIT_FLASH_FRAMES

    return true
end

function BethanyShieldFeedbackModule:OnPlayerRender(player, renderOffset)
    if not self:IsEnabled()
        or player:GetPlayerType() ~= BETHANY
    then
        return
    end

    local playerHash = GetPtrHash(player)
    local frame = Game():GetFrameCount()
    local soulCharge = player:GetSoulCharge()
    local hitUntilFrame = self.HitUntilFrame[playerHash] or 0

    if soulCharge <= 0 and hitUntilFrame <= frame then
        return
    end

    local sprite = self:GetShieldSprite(playerHash)
    local chargeRatio = Clamp(soulCharge, 0, MAX_SOUL_CHARGE)
        / MAX_SOUL_CHARGE
    local strength = math.sqrt(chargeRatio)
    local phase = frame * 0.075 + (playerHash % 31) * 0.21
    local timePulse = 0.5 + math.sin(phase) * 0.5
    local movement = Clamp(player.Velocity:Length() / 6, 0, 1)
    local hitFrames = math.max(
        0,
        hitUntilFrame - frame
    )
    local hitStrength = Clamp(hitFrames / HIT_FLASH_FRAMES, 0, 1)
    local alpha = (0.07 + strength * 0.23)
        * (0.78 + timePulse * 0.22)
        + movement * 0.025
        + hitStrength * 0.22
    local baseScale = 0.84 + strength * 0.16
        + math.sin(phase * 0.73) * 0.012
        + hitStrength * 0.055
    local squash = movement * math.sin(phase * 1.37) * 0.012
    local layerCount = soulCharge >= 24 and 3
        or soulCharge >= 8 and 2
        or 1
    local layerAlpha = Clamp(alpha / (1 + (layerCount - 1) * 0.65), 0, 0.7)
    local worldPosition = player.Position + player.PositionOffset
    local screenPosition = Isaac.WorldToScreen(worldPosition)
        + (renderOffset or Vector.Zero)

    for layer = 1, layerCount do
        local centeredLayer = layer - (layerCount + 1) / 2
        local layerScale = baseScale + centeredLayer * 0.026

        sprite.Scale = Vector(
            layerScale + squash,
            layerScale - squash
        )
        sprite.Color = Color(
            0.40 + hitStrength * 0.16,
            0.76 + hitStrength * 0.12,
            1,
            layerAlpha,
            0,
            0,
            0
        )
        sprite:Render(screenPosition)
    end
end

function BethanyShieldFeedbackModule:OnSettingChanged()
    self:Reset()
end

function BethanyShieldFeedbackModule:OnPreGameExit()
    self:Reset()
end

return BethanyShieldFeedbackModule
