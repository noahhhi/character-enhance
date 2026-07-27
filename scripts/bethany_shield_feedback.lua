local BethanyShieldFeedbackModule = {}
BethanyShieldFeedbackModule.__index = BethanyShieldFeedbackModule

local SETTING_KEY = "bethanyShieldFeedback"
local SHIELD_SETTING_KEY = "bethanyDamageShield"
local VISUAL_STYLE_KEY = "bethanyShieldVisualStyle"
local SOUND_STYLE_KEY = "bethanyShieldSoundStyle"
local HIT_STYLE_KEY = "bethanyShieldHitStyle"
local BETHANY = PlayerType.PLAYER_BETHANY
local MAX_SOUL_CHARGE = 99
local HIT_FLASH_FRAMES = 26
local PREVIEW_FRAMES = 60
local DISABLE_FADE_FRAMES = 15
local SHIELD_SPRITE_PATH = "gfx/1000.160_bishop shield.anm2"
local PARTICLE_SPRITE_PATH = "gfx/1000.085_diamond particle.anm2"
local PARTICLE_WALL_SPRITE_PATH =
    "gfx/character-enhance/ce_particle_wall.anm2"
local FROSTED_SOUL_SPRITE_PATH =
    "gfx/character-enhance/ce_frosted_soul.anm2"
local SHIELD_ANIMATION = "Hit"
local PARTICLE_WALL_ANIMATION = "Idle"
local FROSTED_SOUL_ANIMATION = "Idle"
local SHIELD_BODY_LAYER = 1
local SHIELD_GLOW_LAYER = 2
local PARTICLE_ANIMATION_COUNT = 8
local PARTICLE_COUNT = 14
local STYLE_SOUL_VEIL = 1
local STYLE_PARTICLE_WALL = 2
local STYLE_FROSTED_SOUL = 3
local STYLE_COUNT = 3
local HIT_STYLE_COUNT = 5
local CHARGE_RESPONSE_RATE = 4
local CHARGE_RESPONSE_DENOMINATOR = 1 - math.exp(-CHARGE_RESPONSE_RATE)
local SOUND_PROFILES = {
    [1] = {
        Gain = 1.00,
        PitchStart = 1.08,
        PitchEnd = 0.92,
        Thin = "Character Enhance Soul Glass Thin",
        Mid = "Character Enhance Soul Glass Mid",
        Thick = "Character Enhance Soul Glass Thick",
    },
    [2] = {
        Gain = 0.98,
        PitchStart = 1.05,
        PitchEnd = 0.94,
        Thin = "Character Enhance Aether Membrane Thin",
        Mid = "Character Enhance Aether Membrane Mid",
        Thick = "Character Enhance Aether Membrane Thick",
    },
    [3] = {
        Gain = 1.00,
        PitchStart = 1.07,
        PitchEnd = 0.91,
        Thin = "Character Enhance Wraith Prism Thin",
        Mid = "Character Enhance Wraith Prism Mid",
        Thick = "Character Enhance Wraith Prism Thick",
    },
}

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
    local normalized = Clamp(soulCharge, 0, MAX_SOUL_CHARGE)
        / MAX_SOUL_CHARGE

    return (1 - math.exp(-CHARGE_RESPONSE_RATE * normalized))
        / CHARGE_RESPONSE_DENOMINATOR
end

local SOUND_MID_STRENGTH = GetChargeStrength(30)

local function GetSoundWeights(strength)
    local progress

    if strength <= SOUND_MID_STRENGTH then
        progress = SmoothStep(
            0,
            1,
            strength / SOUND_MID_STRENGTH
        )
        return math.cos(progress * math.pi * 0.5),
            math.sin(progress * math.pi * 0.5),
            0
    end

    progress = SmoothStep(
        0,
        1,
        (strength - SOUND_MID_STRENGTH)
            / (1 - SOUND_MID_STRENGTH)
    )
    return 0,
        math.cos(progress * math.pi * 0.5),
        math.sin(progress * math.pi * 0.5)
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

local function GetPlayerSpriteScale(player)
    local spriteScale = player.SpriteScale

    if not spriteScale or type(spriteScale.X) ~= "number"
        or type(spriteScale.Y) ~= "number"
    then
        return 1, 1
    end

    return math.max(math.abs(spriteScale.X), 0.01),
        math.max(math.abs(spriteScale.Y), 0.01)
end

