local ZodiacFloorItemDisplayModule = {}
ZodiacFloorItemDisplayModule.__index = ZodiacFloorItemDisplayModule

local SETTING_KEY = "zodiacFloorItemDisplay"
local ZODIAC = CollectibleType.COLLECTIBLE_ZODIAC
local PRIMARY_SLOT = ActiveSlot.SLOT_PRIMARY
local PASSIVE = ItemType.ITEM_PASSIVE
local FAMILIAR = ItemType.ITEM_FAMILIAR
local TREASURE_POOL = ItemPoolType and ItemPoolType.POOL_TREASURE or 0
local MAX_SEQUENCE_LENGTH = 512
local MAX_RECENT_POOLS = 96
local INVENTORY_SCAN_INTERVAL = 5
local MANAGED_WISP_TAG = "CharacterEnhanceZodiacWisp"
local ITEM_WISP = FamiliarVariant and FamiliarVariant.ITEM_WISP
local ENTITY_FAMILIAR = EntityType and EntityType.ENTITY_FAMILIAR
local NO_ENTITY_COLLISION = EntityCollisionClass
    and EntityCollisionClass.ENTCOLL_NONE
local NO_GRID_COLLISION = EntityGridCollisionClass
    and EntityGridCollisionClass.GRIDCOLL_NONE
local WISP_FIRE_COOLDOWN = 2147483647

local EFFECT_DEFINITIONS = {
    {
        effect = CollectibleType.COLLECTIBLE_TAURUS,
        proxyName = "Zodiac: Taurus",
    },
    {
        effect = CollectibleType.COLLECTIBLE_ARIES,
        proxyName = "Zodiac: Aries",
    },
    {
        effect = CollectibleType.COLLECTIBLE_CANCER,
        proxyName = "Zodiac: Cancer",
    },
    {
        effect = CollectibleType.COLLECTIBLE_LEO,
        proxyName = "Zodiac: Leo",
    },
    {
        effect = CollectibleType.COLLECTIBLE_VIRGO,
        proxyName = "Zodiac: Virgo",
    },
    {
        effect = CollectibleType.COLLECTIBLE_LIBRA,
        proxyName = "Zodiac: Libra",
    },
    {
        effect = CollectibleType.COLLECTIBLE_SCORPIO,
        proxyName = "Zodiac: Scorpio",
    },
    {
        effect = CollectibleType.COLLECTIBLE_SAGITTARIUS,
        proxyName = "Zodiac: Sagittarius",
    },
    {
        effect = CollectibleType.COLLECTIBLE_CAPRICORN,
        proxyName = "Zodiac: Capricorn",
    },
    {
        effect = CollectibleType.COLLECTIBLE_AQUARIUS,
        proxyName = "Zodiac: Aquarius",
    },
    {
        effect = CollectibleType.COLLECTIBLE_PISCES,
        proxyName = "Zodiac: Pisces",
    },
    {
        effect = CollectibleType.COLLECTIBLE_GEMINI,
        proxyName = "Zodiac: Gemini",
    },
}

local VALID_EFFECTS = {}

for _, definition in ipairs(EFFECT_DEFINITIONS) do
    VALID_EFFECTS[definition.effect] = true
end

local function CopyCounts(source)
    local result = {}

    for collectible, count in pairs(source or {}) do
        result[collectible] = count
    end

    return result
end

local function CopySequence(source, maximumLength)
    local result = {}

    for _, entry in ipairs(source or {}) do
        if maximumLength and #result >= maximumLength then
            break
        end

        result[#result + 1] = {
            kind = entry.kind,
            id = entry.id,
            pool = entry.pool,
        }
    end

    return result
end

local function CountZodiacEntries(sequence)
    local count = 0

    for _, entry in ipairs(sequence or {}) do
        if entry.kind == "zodiac" then
            count = count + 1
        end
    end

    return count
end

function ZodiacFloorItemDisplayModule.New(context)
    local self = setmetatable({
        Context = context,
        SavedData = context:GetSavedModuleData(SETTING_KEY),
        RunSeed = nil,
        RunActive = false,
        Players = {},
        PendingPlayers = {},
        TrackedCollectibles = nil,
        ProxyByEffect = {},
        EffectByProxy = {},
        ProxyIdsReady = false,
        RecentPools = {},
        MutationDepth = 0,
        LastInventoryScanFrame = -1,
        MissingProxyWarningLogged = false,
    }, ZodiacFloorItemDisplayModule)

    context.Mod:AddCallback(
        ModCallbacks.MC_POST_GAME_STARTED,
        function(_, isContinued)
            self:OnGameStarted(isContinued)
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_PEFFECT_UPDATE,
        function(_, player)
            self:OnPlayerEffectUpdate(player)
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_NEW_LEVEL,
        function()
            self:OnNewLevel()
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_NEW_ROOM,
        function()
            self:OnNewRoom()
        end
    )

    if ModCallbacks.MC_FAMILIAR_UPDATE and ITEM_WISP then
        context.Mod:AddCallback(
            ModCallbacks.MC_FAMILIAR_UPDATE,
            function(_, familiar)
                self:OnFamiliarUpdate(familiar)
            end,
            ITEM_WISP
        )
    end

    if ModCallbacks.MC_ENTITY_TAKE_DMG and ENTITY_FAMILIAR then
        context.Mod:AddCallback(
            ModCallbacks.MC_ENTITY_TAKE_DMG,
            function(_, entity)
                return self:OnEntityTakeDamage(entity)
            end,
            ENTITY_FAMILIAR
        )
    end

    local poolCallback = function(
        _,
        selectedCollectible,
        poolType,
        decrease,
        seed
    )
        return self:OnPostGetCollectible(
            selectedCollectible,
            poolType,
            decrease,
            seed
        )
    end

    if type(context.Mod.AddPriorityCallback) == "function" then
        context.Mod:AddPriorityCallback(
            ModCallbacks.MC_POST_GET_COLLECTIBLE,
            CallbackPriority.LATE,
            poolCallback
        )
    else
        context.Mod:AddCallback(
            ModCallbacks.MC_POST_GET_COLLECTIBLE,
            poolCallback
        )
    end

    return self
