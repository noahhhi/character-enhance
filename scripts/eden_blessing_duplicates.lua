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
local CHOICE_COUNT = 3
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

function EdenChoicesModule.New(context)
    local self = setmetatable({
        Context = context,
        PendingRewards = 0,
        PendingPickups = {},
        PlayerBaselines = {},
        SuppressedPickupCounts = {},
        RedirectedPickupSeeds = {},
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

    if self.SuppressedPickupCounts[playerKey] == nil then
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

    if collectible then
        player:RemoveCollectible(collectible, true)
        Debug(string.format(
            "removed native Eden passive %d; redirected pickups=%d",
            collectible,
            self.SuppressedPickupCounts[self:GetPlayerKey(player)] or 0
        ))
    else
        Debug("native Eden passive was not found")
    end

    self:RestorePlayerState(player, baseline.state)
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

    if isContinued then
        self.PlayerBaselines = {}
        self.SuppressedPickupCounts = {}
        return
    end

    local groups = {}
    local excluded = {}

    for playerIndex = 0, Game():GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(playerIndex)
        local playerKey = self:GetPlayerKey(player)
        local baseline = self.PlayerBaselines[playerKey]

        if baseline
            and player:GetPlayerType() == EDEN
            and self.Context:IsEnabled(STARTING_CHOICE_KEY)
        then
            self:RemoveNativeStartingPassive(player, baseline)
            groups[#groups + 1] = {
                player = player,
                seedSalt = STARTING_SEED_SALT + playerIndex * SEED_STEP,
                kind = "starting",
            }
        end
    end

    self.PlayerBaselines = {}
    self.SuppressedPickupCounts = {}

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

    if rewardCount > 0 then
        self.Context:Save()
    end
end

function EdenChoicesModule:GetSaveData()
    return { pendingRewards = self.PendingRewards }
end

return EdenChoicesModule