local function GetHitProfile(hitStyle, hitFrames)
    if hitFrames <= 0 then
        return 0, 0, 0, 0
    end

    local elapsed = HIT_FLASH_FRAMES - hitFrames
    local progress = Clamp(elapsed / HIT_FLASH_FRAMES, 0, 1)
    local tail = 1 - progress
    local peak = Clamp(1 - progress / 0.16, 0, 1)

    if hitStyle == 2 then
        local pulse = tail * (0.72 + math.sin(progress * math.pi) * 0.28)
        return pulse * 0.92, 0, tail * 0.22, progress
    end

    if hitStyle == 3 then
        return math.max(peak * 0.88, tail * 0.42),
            tail * 1.30,
            tail * 0.38,
            progress
    end

    if hitStyle == 4 then
        return math.max(peak * 1.65, tail * 0.58),
            0,
            math.max(peak * 2.00, tail * 0.86),
            progress
    end

    if hitStyle == 5 then
        local oscillation = 0.82 + math.sin(elapsed * 1.45) * 0.18
        return math.max(peak * 1.10, tail * 0.50 * oscillation),
            tail * 1.08,
            tail * 0.62,
            progress
    end

    local stepped = progress < 0.16 and 1.55
        or progress < 0.42 and 0.88
        or progress < 0.72 and 0.46
        or tail * 0.24
    return stepped, 0, tail * 0.34, progress
end

function BethanyShieldFeedbackModule.New(context)
    local self = setmetatable({
        Context = context,
        Sfx = SFXManager(),
        PlayerVisuals = {},
        HitUntilFrame = {},
        FadeOutUntilFrame = {},
        PreviewUntilFrame = {},
        SoundIds = {},
        MissingSoundWarnings = {},
    }, BethanyShieldFeedbackModule)

    self:ResolveSoundIds()

    context.Mod:AddCallback(
        ModCallbacks.MC_POST_GAME_STARTED,
        function()
            self:Reset()
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_PLAYER_RENDER,
        function(_, player)
            self:OnPlayerRender(player)
        end
    )

    return self
end

function BethanyShieldFeedbackModule:ResolveSoundIds()
    for style, profile in pairs(SOUND_PROFILES) do
        local ids = self.SoundIds[style] or {}

        for _, layer in ipairs({ "Thin", "Mid", "Thick" }) do
            if type(ids[layer]) ~= "number" or ids[layer] <= 0 then
                local soundName = profile[layer]
                local soundId = Isaac.GetSoundIdByName(soundName)
                ids[layer] = soundId

                if (type(soundId) ~= "number" or soundId <= 0)
                    and not self.MissingSoundWarnings[soundName]
                then
                    self.MissingSoundWarnings[soundName] = true

                    if Isaac.DebugString then
                        Isaac.DebugString(
                            "[Character Enhance] Missing shield sound: "
                                .. soundName .. " (restart Isaac after "
                                .. "installing audio resources)"
                        )
                    end
                end
            end
        end

        self.SoundIds[style] = ids
    end
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

function BethanyShieldFeedbackModule:GetParticleWall(visuals)
    if visuals.ParticleWall then
        return visuals.ParticleWall
    end

    local particleWall = Sprite()
    particleWall:Load(PARTICLE_WALL_SPRITE_PATH, true)
    particleWall:Play(PARTICLE_WALL_ANIMATION, true)
    particleWall:SetFrame(PARTICLE_WALL_ANIMATION, 0)
    visuals.ParticleWall = particleWall
    return particleWall
end

function BethanyShieldFeedbackModule:GetFrostedSoul(visuals)
    if visuals.FrostedSoul then
        return visuals.FrostedSoul
    end

    local frostedSoul = Sprite()
    frostedSoul:Load(FROSTED_SOUL_SPRITE_PATH, true)
    frostedSoul:Play(FROSTED_SOUL_ANIMATION, true)
    frostedSoul:SetFrame(FROSTED_SOUL_ANIMATION, 0)
    visuals.FrostedSoul = frostedSoul
    return frostedSoul
end

