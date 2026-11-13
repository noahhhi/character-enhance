local AimingReticleProtectionModule = {}
AimingReticleProtectionModule.__index = AimingReticleProtectionModule

local SETTING_KEY = "aimingReticleProtection"
local TARGET = EffectVariant.TARGET
local DONT_OVERWRITE = EntityFlag.FLAG_DONT_OVERWRITE
local OWNERSHIP_TAG = "CharacterEnhanceAimingReticlePoolGuard"

-- Index is assigned after MC_POST_EFFECT_INIT on J374 (observed 0 -> 20).
-- It is not a lifetime identity. Pointer + InitSeed + the exact own GetData tag
-- guard reuse without abandoning an entity when native list insertion completes.
local function IdentityMatches(effect, record)
    return effect ~= nil
        and effect.Type == EntityType.ENTITY_EFFECT
        and effect.Variant == TARGET
        and GetPtrHash(effect) == record.ptr
        and effect.InitSeed == record.seed
end

local function TagMatches(effect, tag)
    return type(tag) == "table" and tag.added == true
        and IdentityMatches(effect, tag)
end

function AimingReticleProtectionModule.New(context)
    local self = setmetatable({
        Context = context,
        RunActive = false,
        Tracked = {},
        ReleaseErrors = 0,
    }, AimingReticleProtectionModule)

    context.Mod:AddCallback(ModCallbacks.MC_POST_EFFECT_INIT, function(_, effect)
        self:OnEffect(effect)
    end, TARGET)
    -- Native init may precede assignment of SpawnerEntity. Retry only TARGET
    -- effects; this is O(1) per target, never a per-frame global entity scan.
    context.Mod:AddCallback(ModCallbacks.MC_POST_EFFECT_UPDATE, function(_, effect)
        self:OnEffect(effect)
    end, TARGET)
    context.Mod:AddCallback(ModCallbacks.MC_POST_ENTITY_REMOVE, function(_, entity)
        self:OnEntityRemove(entity)
    end, EntityType.ENTITY_EFFECT)
    context.Mod:AddCallback(ModCallbacks.MC_POST_NEW_ROOM, function()
        self:OnNewRoom()
    end)
    context.Mod:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, function()
        self:OnGameStarted()
    end)
    context.Mod:AddCallback(ModCallbacks.MC_PRE_MOD_UNLOAD, function()
        -- Some loaders notify other mods too. Releasing is safe either way:
        -- if still loaded/enabled, our filtered target update can adopt again.
        self:OnModUnload()
    end)
    return self
end

function AimingReticleProtectionModule:IsEnabled()
    return self.RunActive and self.Context:IsEnabled(SETTING_KEY)
end

function AimingReticleProtectionModule:PlayerOwner(effect)
    -- SpawnerType alone is stale metadata, and Parent can be an intended victim.
    -- Require the live direct spawner to actually be a Player. Do not infer
    -- ownership from proximity, familiar chains, or the presence of Marked.
    local spawner = effect.SpawnerEntity
    if not spawner or not spawner:Exists()
        or spawner.Type ~= EntityType.ENTITY_PLAYER
    then
        return nil
    end
    return spawner:ToPlayer()
end

function AimingReticleProtectionModule:Release(effect, record)
    if not record or not IdentityMatches(effect, record) then
        return
    end
    local data = effect:GetData()
    if data[OWNERSHIP_TAG] ~= record.tag or not TagMatches(effect, record.tag) then
        return
    end
    -- Removal callbacks can run after Exists() becomes false but before native
    -- storage is reused. Clear our bit here, not from a later stale wrapper.
    effect:ClearEntityFlags(DONT_OVERWRITE)
    data[OWNERSHIP_TAG] = nil
end

function AimingReticleProtectionModule:ReleaseAll()
    for _, record in pairs(self.Tracked) do
        -- A native removal/reload may already have invalidated the userdata.
        -- Identity + tag guards ensure a recycled slot is never modified.
        local ok, err = pcall(function()
            self:Release(record.entity, record)
        end)
        if not ok and self.ReleaseErrors < 4 then
            self.ReleaseErrors = self.ReleaseErrors + 1
            Isaac.DebugString("[Character Enhance] Reticle protection release failed: " .. tostring(err))
        end
    end
    self.Tracked = {}
end

function AimingReticleProtectionModule:OnEffect(effect)
    if not self:IsEnabled() or not effect
        or effect.Type ~= EntityType.ENTITY_EFFECT
        or effect.Variant ~= TARGET or not effect:Exists()
    then
        return
    end
    local ptr = GetPtrHash(effect)
    local old = self.Tracked[ptr]
    if old and not IdentityMatches(effect, old) then
        self.Tracked[ptr] = nil
        old = nil
    end
    local owner = self:PlayerOwner(effect)
    if not owner then
        if old then
            self:Release(effect, old)
            self.Tracked[ptr] = nil
        end
        return
    end
    local data = effect:GetData()
    local tag = data[OWNERSHIP_TAG]
    if not TagMatches(effect, tag) then
        -- Preserve an engine/another mod's preexisting protection completely.
        if effect:HasEntityFlags(DONT_OVERWRITE) then
            self.Tracked[ptr] = nil
            return
        end
        tag = { ptr = ptr, seed = effect.InitSeed, added = true }
        data[OWNERSHIP_TAG] = tag
    end
    if not effect:HasEntityFlags(DONT_OVERWRITE) then
        effect:AddEntityFlags(DONT_OVERWRITE)
    end
    if not old or old.tag ~= tag then
        self.Tracked[ptr] = {
            ptr = ptr, seed = effect.InitSeed,
            entity = effect, tag = tag,
        }
    end
end

function AimingReticleProtectionModule:OnEntityRemove(entity)
    if not entity or entity.Type ~= EntityType.ENTITY_EFFECT then
        return
    end
    local ptr = GetPtrHash(entity)
    local record = self.Tracked[ptr]
    if record and IdentityMatches(entity, record) then
        self:Release(entity, record)
        self.Tracked[ptr] = nil
    end
end

function AimingReticleProtectionModule:AdoptExisting()
    if not self:IsEnabled() then
        return
    end
    -- One targeted lifecycle/toggle scan. No scan is scheduled on ordinary ticks.
    for _, effect in ipairs(Isaac.FindByType(
        EntityType.ENTITY_EFFECT, TARGET, -1, false, false
    )) do
        self:OnEffect(effect)
    end
end

function AimingReticleProtectionModule:OnGameStarted()
    self:ReleaseAll()
    self.RunActive = true
    self:AdoptExisting()
end

function AimingReticleProtectionModule:OnNewRoom()
    self:ReleaseAll()
    self:AdoptExisting()
end

function AimingReticleProtectionModule:OnSettingChanged(enabled)
    if enabled then
        self:AdoptExisting()
    else
        self:ReleaseAll()
    end
end

function AimingReticleProtectionModule:OnSaveDataLoaded()
    self:ReleaseAll()
    self.RunActive = false
end

function AimingReticleProtectionModule:OnPreGameExit()
    self:ReleaseAll()
    self.RunActive = false
end

function AimingReticleProtectionModule:OnModUnload()
    self:ReleaseAll()
    -- No SaveData, Remove, Kill, Respawn, timer or position writes on unload.
end

return AimingReticleProtectionModule
