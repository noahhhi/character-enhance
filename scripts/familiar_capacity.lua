local FamiliarCapacityModule = {}
FamiliarCapacityModule.__index = FamiliarCapacityModule

local SETTING_KEY = "familiarCapacity"
local BLUE_FLY = FamiliarVariant.BLUE_FLY
local BLUE_SPIDER = FamiliarVariant.BLUE_SPIDER
local FAMILIAR_SOFT_LIMIT = 60
local FAMILIAR_HARD_LIMIT = 64
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

    -- Removing overflow in MC_FAMILIAR_INIT is too late for the engine's fixed
    -- 64-entry familiar pool: allocation and destructive slot overwrite have
    -- already happened. Run late in the pre-spawn chain so owned expendable
    -- familiars can be redirected before they ever request a familiar slot.
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

function FamiliarCapacityModule:IsBankableVariant(variant)
    return variant == BLUE_FLY or variant == BLUE_SPIDER
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

    Isaac.Spawn(
        EntityType.ENTITY_EFFECT,
        EffectVariant.POOF01,
        0,
        position,
        Vector.Zero,
        player
    )
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

    if not self:IsBankableVariant(variant)
        or snapshot.total < FAMILIAR_SOFT_LIMIT
    then
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
    if not self:AddToBank(playerIndex, variant, 1) then
        self:ReserveFamiliarSpawn(seed)
        return nil
    end

    local effectVariant = EffectVariant.EFFECT_NULL

    if self:ShouldPlayBankAnimation(playerIndex, variant) then
        effectVariant = EffectVariant.POOF01
    end

    -- MC_PRE_ENTITY_SPAWN cannot cancel a spawn. Redirecting to an effect keeps
    -- the attempt out of the fixed familiar pool; EFFECT_NULL coalesces the
    -- visual spam between the deliberately throttled POOF01 replacements.
    return {
        EntityType.ENTITY_EFFECT,
        effectVariant,
        0,
        seed,
    }
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

    self:RegisterInitializedFamiliar(familiar)

    if self:IsBankableVariant(familiar.Variant) then
        if self.Snapshot.total > FAMILIAR_SOFT_LIMIT then
            self:BankFamiliar(familiar, true)
        end

        return
    end

    self:ProtectImportantSlots()
end

function FamiliarCapacityModule:RebalanceCapacity()
    self:RefreshSnapshot(true)

    while self.Snapshot.total > FAMILIAR_SOFT_LIMIT do
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
    self.AnimationFrames = {}
    self:ResetSnapshot()
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
    end

    self:RefreshUpdateCallback()
end

function FamiliarCapacityModule:OnNewRoom()
    if not self.RunActive then
        return
    end

    self:ResetSnapshot()
    self.AnimationFrames = {}
    self.NeedsRebalance = self.Context:IsEnabled(SETTING_KEY)
    self.ReleaseRetryInterval = BANK_RELEASE_INTERVAL
    self:RefreshUpdateCallback()
end

function FamiliarCapacityModule:OnSettingChanged(enabled)
    self:ResetSnapshot()
    self.AnimationFrames = {}
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
end

return FamiliarCapacityModule
