local HeldItemProtectionModule = {}
HeldItemProtectionModule.__index = HeldItemProtectionModule

local SETTING_KEY = "heldItemProtection"
local FLOOR_RESET_ITEMS = {
    [CollectibleType.COLLECTIBLE_R_KEY] = true,
    [CollectibleType.COLLECTIBLE_FORGET_ME_NOW] = true,
}

function HeldItemProtectionModule.New(context)
    local self = setmetatable({
        Context = context,
    }, HeldItemProtectionModule)

    context.Mod:AddCallback(
        ModCallbacks.MC_PRE_USE_ITEM,
        function(_, collectibleType)
            self:OnPreUseItem(collectibleType)
        end
    )

    return self
end

function HeldItemProtectionModule:FlushAllQueuedItems()
    local game = Game()

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(playerIndex)

        if player then
            -- FlushQueueItem is the vanilla completion path for the held-item
            -- queue. Running it before a floor/run replacement prevents the
            -- queued collectible from being discarded with the old level.
            player:FlushQueueItem()
        end
    end
end

function HeldItemProtectionModule:OnPreUseItem(collectibleType)
    if self.Context:IsEnabled(SETTING_KEY)
        and FLOOR_RESET_ITEMS[collectibleType]
    then
        self:FlushAllQueuedItems()
    end
end

return HeldItemProtectionModule
