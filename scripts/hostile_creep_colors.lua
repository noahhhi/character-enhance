local HostileCreepColors = {}
HostileCreepColors.__index = HostileCreepColors

local Contrast = include("scripts/hostile_creep_contrast")
local FloorColors = include("scripts/hostile_creep_floor_colors")
local SETTING = "hostileCreepContrast"
local EFFECT = EntityType.ENTITY_EFFECT
local RED = { 0.996, 0.76, 0.43 }
local GREEN = { 0.350, 0.80, 0.36 }
local GREEN_ALT = { 0.225, 0.80, 0.36 }
local YELLOW = { 1 / 6, 0.85, 0.45 }
local WHITE = { 0, 0, 0.83 }
local BLACK = { 0, 0, 0.20 }
local GRAY = { 0, 0, 0.46 }
local ORANGE = { 0.085, 0.82, 0.43 }
local BROWN = { 0.112, 0.62, 0.33 }
local GROWING_BROWN = { 0.112, 0.62, 0.33, 0.60 }
local BLUE = { 0.626, 0.64, 0.39 }
local TAR = { 0.087, 0.42, 0.23 }

local CREEP_PROFILES = {
    [EffectVariant.CREEP_RED] = RED,
    [EffectVariant.CREEP_GREEN] = GREEN,
    [EffectVariant.CREEP_YELLOW] = YELLOW,
    [EffectVariant.CREEP_WHITE] = WHITE,
    [EffectVariant.CREEP_BLACK] = BLACK,
    [EffectVariant.CREEP_BROWN] = ORANGE,
    [EffectVariant.CREEP_SLIPPERY_BROWN] = BROWN,
    [EffectVariant.CREEP_SLIPPERY_BROWN_GROWING] = GROWING_BROWN,
    [EffectVariant.COLOSTOMIA_PUDDLE] = TAR,
    [EffectVariant.CREEP_STATIC] = GRAY,
}

local SHAPE_PROFILE = { [2] = 2, [7] = 2, [3] = 3, [5] = 3, [9] = 4, [10] = 4, [11] = 4, [12] = 4 }
-- The Womb family multiplies the floor and ground effects by a warm scene tint.
local WOMB_TINT = { [10] = true, [11] = true, [12] = true }
local SCREEN_EXPOSURE = { 1, 1, 1 }
local MAX_LATE_POOLS = 16
local MAX_OCCLUDERS = 72
local FLOOR_DETAILS = {
    [EffectVariant.WATER_DROPLET] = true,
    [EffectVariant.TAR_BUBBLE] = true,
    [EffectVariant.TINY_FLY] = true,
    [EffectVariant.WORM] = true,
    [EffectVariant.WALL_BUG] = true,
}

-- Each of these stock ANM2s uses the same offset cycle for all 24 shapes.
-- Indexes are keyframe start frames. The engine interpolates the channels.
local OFFSET_FRAMES = { 0, 6, 10, 15, 21 }
local OFFSET_CYCLES = {
    ["1000.023_creep (green).anm2"] = { { 0, 130, 0 }, { 0, 100, 0 }, { 0, 70, 0 } },
    ["1000.023_creep (green alt).anm2"] = { { 130, 200, 0 }, { 100, 150, 0 }, { 70, 100, 0 } },
    ["1000.024_creep (yellow).anm2"] = { { 255, 255, 0 }, { 225, 225, 0 }, { 195, 195, 0 } },
    ["1000.025_creep (white).anm2"] = { { 255, 255, 255 }, { 240, 240, 240 }, { 225, 225, 225 } },
    ["1000.026_creep (black).anm2"] = { { 0, 0, 0 }, { 15, 15, 15 }, { 30, 30, 30 } },
}

local function OffsetSamples(keys)
    local cycle = { keys[1], keys[2], keys[3], keys[2], keys[1] }
    local frames = { [21] = keys[1] }
    for i = 1, 4 do
        local from, to = cycle[i], cycle[i + 1]
        local start, stop = OFFSET_FRAMES[i], OFFSET_FRAMES[i + 1]
        for frame = start, stop - 1 do
            local progress = (frame - start) / (stop - start)
            frames[frame] = {
                from[1] + (to[1] - from[1]) * progress,
                from[2] + (to[2] - from[2]) * progress,
                from[3] + (to[3] - from[3]) * progress,
            }
        end
    end
    return frames
