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
local PRIMARY_SLOT = ActiveSlot.SLOT_PRIMARY
local SECONDARY_SLOT = ActiveSlot.SLOT_SECONDARY
local POCKET_SLOT = ActiveSlot.SLOT_POCKET
local POCKET2_SLOT = ActiveSlot.SLOT_POCKET2
local CHOICE_COUNT = 3
local POCKET_ITEM_SLOTS = 2
local TRINKET_SLOTS = 2
local GOLDEN_TRINKET_FLAG = (TrinketType
    and TrinketType.TRINKET_GOLDEN_FLAG)
    or (1 << 15)
local CHOICE_SPACING = 80
local GROUP_SPACING = 88
local STARTING_PLAYER_OFFSET = 80
local STARTING_FADE_FRAMES = 60
local STARTING_FADE_SPRITE =
    "gfx/character-enhance/ce_black_fade.anm2"
local STARTING_FADE_TEXTURE_WIDTH = 120
local STARTING_FADE_TEXTURE_HEIGHT = 68
local STARTING_PLACEMENT_UPDATES = 10
local STARTING_FADE_HOLD_TIMEOUT = 120
local MAX_SAVED_STARTING_CHOICES = 32
local SEED_STEP = 104729
local STARTING_SEED_SALT = 32452843
local BLESSING_SEED_SALT = 49979687
local RNG_SHIFT_INDEX = 35
local REWIND_TIMEOUT_UPDATES = 10
local CHOICE_POOL_DATA_KEY = "CharacterEnhanceEdenChoicePool"
local CHOICE_KIND_DATA_KEY = "CharacterEnhanceEdenChoiceKind"
local GREED_POOL_FIRST = ItemPoolType.POOL_GREED_TREASURE or 16
local GREED_POOL_LAST = ItemPoolType.POOL_GREED_SECRET or 22

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
        StartingFade = nil,
        StartingFadeSprite = nil,
        StartingPlacement = nil,
        ActiveRunSeed = Game():GetSeeds():GetStartSeed(),
        ChoiceRunSeed = nil,
        ChoiceMetadataBySeed = {},
        ChoiceMetadataDirty = false,
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
        ModCallbacks.MC_POST_RENDER,
        function()
            self:OnPostRender()
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

local function IsFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function HasPoolMembership(collectible, poolType)
    if not IsFiniteNumber(collectible)
        or not IsFiniteNumber(poolType)
    then
        return false
    end

    for _, candidatePool in ipairs(
        VANILLA_POOLS_BY_ITEM[math.floor(collectible)] or {}
    ) do
        if candidatePool == math.floor(poolType) then
            return true
        end
    end

    return false
end

function EdenChoicesModule:SanitizeChoiceMetadata(savedData)
    local savedChoices = type(savedData) == "table"
        and savedData.startingChoicePedestals

    if type(savedChoices) ~= "table"
        or not IsFiniteNumber(savedChoices.runSeed)
        or type(savedChoices.entries) ~= "table"
    then
        return nil, {}
    end

    local runSeed = math.floor(savedChoices.runSeed)

    if runSeed < 0 or runSeed > 4294967295 then
        return nil, {}
    end

    local bySeed = {}

    for index = 1, math.min(
        #savedChoices.entries,
        MAX_SAVED_STARTING_CHOICES
    ) do
        local entry = savedChoices.entries[index]

        if type(entry) == "table"
            and IsFiniteNumber(entry.initSeed)
            and IsFiniteNumber(entry.collectible)
            and IsFiniteNumber(entry.poolType)
            and IsFiniteNumber(entry.optionsIndex)
        then
            local initSeed = math.floor(entry.initSeed)
            local collectible = math.floor(entry.collectible)
            local poolType = math.floor(entry.poolType)
            local optionsIndex = math.floor(entry.optionsIndex)

            if initSeed >= 0
                and initSeed <= 4294967295
                and collectible > 0
                and optionsIndex > 0
                and HasPoolMembership(collectible, poolType)
            then
                bySeed[tostring(initSeed)] = {
                    initSeed = initSeed,
                    collectible = collectible,
                    poolType = poolType,
                    optionsIndex = optionsIndex,
                }
            end
        end
    end

    if not next(bySeed) then
        return nil, {}
    end

    return runSeed, bySeed