function BethanyShieldFeedbackModule:PlayShieldSound(soulCharge)
    self:ResolveSoundIds()
    local strength = GetChargeStrength(soulCharge)
    local soundStyle = self:GetStyle(SOUND_STYLE_KEY, STYLE_COUNT)
    local profile = SOUND_PROFILES[soundStyle]
    local ids = self.SoundIds[soundStyle]
    local thinWeight, midWeight, thickWeight = GetSoundWeights(strength)
    local masterVolume = profile.Gain * (0.88 + strength * 0.12)
    local pitch = profile.PitchStart
        + (profile.PitchEnd - profile.PitchStart) * strength
    local played = false

    local function PlayLayer(soundId, weight)
        if soundId and soundId > 0 and weight > 0.001 then
            self.Sfx:Play(
                soundId,
                masterVolume * weight,
                0,
                false,
                pitch,
                0
            )
            played = true
        end
    end

    PlayLayer(ids.Thin, thinWeight)
    PlayLayer(ids.Mid, midWeight)
    PlayLayer(ids.Thick, thickWeight)

    return played
end

function BethanyShieldFeedbackModule:PlayDisappearanceSound()
    local soundStyle = self:GetStyle(SOUND_STYLE_KEY, STYLE_COUNT)
    local profile = SOUND_PROFILES[soundStyle]
    local soundId = self.SoundIds[soundStyle].Thin

    if soundId and soundId > 0 then
        self.Sfx:Play(
            soundId,
            0.20 * profile.Gain,
            0,
            false,
            profile.PitchStart + 0.10,
            0
        )
    end
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

function BethanyShieldFeedbackModule:PreviewSound(soulCharge)
    if not self:IsEnabled() then
        return false
    end

    local previewCharge = type(soulCharge) == "number" and soulCharge or 30
    return self:PlayShieldSound(
        Clamp(previewCharge, 0, MAX_SOUL_CHARGE)
    )
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

