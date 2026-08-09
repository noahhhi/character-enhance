local EdenChoicesModule = {}
EdenChoicesModule.__index = EdenChoicesModule

local VANILLA_POOLS_BY_ITEM = include(
    "scripts/eden_item_pool_membership"
)

local STARTING_CHOICE_KEY = "edenStartingItemChoice"
local BLESSING_CHOICE_KEY = "edenBlessingDuplicateFix"
local EDENS_BLESSING = CollectibleType.COLLECTIBLE_EDENS_BLESSING
local EDEN = PlayerType.PLAYER_EDEN
local COLLECTIBLE_PICKUP = PickupVariant.PICKUP_COLLECTIBLE
local COIN_PICKUP = PickupVariant.PICKUP_COIN
local PENNY = CoinSubType.COIN_PENNY
local ACTIVE = ItemType.ITEM_ACTIVE
local PASSIVE = ItemType.ITEM_PASSIVE
local FAMILIAR = ItemType.ITEM_FAMILIAR
local NO_EDEN_TAG = ItemConfig.TAG_NO_EDEN or (1 << 32)
local CHOICE_COUNT = 3
local RECYCLED_ITEM_LIMIT = 16
local CHOICE_SPACING = 80
local GROUP_SPACING = 88
local SEED_STEP = 104729
local STARTING_SEED_SALT = 32452843
local BLESSING_SEED_SALT = 49979687
local RNG_SHIFT_INDEX = 35

local function Debug(message)
    if type(Isaac.DebugString) == "function" then
        Isaac.DebugString("[Character Enhance][Eden] " .. message)
    end
end

local function NormalizeSeed(seed)
    local normalized = math.abs(math.floor(tonumber(seed) or 1)) % 2147483647
    return normalized == 0 and 1 or normalized
end

local function AddDifference(player, getterName, adderName, wanted, ...)
    local current = player[getterName](player)
    local difference = wanted - current

    if difference ~= 0 then
        player[adderName](player, difference, ...)
    end
end

local function GetConfigGrant(config, field)
    local value = config and config[field]

    if type(value) ~= "number"
        or value ~= value
        or value == math.huge
        or value == -math.huge
    then
        return 0
    end

    return math.max(0, math.floor(value))
end

function EdenChoicesModule.New(context)
    local self = setmetatable({
        Context = context,
        PendingRewards = 0,
        PendingPickups = {},
        PlayerBaselines = {},
        SuppressedPickupCounts = {},
        RedirectedPickupSeeds = {},
        RemovedStartingEntities = {},
        PreservedRunSeed = nil,
        PreservedRecycledItems = {},
        PreservedConsumedRecycledItems = {},
        RunSeed = nil,
        RunActive = false,
        RecycledItems = {},
        ConsumedRecycledItems = {},
        DynamicPoolsByItem = {},
        LastRoomTimeCounter = nil,
    }, EdenChoicesModule)

    self:OnSaveDataLoaded(
        context:GetSavedModuleData(BLESSING_CHOICE_KEY)
    )

    context.Mod:AddCallback(
        ModCallbacks.MC_POST_PLAYER_INIT,
        function(_, player)
            self:OnPlayerInit(player)
        end
    )
    local preSpawnCallback = function(
        _,
        entityType,
        variant,
        subtype,
        position,
        velocity,
        spawner,
        seed
    )
        return self:OnPreEntitySpawn(
            entityType,
            variant,
            subtype,
            position,
            velocity,
            spawner,
            seed
        )
    end

    -- Intercept unresolved player-spawned pickups before their subtype pools
    -- are queried. Deleting Marbles trinkets in MC_POST_PICKUP_INIT is too
    -- late: their concrete subtypes have already advanced the trinket stream.
    if type(context.Mod.AddPriorityCallback) == "function" then
        context.Mod:AddPriorityCallback(
            ModCallbacks.MC_PRE_ENTITY_SPAWN,
            CallbackPriority.IMPORTANT,
            preSpawnCallback,
            EntityType.ENTITY_PICKUP
        )
    else
        context.Mod:AddCallback(
            ModCallbacks.MC_PRE_ENTITY_SPAWN,
            preSpawnCallback,
            EntityType.ENTITY_PICKUP
        )
    end
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_PICKUP_INIT,
        function(_, pickup)
            self:OnPickupInit(pickup)
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_FAMILIAR_INIT,
        function(_, familiar)
            self:OnFamiliarInit(familiar)
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_EFFECT_INIT,
        function(_, effect)
            self:OnEffectInit(effect)
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_PRE_PICKUP_COLLISION,
        function(_, pickup, collider)
            self:OnPrePickupCollision(pickup, collider)
        end,
        COLLECTIBLE_PICKUP
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_PEFFECT_UPDATE,
        function(_, player)
            self:OnPlayerEffectUpdate(player)
        end
    )
    local preGetCollectibleCallback = function(
        _,
        poolType,
        decrease,
        seed
    )
        return self:OnPreGetCollectible(poolType, decrease, seed)
    end

    if type(context.Mod.AddPriorityCallback) == "function" then
        context.Mod:AddPriorityCallback(
            ModCallbacks.MC_PRE_GET_COLLECTIBLE,
            CallbackPriority.LATE,
            preGetCollectibleCallback
        )
    else
        context.Mod:AddCallback(
            ModCallbacks.MC_PRE_GET_COLLECTIBLE,
            preGetCollectibleCallback
        )
    end
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_GAME_STARTED,
        function(_, isContinued)
            self:OnGameStarted(isContinued)
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_NEW_ROOM,
        function()
            self:OnNewRoom()
        end
    )

    -- MC_POST_GAME_STARTED is not replayed by the debug-console `luamod`
    -- command. Restore only the saved pool overlay when reloading mid-run;
    -- never replay the new-run starting choice itself.
    if Game():GetFrameCount() > 0 then
        self:ActivateRun(true)
    end

    return self
