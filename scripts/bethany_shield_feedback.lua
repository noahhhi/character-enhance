local BethanyShieldFeedbackModule = {}
BethanyShieldFeedbackModule.__index = BethanyShieldFeedbackModule

local SETTING_KEY = "bethanyShieldFeedback"
local SHIELD_SETTING_KEY = "bethanyDamageShield"
local BETHANY = PlayerType.PLAYER_BETHANY
local MAX_SOUL_CHARGE = 99
local HIT_FLASH_FRAMES = 10
local HURT_SOUND_SUPPRESSION_FRAMES = 4
local SHIELD_SPRITE_PATH = "gfx/1000.160_bishop shield.anm2"
local PARTICLE_SPRITE_PATH = "gfx/1000.085_diamond particle.anm2"
local MIN_PARTICLES = 3
local EXTRA_PARTICLES = 7

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
        PlayerVisuals = {},
        HitUntilFrame = {},
        HurtSoundSuppressions = {},
    }, BethanyShieldFeedbackModule)

    context.Mod:AddCallback(
        ModCallbacks.MC_POST_GAME_STARTED,
        function()
            self:Reset()
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_UPDATE,
        function()
            self:OnPostUpdate()
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
    self.PlayerVisuals = {}
    self.HitUntilFrame = {}
    self.HurtSoundSuppressions = {}
end

function BethanyShieldFeedbackModule:GetPlayerVisuals(playerHash)
    local visuals = self.PlayerVisuals[playerHash]

    if visuals then
        return visuals
    end

    local shield = Sprite()
    shield:Load(SHIELD_SPRITE_PATH, true)
    shield:Play("Idle", true)

    local particle = Sprite()
    particle:Load(PARTICLE_SPRITE_PATH, true)
    particle:Play("Idle", true)

    visuals = {
        Shield = shield,
        Particle = particle,
        LastUpdateFrame = -1,
    }
    self.PlayerVisuals[playerHash] = visuals
    return visuals
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

function BethanyShieldFeedbackModule:OnPostUpdate()
    if not self:IsEnabled() then
        self.HurtSoundSuppressions = {}
        return
    end

    local frame = Game():GetFrameCount()

    for playerHash, suppression in pairs(self.HurtSoundSuppressions) do
        if frame > suppression.UntilFrame then
            self.HurtSoundSuppressions[playerHash] = nil
        else
            self:StopNewHurtSounds(suppression.WasPlaying)
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
    local playerHash = GetPtrHash(player)
    local frame = Game():GetFrameCount()

    player:TakeDamage(
        damageAmount,
        damageFlags | DamageFlag.DAMAGE_FAKE
            | DamageFlag.DAMAGE_NO_PENALTIES,
        source,
        damageCountdownFrames
    )

    self:StopNewHurtSounds(wasPlaying)
    self.HurtSoundSuppressions[playerHash] = {
        WasPlaying = wasPlaying,
        UntilFrame = frame + HURT_SOUND_SUPPRESSION_FRAMES,
    }
    self:PlayShieldSound(player:GetSoulCharge())

    self.HitUntilFrame[playerHash] = frame + HIT_FLASH_FRAMES

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

    local visuals = self:GetPlayerVisuals(playerHash)
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
    local alpha = (0.05 + strength * 0.20)
        * (0.72 + timePulse * 0.28)
        + movement * 0.018
        + hitStrength * 0.20
    local baseScale = 0.78 + strength * 0.16
        + math.sin(phase * 0.73) * 0.010
        + hitStrength * 0.045
    local squash = movement * math.sin(phase * 1.37) * 0.009
    local worldPosition = player.Position + player.PositionOffset
    local screenPosition = Isaac.WorldToScreen(worldPosition)
        + (renderOffset or Vector.Zero)
        + Vector(0, -5)

    if visuals.LastUpdateFrame ~= frame then
        visuals.Shield:Update()
        visuals.Particle:Update()
        visuals.LastUpdateFrame = frame
    end

    visuals.Shield.Scale = Vector(
        baseScale + squash,
        baseScale * 0.78 - squash
    )
    visuals.Shield.Color = Color(
        0.30 + hitStrength * 0.20,
        0.72 + hitStrength * 0.16,
        1,
        Clamp(alpha, 0, 0.58),
        0,
        0,
        0
    )
    visuals.Shield.Rotation = math.sin(phase * 0.43) * 1.5
    visuals.Shield:Render(screenPosition)

    local particleCount = MIN_PARTICLES
        + math.floor(strength * EXTRA_PARTICLES + 0.5)

    for particleIndex = 1, particleCount do
        local particlePhase = phase * (0.72 + particleIndex * 0.017)
            + particleIndex * 2.399963
        local radialPulse = 0.88
            + math.sin(phase * 1.11 + particleIndex * 1.73) * 0.12
        local radius = (19 + (particleIndex * 7 % 11))
            * radialPulse
            * (0.82 + strength * 0.18)
        local x = math.cos(particlePhase) * radius
        local y = math.sin(particlePhase) * radius * 0.70
            + math.sin(phase * 1.39 + particleIndex) * 2.2
        local particlePulse = 0.5
            + math.sin(phase * 1.67 + particleIndex * 0.91) * 0.5
        local particleScale = 0.16 + strength * 0.08
            + particlePulse * 0.035
            + hitStrength * 0.055

        visuals.Particle.Scale = Vector(particleScale, particleScale)
        visuals.Particle.Color = Color(
            0.38 + hitStrength * 0.18,
            0.80 + hitStrength * 0.10,
            1,
            Clamp(
                (0.06 + strength * 0.16)
                    * (0.45 + particlePulse * 0.55)
                    + hitStrength * 0.13,
                0,
                0.52
            ),
            0,
            0,
            0
        )
        visuals.Particle.Rotation = frame * 1.2 + particleIndex * 37
        visuals.Particle:Render(screenPosition + Vector(x, y))
    end
end

function BethanyShieldFeedbackModule:OnSettingChanged()
    self:Reset()
end

function BethanyShieldFeedbackModule:OnPreGameExit()
    self:Reset()
end

return BethanyShieldFeedbackModule
