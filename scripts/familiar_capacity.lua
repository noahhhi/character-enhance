local FamiliarCapacityModule = {}
FamiliarCapacityModule.__index = FamiliarCapacityModule

local SETTING_KEY = "familiarCapacity"
local BLUE_FLY = FamiliarVariant.BLUE_FLY
local BLUE_SPIDER = FamiliarVariant.BLUE_SPIDER
local FAMILIAR_SOFT_LIMIT = 55
local FAMILIAR_HARD_LIMIT = 64
local DONT_OVERWRITE = EntityFlag.FLAG_DONT_OVERWRITE
local POOL_GUARD_TAG = "CharacterEnhanceFamiliarCapacityPoolGuard"
local BANK_RELEASE_INTERVAL = 1
local BANK_BLOCKED_RETRY_MAX = 30
local BANK_RELEASE_BATCH_SIZE = 7
local BANK_SAVE_DELAY = 60
local MAX_BANKED_PER_TYPE = 2147483647
local REWIND_HISTORY_LIMIT = 16
local REWIND_RELEASE_DELAY = 5
local REWIND_REMOVAL_TAG = "CharacterEnhanceFamiliarCapacityRewindRemoval"
local RELEASE_TARGET_DISTANCE = 10000
local SPIDER_TARGET_GAP = 20
local RELEASE_TARGET_RETRY_INTERVAL = 10
local RELEASE_RETARGET_INTERVAL = 10

