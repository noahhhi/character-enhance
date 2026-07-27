local BethanyShieldFeedbackModule = {}
BethanyShieldFeedbackModule.__index = BethanyShieldFeedbackModule

local SETTING_KEY = "bethanyShieldFeedback"
local SHIELD_SETTING_KEY = "bethanyDamageShield"
local VISUAL_STYLE_KEY = "bethanyShieldVisualStyle"
local SOUND_STYLE_KEY = "bethanyShieldSoundStyle"
local HIT_STYLE_KEY = "bethanyShieldHitStyle"
local BETHANY = PlayerType.PLAYER_BETHANY
local MAX_SOUL_CHARGE = 99
local HIT_FLASH_FRAMES = 18
local PREVIEW_FRAMES = 45
local DISABLE_FADE_FRAMES = 15
local SHIELD_SPRITE_PATH = "gfx/1000.160_bishop shield.anm2"
local PARTICLE_SPRITE_PATH = "gfx/1000.085_diamond particle.anm2"
local SHIELD_ANIMATION = "Hit"
local SHIELD_BODY_LAYER = 1
local SHIELD_GLOW_LAYER = 2
local PARTICLE_ANIMATION_COUNT = 8
local PARTICLE_COUNT = 14
local STYLE_SOUL_VEIL = 1
local STYLE_SHADOW_SIGIL = 2
local STYLE_CRYSTAL_HEART = 3
local HIT_STYLE_COUNT = 5

local function Clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function SmoothStep(edgeStart, edgeEnd, value)
    local normalized = Clamp(
        (value - edgeStart) / (edgeEnd - edgeStart),
        0,
        1
    )
    return normalized * normalized * (3 - 2 * normalized)
end

local function GetChargeStrength(soulCharge)
    return math.sqrt(
        Clamp(soulCharge, 0, MAX_SOUL_CHARGE) / MAX_SOUL_CHARGE
    )
end

local function GetShieldThickness(strength)
    -- Keep the shell readable at low charge while reserving most of the
    -- shadow, glow range, and particle mass for a nearly full shield.
    return Clamp(strength, 0, 1) ^ 2.3
end

local function GetLowChargePresence(strength)
    -- Bethany starts with 4 Soul Charge. Preserve a faint but dependable
    -- outline and shimmer across that small opening reserve.
    return SmoothStep(0, GetChargeStrength(4), strength)
end

local function GetHitProfile(hitStyle, hitFrames)
    if hitFrames <= 0 then
        return 0, 0, 0, 0
    end

    local elapsed = HIT_FLASH_FRAMES - hitFrames
    local progress = Clamp(elapsed / HIT_FLASH_FRAMES, 0, 1)
    local tail = 1 - progress
    local peak = elapsed < 4 and 1 or 0
    local afterglow = peak > 0 and 0
        or 0.56 * Clamp((hitFrames - 1) / 13, 0, 1)

    if hitStyle == 2 then
        local pulse = tail * tail
        return math.max(peak * 0.92, pulse * 0.72), 0,
            pulse * 0.55, progress
    end

    if hitStyle == 3 then
        return math.max(peak, afterglow * 0.75),
            tail * (0.30 + progress * 0.34),
            tail * 0.72,
            progress
    end

    if hitStyle == 4 then
        return peak > 0 and 1.16 or afterglow * 1.08,
            tail * 0.18,
            peak > 0 and 1.20 or tail * 0.82,
            progress
    end

    if hitStyle == 5 then
        local oscillation = 0.78 + math.sin(elapsed * 1.9) * 0.22
        return peak > 0 and 1.02 or afterglow * oscillation,
            tail * 0.38,
            tail * 0.48,
            progress
    end

    return math.max(peak, afterglow), 0, tail * 0.46, progress
end

