local EdenChoicesModule = {}
EdenChoicesModule.__index = EdenChoicesModule

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
local PRIMARY_SLOT = ActiveSlot.SLOT_PRIMARY
local SECONDARY_SLOT = ActiveSlot.SLOT_SECONDARY
local POCKET_SLOT = ActiveSlot.SLOT_POCKET
local POCKET2_SLOT = ActiveSlot.SLOT_POCKET2
local CHOICE_COUNT = 3
local POCKET_ITEM_SLOTS = 2
local TRINKET_SLOTS = 2
local CHOICE_SPACING = 80
local GROUP_SPACING = 88
local SEED_STEP = 104729
local STARTING_SEED_SALT = 32452843
local BLESSING_SEED_SALT = 49979687
local RNG_SHIFT_INDEX = 35
local REWIND_TIMEOUT_UPDATES = 10

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
        StartingRewind = nil,
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
end

function EdenChoicesModule:OnNewRoom()
    local rewind = self.StartingRewind

    if not rewind or rewind.phase ~= "rewinding" then
        return
    end

    rewind.phase = "restore"
    Debug("native starting-room rewind restored the item pool")
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

function EdenChoicesModule:CaptureActiveItems(player)
    local activeItems = {}

    for _, slot in ipairs({
        PRIMARY_SLOT,
        SECONDARY_SLOT,
        POCKET_SLOT,
        POCKET2_SLOT,
    }) do
        local collectible = player:GetActiveItem(slot)

        if collectible and collectible > 0 then
            activeItems[#activeItems + 1] = {
                collectible = collectible,
                slot = slot,
                charge = player:GetActiveCharge(slot),
                batteryCharge = player:GetBatteryCharge(slot),
            }
        end
    end

    return activeItems
end

function EdenChoicesModule:CapturePocketItems(player)
    local pocketItems = {}

    for slot = 0, POCKET_ITEM_SLOTS - 1 do
        local card = player:GetCard(slot)
        local pill = player:GetPill(slot)

        if card and card > 0 then
            pocketItems[slot + 1] = { kind = "card", value = card }
        elseif pill and pill > 0 then
            pocketItems[slot + 1] = { kind = "pill", value = pill }
        else
            pocketItems[slot + 1] = { kind = "empty", value = 0 }
        end
    end

    return pocketItems
end