end

function EdenChoicesModule:OnSaveDataLoaded(savedData)
    self.PendingRewards = self:SanitizePendingRewards(savedData)
    self.ChoiceRunSeed, self.ChoiceMetadataBySeed =
        self:SanitizeChoiceMetadata(savedData)
    self.ChoiceMetadataDirty = false
end

function EdenChoicesModule:ClearChoiceMetadata()
    if self.ChoiceRunSeed or next(self.ChoiceMetadataBySeed) then
        self.ChoiceMetadataDirty = true
    end

    self.ChoiceRunSeed = nil
    self.ChoiceMetadataBySeed = {}
end

function EdenChoicesModule:RecordChoiceMetadata(
    pickup,
    collectible,
    poolType,
    optionsIndex
)
    if not pickup or type(pickup.InitSeed) ~= "number" then
        return
    end

    local initSeed = math.floor(pickup.InitSeed)
    self.ChoiceRunSeed = Game():GetSeeds():GetStartSeed()
    self.ChoiceMetadataBySeed[tostring(initSeed)] = {
        initSeed = initSeed,
        collectible = collectible,
        poolType = poolType,
        optionsIndex = optionsIndex,
    }
    self.ChoiceMetadataDirty = true
end

function EdenChoicesModule:GetChoiceMetadata(pickup)
    if not pickup
        or type(pickup.InitSeed) ~= "number"
        or self.ChoiceRunSeed ~= Game():GetSeeds():GetStartSeed()
    then
        return nil
    end

    local metadata = self.ChoiceMetadataBySeed[
        tostring(math.floor(pickup.InitSeed))
    ]

    if not metadata
        or metadata.collectible ~= pickup.SubType
        or metadata.optionsIndex ~= pickup.OptionsPickupIndex
    then
        return nil
    end

    return metadata
end


function EdenChoicesModule:AttachChoiceMetadata(pickup)
    local metadata = self:GetChoiceMetadata(pickup)

    if not metadata or type(pickup.GetData) ~= "function" then
        return false
    end

    local data = pickup:GetData()
    data[CHOICE_POOL_DATA_KEY] = metadata.poolType
    data[CHOICE_KIND_DATA_KEY] = "starting"
    return true
end

function EdenChoicesModule:AttachAllChoiceMetadata()
    for _, entity in ipairs(Isaac.FindByType(
        EntityType.ENTITY_PICKUP,
        COLLECTIBLE_PICKUP,
        -1,
        false,
        false
    )) do
        self:AttachChoiceMetadata(entity:ToPickup())
    end
end

function EdenChoicesModule:RemoveChoiceGroupMetadata(optionsIndex)
    local removed = false

    for seed, metadata in pairs(self.ChoiceMetadataBySeed) do
        if metadata.optionsIndex == optionsIndex then
            self.ChoiceMetadataBySeed[seed] = nil
            removed = true
        end
    end

    if removed then
        if not next(self.ChoiceMetadataBySeed) then
            self.ChoiceRunSeed = nil
        end

        self.ChoiceMetadataDirty = true
    end
end

function EdenChoicesModule:SaveChoiceMetadataIfDirty()
    if not self.ChoiceMetadataDirty then
        return false
    end

    self.ChoiceMetadataDirty = false
    self.Context:Save()
    return true
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

function EdenChoicesModule:GetAddedTrinkets(currentTrinkets, baselineTrinkets)
    local baselineCounts = {}
    local addedTrinkets = {}

    for _, trinket in ipairs(baselineTrinkets or {}) do
        baselineCounts[trinket] = (baselineCounts[trinket] or 0) + 1
    end

    for _, trinket in ipairs(currentTrinkets or {}) do
        local baselineCount = baselineCounts[trinket] or 0

        if baselineCount > 0 then
            baselineCounts[trinket] = baselineCount - 1
        else
            addedTrinkets[#addedTrinkets + 1] = trinket
        end
    end

    return addedTrinkets
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
        trinketPoolRemovals = {},
        state = self:CapturePlayerState(player),
        poolRemovals = poolRemovals,
    }
