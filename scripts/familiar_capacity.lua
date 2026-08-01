local FamiliarCapacityModule = {}
FamiliarCapacityModule.__index = FamiliarCapacityModule

local SETTING_KEY = "familiarCapacity"
local BLUE_FLY = FamiliarVariant.BLUE_FLY
local BLUE_SPIDER = FamiliarVariant.BLUE_SPIDER
local FAMILIAR_SOFT_LIMIT = 60
local FAMILIAR_COMBAT_LIMIT = 32
local FAMILIAR_HARD_LIMIT = 64
local DEBUG_DUMMY_TYPE = 964
local BANK_RELEASE_INTERVAL = 3
local BANK_BLOCKED_RETRY_MAX = 30
local BANK_RELEASE_BATCH_SIZE = 2
local BANK_ANIMATION_INTERVAL = 5
local BANK_SAVE_DELAY = 60
local MAX_BANKED_PER_TYPE = 2147483647

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
            reservedSeeds = {},
        },
        PendingOverflowSpawns = {},
        PendingOverflowCount = 0,
        TargetLimitFrame = -1,
        CachedTargetLimit = FAMILIAR_SOFT_LIMIT,
        AnimationFrames = {},
        NextReleaseFrame = 0,
        ReleaseRetryInterval = BANK_RELEASE_INTERVAL,
        ReleasePlayerCursor = 0,
        ReleaseSpiderNext = false,
        BankDirty = false,
        BankSaveDueFrame = nil,
        RunActive = false,
        NeedsRebalance = false,
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
        ModCallbacks.MC_POST_NEW_ROOM,
        function()
            self:OnNewRoom()
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_NPC_INIT,
        function()
            self:OnNPCInit()
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
        and (self.NeedsRebalance or self.BankedCount > 0 or self.BankDirty)

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
    self.Snapshot.reservedSeeds = {}
end

function FamiliarCapacityModule:ResetPendingOverflowSpawns()
    self.PendingOverflowSpawns = {}
    self.PendingOverflowCount = 0
end

function FamiliarCapacityModule:IsBankableVariant(variant)
    return variant == BLUE_FLY or variant == BLUE_SPIDER
end

function FamiliarCapacityModule:HasCombatPressure()
    local room = Game():GetRoom()

    if room:GetAliveEnemiesCount() > 0 then
        return true
    end

    -- Debug dummies do not consistently contribute to AliveEnemiesCount, but
    -- the same burst reserve is required for the documented stress test.
    for _, dummy in ipairs(Isaac.FindByType(
        DEBUG_DUMMY_TYPE,
        -1,
        -1,
        false,
        false
    )) do
        if dummy:Exists() then
            return true
        end
    end

    return false
end

function FamiliarCapacityModule:GetTargetFamiliarLimit()
    local frame = Game():GetFrameCount()

    if self.TargetLimitFrame == frame then
        return self.CachedTargetLimit
    end

    self.TargetLimitFrame = frame

    if self:HasCombatPressure() then
        self.CachedTargetLimit = FAMILIAR_COMBAT_LIMIT
    else
        self.CachedTargetLimit = FAMILIAR_SOFT_LIMIT
    end

    return self.CachedTargetLimit
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