end

function ZodiacFloorItemDisplayModule:SanitizeInteger(
    value,
    minimum,
    maximum
)
    local number = tonumber(value)

    if type(number) ~= "number" or number ~= number
        or number == math.huge or number == -math.huge
    then
        return nil
    end

    number = math.floor(number)

    if number < minimum or number > maximum then
        return nil
    end

    return number
end

function ZodiacFloorItemDisplayModule:SanitizePool(poolType)
    return self:SanitizeInteger(poolType, 0, 255) or TREASURE_POOL
end

function ZodiacFloorItemDisplayModule:SanitizeSequence(sequence)
    local result = {}

    if type(sequence) ~= "table" then
        return result
    end

    for _, entry in ipairs(sequence) do
        if #result >= MAX_SEQUENCE_LENGTH then
            break
        end

        if type(entry) == "table" and entry.kind == "zodiac" then
            result[#result + 1] = {
                kind = "zodiac",
                pool = self:SanitizePool(entry.pool),
            }
        elseif type(entry) == "table" and entry.kind == "item" then
            local collectible = self:SanitizeInteger(
                entry.id,
                1,
                1000000
            )

            if collectible and collectible ~= ZODIAC then
                result[#result + 1] = {
                    kind = "item",
                    id = collectible,
                    pool = self:SanitizePool(entry.pool),
                }
            end
        end
    end

    return result
end

function ZodiacFloorItemDisplayModule:SanitizeBaseline(baseline)
    local result = {}

    if type(baseline) ~= "table" then
        return result
    end

    for collectibleKey, savedCount in pairs(baseline) do
        local collectible = self:SanitizeInteger(
            collectibleKey,
            1,
            1000000
        )
        local count = self:SanitizeInteger(savedCount, 0, 99)

        if collectible and count and count > 0
            and collectible ~= ZODIAC
        then
            result[collectible] = count
        end
    end

    return result
end

function ZodiacFloorItemDisplayModule:SanitizeSavedData(savedData)
    local result = { players = {} }

    if type(savedData) ~= "table" then
        return result
    end

    result.runSeed = self:SanitizeInteger(
        savedData.runSeed,
        0,
        0xFFFFFFFF
    )

    if type(savedData.players) ~= "table" then
        return result
    end

    for playerKey, savedState in pairs(savedData.players) do
        local playerIndex = self:SanitizeInteger(playerKey, 0, 15)

        if playerIndex and type(savedState) == "table" then
            local effect = self:SanitizeInteger(
                savedState.effect,
                1,
                1000000
            )
            local sequence = self:SanitizeSequence(savedState.sequence)

            if VALID_EFFECTS[effect]
                and CountZodiacEntries(sequence) > 0
            then
                result.players[tostring(playerIndex)] = {
                    effect = effect,
                    sequence = sequence,
                    baseline = self:SanitizeBaseline(savedState.baseline),
                    effectCarrier = savedState.effectCarrier == "wisp"
                        and "wisp"
                        or nil,
                }
            end
        end
    end

    return result
end

function ZodiacFloorItemDisplayModule:GetRunSeed()
    return Game():GetSeeds():GetStartSeed()
end

function ZodiacFloorItemDisplayModule:GetPlayerKey(player)
    return tostring(GetPtrHash(player))
end

function ZodiacFloorItemDisplayModule:GetPlayerIndex(player)
    local targetKey = self:GetPlayerKey(player)
    local game = Game()

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        if self:GetPlayerKey(Isaac.GetPlayer(playerIndex)) == targetKey then
            return playerIndex
        end
    end

    return nil
end

function ZodiacFloorItemDisplayModule:ResolveProxyIds()
    self.ProxyByEffect = {}
    self.EffectByProxy = {}
    self.ProxyIdsReady = true

    for _, definition in ipairs(EFFECT_DEFINITIONS) do
        local proxyId = Isaac.GetItemIdByName(definition.proxyName)

        if type(proxyId) ~= "number" or proxyId <= 0 then
            self.ProxyIdsReady = false
        else
            self.ProxyByEffect[definition.effect] = proxyId
            self.EffectByProxy[proxyId] = definition.effect
        end
    end

    if not self.ProxyIdsReady and not self.MissingProxyWarningLogged then
        Isaac.DebugString(
            "Character Enhance: Zodiac marker items require a game restart"
        )
        self.MissingProxyWarningLogged = true
    end

    return self.ProxyIdsReady
end

function ZodiacFloorItemDisplayModule:IsTrackedConfig(config)
    return config and (config.Type == PASSIVE or config.Type == FAMILIAR)
end