function EdenChoicesModule:CaptureTrinkets(player)
    local trinkets = {}

    for slot = 0, TRINKET_SLOTS - 1 do
        local trinket = player:GetTrinket(slot)

        if trinket and trinket > 0 then
            trinkets[#trinkets + 1] = trinket
        end
    end

    return trinkets
end

function EdenChoicesModule:CaptureRewindSnapshot(player, baseline)
    local collectibles = self:CaptureCollectibles(player)
    local poolRemovals = {}

    for collectible, count in pairs(collectibles) do
        local previousCount = baseline
            and baseline.collectibles[collectible]
            or 0
        local addedCount = math.max(0, count - previousCount)

        if addedCount > 0 then
            poolRemovals[collectible] = addedCount
        end
    end

    return {
        collectibles = collectibles,
        activeItems = self:CaptureActiveItems(player),
        pocketItems = self:CapturePocketItems(player),
        trinkets = self:CaptureTrinkets(player),
        state = self:CapturePlayerState(player),
        poolRemovals = poolRemovals,
    }
end

function EdenChoicesModule:OnPlayerInit(player)
    if not self.Context:IsEnabled(STARTING_CHOICE_KEY)
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

    if player:GetPlayerType() ~= EDEN then
        return
    end

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
    self:ProcessStartingRewind(player)

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

function EdenChoicesModule:GetExistingChoiceGroup(groupIndex)
    local optionsIndex = self:GetOptionsIndex(groupIndex)
    local choices = {}

    for _, entity in ipairs(Isaac.FindByType(
        EntityType.ENTITY_PICKUP,
        COLLECTIBLE_PICKUP,
        -1,
        false,
        false
    )) do
        local pickup = entity:ToPickup()

        if pickup and pickup.OptionsPickupIndex == optionsIndex then
            choices[#choices + 1] = pickup.SubType
        end
    end

    return choices
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

function EdenChoicesModule:RemoveExcessCollectibles(player, wanted)
    local itemConfig = Isaac.GetItemConfig()
    local collectibleList = itemConfig:GetCollectibles()
    local maximum = math.max(0, (collectibleList.Size or 1) - 1)
    local removedAny = false

    for collectible = 1, maximum do
        local current = player:GetCollectibleNum(collectible, true)
        local target = wanted[collectible] or 0

        for _ = target + 1, current do
            player:RemoveCollectible(collectible, true)
            player:TryRemoveCollectibleCostume(collectible, false)
            removedAny = true
        end
    end

    if removedAny then
        player:AddCacheFlags(CacheFlag.CACHE_ALL)
        player:EvaluateItems()
    end
end

function EdenChoicesModule:RestorePocketItems(player, pocketItems)
    for slot = 0, POCKET_ITEM_SLOTS - 1 do
        local item = pocketItems[slot + 1]

        if item and item.kind == "card" then
            player:SetCard(slot, item.value)
        elseif item and item.kind == "pill" then
            player:SetPill(slot, item.value)
        else
            player:SetCard(slot, 0)
        end
    end
end

function EdenChoicesModule:RestoreTrinkets(player, trinkets)
    for slot = TRINKET_SLOTS - 1, 0, -1 do
        local current = player:GetTrinket(slot)

        if current and current > 0 then
            player:TryRemoveTrinket(current)
        end
    end

    for _, trinket in ipairs(trinkets) do
        player:AddTrinket(trinket, false)
    end
end

function EdenChoicesModule:RestoreCollectibles(player, snapshot)
    local itemConfig = Isaac.GetItemConfig()
    local itemPool = Game():GetItemPool()

    self:RemoveExcessCollectibles(player, snapshot.collectibles)

    for collectible in pairs(snapshot.poolRemovals) do
        local removed = itemPool:RemoveCollectible(collectible)
        Debug(string.format(
            "removed restored starting collectible %d from run pools: %s",
            collectible,
            tostring(removed)
        ))
    end

    local activeTargets = {}

    for _, active in ipairs(snapshot.activeItems) do
        activeTargets[active.collectible] =
            (activeTargets[active.collectible] or 0) + 1
    end

    for collectible, target in pairs(snapshot.collectibles) do
        local config = itemConfig:GetCollectible(collectible)
        local current = player:GetCollectibleNum(collectible, true)
        local passiveTarget = target - (activeTargets[collectible] or 0)

        if config and config.Type ~= ACTIVE then
            for _ = current + 1, passiveTarget do
                player:AddCollectible(collectible, 0, true)
            end
        end
    end

    for _, active in ipairs(snapshot.activeItems) do
        if player:GetActiveItem(active.slot) ~= active.collectible then
            player:AddCollectible(
                active.collectible,
                active.charge + active.batteryCharge,
                true,
                active.slot
            )
        end

        player:SetActiveCharge(
            active.charge + active.batteryCharge,
            active.slot
        )
    end
end

function EdenChoicesModule:RestoreRewoundPlayers(rewind)
    for playerIndex, snapshot in pairs(rewind.snapshots) do
        local player = Isaac.GetPlayer(playerIndex)

        self:RestoreCollectibles(player, snapshot)
        self:RestorePocketItems(player, snapshot.pocketItems)
        self:RestoreTrinkets(player, snapshot.trinkets)
        self:RestorePlayerState(player, snapshot.state)
    end
end

function EdenChoicesModule:RemoveRejectedPassivesWithoutRewind(rewind)
    for playerIndex, collectible in pairs(rewind.rejectedPassives) do
        local player = Isaac.GetPlayer(playerIndex)
        local snapshot = rewind.snapshots[playerIndex]

        self:RemoveExcessCollectibles(player, snapshot.collectibles)
        self:RestorePlayerState(player, snapshot.state)
        Debug(string.format(
            "native rewind failed; removed Eden passive %d without pool restore",
            collectible
        ))
    end
end

function EdenChoicesModule:IssueStartingRewind()
    local rewind = self.StartingRewind

    if not rewind or rewind.phase ~= "request" then
        return
    end

    rewind.phase = "rewinding"
    rewind.waitUpdates = 0
    Debug("requesting one native starting-room rewind before room fade-in")

    local succeeded, result = pcall(Isaac.ExecuteCommand, "rewind")

    if not succeeded then
        Debug("native starting-room rewind command failed: " .. tostring(result))
        rewind.phase = "fallback"
    end
end

function EdenChoicesModule:ProcessStartingRewind(player)
    local rewind = self.StartingRewind

    if not rewind
        or self:GetPlayerKey(player)
            ~= self:GetPlayerKey(Isaac.GetPlayer(0))
    then
        return
    end

    if rewind.phase == "request" then
        self:IssueStartingRewind()
    elseif rewind.phase == "rewinding" then
        rewind.waitUpdates = rewind.waitUpdates + 1

        if rewind.waitUpdates >= REWIND_TIMEOUT_UPDATES then
            Debug("native starting-room rewind timed out")
            rewind.phase = "fallback"
        end
    end

    if rewind.phase == "restore" then
        -- AddCollectible and the engine's rewind bookkeeping can re-enter
        -- player-effect callbacks. Retire the in-memory transaction before
        -- restoring anything; the pedestal scan in CompleteChoiceSetup also
        -- protects against the engine rolling Lua state back a second time.
        rewind.phase = "completing"
        self.StartingRewind = nil
        self:RestoreRewoundPlayers(rewind)
        self:CompleteChoiceSetup(rewind.groups, rewind.excluded)
    elseif rewind.phase == "fallback" then
        rewind.phase = "completing"
        self.StartingRewind = nil
        self:RemoveRejectedPassivesWithoutRewind(rewind)
        self:CompleteChoiceSetup(rewind.groups, rewind.excluded)
    end
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

function EdenChoicesModule:CompleteChoiceSetup(groups, excluded)
    local primaryPlayer = Game():GetNumPlayers() > 0 and Isaac.GetPlayer(0)
    local rewardCount = self.PendingRewards
    self.PendingRewards = 0

    if primaryPlayer and rewardCount > 0 then
        if self.Context:IsEnabled(BLESSING_CHOICE_KEY) then
            for rewardIndex = 1, rewardCount do
                groups[#groups + 1] = {
                    playerIndex = 0,
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
        local player = Isaac.GetPlayer(group.playerIndex)
        local existingChoices = self:GetExistingChoiceGroup(groupIndex)

        if #existingChoices > 0 then
            for _, collectible in ipairs(existingChoices) do
                excluded[collectible] = true
            end

            Debug(string.format(
                "kept existing choice group %d after rewind state rollback: %s",
                groupIndex,
                table.concat(existingChoices, ",")
            ))
        else
            local choices = self:DrawChoices(
                player,
                groupIndex,
                group.seedSalt,
                excluded
            )

            if not self:SpawnChoiceGroup(
                player,
                choices,
                groupIndex,
                #groups
            ) and group.kind == "blessing" then
                unspawnedRewards = unspawnedRewards + 1
            end
        end
    end

    self.PendingRewards = self.PendingRewards + unspawnedRewards

    if rewardCount > 0 then
        self.Context:Save()
    end
end

function EdenChoicesModule:OnGameStarted(isContinued)
    self.PendingPickups = {}
    self.RedirectedPickupSeeds = {}
    self.StartingRewind = nil

    if isContinued then
        self.PlayerBaselines = {}
        self.SuppressedPickupCounts = {}
        self.RemovedStartingEntities = {}
        return
    end

    local groups = {}
    local excluded = {}
    local snapshots = {}
    local rejectedPassives = {}
    local hasStartingChoice = false

    for playerIndex = 0, Game():GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(playerIndex)
        local playerKey = self:GetPlayerKey(player)
        local baseline = self.PlayerBaselines[playerKey]
        local snapshot = self:CaptureRewindSnapshot(player, baseline)
        snapshots[playerIndex] = snapshot

        if baseline
            and player:GetPlayerType() == EDEN
            and self.Context:IsEnabled(STARTING_CHOICE_KEY)
        then
            local collectible = self:FindNativeStartingPassive(
                player,
                baseline
            )
            local activeCollectible, activeConfig =
                self:FindNativeStartingActive(player, baseline)

            if collectible then
                snapshot.collectibles[collectible] =
                    math.max(0, (snapshot.collectibles[collectible] or 0) - 1)
                snapshot.poolRemovals[collectible] = nil
                rejectedPassives[playerIndex] = collectible
                excluded[collectible] = true
                hasStartingChoice = true
                groups[#groups + 1] = {
                    playerIndex = playerIndex,
                    seedSalt = STARTING_SEED_SALT
                        + playerIndex * SEED_STEP,
                    kind = "starting",
                }
                snapshot.state = self:GetStateWithActiveGrants(
                    baseline.state,
                    activeConfig
                )
                Debug(string.format(
                    "prepared native rewind for Eden passive %d; "
                        .. "active=%s; redirected pickups=%d; "
                        .. "removed entities=%d",
                    collectible,
                    tostring(activeCollectible),
                    self.SuppressedPickupCounts[playerKey] or 0,
                    self.RemovedStartingEntities[playerKey] or 0
                ))
            else
                Debug("native Eden passive was not found")
            end
        end
    end

    self.PlayerBaselines = {}
    self.SuppressedPickupCounts = {}
    self.RemovedStartingEntities = {}

    if hasStartingChoice then
        self.StartingRewind = {
            phase = "request",
            waitUpdates = 0,
            groups = groups,
            excluded = excluded,
            snapshots = snapshots,
            rejectedPassives = rejectedPassives,
        }
        -- MC_POST_GAME_STARTED runs after vanilla has assigned Eden's items,
        -- but before the starting room finishes fading in. Rewind here instead
        -- of waiting for the first player-effect update so its transition stays
        -- behind the new-run loading screen.
        self:IssueStartingRewind()
        return
    end

    self:CompleteChoiceSetup(groups, excluded)
end

function EdenChoicesModule:GetSaveData()
    return {
        pendingRewards = self.PendingRewards,
    }
end

return EdenChoicesModule