function FamiliarCapacityModule:RefreshSnapshot(force)
    local frame = Game():GetFrameCount()

    if not force and self.Snapshot.frame == frame then
        return self.Snapshot
    end

    local total = 0
    local expendable = {}
    local familiars = Isaac.FindByType(
        EntityType.ENTITY_FAMILIAR,
        -1,
        -1,
        false,
        false
    )

    for _, entity in ipairs(familiars) do
        if entity:Exists() then
            total = total + 1

            if self:IsBankableVariant(entity.Variant) then
                expendable[#expendable + 1] = entity:ToFamiliar()
            end
        end
    end

    self.Snapshot.frame = frame
    self.Snapshot.total = total
    self.Snapshot.expendable = expendable
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

function FamiliarCapacityModule:RegisterInitializedFamiliar(familiar)
    local frame = Game():GetFrameCount()

    if self.Snapshot.frame ~= frame then
        return self:RefreshSnapshot(true)
    end

    if not self:ConsumeFamiliarReservation(familiar) then
        self.Snapshot.total = self.Snapshot.total + 1
    end

    if self:IsBankableVariant(familiar.Variant) then
        self.Snapshot.expendable[#self.Snapshot.expendable + 1] = familiar
    end

    return self.Snapshot
end

function FamiliarCapacityModule:ShouldPlayBankAnimation(playerIndex, variant)
    local frame = Game():GetFrameCount()
    local animationKey = tostring(playerIndex) .. ":" .. tostring(variant)
    local previousFrame = self.AnimationFrames[animationKey]

    if previousFrame and frame - previousFrame < BANK_ANIMATION_INTERVAL then
        return false
    end

    self.AnimationFrames[animationKey] = frame

    return true
end

function FamiliarCapacityModule:PlayBankAnimation(
    playerIndex,
    variant,
    position,
    player
)
    if not self:ShouldPlayBankAnimation(playerIndex, variant) then
        return
    end

    self:SpawnBankAnimation(position, player)
end

function FamiliarCapacityModule:SpawnBankAnimation(position, player)
    Isaac.Spawn(
        EntityType.ENTITY_EFFECT,
        EffectVariant.POOF01,
        0,
        position,
        Vector.Zero,
        player
    )
end

function FamiliarCapacityModule:QueuePendingOverflowSpawn(
    seed,
    variant,
    showAnimation,
    player
)
    if type(seed) ~= "number" or not self:IsBankableVariant(variant) then
        return false
    end

    local queue = self.PendingOverflowSpawns[seed]

    if not queue then
        queue = { head = 1, tail = 0 }
        self.PendingOverflowSpawns[seed] = queue
    end

    queue.tail = queue.tail + 1
    queue[queue.tail] = {
        variant = variant,
        showAnimation = showAnimation,
        player = player,
    }
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

    if not self:IsBankableVariant(variant) then
        -- Important familiars stay in their original native class. At the hard
        -- edge, free an already initialized expendable slot before allocation.
        if snapshot.total >= FAMILIAR_HARD_LIMIT then
            local expendable = self:FindExpendableFamiliar()

            if expendable then
                self:BankFamiliar(expendable, false)
            end
        end

        self:ReserveFamiliarSpawn(seed)
        return nil
    end

    local targetLimit = self:GetTargetFamiliarLimit()

    if snapshot.total < targetLimit then
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
    local expendable = self:FindExpendableFamiliar()

    if expendable and self:BankFamiliar(expendable, true) then
        self:ReserveFamiliarSpawn(seed)
        return nil
    end

    -- The soft limit can consist entirely of important familiars. Record this
    -- overflow now, keep the four-slot reserve, and remove the new same-class
    -- fly/spider from its init fallback. No cross-type proxy is constructed.
    if not self:AddToBank(playerIndex, variant, 1) then
        self:ReserveFamiliarSpawn(seed)
        return nil
    end

    local showAnimation = self:ShouldPlayBankAnimation(playerIndex, variant)
    self:QueuePendingOverflowSpawn(
        seed,
        variant,
        showAnimation,
        player
    )
    self:ReserveFamiliarSpawn(seed)

    return nil
end

function FamiliarCapacityModule:BankFamiliar(familiar, showAnimation)
    if not familiar or not familiar:Exists()
        or not self:IsBankableVariant(familiar.Variant)
    then
        return false
    end

    local player = self:ResolveOwner(familiar)
    local playerIndex = self:GetPlayerIndex(player)

    if not self:AddToBank(playerIndex, familiar.Variant, 1) then
        return false
    end

    local variant = familiar.Variant
    local position = familiar.Position
    familiar:Remove()
    self.Snapshot.total = math.max(0, self.Snapshot.total - 1)

    if showAnimation then
        self:PlayBankAnimation(playerIndex, variant, position, player)
    end

    return true
end

function FamiliarCapacityModule:FindExpendableFamiliar()
    for _, familiar in ipairs(self.Snapshot.expendable) do
        if familiar and familiar:Exists()
            and self:IsBankableVariant(familiar.Variant)
        then
            return familiar
        end
    end

    return nil
end

function FamiliarCapacityModule:ProtectImportantSlots()
    while self.Snapshot.total >= FAMILIAR_HARD_LIMIT do
        local expendable = self:FindExpendableFamiliar()

        if not expendable or not self:BankFamiliar(expendable, false) then
            break
        end
    end
end

function FamiliarCapacityModule:OnFamiliarInit(familiar)
    if not self:IsEnabled() then
        return
    end

    local pending = self:IsBankableVariant(familiar.Variant)
        and self:ConsumePendingOverflowSpawn(
            familiar.InitSeed,
            familiar.Variant
        )
        or nil
    self:RegisterInitializedFamiliar(familiar)

    if pending then
        local position = familiar.Position
        familiar:Remove()
        self.Snapshot.total = math.max(0, self.Snapshot.total - 1)

        if pending.showAnimation then
            self:SpawnBankAnimation(position, pending.player)
        end

        return
    end

    if self:IsBankableVariant(familiar.Variant) then
        -- Reservations for queued overflow are already included in total and
        -- will be removed by their own init callbacks. Exclude those future
        -- removals so an earlier allowed familiar is not banked as well.
        if self.Snapshot.total - self.PendingOverflowCount
            > self:GetTargetFamiliarLimit()
        then
            self:BankFamiliar(familiar, true)
        end

        return
    end

    self:ProtectImportantSlots()
end

function FamiliarCapacityModule:RebalanceCapacity()
    self:RefreshSnapshot(true)
    local targetLimit = self:GetTargetFamiliarLimit()

    while self.Snapshot.total > targetLimit do
        local expendable = self:FindExpendableFamiliar()

        if not expendable or not self:BankFamiliar(expendable, false) then
            break
        end
    end

    self.NeedsRebalance = false
end

function FamiliarCapacityModule:TryRelease(playerIndex, player, variant)
    local bank = self:GetPlayerBank(playerIndex)
    local field = variant == BLUE_FLY and "blueFlies" or "blueSpiders"

    if (bank[field] or 0) <= 0 then
        return false
    end

    bank[field] = bank[field] - 1
    self.BankedCount = math.max(0, self.BankedCount - 1)
    self:MarkBankDirty()

    if variant == BLUE_FLY then
        player:AddBlueFlies(1, player.Position, nil)
    else
        player:AddBlueSpider(player.Position)
    end

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
    local targetLimit = self:GetTargetFamiliarLimit()
    local availableSlots = targetLimit - snapshot.total

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
    self.AnimationFrames = {}
    self.TargetLimitFrame = -1
    self:ResetSnapshot()
    self:ResetPendingOverflowSpawns()
    self:LoadBank(isContinued)

    if self.Context:IsEnabled(SETTING_KEY) then
        self.NeedsRebalance = true
    end

    self:RefreshUpdateCallback()
end

function FamiliarCapacityModule:OnUpdate()
    if self:IsEnabled() then
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

    self:ResetSnapshot()
    self:ResetPendingOverflowSpawns()
    self.AnimationFrames = {}
    self.TargetLimitFrame = -1
    self.NeedsRebalance = self.Context:IsEnabled(SETTING_KEY)
    self.ReleaseRetryInterval = BANK_RELEASE_INTERVAL
    self:RefreshUpdateCallback()
end

function FamiliarCapacityModule:OnNPCInit()
    if not self:IsEnabled() then
        return
    end

    -- New combat pressure can appear after MC_POST_NEW_ROOM (including debug
    -- dummies). Rebalance on the next normal update before attacks begin.
    self.TargetLimitFrame = -1
    self.NeedsRebalance = true
    self:RefreshUpdateCallback()
end

function FamiliarCapacityModule:OnSettingChanged(enabled)
    self:ResetSnapshot()
    self:ResetPendingOverflowSpawns()
    self.AnimationFrames = {}
    self.TargetLimitFrame = -1
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
    if self.UpdateCallbackRegistered then
        self.Context.Mod:RemoveCallback(
            ModCallbacks.MC_POST_UPDATE,
            self.UpdateCallback
        )
        self.UpdateCallbackRegistered = false
    end

    self.RunActive = false
    self.NeedsRebalance = false
    self:ResetSnapshot()
    self:ResetPendingOverflowSpawns()
end

return FamiliarCapacityModule