end

function EdenChoicesModule:SanitizePendingRewards(savedData)
    if type(savedData) ~= "table" then
        return 0
    end

    local pendingRewards = savedData.pendingRewards

    if type(pendingRewards) ~= "number"
        or pendingRewards ~= pendingRewards
        or pendingRewards == math.huge
        or pendingRewards == -math.huge
    then
        return 0
    end

    return math.max(0, math.min(99, math.floor(pendingRewards)))
end

function EdenChoicesModule:OnSaveDataLoaded(savedData)
    self.PendingRewards = self:SanitizePendingRewards(savedData)

    local runSeed = type(savedData) == "table" and savedData.runSeed

    if type(runSeed) == "number"
        and runSeed == runSeed
        and runSeed ~= math.huge
        and runSeed ~= -math.huge
        and runSeed >= 0
        and runSeed <= 0xFFFFFFFF
    then
        self.PreservedRunSeed = math.floor(runSeed)
    else
        self.PreservedRunSeed = nil
    end

    self.PreservedRecycledItems = {}
    local recycledItems = type(savedData) == "table"
        and savedData.recycledItems

    local collectibles = Isaac.GetItemConfig():GetCollectibles()
    local maximum = math.max(0, (collectibles.Size or 1) - 1)

    if type(recycledItems) == "table" then
        for _, collectible in ipairs(recycledItems) do
            if #self.PreservedRecycledItems >= RECYCLED_ITEM_LIMIT then
                break
            end

            if type(collectible) == "number"
                and collectible == math.floor(collectible)
                and collectible > 0
                and collectible <= maximum
                and Isaac.GetItemConfig():GetCollectible(collectible)
            then
                self.PreservedRecycledItems[
                    #self.PreservedRecycledItems + 1
                ] = collectible
            end
        end
    end

    self.PreservedConsumedRecycledItems = {}
    local consumedItems = type(savedData) == "table"
        and savedData.consumedRecycledItems

    if type(consumedItems) == "table" then
        for _, entry in ipairs(consumedItems) do
            if #self.PreservedConsumedRecycledItems
                >= RECYCLED_ITEM_LIMIT
            then
                break
            end

            local collectible = type(entry) == "table"
                and entry.collectible
            local timeCounter = type(entry) == "table"
                and entry.timeCounter

            if type(collectible) == "number"
                and collectible == math.floor(collectible)
                and collectible > 0
                and collectible <= maximum
                and Isaac.GetItemConfig():GetCollectible(collectible)
                and type(timeCounter) == "number"
                and timeCounter == timeCounter
                and timeCounter ~= math.huge
                and timeCounter ~= -math.huge
                and timeCounter >= 0
            then
                self.PreservedConsumedRecycledItems[
                    #self.PreservedConsumedRecycledItems + 1
                ] = {
                    collectible = collectible,
                    timeCounter = math.floor(timeCounter),
                }
            end
        end
    end
