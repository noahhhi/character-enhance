local TaintedBlueBabyPoopCapacityModule = {}
TaintedBlueBabyPoopCapacityModule.__index = TaintedBlueBabyPoopCapacityModule

local SETTING_KEY = "taintedBlueBabyPoopCapacity"
local TAINTED_BLUE_BABY = PlayerType.PLAYER_BLUEBABY_B
local POOP_PICKUP = PickupVariant.PICKUP_POOP

function TaintedBlueBabyPoopCapacityModule.New(context)
    local self = setmetatable({
        Context = context,
    }, TaintedBlueBabyPoopCapacityModule)

    context.Mod:AddCallback(
        ModCallbacks.MC_PRE_PICKUP_COLLISION,
        function(_, pickup, collider)
            return self:OnPrePickupCollision(pickup, collider)
        end,
        POOP_PICKUP
    )

    return self
end

function TaintedBlueBabyPoopCapacityModule:OnPrePickupCollision(
    pickup,
    collider
)
    if not self.Context:IsEnabled(SETTING_KEY)
        or not pickup
        or pickup.Variant ~= POOP_PICKUP
        or not collider
        or type(collider.ToPlayer) ~= "function"
    then
        return nil
    end

    local player = collider:ToPlayer()

    if not player or player:GetPlayerType() ~= TAINTED_BLUE_BABY then
        return nil
    end

    if player:GetPoopMana() >= player:GetMaxPoopMana() then
        -- Preserve the physical collision but skip vanilla pickup handling so
        -- both pickup sizes remain available after a queued poop is used.
        return false
    end

    return nil
end

return TaintedBlueBabyPoopCapacityModule
