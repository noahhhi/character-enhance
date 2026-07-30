local RerollHealthModule = {}
RerollHealthModule.__index = RerollHealthModule

local REROLL_SETTING_KEY = "rerollHealthProtection"
local ABSORBED_STATS_SETTING_KEY = "rerollAbsorbedStats"
local ESAU_JR_SETTING_KEY = "esauJrFirstPickup"
local TMTRAINER_SETTING_KEY = "rerollTmtrainerChance"
local TAINTED_EDEN = PlayerType.PLAYER_EDEN_B
local DICE_FLOOR = EffectVariant.DICE_FLOOR
local ENTITY_EFFECT = EntityType.ENTITY_EFFECT
local DICE_TRIGGER_DISTANCE_SQUARED = 40 * 40
local DIRECT_REROLL_ITEMS = {
    [CollectibleType.COLLECTIBLE_D4] = true,
    [CollectibleType.COLLECTIBLE_D100] = true,
}
local VOID = CollectibleType.COLLECTIBLE_VOID
local BLANK_CARD = CollectibleType.COLLECTIBLE_BLANK_CARD
local CLEAR_RUNE = CollectibleType.COLLECTIBLE_CLEAR_RUNE
local BLACK_RUNE = Card.CARD_BLACK_RUNE
local ESAU_JR = CollectibleType.COLLECTIBLE_ESAU_JR
local MISSING_NO = CollectibleType.COLLECTIBLE_MISSING_NO
local TMTRAINER = CollectibleType.COLLECTIBLE_TMTRAINER
local NULL_COLLECTIBLE = CollectibleType.COLLECTIBLE_NULL
local BREAKFAST = CollectibleType.COLLECTIBLE_BREAKFAST
local SECRET_POOL = ItemPoolType.POOL_SECRET
local REVERSE_WHEEL_OF_FORTUNE = Card.CARD_REVERSE_WHEEL_OF_FORTUNE
local PASSIVE = ItemType.ITEM_PASSIVE
local FAMILIAR = ItemType.ITEM_FAMILIAR
local ACTIVE = ItemType.ITEM_ACTIVE
local ENTITY_PICKUP = EntityType.ENTITY_PICKUP
local COLLECTIBLE_PICKUP = PickupVariant.PICKUP_COLLECTIBLE

local STAT_DEFINITIONS = {
    damage = {
        flag = CacheFlag.CACHE_DAMAGE,
        read = function(player)
            return player.Damage
        end,
        apply = function(player, amount)
            player.Damage = player.Damage + amount
        end,
    },
    tears = {
        flag = CacheFlag.CACHE_FIREDELAY,
        read = function(player)
            return 30 / (player.MaxFireDelay + 1)
        end,
        apply = function(player, amount)
            local tears = 30 / (player.MaxFireDelay + 1) + amount
            player.MaxFireDelay = 30 / tears - 1
        end,
    },
    shotSpeed = {
        flag = CacheFlag.CACHE_SHOTSPEED,
        read = function(player)
            return player.ShotSpeed
        end,
        apply = function(player, amount)
            player.ShotSpeed = player.ShotSpeed + amount
        end,
    },
    range = {
        flag = CacheFlag.CACHE_RANGE,
        read = function(player)
            return player.TearRange
        end,
        apply = function(player, amount)
            player.TearRange = player.TearRange + amount
        end,
    },
    speed = {
        flag = CacheFlag.CACHE_SPEED,
        read = function(player)
            return player.MoveSpeed
        end,
        apply = function(player, amount)
            player.MoveSpeed = player.MoveSpeed + amount
        end,
    },
    luck = {
        flag = CacheFlag.CACHE_LUCK,
        read = function(player)
            return player.Luck
        end,
        apply = function(player, amount)
            player.Luck = player.Luck + amount
        end,
    },
}

local EMPTY_STATS = {
    damage = 0,
    tears = 0,
    shotSpeed = 0,
    range = 0,
    speed = 0,
    luck = 0,
}

