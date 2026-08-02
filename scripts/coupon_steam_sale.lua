local CouponSteamSaleModule = {}
CouponSteamSaleModule.__index = CouponSteamSaleModule

local SETTING_KEY = "couponSteamSale"
local STATE_KEY = "CharacterEnhanceCouponShopPrice"
local COUPON = CollectibleType.COLLECTIBLE_COUPON
local STEAM_SALE = CollectibleType.COLLECTIBLE_STEAM_SALE
local VANILLA_MAX_CHARGES = 6
local ACTIVE_SLOTS = {
    ActiveSlot.SLOT_PRIMARY,
    ActiveSlot.SLOT_SECONDARY,
    ActiveSlot.SLOT_POCKET,
    ActiveSlot.SLOT_POCKET2,
}
local STANDARD_PICKUP_PRICES = {
    [PickupVariant.PICKUP_BOMB] = 5,
    [PickupVariant.PICKUP_KEY] = 5,
    [PickupVariant.PICKUP_TAROTCARD] = 5,
    [PickupVariant.PICKUP_PILL] = 5,
    [PickupVariant.PICKUP_LIL_BATTERY] = 5,
    [PickupVariant.PICKUP_GRAB_BAG] = 7,
}
local RED_HEART_SUBTYPES = {
    [HeartSubType.HEART_FULL] = true,
    [HeartSubType.HEART_HALF] = true,
    [HeartSubType.HEART_SCARED] = true,
}

function CouponSteamSaleModule.New(context)
    local self = setmetatable({
        Context = context,
        RunActive = false,
        CachedFrame = nil,
        CachedCouponCount = 0,
        CachedSteamSaleCount = 0,
    }, CouponSteamSaleModule)

    context.Mod:AddCallback(
        ModCallbacks.MC_POST_GAME_STARTED,
        function()
            self:OnGameStarted()
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_PICKUP_UPDATE,
        function(_, pickup)
            self:OnPickupUpdate(pickup)
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_PRE_SPAWN_CLEAN_AWARD,
        function()
            self:OnPreSpawnCleanAward()
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_NEW_ROOM,
        function()
            self:InvalidateDiscountCounts()
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_PRE_MOD_UNLOAD,
        function()
            self:OnModUnload()
        end
    )

    return self
end

function CouponSteamSaleModule:InvalidateDiscountCounts()
    self.CachedFrame = nil
end

function CouponSteamSaleModule:GetDiscountCounts()
    local game = Game()
    local frame = game:GetFrameCount()

    if self.CachedFrame == frame then
        return self.CachedCouponCount, self.CachedSteamSaleCount
    end

    local couponCount = 0
    local steamSaleCount = 0

    if self.RunActive then
        for playerIndex = 0, game:GetNumPlayers() - 1 do
            local player = Isaac.GetPlayer(playerIndex)

            if not player:IsDead() then
                steamSaleCount = steamSaleCount
                    + math.max(0, player:GetCollectibleNum(STEAM_SALE, true))

                for _, activeSlot in ipairs(ACTIVE_SLOTS) do
                    if player:GetActiveItem(activeSlot) == COUPON then
                        couponCount = couponCount + 1
                    end
                end
            end
        end
    end

    self.CachedFrame = frame
    self.CachedCouponCount = couponCount
    self.CachedSteamSaleCount = steamSaleCount
    return couponCount, steamSaleCount
end

function CouponSteamSaleModule:GetStandardPrice(pickup)
    if pickup.Variant == PickupVariant.PICKUP_COLLECTIBLE then
        local item = Isaac.GetItemConfig():GetCollectible(pickup.SubType)
        local shopPrice = item and item.ShopPrice

        if type(shopPrice) == "number" and shopPrice > 0 then
            return shopPrice
        end

        return 15
    end

    if pickup.Variant == PickupVariant.PICKUP_HEART then
        return RED_HEART_SUBTYPES[pickup.SubType] and 3 or 5
    end

    return STANDARD_PICKUP_PRICES[pickup.Variant]
end

function CouponSteamSaleModule:GetInitialBasePrice(pickup)
    local standardPrice = self:GetStandardPrice(pickup)

    if not standardPrice then
        return pickup.Price
    end

    -- Natural sales and Coupon's vanilla one-product sale are below the
    -- standard price. Restock and other price increases remain authoritative.
    return math.max(standardPrice, pickup.Price)
end