end

function EdenChoicesModule:OnPlayerInit(player)
    local game = Game()
    local runSeed = game:GetSeeds():GetStartSeed()

    if not self.Context:IsEnabled(STARTING_CHOICE_KEY)
        or (game:GetFrameCount() ~= 0 and runSeed == self.ActiveRunSeed)
    then
        return
    end

    local playerKey = self:GetPlayerKey(player)
    self.PlayerBaselines[playerKey] = {
        player = player,
        collectibles = self:CaptureCollectibles(player),
        trinkets = self:CaptureTrinkets(player),
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

    if redirected then
        self.RedirectedPickupSeeds[pickup.InitSeed] = nil
        pickup:Remove()
        Debug(string.format(
            "removed redirected native passive pickup from 5.%d.%d",
            redirected.originalVariant,
            redirected.originalSubtype
        ))
        return
    end

    self:AttachChoiceMetadata(pickup)
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

function EdenChoicesModule:DropReplacedPrimaryActive(player, position)
    local collectible = player:GetActiveItem(PRIMARY_SLOT)

    if not collectible or collectible <= 0 then
        return
    end

    local charge = player:GetActiveCharge(PRIMARY_SLOT)
        + player:GetBatteryCharge(PRIMARY_SLOT)
    player:RemoveCollectible(collectible, true, PRIMARY_SLOT, false)

    local dropped = Isaac.Spawn(
        EntityType.ENTITY_PICKUP,
        COLLECTIBLE_PICKUP,
        collectible,
        Game():GetRoom():FindFreePickupSpawnPosition(position, 0, true),
        Vector.Zero,
        player
    ):ToPickup()

    if dropped then
        dropped.Charge = charge
        dropped.Touched = true
        dropped.Wait = 30
        dropped.ShopItemId = -1
    end
end

function EdenChoicesModule:CollectStartingChoice(pickup, player, poolType)
    local config = Isaac.GetItemConfig():GetCollectible(pickup.SubType)

    if not config then
        return nil
    end

    if type(player.CanPickupItem) == "function" and not player:CanPickupItem() then
        return nil
    end

    if type(pickup.Wait) == "number" and pickup.Wait > 0 then
        return nil
    end

    local activeSlot = PRIMARY_SLOT

    if config.Type == ACTIVE then
        self:DropReplacedPrimaryActive(player, pickup.Position)
    end

    local charge = type(pickup.Charge) == "number"
        and math.max(0, pickup.Charge)
        or GetConfigGrant(config, "InitCharge")
    local varData = type(pickup.VarData) == "number" and pickup.VarData or 0

    player:AddCollectible(
        pickup.SubType,
        charge,
        pickup.Touched ~= true,
        activeSlot,
        varData,
        poolType
    )

    if type(player.AnimateCollectible) == "function" then
        player:AnimateCollectible(pickup.SubType)
    end

    local game = Game()
    local hud = type(game.GetHUD) == "function" and game:GetHUD()

    if hud and type(hud.ShowItemText) == "function" then
        hud:ShowItemText(player, config)
    end

    if type(SFXManager) == "function"
        and SoundEffect
        and SoundEffect.SOUND_POWERUP1
    then
        SFXManager():Play(SoundEffect.SOUND_POWERUP1)
    end

    local optionsIndex = pickup.OptionsPickupIndex or 0
    self:RemoveChoiceGroupMetadata(optionsIndex)

    for _, entity in ipairs(Isaac.FindByType(
        EntityType.ENTITY_PICKUP,
        COLLECTIBLE_PICKUP,
        -1,
        false,
        false
    )) do
        local option = entity:ToPickup()

        if option
            and ((type(pickup.InitSeed) == "number"
                    and option.InitSeed == pickup.InitSeed)
                or (optionsIndex ~= 0
                    and option.OptionsPickupIndex == optionsIndex))
        then
            option:Remove()
        end
    end

    if type(pickup.Exists) ~= "function" or pickup:Exists() then
        pickup:Remove()
    end

    Debug(string.format(
        "collected starting choice %d with native source pool %d",
        pickup.SubType,
        poolType
    ))
    self:SaveChoiceMetadataIfDirty()
    return true
end

function EdenChoicesModule:OnPrePickupCollision(pickup, collider)
    local player = collider and collider:ToPlayer()
    local data = pickup
        and type(pickup.GetData) == "function"
        and pickup:GetData()
    local metadata = self:GetChoiceMetadata(pickup)
    local choicePool = data
        and data[CHOICE_KIND_DATA_KEY] == "starting"
        and data[CHOICE_POOL_DATA_KEY]

    if type(choicePool) ~= "number" and metadata then
        choicePool = metadata.poolType
        self:AttachChoiceMetadata(pickup)
    end

    if player
        and pickup
        and pickup.Variant == COLLECTIBLE_PICKUP
        and type(choicePool) == "number"
    then
        return self:CollectStartingChoice(
            pickup,
            player,
            choicePool
        )
    end

    if not pickup
        or pickup.Variant ~= COLLECTIBLE_PICKUP
        or pickup.SubType ~= EDENS_BLESSING
        or not collider
        or not self.Context:IsEnabled(BLESSING_CHOICE_KEY)
    then
        return
    end

    player = collider:ToPlayer()

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
    if self:GetPlayerKey(player)
        == self:GetPlayerKey(Isaac.GetPlayer(0))
    then
        self:ApplyStartingPlacement()
    end

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

function EdenChoicesModule:GetCollectiblePools(collectible)
    local pools = VANILLA_POOLS_BY_ITEM[collectible] or {}
    local normalPools = {}
    local greedPools = {}

    for _, poolType in ipairs(pools) do
        if poolType >= GREED_POOL_FIRST and poolType <= GREED_POOL_LAST then
            greedPools[#greedPools + 1] = poolType
        else
            normalPools[#normalPools + 1] = poolType
        end
    end

    local game = Game()
    local isGreedMode = type(game.IsGreedMode) == "function"
        and game:IsGreedMode()

    if isGreedMode and #greedPools > 0 then
        return greedPools
    end

    if #normalPools > 0 then
        return normalPools
    end

    return greedPools
end

function EdenChoicesModule:GetChoicePool(
    collectible,
    groupIndex,
    choiceIndex,
    seedSalt
)
    local pools = self:GetCollectiblePools(collectible)

    if #pools == 0 then
        return nil
    end

    local startSeed = Game():GetSeeds():GetStartSeed()
    local poolSeed = NormalizeSeed(
        startSeed
            + (seedSalt or 0)
            + groupIndex * SEED_STEP
            + choiceIndex * 16127
            + collectible * 31337
    )
    return pools[(poolSeed % #pools) + 1]
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
        or #self:GetCollectiblePools(collectible) == 0
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
    groupCount,
    seedSalt,
    kind
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
        local poolType = self:GetChoicePool(
            collectible,
            groupIndex,
            choiceIndex,
            seedSalt
        )
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
            pickup.ShopItemId = -1

            if type(pickup.GetData) == "function" then
                local data = pickup:GetData()
                data[CHOICE_POOL_DATA_KEY] = poolType
                data[CHOICE_KIND_DATA_KEY] = kind
            end

            if kind == "starting" then
                self:RecordChoiceMetadata(
                    pickup,
                    collectible,
                    poolType,
                    optionsIndex
                )
            end

            local removed = itemPool:RemoveCollectible(collectible)
            Debug(string.format(
                "removed spawned choice %d (source pool %s) "
                    .. "from run item pools: %s",
                collectible,
                tostring(poolType),
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

function EdenChoicesModule:RestoreTrinkets(
    player,
    trinkets,
    poolRemovals
)
    for slot = TRINKET_SLOTS - 1, 0, -1 do
        local current = player:GetTrinket(slot)

        if current and current > 0 then
            player:TryRemoveTrinket(current)
        end
    end

    local itemPool = Game():GetItemPool()

    for _, trinket in ipairs(poolRemovals or {}) do
        local poolTrinket = trinket & ~GOLDEN_TRINKET_FLAG
        local removed = poolTrinket > 0
            and itemPool:RemoveTrinket(poolTrinket)
            or false
        Debug(string.format(
            "removed restored starting trinket %d from run pool: %s",
            poolTrinket,
            tostring(removed)
        ))
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
        self:RestoreTrinkets(
            player,
            snapshot.trinkets,
            snapshot.trinketPoolRemovals
        )
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
    Debug("requesting one native starting-room rewind during black transition")

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

    if rewind.phase == "rewinding" then
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
        self:CompleteChoiceSetup(rewind.groups, rewind.excluded, true)
    elseif rewind.phase == "fallback" then
        rewind.phase = "completing"
        self.StartingRewind = nil
        self:RemoveRejectedPassivesWithoutRewind(rewind)
        self:CompleteChoiceSetup(rewind.groups, rewind.excluded, false)
    end
end

function EdenChoicesModule:OnPostRender()
    local rewind = self.StartingRewind

    if rewind and rewind.phase == "request" then
        -- Rewind from the first still-black render. The command clears the
        -- engine's pending room fade, so this render callback restores the same
        -- black-to-room transition after setup is complete. Repentance+ calls
        -- this callback twice per visible fade step, so sixty callback passes
        -- match the ordinary transition captured from an unmodified start.
        self:IssueStartingRewind()
    end

    self:RenderStartingFade()
end

function EdenChoicesModule:GetStartingFadeSprite()
    if self.StartingFadeSprite then
        return self.StartingFadeSprite
    end

    local sprite = Sprite()
    sprite:Load(STARTING_FADE_SPRITE, true)
    sprite:Play("Idle", true)
    self.StartingFadeSprite = sprite
    return sprite
end

function EdenChoicesModule:BeginStartingFade(waitForPlacement)
    if self.StartingFade then
        return
    end

    self.StartingFade = {
        remaining = STARTING_FADE_FRAMES,
        total = STARTING_FADE_FRAMES,
        waitingForPlacement = waitForPlacement == true,
        holdRemaining = STARTING_FADE_HOLD_TIMEOUT,
    }
    Debug(waitForPlacement
        and "holding the starting room black until Eden placement is stable"
        or "armed standard-timing starting-room fade-in")
end

function EdenChoicesModule:RenderStartingFade()
    local fade = self.StartingFade

    if not fade then
        return
    end

    local width = Isaac.GetScreenWidth()
    local height = Isaac.GetScreenHeight()
    local sprite = self:GetStartingFadeSprite()
    sprite.Scale = Vector(
        width / STARTING_FADE_TEXTURE_WIDTH,
        height / STARTING_FADE_TEXTURE_HEIGHT
    )
    local alpha = fade.waitingForPlacement
        and 1
        or fade.remaining / fade.total
    sprite.Color = Color(
        1,
        1,
        1,
        alpha,
        0,
        0,
        0
    )
    sprite:Render(Vector(width / 2, height / 2))

    if fade.waitingForPlacement then
        fade.holdRemaining = fade.holdRemaining - 1

        if fade.holdRemaining <= 0 then
            fade.waitingForPlacement = false
            Debug("starting placement hold timed out; releasing fade")
        end

        return
    end

    fade.remaining = fade.remaining - 1

    if fade.remaining <= 0 then
        self.StartingFade = nil
    end
end

function EdenChoicesModule:ApplyStartingPlacement()
    local placement = self.StartingPlacement

    if not placement or not placement.remainingUpdates then
        return
    end

    local room = Game():GetRoom()

    for playerIndex, target in pairs(placement.targets) do
        local player = Isaac.GetPlayer(playerIndex)
        player.Position = room:FindFreePickupSpawnPosition(
            Vector(target.x, target.y),
            0,
            true
        )
        player.Velocity = Vector.Zero
    end

    placement.remainingUpdates = placement.remainingUpdates - 1

    if placement.remainingUpdates <= 0 then
        self.StartingPlacement = nil
        if self.StartingFade then
            self.StartingFade.waitingForPlacement = false
        end
        Debug("finished restoring Eden placement after internal continuation")
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

function EdenChoicesModule:CompleteChoiceSetup(
    groups,
    excluded,
    waitForContinuation
)
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
    local positionedStartingPlayers = {}

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
            if group.kind == "starting" then
                positionedStartingPlayers[group.playerIndex] = true
            end
        else
            local choices = self:DrawChoices(
                player,
                groupIndex,
                group.seedSalt,
                excluded
            )

            local spawned = self:SpawnChoiceGroup(
                player,
                choices,
                groupIndex,
                #groups,
                group.seedSalt,
                group.kind
            )

            if spawned and group.kind == "starting" then
                positionedStartingPlayers[group.playerIndex] = true
            elseif not spawned and group.kind == "blessing" then
                unspawnedRewards = unspawnedRewards + 1
            end
        end
    end

    local room = Game():GetRoom()
    local center = room:GetCenterPos()
    local bottomRowOffset = math.max(0, (#groups - 1) / 2)
        * GROUP_SPACING
    local target = center + Vector(
        0,
        bottomRowOffset + STARTING_PLAYER_OFFSET
    )
    local placementTargets = {}

    for playerIndex in pairs(positionedStartingPlayers) do
        local player = Isaac.GetPlayer(playerIndex)
        player.Position = room:FindFreePickupSpawnPosition(target, 0, true)
        player.Velocity = Vector.Zero
        placementTargets[playerIndex] = {
            x = player.Position.X,
            y = player.Position.Y,
        }
        Debug(string.format(
            "positioned Eden player %d below starting choices at %.1f,%.1f",
            playerIndex,
            player.Position.X,
            player.Position.Y
        ))
    end

    if next(positionedStartingPlayers) then
        self.StartingPlacement = {
            targets = placementTargets,
            remainingUpdates = waitForContinuation
                and nil
                or STARTING_PLACEMENT_UPDATES,
        }
        self:BeginStartingFade(waitForContinuation)
    end

    self.PendingRewards = self.PendingRewards + unspawnedRewards

    if rewardCount > 0 and not self.ChoiceMetadataDirty then
        self.Context:Save()
    else
        self:SaveChoiceMetadataIfDirty()
    end
end

function EdenChoicesModule:OnGameStarted(isContinued)
    self.ActiveRunSeed = Game():GetSeeds():GetStartSeed()
    self.PendingPickups = {}
    self.RedirectedPickupSeeds = {}
    self.StartingRewind = nil

    if not isContinued then
        self.StartingFade = nil
        self.StartingPlacement = nil
        self:ClearChoiceMetadata()
    end

    if isContinued then
        self:AttachAllChoiceMetadata()

        if self.StartingPlacement then
            self.StartingPlacement.remainingUpdates =
                STARTING_PLACEMENT_UPDATES
            Debug("scheduled Eden placement after internal continuation")
        end

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
                snapshot.trinketPoolRemovals = self:GetAddedTrinkets(
                    snapshot.trinkets,
                    baseline.trinkets
                )
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
        -- Wait until the first black render so the rewind never appears over
        -- the room. Once restoration finishes, a standard-timing fade replaces
        -- the engine fade that the command necessarily clears.
        return
    end

    self:CompleteChoiceSetup(groups, excluded)
end

function EdenChoicesModule:GetSaveData()
    local entries = {}

    for _, metadata in pairs(self.ChoiceMetadataBySeed) do
        entries[#entries + 1] = {
            initSeed = metadata.initSeed,
            collectible = metadata.collectible,
            poolType = metadata.poolType,
            optionsIndex = metadata.optionsIndex,
        }
    end

    table.sort(entries, function(left, right)
        return left.initSeed < right.initSeed
    end)

    local saveData = {
        pendingRewards = self.PendingRewards,
    }

    if self.ChoiceRunSeed and #entries > 0 then
        saveData.startingChoicePedestals = {
            runSeed = self.ChoiceRunSeed,
            entries = entries,
        }
    end

    return saveData
end

return EdenChoicesModule
