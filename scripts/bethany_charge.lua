local BethanyChargeModule = {}
BethanyChargeModule.__index = BethanyChargeModule

local SETTING_KEY = "bethanySoulCharge"
local BETHANY = PlayerType.PLAYER_BETHANY
local CLICKER = CollectibleType.COLLECTIBLE_CLICKER
local MAX_SOUL_CHARGE = 99
local TORN_POCKET = TrinketType.TRINKET_TORN_POCKET

-- Only pure Soul Charge heart pickups are blocked at the cap. Blended Hearts
-- remain vanilla because they may still be collected to restore red health.
local SOUL_CHARGE_HEART_PICKUP = {
    [HeartSubType.HEART_SOUL] = true,
    [HeartSubType.HEART_BLACK] = true,
    [HeartSubType.HEART_HALF_SOUL] = true,
}

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
        RecentDamage = {},
        PendingTornPocketDebt = {},
        PendingCharacterRefresh = false,
        RunActive = false,
        UpdateCallbackRegistered = false,
    }, BethanyChargeModule)

    self.UpdateCallback = function()
        self:OnUpdate()
    end

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
        ModCallbacks.MC_PRE_PICKUP_COLLISION,
        function(_, pickup, collider)
            return self:OnPrePickupCollision(pickup, collider)
        end,
        PickupVariant.PICKUP_HEART
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_ENTITY_TAKE_DMG,
        function(_, entity)
            self:OnPlayerDamage(entity)
        end,
        EntityType.ENTITY_PLAYER
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_PICKUP_INIT,
        function(_, pickup)
            self:OnHeartPickupInit(pickup)
        end,
        PickupVariant.PICKUP_HEART
    )
    return self
end

function BethanyChargeModule:SetUpdateCallbackEnabled(enabled)
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

function BethanyChargeModule:IsBethany(player)
    return player and player:GetPlayerType() == BETHANY
end

function BethanyChargeModule:ResetTracking()
    self.TrackedCharge = {}
    self.PendingActiveBonus = {}
    self.PendingBaselineReset = {}
    self.RecentDamage = {}
    self.PendingTornPocketDebt = {}
    self.PendingCharacterRefresh = false
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
    self:SetUpdateCallbackEnabled(false)
    self.RunActive = true
    self:ResetTracking()

    if self.Context:IsEnabled(SETTING_KEY) then
        self:EstablishCurrentBaselines()
        self:SetUpdateCallbackEnabled(next(self.TrackedCharge) ~= nil)
    end
end

function BethanyChargeModule:OnPlayerDamage(entity)
    local player = entity and entity:ToPlayer()

    if not self.Context:IsEnabled(SETTING_KEY)
        or not self:IsBethany(player)
        or not player:HasTrinket(TORN_POCKET)
    then
        return
    end

    self.RecentDamage[GetPtrHash(player)] = {
        Player = player,
        ChargeBefore = player:GetSoulCharge(),
        Frame = Game():GetFrameCount(),
    }
end

function BethanyChargeModule:OnHeartPickupInit(pickup)
    if not self.Context:IsEnabled(SETTING_KEY)
        or not pickup
        or pickup.SubType ~= HeartSubType.HEART_HALF_SOUL
    then
        return
    end

    local spawner = pickup.SpawnerEntity
    local player = spawner and spawner:ToPlayer()

    if not self:IsBethany(player) or not player:HasTrinket(TORN_POCKET) then
        return
    end

    local damage = self.RecentDamage[GetPtrHash(player)]
    local frame = Game():GetFrameCount()

    if not damage or frame - damage.Frame > 1 then
        return
    end

    local currentCharge = player:GetSoulCharge()

    if currentCharge >= damage.ChargeBefore then
        return
    end

    if currentCharge > 0 then
        player:AddSoulCharge(-1)
    else
        local playerHash = GetPtrHash(player)
        self.PendingTornPocketDebt[playerHash] =
            (self.PendingTornPocketDebt[playerHash] or 0) + 1
    end

    self.TrackedCharge[GetPtrHash(player)] = player:GetSoulCharge()
    self:SetUpdateCallbackEnabled(true)
end

