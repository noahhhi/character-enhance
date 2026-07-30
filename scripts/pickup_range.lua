local PickupRangeModule = {}
PickupRangeModule.__index = PickupRangeModule

local ENTITY_PICKUP = EntityType.ENTITY_PICKUP
local NORMAL_SCALE = 1
local EPSILON = 0.001

local function IsFinitePositive(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
        and value > 0
end

local function GetPickupCompensation(player)
    if not player or (player.IsDead and player:IsDead())
        or not IsFinitePositive(player.Size)
    then
        return 0
    end

    local spriteScale = player.SpriteScale

    if not spriteScale
        or not IsFinitePositive(spriteScale.X)
        or not IsFinitePositive(spriteScale.Y)
    then
        return 0
    end

    local scale = math.min(spriteScale.X, spriteScale.Y)

    if scale >= NORMAL_SCALE - EPSILON then
        return 0
    end

    -- Vanilla's player collision radius and SpriteScale follow the same size
    -- stat. Recover the unscaled radius, then add only the missing portion to
    -- pickups; the player's own collision body is never changed.
    return math.max(0, player.Size / scale - player.Size)
end

function PickupRangeModule.New(context)
    local self = setmetatable({
        Context = context,
        Compensation = 0,
        ManagedPickups = setmetatable({}, { __mode = "k" }),
    }, PickupRangeModule)

    context.Mod:AddCallback(
        ModCallbacks.MC_EVALUATE_CACHE,
        function(_, player)
            self:RefreshCompensation(player)
        end,
        CacheFlag.CACHE_SIZE
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_PICKUP_INIT,
        function(_, pickup)
            self:ApplyToPickup(pickup)
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_NEW_ROOM,
        function()
            self:RefreshAll()
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_GAME_STARTED,
        function()
            self:RefreshAll()
        end
    )

    self:RefreshAll()
    return self
end

function PickupRangeModule:RestorePickup(pickup, state)
    if math.abs(pickup.Size - state.appliedSize) <= EPSILON then
        pickup.Size = state.baseSize
    end

    self.ManagedPickups[pickup] = nil
end

function PickupRangeModule:RestoreAll()
    for pickup, state in pairs(self.ManagedPickups) do
        if pickup and IsFinitePositive(pickup.Size) then
            self:RestorePickup(pickup, state)
        else
            self.ManagedPickups[pickup] = nil
        end
    end
end

function PickupRangeModule:CalculateCompensation()
    local compensation = 0
    local playerCount = Game():GetNumPlayers()

    for playerIndex = 0, playerCount - 1 do
        compensation = math.max(
            compensation,
            GetPickupCompensation(Isaac.GetPlayer(playerIndex))
        )
    end

    return compensation
end


function PickupRangeModule:GetRoomPickups()
    local pickups = {}

    for _, entity in ipairs(Isaac.FindByType(ENTITY_PICKUP)) do
        local pickup = entity:ToPickup()

        if pickup then
            pickups[#pickups + 1] = pickup
        end
    end

    return pickups
end


function PickupRangeModule:ApplyToPickup(pickup)
    if not pickup or pickup.Type ~= ENTITY_PICKUP
        or not IsFinitePositive(pickup.Size)
    then
        return
    end

    local state = self.ManagedPickups[pickup]

    if state and math.abs(pickup.Size - state.appliedSize) > EPSILON then
        -- A later game state or another mod changed this pickup. Adopt that
        -- exact value as the new base rather than restoring stale state.
        state.baseSize = pickup.Size
    end

    if not self.Context:IsEnabled("smallPlayerPickupRange")
        or self.Compensation <= EPSILON
    then
        if state then
            self:RestorePickup(pickup, state)
        end

        return
    end

    local baseSize = state and state.baseSize or pickup.Size
    local appliedSize = baseSize + self.Compensation

    pickup.Size = appliedSize
    self.ManagedPickups[pickup] = {
        baseSize = baseSize,
        appliedSize = appliedSize,
    }
end

function PickupRangeModule:RefreshRoomPickups()
    for _, pickup in ipairs(self:GetRoomPickups()) do
        self:ApplyToPickup(pickup)
    end
end

function PickupRangeModule:RefreshCompensation()
    local compensation = self.Context:IsEnabled("smallPlayerPickupRange")
        and self:CalculateCompensation()
        or 0

    if math.abs(compensation - self.Compensation) <= EPSILON then
        return
    end

    self.Compensation = compensation

    if compensation <= EPSILON then
        self:RestoreAll()
    else
        self:RefreshRoomPickups()
    end
end

function PickupRangeModule:RefreshAll()
    self.Compensation = self.Context:IsEnabled("smallPlayerPickupRange")
        and self:CalculateCompensation()
        or 0

    if self.Compensation <= EPSILON then
        self:RestoreAll()
    else
        self:RefreshRoomPickups()
    end
end

function PickupRangeModule:OnSettingChanged(enabled)
    if enabled then
        self:RefreshAll()
        return
    end

    self.Compensation = 0
    self:RestoreAll()
end

return PickupRangeModule