function BethanyShieldFeedbackModule:OnPlayerRender(player)
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
        STYLE_COUNT
    )
    local phaseSpeed = visualStyle == STYLE_PARTICLE_WALL and 0.082
        or visualStyle == STYLE_FROSTED_SOUL and 0.035
        or 0.046
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
    local hitPeak = hitFrames > 0
        and Clamp(1 - hitProgress / 0.16, 0, 1)
        or 0
    local hitScaleOffset = 0

    if hitFrames > 0 then
        if hitStyle == 2 then
            hitScaleOffset = 0.085
                + math.sin(hitProgress * math.pi) * 0.105
        elseif hitStyle == 3 then
            hitScaleOffset = 0.025 * (1 - hitProgress)
        elseif hitStyle == 4 then
            hitScaleOffset = -0.030 * hitPeak
                + math.sin(hitProgress * math.pi) * 0.055
        elseif hitStyle == 5 then
            hitScaleOffset = -0.080 * hitPeak
                + math.sin(hitProgress * math.pi) * 0.090
        else
            hitScaleOffset = 0.018 * hitStrength
        end
    end

    local alpha = (0.12 + strength * 0.18 + thickness * 0.34
            + lowChargePresence * 0.025)
        * (0.74 + timePulse * 0.26)
        + movement * 0.018
        + hitStrength * 0.34
    alpha = alpha * fadeFactor
    local baseScale = 0.78 + strength * 0.16
        + math.sin(phase * 0.73) * 0.010
        + hitScaleOffset
    baseScale = baseScale * (0.90 + fadeFactor * 0.10)

    if visualStyle == STYLE_PARTICLE_WALL then
        alpha = alpha * (0.82 + timePulse * 0.18)
        baseScale = baseScale * (0.99 + timePulse * 0.025)
    elseif visualStyle == STYLE_FROSTED_SOUL then
        alpha = alpha * (0.88 + timePulse * 0.12)
        baseScale = baseScale * (0.985 + timePulse * 0.035)
    else
        baseScale = baseScale * (0.975 + timePulse * 0.045)
    end

    local squash = movement * math.sin(phase * 1.37) * 0.009
    local playerScaleX, playerScaleY = GetPlayerSpriteScale(player)
    -- WorldToScreen already includes room-camera scrolling. PositionOffset is
    -- a render-space player offset, so apply it once after conversion. Adding
    -- MC_POST_PLAYER_RENDER's RenderOffset here makes the shell drift away in
    -- large rooms as the camera moves.
    local screenPosition = Isaac.WorldToScreen(player.Position)
        + player.PositionOffset
        + Vector(0, -14 * playerScaleY)

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

    if visualStyle == STYLE_PARTICLE_WALL then
        shieldScaleX = shieldScaleX * (0.99 + timePulse * 0.025)
        shieldScaleY = shieldScaleY * (1.01 - timePulse * 0.015)
    elseif visualStyle == STYLE_FROSTED_SOUL then
        shieldScaleX = shieldScaleX * (0.985 + timePulse * 0.020)
        shieldScaleY = shieldScaleY * (1.025 + timePulse * 0.015)
    end

    shieldScaleX = shieldScaleX * playerScaleX
    shieldScaleY = shieldScaleY * playerScaleY
    local shieldRed = 0.30 + hitStrength * 0.20
    local shieldGreen = 0.72 + hitStrength * 0.16

    if visualStyle == STYLE_PARTICLE_WALL then
        shieldRed = 0.36 + hitStrength * 0.18
        shieldGreen = 0.82 + hitStrength * 0.10
    elseif visualStyle == STYLE_FROSTED_SOUL then
        shieldRed = 0.48 + hitStrength * 0.16
        shieldGreen = 0.78 + timePulse * 0.08
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
        Clamp(alpha, 0, hitFrames > 0 and 0.96 or 0.72),
        0,
        0,
        0
    )
    local shieldRotation

    if visualStyle == STYLE_PARTICLE_WALL then
        shieldRotation = math.sin(phase * 1.4) * 0.8
    elseif visualStyle == STYLE_FROSTED_SOUL then
        shieldRotation = math.sin(phase * 0.58) * 0.35
    else
        shieldRotation = math.sin(phase * 0.43) * 1.5
    end
    shieldRotation = shieldRotation
        + math.sin(phase * 3.2) * brittleness

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
        visuals.Shield:RenderLayer(SHIELD_BODY_LAYER, screenPosition)
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
                hitFrames > 0 and 0.96 or 0.68
            ),
            0,
            0,
            0
        )
        visuals.Shield.Rotation = shieldRotation + hitProgress * 8
        visuals.Shield:RenderLayer(SHIELD_GLOW_LAYER, screenPosition)
    end

    if visualStyle == STYLE_PARTICLE_WALL then
        local particleWall = self:GetParticleWall(visuals)
        local wallPulse = 0.96 + timePulse * 0.055
        local wallScale = (0.42 + strength * 0.035
                + thickness * 0.055)
            * wallPulse
        local wallAlpha = (0.10 + strength * 0.18
                + thickness * 0.28
                + hitStrength * 0.44)
            * fadeFactor

        particleWall.Scale = Vector(
            wallScale * playerScaleX,
            wallScale * playerScaleY * 1.04
        )
        particleWall.Color = Color(
            0.54 + hitStrength * 0.18,
            0.88 + hitStrength * 0.10,
            1,
            Clamp(wallAlpha, 0, hitFrames > 0 and 0.98 or 0.72),
            0,
            0,
            0
        )
        particleWall.Rotation = math.sin(phase * 0.52) * 1.8
        particleWall:SetFrame(PARTICLE_WALL_ANIMATION, 0)
        particleWall:Render(screenPosition)

        if thickness > 0.12 or hitStrength > 0 then
            local depthScale = 1.035 + thickness * 0.035
            particleWall.Scale = Vector(
                wallScale * depthScale * playerScaleX,
                wallScale * depthScale * playerScaleY * 1.04
            )
            particleWall.Color = Color(
                0.22,
                0.66 + hitStrength * 0.12,
                1,
                Clamp(
                    (0.055 + thickness * 0.16
                        + hitStrength * 0.24) * fadeFactor,
                    0,
                    0.52
                ),
                0,
                0,
                0
            )
            particleWall.Rotation = -math.sin(phase * 0.41) * 2.4
            particleWall:Render(screenPosition)
        end
    end


    if visualStyle == STYLE_FROSTED_SOUL then
        local frostedSoul = self:GetFrostedSoul(visuals)
        local frostScale = (0.415 + strength * 0.040
                + thickness * 0.060)
            * (0.975 + timePulse * 0.035)
        local frostAlpha = (0.28 + strength * 0.18
                + thickness * 0.24
                + hitStrength * 0.38)
            * fadeFactor

        frostedSoul.Scale = Vector(
            frostScale * playerScaleX,
            frostScale * playerScaleY * 1.045
        )
        frostedSoul.Color = Color(
            0.64 + hitStrength * 0.12,
            0.84 + hitStrength * 0.10,
            1,
            Clamp(frostAlpha, 0, hitFrames > 0 and 0.94 or 0.72),
            0,
            0,
            0
        )
        frostedSoul.Rotation = math.sin(phase * 0.47) * 0.42
        frostedSoul:SetFrame(FROSTED_SOUL_ANIMATION, 0)
        frostedSoul:Render(screenPosition)
    end

    -- Draw expanding impact rings last so the idle shell cannot cover them.
    if hitRing > 0 then
        local ringExpansion = hitStyle == 3
            and 1.03 + hitProgress * 0.52
            or 0.95 + hitProgress * 0.40
        local ringRed = hitStyle == 5 and 0.22 or 0.64
        local ringGreen = hitStyle == 5 and 0.42 or 0.96

        visuals.Shield.Scale = Vector(
            shieldScaleX * ringExpansion,
            shieldScaleY * ringExpansion
        )
        visuals.Shield.Color = Color(
            ringRed,
            ringGreen,
            1,
            Clamp(hitRing * 0.58 * fadeFactor, 0, 0.74),
            0,
            0,
            0
        )
        visuals.Shield.Rotation = shieldRotation
            + (hitStyle == 5 and hitProgress * 18
                or -hitProgress * 12)
        visuals.Shield:SetFrame(SHIELD_ANIMATION, 0)
        visuals.Shield:RenderLayer(SHIELD_BODY_LAYER, screenPosition)
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

        if visualStyle == STYLE_PARTICLE_WALL then
            particlePhase = ((particleIndex - 1) % 7)
                    * (math.pi * 2 / 7)
                + math.sin(phase * 0.43) * 0.075
        elseif visualStyle == STYLE_FROSTED_SOUL then
            particlePhase = phase * (0.24 + particleIndex * 0.006)
                + particleIndex * 2.399963
        end
        local radialPulse = 0.88
            + math.sin(phase * 1.11 + particleIndex * 1.73) * 0.12
        local radius = (19 + (particleIndex * 7 % 11))
            * radialPulse
            * (0.72 + strength * 0.10 + thickness * 0.38)
            + (1 - fadeFactor) * (4 + particleRank * 5)

        if visualStyle == STYLE_PARTICLE_WALL then
            local crystalRing = math.floor((particleIndex - 1) / 7)
            radius = (18 + crystalRing * 8)
                * (0.74 + strength * 0.10 + thickness * 0.38)
                + math.sin(phase * 3.4 + particleIndex * 1.37)
                    * (2.0 + strength * 2.8)
        elseif visualStyle == STYLE_FROSTED_SOUL then
            radius = (17 + (particleIndex * 5 % 10))
                * (0.75 + strength * 0.08 + thickness * 0.34)
                + math.sin(phase * 0.72 + particleIndex * 1.13) * 1.4
        end
        local burstDistance = hitStyle == 4
            and 8 + hitProgress * (20 + particleRank * 12)
            or 3 + hitProgress * (10 + particleRank * 7)
        radius = radius + particleBurst * burstDistance
        local x = math.cos(particlePhase) * radius * playerScaleX
        local orbitHeight = visualStyle == STYLE_PARTICLE_WALL and 0.92
            or visualStyle == STYLE_FROSTED_SOUL and 0.76
            or 0.88
        local y = math.sin(particlePhase) * radius * orbitHeight
            + math.sin(phase * 1.39 + particleIndex) * 2.2
        y = y * playerScaleY
        local particlePulse = 0.5
            + math.sin(phase * 1.67 + particleIndex * 0.91) * 0.5
        local particleScale = 0.11 + strength * 0.07
            + thickness * 0.18
            + particlePulse * 0.04
            + particleBurst * (hitStyle == 4 and 0.14 or 0.085)
        particleScale = particleScale * (0.72 + visibility * 0.28)

        visuals.Particle.Scale = Vector(
            particleScale * playerScaleX,
            particleScale * playerScaleY
        )
        local particleRed = 0.38 + thickness * 0.12
            + hitStrength * 0.18
        local particleGreen = 0.80 + thickness * 0.12
            + hitStrength * 0.10

        if visualStyle == STYLE_PARTICLE_WALL then
            particleRed = 0.52 + particlePulse * 0.10
            particleGreen = 0.92 + particlePulse * 0.06
        elseif visualStyle == STYLE_FROSTED_SOUL then
            particleRed = 0.68 + particlePulse * 0.08
            particleGreen = 0.86 + particlePulse * 0.08
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
                hitFrames > 0 and 0.96 or 0.70
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