function BethanyChargeModule:OnPlayerInit(player)
    if self.Context:IsEnabled(SETTING_KEY) and self:IsBethany(player) then
        self.TrackedCharge[GetPtrHash(player)] = player:GetSoulCharge()
        self:SetUpdateCallbackEnabled(true)
    end
end

function BethanyChargeModule:OnUseItem(collectibleType, player)
    if not self.Context:IsEnabled(SETTING_KEY) then
        return
    end

    if collectibleType == CLICKER then
        -- Clicker can create or remove a normal Bethany without a player-init
        -- callback. Keep one update active to adopt the resulting character.
        self.PendingCharacterRefresh = true
        self:SetUpdateCallbackEnabled(true)
    end

    if not self:IsBethany(player) then
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

function BethanyChargeModule:OnPrePickupCollision(pickup, collider)
    if not pickup
        or pickup.Variant ~= PickupVariant.PICKUP_HEART
        or not SOUL_CHARGE_HEART_PICKUP[pickup.SubType]
        or not collider
        or type(collider.ToPlayer) ~= "function"
    then
        return nil
    end

    local player = collider:ToPlayer()

    if not self:IsBethany(player) then
        return nil
    end

    local enabled = self.Context:IsEnabled(SETTING_KEY)

    if enabled and player:GetSoulCharge() >= MAX_SOUL_CHARGE then
        -- MC_PRE_PICKUP_COLLISION returns true to ignore the collision, leaving
        -- the pickup available until Bethany has room for more Soul Charge.
        return true
    end

    return nil
end

function BethanyChargeModule:PayTornPocketDebt(player, playerHash)
    local debt = self.PendingTornPocketDebt[playerHash] or 0
    local payment = math.min(debt, player:GetSoulCharge())

    if payment > 0 then
        player:AddSoulCharge(-payment)
        debt = debt - payment
    end

    self.PendingTornPocketDebt[playerHash] = debt > 0 and debt or nil
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
        self.PendingTornPocketDebt[playerHash] = nil
        previousCharge = currentCharge
    end

    local activeBonus = self.PendingActiveBonus[playerHash]

    if activeBonus then
        player:AddSoulCharge(activeBonus)
        self:PayTornPocketDebt(player, playerHash)
        currentCharge = player:GetSoulCharge()
        self.TrackedCharge[playerHash] = currentCharge
        self.PendingActiveBonus[playerHash] = nil
        return
    end

    local gainedCharge = currentCharge - previousCharge

    if gainedCharge > 0 then
        player:AddSoulCharge(gainedCharge)
        self:PayTornPocketDebt(player, playerHash)
        currentCharge = player:GetSoulCharge()
    end

    self.TrackedCharge[playerHash] = currentCharge
end

function BethanyChargeModule:AdoptCurrentCharge(player)
    if self.Context:IsEnabled(SETTING_KEY) and self:IsBethany(player) then
        self.TrackedCharge[GetPtrHash(player)] = player:GetSoulCharge()
        self:SetUpdateCallbackEnabled(true)
    end
end

function BethanyChargeModule:OnUpdate()
    if not self.Context:IsEnabled(SETTING_KEY) then
        self:SetUpdateCallbackEnabled(false)
        return
    end

    local game = Game()
    local foundBethany = false

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(playerIndex)

        if self:IsBethany(player) then
            foundBethany = true
            self:SyncPlayer(player)
        else
            local playerHash = GetPtrHash(player)
            self.TrackedCharge[playerHash] = nil
            self.PendingActiveBonus[playerHash] = nil
            self.PendingBaselineReset[playerHash] = nil
            self.PendingTornPocketDebt[playerHash] = nil
        end
    end

    self.PendingCharacterRefresh = false
    self:SetUpdateCallbackEnabled(foundBethany)
end

function BethanyChargeModule:OnSettingChanged(enabled)
    self:SetUpdateCallbackEnabled(false)
    self:ResetTracking()

    if enabled then
        self:EstablishCurrentBaselines()
        self:SetUpdateCallbackEnabled(next(self.TrackedCharge) ~= nil)
    end
end

function BethanyChargeModule:OnPreGameExit()
    self:SetUpdateCallbackEnabled(false)
    self.RunActive = false
    self:ResetTracking()
end

return BethanyChargeModule