end

function EdenChoicesModule:GetRunSeed()
    return Game():GetSeeds():GetStartSeed()
end

function EdenChoicesModule:ActivateRun(isContinued)
    self.RunSeed = self:GetRunSeed()
    self.RunActive = true
    self.RecycledItems = {}
    self.ConsumedRecycledItems = {}
    self.LastRoomTimeCounter = self:GetTimeCounter()

    if not isContinued or self.PreservedRunSeed ~= self.RunSeed then
        return
    end

    for _, collectible in ipairs(self.PreservedRecycledItems) do
        self.RecycledItems[#self.RecycledItems + 1] = collectible
    end

    for _, entry in ipairs(self.PreservedConsumedRecycledItems) do
        self.ConsumedRecycledItems[
            #self.ConsumedRecycledItems + 1
        ] = {
            collectible = entry.collectible,
            timeCounter = entry.timeCounter,
        }
    end
end

function EdenChoicesModule:QueueRecycledItem(collectible)
    local pools = self:GetCollectiblePools(collectible)

    if not pools or #pools == 0 then
        Debug(string.format(
            "could not recycle native Eden passive %d: no known pool",
            collectible
        ))
        return false
    end

    self.RecycledItems[#self.RecycledItems + 1] = collectible
    Debug(string.format(
        "returned native Eden passive %d to pool overlays %s",
        collectible,
        table.concat(pools, ",")
    ))
    return true
end

function EdenChoicesModule:GetCollectiblePools(collectible)
    local cached = self.DynamicPoolsByItem[collectible]

    if cached ~= nil then
        return cached ~= false and cached or nil
    end

    local itemPool = Game():GetItemPool()

    -- REPENTOGON exposes the authoritative live pools, including additions
    -- made by other mods. Standard Repentance+ falls back to the generated
    -- vanilla membership table above.
    if type(itemPool.GetNumItemPools) == "function"
        and type(itemPool.GetCollectiblesFromPool) == "function"
    then
        local livePools = {}
        local poolCount = itemPool:GetNumItemPools()

        for poolType = 0, poolCount - 1 do
            local entries = itemPool:GetCollectiblesFromPool(poolType) or {}

            for _, entry in ipairs(entries) do
                if entry.itemID == collectible
                    and (entry.initialWeight or 1) > 0
                then
                    livePools[#livePools + 1] = poolType
                    break
                end
            end
        end

        if #livePools > 0 then
            self.DynamicPoolsByItem[collectible] = livePools
            return livePools
        end
    end

    local pools = VANILLA_POOLS_BY_ITEM[collectible]
    self.DynamicPoolsByItem[collectible] = pools or false
    return pools
end

function EdenChoicesModule:IsCollectibleInPool(collectible, poolType)
    local pools = self:GetCollectiblePools(collectible)

    for _, candidatePool in ipairs(pools or {}) do
        if candidatePool == poolType then
            return true
        end
    end

    return false
end

function EdenChoicesModule:GetTimeCounter()
    local game = Game()

    if type(game.TimeCounter) == "number" then
        return math.max(0, math.floor(game.TimeCounter))
    end

    return math.max(0, math.floor(game:GetFrameCount()))
end

function EdenChoicesModule:OnPreGetCollectible(poolType, decrease, _)
    if not self.RunActive or not decrease or #self.RecycledItems == 0 then
        return nil
    end

    for index, collectible in ipairs(self.RecycledItems) do
        if self:IsCollectibleInPool(collectible, poolType) then
            table.remove(self.RecycledItems, index)
            self.ConsumedRecycledItems[
                #self.ConsumedRecycledItems + 1
            ] = {
                collectible = collectible,
                timeCounter = self:GetTimeCounter(),
            }

            -- Persist both the pop and its time so a continue/hot reload
            -- cannot duplicate it, while a room rewind can put it back.
            self.Context:Save()
            Debug(string.format(
                "recycled native Eden passive %d from pool overlay %d",
                collectible,
                poolType
            ))
            return collectible
        end
    end

    return nil
end

function EdenChoicesModule:OnNewRoom()
    if not self.RunActive then
        return
    end

    local timeCounter = self:GetTimeCounter()
    local isRewind = self.LastRoomTimeCounter ~= nil
        and timeCounter < self.LastRoomTimeCounter
    local restored = 0

    if isRewind then
        for index = #self.ConsumedRecycledItems, 1, -1 do
            local entry = self.ConsumedRecycledItems[index]

            if entry.timeCounter >= timeCounter then
                table.insert(self.RecycledItems, 1, entry.collectible)
                table.remove(self.ConsumedRecycledItems, index)
                restored = restored + 1
            end
        end
    end

    self.LastRoomTimeCounter = timeCounter

    if restored > 0 then
        self.Context:Save()
        Debug(string.format(
            "rewind restored %d native Eden pool overlay item(s)",
            restored
        ))
    end
end

function EdenChoicesModule:GetPlayerKey(player)
    return tostring(GetPtrHash(player))
end

function EdenChoicesModule:CaptureCollectibles(player)
    local counts = {}
    local collectibles = Isaac.GetItemConfig():GetCollectibles()
    local maximum = math.max(0, (collectibles.Size or 1) - 1)

    for collectible = 1, maximum do
        local count = player:GetCollectibleNum(collectible, true)

        if count > 0 then
            counts[collectible] = count
        end
    end

    return counts
end

function EdenChoicesModule:CapturePlayerState(player)
    return {
        coins = player:GetNumCoins(),
        bombs = player:GetNumBombs(),
        keys = player:GetNumKeys(),
        hearts = player:GetHearts(),
        maxHearts = player:GetMaxHearts(),
        soulHearts = player:GetSoulHearts(),
        boneHearts = player:GetBoneHearts(),
        rottenHearts = player:GetRottenHearts(),
        brokenHearts = player:GetBrokenHearts(),
        goldenHearts = player:GetGoldenHearts(),
        eternalHearts = player:GetEternalHearts(),
    }
end

function EdenChoicesModule:OnPlayerInit(player)
    if player:GetPlayerType() ~= EDEN
        or not self.Context:IsEnabled(STARTING_CHOICE_KEY)
        or Game():GetFrameCount() ~= 0
    then
        return
    end

    local playerKey = self:GetPlayerKey(player)
    self.PlayerBaselines[playerKey] = {
        player = player,
        collectibles = self:CaptureCollectibles(player),
        state = self:CapturePlayerState(player),
    }
    self.SuppressedPickupCounts[playerKey] = 0
    self.RemovedStartingEntities[playerKey] = 0
    Debug("captured Eden baseline before native starting items")
end

function EdenChoicesModule:OnPreEntitySpawn(
    entityType,
    variant,
    subtype,
    _position,
    _velocity,
    spawner,
    seed
)
    if entityType ~= EntityType.ENTITY_PICKUP
        or not spawner
        or type(seed) ~= "number"
    then
        return nil
    end

    local player = spawner:ToPlayer()

    if not player then
        return nil
    end

    local playerKey = self:GetPlayerKey(player)
    local baseline = self.PlayerBaselines[playerKey]

    if self.SuppressedPickupCounts[playerKey] == nil
        or not baseline
        or not self:FindNativeStartingPassive(player, baseline)
    then
        return nil
    end

    self.SuppressedPickupCounts[playerKey] =
        self.SuppressedPickupCounts[playerKey] + 1
    self.RedirectedPickupSeeds[seed] = {
        playerKey = playerKey,
        originalVariant = variant,
        originalSubtype = subtype,
    }
    Debug(string.format(
        "redirected native passive pickup 5.%d.%d before subtype resolution",
        variant,
        subtype
    ))
    return {
        EntityType.ENTITY_PICKUP,
        COIN_PICKUP,
        PENNY,
        seed,
    }
end

function EdenChoicesModule:OnPickupInit(pickup)
    local redirected = pickup
        and self.RedirectedPickupSeeds[pickup.InitSeed]

    if not redirected then
        return
    end

    self.RedirectedPickupSeeds[pickup.InitSeed] = nil
    pickup:Remove()
    Debug(string.format(
        "removed redirected native passive pickup from 5.%d.%d",
        redirected.originalVariant,
        redirected.originalSubtype
    ))
end

function EdenChoicesModule:GetEntityOwner(entity)
    local owner = entity and entity.Player

    if owner then
        return owner
    end

    local spawner = entity and entity.SpawnerEntity
    owner = spawner and spawner:ToPlayer()

    if owner then
        return owner
    end

    local parent = entity and entity.Parent
    return parent and parent:ToPlayer()
end

function EdenChoicesModule:RemoveStartingEntity(entity)
    local owner = self:GetEntityOwner(entity)

    if not owner then
        return
    end

    local playerKey = self:GetPlayerKey(owner)
    local baseline = self.PlayerBaselines[playerKey]

    if self.RemovedStartingEntities[playerKey] == nil
        or not baseline
        or not self:FindNativeStartingPassive(owner, baseline)
    then
        return
    end

    self.RemovedStartingEntities[playerKey] =
        self.RemovedStartingEntities[playerKey] + 1
    entity:Remove()
    Debug(string.format(
        "removed native starting entity %d.%d.%d for Eden",
        entity.Type,
        entity.Variant,
        entity.SubType
    ))
end

function EdenChoicesModule:OnFamiliarInit(familiar)
    self:RemoveStartingEntity(familiar)
end

function EdenChoicesModule:OnEffectInit(effect)
    self:RemoveStartingEntity(effect)
end

function EdenChoicesModule:OnPrePickupCollision(pickup, collider)
    if not pickup
        or pickup.Variant ~= COLLECTIBLE_PICKUP
        or pickup.SubType ~= EDENS_BLESSING
        or not collider
        or not self.Context:IsEnabled(BLESSING_CHOICE_KEY)
    then
        return
    end

    local player = collider:ToPlayer()

    if not player then
        return
    end

    -- The real pedestal must be marked before vanilla copies its state into
    -- QueuedItem. This disables vanilla's next-run copy without replacing the
    -- pedestal or postponing first-pickup side effects until after collection.
    pickup.Touched = true

    local playerKey = self:GetPlayerKey(player)

    if not self.PendingPickups[playerKey] then
        self.PendingPickups[playerKey] = {
            pickup = pickup,
            graceFrames = 10,
        }
    end
end

function EdenChoicesModule:RecordQueuedPickup(playerKey, queuedItem)
    queuedItem.Touched = true
    self.PendingRewards = math.min(99, self.PendingRewards + 1)
    self.PendingPickups[playerKey] = nil
    self.Context:Save()
    Debug(string.format(
        "recorded Eden's Blessing choice; pending=%d",
        self.PendingRewards
    ))
end

function EdenChoicesModule:OnPlayerEffectUpdate(player)
    local playerKey = self:GetPlayerKey(player)
    local pending = self.PendingPickups[playerKey]

    if not pending then
        return
    end

    local queuedItemData = player.QueuedItem
    local queuedItem = queuedItemData and queuedItemData.Item

    if queuedItem and queuedItem.ID == EDENS_BLESSING then
        self:RecordQueuedPickup(playerKey, queuedItemData)
        return
    end

    if not pending.pickup or not pending.pickup:Exists() then
        pending.graceFrames = pending.graceFrames - 1

        if pending.graceFrames <= 0 then
            self.PendingPickups[playerKey] = nil
        end
    end
end

function EdenChoicesModule:HasNoEdenTag(config)
    if type(config.HasTags) == "function" then
        return config:HasTags(NO_EDEN_TAG)
    end

    return type(config.Tags) == "number"
        and config.Tags & NO_EDEN_TAG ~= 0
end

function EdenChoicesModule:IsChoiceCandidate(player, collectible, excluded)
    local config = Isaac.GetItemConfig():GetCollectible(collectible)

    if not config
        or config.Hidden == true
        or (config.Type ~= ACTIVE
            and config.Type ~= PASSIVE
            and config.Type ~= FAMILIAR)
        or player:GetCollectibleNum(collectible, true) > 0
        or (excluded and excluded[collectible])
        or self:HasNoEdenTag(config)
    then
        return false
    end

    return type(config.IsAvailable) ~= "function" or config:IsAvailable()
end

function EdenChoicesModule:GetChoiceCandidates(player, excluded)
    local itemConfig = Isaac.GetItemConfig()
    local collectibleList = itemConfig:GetCollectibles()
    local maximum = math.max(0, (collectibleList.Size or 1) - 1)
    local candidates = {}

    for collectible = 1, maximum do
        if self:IsChoiceCandidate(player, collectible, excluded) then
            candidates[#candidates + 1] = collectible
        end
    end

    return candidates
end

function EdenChoicesModule:DrawChoices(player, groupIndex, seedSalt, excluded)
    local candidates = self:GetChoiceCandidates(player, excluded)

    if #candidates == 0 then
        return {}
    end

    local startSeed = Game():GetSeeds():GetStartSeed()
    local rng = RNG()
    rng:SetSeed(NormalizeSeed(
        startSeed + seedSalt + groupIndex * SEED_STEP
    ), RNG_SHIFT_INDEX)

    local choices = {}
    local drawCount = math.min(CHOICE_COUNT, #candidates)

    for _ = 1, drawCount do
        local candidateIndex = rng:RandomInt(#candidates) + 1
        local collectible = candidates[candidateIndex]
        choices[#choices + 1] = collectible

        if excluded then
            excluded[collectible] = true
        end

        candidates[candidateIndex] = candidates[#candidates]
        candidates[#candidates] = nil
    end

    return choices
end

function EdenChoicesModule:GetOptionsIndex(groupIndex)
    local seed = NormalizeSeed(Game():GetSeeds():GetStartSeed())
    return 1000 + (seed % 1000000) * 100 + groupIndex
end

function EdenChoicesModule:SpawnChoiceGroup(
    player,
    choices,
    groupIndex,
    groupCount
)
    if #choices == 0 then
        return false
    end

    local room = Game():GetRoom()
    local itemPool = Game():GetItemPool()
    local center = room:GetCenterPos()
    local rowOffset = (groupIndex - (groupCount + 1) / 2) * GROUP_SPACING
    local optionsIndex = self:GetOptionsIndex(groupIndex)

    for choiceIndex, collectible in ipairs(choices) do
        local columnOffset = (choiceIndex - (#choices + 1) / 2)
            * CHOICE_SPACING
        local target = center + Vector(columnOffset, rowOffset)
        local position = room:FindFreePickupSpawnPosition(target, 0, true)
        local pickup = Isaac.Spawn(
            EntityType.ENTITY_PICKUP,
            COLLECTIBLE_PICKUP,
            collectible,
            position,
            Vector.Zero,
            player
        ):ToPickup()

        if pickup then
            pickup.OptionsPickupIndex = optionsIndex
            pickup.Wait = 30
            pickup.Price = 0
            pickup.AutoUpdatePrice = false
            local removed = itemPool:RemoveCollectible(collectible)
            Debug(string.format(
                "removed spawned choice %d from run item pools: %s",
                collectible,
                tostring(removed)
            ))
        end
    end

    Debug(string.format(
        "spawned choice group %d: %s",
        groupIndex,
        table.concat(choices, ",")
    ))
    return true
end

function EdenChoicesModule:FindNativeStartingPassive(player, baseline)
    local itemConfig = Isaac.GetItemConfig()
    local collectibleList = itemConfig:GetCollectibles()
    local maximum = math.max(0, (collectibleList.Size or 1) - 1)

    for collectible = 1, maximum do
        local config = itemConfig:GetCollectible(collectible)
        local previousCount = baseline.collectibles[collectible] or 0

        if config
            and (config.Type == PASSIVE or config.Type == FAMILIAR)
            and player:GetCollectibleNum(collectible, true) > previousCount
        then
            return collectible
        end
    end

    return nil
end

function EdenChoicesModule:FindNativeStartingActive(player, baseline)
    local itemConfig = Isaac.GetItemConfig()
    local collectibleList = itemConfig:GetCollectibles()
    local maximum = math.max(0, (collectibleList.Size or 1) - 1)

    for collectible = 1, maximum do
        local config = itemConfig:GetCollectible(collectible)
        local previousCount = baseline.collectibles[collectible] or 0

        if config
            and config.Type == ACTIVE
            and player:GetCollectibleNum(collectible, true) > previousCount
        then
            return collectible, config
        end
    end

    return nil, nil
end

function EdenChoicesModule:GetStateWithActiveGrants(state, activeConfig)
    local result = {}

    for key, value in pairs(state) do
        result[key] = value
    end

    if not activeConfig then
        return result
    end

    result.coins = math.min(
        99,
        result.coins + GetConfigGrant(activeConfig, "AddCoins")
    )
    result.bombs = math.min(
        99,
        result.bombs + GetConfigGrant(activeConfig, "AddBombs")
    )
    result.keys = math.min(
        99,
        result.keys + GetConfigGrant(activeConfig, "AddKeys")
    )
    result.maxHearts = result.maxHearts
        + GetConfigGrant(activeConfig, "AddMaxHearts")
    result.hearts = math.min(
        result.maxHearts,
        result.hearts + GetConfigGrant(activeConfig, "AddHearts")
    )
    result.soulHearts = result.soulHearts
        + GetConfigGrant(activeConfig, "AddSoulHearts")
        + GetConfigGrant(activeConfig, "AddBlackHearts")
    return result
end

function EdenChoicesModule:RestorePlayerState(player, state)
    AddDifference(player, "GetNumCoins", "AddCoins", state.coins)
    AddDifference(player, "GetNumBombs", "AddBombs", state.bombs)
    AddDifference(player, "GetNumKeys", "AddKeys", state.keys)

    AddDifference(
        player,
        "GetGoldenHearts",
        "AddGoldenHearts",
        state.goldenHearts
    )
    AddDifference(
        player,
        "GetEternalHearts",
        "AddEternalHearts",
        state.eternalHearts
    )
    AddDifference(
        player,
        "GetRottenHearts",
        "AddRottenHearts",
        state.rottenHearts
    )
    AddDifference(
        player,
        "GetBoneHearts",
        "AddBoneHearts",
        state.boneHearts
    )
    AddDifference(
        player,
        "GetBrokenHearts",
        "AddBrokenHearts",
        state.brokenHearts
    )
    AddDifference(
        player,
        "GetMaxHearts",
        "AddMaxHearts",
        state.maxHearts,
        false
    )
    AddDifference(player, "GetHearts", "AddHearts", state.hearts)

    -- Eden's native generation never creates black hearts. Rebuild the soul
    -- heart row so a removed passive cannot leave its pickup-only health.
    local currentSoulHearts = player:GetSoulHearts()

    if currentSoulHearts ~= 0 then
        player:AddSoulHearts(-currentSoulHearts)
    end

    if state.soulHearts ~= 0 then
        player:AddSoulHearts(state.soulHearts)
    end
end

function EdenChoicesModule:RemoveNativeStartingPassive(player, baseline)
    local collectible = self:FindNativeStartingPassive(player, baseline)
    local activeCollectible, activeConfig = self:FindNativeStartingActive(
        player,
        baseline
    )

    if collectible then
        player:RemoveCollectible(collectible, true)
        player:TryRemoveCollectibleCostume(collectible, false)
        player:AddCacheFlags(CacheFlag.CACHE_ALL)
        player:EvaluateItems()
        Debug(string.format(
            "removed native Eden passive %d; redirected pickups=%d; "
                .. "removed entities=%d",
            collectible,
            self.SuppressedPickupCounts[self:GetPlayerKey(player)] or 0,
            self.RemovedStartingEntities[self:GetPlayerKey(player)] or 0
        ))
    else
        Debug("native Eden passive was not found")
    end

    self:RestorePlayerState(
        player,
        self:GetStateWithActiveGrants(baseline.state, activeConfig)
    )

    if activeCollectible then
        Debug(string.format(
            "preserved native Eden active %d pickup resources",
            activeCollectible
        ))
    end

    return collectible
end

function EdenChoicesModule:GrantOutstandingRewardDirectly(
    player,
    rewardIndex,
    excluded
)
    local choices = self:DrawChoices(
        player,
        rewardIndex,
        BLESSING_SEED_SALT,
        excluded
    )
    local collectible = choices[1]

    if not collectible then
        return false
    end

    player:AddCollectible(collectible, 0, true)
    Debug(string.format(
        "granted disabled-setting fallback reward %d",
        collectible
    ))
    return true
end

function EdenChoicesModule:OnGameStarted(isContinued)
    self.PendingPickups = {}
    self.RedirectedPickupSeeds = {}
    self:ActivateRun(isContinued)

    if isContinued then
        self.PlayerBaselines = {}
        self.SuppressedPickupCounts = {}
        self.RemovedStartingEntities = {}
        return
    end

    local groups = {}
    local excluded = {}
    local recycleStateChanged = #self.PreservedRecycledItems > 0

    for playerIndex = 0, Game():GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(playerIndex)
        local playerKey = self:GetPlayerKey(player)
        local baseline = self.PlayerBaselines[playerKey]

        if baseline
            and player:GetPlayerType() == EDEN
            and self.Context:IsEnabled(STARTING_CHOICE_KEY)
        then
            local collectible = self:RemoveNativeStartingPassive(
                player,
                baseline
            )

            if collectible then
                if self:QueueRecycledItem(collectible) then
                    recycleStateChanged = true
                end

                excluded[collectible] = true
            end

            groups[#groups + 1] = {
                player = player,
                seedSalt = STARTING_SEED_SALT + playerIndex * SEED_STEP,
                kind = "starting",
            }
        end
    end

    self.PlayerBaselines = {}
    self.SuppressedPickupCounts = {}
    self.RemovedStartingEntities = {}

    local primaryPlayer = Game():GetNumPlayers() > 0 and Isaac.GetPlayer(0)
    local rewardCount = self.PendingRewards
    self.PendingRewards = 0

    if primaryPlayer and rewardCount > 0 then
        if self.Context:IsEnabled(BLESSING_CHOICE_KEY) then
            for rewardIndex = 1, rewardCount do
                groups[#groups + 1] = {
                    player = primaryPlayer,
                    seedSalt = BLESSING_SEED_SALT
                        + rewardIndex * SEED_STEP,
                    kind = "blessing",
                }
            end
        else
            for rewardIndex = 1, rewardCount do
                if not self:GrantOutstandingRewardDirectly(
                    primaryPlayer,
                    rewardIndex,
                    excluded
                ) then
                    self.PendingRewards = self.PendingRewards + 1
                end
            end
        end
    end

    local unspawnedRewards = 0

    for groupIndex, group in ipairs(groups) do
        local choices = self:DrawChoices(
            group.player,
            groupIndex,
            group.seedSalt,
            excluded
        )

        if not self:SpawnChoiceGroup(
            group.player,
            choices,
            groupIndex,
            #groups
        ) and group.kind == "blessing" then
            unspawnedRewards = unspawnedRewards + 1
        end
    end

    self.PendingRewards = self.PendingRewards + unspawnedRewards

    if rewardCount > 0 or recycleStateChanged then
        self.Context:Save()
    end
end

function EdenChoicesModule:GetSaveData()
    local runSeed = self.RunSeed
    local recycledItems = self.RecycledItems
    local consumedItems = self.ConsumedRecycledItems

    -- Preserve a continuation queue loaded at the file-select menu until the
    -- selected run becomes active and supplies its authoritative start seed.
    if runSeed == nil then
        runSeed = self.PreservedRunSeed
        recycledItems = self.PreservedRecycledItems
        consumedItems = self.PreservedConsumedRecycledItems
    end

    local savedRecycledItems = {}
    local savedConsumedItems = {}

    for _, collectible in ipairs(recycledItems) do
        savedRecycledItems[#savedRecycledItems + 1] = collectible
    end

    for _, entry in ipairs(consumedItems) do
        savedConsumedItems[#savedConsumedItems + 1] = {
            collectible = entry.collectible,
            timeCounter = entry.timeCounter,
        }
    end

    return {
        pendingRewards = self.PendingRewards,
        runSeed = runSeed,
        recycledItems = savedRecycledItems,
        consumedRecycledItems = savedConsumedItems,
    }
end

return EdenChoicesModule
