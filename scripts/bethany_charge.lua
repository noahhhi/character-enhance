local BethanyChargeModule = {}
BethanyChargeModule.__index = BethanyChargeModule

local SETTING_KEY = "bethanySoulCharge"
local BETHANY = PlayerType.PLAYER_BETHANY

-- These active items grant Soul/Black Hearts directly instead of spawning a
-- pickup. The value is the extra Soul Charge needed for the doubled grant.
local DIRECT_SOUL_CHARGE_ACTIVE_BONUS = {
    [CollectibleType.COLLECTIBLE_BOOK_OF_REVELATIONS] = 2,
    [CollectibleType.COLLECTIBLE_THE_NAIL] = 2,
    [CollectibleType.COLLECTIBLE_SATANIC_BIBLE] = 2,
    [CollectibleType.COLLECTIBLE_GUPPYS_PAW] = 6,
}

-- These items restore or replace player state. Previously earned charge must
-- become the new baseline instead of being doubled for a second time.
local CHARGE_BASELINE_RESET_ACTIVE = {
    [CollectibleType.COLLECTIBLE_GLOWING_HOUR_GLASS] = true,
    [CollectibleType.COLLECTIBLE_GENESIS] = true,
    [CollectibleType.COLLECTIBLE_R_KEY] = true,
}

function BethanyChargeModule.New(context)
    local self = setmetatable({
        Context = context,
        TrackedCharge = {},
        PendingActiveBonus = {},
        PendingBaselineReset = {},
        RunActive = false,
    }, BethanyChargeModule)

    context.Mod:AddCallback(
        ModCallbacks.MC_POST_GAME_STARTED,
        function()
            self:OnGameStarted()
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_PLAYER_INIT,
        function(_, player)
            self:OnPlayerInit(player)
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_USE_ITEM,
        function(_, collectibleType, _, player)
            self:OnUseItem(collectibleType, player)
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_UPDATE,
        function()
            self:OnUpdate()
        end
    )

    return self
end

function BethanyChargeModule:IsBethany(player)
    return player and player:GetPlayerType() == BETHANY
end

function BethanyChargeModule:ResetTracking()
    self.TrackedCharge = {}
    self.PendingActiveBonus = {}
    self.PendingBaselineReset = {}
end

function BethanyChargeModule:EstablishCurrentBaselines()
    if not self.RunActive then
        return
    end

    local game = Game()

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(playerIndex)

        if self:IsBethany(player) then
            self.TrackedCharge[GetPtrHash(player)] = player:GetSoulCharge()
        end
    end
end

function BethanyChargeModule:OnGameStarted()
    self.RunActive = true
    self:ResetTracking()

    if self.Context:IsEnabled(SETTING_KEY) then
        self:EstablishCurrentBaselines()
    end
end

function BethanyChargeModule:OnPlayerInit(player)
    if self.Context:IsEnabled(SETTING_KEY) and self:IsBethany(player) then
        self.TrackedCharge[GetPtrHash(player)] = player:GetSoulCharge()
    end
end

function BethanyChargeModule:OnUseItem(collectibleType, player)
    if not self.Context:IsEnabled(SETTING_KEY) or not self:IsBethany(player) then
        return
    end

    local playerHash = GetPtrHash(player)
    local directBonus = DIRECT_SOUL_CHARGE_ACTIVE_BONUS[collectibleType]

    if directBonus then
        self.PendingActiveBonus[playerHash] =
            (self.PendingActiveBonus[playerHash] or 0) + directBonus
    end

    if CHARGE_BASELINE_RESET_ACTIVE[collectibleType] then
        self.PendingBaselineReset[playerHash] = true
    end
end

function BethanyChargeModule:SyncPlayer(player)
    if not self.Context:IsEnabled(SETTING_KEY) or not self:IsBethany(player) then
        return
    end

    local playerHash = GetPtrHash(player)
    local currentCharge = player:GetSoulCharge()
    local previousCharge = self.TrackedCharge[playerHash]

    if previousCharge == nil then
        self.TrackedCharge[playerHash] = currentCharge
        return
    end

    if self.PendingBaselineReset[playerHash] then
        self.TrackedCharge[playerHash] = currentCharge
        self.PendingBaselineReset[playerHash] = nil
        previousCharge = currentCharge
    end

    local activeBonus = self.PendingActiveBonus[playerHash]

    if activeBonus then
        player:AddSoulCharge(activeBonus)
        currentCharge = player:GetSoulCharge()
        self.TrackedCharge[playerHash] = currentCharge
        self.PendingActiveBonus[playerHash] = nil
        return
    end

    local gainedCharge = currentCharge - previousCharge

    if gainedCharge > 0 then
        player:AddSoulCharge(gainedCharge)
        currentCharge = player:GetSoulCharge()
    end

    self.TrackedCharge[playerHash] = currentCharge
end

function BethanyChargeModule:AdoptCurrentCharge(player)
    if self.Context:IsEnabled(SETTING_KEY) and self:IsBethany(player) then
        self.TrackedCharge[GetPtrHash(player)] = player:GetSoulCharge()
    end
end

function BethanyChargeModule:OnUpdate()
    if not self.Context:IsEnabled(SETTING_KEY) then
        return
    end

    local game = Game()

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(playerIndex)

        if self:IsBethany(player) then
            self:SyncPlayer(player)
        else
            local playerHash = GetPtrHash(player)
            self.TrackedCharge[playerHash] = nil
            self.PendingActiveBonus[playerHash] = nil
            self.PendingBaselineReset[playerHash] = nil
        end
    end
end

function BethanyChargeModule:OnSettingChanged(enabled)
    self:ResetTracking()

    if enabled then
        self:EstablishCurrentBaselines()
    end
end

function BethanyChargeModule:OnPreGameExit()
    self.RunActive = false
    self:ResetTracking()
end

return BethanyChargeModule
