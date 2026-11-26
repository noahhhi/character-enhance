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
local CHOICE_COUNT = 3
local CHOICE_SPACING = 80
local GROUP_SPACING = 88
local STARTING_PLAYER_OFFSET = 80
local CONSUMABLE_GRANTS = {
    { "GetNumCoins", "AddCoins" },
    { "GetNumBombs", "AddBombs" },
    { "GetNumKeys", "AddKeys" },
}
local MAX_SAVED_STARTING_CHOICES = 32
local SEED_STEP = 104729
local STARTING_SEED_SALT = 32452843
local BLESSING_SEED_SALT = 49979687
local RNG_SHIFT_INDEX = 35
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

local function RemoveConfiguredGrant(player, getter, adder, retained, amount, ...)
    local removable = math.min(
        amount,
        math.max(0, player[getter](player) - retained)
    )

    if removable > 0 then
        player[adder](player, -removable, ...)
    end
end

local function RestoreSharedStartingHearts(player, getter, adder, retained, amount, ...)
    local current = player[getter](player)
    local target = math.max(retained, current - amount)

    if target ~= current then
        player[adder](player, target - current, ...)
    end
end

local function IsSecretEntrance(door)
    return door.TargetRoomType == RoomType.ROOM_SECRET
        or door.TargetRoomType == RoomType.ROOM_SUPERSECRET
end