end

for filename, cycle in pairs(OFFSET_CYCLES) do
    OFFSET_CYCLES[filename] = OffsetSamples(cycle)
end

local NO_OFFSET = { 0, 0, 0 }

local function IsFriendly(entity)
    return entity:HasEntityFlags(EntityFlag.FLAG_FRIENDLY)
        or entity:HasEntityFlags(EntityFlag.FLAG_CHARM)
end

local function IsPlayerOwned(entityType)
    return entityType == EntityType.ENTITY_PLAYER or entityType == EntityType.ENTITY_FAMILIAR
end

local function IsNpc(entityType)
    return entityType and entityType >= 10 and entityType < EFFECT
end

local function Source(effect)
    local entity = effect
    local npcType, hush = nil, false
    for _ = 1, 5 do
        if IsFriendly(entity) or IsPlayerOwned(entity.Type) or IsPlayerOwned(entity.SpawnerType) then
            return nil, false, true
        end
        if not npcType then
            npcType = IsNpc(entity.Type) and entity.Type
                or IsNpc(entity.SpawnerType) and entity.SpawnerType or nil
        end
        hush = hush or entity.Type == EFFECT and entity.Variant == EffectVariant.HUSH_LASER
            or entity.SpawnerType == EFFECT and entity.SpawnerVariant == EffectVariant.HUSH_LASER
        local owner = entity.SpawnerEntity or entity.Parent
        if not owner or GetPtrHash(owner) == GetPtrHash(entity) then
            break
        end
        entity = owner
    end
    return npcType, hush, false
end

local function Profile(effect)
    local profile = CREEP_PROFILES[effect.Variant]
    if not profile then
        return nil
    end
    local npcType, hush, friendly = Source(effect)
    if friendly then
        return nil
    end
    if profile == BROWN or profile == GROWING_BROWN then
        if hush or npcType == EntityType.ENTITY_HUSH then
            return BLUE
        end
        -- X-Lax uses the same slippery variants. Require an enemy creator.
        return npcType and profile or nil
    end
    if npcType == EntityType.ENTITY_CAGE and (profile == RED or profile == GREEN or profile == YELLOW) then
        return GRAY
    end
    return profile
end

