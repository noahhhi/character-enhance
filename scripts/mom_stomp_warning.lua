local MomStompWarning = {}
MomStompWarning.__index = MomStompWarning

local SETTING = "momStompWarning"
local STOMP = EffectVariant.MOM_FOOT_STOMP
local IMPACT_FRAME = 27
local NATIVE_ANIMATION = "1000%.029_mom foot stomp%.anm2$"
local SHADOW_LAYER = 2
local TRANSPARENT_SHADOW_FRAME = 70
local RING_RADIUS = 90
local BASE_RADIUS = 60
local SOLID_WARNING_FRAMES = 9
local FADE_FRAMES = IMPACT_FRAME - SOLID_WARNING_FRAMES

-- Relative luminance of the parchment (#F4D7A5) and umber (#231319) strokes.
local PARCHMENT_LUMINANCE = 0.705506
local UMBER_LUMINANCE = 0.008933

-- Median linear-sRGB luminance of the vanilla floor art by BackdropType.
-- A few special rooms pack their floor into the room atlas itself.
local FLOOR_LUMINANCE = {
    [1] = 0.0769, [2] = 0.0659, [3] = 0.0470,
    [4] = 0.0483, [5] = 0.0322, [6] = 0.0290,
    [7] = 0.0214, [8] = 0.0170, [9] = 0.0167,
    [10] = 0.0306, [11] = 0.0213, [12] = 0.2378,
    [13] = 0.0680, [14] = 0.0077, [15] = 0.0399,
    [16] = 0.0100, [17] = 0.0479, [18] = 0.0077,
    [19] = 0.0284, [20] = 0.0659, [21] = 0.0937,
    [22] = 0.0470, [23] = 0.0352, [24] = 0.0262,
    [25] = 0.0212, [27] = 0.0249, [28] = 0.0478,
    [30] = 0.0197, [31] = 0.1286, [32] = 0.0239,
    [33] = 0.0206, [34] = 0.0624, [36] = 0.0211,
    [37] = 0.0227, [38] = 0.0186, [39] = 0.0239,
    [40] = 0.0206, [41] = 0.0160, [42] = 0.0206,
    [43] = 0.0504, [44] = 0.0173, [45] = 0.0373,
    [46] = 0.0337, [47] = 0.0099, [48] = 0.0624,
    [49] = 0.0599, [50] = 0.0599, [51] = 0.0311,
    [52] = 0.0396, [53] = 0.0106, [54] = 0.0612,
    [58] = 0.0239, [59] = 0.0337, [60] = 0.0175,
    [61] = 0.0410, [62] = 0.0260,
}

function MomStompWarning.New(context)
    local self = setmetatable({
        Context = context,
        Game = Game(),
        Warnings = {},
    }, MomStompWarning)

    context.Mod:AddCallback(ModCallbacks.MC_POST_EFFECT_INIT, function(_, effect)
        self:OnEffect(effect)
    end, STOMP)
    context.Mod:AddCallback(ModCallbacks.MC_POST_EFFECT_UPDATE, function(_, effect)
        self:OnEffect(effect)
    end, STOMP)
    context.Mod:AddCallback(ModCallbacks.MC_POST_ENTITY_REMOVE, function(_, entity)
        if entity.Variant == STOMP then
            self.Warnings[GetPtrHash(entity)] = nil
        end
    end, EntityType.ENTITY_EFFECT)
    context.Mod:AddCallback(ModCallbacks.MC_POST_RENDER, function()
        self:Render()
    end)
    context.Mod:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, function()
        self:OnGameStarted()
    end)
    context.Mod:AddCallback(ModCallbacks.MC_POST_NEW_ROOM, function()
        self:OnGameStarted()
    end)
    context.Mod:AddCallback(ModCallbacks.MC_PRE_MOD_UNLOAD, function(_, mod)
        if mod == context.Mod then
            self:RestoreShadows()
        end
    end)
    return self
end

function MomStompWarning:LoadMarker()
    if self.Marker == nil then
        local sprite = Sprite()
        sprite:Load("gfx/character-enhance/ce_mom_stomp_fade.anm2", true)
        self.Marker = sprite:IsLoaded() and sprite or false
    end
    return self.Marker
end