function CouponSteamSaleModule:CalculatePrice(
    basePrice,
    discountCount,
    roundsFirstDiscountDown
)
    if discountCount <= 0 then
        return basePrice
    end

    local price

    if roundsFirstDiscountDown then
        price = math.floor(basePrice / 2)
    else
        price = math.ceil(basePrice / 2)
    end

    price = math.max(1, price)

    -- Repentance stacks further Steam Sales incrementally rather than making
    -- two copies free: 15 -> 7 -> 5 -> 4. Coupon copies follow that rule.
    for copyCount = 2, discountCount do
        price = math.max(1, math.ceil(price * copyCount / (copyCount + 1)))
    end

    return price
end

function CouponSteamSaleModule:RoundsFirstDiscountDown(pickup)
    return pickup.Variant == PickupVariant.PICKUP_COLLECTIBLE
        or pickup.Variant == PickupVariant.PICKUP_GRAB_BAG
end

function CouponSteamSaleModule:RestorePrice(pickup)
    local data = pickup:GetData()
    local state = data[STATE_KEY]

    if not state then
        return
    end

    if pickup.Price == state.appliedPrice then
        pickup.Price = state.nativePrice
    end

    pickup.AutoUpdatePrice = state.autoUpdatePrice
    data[STATE_KEY] = nil
end

function CouponSteamSaleModule:ApplyPrice(
    pickup,
    couponCount,
    steamSaleCount
)
    if pickup.Price <= 0 or not pickup:IsShopItem() then
        self:RestorePrice(pickup)
        return
    end

    local data = pickup:GetData()
    local state = data[STATE_KEY]

    if not state then
        state = {
            basePrice = self:GetInitialBasePrice(pickup),
            nativePrice = pickup.Price,
            nativeSaleCount = steamSaleCount,
            autoUpdatePrice = pickup.AutoUpdatePrice,
        }
        data[STATE_KEY] = state
    elseif state.nativeSaleCount ~= steamSaleCount then
        state.nativeSaleCount = steamSaleCount
        state.nativePrice = self:CalculatePrice(
            state.basePrice,
            steamSaleCount,
            self:RoundsFirstDiscountDown(pickup)
        )
    elseif pickup.Price ~= state.appliedPrice
        and pickup.Price ~= state.nativePrice
    then
        -- A later native or modded price change owns the new baseline. Stack
        -- Coupon on top of it instead of restoring an obsolete value.
        state.basePrice = pickup.Price
        state.nativePrice = pickup.Price
    end

    local appliedPrice = self:CalculatePrice(
        state.basePrice,
        steamSaleCount + couponCount,
        self:RoundsFirstDiscountDown(pickup)
    )

    state.appliedPrice = appliedPrice
    pickup.AutoUpdatePrice = false
    pickup.Price = appliedPrice
end

function CouponSteamSaleModule:OnPickupUpdate(pickup)
    local couponCount, steamSaleCount = self:GetDiscountCounts()

    if not self.Context:IsEnabled(SETTING_KEY) or couponCount <= 0 then
        self:RestorePrice(pickup)
        return
    end

    self:ApplyPrice(pickup, couponCount, steamSaleCount)
end

function CouponSteamSaleModule:RestoreAllPrices()
    if not self.RunActive then
        return
    end

    for _, entity in ipairs(Isaac.FindByType(EntityType.ENTITY_PICKUP)) do
        local pickup = entity:ToPickup()

        if pickup then
            self:RestorePrice(pickup)
        end
    end
end

function CouponSteamSaleModule:OnGameStarted()
    self.RunActive = true
    self:InvalidateDiscountCounts()
end

function CouponSteamSaleModule:OnPreSpawnCleanAward()
    if not self.RunActive or not self.Context:IsEnabled(SETTING_KEY) then
        return
    end

    local game = Game()

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(playerIndex)

        if not player:IsDead() then
            for _, activeSlot in ipairs(ACTIVE_SLOTS) do
                if player:GetActiveItem(activeSlot) == COUPON then
                    local charge = player:GetActiveCharge(activeSlot)

                    if charge < VANILLA_MAX_CHARGES then
                        -- Vanilla supplies the normal one room charge. This
                        -- extra point makes the six-point Coupon fill in three
                        -- cleared rooms without changing direct battery gains.
                        player:SetActiveCharge(
                            math.min(VANILLA_MAX_CHARGES, charge + 1),
                            activeSlot
                        )
                    end
                end
            end
        end
    end
end

function CouponSteamSaleModule:OnSettingChanged()
    self:InvalidateDiscountCounts()

    if not self.Context:IsEnabled(SETTING_KEY) then
        self:RestoreAllPrices()
    end
end

function CouponSteamSaleModule:OnPreGameExit()
    self:RestoreAllPrices()
    self.RunActive = false
end

function CouponSteamSaleModule:OnModUnload()
    self:RestoreAllPrices()
end

return CouponSteamSaleModule