function HostileCreepColors.New(context)
    local self = setmetatable({ Context = context, Game = Game(), Seen = {}, Palette = {},
        RenderQueue = {}, Queued = {}, BubbleQueue = {}, DrawnTar = {} }, HostileCreepColors)
    for variant in pairs(CREEP_PROFILES) do
        context.Mod:AddCallback(ModCallbacks.MC_POST_EFFECT_UPDATE, function(_, effect)
            self:OnEffect(effect)
        end, variant)
        context.Mod:AddCallback(ModCallbacks.MC_POST_EFFECT_RENDER, function(_, effect, offset)
            self:QueueLate(effect, offset)
        end, variant)
    end
    context.Mod:AddCallback(ModCallbacks.MC_POST_RENDER, function()
        self:RenderLate()
    end)
    context.Mod:AddCallback(ModCallbacks.MC_POST_EFFECT_RENDER, function(_, bubble, offset)
        if self.LateLighting and not self.Drawing and #self.BubbleQueue < MAX_LATE_POOLS then
            self.BubbleQueue[#self.BubbleQueue + 1] = { effect = bubble, offset = offset }
        end
    end, EffectVariant.TAR_BUBBLE)
    context.Mod:AddCallback(ModCallbacks.MC_POST_ENTITY_REMOVE, function(_, entity)
        if CREEP_PROFILES[entity.Variant] then
            self.Seen[GetPtrHash(entity)] = nil
        end
    end, EFFECT)
    context.Mod:AddCallback(ModCallbacks.MC_POST_NEW_ROOM, function()
        self:ResetRoom()
    end)
    context.Mod:AddCallback(ModCallbacks.MC_PRE_MOD_UNLOAD, function(_, mod)
        if mod == context.Mod then
            self:Restore()
        end
    end)
    return self
end

function HostileCreepColors:Tone(profile, position)
    if not self.Floor then
        local room = self.Game:GetRoom()
        local level = self.Game:GetLevel()
        local desc = level:GetCurrentRoomDesc()
        local flags = desc and desc.Flags or 0
        local backdrop = room:GetBackdropType()
        if backdrop == 46 and flags & RoomDescriptor.FLAG_USE_ALTERNATE_BACKDROP ~= 0 then
            backdrop = 146
        end
        local variants = FloorColors[backdrop] or FloorColors[1]
        self.Floor = variants[SHAPE_PROFILE[room:GetRoomShape()]] or variants[1]
        self.WarmLight = WOMB_TINT[backdrop]
        self.DarkLighting = level:GetCurses() & LevelCurse.CURSE_OF_DARKNESS ~= 0
            or flags & RoomDescriptor.FLAG_PITCH_BLACK ~= 0
        self.LateLighting = self.WarmLight or self.DarkLighting
    end

    -- Ground art is darker at the edge of the camera. Quantize the estimated
    -- exposure so nearby puddles share a color calculation.
    local screen = Isaac.WorldToScreen(position)
    local x = 2 * screen.X / Isaac.GetScreenWidth() - 1
    local y = 2 * screen.Y / Isaac.GetScreenHeight() - 1
    local band = math.min(8, math.floor(math.sqrt(x * x + y * y) * 8 + 0.5))
    local palette = self.Palette[band]
    if not palette then
        local shade = (0.94 - band * 0.035) * (self.DarkLighting and 0.55 or 1)
        local exposure = self.WarmLight and { shade * 0.96, shade * 0.77, shade * 0.74 }
            or { shade, shade, shade }
        local values = self.Floor
        local backgrounds = { Contrast.Decode(values[1], exposure), Contrast.Decode(values[2], exposure),
            Contrast.Decode(values[3], exposure) }
        palette = { exposure = exposure, backgrounds = backgrounds }
        self.Palette[band] = palette
    end

    local tones = palette[profile]
    if not tones then
        local native = Contrast.Choose(profile, palette.backgrounds, palette.exposure)
        local screen = self.LateLighting and Contrast.Choose(profile, palette.backgrounds, SCREEN_EXPOSURE) or nil
        tones = { native, screen }
        palette[profile] = tones
    end
    return tones[1], tones[2]
end

local function MatchOffset(color, applied)
    return math.abs(color.RO - applied.RO) < 0.0001
        and math.abs(color.GO - applied.GO) < 0.0001 and math.abs(color.BO - applied.BO) < 0.0001
end

local function Tint(original, tone, offset, cache, frame)
    local tint = cache[frame]
    if tint then
        return tint
    end
    local red, green, blue = tone.ro - offset[1] / 255, tone.go - offset[2] / 255, tone.bo - offset[3] / 255
    tint = Color(original.R, original.G, original.B, original.A, red, green, blue)
    tint:SetColorize(tone.cr, tone.cg, tone.cb, 1)
    cache[frame] = tint
    return tint
end

local function Paint(sprite, record)
    local frame = record.cycle and sprite:GetFrame() % 22 or 0
    if record.frame == frame then
        return
    end
    local offset = record.cycle and record.cycle[frame] or NO_OFFSET
    record.frame = frame
    record.applied = Tint(record.original, record.tone, offset, record.nativeTints, frame)
    sprite.Color = record.applied
end

local function RestoreRecord(record)
    if record and record.effect:Exists() and record.effect.InitSeed == record.seed then
        local sprite = record.effect:GetSprite()
        local tint = sprite.Color
        if MatchOffset(tint, record.applied) then
            sprite.Color = record.original
        end
    end
end

function HostileCreepColors:OnEffect(effect)
    if not self.Context:IsEnabled(SETTING) then
        return
    end
    local hash = GetPtrHash(effect)
    local record = self.Seen[hash]
    if record == false then
        return
    end
    if record and record.seed == effect.InitSeed then
        if IsFriendly(effect) then
            RestoreRecord(record)
            self.Seen[hash] = false
        elseif record.cycle then
            Paint(effect:GetSprite(), record)
        end
        return
    end

    local profile = Profile(effect)
    if not profile then
        -- Some creators are assigned after the spawn callback or first update.
        if effect.FrameCount >= 3 then
            self.Seen[hash] = false
        end
        return
    end
    local sprite = effect:GetSprite()
    local filename = sprite:GetFilename():lower():match("[^/\\]+$")
    if profile == GREEN and filename == "1000.023_creep (green alt).anm2" then
        profile = GREEN_ALT
    end
    local tone, lateTone = self:Tone(profile, effect.Position)
    record = { effect = effect, seed = effect.InitSeed, tone = tone, lateTone = lateTone,
        original = Color.Lerp(sprite.Color, sprite.Color, 0), cycle = OFFSET_CYCLES[filename],
        nativeTints = {}, lateTints = {} }
    Paint(sprite, record)
    self.Seen[hash] = record
end

function HostileCreepColors:QueueLate(effect, offset)
    if not self.LateLighting or self.Drawing or #self.RenderQueue >= MAX_LATE_POOLS then
        return
    end
    local hash = GetPtrHash(effect)
    local record = self.Seen[hash]
    if record and record.lateTone and not self.Queued[hash] then
        self.Queued[hash] = true
        record.renderOffset = offset
        self.RenderQueue[#self.RenderQueue + 1] = record
    end
end

local function PoolBounds(effect)
    local position = effect.Position
    local radius = math.max(22, effect.Size)
    local xRadius = radius * 1.10
    local yRadius = effect.Variant == EffectVariant.COLOSTOMIA_PUDDLE and radius * 0.52 or radius * 1.04
    return position.X - xRadius, position.Y - yRadius, position.X + xRadius, position.Y + yRadius
end

function HostileCreepColors:Foreground()
    local frame = self.Game:GetFrameCount()
    if self.OccluderFrame == frame then
        return self.Occluders
    end
    self.OccluderFrame = frame
    local boxes = {}
    for _, entity in ipairs(Isaac.GetRoomEntities()) do
        local floorEffect = entity.Type == EFFECT
            and (CREEP_PROFILES[entity.Variant] or FLOOR_DETAILS[entity.Variant])
        if entity.Visible and not floorEffect then
            if #boxes >= MAX_OCCLUDERS then
                self.Occluders = nil
                return nil
            end
            if entity.Type == EFFECT and EntityEffect.IsPlayerCreep(entity.Variant) then
                boxes[#boxes + 1] = { PoolBounds(entity) }
            else
                local p = entity.Position
                local size = entity.Size
                local xRadius = math.max(14, size * 1.5)
                local yTop = math.max(24, size * 2.5)
                boxes[#boxes + 1] = { p.X - xRadius, p.Y - yTop, p.X + xRadius, p.Y + size }
            end
        end
    end
    self.Occluders = boxes
    return boxes
end

local function Uncovered(effect, room, foreground)
    if effect.Size > 112 then
        return false
    end
    local left, top, right, bottom = PoolBounds(effect)
    local clip
    if effect.Variant == EffectVariant.COLOSTOMIA_PUDDLE and room:GetRoomShape() <= 8 then
        local start, finish = room:GetTopLeftPos(), room:GetBottomRightPos()
        local clipLeft, clipTop = math.max(left, start.X + 2), math.max(top, start.Y + 2)
        local clipRight, clipBottom = math.min(right, finish.X - 2), math.min(bottom, finish.Y - 2)
        if clipLeft ~= left or clipTop ~= top or clipRight ~= right or clipBottom ~= bottom then
            left, top, right, bottom = clipLeft, clipTop, clipRight, clipBottom
            clip = { left, top, right, bottom }
        end
    end
    for _, box in ipairs(foreground) do
        if left < box[3] and right > box[1] and top < box[4] and bottom > box[2] then
            return false
        end
    end
    if not room:IsPositionInRoom(Vector(left, top), 0) or not room:IsPositionInRoom(Vector(right, top), 0)
        or not room:IsPositionInRoom(Vector(left, bottom), 0) or not room:IsPositionInRoom(Vector(right, bottom), 0) then
        return false
    end
    local first = room:GetGridIndex(Vector(left, top))
    local last = room:GetGridIndex(Vector(right, bottom))
    local width = room:GetGridWidth()
    for y = math.floor(first / width), math.floor(last / width) do
        for x = first % width, last % width do
            if room:GetGridCollision(y * width + x) ~= GridCollisionClass.COLLISION_NONE then
                return false
            end
        end
    end
    return true, clip
end

local function RenderClippedTar(effect, sprite, clip)
    local position = Isaac.WorldToScreen(effect.Position) + effect.PositionOffset
    local topLeft = Isaac.WorldToScreen(Vector(clip[1], clip[2]))
    local bottomRight = Isaac.WorldToScreen(Vector(clip[3], clip[4]))
    local scale, offset = sprite.Scale, sprite.Offset
    local halfWidth = 72 * math.abs(scale.X)
    local halfHeight = 40 * math.abs(scale.Y)
    local center = position + offset
    -- Crop the stock 144×80 body layer in render pixels. The separate stock
    -- foam and perimeter layers keep their native draw order near the wall.
    local trimStart = Vector(math.max(0, topLeft.X - center.X + halfWidth),
        math.max(0, topLeft.Y - center.Y + halfHeight))
    local trimEnd = Vector(math.max(0, center.X + halfWidth - bottomRight.X),
        math.max(0, center.Y + halfHeight - bottomRight.Y))
    sprite:RenderLayer(0, position, trimStart, trimEnd)
end

function HostileCreepColors:RenderTarBubbles()
    for _, bubble in ipairs(self.BubbleQueue) do
        if bubble.effect:Exists() then
            local p = bubble.effect.Position
            for _, tar in ipairs(self.DrawnTar) do
                local left, top, right, bottom = PoolBounds(tar)
                if p.X >= left and p.X <= right and p.Y >= top and p.Y <= bottom then
                    bubble.effect:Render(bubble.offset)
                    break
                end
            end
        end
    end
end

local function Clear(entries)
    for key in pairs(entries) do
        entries[key] = nil
    end
end

function HostileCreepColors:RenderLate()
    local queue = self.RenderQueue
    if #queue == 0 then
        Clear(self.BubbleQueue)
        return
    end
    local room = self.Game:GetRoom()
    local eligible = not self.Game:IsPaused() and not room:HasWater() and self.Context:IsEnabled(SETTING)
    local foreground = eligible and self:Foreground()
    if not foreground then
        Clear(queue)
        Clear(self.Queued)
        Clear(self.BubbleQueue)
        return
    end
    self.Drawing = true
    for _, record in ipairs(queue) do
        local effect = record.effect
        if effect:Exists() and effect.Visible and effect.InitSeed == record.seed then
            local uncovered, clip = Uncovered(effect, room, foreground)
            local sprite = effect:GetSprite()
            if uncovered and MatchOffset(sprite.Color, record.applied) then
                local frame = record.cycle and sprite:GetFrame() % 22 or 0
                local offset = record.cycle and record.cycle[frame] or NO_OFFSET
                sprite.Color = Tint(record.original, record.lateTone, offset, record.lateTints, frame)
                if clip then
                    RenderClippedTar(effect, sprite, clip)
                else
                    effect:Render(record.renderOffset)
                end
                sprite.Color = record.applied
                if effect.Variant == EffectVariant.COLOSTOMIA_PUDDLE then
                    self.DrawnTar[#self.DrawnTar + 1] = effect
                end
            end
        end
    end
    self:RenderTarBubbles()
    self.Drawing = false
    Clear(queue)
    Clear(self.Queued)
    Clear(self.BubbleQueue)
    Clear(self.DrawnTar)
end

function HostileCreepColors:Restore()
    for _, record in pairs(self.Seen) do
        RestoreRecord(record)
    end
    self.Seen = {}
    Clear(self.RenderQueue)
    Clear(self.Queued)
    Clear(self.BubbleQueue)
    Clear(self.DrawnTar)
end

function HostileCreepColors:ResetRoom()
    self:Restore()
    self.Floor = nil
    self.Palette = {}
    self.OccluderFrame = nil
    self.LateLighting = false
end

function HostileCreepColors:OnSettingChanged(enabled)
    self:ResetRoom()
    if not enabled then
        return
    end
    for _, entity in ipairs(Isaac.FindByType(EFFECT, -1, -1, false, false)) do
        if CREEP_PROFILES[entity.Variant] then
            self:OnEffect(entity:ToEffect())
        end
    end
end

function HostileCreepColors:OnGameStarted()
    self:OnSettingChanged(self.Context:IsEnabled(SETTING))
end

function HostileCreepColors:OnPreGameExit()
    self:ResetRoom()
end

return HostileCreepColors
