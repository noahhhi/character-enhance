local FamiliarCapacityModule = {}
FamiliarCapacityModule.__index = FamiliarCapacityModule

local SETTING_KEY = "familiarCapacity"
local BLUE_FLY = FamiliarVariant.BLUE_FLY
local BLUE_SPIDER = FamiliarVariant.BLUE_SPIDER
local FAMILIAR_SOFT_LIMIT = 60
local FAMILIAR_HARD_LIMIT = 64
local BANK_RELEASE_INTERVAL = 3
local BANK_RELEASE_BATCH_SIZE = 2
local BANK_ANIMATION_INTERVAL = 5
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
        },
        AnimationFrames = {},
        NextReleaseFrame = 0,
        ReleasePlayerCursor = 0,
        ReleaseSpiderNext = false,
        RunActive = false,
        NeedsRebalance = false,
    }, FamiliarCapacityModule)

    context.Mod:AddCallback(
        ModCallbacks.MC_POST_GAME_STARTED,
        function(_, isContinued)
            self:OnGameStarted(isContinued)
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_FAMILIAR_INIT,
        function(_, familiar)
            self:OnFamiliarInit(familiar)
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_UPDATE,
        function()
            self:OnUpdate()
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

function FamiliarCapacityModule:IsEnabled()
    return self.RunActive and self.Context:IsEnabled(SETTING_KEY)
end

function FamiliarCapacityModule:ResetSnapshot()
    self.Snapshot.frame = -1
    self.Snapshot.total = 0
    self.Snapshot.expendable = {}
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

function FamiliarCapacityModule:ResolveOwner(familiar)
    if familiar.Player then
        return familiar.Player
    end

    local source = familiar.SpawnerEntity or familiar.Parent

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

    return self.Snapshot
end


function FamiliarCapacityModule:RegisterInitializedFamiliar(familiar)
    local frame = Game():GetFrameCount()

    if self.Snapshot.frame ~= frame then
        return self:RefreshSnapshot(true)
    end

    self.Snapshot.total = self.Snapshot.total + 1

    if self:IsBankableVariant(familiar.Variant) then
        self.Snapshot.expendable[#self.Snapshot.expendable + 1] = familiar
    end

    return self.Snapshot
end

function FamiliarCapacityModule:PlayBankAnimation(
    playerIndex,
    variant,
    position,
    player
)
    local frame = Game():GetFrameCount()
    local animationKey = tostring(playerIndex) .. ":" .. tostring(variant)
    local previousFrame = self.AnimationFrames[animationKey]

    if previousFrame and frame - previousFrame < BANK_ANIMATION_INTERVAL then
        return
    end

    self.AnimationFrames[animationKey] = frame
    Isaac.Spawn(
        EntityType.ENTITY_EFFECT,
        EffectVariant.POOF01,
        0,
        position,
        Vector.Zero,
        player
    )
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
        self.NextReleaseFrame = frame + BANK_RELEASE_INTERVAL
        return
    end

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
    self.RunActive = true
    self.NeedsRebalance = false
    self.NextReleaseFrame = 0
    self.ReleasePlayerCursor = 0
    self.ReleaseSpiderNext = false
    self.AnimationFrames = {}
    self:ResetSnapshot()
    self:LoadBank(isContinued)

    if self.Context:IsEnabled(SETTING_KEY) then
        self.NeedsRebalance = true
    end
end

function FamiliarCapacityModule:OnUpdate()
    if self:IsEnabled() then
        self:ReleaseBankedFamiliars()
    end
end

function FamiliarCapacityModule:OnNewRoom()
    if not self.RunActive then
        return
    end

    self:ResetSnapshot()
    self.AnimationFrames = {}
    self.NeedsRebalance = self.Context:IsEnabled(SETTING_KEY)
end

function FamiliarCapacityModule:OnSettingChanged(enabled)
    self:ResetSnapshot()
    self.AnimationFrames = {}
    self.NeedsRebalance = enabled and self.RunActive

    if enabled and self.RunActive then
        self.NextReleaseFrame = Game():GetFrameCount()
    end
end

function FamiliarCapacityModule:GetSaveData()
    return {
        temporaryFamiliarBank = self.TemporaryBank,
    }
end

function FamiliarCapacityModule:OnPreGameExit()
    self.RunActive = false
    self.NeedsRebalance = false
    self:ResetSnapshot()
end

return FamiliarCapacityModule