function EdenChoicesModule.New(context)
    local self = setmetatable({
        Context = context,
        PendingRewards = 0,
        PendingPickups = {},
        PlayerBaselines = {},
        RedirectedPickupSeeds = {},
        StartingRoomEntered = false,
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
    local evaluateCacheCallback = function(_, player)
        self:OnEvaluateCache(player)
    end
    local closeStartingWindow = function()
        self.StartingRoomEntered = false
    end

    -- Intercept starting pickups before their subtype pools are queried.
    -- Close the spawner-less grant window before other cache callbacks run.
    if type(context.Mod.AddPriorityCallback) == "function" then
        context.Mod:AddPriorityCallback(
            ModCallbacks.MC_PRE_ENTITY_SPAWN,
            CallbackPriority.IMPORTANT,
            preSpawnCallback,
            EntityType.ENTITY_PICKUP
        )
        context.Mod:AddPriorityCallback(
            ModCallbacks.MC_EVALUATE_CACHE,
            CallbackPriority.IMPORTANT,
            evaluateCacheCallback
        )
        context.Mod:AddPriorityCallback(
            ModCallbacks.MC_POST_GAME_STARTED,
            CallbackPriority.IMPORTANT,
            closeStartingWindow
        )
    else
        context.Mod:AddCallback(
            ModCallbacks.MC_PRE_ENTITY_SPAWN,
            preSpawnCallback,
            EntityType.ENTITY_PICKUP
        )
        context.Mod:AddCallback(
            ModCallbacks.MC_EVALUATE_CACHE,
            evaluateCacheCallback
        )
        context.Mod:AddCallback(
            ModCallbacks.MC_POST_GAME_STARTED,
            closeStartingWindow
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
    -- Restored room entities initialize before POST_NEW_ROOM. The native
    -- starting grants happen after it, before POST_GAME_STARTED.
    self.StartingRoomEntered = next(self.PlayerBaselines) ~= nil
    self.StartingRoomDoors = nil

    if not self.StartingRoomEntered then
        return
    end

    local game = Game()

    if game:GetNumPlayers() ~= 1 then
        return
    end

    local level = game:GetLevel()

    if level:GetCurrentRoomIndex() ~= level:GetStartingRoomIndex() then
        return
    end

    local room = game:GetRoom()
    local entrances = {}

    for slot = 0, DoorSlot.NUM_DOOR_SLOTS - 1 do
        local door = room:GetDoor(slot)

        if door and IsSecretEntrance(door) and not door:IsOpen()
            and not door.Busted
            and door:GetSaveState().Variant == DoorVariant.DOOR_HIDDEN
        then
            local target = level:GetRoomByIdx(door.TargetRoomIndex)
            local sprite = door:GetSprite()
            entrances[slot] = {
                targetIndex = door.TargetRoomIndex,
                targetType = door.TargetRoomType,
                state = door.State,
                varData = door.VarData,
                animation = sprite:GetAnimation(),
                frame = sprite:GetFrame(),
                x = door.Position.X,
                y = door.Position.Y,
                displayFlags = target.DisplayFlags,
                visitedCount = target.VisitedCount,
            }
        end
    end

    if next(entrances) then
        self.StartingRoomDoors = {
            roomSeed = room:GetSpawnSeed(),
            entrances = entrances,
        }
    end
end

function EdenChoicesModule:RestoreStartingRoomDoors(snapshot)
    local game = Game()
    local room = game:GetRoom()

    if not snapshot or room:GetSpawnSeed() ~= snapshot.roomSeed then
        return
    end

    local level = game:GetLevel()
    local restoreVisibility = false

    for slot, before in pairs(snapshot.entrances) do
        local door = room:GetDoor(slot)

        if door and door.TargetRoomIndex == before.targetIndex
            and door.TargetRoomType == before.targetType
        then
            local grid = door:GetSaveState()
            local opened = door:IsOpen() or door.Busted
            local target = level:GetRoomByIdx(before.targetIndex)

            -- A grant can change the grid variant before the door update
            -- opens it. Restore that pending reveal as well as an open door.
            if target.VisitedCount == before.visitedCount
                and (opened or grid.Variant ~= DoorVariant.DOOR_HIDDEN
                    or before.revealEffects)
            then
                if before.revealEffects then
                    for _, effect in ipairs(before.revealEffects) do
                        if effect:Exists() then
                            effect:Remove()
                        end
                    end
                end

                if opened then
                    door:Close(true)
                    door.Busted = false
                    door.State = before.state
                    door.CollisionClass = GridCollisionClass.COLLISION_WALL
                    door:GetSprite():SetFrame(before.animation, before.frame)
                end

                grid.Variant = DoorVariant.DOOR_HIDDEN
                door.VarData = before.varData

                if target.DisplayFlags ~= before.displayFlags then
                    target.DisplayFlags = before.displayFlags
                    restoreVisibility = true
                end

                Debug(string.format("restored starting secret entrance in slot %d", slot))
            end
        end
    end

    if restoreVisibility then
        level:UpdateVisibility()
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

function EdenChoicesModule:CaptureStartingHealth(player)
    return {
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

function EdenChoicesModule:CaptureRetainedStartingGrants(player)
    local consumables = {}

    for _, grant in ipairs(CONSUMABLE_GRANTS) do
        local getter, adder = grant[1], grant[2]
        consumables[adder] = player[getter](player)
    end

    return {
        primaryActive = player:GetActiveItem(PRIMARY_SLOT),
        trinket = player:GetTrinket(0),
        secondTrinket = player:GetTrinket(1),
        consumables = consumables,
        health = self:CaptureStartingHealth(player),
    }
end

function EdenChoicesModule:OnPlayerInit(player)
    local game = Game()
    local runSeed = game:GetSeeds():GetStartSeed()

    if player:GetPlayerType() ~= EDEN
        or not self.Context:IsEnabled(STARTING_CHOICE_KEY)
        or (game:GetFrameCount() ~= 0 and runSeed == self.ActiveRunSeed)
    then
        return
    end

    self.PlayerBaselines[self:GetPlayerKey(player)] = {
        collectibleCount = player:GetCollectibleCount(),
        collectibles = self:CaptureCollectibles(player),
        retained = self:CaptureRetainedStartingGrants(player),
    }
end

local function TrinketsChanged(player, retained)
    return retained.trinket ~= player:GetTrinket(0)
        or retained.secondTrinket ~= player:GetTrinket(1)
end

function EdenChoicesModule:OnEvaluateCache(player)
    if not self.StartingRoomEntered then
        return
    end

    local baseline = self.PlayerBaselines[self:GetPlayerKey(player)]

    if not baseline or baseline.pickupGrantFinished then
        return
    end

    if self:FindNativeStartingPassive(player, baseline) then
        -- The first cache evaluation with the passive marks the end of its
        -- immediate pickup grant. Later cache-spawned familiars use ownership.
        baseline.pickupGrantFinished = true
    elseif baseline.retained.primaryActive ~= player:GetActiveItem(PRIMARY_SLOT)
        or TrinketsChanged(player, baseline.retained)
    then
        baseline.retained = self:CaptureRetainedStartingGrants(player)
    end
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
        or not self.StartingRoomEntered
        or type(seed) ~= "number"
    then
        return nil
    end

    -- Native grants can spawn pickups without a spawner. Attribute those
    -- only when Eden is alone in the already-generated starting room.
    local player = spawner and spawner:ToPlayer()

    if not spawner and Game():GetNumPlayers() == 1 then
        player = Isaac.GetPlayer(0)
    end

    local baseline = player and self.PlayerBaselines[self:GetPlayerKey(player)]

    if not baseline
        or (not spawner and baseline.pickupGrantFinished)
        or not self:FindNativeStartingPassive(player, baseline)
    then
        return nil
    end

    self.RedirectedPickupSeeds[seed] = {
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

        if pickup.Variant == COIN_PICKUP and pickup.SubType == PENNY then
            pickup:Remove()
            Debug(string.format(
                "removed redirected native passive pickup from 5.%d.%d",
                redirected.originalVariant,
                redirected.originalSubtype
            ))
            return
        end
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

    if not self.StartingRoomEntered or not owner then
        return
    end

    local baseline = self.PlayerBaselines[self:GetPlayerKey(owner)]

    if not baseline or not self:FindNativeStartingPassive(owner, baseline) then
        return
    end

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
    local snapshot = self.StartingRoomDoors

    if snapshot and self.StartingRoomEntered
        and effect.Variant == EffectVariant.XRAY_WALL
    then
        -- The room's reveal animation can open the door later, after the
        -- original collectible and its initial grid changes are gone.
        local position = effect.Position

        for _, entrance in pairs(snapshot.entrances) do
            if position.X == entrance.x and position.Y == entrance.y then
                entrance.revealEffects = entrance.revealEffects or {}
                table.insert(entrance.revealEffects, effect)
                break
            end
        end
    end

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

function EdenChoicesModule:FindNativeStartingPassive(player, baseline)
    if baseline.passive then
        return baseline.passive
    end

    if player:GetCollectibleCount() <= baseline.collectibleCount then
        return nil
    end

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
            baseline.passive = collectible
            return collectible
        end
    end

    return nil
end

function EdenChoicesModule:RestoreStartingHealth(
    player,
    retained,
    activeConfig,
    passiveConfig
)
    local health = retained.health
    local maxHearts = health.maxHearts
        + GetConfigGrant(activeConfig, "AddMaxHearts")
    local hearts = math.min(
        maxHearts,
        health.hearts + GetConfigGrant(activeConfig, "AddHearts")
    )
    local soulHearts = health.soulHearts
        + GetConfigGrant(activeConfig, "AddSoulHearts")
    local blackHearts = GetConfigGrant(activeConfig, "AddBlackHearts")
    local unobservedTrinket = TrinketsChanged(player, retained)

    -- These counters have their own baseline. Native starting trinket pickup
    -- effects for regular Eden do not grant these heart types. The engine can
    -- give or convert them on collectible pickup without any config fields.
    AddDifference(player, "GetGoldenHearts", "AddGoldenHearts", health.goldenHearts)
    AddDifference(player, "GetEternalHearts", "AddEternalHearts", health.eternalHearts)
    AddDifference(player, "GetRottenHearts", "AddRottenHearts", health.rottenHearts)
    AddDifference(player, "GetBoneHearts", "AddBoneHearts", health.boneHearts)
    AddDifference(player, "GetBrokenHearts", "AddBrokenHearts", health.brokenHearts)

    if unobservedTrinket then
        -- There was no cache checkpoint after the retained trinket arrived
        -- and before the passive. Restore known hearts lost to conversions
        -- and preserve gains beyond the passive's configured grants.
        RestoreSharedStartingHearts(
            player, "GetMaxHearts", "AddMaxHearts", maxHearts,
            GetConfigGrant(passiveConfig, "AddMaxHearts"), false
        )
        RestoreSharedStartingHearts(
            player, "GetHearts", "AddHearts", hearts,
            GetConfigGrant(passiveConfig, "AddHearts")
        )
        RestoreSharedStartingHearts(
            player, "GetSoulHearts", "AddSoulHearts", soulHearts + blackHearts,
            GetConfigGrant(passiveConfig, "AddSoulHearts")
                + GetConfigGrant(passiveConfig, "AddBlackHearts")
        )
        return
    end

    AddDifference(player, "GetMaxHearts", "AddMaxHearts", maxHearts, false)
    AddDifference(player, "GetHearts", "AddHearts", hearts)

    -- Vanilla Eden's initial heart roll contains no Black Hearts.
    if blackHearts == 0 then
        AddDifference(player, "GetSoulHearts", "AddSoulHearts", soulHearts)
        if player:GetBlackHearts() == 0 then
            return
        end
    end

    player:AddSoulHearts(-player:GetSoulHearts())
    if soulHearts > 0 then
        player:AddSoulHearts(soulHearts)
    end
    if blackHearts > 0 then
        player:AddBlackHearts(blackHearts)
    end
end

function EdenChoicesModule:RemoveStartingPassive(player, collectible, baseline)
    local itemConfig = Isaac.GetItemConfig()
    local passiveConfig = itemConfig:GetCollectible(collectible)
    local retained = baseline.retained
    local active = player:GetActiveItem(PRIMARY_SLOT)
    local activeConfig = active > 0 and active ~= retained.primaryActive
        and itemConfig:GetCollectible(active) or nil

    -- Keep retained starting items and consumable grants in place. Reverse
    -- the rejected passive's configured grants against the observed totals.
    for _, grant in ipairs(CONSUMABLE_GRANTS) do
        local getter, adder = grant[1], grant[2]
        local beforePassive = math.min(
            99,
            retained.consumables[adder] + GetConfigGrant(activeConfig, adder)
        )
        RemoveConfiguredGrant(
            player, getter, adder, beforePassive,
            math.min(GetConfigGrant(passiveConfig, adder), 99 - beforePassive)
        )
    end

    player:RemoveCollectible(collectible, true)
    player:TryRemoveCollectibleCostume(collectible, false)
    self:RestoreStartingHealth(player, retained, activeConfig, passiveConfig)
    player:AddCacheFlags(CacheFlag.CACHE_ALL)
    player:EvaluateItems()
    Debug(string.format("removed native starting passive %d in place", collectible))
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
    local positionedStartingPlayers = {}

    for groupIndex, group in ipairs(groups) do
        local player = Isaac.GetPlayer(group.playerIndex)
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

    if next(positionedStartingPlayers) then
        local room = Game():GetRoom()
        local bottomRowOffset = (#groups - 1) / 2 * GROUP_SPACING
        local target = room:GetCenterPos()
            + Vector(0, bottomRowOffset + STARTING_PLAYER_OFFSET)

        for playerIndex in pairs(positionedStartingPlayers) do
            local player = Isaac.GetPlayer(playerIndex)
            player.Position = room:FindFreePickupSpawnPosition(target, 0, true)
            player.Velocity = Vector.Zero
            Debug(string.format(
                "positioned Eden player %d below starting choices at %.1f,%.1f",
                playerIndex,
                player.Position.X,
                player.Position.Y
            ))
        end
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
    local baselines = self.PlayerBaselines
    local startingRoomDoors = self.StartingRoomDoors
    self.PlayerBaselines = {}
    self.StartingRoomEntered = false
    self.StartingRoomDoors = nil

    if isContinued then
        self:AttachAllChoiceMetadata()
        return
    end

    self:ClearChoiceMetadata()
    local groups = {}
    local excluded = {}

    if self.Context:IsEnabled(STARTING_CHOICE_KEY) then
        for playerIndex = 0, Game():GetNumPlayers() - 1 do
            local player = Isaac.GetPlayer(playerIndex)
            local baseline = baselines[self:GetPlayerKey(player)]
            local collectible = baseline
                and self:FindNativeStartingPassive(player, baseline)

            if collectible then
                self:RemoveStartingPassive(player, collectible, baseline)
                excluded[collectible] = true
                groups[#groups + 1] = {
                    playerIndex = playerIndex,
                    seedSalt = STARTING_SEED_SALT + playerIndex * SEED_STEP,
                    kind = "starting",
                }
            end
        end
    end

    if #groups > 0 and startingRoomDoors and Game():GetNumPlayers() == 1 then
        self:RestoreStartingRoomDoors(startingRoomDoors)
    end

    -- Finish before the native fade without creating a room rewind or
    -- spending the first-room Glowing Hour Glass transition to Home.
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
