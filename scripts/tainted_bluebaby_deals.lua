local TaintedBlueBabyDealsModule = {}
TaintedBlueBabyDealsModule.__index = TaintedBlueBabyDealsModule

local SETTING_KEY = "taintedBlueBabyDevilDeals"
local TAINTED_BLUE_BABY = PlayerType.PLAYER_BLUEBABY_B
local COLLECTIBLE = PickupVariant.PICKUP_COLLECTIBLE
local THREE_SOUL_HEARTS = PickupPrice.PRICE_THREE_SOULHEARTS
local ONE_SOUL_HEART = PickupPrice.PRICE_ONE_SOUL_HEART
local TWO_SOUL_HEARTS = PickupPrice.PRICE_TWO_SOUL_HEARTS
local HEALTH_PRICES = {
    [PickupPrice.PRICE_ONE_HEART] = true,
    [PickupPrice.PRICE_TWO_HEARTS] = true,
    [PickupPrice.PRICE_THREE_SOULHEARTS] = true,
    [PickupPrice.PRICE_ONE_HEART_AND_TWO_SOULHEARTS] = true,
    [PickupPrice.PRICE_ONE_HEART_AND_ONE_SOUL_HEART] = true,
}
local STATE_KEY = "CharacterEnhanceTaintedBlueBabyDealPrice"

function TaintedBlueBabyDealsModule.New(context)
    local self = setmetatable({
        Context = context,
        ItemConfig = Isaac.GetItemConfig(),
    }, TaintedBlueBabyDealsModule)

    context.Mod:AddCallback(
        ModCallbacks.MC_POST_PICKUP_UPDATE,
        function(_, pickup)
            self:OnPickupUpdate(pickup)
        end,
        COLLECTIBLE
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_PRE_PICKUP_COLLISION,
        function(_, pickup, collider)
            self:OnPrePickupCollision(pickup, collider)
        end,
        COLLECTIBLE
    )

    return self
end

function TaintedBlueBabyDealsModule:HasOnlyTaintedBlueBabies()
    local game = Game()
    local foundTarget = false

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(playerIndex)

        if player then
            if player:GetPlayerType() ~= TAINTED_BLUE_BABY then
                return false
            end

            foundTarget = true
        end
    end

    return foundTarget
end

function TaintedBlueBabyDealsModule:GetSoulHeartPrice(pickup)
    if pickup.Variant ~= COLLECTIBLE then
        return nil
    end

    local item = self.ItemConfig:GetCollectible(pickup.SubType)
    local devilPrice = item and item.DevilPrice

    if devilPrice == 1 or devilPrice == PickupPrice.PRICE_ONE_HEART then
        return ONE_SOUL_HEART
    end

    if devilPrice == 2 or devilPrice == PickupPrice.PRICE_TWO_HEARTS then
        return TWO_SOUL_HEARTS
    end

    return nil
end

function TaintedBlueBabyDealsModule:RestorePrice(pickup)
    local data = pickup:GetData()
    local state = data[STATE_KEY]

    if not state then
        return
    end

    if pickup.Price == state.appliedPrice then
        pickup.Price = state.originalPrice
    end

    data[STATE_KEY] = nil
end

function TaintedBlueBabyDealsModule:ApplyPrice(pickup)
    local soulHeartPrice = self:GetSoulHeartPrice(pickup)

    if not soulHeartPrice then
        self:RestorePrice(pickup)
        return
    end

    local data = pickup:GetData()
    local state = data[STATE_KEY]

    if state then
        local stillOwned = pickup.Price == state.appliedPrice
            or pickup.Price == state.originalPrice

        if not stillOwned then
            -- Another price effect took ownership after this module. Preserve it.
            data[STATE_KEY] = nil
            return
        end

        state.appliedPrice = soulHeartPrice
        pickup.Price = soulHeartPrice
        return
    end

    if not HEALTH_PRICES[pickup.Price] then
        return
    end

    data[STATE_KEY] = {
        originalPrice = pickup.Price,
        appliedPrice = soulHeartPrice,
    }
    pickup.Price = soulHeartPrice
end

function TaintedBlueBabyDealsModule:OnPickupUpdate(pickup)
    local state = pickup:GetData()[STATE_KEY]

    -- Vanilla Tainted Blue Baby deals are the only unowned pedestals that can
    -- need adjustment. Avoid a co-op player scan for ordinary room, shop and
    -- already adjusted collectible pedestals on every pickup-update frame.
    if not state and pickup.Price ~= THREE_SOUL_HEARTS then
        return
    end

    if self.Context:IsEnabled(SETTING_KEY)
        and self:HasOnlyTaintedBlueBabies()
    then
        self:ApplyPrice(pickup)
    else
        self:RestorePrice(pickup)
    end
end

function TaintedBlueBabyDealsModule:OnPrePickupCollision(pickup, collider)
    local player = collider and collider:ToPlayer()

    if not player then
        return
    end

    if self.Context:IsEnabled(SETTING_KEY)
        and player:GetPlayerType() == TAINTED_BLUE_BABY
    then
        self:ApplyPrice(pickup)
    else
        -- Pedestal prices are shared in co-op. Restore the exact prior price
        -- before another character buys so only Tainted Blue Baby gets it.
        self:RestorePrice(pickup)
    end
end

return TaintedBlueBabyDealsModule