function MomStompWarning:OnEffect(effect)
    if not self.Context:IsEnabled(SETTING) then
        return
    end

    local sprite = effect:GetSprite()
    local frame = sprite:GetFrame()
    local hash = GetPtrHash(effect)
    local tracked = self.Warnings[hash]
    local stomping = sprite:IsPlaying("Stomp")
    if frame < 0 or frame >= IMPACT_FRAME or not stomping then
        if tracked then
            if stomping then
                sprite:SetLayerFrame(SHADOW_LAYER, frame)
            end
            self.Warnings[hash] = nil
        end
        return
    end

    if not tracked then
        if not sprite:GetFilename():lower():match(NATIVE_ANIMATION)
            or sprite:GetLayerCount() < 3 or not self:LoadMarker() then
            return
        end
        self.Warnings[hash] = effect
    end
    -- Move only the shadow layer's cursor to its transparent keyframe. The
    -- native animation clock still drives position, impact and the foot art.
    sprite:SetLayerFrame(SHADOW_LAYER, TRANSPARENT_SHADOW_FRAME)
end

function MomStompWarning:RestoreShadows()
    for hash, effect in pairs(self.Warnings) do
        if effect:Exists() then
            local sprite = effect:GetSprite()
            if sprite:IsPlaying("Stomp") then
                sprite:SetLayerFrame(SHADOW_LAYER, sprite:GetFrame())
            end
        end
        self.Warnings[hash] = nil
    end
end

function MomStompWarning:OnSettingChanged(enabled)
    if not enabled then
        self:RestoreShadows()
        return
    end
    for _, effect in ipairs(Isaac.FindByType(EntityType.ENTITY_EFFECT, STOMP, -1)) do
        self:OnEffect(effect)
    end
end

function MomStompWarning:OnGameStarted()
    self:RestoreShadows()
    self.MetricsFrame = nil
    self:OnSettingChanged(self.Context:IsEnabled(SETTING))
end

function MomStompWarning:OnPreGameExit()
    self:RestoreShadows()
    self.MetricsFrame = nil
end

function MomStompWarning:GetFrameMetrics()
    local frame = self.Game:GetFrameCount()
    if self.MetricsFrame == frame then
        return
    end
    self.MetricsFrame = frame

    local playerRadius, scissors = 0, 0
    for index = 0, self.Game:GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(index)
        if not player:IsDead() and not player:IsCoopGhost() then
            playerRadius = math.max(playerRadius, player.Size)
        end
        if player.Variant == 0 then
            scissors = scissors + player:GetTrinketMultiplier(TrinketType.TRINKET_SAFETY_SCISSORS)
        end
    end

    local toScreen = Isaac.WorldToScreenDistance(Vector(1, 1)) / RING_RADIUS
    self.NormalScale = toScreen * (BASE_RADIUS + playerRadius)
    -- Native non-player explosion size is reduced by stacked Safety Scissors.
    local blastScale = scissors >= 3 and 0.5 or scissors == 2 and 0.75 or 1
    self.UnownedScale = toScreen * (BASE_RADIUS * blastScale + playerRadius)

    local backdrop = self.Game:GetRoom():GetBackdropType()
    local luminance = FLOOR_LUMINANCE[backdrop] or 0.179
    local floor = luminance + 0.05
    local parchment = PARCHMENT_LUMINANCE + 0.05
    local umber = UMBER_LUMINANCE + 0.05
    local parchmentContrast = math.max(parchment, floor) / math.min(parchment, floor)
    local umberContrast = math.max(umber, floor) / math.min(umber, floor)
    self.MarkerPalette = umberContrast > parchmentContrast and "Umber" or "Parchment"
end

function MomStompWarning:Render()
    if not next(self.Warnings) then
        return
    end
    self:GetFrameMetrics()
    for _, effect in pairs(self.Warnings) do
        if effect:Exists() and effect.Visible then
            local frame = effect:GetSprite():GetFrame()
            if frame >= 0 and frame < IMPACT_FRAME then
                self:RenderWarning(effect, frame)
            end
        end
    end
end

function MomStompWarning:RenderWarning(effect, frame)
    local marker = self.Marker
    marker.Scale = effect.SpawnerType == EntityType.ENTITY_PLAYER
        and self.NormalScale or self.UnownedScale
    local fadeFrame = math.min(frame, FADE_FRAMES)
    local palette = self.MarkerPalette
    if fadeFrame ~= self.DrawnFrame or palette ~= self.DrawnPalette then
        -- Texture alpha carries the fade through the overlay compositor.
        marker:SetFrame(palette, fadeFrame)
        self.DrawnFrame, self.DrawnPalette = fadeFrame, palette
    end
    marker:Render(Isaac.WorldToScreen(effect.Position))
end

return MomStompWarning