function FamiliarCapacityModule.New(context)
    local self = setmetatable({
        Context = context,
        SavedData = context:GetSavedModuleData(SETTING_KEY),
        TemporaryBank = {},
        BankedCount = 0,
        Snapshot = {
            frame = -1,
            total = 0,
            expendable = {},
            expendableOwners = {},
            nearestByPlayer = {},
            nearestAny = nil,
            reservedSeeds = {},
        },
        PendingOverflowSpawns = {},
        PendingOverflowCount = 0,
        ActiveReleaseRequest = nil,
        NextReleaseFrame = 0,
        ReleaseRetryInterval = BANK_RELEASE_INTERVAL,
        ReleasePlayerCursor = 0,
        ReleaseSpiderNext = false,
        BankDirty = false,
        BankSaveDueFrame = nil,
        RunActive = false,
        NeedsRebalance = false,
        ReleaseTargetCache = {},
        DeadReleaseTargetHashes = {},
        TrackedReleasedFamiliars = {},
        TrackedReleaseTargetCounts = {},
        TrackedReleasedCount = 0,
        NextRetargetFrame = 0,
        RewindHistory = {},
        LastRoomTimeCounter = nil,
        UpdateCallbackRegistered = false,
    }, FamiliarCapacityModule)

    self.UpdateCallback = function()
        self:OnUpdate()
    end

    context.Mod:AddCallback(
        ModCallbacks.MC_POST_GAME_STARTED,
        function(_, isContinued)
            self:OnGameStarted(isContinued)
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

    -- Run late in the pre-spawn chain so an initialized expendable familiar can
    -- be banked before the replacement request reaches the fixed familiar pool.
    if type(context.Mod.AddPriorityCallback) == "function" then
        context.Mod:AddPriorityCallback(
            ModCallbacks.MC_PRE_ENTITY_SPAWN,
            CallbackPriority.LATE,
            preSpawnCallback,
            EntityType.ENTITY_FAMILIAR
        )
    else
        context.Mod:AddCallback(
            ModCallbacks.MC_PRE_ENTITY_SPAWN,
            preSpawnCallback,
            EntityType.ENTITY_FAMILIAR
        )
    end
    context.Mod:AddCallback(
        ModCallbacks.MC_FAMILIAR_INIT,
        function(_, familiar)
            self:OnFamiliarInit(familiar)
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_ENTITY_REMOVE,
        function(_, entity)
            self:OnEntityRemove(entity)
        end,
        EntityType.ENTITY_FAMILIAR
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_NPC_DEATH,
        function(_, npc)
            self:OnReleaseTargetDeath(npc)
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_NEW_ROOM,
        function()
            self:OnNewRoom()
        end
    )
    -- Keep previously saved overflow available even while sitting in the main
    -- menu. Changing an MCM option before continuing a run must not overwrite
    -- that saved bank with an empty table.
    self:LoadBank(true)

    return self
end

function FamiliarCapacityModule:RefreshUpdateCallback()
    local enabled = self:IsEnabled()
        and (self.NeedsRebalance
            or self.BankedCount > 0
            or self.BankDirty
            or self.TrackedReleasedCount > 0)

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

function FamiliarCapacityModule:MarkBankDirty()
    self.BankDirty = true

    if not self.BankSaveDueFrame then
        self.BankSaveDueFrame = Game():GetFrameCount() + BANK_SAVE_DELAY
    end
end

function FamiliarCapacityModule:SaveBankIfDue()
    if not self.BankDirty
        or Game():GetFrameCount() < self.BankSaveDueFrame
    then
        return
    end

    -- SaveData is unsafe during MC_PRE_MOD_UNLOAD on Repentance+ 1.9.7.15.
    -- Persist the mutable overflow bank from this normal update callback instead.
    self.Context:Save()
    self.BankDirty = false
    self.BankSaveDueFrame = nil
end

function FamiliarCapacityModule:IsEnabled()
    return self.RunActive and self.Context:IsEnabled(SETTING_KEY)
end

function FamiliarCapacityModule:ResetSnapshot()
    self.Snapshot.frame = -1
    self.Snapshot.total = 0
    self.Snapshot.expendable = {}
    self.Snapshot.expendableOwners = {}
    self.Snapshot.nearestByPlayer = {}
    self.Snapshot.nearestAny = nil
    self.Snapshot.reservedSeeds = {}
end

function FamiliarCapacityModule:ResetPendingOverflowSpawns()
    self.PendingOverflowSpawns = {}
    self.PendingOverflowCount = 0
    self.ActiveReleaseRequest = nil
end

function FamiliarCapacityModule:IsBankableVariant(variant)
    return variant == BLUE_FLY or variant == BLUE_SPIDER
end

function FamiliarCapacityModule:GuardFamiliarPoolSlot(familiar)
    if not familiar or not familiar:Exists() then
        return
    end

    local data = familiar:GetData()

    if not familiar:HasEntityFlags(DONT_OVERWRITE) then
        familiar:AddEntityFlags(DONT_OVERWRITE)
        data[POOL_GUARD_TAG] = true
    end
end

function FamiliarCapacityModule:ReleaseFamiliarPoolSlot(familiar)
    if not familiar then
        return
    end

    local data = familiar:GetData()

    if data[POOL_GUARD_TAG] then
        familiar:ClearEntityFlags(DONT_OVERWRITE)
        data[POOL_GUARD_TAG] = nil
    end
end

function FamiliarCapacityModule:ReleaseAllFamiliarPoolSlots()
    for _, entity in ipairs(Isaac.FindByType(
        EntityType.ENTITY_FAMILIAR,
        -1,
        -1,
        false,
        false
    )) do
        local familiar = entity:ToFamiliar()

        if familiar and familiar:Exists() then
            self:ReleaseFamiliarPoolSlot(familiar)
        end
    end
end

function FamiliarCapacityModule:GetPlayerIndex(player)
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

function FamiliarCapacityModule:ResolveOwnerFromSource(source)
    for _ = 1, 6 do
        if not source then
            break
        end

        local player = source:ToPlayer()

        if player then
            return player
        end

        local sourceFamiliar = source:ToFamiliar()

        if sourceFamiliar and sourceFamiliar.Player then
            return sourceFamiliar.Player
        end

        source = source.SpawnerEntity or source.Parent
    end

    if Game():GetNumPlayers() == 1 then
        return Isaac.GetPlayer(0)
    end

    return nil
end

function FamiliarCapacityModule:ResolveOwner(familiar)
    if familiar.Player then
        return familiar.Player
    end

    return self:ResolveOwnerFromSource(
        familiar.SpawnerEntity or familiar.Parent
    )
end

function FamiliarCapacityModule:GetSquaredDistance(first, second)
    if not first or not second then
        return math.huge
    end

    local deltaX = first.X - second.X
    local deltaY = first.Y - second.Y

    return deltaX * deltaX + deltaY * deltaY
end

function FamiliarCapacityModule:CacheExpendableCandidate(familiar)
    local owner = self:ResolveOwner(familiar)
    local playerIndex = self:GetPlayerIndex(owner)

    if playerIndex == nil then
        return nil
    end

    local entry = {
        familiar = familiar,
        playerIndex = playerIndex,
        distance = self:GetSquaredDistance(
            familiar.Position,
            owner.Position
        ),
    }
    local nearestForPlayer = self.Snapshot.nearestByPlayer[playerIndex]

    self.Snapshot.expendableOwners[GetPtrHash(familiar)] = playerIndex

    if not nearestForPlayer
        or entry.distance < nearestForPlayer.distance
    then
        self.Snapshot.nearestByPlayer[playerIndex] = entry
    end

    if not self.Snapshot.nearestAny
        or entry.distance < self.Snapshot.nearestAny.distance
    then
        self.Snapshot.nearestAny = entry
    end

    return entry
end

function FamiliarCapacityModule:RegisterExpendableCandidate(familiar)
    local entry = self:CacheExpendableCandidate(familiar)

    if entry then
        self.Snapshot.expendable[#self.Snapshot.expendable + 1] = entry
    end

    return entry
end

function FamiliarCapacityModule:IsValidExpendableEntry(entry)
    local familiar = entry and entry.familiar

    return familiar
        and familiar:Exists()
        and self:IsBankableVariant(familiar.Variant)
end

function FamiliarCapacityModule:InvalidateExpendableCandidate(familiar)
    local familiarHash = GetPtrHash(familiar)
    local playerIndex = self.Snapshot.expendableOwners[familiarHash]

    self.Snapshot.expendableOwners[familiarHash] = nil

    if playerIndex ~= nil then
        local nearest = self.Snapshot.nearestByPlayer[playerIndex]

        if nearest and nearest.familiar == familiar then
            self.Snapshot.nearestByPlayer[playerIndex] = nil
        end
    end

    local nearestAny = self.Snapshot.nearestAny

    if nearestAny and nearestAny.familiar == familiar then
        self.Snapshot.nearestAny = nil
    end
end

function FamiliarCapacityModule:GetPlayerBank(playerIndex)
    local key = tostring(playerIndex)
    local bank = self.TemporaryBank[key]

    if not bank then
        bank = {
            blueFlies = 0,
            blueSpiders = 0,
        }
        self.TemporaryBank[key] = bank
    end

    return bank
end

function FamiliarCapacityModule:AddToBank(playerIndex, variant, amount)
    if playerIndex == nil or amount <= 0 then
        return false
    end

    local bank = self:GetPlayerBank(playerIndex)
    local field = variant == BLUE_FLY and "blueFlies" or "blueSpiders"
    local previousCount = bank[field] or 0

    if previousCount >= MAX_BANKED_PER_TYPE then
        return false
    end

    local newCount = math.min(MAX_BANKED_PER_TYPE, previousCount + amount)
    bank[field] = newCount
    self.BankedCount = self.BankedCount + newCount - previousCount
    self:MarkBankDirty()
    self:RefreshUpdateCallback()

    return true
end

function FamiliarCapacityModule:CopyTemporaryBank(bankSource)
    local copy = {}

    for playerKey, bank in pairs(bankSource or {}) do
        if type(bank) == "table" then
            copy[tostring(playerKey)] = {
                blueFlies = self:SanitizeCount(bank.blueFlies),
                blueSpiders = self:SanitizeCount(bank.blueSpiders),
            }
        end
    end

    return copy
end

function FamiliarCapacityModule:CountBankedFamiliars(bankSource)
    local total = 0

    for _, bank in pairs(bankSource or {}) do
        if type(bank) == "table" then
            total = total + self:SanitizeCount(bank.blueFlies)
            total = total + self:SanitizeCount(bank.blueSpiders)
        end
    end

    return total
end

function FamiliarCapacityModule:GetBankField(variant)
    return variant == BLUE_FLY and "blueFlies" or "blueSpiders"
end

function FamiliarCapacityModule:CollectPhysicalTemporaryFamiliars()
    local counts = {}
    local entities = {}

    for _, entity in ipairs(Isaac.FindByType(
        EntityType.ENTITY_FAMILIAR,
        -1,
        -1,
        false,
        false
    )) do
        local familiar = entity:ToFamiliar()

        if familiar and familiar:Exists()
            and self:IsBankableVariant(familiar.Variant)
        then
            local owner = self:ResolveOwner(familiar)
            local playerIndex = self:GetPlayerIndex(owner)

            if playerIndex ~= nil then
                local playerKey = tostring(playerIndex)
                local field = self:GetBankField(familiar.Variant)
                local playerCounts = counts[playerKey]
                local playerEntities = entities[playerKey]

                if not playerCounts then
                    playerCounts = { blueFlies = 0, blueSpiders = 0 }
                    counts[playerKey] = playerCounts
                    playerEntities = { blueFlies = {}, blueSpiders = {} }
                    entities[playerKey] = playerEntities
                end

                playerCounts[field] = playerCounts[field] + 1
                playerEntities[field][#playerEntities[field] + 1] = {
                    familiar = familiar,
                    distance = self:GetSquaredDistance(
                        familiar.Position,
                        owner.Position
                    ),
                }
            end
        end
    end

    return counts, entities
end

function FamiliarCapacityModule:GetTimeCounter()
    local game = Game()

    if type(game.TimeCounter) == "number" then
        return game.TimeCounter
    end

    return game:GetFrameCount()
end

function FamiliarCapacityModule:CaptureRewindSnapshot(timeCounter)
    local physicalCounts = self:CollectPhysicalTemporaryFamiliars()
    local snapshot = {
        timeCounter = timeCounter or self:GetTimeCounter(),
        temporaryBank = self:CopyTemporaryBank(self.TemporaryBank),
        physicalCounts = physicalCounts,
    }

    self.RewindHistory[#self.RewindHistory + 1] = snapshot

    if #self.RewindHistory > REWIND_HISTORY_LIMIT then
        table.remove(self.RewindHistory, 1)
    end

    return snapshot
end

function FamiliarCapacityModule:FindRewindSnapshot(timeCounter)
    for index = #self.RewindHistory, 1, -1 do
        local snapshot = self.RewindHistory[index]

        if snapshot.timeCounter <= timeCounter then
            return snapshot, index
        end
    end

    return nil, nil
end

function FamiliarCapacityModule:AddMissingRewindCount(
    playerKey,
    field,
    amount
)
    if amount <= 0 then
        return 0
    end

    local bank = self.TemporaryBank[playerKey]

    if not bank then
        bank = { blueFlies = 0, blueSpiders = 0 }
        self.TemporaryBank[playerKey] = bank
    end

    local previousCount = bank[field] or 0
    local newCount = math.min(MAX_BANKED_PER_TYPE, previousCount + amount)
    bank[field] = newCount
    self.BankedCount = self.BankedCount + newCount - previousCount

    return newCount - previousCount
end

function FamiliarCapacityModule:RemoveRewindDuplicate(familiar)
    if not familiar or not familiar:Exists() then
        return false
    end

    familiar:GetData()[REWIND_REMOVAL_TAG] = true
    self:ReleaseFamiliarPoolSlot(familiar)
    familiar:Remove()

    return true
end

function FamiliarCapacityModule:RestoreRewindSnapshot(snapshot)
    if not snapshot then
        return false
    end

    self.TemporaryBank = self:CopyTemporaryBank(snapshot.temporaryBank)
    self.BankedCount = self:CountBankedFamiliars(self.TemporaryBank)
    self.BankDirty = false
    self.BankSaveDueFrame = nil

    local currentCounts, currentEntities =
        self:CollectPhysicalTemporaryFamiliars()
    local targetPhysicalCounts = snapshot.physicalCounts or {}
    local playerKeys = {}
    local removedDuplicates = 0
    local restoredMissing = 0

    for playerKey in pairs(targetPhysicalCounts) do
        playerKeys[playerKey] = true
    end

    for playerKey in pairs(currentCounts) do
        playerKeys[playerKey] = true
    end

    for playerKey in pairs(playerKeys) do
        for _, field in ipairs({ "blueFlies", "blueSpiders" }) do
            local targetBank = targetPhysicalCounts[playerKey]
            local targetCount = targetBank and targetBank[field] or 0
            local currentBank = currentCounts[playerKey]
            local currentCount = currentBank and currentBank[field] or 0
            local entries = currentEntities[playerKey]
                and currentEntities[playerKey][field]
                or {}

            if currentCount > targetCount then
                table.sort(entries, function(first, second)
                    return first.distance < second.distance
                end)

                for index = 1, currentCount - targetCount do
                    if self:RemoveRewindDuplicate(
                        entries[index].familiar
                    ) then
                        removedDuplicates = removedDuplicates + 1
                    end
                end
            elseif currentCount < targetCount then
                restoredMissing = restoredMissing
                    + self:AddMissingRewindCount(
                        playerKey,
                        field,
                        targetCount - currentCount
                    )
            end
        end
    end

    self:ResetSnapshot()
    self:ResetPendingOverflowSpawns()
    self:ResetReleaseTracking()
    self.NeedsRebalance = self.Context:IsEnabled(SETTING_KEY)
    self.ReleaseRetryInterval = BANK_RELEASE_INTERVAL
    self.NextReleaseFrame = Game():GetFrameCount() + REWIND_RELEASE_DELAY
    self:MarkBankDirty()
    Isaac.DebugString(
        "[Character Enhance][Familiar Capacity] rewind restored; "
        .. "discarded duplicates=" .. removedDuplicates
        .. "; cached missing=" .. restoredMissing
        .. "; banked=" .. self.BankedCount
    )

    return true
end

function FamiliarCapacityModule:RefreshSnapshot(force)
    local frame = Game():GetFrameCount()

    if not force and self.Snapshot.frame == frame then
        return self.Snapshot
    end

    local total = 0
    local familiars = Isaac.FindByType(
        EntityType.ENTITY_FAMILIAR,
        -1,
        -1,
        false,
        false
    )

    self.Snapshot.expendable = {}
    self.Snapshot.expendableOwners = {}
    self.Snapshot.nearestByPlayer = {}
    self.Snapshot.nearestAny = nil

    for _, entity in ipairs(familiars) do
        if entity:Exists() then
            local familiar = entity:ToFamiliar()
            total = total + 1

            -- EntityFactory consults FLAG_DONT_OVERWRITE when its native
            -- familiar array is full. Guard every occupied slot so a burst can
            -- recycle only the expendable slot explicitly released below.
            self:GuardFamiliarPoolSlot(familiar)

            if self:IsBankableVariant(entity.Variant) then
                self:RegisterExpendableCandidate(familiar)
            end
        end
    end

    self.Snapshot.frame = frame
    self.Snapshot.total = total
    self.Snapshot.reservedSeeds = {}

    return self.Snapshot
end

function FamiliarCapacityModule:ReserveFamiliarSpawn(seed)
    if type(seed) ~= "number" then
        return false
    end

    self.Snapshot.reservedSeeds[seed] =
        (self.Snapshot.reservedSeeds[seed] or 0) + 1
    self.Snapshot.total = self.Snapshot.total + 1

    return true
end

function FamiliarCapacityModule:ConsumeFamiliarReservation(familiar)
    local seed = familiar.InitSeed
    local reserved = type(seed) == "number"
        and self.Snapshot.reservedSeeds[seed]
        or 0

    if reserved <= 0 then
        return false
    end

    if reserved == 1 then
        self.Snapshot.reservedSeeds[seed] = nil
    else
        self.Snapshot.reservedSeeds[seed] = reserved - 1
    end

    return true
end

function FamiliarCapacityModule:RegisterInitializedFamiliar(
    familiar,
    skipExpendable
)
    local frame = Game():GetFrameCount()

    if self.Snapshot.frame ~= frame then
        return self:RefreshSnapshot(true)
    end

    if not self:ConsumeFamiliarReservation(familiar) then
        self.Snapshot.total = self.Snapshot.total + 1
    end

    if not skipExpendable
        and self:IsBankableVariant(familiar.Variant)
    then
        self:RegisterExpendableCandidate(familiar)
    end

    return self.Snapshot
end

function FamiliarCapacityModule:QueuePendingOverflowSpawn(seed, variant)
    if type(seed) ~= "number" or not self:IsBankableVariant(variant) then
        return false
    end

    local queue = self.PendingOverflowSpawns[seed]

    if not queue then
        queue = { head = 1, tail = 0 }
        self.PendingOverflowSpawns[seed] = queue
    end

    queue.tail = queue.tail + 1
    queue[queue.tail] = { variant = variant }
    self.PendingOverflowCount = self.PendingOverflowCount + 1

    return true
end

function FamiliarCapacityModule:DiscardUninitializedOverflowSpawns()
    if self.PendingOverflowCount > 0 then
        -- Native familiar initialization is synchronous with allocation. Any
        -- request still queued by MC_POST_UPDATE was rejected by the engine and
        -- must not suppress later fallback accounting through a stale count.
        self:ResetPendingOverflowSpawns()
    end
end

function FamiliarCapacityModule:ConsumePendingOverflowSpawn(seed, variant)
    local queue = type(seed) == "number"
        and self.PendingOverflowSpawns[seed]
        or nil

    if not queue or queue.head > queue.tail then
        return nil
    end

    local pending = queue[queue.head]

    if pending.variant ~= variant then
        return nil
    end

    queue[queue.head] = nil
    queue.head = queue.head + 1
    self.PendingOverflowCount = math.max(
        0,
        self.PendingOverflowCount - 1
    )

    if queue.head > queue.tail then
        self.PendingOverflowSpawns[seed] = nil
    end

    return pending
end

function FamiliarCapacityModule:OnPreEntitySpawn(
    entityType,
    variant,
    _subtype,
    _position,
    _velocity,
    spawner,
    seed
)
    if not self:IsEnabled()
        or entityType ~= EntityType.ENTITY_FAMILIAR
    then
        return nil
    end

    local snapshot = self:RefreshSnapshot(false)

    local releaseRequest = self.ActiveReleaseRequest
    local releaseOwner = releaseRequest
        and self:ResolveOwnerFromSource(spawner)
        or nil

    if releaseRequest
        and releaseRequest.variant == variant
        and self:IsBankableVariant(variant)
        and self:GetPlayerIndex(releaseOwner) == releaseRequest.playerIndex
    then
        -- A refill is committed only after its synchronous familiar-init
        -- callback confirms that EntityFactory really allocated the slot.
        -- Bypass normal overflow banking for this already-accounted request.
        releaseRequest.seed = seed
        self:ReserveFamiliarSpawn(seed)
        return nil
    end

    if not self:IsBankableVariant(variant) then
        -- Important familiars stay in their original native class. At the hard
        -- edge, free an already initialized expendable slot before allocation.
        if snapshot.total >= FAMILIAR_HARD_LIMIT then
            local owner = self:ResolveOwnerFromSource(spawner)
            local expendable = self:FindExpendableFamiliar(
                self:GetPlayerIndex(owner)
            )

            if expendable then
                self:BankFamiliar(expendable)
            end
        end

        self:ReserveFamiliarSpawn(seed)
        return nil
    end

    if snapshot.total < FAMILIAR_SOFT_LIMIT then
        -- Pre-spawn callbacks can be grouped before familiar initialization.
        -- Reserve this same-frame slot now so a burst cannot admit multiple
        -- expendable familiars through the final open slot.
        self:ReserveFamiliarSpawn(seed)
        return nil
    end

    local player = self:ResolveOwnerFromSource(spawner)
    local playerIndex = self:GetPlayerIndex(player)

    -- Multiplayer ownership can be ambiguous. Preserve the original spawn
    -- rather than banking it under a guessed player.
    if playerIndex == nil or type(seed) ~= "number" then
        self:ReserveFamiliarSpawn(seed)
        return nil
    end

    -- Repentance+ 1.9.7.15 selects native object storage before applying a
    -- cross-type pre-spawn replacement. Turning a familiar request into an
    -- effect therefore corrupts effect initialization and crashes. Instead,
    -- bank one fully initialized expendable familiar before allowing the new
    -- same-class request to replace it.
    local expendable = self:FindExpendableFamiliar(playerIndex)

    if expendable and self:BankFamiliar(expendable) then
        self:ReserveFamiliarSpawn(seed)
        return nil
    end

    -- The current limit can consist entirely of important familiars. Record
    -- this overflow now, use the soft-limit reserve, and remove the new
    -- same-class fly/spider from its init fallback. No cross-type proxy is
    -- constructed.
    if not self:AddToBank(playerIndex, variant, 1) then
        self:ReserveFamiliarSpawn(seed)
        return nil
    end

    self:QueuePendingOverflowSpawn(seed, variant)
    self:ReserveFamiliarSpawn(seed)

    return nil
end

function FamiliarCapacityModule:BankFamiliar(familiar)
    if not familiar or not familiar:Exists()
        or not self:IsBankableVariant(familiar.Variant)
    then
        return false
    end

    local familiarHash = GetPtrHash(familiar)
    local playerIndex = self.Snapshot.expendableOwners[familiarHash]

    if playerIndex == nil then
        local player = self:ResolveOwner(familiar)
        playerIndex = self:GetPlayerIndex(player)
    end

    if not self:AddToBank(playerIndex, familiar.Variant, 1) then
        return false
    end

    self:InvalidateExpendableCandidate(familiar)
    self:ReleaseFamiliarPoolSlot(familiar)
    familiar:Remove()
    self.Snapshot.total = math.max(0, self.Snapshot.total - 1)

    return true
end

function FamiliarCapacityModule:FindExpendableFamiliar(
    preferredPlayerIndex
)
    local selectedEntry = nil

    if preferredPlayerIndex ~= nil then
        selectedEntry = self.Snapshot.nearestByPlayer[preferredPlayerIndex]
    else
        selectedEntry = self.Snapshot.nearestAny
    end

    if self:IsValidExpendableEntry(selectedEntry) then
        return selectedEntry.familiar
    end

    local selected = nil
    local selectedOwnerRank = math.huge
    local selectedDistance = math.huge

    for _, entry in ipairs(self.Snapshot.expendable) do
        if self:IsValidExpendableEntry(entry) then
            local ownerRank = preferredPlayerIndex ~= nil
                and (entry.playerIndex == preferredPlayerIndex and 0 or 1)
                or 0
            local distance = entry.distance

            -- Newly generated flies and spiders begin beside their owner.
            -- Prefer banking those nearby entities so distant familiars
            -- already travelling toward an enemy keep their attack.
            if ownerRank < selectedOwnerRank
                or (ownerRank == selectedOwnerRank
                    and distance < selectedDistance)
            then
                selected = entry.familiar
                selectedOwnerRank = ownerRank
                selectedDistance = distance
            end
        end
    end

    return selected
end

function FamiliarCapacityModule:ProtectImportantSlots(preferredPlayerIndex)
    while self.Snapshot.total >= FAMILIAR_HARD_LIMIT do
        local expendable = self:FindExpendableFamiliar(
            preferredPlayerIndex
        )

        if not expendable or not self:BankFamiliar(expendable) then
            break
        end
    end
end

function FamiliarCapacityModule:OnFamiliarInit(familiar)
    if not self:IsEnabled() then
        return
    end

    local releaseRequest = self.ActiveReleaseRequest

    if releaseRequest
        and releaseRequest.variant == familiar.Variant
        and releaseRequest.seed == familiar.InitSeed
    then
        releaseRequest.confirmed = true
    end

    local pending = self:IsBankableVariant(familiar.Variant)
        and self:ConsumePendingOverflowSpawn(
            familiar.InitSeed,
            familiar.Variant
        )
        or nil
    self:RegisterInitializedFamiliar(familiar, pending ~= nil)

    if pending then
        self:ReleaseFamiliarPoolSlot(familiar)
        familiar:Remove()
        self.Snapshot.total = math.max(0, self.Snapshot.total - 1)

        return
    end

    if self:IsBankableVariant(familiar.Variant) then
        -- Reservations for queued overflow are already included in total and
        -- will be removed by their own init callbacks. Exclude those future
        -- removals so an earlier allowed familiar is not banked as well.
        if self.Snapshot.total - self.PendingOverflowCount
                > FAMILIAR_SOFT_LIMIT
            and self:BankFamiliar(familiar)
        then
            return
        end

        self:GuardFamiliarPoolSlot(familiar)
        return
    end

    self:GuardFamiliarPoolSlot(familiar)
    local owner = self:ResolveOwner(familiar)
    self:ProtectImportantSlots(self:GetPlayerIndex(owner))
end

function FamiliarCapacityModule:OnEntityRemove(entity)
    if not entity or entity.Type ~= EntityType.ENTITY_FAMILIAR then
        return
    end

    local familiar = entity:ToFamiliar()
    local wasRewindDuplicate = familiar
        and familiar:GetData()[REWIND_REMOVAL_TAG] == true
    local wasModuleGuarded = familiar
        and familiar:GetData()[POOL_GUARD_TAG] == true

    self:UntrackReleasedFamiliar(familiar)

    -- Removed familiars can remain in EntityFactory's native storage until
    -- that slot is reused. Leaving FLAG_DONT_OVERWRITE on the dead entity
    -- makes the slot permanently ineligible for reuse and eventually exhausts
    -- the pool even when only a few live familiars remain in the room.
    self:ReleaseFamiliarPoolSlot(familiar)

    if wasRewindDuplicate then
        familiar:GetData()[REWIND_REMOVAL_TAG] = nil
        return
    end

    -- Natural removals do not pass through BankFamiliar's explicit snapshot
    -- accounting. Invalidate the same-frame count so the next spawn rescans
    -- live entities instead of treating the released slot as occupied.
    if wasModuleGuarded then
        self:ResetSnapshot()
    end

    -- A removed familiar has just opened a native slot. Wake a backed-off
    -- refill immediately so sustained attackers are replaced on the next
    -- update instead of leaving a visible gap in the swarm.
    if self:IsEnabled() and self.BankedCount > 0 then
        self.ReleaseRetryInterval = BANK_RELEASE_INTERVAL
        self.NextReleaseFrame = Game():GetFrameCount()
    end
end

function FamiliarCapacityModule:RebalanceCapacity()
    self:RefreshSnapshot(true)

    while self.Snapshot.total > FAMILIAR_SOFT_LIMIT do
        local expendable = self:FindExpendableFamiliar()

        if not expendable or not self:BankFamiliar(expendable) then
            break
        end
    end

    self.NeedsRebalance = false
end

function FamiliarCapacityModule:IsValidReleaseTarget(entity)
    return entity
        and entity:Exists()
        and entity:IsActiveEnemy(false)
        and entity:IsVulnerableEnemy()
        and not entity:HasEntityFlags(EntityFlag.FLAG_NO_TARGET)
        and not entity:HasEntityFlags(EntityFlag.FLAG_FRIENDLY)
end

function FamiliarCapacityModule:FindReleaseTargets(player)
    local targets = {}

    for order, entity in ipairs(Isaac.GetRoomEntities()) do
        if self:IsValidReleaseTarget(entity) then
            targets[#targets + 1] = {
                entity = entity,
                distance = self:GetSquaredDistance(
                    player.Position,
                    entity.Position
                ),
                order = order,
            }
        end
    end

    table.sort(targets, function(first, second)
        if first.distance == second.distance then
            return first.order < second.order
        end

        return first.distance < second.distance
    end)

    for index, target in ipairs(targets) do
        targets[index] = target.entity
    end

    return targets
end

function FamiliarCapacityModule:ResetReleaseTracking()
    self.ReleaseTargetCache = {}
    self.DeadReleaseTargetHashes = {}
    self.TrackedReleasedFamiliars = {}
    self.TrackedReleaseTargetCounts = {}
    self.TrackedReleasedCount = 0
    self.NextRetargetFrame = 0
end

function FamiliarCapacityModule:ResetReleaseTargetCache()
    self.ReleaseTargetCache = {}
end

function FamiliarCapacityModule:GetReleaseTarget(playerIndex, player)
    local frame = Game():GetFrameCount()
    local cached = self.ReleaseTargetCache[playerIndex]

    if not cached or frame >= cached.nextSearchFrame then
        local cursor = cached and cached.cursor or 1
        local targets = self:FindReleaseTargets(player)

        if #targets > 0 then
            cursor = (cursor - 1) % #targets + 1
        else
            cursor = 1
        end

        cached = {
            targets = targets,
            cursor = cursor,
            nextSearchFrame = frame + RELEASE_TARGET_RETRY_INTERVAL,
        }
        self.ReleaseTargetCache[playerIndex] = cached
    end

    local targetCount = #cached.targets

    for _ = 1, targetCount do
        local targetIndex = cached.cursor
        local target = cached.targets[targetIndex]

        cached.cursor = targetIndex % targetCount + 1

        if self:IsValidReleaseTarget(target) then
            return target
        end
    end

    return nil
end

function FamiliarCapacityModule:SetTrackedReleaseTarget(
    tracked,
    target
)
    local oldHash = tracked.targetHash
    local targetHash = target and GetPtrHash(target) or nil

    if oldHash == targetHash then
        return
    end

    if oldHash then
        local oldCount = self.TrackedReleaseTargetCounts[oldHash] or 0

        if oldCount <= 1 then
            self.TrackedReleaseTargetCounts[oldHash] = nil
        else
            self.TrackedReleaseTargetCounts[oldHash] = oldCount - 1
        end
    end

    tracked.targetHash = targetHash

    if targetHash then
        self.TrackedReleaseTargetCounts[targetHash] =
            (self.TrackedReleaseTargetCounts[targetHash] or 0) + 1
    end
end

function FamiliarCapacityModule:TrackReleasedFamiliar(
    entity,
    playerIndex
)
    local familiar = entity and entity:ToFamiliar()

    if not familiar or not familiar:Exists()
        or not self:IsBankableVariant(familiar.Variant)
    then
        return
    end

    local familiarHash = GetPtrHash(familiar)
    local previous = self.TrackedReleasedFamiliars[familiarHash]

    if not previous then
        self.TrackedReleasedCount = self.TrackedReleasedCount + 1
    else
        self:SetTrackedReleaseTarget(previous, nil)
    end

    local tracked = {
        familiar = familiar,
        playerIndex = playerIndex,
        needsReacquire = not self:IsValidReleaseTarget(familiar.Target),
    }
    self.TrackedReleasedFamiliars[familiarHash] = tracked
    self:SetTrackedReleaseTarget(tracked, familiar.Target)
end

function FamiliarCapacityModule:UntrackReleasedFamiliar(familiar)
    if not familiar then
        return
    end

    local familiarHash = GetPtrHash(familiar)

    local tracked = self.TrackedReleasedFamiliars[familiarHash]

    if tracked then
        self:SetTrackedReleaseTarget(tracked, nil)
        self.TrackedReleasedFamiliars[familiarHash] = nil
        self.TrackedReleasedCount = math.max(
            0,
            self.TrackedReleasedCount - 1
        )
    end
end

function FamiliarCapacityModule:OnReleaseTargetDeath(npc)
    if self.TrackedReleasedCount <= 0 or not npc then
        return
    end

    local targetHash = GetPtrHash(npc)

    if not self.TrackedReleaseTargetCounts[targetHash] then
        return
    end

    self.DeadReleaseTargetHashes[targetHash] = true
    self:ResetReleaseTargetCache()
    self.NextRetargetFrame = 0
end

function FamiliarCapacityModule:RetargetReleasedFamiliars()
    if self.TrackedReleasedCount <= 0 then
        return
    end

    local frame = Game():GetFrameCount()

    if frame < self.NextRetargetFrame then
        return
    end

    self.NextRetargetFrame = frame + RELEASE_RETARGET_INTERVAL
    local deadTargetHashes = self.DeadReleaseTargetHashes
    self.DeadReleaseTargetHashes = {}

    for familiarHash, tracked in pairs(self.TrackedReleasedFamiliars) do
        local familiar = tracked.familiar

        if not familiar or not familiar:Exists()
            or not self:IsBankableVariant(familiar.Variant)
        then
            self:SetTrackedReleaseTarget(tracked, nil)
            self.TrackedReleasedFamiliars[familiarHash] = nil
            self.TrackedReleasedCount = math.max(
                0,
                self.TrackedReleasedCount - 1
            )
        else
            self:SetTrackedReleaseTarget(tracked, familiar.Target)
            local targetHash = tracked.targetHash
            local targetDied = targetHash
                and deadTargetHashes[targetHash] == true
            local hasValidTarget = not targetDied
                and self:IsValidReleaseTarget(familiar.Target)

            if not hasValidTarget then
                tracked.needsReacquire = true
            end

            if not hasValidTarget or tracked.needsReacquire then
                local player = Isaac.GetPlayer(tracked.playerIndex)

                if player and not player:IsDead() then
                    local target = self:GetReleaseTarget(
                        tracked.playerIndex,
                        player
                    )
                    self:AssignReleaseTarget(familiar, target, true)
                    self:SetTrackedReleaseTarget(tracked, familiar.Target)

                    if self:IsValidReleaseTarget(familiar.Target) then
                        tracked.needsReacquire = false
                    end
                end
            end
        end
    end
end

function FamiliarCapacityModule:GetSpiderReleasePosition(player, target)
    if not target then
        return player.Position
    end

    local deltaX = player.Position.X - target.Position.X
    local deltaY = player.Position.Y - target.Position.Y
    local length = math.sqrt(deltaX * deltaX + deltaY * deltaY)
    local distance = math.max(0, target.Size or 0) + SPIDER_TARGET_GAP

    if length <= 0 then
        deltaX = 1
        deltaY = 0
        length = 1
    end

    local desiredPosition = Vector(
        target.Position.X + deltaX / length * distance,
        target.Position.Y + deltaY / length * distance
    )
    local room = Game():GetRoom()
    local clampedPosition = room:GetClampedPosition(desiredPosition, 20)

    return room:FindFreeTilePosition(clampedPosition, 40)
end

function FamiliarCapacityModule:AssignReleaseTarget(
    entity,
    target,
    refreshNativeState
)
    local familiar = entity and entity:ToFamiliar()

    if not familiar
        or not self:IsValidReleaseTarget(target)
    then
        return
    end

    -- Refresh native attack state only when a spider is first restored or an
    -- old target became invalid. The target comes from a shared round-robin
    -- room cache, so restored attackers split across enemies without one room
    -- scan per familiar. Stable targets are never rewritten and remain under
    -- vanilla AI control.
    if refreshNativeState then
        familiar:PickEnemyTarget(RELEASE_TARGET_DISTANCE, 1)
    end

    familiar.Target = target
end

function FamiliarCapacityModule:TryRelease(playerIndex, player, variant)
    local bank = self:GetPlayerBank(playerIndex)
    local field = variant == BLUE_FLY and "blueFlies" or "blueSpiders"

    if (bank[field] or 0) <= 0 then
        return false
    end

    local releaseRequest = {
        playerIndex = playerIndex,
        variant = variant,
        seed = nil,
        confirmed = false,
    }
    self.ActiveReleaseRequest = releaseRequest
    local target = self:GetReleaseTarget(playerIndex, player)
    local releasedEntity = nil

    if variant == BLUE_FLY then
        releasedEntity = player:AddBlueFlies(
            1,
            player.Position,
            target
        )
    else
        releasedEntity = player:AddBlueSpider(
            self:GetSpiderReleasePosition(player, target)
        )
        self:AssignReleaseTarget(releasedEntity, target, true)
    end

    self.ActiveReleaseRequest = nil

    if not releaseRequest.confirmed then
        return false
    end

    self:TrackReleasedFamiliar(releasedEntity, playerIndex)

    bank[field] = bank[field] - 1
    self.BankedCount = math.max(0, self.BankedCount - 1)
    self:MarkBankDirty()

    return true
end

function FamiliarCapacityModule:ReleaseBankedFamiliars()
    local game = Game()
    local frame = game:GetFrameCount()

    if self.NeedsRebalance then
        self:RebalanceCapacity()
    end

    if self.BankedCount <= 0 then
        return
    end

    if frame < self.NextReleaseFrame
        or game:GetRoom():GetFrameCount() < 2
    then
        return
    end

    local snapshot = self:RefreshSnapshot(true)
    local availableSlots = FAMILIAR_SOFT_LIMIT - snapshot.total

    if availableSlots <= 0 then
        self.ReleaseRetryInterval = math.min(
            BANK_BLOCKED_RETRY_MAX,
            self.ReleaseRetryInterval * 2
        )
        self.NextReleaseFrame = frame + self.ReleaseRetryInterval
        return
    end

    self.ReleaseRetryInterval = BANK_RELEASE_INTERVAL

    local playerCount = game:GetNumPlayers()

    if playerCount <= 0 then
        return
    end

    local releaseBudget = math.min(BANK_RELEASE_BATCH_SIZE, availableSlots)
    local attemptsWithoutRelease = 0

    while releaseBudget > 0 and attemptsWithoutRelease < playerCount * 2 do
        local playerIndex = self.ReleasePlayerCursor % playerCount
        local player = Isaac.GetPlayer(playerIndex)
        local preferredVariant = self.ReleaseSpiderNext
            and BLUE_SPIDER
            or BLUE_FLY
        local alternateVariant = self.ReleaseSpiderNext
            and BLUE_FLY
            or BLUE_SPIDER
        local released = false

        if player and not player:IsDead() then
            released = self:TryRelease(
                playerIndex,
                player,
                preferredVariant
            ) or self:TryRelease(
                playerIndex,
                player,
                alternateVariant
            )
        end

        self.ReleaseSpiderNext = not self.ReleaseSpiderNext
        self.ReleasePlayerCursor = (playerIndex + 1) % playerCount

        if released then
            releaseBudget = releaseBudget - 1
            attemptsWithoutRelease = 0
        else
            attemptsWithoutRelease = attemptsWithoutRelease + 1
        end
    end

    self.NextReleaseFrame = frame + BANK_RELEASE_INTERVAL
end

function FamiliarCapacityModule:SanitizeCount(value)
    if type(value) ~= "number" or value ~= value then
        return 0
    end

    return math.min(MAX_BANKED_PER_TYPE, math.max(0, math.floor(value)))
end

function FamiliarCapacityModule:LoadBank(isContinued)
    self.TemporaryBank = {}
    self.BankedCount = 0
    self.BankDirty = false
    self.BankSaveDueFrame = nil

    if not isContinued then
        return
    end

    local savedBank = self.SavedData.temporaryFamiliarBank

    if type(savedBank) ~= "table" then
        return
    end

    for playerKey, playerBank in pairs(savedBank) do
        if type(playerBank) == "table" then
            local blueFlies = self:SanitizeCount(playerBank.blueFlies)
            local blueSpiders = self:SanitizeCount(playerBank.blueSpiders)
            self.TemporaryBank[tostring(playerKey)] = {
                blueFlies = blueFlies,
                blueSpiders = blueSpiders,
            }
            self.BankedCount = self.BankedCount + blueFlies + blueSpiders
        end
    end
end

function FamiliarCapacityModule:OnGameStarted(isContinued)
    if self.UpdateCallbackRegistered then
        self.Context.Mod:RemoveCallback(
            ModCallbacks.MC_POST_UPDATE,
            self.UpdateCallback
        )
        self.UpdateCallbackRegistered = false
    end

    self.RunActive = true
    self.NeedsRebalance = false
    self.NextReleaseFrame = 0
    self.ReleaseRetryInterval = BANK_RELEASE_INTERVAL
    self.ReleasePlayerCursor = 0
    self.ReleaseSpiderNext = false
    self.RewindHistory = {}
    self.LastRoomTimeCounter = self:GetTimeCounter()
    self:ResetSnapshot()
    self:ResetPendingOverflowSpawns()
    self:ResetReleaseTracking()
    self:LoadBank(isContinued)
    self:CaptureRewindSnapshot(self.LastRoomTimeCounter)

    if self.Context:IsEnabled(SETTING_KEY) then
        self.NeedsRebalance = true
    end

    self:RefreshUpdateCallback()
end

function FamiliarCapacityModule:OnUpdate()
    if self:IsEnabled() then
        self:RetargetReleasedFamiliars()
        self:ReleaseBankedFamiliars()
        self:SaveBankIfDue()
        self:DiscardUninitializedOverflowSpawns()
    end

    self:RefreshUpdateCallback()
end

function FamiliarCapacityModule:OnNewRoom()
    if not self.RunActive then
        return
    end

    local timeCounter = self:GetTimeCounter()
    local isRewind = self.LastRoomTimeCounter ~= nil
        and timeCounter < self.LastRoomTimeCounter

    if isRewind then
        local snapshot, historyIndex = self:FindRewindSnapshot(timeCounter)

        if snapshot then
            self:RestoreRewindSnapshot(snapshot)

            for index = #self.RewindHistory, historyIndex + 1, -1 do
                self.RewindHistory[index] = nil
            end
        else
            self:ResetSnapshot()
            self:ResetPendingOverflowSpawns()
            self:ResetReleaseTargetCache()
            self.NeedsRebalance = self.Context:IsEnabled(SETTING_KEY)
        end
    else
        self:CaptureRewindSnapshot(timeCounter)
        self:ResetSnapshot()
        self:ResetPendingOverflowSpawns()
        self:ResetReleaseTargetCache()
        self.NextRetargetFrame = Game():GetFrameCount()
        self.NeedsRebalance = self.Context:IsEnabled(SETTING_KEY)
        self.ReleaseRetryInterval = BANK_RELEASE_INTERVAL
    end

    self.LastRoomTimeCounter = timeCounter
    self:RefreshUpdateCallback()
end

function FamiliarCapacityModule:OnSettingChanged(enabled)
    if not enabled and self.RunActive then
        self:ReleaseAllFamiliarPoolSlots()
    end

    self:ResetSnapshot()
    self:ResetPendingOverflowSpawns()
    self:ResetReleaseTargetCache()
    self.NextRetargetFrame = Game():GetFrameCount()
    self.NeedsRebalance = enabled and self.RunActive

    if enabled and self.RunActive then
        self.NextReleaseFrame = Game():GetFrameCount()
        self.ReleaseRetryInterval = BANK_RELEASE_INTERVAL
    end

    self:RefreshUpdateCallback()
end

function FamiliarCapacityModule:GetSaveData()
    return {
        temporaryFamiliarBank = self.TemporaryBank,
    }
end

function FamiliarCapacityModule:OnPreGameExit()
    self:ReleaseAllFamiliarPoolSlots()

    if self.UpdateCallbackRegistered then
        self.Context.Mod:RemoveCallback(
            ModCallbacks.MC_POST_UPDATE,
            self.UpdateCallback
        )
        self.UpdateCallbackRegistered = false
    end

    self.RunActive = false
    self.NeedsRebalance = false
    self.RewindHistory = {}
    self.LastRoomTimeCounter = nil
    self:ResetSnapshot()
    self:ResetPendingOverflowSpawns()
    self:ResetReleaseTracking()
end

return FamiliarCapacityModule