function ZodiacFloorItemDisplayModule:BuildTrackedCollectibles()
    if self.TrackedCollectibles then
        return
    end

    self.TrackedCollectibles = {}
    local itemConfig = Isaac.GetItemConfig()
    local collectibleList = itemConfig:GetCollectibles()
    local maximumId = math.max(0, collectibleList.Size - 1)

    for collectible = 1, maximumId do
        if collectible ~= ZODIAC
            and not self.EffectByProxy[collectible]
            and self:IsTrackedConfig(itemConfig:GetCollectible(collectible))
        then
            self.TrackedCollectibles[#self.TrackedCollectibles + 1]
                = collectible
        end
    end
end

function ZodiacFloorItemDisplayModule:CaptureCounts(player)
    self:BuildTrackedCollectibles()
    local counts = {}

    for _, collectible in ipairs(self.TrackedCollectibles) do
        local count = player:GetCollectibleNum(collectible, true)

        if count > 0 then
            counts[collectible] = count
        end
    end

    return counts
end

function ZodiacFloorItemDisplayModule:NormalizeSequence(state)
    local baseline = state.baseline or {}

    if next(baseline) == nil then
        state.baseline = {}
        return
    end

    self:BuildTrackedCollectibles()
    local sequence = {}
    local originalSequence = state.sequence or {}
    local prefixLimit = math.max(
        0,
        MAX_SEQUENCE_LENGTH - #originalSequence
    )

    -- Older saves only stored counts for items owned before Zodiac. Their
    -- native History order is not exposed by the current standard API, so
    -- migrate them once in stable collectible order ahead of the marker.
    for _, collectible in ipairs(self.TrackedCollectibles) do
        for _ = 1, baseline[collectible] or 0 do
            if #sequence < prefixLimit then
                sequence[#sequence + 1] = {
                    kind = "item",
                    id = collectible,
                    pool = TREASURE_POOL,
                }
            end
        end
    end

    for _, entry in ipairs(originalSequence) do
        if #sequence < MAX_SEQUENCE_LENGTH then
            sequence[#sequence + 1] = entry
        end
    end

    state.sequence = sequence
    state.baseline = {}
end

function ZodiacFloorItemDisplayModule:CreatePendingState(
    player,
    playerIndex
)
    local state = {
        playerIndex = playerIndex,
        sequence = {},
        baseline = {},
        suspendedForReroll = false,
        lastInventoryScanFrame = -1,
    }
    local counts = self:CaptureCounts(player)

    for _, collectible in ipairs(self.TrackedCollectibles) do
        for _ = 1, counts[collectible] or 0 do
            if #state.sequence < MAX_SEQUENCE_LENGTH then
                state.sequence[#state.sequence + 1] = {
                    kind = "item",
                    id = collectible,
                    pool = TREASURE_POOL,
                }
            end
        end
    end

    state.lastCounts = counts
    return state
end

function ZodiacFloorItemDisplayModule:CaptureConsumables(player)
    return {
        coins = player:GetNumCoins(),
        bombs = player:GetNumBombs(),
        keys = player:GetNumKeys(),
        soulCharge = player:GetSoulCharge(),
        bloodCharge = player:GetBloodCharge(),
    }
end

function ZodiacFloorItemDisplayModule:RestoreConsumables(player, snapshot)
    player:AddCoins(snapshot.coins - player:GetNumCoins())
    player:AddBombs(snapshot.bombs - player:GetNumBombs())
    player:AddKeys(snapshot.keys - player:GetNumKeys())

    if player:GetSoulCharge() ~= snapshot.soulCharge then
        player:SetSoulCharge(snapshot.soulCharge)
    end
    if player:GetBloodCharge() ~= snapshot.bloodCharge then
        player:SetBloodCharge(snapshot.bloodCharge)
    end
end

function ZodiacFloorItemDisplayModule:CaptureHealth(player)
    local rerollModule = self.Context.Modules
        and self.Context.Modules.rerollHealthProtection

    if rerollModule and rerollModule.CaptureHealth then
        return rerollModule:CaptureHealth(player), rerollModule
    end

    return nil, nil
end

function ZodiacFloorItemDisplayModule:RestoreHealth(
    player,
    snapshot,
    rerollModule
)
    if snapshot and rerollModule and rerollModule.RestoreHealth then
        rerollModule:RestoreHealth(player, snapshot)
    end
end

function ZodiacFloorItemDisplayModule:GetCurrentRoomKey()
    local level = Game():GetLevel()
    local stage = level and level:GetStage() or -1
    local stageType = level and level:GetStageType() or -1
    local roomIndex = level and level:GetCurrentRoomIndex() or -1

    return table.concat({ stage, stageType, roomIndex }, ":")
end

function ZodiacFloorItemDisplayModule:OnPostGetCollectible(
    selectedCollectible,
    poolType,
    _,
    seed
)
    if not self.RunActive or self.MutationDepth > 0
        or type(selectedCollectible) ~= "number"
        or selectedCollectible <= 0
    then
        return
    end

    local config = Isaac.GetItemConfig():GetCollectible(selectedCollectible)

    if not self:IsTrackedConfig(config) then
        return
    end

    self.RecentPools[#self.RecentPools + 1] = {
        id = selectedCollectible,
        pool = self:SanitizePool(poolType),
        seed = self:SanitizeInteger(seed, 0, 0xFFFFFFFF),
        frame = Game():GetFrameCount(),
        roomKey = self:GetCurrentRoomKey(),
    }

    while #self.RecentPools > MAX_RECENT_POOLS do
        table.remove(self.RecentPools, 1)
    end
end

function ZodiacFloorItemDisplayModule:ConsumeRecentPool(collectible)
    local currentRoomKey = self:GetCurrentRoomKey()
    local currentFrame = Game():GetFrameCount()
    local fallbackIndex = nil

    for index = #self.RecentPools, 1, -1 do
        local candidate = self.RecentPools[index]

        if currentFrame - candidate.frame > 3600 then
            table.remove(self.RecentPools, index)
        elseif candidate.id == collectible then
            fallbackIndex = fallbackIndex or index

            if candidate.roomKey == currentRoomKey then
                local pool = candidate.pool
                table.remove(self.RecentPools, index)
                return pool
            end
        end
    end

    if fallbackIndex and self.RecentPools[fallbackIndex] then
        local pool = self.RecentPools[fallbackIndex].pool
        table.remove(self.RecentPools, fallbackIndex)
        return pool
    end

    return TREASURE_POOL
end

function ZodiacFloorItemDisplayModule:GetExpectedItemCounts(state)
    local expected = CopyCounts(state.baseline)

    for _, entry in ipairs(state.sequence) do
        if entry.kind == "item" then
            expected[entry.id] = (expected[entry.id] or 0) + 1
        end
    end

    return expected
end

function ZodiacFloorItemDisplayModule:RemoveSequenceItem(
    state,
    collectible
)
    for index = #state.sequence, 1, -1 do
        local entry = state.sequence[index]

        if entry.kind == "item" and entry.id == collectible then
            table.remove(state.sequence, index)
            return true
        end
    end

    return false
end

function ZodiacFloorItemDisplayModule:AppendItemEntry(
    state,
    collectible
)
    if #state.sequence >= MAX_SEQUENCE_LENGTH then
        return false
    end

    state.sequence[#state.sequence + 1] = {
        kind = "item",
        id = collectible,
        pool = self:ConsumeRecentPool(collectible),
    }
    return true
end

function ZodiacFloorItemDisplayModule:SyncSequence(player, state)
    if self.MutationDepth > 0 or state.suspendedForReroll then
        return false
    end

    local current = self:CaptureCounts(player)
    local expected = self:GetExpectedItemCounts(state)
    local additions = {}
    local changed = false

    for _, collectible in ipairs(self.TrackedCollectibles) do
        local currentCount = current[collectible] or 0
        local expectedCount = expected[collectible] or 0

        if currentCount > expectedCount then
            additions[collectible] = currentCount - expectedCount
        elseif currentCount < expectedCount then
            local missing = expectedCount - currentCount

            while missing > 0
                and self:RemoveSequenceItem(state, collectible)
            do
                missing = missing - 1
                changed = true
            end

            if missing > 0 then
                state.baseline[collectible] = math.max(
                    0,
                    (state.baseline[collectible] or 0) - missing
                )
                changed = true
            end
        end
    end

    local queuedCollectible = state.queuedCollectible

    if queuedCollectible and (additions[queuedCollectible] or 0) > 0 then
        if self:AppendItemEntry(state, queuedCollectible) then
            additions[queuedCollectible]
                = additions[queuedCollectible] - 1
            changed = true
        end
    end

    for _, collectible in ipairs(self.TrackedCollectibles) do
        local count = additions[collectible] or 0

        for _ = 1, count do
            if self:AppendItemEntry(state, collectible) then
                changed = true
            end
        end
    end

    state.queuedCollectible = nil
    state.lastCounts = current
    return changed
end

function ZodiacFloorItemDisplayModule:RemoveManagedEffect(player, state)
    local count = state.managedEffectCount or 0

    if count > 0 and VALID_EFFECTS[state.effect] then
        player:GetEffects():RemoveCollectibleEffect(state.effect, count)
    end

    state.managedEffectCount = 0

    for _, wisp in ipairs(self:FindManagedWisps(player, state)) do
        if self:EntityExists(wisp) then
            wisp:Remove()
        end
    end

    state.managedWisps = {}
    state.pendingWispFrame = nil
    self:RefreshPlayerItems(player)
end

function ZodiacFloorItemDisplayModule:EntityExists(entity)
    return entity ~= nil
        and (type(entity.Exists) ~= "function" or entity:Exists())
end

function ZodiacFloorItemDisplayModule:IsManagedWisp(wisp, player)
    if not wisp or type(wisp.GetData) ~= "function" then
        return false
    end

    local data = wisp:GetData()

    if not data or data[MANAGED_WISP_TAG] ~= true then
        return false
    end

    if not player then
        return true
    end

    local owner = wisp.Player
    return owner ~= nil
        and self:GetPlayerKey(owner) == self:GetPlayerKey(player)
end

function ZodiacFloorItemDisplayModule:FindManagedWisps(player, state)
    local result = {}
    local seen = {}

    local function append(wisp)
        if not self:EntityExists(wisp)
            or not self:IsManagedWisp(wisp, player)
        then
            return
        end

        local hash = self:GetPlayerKey(wisp)

        if not seen[hash] then
            seen[hash] = true
            result[#result + 1] = wisp
        end
    end

    for _, wisp in ipairs(state.managedWisps or {}) do
        append(wisp)
    end

    if Isaac.FindByType and ENTITY_FAMILIAR and ITEM_WISP then
        for _, entity in ipairs(Isaac.FindByType(
            ENTITY_FAMILIAR,
            ITEM_WISP,
            -1,
            false,
            false
        )) do
            local familiar = type(entity.ToFamiliar) == "function"
                and entity:ToFamiliar()
                or entity
            append(familiar)
        end
    end

    return result
end


function ZodiacFloorItemDisplayModule:RefreshPlayerItems(player)
    if type(player.AddCacheFlags) == "function" and CacheFlag then
        player:AddCacheFlags(CacheFlag.CACHE_ALL)
    end

    if type(player.EvaluateItems) == "function" then
        player:EvaluateItems()
    end
end

function ZodiacFloorItemDisplayModule:StabilizeManagedWisp(wisp)
    if not self:IsManagedWisp(wisp) then
        return
    end

    wisp.Visible = false
    wisp.FireCooldown = WISP_FIRE_COOLDOWN
    wisp.CollisionDamage = 0

    if NO_ENTITY_COLLISION then
        wisp.EntityCollisionClass = NO_ENTITY_COLLISION
    end
    if NO_GRID_COLLISION then
        wisp.GridCollisionClass = NO_GRID_COLLISION
    end
end

function ZodiacFloorItemDisplayModule:TagManagedWisp(wisp, player, effect)
    local data = wisp:GetData()
    data[MANAGED_WISP_TAG] = true
    data.CharacterEnhanceZodiacEffect = effect
    data.CharacterEnhanceZodiacOwner = self:GetPlayerKey(player)
    self:StabilizeManagedWisp(wisp)
end

function ZodiacFloorItemDisplayModule:ScheduleManagedEffect(
    player,
    state
)
    self:RemoveManagedEffect(player, state)
    state.pendingWispFrame = Game():GetFrameCount() + 1
end

function ZodiacFloorItemDisplayModule:ApplyManagedEffect(player, state)
    local desiredCount = CountZodiacEntries(state.sequence)

    if desiredCount <= 0 or not VALID_EFFECTS[state.effect]
        or type(player.AddItemWisp) ~= "function"
    then
        self:RemoveManagedEffect(player, state)
        return false
    end

    -- Saves created by the old implementation may still contain its inert
    -- TemporaryEffects entry. Remove it once before adopting native item wisps.
    local legacyCount = state.managedEffectCount or 0

    if legacyCount > 0 then
        player:GetEffects():RemoveCollectibleEffect(
            state.effect,
            legacyCount
        )
        state.managedEffectCount = 0
    end

    local matching = {}
    local removedWrongEffect = false

    for _, wisp in ipairs(self:FindManagedWisps(player, state)) do
        local data = wisp:GetData()
        local effect = data.CharacterEnhanceZodiacEffect or wisp.SubType

        if effect == state.effect and #matching < desiredCount then
            self:StabilizeManagedWisp(wisp)
            matching[#matching + 1] = wisp
        else
            wisp:Remove()
            removedWrongEffect = removedWrongEffect or effect ~= state.effect
        end
    end

    local frame = Game():GetFrameCount()

    if removedWrongEffect then
        state.managedWisps = matching
        state.pendingWispFrame = frame + 1
        self:RefreshPlayerItems(player)
        return false
    end

    if state.pendingWispFrame and frame < state.pendingWispFrame then
        state.managedWisps = matching
        return false
    end

    while #matching < desiredCount do
        local wisp = player:AddItemWisp(
            state.effect,
            player.Position,
            false
        )

        if not wisp then
            break
        end

        self:TagManagedWisp(wisp, player, state.effect)
        matching[#matching + 1] = wisp
    end

    state.managedWisps = matching
    state.pendingWispFrame = #matching == desiredCount and nil or frame + 1
    self:RefreshPlayerItems(player)
    return #matching == desiredCount
end

function ZodiacFloorItemDisplayModule:OnFamiliarUpdate(familiar)
    if self:IsManagedWisp(familiar) then
        self:StabilizeManagedWisp(familiar)
    end
end

function ZodiacFloorItemDisplayModule:OnEntityTakeDamage(entity)
    local familiar = entity and type(entity.ToFamiliar) == "function"
        and entity:ToFamiliar()
        or nil

    if self:IsManagedWisp(familiar) then
        return false
    end
end

function ZodiacFloorItemDisplayModule:AddOwnedCollectible(
    player,
    collectible,
    poolType
)
    player:AddCollectible(
        collectible,
        0,
        false,
        PRIMARY_SLOT,
        0,
        self:SanitizePool(poolType)
    )
end

function ZodiacFloorItemDisplayModule:RemoveOwnedCollectible(
    player,
    collectible
)
    player:RemoveCollectible(
        collectible,
        true,
        PRIMARY_SLOT,
        false
    )
end

function ZodiacFloorItemDisplayModule:GetStoredCollectible(state, entry)
    if entry.kind == "item" then
        return entry.id
    end

    if state.storageMode == "zodiac" then
        return ZODIAC
    end

    return self.ProxyByEffect[state.effect]
end

function ZodiacFloorItemDisplayModule:RebuildSequence(
    player,
    state,
    targetMode,
    targetEffect
)
    if not self.ProxyIdsReady or #state.sequence == 0 then
        return false
    end

    if targetMode == "proxy" and not self.ProxyByEffect[targetEffect] then
        return false
    end

    self:SyncSequence(player, state)
    local consumables = self:CaptureConsumables(player)
    local health, rerollModule = self:CaptureHealth(player)
    self.MutationDepth = self.MutationDepth + 1

    for index = #state.sequence, 1, -1 do
        local collectible = self:GetStoredCollectible(
            state,
            state.sequence[index]
        )

        if collectible and player:GetCollectibleNum(collectible, true) > 0 then
            self:RemoveOwnedCollectible(player, collectible)
        end
    end

    state.effect = targetEffect or state.effect
    state.storageMode = targetMode

    for _, entry in ipairs(state.sequence) do
        local collectible = entry.kind == "zodiac"
            and (targetMode == "zodiac"
                and ZODIAC
                or self.ProxyByEffect[state.effect])
            or entry.id
        self:AddOwnedCollectible(player, collectible, entry.pool)
    end

    self.MutationDepth = self.MutationDepth - 1
    self:RestoreConsumables(player, consumables)
    self:RestoreHealth(player, health, rerollModule)
    state.lastCounts = self:CaptureCounts(player)
    return true
end

function ZodiacFloorItemDisplayModule:SnapshotEffectCounts(player)
    local result = {}
    local effects = player:GetEffects()

    for effect in pairs(VALID_EFFECTS) do
        result[effect] = effects:GetCollectibleEffectNum(effect)
    end

    return result
end

function ZodiacFloorItemDisplayModule:RemoveNewNativeEffects(
    player,
    beforeCounts
)
    local effects = player:GetEffects()

    for effect in pairs(VALID_EFFECTS) do
        local before = beforeCounts[effect] or 0
        local after = effects:GetCollectibleEffectNum(effect)

        if after > before then
            effects:RemoveCollectibleEffect(effect, after - before)
        end
    end
end

function ZodiacFloorItemDisplayModule:DetermineFloorEffect(player, poolType)
    local beforeEffects = self:SnapshotEffectCounts(player)
    local consumables = self:CaptureConsumables(player)
    self.MutationDepth = self.MutationDepth + 1
    self:AddOwnedCollectible(player, ZODIAC, poolType)
    local effect = player:GetZodiacEffect()
    self:RemoveOwnedCollectible(player, ZODIAC)
    self.MutationDepth = self.MutationDepth - 1
    self:RestoreConsumables(player, consumables)
    self:RemoveNewNativeEffects(player, beforeEffects)

    if VALID_EFFECTS[effect] then
        return effect
    end

    return nil
end

function ZodiacFloorItemDisplayModule:CreateStateFromZodiac(
    player,
    playerIndex,
    zodiacCount
)
    local effect = player:GetZodiacEffect()

    if not VALID_EFFECTS[effect] or zodiacCount <= 0 then
        return nil
    end

    local playerKey = self:GetPlayerKey(player)
    local pendingState = self.PendingPlayers[playerKey]

    if pendingState then
        self:UpdateQueuedItem(player, pendingState)
        self:SyncSequence(player, pendingState)
    end

    local state = {
        playerIndex = playerIndex,
        effect = effect,
        sequence = pendingState
            and CopySequence(
                pendingState.sequence,
                math.max(0, MAX_SEQUENCE_LENGTH - zodiacCount)
            )
            or {},
        baseline = {},
        storageMode = "zodiac",
        managedEffectCount = 0,
        managedWisps = {},
        suspendedForReroll = false,
        lastInventoryScanFrame = -1,
        lastWispScanFrame = -1,
    }

    for _ = 1, zodiacCount do
        state.sequence[#state.sequence + 1] = {
            kind = "zodiac",
            pool = self:ConsumeRecentPool(ZODIAC),
        }
    end

    self.PendingPlayers[playerKey] = nil

    return state
end

function ZodiacFloorItemDisplayModule:AdoptZodiac(player, state)
    local zodiacCount = player:GetCollectibleNum(ZODIAC, true)

    if zodiacCount <= 0 or not self.ProxyIdsReady then
        return false
    end

    local playerIndex = self:GetPlayerIndex(player)
    local newPools = {}

    if playerIndex == nil then
        return false
    end

    if state then
        self:NormalizeSequence(state)
    end

    if not state then
        state = self:CreateStateFromZodiac(
            player,
            playerIndex,
            zodiacCount
        )

        if not state then
            return false
        end

        self.Players[self:GetPlayerKey(player)] = state

        for index = #state.sequence - zodiacCount + 1, #state.sequence do
            newPools[#newPools + 1] = state.sequence[index].pool
        end
    else
        self:SyncSequence(player, state)

        for _ = 1, zodiacCount do
            if #state.sequence < MAX_SEQUENCE_LENGTH then
                local poolType = self:ConsumeRecentPool(ZODIAC)
                state.sequence[#state.sequence + 1] = {
                    kind = "zodiac",
                    pool = poolType,
                }
                newPools[#newPools + 1] = poolType
            end
        end
    end

    local effect = player:GetZodiacEffect()

    if not VALID_EFFECTS[effect] then
        return false
    end

    local consumables = self:CaptureConsumables(player)
    self.MutationDepth = self.MutationDepth + 1

    for index, poolType in ipairs(newPools) do
        self:RemoveOwnedCollectible(player, ZODIAC)
        self:AddOwnedCollectible(
            player,
            self.ProxyByEffect[effect],
            poolType
        )
    end

    self.MutationDepth = self.MutationDepth - 1
    self:RestoreConsumables(player, consumables)
    state.effect = effect
    state.storageMode = "proxy"
    self:ApplyManagedEffect(player, state)
    state.lastCounts = self:CaptureCounts(player)
    self.Context:Save()
    return true
end

function ZodiacFloorItemDisplayModule:GetProxyCount(player, state)
    local proxyId = self.ProxyByEffect[state.effect]

    if not proxyId then
        return 0
    end

    return player:GetCollectibleNum(proxyId, true)
end

function ZodiacFloorItemDisplayModule:IsInternalNativeReroll(player)
    return false
end

function ZodiacFloorItemDisplayModule:RestoreStateToZodiac(player, state)
    self:RemoveManagedEffect(player, state)

    if state.storageMode ~= "zodiac" then
        self:RebuildSequence(player, state, "zodiac", state.effect)
    end

    state.storageMode = "zodiac"
end

function ZodiacFloorItemDisplayModule:RotateFloorEffect(player, state)
    if state.suspendedForReroll or state.storageMode ~= "proxy" then
        return false
    end

    local firstPool = TREASURE_POOL

    for _, entry in ipairs(state.sequence) do
        if entry.kind == "zodiac" then
            firstPool = entry.pool
            break
        end
    end

    local effect = self:DetermineFloorEffect(player, firstPool)

    if not effect then
        return false
    end

    if effect ~= state.effect then
        self:ScheduleManagedEffect(player, state)

        if not self:RebuildSequence(player, state, "proxy", effect) then
            return false
        end
    else
        self:ApplyManagedEffect(player, state)
    end

    state.effect = effect
    state.pendingFloorRefresh = nil
    self.Context:Save()
    return true
end

function ZodiacFloorItemDisplayModule:PrepareForFullInventoryReroll(player)
    if not player or not self.RunActive
        or not self.Context:IsEnabled(SETTING_KEY)
    then
        return false
    end

    local state = self.Players[self:GetPlayerKey(player)]

    if not state or state.suspendedForReroll then
        return false
    end

    self:RestoreStateToZodiac(player, state)
    state.suspendedForReroll = true
    state.rerollFrame = Game():GetFrameCount()
    self.Context:Save()
    return true
end

function ZodiacFloorItemDisplayModule:FinishFullInventoryReroll(
    player,
    state
)
    if Game():GetFrameCount() <= (state.rerollFrame or -1) then
        return false
    end

    self:RemoveManagedEffect(player, state)
    self.Players[self:GetPlayerKey(player)] = nil
    local zodiacCount = player:GetCollectibleNum(ZODIAC, true)

    if zodiacCount > 0 then
        self:AdoptZodiac(player, nil)
    else
        self.Context:Save()
    end

    return true
end

function ZodiacFloorItemDisplayModule:RecoverStrayProxies(player)
    if not self.ProxyIdsReady then
        return 0
    end

    local recovered = 0
    self.MutationDepth = self.MutationDepth + 1

    for proxyId in pairs(self.EffectByProxy) do
        local count = player:GetCollectibleNum(proxyId, true)

        for _ = 1, count do
            self:RemoveOwnedCollectible(player, proxyId)
            self:AddOwnedCollectible(player, ZODIAC, TREASURE_POOL)
            recovered = recovered + 1
        end
    end

    self.MutationDepth = self.MutationDepth - 1
    return recovered
end

function ZodiacFloorItemDisplayModule:RestoreSavedState(
    player,
    playerIndex,
    savedState
)
    local proxyId = self.ProxyByEffect[savedState.effect]
    local expectedProxyCount = CountZodiacEntries(savedState.sequence)

    if not proxyId
        or player:GetCollectibleNum(proxyId, true) < expectedProxyCount
    then
        return nil
    end

    local state = {
        playerIndex = playerIndex,
        effect = savedState.effect,
        sequence = savedState.sequence,
        baseline = savedState.baseline,
        storageMode = "proxy",
        managedEffectCount = savedState.effectCarrier == "wisp"
            and 0
            or expectedProxyCount,
        managedWisps = {},
        suspendedForReroll = false,
        lastInventoryScanFrame = -1,
        lastWispScanFrame = -1,
    }

    self:NormalizeSequence(state)

    self.Players[self:GetPlayerKey(player)] = state
    self:ApplyManagedEffect(player, state)
    state.lastCounts = self:CaptureCounts(player)
    return state
end

function ZodiacFloorItemDisplayModule:OnGameStarted(isContinued)
    self.RunSeed = self:GetRunSeed()
    self.RunActive = true
    self.Players = {}
    self.PendingPlayers = {}
    self.RecentPools = {}
    self.TrackedCollectibles = nil
    self.LastInventoryScanFrame = Game():GetFrameCount()

    if not self:ResolveProxyIds() then
        return
    end

    self:BuildTrackedCollectibles()
    local sanitized = self:SanitizeSavedData(self.SavedData)
    local canRestore = isContinued and sanitized.runSeed == self.RunSeed
    local game = Game()

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(playerIndex)
        local state = canRestore
            and self.Context:IsEnabled(SETTING_KEY)
            and self:RestoreSavedState(
            player,
            playerIndex,
            sanitized.players[tostring(playerIndex)] or {}
        )

        if not state then
            self:RecoverStrayProxies(player)

            if self.Context:IsEnabled(SETTING_KEY) then
                if not self:AdoptZodiac(player, nil) then
                    self.PendingPlayers[self:GetPlayerKey(player)]
                        = self:CreatePendingState(player, playerIndex)
                end
            end
        end
    end

    self.Context:Save()
end

function ZodiacFloorItemDisplayModule:UpdateQueuedItem(player, state)
    local queuedItem = player.QueuedItem
    local item = queuedItem and queuedItem.Item
    local collectible = item and item.ID

    if type(collectible) == "number" and collectible > 0
        and collectible ~= ZODIAC
        and not self.EffectByProxy[collectible]
    then
        state.queuedCollectible = collectible
    end
end

function ZodiacFloorItemDisplayModule:OnPlayerEffectUpdate(player)
    if not self.RunActive or not player or player:IsDead()
        or not self.ProxyIdsReady
    then
        return
    end

    local key = self:GetPlayerKey(player)
    local state = self.Players[key]

    if not self.Context:IsEnabled(SETTING_KEY) then
        if state then
            self:RestoreStateToZodiac(player, state)
            self.Players[key] = nil
            self.Context:Save()
        end
        self.PendingPlayers[key] = nil
        return
    end

    if state and state.suspendedForReroll then
        self:FinishFullInventoryReroll(player, state)
        return
    end

    if player:GetCollectibleNum(ZODIAC, true) > 0 then
        local pendingState = self.PendingPlayers[key]

        if not state and pendingState then
            self:UpdateQueuedItem(player, pendingState)
            self:SyncSequence(player, pendingState)
        end

        self:AdoptZodiac(player, state)
        state = self.Players[key]
    end

    if not state then
        local pendingState = self.PendingPlayers[key]

        if not pendingState then
            local playerIndex = self:GetPlayerIndex(player)

            if playerIndex ~= nil then
                pendingState = self:CreatePendingState(
                    player,
                    playerIndex
                )
                self.PendingPlayers[key] = pendingState
            end
        end

        if pendingState then
            self:UpdateQueuedItem(player, pendingState)
            local frame = Game():GetFrameCount()

            if frame ~= pendingState.lastInventoryScanFrame
                and frame % INVENTORY_SCAN_INTERVAL == 0
            then
                pendingState.lastInventoryScanFrame = frame
                self:SyncSequence(player, pendingState)
            end
        end

        return
    end

    self:UpdateQueuedItem(player, state)

    if state.pendingFloorRefresh then
        if self:RotateFloorEffect(player, state) then
            return
        end

        state.pendingFloorRefresh = state.pendingFloorRefresh - 1

        if state.pendingFloorRefresh <= 0 then
            state.pendingFloorRefresh = nil
        end
    end

    local expectedProxyCount = CountZodiacEntries(state.sequence)

    if state.storageMode == "proxy"
        and self:GetProxyCount(player, state) < expectedProxyCount
    then
        self:RemoveManagedEffect(player, state)
        self.Players[key] = nil
        self.Context:Save()
        return
    end

    local frame = Game():GetFrameCount()

    if state.pendingWispFrame
        or (frame ~= state.lastWispScanFrame
            and frame % INVENTORY_SCAN_INTERVAL == 0)
    then
        state.lastWispScanFrame = frame
        self:ApplyManagedEffect(player, state)
    end

    if frame ~= state.lastInventoryScanFrame
        and frame % INVENTORY_SCAN_INTERVAL == 0
    then
        state.lastInventoryScanFrame = frame

        if self:SyncSequence(player, state) then
            self.Context:Save()
        end
    end
end

function ZodiacFloorItemDisplayModule:OnNewLevel()
    if not self.RunActive or not self.Context:IsEnabled(SETTING_KEY) then
        return
    end

    for _, state in pairs(self.Players) do
        if not state.suspendedForReroll then
            state.pendingFloorRefresh = 3
        end
    end
end

function ZodiacFloorItemDisplayModule:OnNewRoom()
    if not self.RunActive or not self.Context:IsEnabled(SETTING_KEY) then
        return
    end

    local game = Game()

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(playerIndex)
        local state = self.Players[self:GetPlayerKey(player)]

        if state and not state.suspendedForReroll
            and not state.pendingFloorRefresh
        then
            self:ApplyManagedEffect(player, state)
        end
    end
end

function ZodiacFloorItemDisplayModule:OnSettingChanged(value)
    if not self.RunActive or not self.ProxyIdsReady then
        return
    end

    local game = Game()

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(playerIndex)
        local key = self:GetPlayerKey(player)
        local state = self.Players[key]

        if value == false then
            if state then
                self:RestoreStateToZodiac(player, state)
                self.Players[key] = nil
            else
                self:RecoverStrayProxies(player)
            end
            self.PendingPlayers[key] = nil
        else
            self:RecoverStrayProxies(player)

            if not self:AdoptZodiac(player, nil) then
                self.PendingPlayers[key] = self:CreatePendingState(
                    player,
                    playerIndex
                )
            end
        end
    end

    self.Context:Save()
end

function ZodiacFloorItemDisplayModule:GetSaveData()
    if self.RunSeed == nil then
        return self:SanitizeSavedData(self.SavedData)
    end

    local savedPlayers = {}

    for _, state in pairs(self.Players) do
        if state.playerIndex ~= nil and #state.sequence > 0 then
            savedPlayers[tostring(state.playerIndex)] = {
                effect = state.effect,
                sequence = state.sequence,
                baseline = state.baseline,
                effectCarrier = "wisp",
            }
        end
    end

    return {
        runSeed = self.RunSeed,
        players = savedPlayers,
    }
end

function ZodiacFloorItemDisplayModule:OnPreGameExit()
    if self.RunActive then
        local game = Game()

        for playerIndex = 0, game:GetNumPlayers() - 1 do
            local player = Isaac.GetPlayer(playerIndex)
            local state = self.Players[self:GetPlayerKey(player)]

            if state then
                self:RemoveManagedEffect(player, state)
            end
        end
    end

    self.RunActive = false
end

return ZodiacFloorItemDisplayModule
