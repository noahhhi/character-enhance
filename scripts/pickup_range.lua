local PickupRangeModule = {}
PickupRangeModule.__index = PickupRangeModule

local NORMAL_SCALE = 1
local EPSILON = 0.001

local function IsFinitePositive(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
        and value > 0
end

local function GetPlayerScale(player)
    local spriteScale = player and player.SpriteScale

    if not spriteScale
        or not IsFinitePositive(spriteScale.X)
        or not IsFinitePositive(spriteScale.Y)
    then
        return NORMAL_SCALE
    end

    return math.min(spriteScale.X, spriteScale.Y)
end

function PickupRangeModule.New(context)
    local self = setmetatable({
        Context = context,
        RefreshPending = false,
        LoggedSafeRoomSize = false,
        RefreshingPlayers = false,
        AdjustedDuringRefresh = 0,
        PendingSizes = setmetatable({}, { __mode = "k" }),
    }, PickupRangeModule)

    self.RefreshCallback = function()
        context.Mod:RemoveCallback(
            ModCallbacks.MC_POST_UPDATE,
            self.RefreshCallback
        )
        self.RefreshPending = false
        self:RefreshPlayers()
    end

    context.Mod:AddCallback(
        ModCallbacks.MC_EVALUATE_CACHE,
        function(_, player)
            self:OnEvaluateSize(player)
        end,
        CacheFlag.CACHE_SIZE
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_NEW_ROOM,
        function()
            -- Room:IsClear() is already valid here. Restore combat collision
            -- before the first update of a newly entered hostile room.
            self:RefreshPlayers()
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_GAME_STARTED,
        function()
            self:ScheduleRefresh()
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_NPC_INIT,
        function()
            -- Covers ambushes and later Greed waves that start combat without
            -- entering another room. Coalesce all spawns into one refresh.
            self:ScheduleRefresh()
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_PRE_SPAWN_CLEAN_AWARD,
        function()
            -- The clear flag settles after this callback, so read it once on
            -- the following update rather than polling it every frame.
            self:ScheduleRefresh()
        end
    )

    -- A hot-loaded mod does not receive the current run's start or room-entry
    -- callbacks. Read the live room and player state on the next game update.
    self:ScheduleRefresh()
    return self
end

function PickupRangeModule:IsSafeRoom()
    local game = Game()
    local room = game and game:GetRoom()

    return room and room:IsClear() or false
end

function PickupRangeModule:OnEvaluateSize(player)
    if not self.Context:IsEnabled("smallPlayerPickupRange")
        or not self:IsSafeRoom()
        or not player
        or (player.IsDead and player:IsDead())
        or not IsFinitePositive(player.Size)
    then
        return
    end

    local scale = GetPlayerScale(player)

    if scale >= NORMAL_SCALE - EPSILON then
        return
    end

    if not self.RefreshingPlayers then
        -- The engine finalizes player Size after all CACHE_SIZE callbacks.
        -- Apply the collision-only override once that cache pass has ended.
        self:ScheduleRefresh()
        return
    end

    self.PendingSizes[player] = player.Size / scale
    self.AdjustedDuringRefresh = self.AdjustedDuringRefresh + 1
end

function PickupRangeModule:ApplyPendingSize(player)
    local targetSize = self.PendingSizes[player]
    self.PendingSizes[player] = nil

    if not targetSize or not IsFinitePositive(targetSize) then
        return
    end

    -- SetSize is intentionally called after EvaluateItems returns. Assigning
    -- Size inside MC_EVALUATE_CACHE is overwritten when the engine finishes
    -- synchronizing the Size stat from SpriteScale.
    player:SetSize(targetSize, player.SizeMulti, 0)
end

function PickupRangeModule:RefreshPlayers()
    local game = Game()
    local playerCount = game:GetNumPlayers()

    self.RefreshingPlayers = true
    self.AdjustedDuringRefresh = 0
    self.PendingSizes = setmetatable({}, { __mode = "k" })

    for playerIndex = 0, playerCount - 1 do
        local player = Isaac.GetPlayer(playerIndex)

        if player then
            -- EvaluateItems first restores vanilla's current Size. Our
            -- CACHE_SIZE callback then normalizes it only in a cleared room.
            player:AddCacheFlags(CacheFlag.CACHE_SIZE)
            player:EvaluateItems()
            self:ApplyPendingSize(player)
        end
    end

    self.RefreshingPlayers = false

    local active = self.Context:IsEnabled("smallPlayerPickupRange")
        and self:IsSafeRoom()
        and self.AdjustedDuringRefresh > 0

    if active and not self.LoggedSafeRoomSize then
        Isaac.DebugString(string.format(
            "[Character Enhance] Safe-room pickup size restored for %d player(s)",
            self.AdjustedDuringRefresh
        ))
    end

    self.LoggedSafeRoomSize = active
end

function PickupRangeModule:ScheduleRefresh()
    if self.RefreshPending then
        return
    end

    self.RefreshPending = true
    self.Context.Mod:AddCallback(
        ModCallbacks.MC_POST_UPDATE,
        self.RefreshCallback
    )
end

function PickupRangeModule:OnSettingChanged()
    -- Re-evaluating CACHE_SIZE restores vanilla collision immediately when
    -- disabled and applies safe-room pickup size when enabled.
    self:ScheduleRefresh()
end

return PickupRangeModule
