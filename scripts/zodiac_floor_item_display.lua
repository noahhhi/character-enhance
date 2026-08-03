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
local REVERSE_STARS = Card and Card.CARD_REVERSE_STARS

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
        RestoringGame = false,
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

    if ModCallbacks.MC_USE_CARD and REVERSE_STARS then
        context.Mod:AddCallback(
            ModCallbacks.MC_USE_CARD,
            function(_, card, player)
                self:OnUseCard(card, player)
            end
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

        if type(entry) == "table" then
            local pool = self:SanitizePool(entry.pool)

            if entry.kind == "zodiac" then
                result[#result + 1] = {
                    kind = "zodiac",
                    pool = pool,
                }
            elseif entry.kind == "item" then
                local collectible = self:SanitizeInteger(
                    entry.id,
                    1,
                    0x7FFFFFFF
                )

                if collectible and collectible ~= ZODIAC then
                    result[#result + 1] = {
                        kind = "item",
                        id = collectible,
                        pool = pool,
                    }
                end
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

    for rawCollectible, rawCount in pairs(baseline) do
        local collectible = self:SanitizeInteger(
            rawCollectible,
            1,
            0x7FFFFFFF
        )
        local count = self:SanitizeInteger(rawCount, 0, 99)

        if collectible and collectible ~= ZODIAC and count and count > 0 then
            result[collectible] = count
        end
    end

    return result
end

function ZodiacFloorItemDisplayModule:SanitizeWispSeeds(seeds)
    local result = {}
    local seen = {}

    if type(seeds) ~= "table" then
        return result
    end

    for _, savedSeed in ipairs(seeds) do
        if #result >= 99 then
            break
        end

        local seed = self:SanitizeInteger(savedSeed, 0, 0xFFFFFFFF)

        if seed and not seen[seed] then
            seen[seed] = true
            result[#result + 1] = seed
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

    for rawPlayerIndex, savedState in pairs(savedData.players) do
        local playerIndex = self:SanitizeInteger(rawPlayerIndex, 0, 63)

        if playerIndex and type(savedState) == "table" then
            local effect = self:SanitizeInteger(
                savedState.effect,
                1,
                0x7FFFFFFF
            )
            local sequence = self:SanitizeSequence(savedState.sequence)

            if VALID_EFFECTS[effect] and CountZodiacEntries(sequence) > 0 then
                result.players[tostring(playerIndex)] = {
                    effect = effect,
                    sequence = sequence,
                    baseline = self:SanitizeBaseline(savedState.baseline),
                    displayMode = savedState.displayMode == "native"
                        and "native"
                        or nil,
                    legacyCarrier = savedState.effectCarrier == "wisp",
                    wispSeeds = self:SanitizeWispSeeds(
                        savedState.wispSeeds
                    ),
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
    local game = Game()
    local targetKey = self:GetPlayerKey(player)

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        local candidate = Isaac.GetPlayer(playerIndex)

        if candidate and self:GetPlayerKey(candidate) == targetKey then
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

        if type(proxyId) == "number" and proxyId > 0 then
            self.ProxyByEffect[definition.effect] = proxyId
            self.EffectByProxy[proxyId] = definition.effect
        else
            self.ProxyIdsReady = false
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

function ZodiacFloorItemDisplayModule:RemoveAllProxies(player)
    if not self.ProxyIdsReady then
        return 0
    end

    local removed = 0
    self.MutationDepth = self.MutationDepth + 1

    for proxyId in pairs(self.EffectByProxy) do
        local count = player:GetCollectibleNum(proxyId, true)

        for _ = 1, count do
            self:RemoveOwnedCollectible(player, proxyId)
            removed = removed + 1
        end
    end

    self.MutationDepth = self.MutationDepth - 1
    return removed
end

function ZodiacFloorItemDisplayModule:GetProxyCount(player, effect)
    local proxyId = self.ProxyByEffect[effect]

    if not proxyId then
        return 0
    end

    return player:GetCollectibleNum(proxyId, true)
end

function ZodiacFloorItemDisplayModule:GetZodiacPool(state, ordinal)
    local current = 0

    for _, entry in ipairs(state.sequence) do
        if entry.kind == "zodiac" then
            current = current + 1

            if current == ordinal then
                return entry.pool
            end
        end
    end

    return TREASURE_POOL
end

function ZodiacFloorItemDisplayModule:EnsureMarkers(player, state)
    local desiredCount = player:GetCollectibleNum(ZODIAC, true)
    local effect = player:GetZodiacEffect()

    if desiredCount <= 0 or not VALID_EFFECTS[effect] then
        return self:RemoveAllProxies(player) > 0
    end

    local correctCount = self:GetProxyCount(player, effect)
    local totalCount = 0

    for proxyId in pairs(self.EffectByProxy) do
        totalCount = totalCount
            + player:GetCollectibleNum(proxyId, true)
    end

    if correctCount == desiredCount and totalCount == desiredCount then
        state.storageMode = "display"
        return false
    end

    self:RemoveAllProxies(player)
    local proxyId = self.ProxyByEffect[effect]
    self.MutationDepth = self.MutationDepth + 1

    for ordinal = 1, desiredCount do
        self:AddOwnedCollectible(
            player,
            proxyId,
            self:GetZodiacPool(state, ordinal)
        )
    end

    self.MutationDepth = self.MutationDepth - 1
    state.storageMode = "display"
    return true
end

function ZodiacFloorItemDisplayModule:CaptureLegacySeeds(savedState)
    local seeds = {}

    for _, seed in ipairs(savedState and savedState.wispSeeds or {}) do
        seeds[seed] = true
    end

    return seeds
end

function ZodiacFloorItemDisplayModule:IsWispOwner(wisp, player)
    local owner = wisp and wisp.Player
    return owner ~= nil
        and self:GetPlayerKey(owner) == self:GetPlayerKey(player)
end

function ZodiacFloorItemDisplayModule:CleanupLegacyWisps(
    player,
    savedState
)
    if not Isaac.FindByType or not ENTITY_FAMILIAR or not ITEM_WISP then
        return 0
    end

    local seeds = self:CaptureLegacySeeds(savedState)
    local removed = 0

    for _, entity in ipairs(Isaac.FindByType(
        ENTITY_FAMILIAR,
        ITEM_WISP,
        -1,
        false,
        false
    )) do
        local wisp = type(entity.ToFamiliar) == "function"
            and entity:ToFamiliar()
            or entity
        local data = wisp and type(wisp.GetData) == "function"
            and wisp:GetData()
            or nil
        local seed = wisp and self:SanitizeInteger(
            wisp.InitSeed,
            0,
            0xFFFFFFFF
        )
        local managed = data and data[MANAGED_WISP_TAG] == true
            or seed and seeds[seed]

        if managed and self:IsWispOwner(wisp, player) then
            if type(wisp.Kill) == "function" then
                wisp:Kill()
            else
                wisp:Remove()
            end
            removed = removed + 1
        end
    end

    if removed > 0 then
        if type(player.AddCacheFlags) == "function" and CacheFlag then
            player:AddCacheFlags(CacheFlag.CACHE_ALL)
        end
        if type(player.EvaluateItems) == "function" then
            player:EvaluateItems()
        end
    end

    return removed
end

function ZodiacFloorItemDisplayModule:MigrateLegacyZodiac(
    player,
    state,
    expectedCount
)
    local actualCount = player:GetCollectibleNum(ZODIAC, true)

    if actualCount >= expectedCount then
        return true
    end

    -- Old releases stored the displayed sign in place of the real Zodiac.
    -- This one-time migration is the only path that may synthesize Zodiac.
    -- Normal floor rotation and continue restore must never remove/reacquire
    -- real collectibles: the engine does not clear Zodiac's current-floor
    -- modifier when RemoveCollectible is called, which stacks native stats.
    self:RemoveAllProxies(player)
    self.MutationDepth = self.MutationDepth + 1

    for ordinal = actualCount + 1, expectedCount do
        self:AddOwnedCollectible(
            player,
            ZODIAC,
            self:GetZodiacPool(state, ordinal)
        )
    end

    self.MutationDepth = self.MutationDepth - 1
    return player:GetCollectibleNum(ZODIAC, true) >= expectedCount
end

function ZodiacFloorItemDisplayModule:AppendZodiacEntries(
    state,
    count
)
    local added = 0

    for _ = 1, count do
        if #state.sequence >= MAX_SEQUENCE_LENGTH then
            break
        end

        state.sequence[#state.sequence + 1] = {
            kind = "zodiac",
            pool = self:ConsumeRecentPool(ZODIAC),
        }
        added = added + 1
    end

    return added
end

function ZodiacFloorItemDisplayModule:RemoveZodiacEntries(
    state,
    count
)
    local removed = 0

    for index = #state.sequence, 1, -1 do
        if removed >= count then
            break
        end

        if state.sequence[index].kind == "zodiac" then
            table.remove(state.sequence, index)
            removed = removed + 1
        end
    end

    return removed
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
        storageMode = "native",
        suspendedForReroll = false,
        lastInventoryScanFrame = -1,
    }

    self:AppendZodiacEntries(state, zodiacCount)
    self.PendingPlayers[playerKey] = nil
    return state
end

function ZodiacFloorItemDisplayModule:AdoptZodiac(player, state)
    local zodiacCount = player:GetCollectibleNum(ZODIAC, true)

    if zodiacCount <= 0 or not self.ProxyIdsReady then
        return false
    end

    local playerIndex = self:GetPlayerIndex(player)

    if playerIndex == nil then
        return false
    end

    local changed = false

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
        changed = true
    else
        self:NormalizeSequence(state)
        changed = self:SyncSequence(player, state) or changed
        local recordedCount = CountZodiacEntries(state.sequence)

        if zodiacCount > recordedCount then
            self:AppendZodiacEntries(state, zodiacCount - recordedCount)
            changed = true
        elseif zodiacCount < recordedCount then
            self:RemoveZodiacEntries(state, recordedCount - zodiacCount)
            changed = true
        end
    end

    changed = self:EnsureMarkers(player, state) or changed
    state.lastCounts = self:CaptureCounts(player)

    if changed and not self.RestoringGame then
        self.Context:Save()
    end

    return true
end

function ZodiacFloorItemDisplayModule:IsInternalNativeReroll(player)
    return false
end

function ZodiacFloorItemDisplayModule:RotateFloorEffect(player, state)
    if state.suspendedForReroll then
        return false
    end

    local effect = player:GetZodiacEffect()

    if not VALID_EFFECTS[effect] then
        return false
    end

    self:EnsureMarkers(player, state)

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

    self:RemoveAllProxies(player)
    state.storageMode = "native"
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

    local key = self:GetPlayerKey(player)
    self:RemoveAllProxies(player)
    self.Players[key] = nil
    local playerIndex = self:GetPlayerIndex(player)

    if playerIndex ~= nil then
        self.PendingPlayers[key] = self:CreatePendingState(
            player,
            playerIndex
        )
    end

    if player:GetCollectibleNum(ZODIAC, true) > 0 then
        self:AdoptZodiac(player, nil)
    else
        self.Context:Save()
    end

    return true
end

function ZodiacFloorItemDisplayModule:RestoreSavedState(
    player,
    playerIndex,
    savedState,
    displayEnabled
)
    if type(savedState) ~= "table"
        or CountZodiacEntries(savedState.sequence) <= 0
    then
        return nil
    end

    local state = {
        playerIndex = playerIndex,
        effect = savedState.effect,
        sequence = savedState.sequence,
        baseline = savedState.baseline,
        storageMode = savedState.displayMode == "native"
            and "display"
            or "legacyProxy",
        suspendedForReroll = false,
        lastInventoryScanFrame = -1,
    }

    self:NormalizeSequence(state)
    self:CleanupLegacyWisps(player, savedState)
    local expectedZodiacCount = CountZodiacEntries(state.sequence)
    local actualZodiacCount = player:GetCollectibleNum(ZODIAC, true)
    local legacyProxyCount = self:GetProxyCount(player, state.effect)

    if actualZodiacCount < expectedZodiacCount
        and legacyProxyCount >= expectedZodiacCount
    then
        self.Players[self:GetPlayerKey(player)] = state

        if not self:MigrateLegacyZodiac(
            player,
            state,
            expectedZodiacCount
        ) then
            self.Players[self:GetPlayerKey(player)] = nil
            return nil
        end

        actualZodiacCount = player:GetCollectibleNum(ZODIAC, true)
    end

    if actualZodiacCount < expectedZodiacCount then
        return nil
    end

    local nativeEffect = player:GetZodiacEffect()

    if VALID_EFFECTS[nativeEffect] then
        state.effect = nativeEffect
    end

    state.storageMode = displayEnabled and "display" or "native"
    self.Players[self:GetPlayerKey(player)] = state

    if displayEnabled then
        self:EnsureMarkers(player, state)
    else
        self:RemoveAllProxies(player)
    end

    state.lastCounts = self:CaptureCounts(player)
    return state
end

function ZodiacFloorItemDisplayModule:OnGameStarted(isContinued)
    self.RestoringGame = true
    self.RunSeed = self:GetRunSeed()
    self.RunActive = true
    self.Players = {}
    self.PendingPlayers = {}
    self.RecentPools = {}
    self.TrackedCollectibles = nil

    if not self:ResolveProxyIds() then
        self.RestoringGame = false
        return
    end

    self:BuildTrackedCollectibles()
    local sanitized = self:SanitizeSavedData(self.SavedData)
    local canRestore = isContinued and sanitized.runSeed == self.RunSeed
    local displayEnabled = self.Context:IsEnabled(SETTING_KEY)
    local game = Game()

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(playerIndex)
        local savedState = canRestore
            and sanitized.players[tostring(playerIndex)]
            or nil
        local state = savedState and self:RestoreSavedState(
            player,
            playerIndex,
            savedState,
            displayEnabled
        )

        if not state then
            self:CleanupLegacyWisps(player, savedState)
            self:RemoveAllProxies(player)

            if displayEnabled then
                if not self:AdoptZodiac(player, nil) then
                    self.PendingPlayers[self:GetPlayerKey(player)]
                        = self:CreatePendingState(player, playerIndex)
                end
            end
        elseif not displayEnabled then
            self.Players[self:GetPlayerKey(player)] = nil
        end
    end

    self.RestoringGame = false
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

function ZodiacFloorItemDisplayModule:ClearPlayerState(player, state)
    self:RemoveAllProxies(player)
    self:CleanupLegacyWisps(player, nil)
    local key = self:GetPlayerKey(player)
    self.Players[key] = nil
    local playerIndex = self:GetPlayerIndex(player)

    if playerIndex ~= nil then
        self.PendingPlayers[key] = self:CreatePendingState(
            player,
            playerIndex
        )
    end

    self.Context:Save()
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
            self:RemoveAllProxies(player)
            self:CleanupLegacyWisps(player, nil)
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

    if state and state.pendingFloorRefresh then
        if self:RotateFloorEffect(player, state) then
            return
        end

        state.pendingFloorRefresh = state.pendingFloorRefresh - 1

        if state.pendingFloorRefresh <= 0 then
            state.pendingFloorRefresh = nil
        end
    end

    local zodiacCount = player:GetCollectibleNum(ZODIAC, true)

    if zodiacCount > 0 then
        local pendingState = self.PendingPlayers[key]

        if not state and pendingState then
            self:UpdateQueuedItem(player, pendingState)
            self:SyncSequence(player, pendingState)
        end

        self:AdoptZodiac(player, state)
        state = self.Players[key]
    elseif state then
        self:ClearPlayerState(player, state)
        return
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
    local frame = Game():GetFrameCount()

    if frame ~= state.lastInventoryScanFrame
        and frame % INVENTORY_SCAN_INTERVAL == 0
    then
        state.lastInventoryScanFrame = frame
        local changed = self:SyncSequence(player, state)
        local effect = player:GetZodiacEffect()

        if VALID_EFFECTS[effect] and effect ~= state.effect then
            changed = self:EnsureMarkers(player, state) or changed
            state.effect = effect
        else
            changed = self:EnsureMarkers(player, state) or changed
        end

        if changed then
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
            local effect = player:GetZodiacEffect()
            local changed = false

            if VALID_EFFECTS[effect] and effect ~= state.effect then
                changed = self:EnsureMarkers(player, state)
                state.effect = effect
            else
                changed = self:EnsureMarkers(player, state)
            end

            if changed then
                self.Context:Save()
            end
        end
    end
end

function ZodiacFloorItemDisplayModule:OnUseCard(card, player)
    if card == REVERSE_STARS then
        self:PrepareForFullInventoryReroll(player)
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
            self:RemoveAllProxies(player)
            self:CleanupLegacyWisps(player, nil)
            self.Players[key] = nil
            self.PendingPlayers[key] = nil
        else
            self:RemoveAllProxies(player)

            if not self:AdoptZodiac(player, state) then
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
                displayMode = "native",
            }
        end
    end

    return {
        runSeed = self.RunSeed,
        players = savedPlayers,
    }
end

function ZodiacFloorItemDisplayModule:OnPreGameExit()
    self.RunActive = false
end

return ZodiacFloorItemDisplayModule