function RerollHealthModule.New(context)
    local self = setmetatable({
        Context = context,
        SavedData = context.GetSavedModuleData
            and context:GetSavedModuleData(REROLL_SETTING_KEY)
            or {},
        PreservedData = {},
        Players = {},
        PendingSyncPlayers = {},
        MaxCollectibleId = 733,
        RunActive = false,
        PendingEsauJr = {},
        KnownEsauJrBodies = {},
        TmtrainerPreparedDecisions = {},
        TmtrainerRoomPoolGuard = false,
        PoolGuardCallbackRegistered = false,
        PoolOverrideInProgress = false,
        DiceRoomFace = nil,
        DiceRoomFloor = nil,
        DiceRoomTriggered = false,
        UpdateCallbackRegistered = false,
        DiceUpdateCallbackRegistered = false,
    }, RerollHealthModule)

    self.UpdateCallback = function()
        self:OnUpdate()
    end
    self.DiceUpdateCallback = function(_, player)
        self:OnPlayerEffectUpdate(player)
    end
    self.PoolGuardCallback = function(
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

    self.EvaluateCacheCallback = function(_, player, cacheFlag)
        self:OnEvaluateCache(player, cacheFlag)
    end

    -- Register before the Bethany module. A restored Soul Heart must already be
    -- present when Bethany's charge tracker runs, otherwise restoration could
    -- be mistaken for a newly collected heart.
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_GAME_STARTED,
        function(_, isContinued)
            self:OnGameStarted(isContinued)
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_PLAYER_INIT,
        function(_, player)
            self:OnPlayerInit(player)
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_PRE_USE_ITEM,
        function(_, collectibleType, _, player)
            self:OnPreUseItem(collectibleType, player)
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_EVALUATE_CACHE,
        self.EvaluateCacheCallback
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_ENTITY_TAKE_DMG,
        function(_, entity, amount, flags, source)
            self:OnEntityTakeDamage(entity, amount, flags, source)
        end,
        EntityType.ENTITY_PLAYER
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
    context.Mod:AddCallback(
        ModCallbacks.MC_USE_CARD,
        function(_, card, player)
            self:OnUseCard(card, player)
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_INPUT_ACTION,
        function(_, entity, inputHook, buttonAction)
            self:OnInputAction(entity, inputHook, buttonAction)
        end,
        EntityType.ENTITY_PLAYER
    )

    self.PreservedData = self:SanitizeSavedData(self.SavedData)

    return self
end

function RerollHealthModule:SetUpdateCallbackEnabled(enabled)
    if enabled and not self.UpdateCallbackRegistered then
        self.Context.Mod:AddCallback(
            ModCallbacks.MC_POST_UPDATE,
            self.UpdateCallback
        )
        self.UpdateCallbackRegistered = true
    elseif not enabled and self.UpdateCallbackRegistered then
        self.Context.Mod:RemoveCallback(
            ModCallbacks.MC_POST_UPDATE,
            self.UpdateCallback
        )
        self.UpdateCallbackRegistered = false
    end
end

function RerollHealthModule:SetDiceUpdateCallbackEnabled(enabled)
    if enabled and not self.DiceUpdateCallbackRegistered then
        self.Context.Mod:AddCallback(
            ModCallbacks.MC_POST_PEFFECT_UPDATE,
            self.DiceUpdateCallback
        )
        self.DiceUpdateCallbackRegistered = true
    elseif not enabled and self.DiceUpdateCallbackRegistered then
        self.Context.Mod:RemoveCallback(
            ModCallbacks.MC_POST_PEFFECT_UPDATE,
            self.DiceUpdateCallback
        )
        self.DiceUpdateCallbackRegistered = false
    end
end

function RerollHealthModule:RefreshUpdateCallback()
    self:SetUpdateCallbackEnabled(
        self.RunActive
        and (#self.PendingEsauJr > 0
            or next(self.PendingSyncPlayers) ~= nil
            or self:HasPendingAbsorption())
    )
end

function RerollHealthModule:SetPoolGuardCallbackEnabled(enabled)
    if enabled and not self.PoolGuardCallbackRegistered then
        self.Context.Mod:AddCallback(
            ModCallbacks.MC_POST_GET_COLLECTIBLE,
            self.PoolGuardCallback
        )
        self.PoolGuardCallbackRegistered = true
    elseif not enabled and self.PoolGuardCallbackRegistered then
        self.Context.Mod:RemoveCallback(
            ModCallbacks.MC_POST_GET_COLLECTIBLE,
            self.PoolGuardCallback
        )
        self.PoolGuardCallbackRegistered = false
    end
end

function RerollHealthModule:HasPendingPoolGuard()
    for _, state in pairs(self.Players) do
        if state.pending and state.pending.tmtrainerAllowed == false then
            return true
        end
    end

    return false
end

function RerollHealthModule:RefreshPoolGuardCallback()
    self:SetPoolGuardCallbackEnabled(
        self.RunActive
        and (self.TmtrainerRoomPoolGuard or self:HasPendingPoolGuard())
    )
end

function RerollHealthModule:GetPlayerKey(player)
    return tostring(GetPtrHash(player))
end

function RerollHealthModule:CopyStats(source)
    local result = {}

    for statName in pairs(EMPTY_STATS) do
        result[statName] = tonumber(source and source[statName]) or 0
    end

    return result
end

function RerollHealthModule:SanitizeStats(source)
    local result = self:CopyStats()

    if type(source) ~= "table" then
        return result
    end

    for statName in pairs(EMPTY_STATS) do
        local value = source[statName]

        if type(value) == "number" and value == value
            and value ~= math.huge and value ~= -math.huge
            and value >= 0 and value <= 100000
        then
            result[statName] = value
        end
    end

    return result
end

function RerollHealthModule:SanitizeSavedData(savedData)
    local result = { players = {} }

    if type(savedData) ~= "table" then
        return result
    end

    if type(savedData.runSeed) == "number"
        and savedData.runSeed == savedData.runSeed
        and savedData.runSeed ~= math.huge
        and savedData.runSeed ~= -math.huge
    then
        result.runSeed = math.floor(savedData.runSeed)
    end

    if type(savedData.absorbedStats) ~= "table" then
        return result
    end

    for playerKey, savedPlayer in pairs(savedData.absorbedStats) do
        local playerIndex = tonumber(playerKey)

        if playerIndex and playerIndex == math.floor(playerIndex)
            and playerIndex >= 0 and playerIndex <= 15
            and type(savedPlayer) == "table"
        then
            result.players[tostring(playerIndex)] = {
                preserved = self:SanitizeStats(savedPlayer.preserved),
                native = self:SanitizeStats(savedPlayer.native),
            }
        end
    end

    return result
end

function RerollHealthModule:GetRunSeed()
    local game = Game()
    local seeds = game.GetSeeds and game:GetSeeds()

    return seeds and seeds:GetStartSeed() or 0
end

function RerollHealthModule:GetPlayerIndex(player)
    if not player then
        return nil
    end

    local playerHash = GetPtrHash(player)
    local game = Game()

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        if GetPtrHash(Isaac.GetPlayer(playerIndex)) == playerHash then
            return playerIndex
        end
    end

    return nil
end

function RerollHealthModule:CaptureStats(player)
    local result = {}

    for statName, definition in pairs(STAT_DEFINITIONS) do
        result[statName] = definition.read(player)
    end

    return result
end

function RerollHealthModule:HasStats(stats)
    for statName in pairs(EMPTY_STATS) do
        if (stats and stats[statName] or 0) > 0.000001 then
            return true
        end
    end

    return false
end

function RerollHealthModule:GetAllStatCacheFlags()
    local flags = 0

    for _, definition in pairs(STAT_DEFINITIONS) do
        flags = flags | definition.flag
    end

    return flags
end

function RerollHealthModule:EvaluatePreservedStats(player)
    if not player then
        return
    end

    player:AddCacheFlags(self:GetAllStatCacheFlags())
    player:EvaluateItems()
end

function RerollHealthModule:OnEvaluateCache(player, cacheFlag)
    if not self.RunActive
        or not self.Context:IsEnabled(ABSORBED_STATS_SETTING_KEY)
    then
        return
    end

    local state = self.Players[self:GetPlayerKey(player)]

    if not state then
        return
    end

    for statName, definition in pairs(STAT_DEFINITIONS) do
        local amount = state.preservedStats[statName] or 0

        if definition.flag == cacheFlag and amount > 0 then
            definition.apply(player, amount)
            return
        end
    end
end

function RerollHealthModule:HasPendingAbsorption()
    for _, state in pairs(self.Players) do
        if state.absorption then
            return true
        end
    end

    return false
end

function RerollHealthModule:RefreshMaxCollectibleId()
    local itemConfig = Isaac.GetItemConfig and Isaac.GetItemConfig()

    if itemConfig and itemConfig.GetCollectibles then
        local collectibles = itemConfig:GetCollectibles()

        if collectibles and type(collectibles.Size) == "number" then
            self.MaxCollectibleId = math.max(1, collectibles.Size - 1)
        end
    end
end

function RerollHealthModule:GetTmtrainerCount(player)
    return player:GetCollectibleNum(TMTRAINER, true)
end


function RerollHealthModule:CaptureHealth(player)
    return {
        maxHearts = player:GetMaxHearts(),
        hearts = player:GetHearts(),
        soulHearts = player:GetSoulHearts(),
        blackHearts = player:GetBlackHearts(),
        boneHearts = player:GetBoneHearts(),
        rottenHearts = player:GetRottenHearts(),
        brokenHearts = player:GetBrokenHearts(),
        eternalHearts = player:GetEternalHearts(),
        goldenHearts = player:GetGoldenHearts(),
    }
end

function RerollHealthModule:AppendSoulLayout(player, target, startUnit)
    local unit = startUnit or 0

    while unit < target.soulHearts do
        local heartIndex = math.floor(unit / 2)
        local amount = math.min(2 - (unit % 2), target.soulHearts - unit)

        if target.blackHearts & (1 << heartIndex) ~= 0 then
            player:AddBlackHearts(amount)
        else
            player:AddSoulHearts(amount)
        end

        unit = unit + amount
    end
end

function RerollHealthModule:RestoreSoulLayout(player, target)
    if player:GetSoulHearts() == target.soulHearts
        and player:GetBlackHearts() == target.blackHearts
    then
        return
    end

    local temporaryRedHeart = target.soulHearts > 0
        and target.hearts == 0
        and target.maxHearts > 0
        and target.boneHearts == 0
    local temporaryBoneHeart = target.soulHearts > 0
        and target.maxHearts == 0
        and target.boneHearts == 0

    -- Keep soul-only characters alive while rebuilding the Soul/Black layout.
    -- The temporary health is removed before returning.
    if temporaryRedHeart then
        player:AddHearts(1)
    elseif temporaryBoneHeart then
        player:AddBoneHearts(1)
    end

    player:AddSoulHearts(-player:GetSoulHearts())
    self:AppendSoulLayout(player, target, 0)

    if temporaryBoneHeart then
        player:AddBoneHearts(-1)

        -- At a full 12-heart display, the temporary Bone Heart may have
        -- limited the first pass to 11 Soul/Black Hearts.
        if player:GetSoulHearts() < target.soulHearts then
            self:AppendSoulLayout(player, target, player:GetSoulHearts())
        end
    end

    if temporaryRedHeart and player:GetHearts() > target.hearts then
        player:AddHearts(target.hearts - player:GetHearts())
    end
end

function RerollHealthModule:ApplyDamageToSnapshot(health, amount)
    -- Player health APIs and damageAmount both count half-heart units: damage
    -- amount 1 removes one half-heart, while 2 removes one full heart.
    local remaining = math.max(1, math.floor(amount + 0.5))
    local target = {}

    for key, value in pairs(health) do
        target[key] = value
    end

    local soulDamage = math.min(target.soulHearts, remaining)
    target.soulHearts = target.soulHearts - soulDamage
    local soulHeartCount = math.ceil(target.soulHearts / 2)
    target.blackHearts = target.blackHearts & ((1 << soulHeartCount) - 1)
    remaining = remaining - soulDamage

    local redDamage = math.min(target.hearts, remaining)
    target.hearts = target.hearts - redDamage
    target.rottenHearts = math.min(target.rottenHearts, target.hearts)
    remaining = remaining - redDamage

    -- An empty Bone Heart is destroyed by the next hit. Bone Hearts are whole
    -- containers, while damage amount and the other heart APIs use half-hearts.
    if remaining > 0 and target.boneHearts > 0 then
        target.boneHearts = target.boneHearts - 1
    end

    return target
end

function RerollHealthModule:RestoreHealth(player, target)
    -- Raise structural limits before filling health so a reroll that removed
    -- containers cannot leave the player dead or clamp restored health.
    if player:GetMaxHearts() < target.maxHearts then
        player:AddMaxHearts(target.maxHearts - player:GetMaxHearts(), false)
    end

    if player:GetBoneHearts() < target.boneHearts then
        player:AddBoneHearts(target.boneHearts - player:GetBoneHearts())
    end

    if player:GetBrokenHearts() ~= target.brokenHearts then
        player:AddBrokenHearts(target.brokenHearts - player:GetBrokenHearts())
    end

    if player:GetBoneHearts() > target.boneHearts then
        player:AddBoneHearts(target.boneHearts - player:GetBoneHearts())
    end

    if player:GetMaxHearts() > target.maxHearts then
        player:AddMaxHearts(target.maxHearts - player:GetMaxHearts(), false)
    end

    -- Rotten Hearts are part of GetHearts(), so restore their subtype first and
    -- then correct the total red-heart fill.
    if player:GetRottenHearts() ~= target.rottenHearts then
        player:AddRottenHearts(target.rottenHearts - player:GetRottenHearts())
    end

    if player:GetHearts() ~= target.hearts then
        player:AddHearts(target.hearts - player:GetHearts())
    end

    self:RestoreSoulLayout(player, target)

    if player:GetEternalHearts() ~= target.eternalHearts then
        player:AddEternalHearts(target.eternalHearts - player:GetEternalHearts())
    end

    if player:GetGoldenHearts() ~= target.goldenHearts then
        player:AddGoldenHearts(target.goldenHearts - player:GetGoldenHearts())
    end
end

function RerollHealthModule:GetAbsorptionCandidates(source)
    local candidates = {}
    local itemConfig = Isaac.GetItemConfig()
    local pickups = Isaac.FindByType(
        ENTITY_PICKUP,
        COLLECTIBLE_PICKUP,
        -1,
        false,
        false
    )

    for _, entity in ipairs(pickups) do
        local pickup = entity:ToPickup()
        local collectible = pickup
            and itemConfig:GetCollectible(pickup.SubType)
        local eligible = collectible ~= nil

        if source == "void" then
            eligible = eligible and collectible.Type ~= ACTIVE
        end

        if eligible then
            candidates[#candidates + 1] = {
                pickup = pickup,
                optionsIndex = pickup.OptionsPickupIndex or 0,
            }
        end
    end

    return candidates
end

function RerollHealthModule:QueueAbsorption(player, source)
    if not self.RunActive or not player then
        return
    end

    local key = self:GetPlayerKey(player)
    local state = self.Players[key]

    if not state then
        self:TrackPlayer(player)
        state = self.Players[key]
    end

    local candidates = self:GetAbsorptionCandidates(source)

    if #candidates == 0 then
        return
    end

    -- Nested Blank Card/Clear Rune callbacks may prepare the same Black Rune
    -- use more than once. The earliest baseline is the only pre-effect state.
    if not state.absorption then
        state.absorption = {
            source = source,
            before = self:CaptureStats(player),
            candidates = candidates,
            cancelled = false,
        }
    end

    self:RefreshUpdateCallback()
end

function RerollHealthModule:GetConsumedCandidateCount(absorption)
    local count = 0
    local optionGroups = {}

    for _, candidate in ipairs(absorption.candidates) do
        local pickup = candidate.pickup

        if pickup and not pickup:Exists() then
            local optionsIndex = candidate.optionsIndex

            if optionsIndex and optionsIndex ~= 0 then
                if not optionGroups[optionsIndex] then
                    optionGroups[optionsIndex] = true
                    count = count + 1
                end
            else
                count = count + 1
            end
        end
    end

    return count
end

function RerollHealthModule:FinalizeAbsorption(player, state)
    local absorption = state.absorption
    state.absorption = nil

    if not absorption or absorption.cancelled then
        return false
    end

    local consumedCount = self:GetConsumedCandidateCount(absorption)

    if consumedCount <= 0 then
        return false
    end

    local after = self:CaptureStats(player)
    local gains = self:CopyStats()
    local changedStats = 0

    for statName in pairs(EMPTY_STATS) do
        local gain = after[statName] - absorption.before[statName]

        if gain > 0.000001 then
            gains[statName] = gain
            changedStats = changedStats + 1
        end
    end

    -- Each consumed pedestal can raise two stats. More changed stat families
    -- means a stored active effect altered the same frame, so the standard API
    -- cannot distinguish that temporary change from the permanent absorption.
    if changedStats > consumedCount * 2 then
        if Isaac.DebugString then
            Isaac.DebugString(
                "[Character Enhance] skipped ambiguous Void stat capture"
            )
        end
        return false
    end

    if not self:HasStats(gains) then
        return false
    end

    for statName in pairs(EMPTY_STATS) do
        state.nativeAbsorbedStats[statName] =
            (state.nativeAbsorbedStats[statName] or 0) + gains[statName]
    end

    return true
end

function RerollHealthModule:PromoteAbsorbedStats(state, snapshot)
    if not snapshot or not self:HasStats(snapshot) then
        return false
    end

    for statName in pairs(EMPTY_STATS) do
        local promoted = snapshot[statName] or 0
        state.preservedStats[statName] =
            (state.preservedStats[statName] or 0) + promoted
        state.nativeAbsorbedStats[statName] = math.max(
            0,
            (state.nativeAbsorbedStats[statName] or 0) - promoted
        )
    end

    return true
end

function RerollHealthModule:DiscardNativeAbsorbedStats(state, snapshot)
    if not snapshot or not self:HasStats(snapshot) then
        return false
    end

    for statName in pairs(EMPTY_STATS) do
        state.nativeAbsorbedStats[statName] = math.max(
            0,
            (state.nativeAbsorbedStats[statName] or 0)
                - (snapshot[statName] or 0)
        )
    end

    return true
end

function RerollHealthModule:TrackPlayer(player, playerIndex, savedStats)
    if not player then
        return
    end

    self.Players[self:GetPlayerKey(player)] = {
        player = player,
        pending = nil,
        absorption = nil,
        playerIndex = playerIndex,
        preservedStats = self:SanitizeStats(
            savedStats and savedStats.preserved
        ),
        nativeAbsorbedStats = self:SanitizeStats(
            savedStats and savedStats.native
        ),
    }
end

function RerollHealthModule:OnPlayerInit(player)
    self:TrackPlayer(player, self:GetPlayerIndex(player))

    -- A normal co-op join or rewind reconstruction is already an established
    -- body. During Esau Jr. creation the pre-use callback has queued a scan,
    -- so leave that new body unmarked until its first-pickup replay completes.
    if player and #self.PendingEsauJr == 0 then
        self.KnownEsauJrBodies[self:GetPlayerKey(player)] = true
    end
end

function RerollHealthModule:QueueRestore(
    player,
    damageAmount,
    preparedTmtrainerDecision
)
    local tmtrainerChance = self.Context.Settings[TMTRAINER_SETTING_KEY] or 0

    if not player or (not self.Context:IsEnabled(REROLL_SETTING_KEY)
        and not self.Context:IsEnabled(ABSORBED_STATS_SETTING_KEY)
        and tmtrainerChance >= 100)
    then
        return
    end

    local key = self:GetPlayerKey(player)
    local state = self.Players[key]

    if not state then
        self:TrackPlayer(player)
        state = self.Players[key]
    end

    if state.absorption then
        -- Void can dispatch an absorbed D4/D100 before consuming the current
        -- pedestal. That inventory reroll makes a before/after stat delta
        -- ambiguous, so preserve prior tracked gains without recording this use.
        state.absorption.cancelled = true
    end

    -- D100 and D Infinity can invoke the D4 callback internally. Keep the
    -- earliest snapshot so nested effects cannot replace the true baseline.
    if not state.pending then
        local tmtrainerCount = nil
        local tmtrainerAllowed = preparedTmtrainerDecision

        if tmtrainerChance < 100 then
            tmtrainerCount = self:GetTmtrainerCount(player)

            if tmtrainerAllowed == nil then
                tmtrainerAllowed = self:PrepareTmtrainerReroll(
                    player,
                    tmtrainerCount
                )
            end
        end

        state.pending = {
            health = self:CaptureHealth(player),
            absorbedStats = self:CopyStats(state.nativeAbsorbedStats),
            tmtrainerCount = tmtrainerCount,
            damageAmount = damageAmount,
            tmtrainerAllowed = tmtrainerAllowed,
        }
    elseif damageAmount then
        state.pending.damageAmount = damageAmount
    end

    self.PendingSyncPlayers[key] = player
    self:RefreshUpdateCallback()
    self:RefreshPoolGuardCallback()
end

function RerollHealthModule:GetInventoryDiceFloor()
    if Game():GetRoom():GetType() ~= RoomType.ROOM_DICE then
        return nil, nil
    end

    local floors = Isaac.FindByType(
        ENTITY_EFFECT,
        DICE_FLOOR,
        -1,
        false,
        false
    )

    for _, floor in ipairs(floors) do
        if floor.SubType == 1 or floor.SubType == 6 then
            return floor.SubType, floor
        end
    end

    return nil, nil
end

function RerollHealthModule:IsDiceRoomAlreadyTriggered()
    local level = Game():GetLevel()
    local descriptor = level and level:GetCurrentRoomDesc()

    return descriptor and descriptor.PressurePlatesTriggered == true
end

function RerollHealthModule:IsPlayerOnDiceFloor(player)
    local floor = self.DiceRoomFloor

    if not player or not floor or not player.Position or not floor.Position then
        return false
    end

    local x = player.Position.X - floor.Position.X
    local y = player.Position.Y - floor.Position.Y

    return x * x + y * y <= DICE_TRIGGER_DISTANCE_SQUARED
end


function RerollHealthModule:PrepareDiceRoomDecision()
    local game = Game()
    local eventPlayer = nil
    local ownedBeforeReroll = false

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(playerIndex)
        eventPlayer = eventPlayer or player

        if player:GetCollectibleNum(TMTRAINER, true) > 0 then
            ownedBeforeReroll = true
        end
    end

    local allowed = ownedBeforeReroll or self:GetTmtrainerChance() >= 100

    if not allowed and eventPlayer then
        allowed = self:RollTmtrainerAllowed(eventPlayer)
    end

    self.TmtrainerRoomPoolGuard = allowed == false

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(playerIndex)
        self.TmtrainerPreparedDecisions[self:GetPlayerKey(player)] = allowed
    end

    self:RefreshPoolGuardCallback()
end

function RerollHealthModule:OnPlayerEffectUpdate(player)
    if not self.RunActive
        or self.DiceRoomTriggered
        or not self.DiceRoomFace
        or not self:IsPlayerOnDiceFloor(player)
    then
        return
    end

    self.DiceRoomTriggered = true
    self:SetDiceUpdateCallbackEnabled(false)

    if self.DiceRoomFace == 1 then
        local key = self:GetPlayerKey(player)
        self:QueueRestore(
            player,
            nil,
            self.TmtrainerPreparedDecisions[key]
        )
        return
    end

    -- A six-pip Dice Room applies the D100-style inventory reroll to every
    -- player. Snapshot everybody before the floor effect executes.
    local game = Game()

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        local affectedPlayer = Isaac.GetPlayer(playerIndex)
        local key = self:GetPlayerKey(affectedPlayer)
        self:QueueRestore(
            affectedPlayer,
            nil,
            self.TmtrainerPreparedDecisions[key]
        )
    end
end

function RerollHealthModule:GetTmtrainerChance()
    local chance = self.Context.Settings[TMTRAINER_SETTING_KEY]

    if type(chance) ~= "number" or chance ~= chance then
        return 0
    end

    return math.max(0, math.min(100, math.floor(chance + 0.5)))
end

function RerollHealthModule:RollTmtrainerAllowed(player)
    local chance = self:GetTmtrainerChance()

    if chance <= 0 then
        return false
    end
    if chance >= 100 then
        return true
    end

    return player:GetCollectibleRNG(TMTRAINER):RandomInt(100) < chance
end

function RerollHealthModule:PrepareTmtrainerReroll(
    player,
    tmtrainerCount
)
    if (tmtrainerCount or 0) > 0
        or self:GetTmtrainerChance() >= 100
    then
        return true
    end

    return self:RollTmtrainerAllowed(player)
end

function RerollHealthModule:OnNewLevel()
    if not self.RunActive then
        return
    end

    local game = Game()

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(playerIndex)

        if player:GetCollectibleNum(MISSING_NO, true) > 0 then
            self:QueueRestore(player, nil)
        end
    end
end

function RerollHealthModule:OnNewRoom()
    self:SetDiceUpdateCallbackEnabled(false)
    self.TmtrainerRoomPoolGuard = false
    self.TmtrainerPreparedDecisions = {}
    self.DiceRoomFace = nil
    self.DiceRoomFloor = nil
    self.DiceRoomTriggered = false

    if not self.RunActive or self:IsDiceRoomAlreadyTriggered() then
        self:RefreshPoolGuardCallback()
        return
    end

    self.DiceRoomFace, self.DiceRoomFloor = self:GetInventoryDiceFloor()

    if self.DiceRoomFace then
        -- The room blacklist is global, so one roll decision is shared by the
        -- single Dice Room event. If any co-op player already owns TMTRAINER,
        -- preserve vanilla behavior instead of restricting that player's roll.
        self:PrepareDiceRoomDecision()
        self:SetDiceUpdateCallbackEnabled(true)
    else
        self:RefreshPoolGuardCallback()
    end
end

function RerollHealthModule:OnUseCard(card, player)
    if card == BLACK_RUNE then
        -- Direct uses are prepared by MC_INPUT_ACTION; Blank Card and Clear
        -- Rune are prepared by their nested pre-use callback. MC_USE_CARD is
        -- retained as the common completion point without replacing vanilla.
        return
    elseif card == REVERSE_WHEEL_OF_FORTUNE then
        self:QueueRestore(player, nil)
    end
end

function RerollHealthModule:OnInputAction(entity, inputHook, buttonAction)
    if not self.RunActive
        or inputHook ~= InputHook.IS_ACTION_TRIGGERED
        or buttonAction ~= ButtonAction.ACTION_PILLCARD
    then
        return
    end

    local player = entity and entity:ToPlayer()

    if not player then
        return
    end

    local card = player:GetCard(0)

    if card == BLACK_RUNE then
        self:QueueAbsorption(player, "blackRune")
    elseif card == REVERSE_WHEEL_OF_FORTUNE then
        self:QueueRestore(player, nil)
    end
end

function RerollHealthModule:GetPoolReplacement(poolType, seed)
    local itemPool = Game():GetItemPool()
    local itemConfig = Isaac.GetItemConfig and Isaac.GetItemConfig()
    local baseSeed = math.abs(tonumber(seed) or 1) % 2147483647

    for attempt = 1, 20 do
        local replacementSeed = (
            baseSeed + attempt * 1103515245
        ) % 2147483647

        if replacementSeed == 0 then
            replacementSeed = attempt
        end

        local collectibleType = itemPool:GetCollectible(
            poolType,
            false,
            replacementSeed,
            NULL_COLLECTIBLE
        )
        local collectibleConfig = itemConfig
            and itemConfig:GetCollectible(collectibleType)
        local itemType = collectibleConfig and collectibleConfig.Type

        -- TMTRAINER is a passive result in the inventory-reroll stream. Its
        -- replacement must remain passive/familiar as well: returning an
        -- active item can collide with another active result later in the
        -- same roll, making one collectible disappear from the player.
        if collectibleType ~= TMTRAINER
            and collectibleType > 0
            and (itemType == PASSIVE or itemType == FAMILIAR)
        then
            return collectibleType
        end
    end

    return BREAKFAST
end

function RerollHealthModule:GetSecretRoomReplacement(player)
    return self:GetPoolReplacement(
        SECRET_POOL,
        player:GetCollectibleRNG(TMTRAINER):Next()
    )
end

function RerollHealthModule:OnPostGetCollectible(
    selectedCollectible,
    poolType,
    _,
    seed
)
    if self.PoolOverrideInProgress
        or selectedCollectible ~= TMTRAINER
        or not self.PoolGuardCallbackRegistered
    then
        return nil
    end

    -- Full-inventory rerolls can ignore ItemPool:AddRoomBlacklist. Override
    -- TMTRAINER at the actual pool-result callback so it never enters the
    -- player inventory and therefore cannot generate extra negative-ID items.
    self.PoolOverrideInProgress = true
    local replacement = self:GetPoolReplacement(poolType, seed)
    self.PoolOverrideInProgress = false

    return replacement
end

function RerollHealthModule:ReplaceUnexpectedTmtrainer(
    player,
    previousTmtrainerCount,
    currentTmtrainerCount,
    fullInventoryReroll,
    preRollAllowed
)
    if not fullInventoryReroll
        or (previousTmtrainerCount or 0) > 0
        or self:GetTmtrainerChance() >= 100
    then
        return false
    end


    local tmtrainerAllowed = preRollAllowed

    if tmtrainerAllowed == nil then
        tmtrainerAllowed = self:RollTmtrainerAllowed(player)
    end

    if tmtrainerAllowed then
        return false
    end

    local unexpectedCount = currentTmtrainerCount or 0

    if unexpectedCount <= 0 then
        return false
    end

    local replaced = false

    for _ = 1, unexpectedCount do
        player:RemoveCollectible(
            TMTRAINER,
            true,
            ActiveSlot.SLOT_PRIMARY,
            true
        )
        player:AddCollectible(
            self:GetSecretRoomReplacement(player),
            0,
            true,
            ActiveSlot.SLOT_PRIMARY,
            0,
            SECRET_POOL
        )
        replaced = true
    end

    return replaced
end

function RerollHealthModule:OnPreUseItem(collectibleType, player)
    if DIRECT_REROLL_ITEMS[collectibleType] then
        -- D Infinity's D4/D100 faces, Void and Metronome dispatch the selected
        -- vanilla active effect through this callback too. Handling the inner
        -- D4/D100 callback covers those paths without affecting D Infinity's
        -- pedestal-only or stat-only faces.
        self:QueueRestore(player, nil)
    elseif collectibleType == VOID then
        self:QueueAbsorption(player, "void")
    elseif collectibleType == BLANK_CARD or collectibleType == CLEAR_RUNE then
        if player and player:GetCard(0) == BLACK_RUNE then
            self:QueueAbsorption(player, "blackRune")
        end
    elseif collectibleType == ESAU_JR then
        self:QueueEsauJrScan(player)
    end
end

function RerollHealthModule:QueueEsauJrScan(player)
    if not player or not self.Context:IsEnabled(ESAU_JR_SETTING_KEY) then
        return
    end

    local knownPlayers = {}
    local game = Game()

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        knownPlayers[tostring(GetPtrHash(Isaac.GetPlayer(playerIndex)))] = true
    end

    self.PendingEsauJr[#self.PendingEsauJr + 1] = {
        knownPlayers = knownPlayers,
        controllerIndex = player.ControllerIndex,
        framesLeft = 3,
    }
    self:RefreshUpdateCallback()
end

function RerollHealthModule:RegisterEsauJrInventory(player)
    local itemConfig = Isaac.GetItemConfig()

    for collectibleType = 1, self.MaxCollectibleId do
        local count = player:GetCollectibleNum(collectibleType, true)
        local config = count > 0 and itemConfig:GetCollectible(collectibleType)

        if config and (config.Type == PASSIVE or config.Type == FAMILIAR) then
            for _ = 1, count do
                -- Esau Jr.'s generated inventory skips normal first-pickup
                -- processing. Replay it once for every passive/familiar, not
                -- only tagged form items: untagged items such as Marbles also
                -- have first-pickup effects. Remove only the temporary copy;
                -- RemoveFromPlayerForm=false preserves any form progress.
                player:AddCollectible(collectibleType, 0, true)
                player:RemoveCollectible(
                    collectibleType,
                    true,
                    ActiveSlot.SLOT_PRIMARY,
                    false
                )
            end
        end
    end
end

function RerollHealthModule:ProcessPendingEsauJr()
    if #self.PendingEsauJr == 0 then
        return
    end

    local game = Game()

    for pendingIndex = #self.PendingEsauJr, 1, -1 do
        local pending = self.PendingEsauJr[pendingIndex]
        local foundPlayer = nil

        for playerIndex = 0, game:GetNumPlayers() - 1 do
            local player = Isaac.GetPlayer(playerIndex)
            local playerHash = tostring(GetPtrHash(player))

            if not pending.knownPlayers[playerHash]
                and (pending.controllerIndex == nil
                    or player.ControllerIndex == pending.controllerIndex)
            then
                foundPlayer = player
                break
            end
        end

        if foundPlayer then
            local playerHash = tostring(GetPtrHash(foundPlayer))

            -- Esau Jr. swaps between two already-created bodies on later uses.
            -- Only the newly generated body needs its skipped first-pickup
            -- processing replayed; revisiting either known body must do nothing.
            if not self.KnownEsauJrBodies[playerHash] then
                self:RegisterEsauJrInventory(foundPlayer)
                self.KnownEsauJrBodies[playerHash] = true
            end

            table.remove(self.PendingEsauJr, pendingIndex)
        else
            pending.framesLeft = pending.framesLeft - 1

            if pending.framesLeft <= 0 then
                table.remove(self.PendingEsauJr, pendingIndex)
            end
        end
    end
end

function RerollHealthModule:IsExcludedDamage(flags, source)
    return self.Context.DamagePolicy:IsNonPenaltyDamage(flags, source)
end

function RerollHealthModule:OnEntityTakeDamage(entity, amount, flags, source)
    local player = entity and entity:ToPlayer()

    if not player or player:GetPlayerType() ~= TAINTED_EDEN then
        return
    end

    if self:IsExcludedDamage(flags, source) then
        return
    end

    self:QueueRestore(player, amount)
end

function RerollHealthModule:SyncPlayer(player)
    local key = self:GetPlayerKey(player)
    local state = self.Players[key]

    if not state then
        self:TrackPlayer(player)
        return
    end

    -- Full inventory scans are expensive standard-API calls. Every supported
    -- reroll path queues its pre-reroll snapshot before vanilla changes the
    -- inventory, so idle frames and player reconstruction (including rewind)
    -- have nothing to reconcile.
    if not state.pending then
        return
    end

    local preRollAllowed = self.TmtrainerPreparedDecisions[key]

    if state.pending.tmtrainerAllowed ~= nil then
        preRollAllowed = state.pending.tmtrainerAllowed
    end

    if state.pending.tmtrainerCount ~= nil then
        self:ReplaceUnexpectedTmtrainer(
            player,
            state.pending.tmtrainerCount,
            self:GetTmtrainerCount(player),
            true,
            preRollAllowed
        )
    end

    local statsPromoted = false

    if self.Context:IsEnabled(ABSORBED_STATS_SETTING_KEY) then
        statsPromoted = self:PromoteAbsorbedStats(
            state,
            state.pending.absorbedStats
        )
    else
        statsPromoted = self:DiscardNativeAbsorbedStats(
            state,
            state.pending.absorbedStats
        )
    end

    if self.Context:IsEnabled(REROLL_SETTING_KEY) then
        local baseline = state.pending.health

        if state.pending.damageAmount then
            baseline = self:ApplyDamageToSnapshot(
                baseline,
                state.pending.damageAmount
            )
        end

        self:RestoreHealth(player, baseline)
    end

    state.pending = nil
    self.TmtrainerPreparedDecisions[key] = nil

    if statsPromoted
        and self.Context:IsEnabled(ABSORBED_STATS_SETTING_KEY)
    then
        self:EvaluatePreservedStats(player)
    end

    return statsPromoted
end

function RerollHealthModule:OnUpdate()
    if not self.RunActive then
        self:SetUpdateCallbackEnabled(false)
        return
    end

    self:ProcessPendingEsauJr()

    local statsChanged = false

    for _, player in pairs(self.PendingSyncPlayers) do
        local state = self.Players[self:GetPlayerKey(player)]

        if state and state.absorption
            and self:FinalizeAbsorption(player, state)
        then
            statsChanged = true
        end
    end

    -- Absorptions that do not also queue a reroll still need reconciliation.
    for key, state in pairs(self.Players) do
        if state.absorption and not self.PendingSyncPlayers[key] then
            local player = state.player

            if player and self:FinalizeAbsorption(player, state) then
                statsChanged = true
            end
        end
    end

    for key, player in pairs(self.PendingSyncPlayers) do
        if self:SyncPlayer(player) then
            statsChanged = true
        end
        self.PendingSyncPlayers[key] = nil
    end

    if statsChanged and self.Context.Save then
        self.Context:Save()
    end

    self:RefreshUpdateCallback()
    self:RefreshPoolGuardCallback()
end

function RerollHealthModule:OnGameStarted(isContinued)
    self:SetUpdateCallbackEnabled(false)
    self:SetDiceUpdateCallbackEnabled(false)
    self:SetPoolGuardCallbackEnabled(false)
    self.RunActive = true
    self.Players = {}
    self.PendingSyncPlayers = {}
    self.PendingEsauJr = {}
    self.KnownEsauJrBodies = {}
    self.TmtrainerPreparedDecisions = {}
    self.TmtrainerRoomPoolGuard = false
    self.PoolOverrideInProgress = false
    self.DiceRoomFace = nil
    self.DiceRoomFloor = nil
    self.DiceRoomTriggered = false
    self:RefreshMaxCollectibleId()

    self.RunSeed = self:GetRunSeed()

    local game = Game()

    local savedPlayers = {}

    if isContinued and self.PreservedData.runSeed == self.RunSeed then
        savedPlayers = self.PreservedData.players
    end

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(playerIndex)
        self:TrackPlayer(
            player,
            playerIndex,
            savedPlayers[tostring(playerIndex)]
        )
        self.KnownEsauJrBodies[self:GetPlayerKey(player)] = true

        if self.Context:IsEnabled(ABSORBED_STATS_SETTING_KEY)
            and self:HasStats(
                self.Players[self:GetPlayerKey(player)].preservedStats
            )
        then
            self:EvaluatePreservedStats(player)
        end
    end

    self:OnNewRoom()
end

function RerollHealthModule:OnSettingChanged(_, settingKey)
    if settingKey == ESAU_JR_SETTING_KEY then
        -- Disabling pauses future first-use registration. Keep known bodies so
        -- toggling the option cannot replay one-time pickup effects.
        self.PendingEsauJr = {}
        self:RefreshUpdateCallback()
        return
    end

    if settingKey == TMTRAINER_SETTING_KEY then
        self.TmtrainerPreparedDecisions = {}
        self.TmtrainerRoomPoolGuard = false

        if self.RunActive and Game():GetRoom():GetType() == RoomType.ROOM_DICE then
            self:OnNewRoom()
        else
            self:RefreshPoolGuardCallback()
        end

        return
    end

    if settingKey == ABSORBED_STATS_SETTING_KEY then
        if self.RunActive then
            local game = Game()

            for playerIndex = 0, game:GetNumPlayers() - 1 do
                self:EvaluatePreservedStats(Isaac.GetPlayer(playerIndex))
            end
        end

        return
    end


    if settingKey == REROLL_SETTING_KEY then
        self.PendingSyncPlayers = {}

        for _, state in pairs(self.Players) do
            state.pending = nil
        end

        self:RefreshUpdateCallback()
        self:RefreshPoolGuardCallback()
        return
    end

    self.Players = {}
    self.PendingSyncPlayers = {}

    if self.RunActive then
        local game = Game()

        for playerIndex = 0, game:GetNumPlayers() - 1 do
            local player = Isaac.GetPlayer(playerIndex)
            self:TrackPlayer(player, playerIndex)
        end
    end

    self:RefreshUpdateCallback()
end

function RerollHealthModule:GetSaveData()
    if self.RunSeed == nil then
        return self.SavedData
    end

    local absorbedStats = {}

    for _, state in pairs(self.Players) do
        if state.playerIndex ~= nil then
            absorbedStats[tostring(state.playerIndex)] = {
                preserved = self:CopyStats(state.preservedStats),
                native = self:CopyStats(state.nativeAbsorbedStats),
            }
        end
    end

    return {
        runSeed = self.RunSeed,
        absorbedStats = absorbedStats,
    }
end

function RerollHealthModule:OnPreGameExit()
    self.SavedData = self:GetSaveData()
    self.RunSeed = nil
    self:SetUpdateCallbackEnabled(false)
    self:SetDiceUpdateCallbackEnabled(false)
    self:SetPoolGuardCallbackEnabled(false)
    self.RunActive = false
    self.Players = {}
    self.PendingSyncPlayers = {}
    self.PendingEsauJr = {}
    self.KnownEsauJrBodies = {}
    self.TmtrainerPreparedDecisions = {}
    self.TmtrainerRoomPoolGuard = false
    self.PoolOverrideInProgress = false
    self.DiceRoomFace = nil
    self.DiceRoomFloor = nil
    self.DiceRoomTriggered = false
end

return RerollHealthModule