function BethanyShieldFeedbackModule.New(context)
    local self = setmetatable({
        Context = context,
        Sfx = SFXManager(),
        PlayerVisuals = {},
        HitUntilFrame = {},
        FadeOutUntilFrame = {},
        PreviewUntilFrame = {},
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
    self.PlayerVisuals = {}
    self.HitUntilFrame = {}
    self.FadeOutUntilFrame = {}
    self.PreviewUntilFrame = {}
end

function BethanyShieldFeedbackModule:GetStyle(settingKey, maximum)
    local style = self.Context.Settings[settingKey]

    if type(style) ~= "number" or style < STYLE_SOUL_VEIL
        or style > maximum
    then
        return STYLE_SOUL_VEIL
    end

    return math.floor(style + 0.5)
end

function BethanyShieldFeedbackModule:GetPlayerVisuals(playerHash)
    local visuals = self.PlayerVisuals[playerHash]

    if visuals then
        return visuals
    end

    local shield = Sprite()
    shield:Load(SHIELD_SPRITE_PATH, true)
    shield:Play(SHIELD_ANIMATION, true)
    shield:SetFrame(SHIELD_ANIMATION, 0)

    local particle = Sprite()
    particle:Load(PARTICLE_SPRITE_PATH, true)
    particle:Play("Gib01", true)
    particle:SetFrame("Gib01", 0)

    visuals = {
        Shield = shield,
        Particle = particle,
        LastUpdateFrame = -1,
        LastStrength = 0,
    }
    self.PlayerVisuals[playerHash] = visuals
    return visuals
end

function BethanyShieldFeedbackModule:PlayShieldSound(soulCharge)
    local strength = GetChargeStrength(soulCharge)
    local soundStyle = self:GetStyle(SOUND_STYLE_KEY, STYLE_CRYSTAL_HEART)

    if soundStyle == STYLE_SHADOW_SIGIL then
        self.Sfx:Play(
            SoundEffect.SOUND_BOOK_SHADOWS_SIGIL,
            0.34 + strength * 0.34,
            0,
            false,
            1.10 - strength * 0.24
        )
        self.Sfx:Play(
            SoundEffect.SOUND_BOOK_PAGE_TURN_12,
            0.08 + strength * 0.10,
            0,
            false,
            1.12 - strength * 0.12
        )

        if soulCharge <= 0 then
            self.Sfx:Play(
                SoundEffect.SOUND_BOOK_SHADOWS_END,
                0.38,
                0,
                false,
                1.08
            )
        end

        return
    end

    if soundStyle == STYLE_CRYSTAL_HEART then
        self.Sfx:Play(
            SoundEffect.SOUND_HOLY_MANTLE,
            0.30 + strength * 0.36,
            0,
            false,
            1.14 - strength * 0.20
        )
        self.Sfx:Play(
            SoundEffect.SOUND_HOLY,
            0.06 + strength * 0.13,
            0,
            false,
            1.22 - strength * 0.10
        )

        return
    end

    local icePitch = 1.20 - strength * 0.38
    local iceVolume = 0.48 + strength * 0.34
    local stoneMix = SmoothStep(0.08, 0.92, strength)
    local stoneVolume = stoneMix * (0.10 + strength * 0.20)
    local stonePitch = 0.95 - strength * 0.17

    self.Sfx:Play(
        SoundEffect.SOUND_FREEZE,
        iceVolume,
        0,
        false,
        icePitch
    )

    if soulCharge > 0 then
        self.Sfx:Play(
            SoundEffect.SOUND_STONE_IMPACT,
            stoneVolume,
            0,
            false,
            stonePitch
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

function BethanyShieldFeedbackModule:PlayDisappearanceSound()
    local soundStyle = self:GetStyle(SOUND_STYLE_KEY, STYLE_CRYSTAL_HEART)

    if soundStyle == STYLE_SHADOW_SIGIL then
        self.Sfx:Play(
            SoundEffect.SOUND_BOOK_SHADOWS_END,
            0.32,
            0,
            false,
            1.10
        )
        return
    end

    if soundStyle == STYLE_CRYSTAL_HEART then
        self.Sfx:Play(
            SoundEffect.SOUND_HOLY_MANTLE,
            0.24,
            0,
            false,
            1.20
        )
        return
    end

    self.Sfx:Play(
        SoundEffect.SOUND_FREEZE_SHATTER,
        0.30,
        0,
        false,
        1.18
    )
end

function BethanyShieldFeedbackModule:ForEachBethany(callback)
    local game = Game()

    if not game.GetNumPlayers or not Isaac.GetPlayer then
        return false
    end

    local found = false

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(playerIndex)

        if player and player:GetPlayerType() == BETHANY then
            callback(player)
            found = true
        end
    end

    return found
end

function BethanyShieldFeedbackModule:PreviewAnimation()
    if not self:IsEnabled() then
        return false
    end

    local frame = Game():GetFrameCount()

    return self:ForEachBethany(function(player)
        local playerHash = GetPtrHash(player)
        self:GetPlayerVisuals(playerHash)
        self.PreviewUntilFrame[playerHash] = frame + PREVIEW_FRAMES
        self.HitUntilFrame[playerHash] = nil
    end)
end

function BethanyShieldFeedbackModule:PreviewHit()
    if not self:IsEnabled() then
        return false
    end

    local frame = Game():GetFrameCount()

    return self:ForEachBethany(function(player)
        local playerHash = GetPtrHash(player)
        self:GetPlayerVisuals(playerHash)
        self.PreviewUntilFrame[playerHash] = frame + PREVIEW_FRAMES
        self.HitUntilFrame[playerHash] = frame + HIT_FLASH_FRAMES
    end)
end

function BethanyShieldFeedbackModule:PreviewSound()
    if not self:IsEnabled() then
        return false
    end

    self:PlayShieldSound(50)
    return true
end

function BethanyShieldFeedbackModule:OnAbsorbedHit(player)
    if not self:IsEnabled() then
        return false
    end

    local playerHash = GetPtrHash(player)
    local frame = Game():GetFrameCount()

    -- Never call TakeDamage for feedback. Repentance+ 1.9.7.15 routes even a
    -- zero-value DAMAGE_FAKE hit through Bethany's hurt voice and full hit
    -- animation. The shield module's real cancelled hit plus explicit damage
    -- cooldown already provides the desired stationary invulnerability flash.
    self:PlayShieldSound(player:GetSoulCharge())

    self.HitUntilFrame[playerHash] = frame + HIT_FLASH_FRAMES

    return true
end

function BethanyShieldFeedbackModule:OnPlayerRender(player, renderOffset)
    if player:GetPlayerType() ~= BETHANY then
        return
    end

    local playerHash = GetPtrHash(player)
    local frame = Game():GetFrameCount()
    local enabled = self:IsEnabled()
    local fadeOutUntilFrame = self.FadeOutUntilFrame[playerHash] or 0
    local fadingOut = not enabled and fadeOutUntilFrame >= frame

    if not enabled and not fadingOut then
        self.PlayerVisuals[playerHash] = nil
        self.HitUntilFrame[playerHash] = nil
        self.FadeOutUntilFrame[playerHash] = nil
        return
    end

    local soulCharge = player:GetSoulCharge()
    local hitUntilFrame = self.HitUntilFrame[playerHash] or 0
    local previewUntilFrame = self.PreviewUntilFrame[playerHash] or 0
    local previewing = enabled and previewUntilFrame >= frame

    if enabled and soulCharge <= 0 and hitUntilFrame <= frame
        and not previewing
    then
        return
    end

    local visuals = self:GetPlayerVisuals(playerHash)
    local strength
    local fadeFactor = 1

    if enabled then
        strength = GetChargeStrength(soulCharge)

        if previewing then
            strength = math.max(strength, 0.72)
        else
            self.PreviewUntilFrame[playerHash] = nil
        end

        visuals.LastStrength = strength
    else
        strength = visuals.LastStrength
        fadeFactor = Clamp(
            (fadeOutUntilFrame - frame) / DISABLE_FADE_FRAMES,
            0,
            1
        )
    end

    local visualStyle = self:GetStyle(
        VISUAL_STYLE_KEY,
        STYLE_CRYSTAL_HEART
    )
    local phaseSpeed = visualStyle == STYLE_SHADOW_SIGIL and 0.052
        or visualStyle == STYLE_CRYSTAL_HEART and 0.095
        or 0.075
    local phase = frame * phaseSpeed + (playerHash % 31) * 0.21
    local timePulse = 0.5 + math.sin(phase) * 0.5
    local movement = Clamp(player.Velocity:Length() / 6, 0, 1)
    local thickness = GetShieldThickness(strength)
    local lowChargePresence = GetLowChargePresence(strength)
    local hitFrames = math.max(
        0,
        hitUntilFrame - frame
    )
    local hitStyle = self:GetStyle(HIT_STYLE_KEY, HIT_STYLE_COUNT)
    local hitStrength, hitRing, particleBurst, hitProgress = GetHitProfile(
        hitStyle,
        hitFrames
    )
    local alpha = (0.12 + strength * 0.18 + thickness * 0.34
            + lowChargePresence * 0.025)
        * (0.74 + timePulse * 0.26)
        + movement * 0.018
        + hitStrength * 0.20
    alpha = alpha * fadeFactor
    local baseScale = 0.78 + strength * 0.16
        + math.sin(phase * 0.73) * 0.010
        + hitStrength * 0.045
    baseScale = baseScale * (0.90 + fadeFactor * 0.10)

    if visualStyle == STYLE_SHADOW_SIGIL then
        alpha = alpha * (0.86 + timePulse * 0.18)
        baseScale = baseScale * (0.96 + timePulse * 0.045)
    elseif visualStyle == STYLE_CRYSTAL_HEART then
        alpha = alpha * (1.08 + hitStrength * 0.08)
        baseScale = baseScale * (1.01 + timePulse * 0.018)
    end

    local squash = movement * math.sin(phase * 1.37) * 0.009
    local worldPosition = player.Position + player.PositionOffset
    local screenPosition = Isaac.WorldToScreen(worldPosition)
        + (renderOffset or Vector.Zero)
        + Vector(0, -14)

    if visuals.LastUpdateFrame ~= frame then
        visuals.Shield:Update()
        visuals.Particle:Update()
        visuals.LastUpdateFrame = frame
    end

    local shieldScaleX = baseScale + squash
    local shieldScaleY = baseScale * 1.04 - squash
    local brittleness = 1 - thickness
    local brittleJitter = math.sin(phase * 4.7) * 0.008
        * brittleness
    shieldScaleX = shieldScaleX + brittleJitter
    shieldScaleY = shieldScaleY - brittleJitter * 0.7
    local shieldRed = 0.30 + hitStrength * 0.20
    local shieldGreen = 0.72 + hitStrength * 0.16

    if visualStyle == STYLE_SHADOW_SIGIL then
        shieldRed = 0.24 + hitStrength * 0.14
        shieldGreen = 0.52 + timePulse * 0.10
    elseif visualStyle == STYLE_CRYSTAL_HEART then
        shieldRed = 0.36 + hitStrength * 0.18
        shieldGreen = 0.82 + hitStrength * 0.10
    end

    if hitStyle == 4 then
        shieldRed = shieldRed + hitStrength * 0.14
        shieldGreen = shieldGreen + hitStrength * 0.12
    elseif hitStyle == 5 then
        shieldRed = shieldRed + hitStrength * 0.22
        shieldGreen = shieldGreen + hitStrength * 0.08
    end

    local shieldColor = Color(
        shieldRed,
        shieldGreen,
        1,
        Clamp(alpha, 0, 0.72),
        0,
        0,
        0
    )
    local shieldRotation

    if visualStyle == STYLE_SHADOW_SIGIL then
        shieldRotation = frame * 0.24
            + math.sin(phase * 0.67) * 4.5
    elseif visualStyle == STYLE_CRYSTAL_HEART then
        shieldRotation = math.sin(phase * 1.4) * 0.8
    else
        shieldRotation = math.sin(phase * 0.43) * 1.5
    end
    shieldRotation = shieldRotation
        + math.sin(phase * 3.2) * brittleness

    if hitRing > 0 then
        local ringExpansion = 1.04 + hitProgress * 0.24
        local ringRed = hitStyle == 5 and 0.54 or 0.52
        local ringGreen = hitStyle == 5 and 0.56 or 0.90

        visuals.Shield.Scale = Vector(
            shieldScaleX * ringExpansion,
            shieldScaleY * ringExpansion
        )
        visuals.Shield.Color = Color(
            ringRed,
            ringGreen,
            1,
            Clamp(hitRing * 0.42 * fadeFactor, 0, 0.46),
            0,
            0,
            0
        )
        visuals.Shield.Rotation = shieldRotation - hitProgress * 12
        visuals.Shield:SetFrame(SHIELD_ANIMATION, 0)
        visuals.Shield:RenderLayer(SHIELD_BODY_LAYER, screenPosition)
    end

    if thickness > 0 then
        local shadowExpansion = 1.01 + thickness * 0.13
        visuals.Shield.Scale = Vector(
            shieldScaleX * shadowExpansion,
            shieldScaleY * shadowExpansion
        )
        visuals.Shield.Color = Color(
            0.08 + thickness * 0.06,
            0.22 + thickness * 0.10,
            0.48 + thickness * 0.12,
            Clamp(
                (0.012 + thickness * 0.26
                    + lowChargePresence * 0.015) * fadeFactor,
                0,
                0.29
            ),
            0,
            0,
            0
        )
        visuals.Shield.Rotation = shieldRotation
        visuals.Shield:SetFrame(SHIELD_ANIMATION, 0)
        visuals.Shield:RenderLayer(
            SHIELD_BODY_LAYER,
            screenPosition + Vector(0, 0.5 + thickness * 1.5)
        )
    end

    visuals.Shield.Scale = Vector(shieldScaleX, shieldScaleY)
    visuals.Shield.Color = shieldColor
    visuals.Shield.Rotation = shieldRotation
    visuals.Shield:SetFrame(SHIELD_ANIMATION, 0)
    visuals.Shield:RenderLayer(SHIELD_BODY_LAYER, screenPosition)

    if thickness > 0 or hitStrength > 0 then
        local glowScale = 1.015 + thickness * 0.16
            + hitStrength * 0.08
        visuals.Shield.Scale = Vector(
            shieldScaleX * glowScale,
            shieldScaleY * glowScale
        )
        visuals.Shield.Color = Color(
            0.52 + thickness * 0.16 + hitStrength * 0.16,
            0.82 + thickness * 0.10 + hitStrength * 0.08,
            1,
            Clamp(
                (0.018 + thickness * 0.40
                    + lowChargePresence * 0.020
                    + hitStrength * 0.34)
                    * fadeFactor,
                0,
                0.68
            ),
            0,
            0,
            0
        )
        visuals.Shield.Rotation = shieldRotation + hitProgress * 8
        visuals.Shield:RenderLayer(SHIELD_GLOW_LAYER, screenPosition)
    end

    for particleIndex = 1, PARTICLE_COUNT do
        local particleRank = (particleIndex - 1) / (PARTICLE_COUNT - 1)
        local chargeVisibility = SmoothStep(
            particleRank - 0.22,
            particleRank + 0.02,
            strength
        )
        local impactVisibility = math.max(hitStrength, particleBurst)
            * (1 - particleRank * 0.35)
        local visibility = math.max(
            chargeVisibility,
            impactVisibility
        ) * fadeFactor
        local particlePhase = phase * (0.72 + particleIndex * 0.017)
            + particleIndex * 2.399963

        if visualStyle == STYLE_SHADOW_SIGIL then
            particlePhase = phase * 1.45 + particleIndex * 0.628319
        elseif visualStyle == STYLE_CRYSTAL_HEART then
            particlePhase = phase * (1.05 + particleIndex * 0.013)
                + particleIndex * 2.399963
        end
        local radialPulse = 0.88
            + math.sin(phase * 1.11 + particleIndex * 1.73) * 0.12
        local radius = (19 + (particleIndex * 7 % 11))
            * radialPulse
            * (0.72 + strength * 0.10 + thickness * 0.38)
            + (1 - fadeFactor) * (4 + particleRank * 5)

        if visualStyle == STYLE_SHADOW_SIGIL then
            radius = (21 + particleRank * 7)
                * (0.94 + timePulse * 0.06)
                * (0.72 + strength * 0.10 + thickness * 0.38)
                + (1 - fadeFactor) * (5 + particleRank * 5)
        elseif visualStyle == STYLE_CRYSTAL_HEART then
            radius = radius + math.sin(
                phase * 3.1 + particleIndex * 1.7
            ) * 1.8
        end
        radius = radius + particleBurst
            * (3 + hitProgress * (8 + particleRank * 5))
        local x = math.cos(particlePhase) * radius
        local y = math.sin(particlePhase) * radius * 0.88
            + math.sin(phase * 1.39 + particleIndex) * 2.2
        local particlePulse = 0.5
            + math.sin(phase * 1.67 + particleIndex * 0.91) * 0.5
        local particleScale = 0.11 + strength * 0.07
            + thickness * 0.18
            + particlePulse * 0.04
            + particleBurst * 0.075
        particleScale = particleScale * (0.72 + visibility * 0.28)

        visuals.Particle.Scale = Vector(particleScale, particleScale)
        local particleRed = 0.38 + thickness * 0.12
            + hitStrength * 0.18
        local particleGreen = 0.80 + thickness * 0.12
            + hitStrength * 0.10

        if visualStyle == STYLE_SHADOW_SIGIL then
            particleRed = 0.32 + hitStrength * 0.12
            particleGreen = 0.58 + particlePulse * 0.12
        elseif visualStyle == STYLE_CRYSTAL_HEART then
            particleRed = 0.44 + particlePulse * 0.08
            particleGreen = 0.88
        end

        if hitStyle == 4 then
            particleRed = particleRed + particleBurst * 0.16
            particleGreen = particleGreen + particleBurst * 0.10
        elseif hitStyle == 5 then
            particleRed = particleRed + particleBurst * 0.20
            particleGreen = particleGreen - particleBurst * 0.08
        end

        visuals.Particle.Color = Color(
            particleRed,
            particleGreen,
            1,
            Clamp(
                (0.06 + strength * 0.10 + thickness * 0.48
                    + lowChargePresence * 0.025)
                    * (0.45 + particlePulse * 0.55)
                    * visibility
                    + particleBurst * 0.16 * impactVisibility,
                0,
                0.70
            ),
            0,
            0,
            0
        )
        visuals.Particle.Rotation = frame * 1.2 + particleIndex * 37
        local particleAnimation = string.format(
            "Gib%02d",
            (particleIndex - 1) % PARTICLE_ANIMATION_COUNT + 1
        )
        local particleFrame = math.floor(
            (frame * 0.55 + particleIndex * 1.7) % 9
        )
        visuals.Particle:SetFrame(particleAnimation, particleFrame)
        visuals.Particle:Render(screenPosition + Vector(x, y))
    end
end

function BethanyShieldFeedbackModule:StartFadeOut()
    local frame = Game():GetFrameCount()
    local startedFade = false

    for playerHash in pairs(self.PlayerVisuals) do
        if not self.FadeOutUntilFrame[playerHash] then
            self.FadeOutUntilFrame[playerHash] = frame
                + DISABLE_FADE_FRAMES
            startedFade = true
        end
    end

    self.HitUntilFrame = {}
    self.PreviewUntilFrame = {}

    if startedFade then
        self:PlayDisappearanceSound()
    end
end

function BethanyShieldFeedbackModule:OnSettingChanged(_, settingKey)
    if settingKey == VISUAL_STYLE_KEY or settingKey == SOUND_STYLE_KEY
        or settingKey == HIT_STYLE_KEY
    then
        self.PlayerVisuals = {}
        self.FadeOutUntilFrame = {}
        return
    end

    if self:IsEnabled() then
        self:Reset()
        return
    end

    self:StartFadeOut()
end

function BethanyShieldFeedbackModule:OnShieldSettingChanged(enabled)
    if enabled and self.Context:IsEnabled(SETTING_KEY) then
        self:Reset()
        return
    end

    self:StartFadeOut()
end

function BethanyShieldFeedbackModule:OnPreGameExit()
    self:Reset()
end

return BethanyShieldFeedbackModule
