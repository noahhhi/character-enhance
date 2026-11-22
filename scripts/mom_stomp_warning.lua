local MomStompWarning = {}
MomStompWarning.__index = MomStompWarning

local SETTING = "momStompWarning"
local MARKER_NAME = "Character Enhance Stomp Marker"
local STOMP = EffectVariant.MOM_FOOT_STOMP
local MOM = EntityType.ENTITY_MOM
local SATAN = EntityType.ENTITY_SATAN
local BOSS_FOOT = 10
local NPC_VARIANTS = {
    [MOM] = -1, -- Both the door and foot entities share this type.
    [SATAN] = BOSS_FOOT,
    [EntityType.ENTITY_MOMS_HAND] = 0,
    [EntityType.ENTITY_MOMS_DEAD_HAND] = 0,
}
local IMPACT_FRAME = 27
local HAND_IMPACT_FRAME = 12
local ARM_IMPACT_FRAME = 7
local NATIVE_ANIMATION = "1000%.029_mom foot stomp%.anm2$"
local SHADOW_LAYER = 2
local TRANSPARENT_SHADOW_FRAME = 70
local RING_RADIUS = 90
local BASE_RADIUS = 60
local BOSS_RADIUS = 50
local SATAN_RADIUS = 70
local SOLID_WARNING_FRAMES = 9
local FADE_FRAMES = IMPACT_FRAME - SOLID_WARNING_FRAMES
local BOSS_IMPACT_FRAMES = {
    [MOM] = { Stomp = 27, QuickStompBegin = 27, QuickStomp = 7, QuickStompEnd = 7 },
    [SATAN] = { Stomp = 26 },
}

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
        MarkerVariant = Isaac.GetEntityVariantByName(MARKER_NAME),
        Warnings = {},
        NpcWarnings = {},
    }, MomStompWarning)

    context.Mod:AddCallback(ModCallbacks.MC_POST_EFFECT_INIT, function(_, effect)
        self:OnEffect(effect)
    end, STOMP)
    for kind in pairs(NPC_VARIANTS) do
        context.Mod:AddCallback(ModCallbacks.MC_NPC_UPDATE, function(_, npc)
            self:OnNPC(npc)
        end, kind)
        context.Mod:AddCallback(ModCallbacks.MC_POST_ENTITY_REMOVE, function(_, npc)
            self:RemoveWarning(self.NpcWarnings, npc)
        end, kind)
    end
    context.Mod:AddCallback(ModCallbacks.MC_POST_EFFECT_UPDATE, function(_, effect)
        self:OnEffect(effect)
    end, STOMP)
    context.Mod:AddCallback(ModCallbacks.MC_POST_ENTITY_REMOVE, function(_, entity)
        if entity.Variant == STOMP then
            self:RemoveWarning(self.Warnings, entity)
        end
    end, EntityType.ENTITY_EFFECT)
    -- Let other update callbacks finish spawning and moving stomp sources.
    context.Mod:AddPriorityCallback(ModCallbacks.MC_POST_UPDATE, CallbackPriority.LATE, function()
        self:UpdateMarkers()
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

function MomStompWarning:OnEffect(effect)
    if self.MarkerVariant <= 0 or not self.Context:IsEnabled(SETTING) then
        return
    end

    local hash = GetPtrHash(effect)
    if self.Warnings[hash] then
        return
    end

    local sprite = effect:GetSprite()
    if sprite:IsPlaying("Stomp") and sprite:GetFrame() < IMPACT_FRAME
        and sprite:GetFilename():lower():match(NATIVE_ANIMATION) and sprite:GetLayerCount() >= 3 then
        self.Warnings[hash] = { Source = effect }
    end
end

local function RestoreShadow(warning)
    if warning.ShadowHidden and warning.Source:Exists() then
        local sprite = warning.Source:GetSprite()
        if sprite:IsPlaying("Stomp") then
            sprite:SetLayerFrame(SHADOW_LAYER, sprite:GetFrame())
        end
    end
    warning.ShadowHidden = nil
end

local function RemoveMarker(warning)
    local marker = warning.Marker
    if marker and marker:Exists() then
        marker.Visible = false
        marker:Remove()
    end
    warning.Marker, warning.Frame, warning.Palette, warning.Scale = nil, nil, nil, nil
end

function MomStompWarning:RemoveWarning(warnings, source)
    local hash = GetPtrHash(source)
    local warning = warnings[hash]
    if warning then
        RemoveMarker(warning)
        warnings[hash] = nil
    end
end

function MomStompWarning:RestoreShadows()
    for hash, warning in pairs(self.Warnings) do
        RestoreShadow(warning)
        RemoveMarker(warning)
        self.Warnings[hash] = nil
    end
    for hash, warning in pairs(self.NpcWarnings) do
        RemoveMarker(warning)
        self.NpcWarnings[hash] = nil
    end
end

local function BossImpact(npc)
    if npc.State ~= NpcState.STATE_STOMP and (npc.Type ~= MOM or npc.State ~= NpcState.STATE_JUMP) then
        return nil
    end
    local sprite = npc:GetSprite()
    local name = sprite:GetAnimation()
    local impact = BOSS_IMPACT_FRAMES[npc.Type][name]
    if impact and sprite:IsPlaying(name) then
        local frame = sprite:GetFrame()
        if frame >= 0 and frame < impact then
            return impact, frame
        end
    end
end

local function ContactImpact(npc)
    local isDoor = npc.Type == MOM
    local state = isDoor and NpcState.STATE_ATTACK2 or NpcState.STATE_STOMP
    if npc.State ~= state or npc:HasEntityFlags(EntityFlag.FLAG_FRIENDLY)
        or npc:HasEntityFlags(EntityFlag.FLAG_CHARM) then
        return nil
    end
    local sprite = npc:GetSprite()
    local animation = isDoor and "ArmOpen" or "JumpDown"
    local impact = isDoor and ARM_IMPACT_FRAME or HAND_IMPACT_FRAME
    local frame = sprite:GetFrame()
    if frame >= 0 and frame < impact and sprite:IsPlaying(animation) then
        return impact, frame
    end
end

function MomStompWarning:OnNPC(npc)
    if self.MarkerVariant <= 0 or not self.Context:IsEnabled(SETTING) then
        return
    end
    local kind, variant = npc.Type, npc.Variant
    if variant ~= NPC_VARIANTS[kind] and not (kind == MOM and (variant == 0 or variant == BOSS_FOOT)) then
        return
    end
    local hash = GetPtrHash(npc)
    if not self.NpcWarnings[hash] then
        self.NpcWarnings[hash] = { Source = npc }
    end
end

function MomStompWarning:OnSettingChanged(enabled)
    if not enabled then
        self:RestoreShadows()
        return
    end
    if self.MarkerVariant <= 0 then
        return
    end
    for _, effect in ipairs(Isaac.FindByType(EntityType.ENTITY_EFFECT, STOMP, -1)) do
        self:OnEffect(effect)
    end
    for kind, variant in pairs(NPC_VARIANTS) do
        for _, entity in ipairs(Isaac.FindByType(kind, variant, -1)) do
            local npc = entity:ToNPC()
            if npc then self:OnNPC(npc) end
        end
    end
    self:UpdateMarkers()
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
    self.WorldScale, self.PlayerRadius = toScreen, playerRadius
    self.NormalScale = toScreen * (BASE_RADIUS + playerRadius)
    -- Native non-player explosion size is reduced by stacked Safety Scissors.
    local blastScale = scissors >= 3 and 0.5 or scissors == 2 and 0.75 or 1
    self.BlastScale = blastScale
    self.UnownedScale = toScreen * (BASE_RADIUS * blastScale + playerRadius)
    self.BossScale = toScreen * (BOSS_RADIUS * blastScale + playerRadius)

    local backdrop = self.Game:GetRoom():GetBackdropType()
    local luminance = FLOOR_LUMINANCE[backdrop] or 0.179
    local floor = luminance + 0.05
    local parchment = PARCHMENT_LUMINANCE + 0.05
    local umber = UMBER_LUMINANCE + 0.05
    local parchmentContrast = math.max(parchment, floor) / math.min(parchment, floor)
    local umberContrast = math.max(umber, floor) / math.min(umber, floor)
    self.MarkerPalette = umberContrast > parchmentContrast and "Umber" or "Parchment"
end

function MomStompWarning:UpdateMarkers()
    if not next(self.Warnings) and not next(self.NpcWarnings) then
        return
    end
    for hash, warning in pairs(self.Warnings) do
        local effect = warning.Source
        if effect:Exists() then
            local sprite = effect:GetSprite()
            local frame = sprite:GetFrame()
            if frame >= 0 and frame < IMPACT_FRAME and sprite:IsPlaying("Stomp") then
                self:GetFrameMetrics()
                local scale = effect.SpawnerType == EntityType.ENTITY_PLAYER
                    and self.NormalScale or self.UnownedScale
                if self:UpdateMarker(warning, scale, frame) then
                    -- Hide only the native shadow once its replacement exists.
                    sprite:SetLayerFrame(SHADOW_LAYER, TRANSPARENT_SHADOW_FRAME)
                    warning.ShadowHidden = true
                else
                    RestoreShadow(warning)
                end
            else
                RestoreShadow(warning)
                RemoveMarker(warning)
                self.Warnings[hash] = nil
            end
        else
            RemoveMarker(warning)
            self.Warnings[hash] = nil
        end
    end
    for hash, warning in pairs(self.NpcWarnings) do
        local npc = warning.Source
        if npc:Exists() then
            local isFoot = npc.Variant == BOSS_FOOT
            local getImpact = isFoot and BossImpact or ContactImpact
            local impact, frame = getImpact(npc)
            if impact then
                self:GetFrameMetrics()
                local scale
                if npc.Type == SATAN then
                    scale = self.WorldScale * (SATAN_RADIUS * self.BlastScale + self.PlayerRadius)
                elseif isFoot then
                    scale = self.BossScale
                else
                    scale = self.WorldScale * (npc.Size + self.PlayerRadius)
                end
                -- Keep a brief solid warning even on the faster attacks.
                local fadeDuration = math.max(3, impact - SOLID_WARNING_FRAMES)
                local fadeFrame = math.floor(frame * FADE_FRAMES / fadeDuration)
                self:UpdateMarker(warning, scale, fadeFrame)
            elseif warning.Marker then
                RemoveMarker(warning)
            end
        else
            RemoveMarker(warning)
            self.NpcWarnings[hash] = nil
        end
    end
end

function MomStompWarning:UpdateMarker(warning, scale, frame)
    local source = warning.Source
    local marker = warning.Marker
    if not marker or not marker:Exists() then
        RemoveMarker(warning)
        -- Use a deterministic visual seed without consuming the gameplay RNG.
        local seed = (source.InitSeed ~ 0x43454D4F) & 0xFFFFFFFF
        local entity = self.Game:Spawn(EntityType.ENTITY_EFFECT, self.MarkerVariant,
            source.Position, Vector.Zero, nil, 0, seed ~= 0 and seed or 1)
        marker = entity and entity:ToEffect()
        if not marker or marker.Variant ~= self.MarkerVariant then
            return false
        end
        if not marker:GetSprite():IsLoaded() then
            marker:Remove()
            return false
        end
        marker.EntityCollisionClass = EntityCollisionClass.ENTCOLL_NONE
        marker.GridCollisionClass = EntityGridCollisionClass.GRIDCOLL_NONE
        marker:AddEntityFlags(EntityFlag.FLAG_NO_TARGET | EntityFlag.FLAG_NO_STATUS_EFFECTS)
        marker:GetSprite().PlaybackSpeed = 0
        warning.Marker = marker
    end
    -- The engine now renders the warning alongside world geometry on every
    -- presentation. Lua only supplies canonical pose and animation state.
    marker.Position = source.Position
    marker.Visible = source.Visible
    if scale ~= warning.Scale then
        marker.SpriteScale = scale
        warning.Scale = scale
    end
    local fadeFrame = math.min(frame, FADE_FRAMES)
    local palette = self.MarkerPalette
    if fadeFrame ~= warning.Frame or palette ~= warning.Palette then
        marker:GetSprite():SetFrame(palette, fadeFrame)
        warning.Frame, warning.Palette = fadeFrame, palette
    end
    return true
end

return MomStompWarning
