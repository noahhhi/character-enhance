local PickupRangeModule = {}
PickupRangeModule.__index = PickupRangeModule

local NORMAL_SCALE = 1
local DEFAULT_PLAYER_SIZE = 10
local DEFAULT_COPLAYER_SIZE = 7
local PLAYER_VARIANT_COPLAYER = 1
local PLAYER_GRID_COLLISION_POINTS = 40
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
        PendingSizes = {},
        MaintainedSizes = {},
        LastAppliedState = nil,
        FinalLogPending = false,
        RenderLogPending = {},
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
        ModCallbacks.MC_POST_PLAYER_UPDATE,
        function(_, player)
            self:MaintainSafeRoomSize(player)
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_PLAYER_RENDER,
        function(_, player)
            self:VerifyRenderedSize(player)
        end
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
        -- CACHE_SIZE can run while the player is being initialized, before
        -- Game():GetRoom():IsClear() is safe to call. Defer every engine-led
        -- cache pass to POST_UPDATE; module-led passes originate only from a
        -- callback where the room has finished loading.
        -- The engine finalizes player Size after all CACHE_SIZE callbacks.
        -- Apply the collision-only override once that cache pass has ended.
        self:ScheduleRefresh()
        return
    end

    if not self:IsSafeRoom() then
        return
    end

    self.PendingSizes[GetPtrHash(player)] = player.Variant
            == PLAYER_VARIANT_COPLAYER
        and DEFAULT_COPLAYER_SIZE
        or DEFAULT_PLAYER_SIZE
    self.AdjustedDuringRefresh = self.AdjustedDuringRefresh + 1
end

function PickupRangeModule:ApplyPendingSize(player)
    local playerHash = GetPtrHash(player)
    local targetSize = self.PendingSizes[playerHash]
    self.PendingSizes[playerHash] = nil

    if not targetSize or not IsFinitePositive(targetSize) then
        return
    end

    -- SetSize is intentionally called after EvaluateItems returns. Assigning
    -- Size inside MC_EVALUATE_CACHE is overwritten when the engine finishes
    -- synchronizing the Size stat from SpriteScale.
    player:SetSize(
        targetSize,
        Vector(NORMAL_SCALE, NORMAL_SCALE),
        PLAYER_GRID_COLLISION_POINTS
    )
    self.MaintainedSizes[playerHash] = targetSize
    self.LastAppliedState = {
        size = player.Size,
        targetSize = targetSize,
        sizeMultiX = player.SizeMulti.X,
        sizeMultiY = player.SizeMulti.Y,
        spriteScaleX = player.SpriteScale.X,
        spriteScaleY = player.SpriteScale.Y,
    }
end

function PickupRangeModule:MaintainSafeRoomSize(player)
    local targetSize = self.MaintainedSizes[GetPtrHash(player)]

    if not targetSize
        or not self.Context:IsEnabled("smallPlayerPickupRange")
        or not self:IsSafeRoom()
        or (player.IsDead and player:IsDead())
    then
        return
    end

    local sizeBefore = player.Size

    -- Reapply only the cached safe-room radius after the player's entire
    -- update has completed: one O(1) write per affected player, with no
    -- pickup/entity scan and no repeated cache evaluation.
    player:SetSize(
        targetSize,
        Vector(NORMAL_SCALE, NORMAL_SCALE),
        PLAYER_GRID_COLLISION_POINTS
    )

    if self.FinalLogPending then
        Isaac.DebugString(string.format(
            "[Character Enhance] Post-player size: before=%.3f after=%.3f "
                .. "target=%.3f multi=(%.3f,%.3f) sprite=(%.3f,%.3f)",
            sizeBefore,
            player.Size,
            targetSize,
            player.SizeMulti.X,
            player.SizeMulti.Y,
            player.SpriteScale.X,
            player.SpriteScale.Y
        ))
        self.FinalLogPending = false
        self.LoggedSafeRoomSize = true
        self.RenderLogPending[GetPtrHash(player)] = targetSize
    end
end

function PickupRangeModule:VerifyRenderedSize(player)
    local playerHash = GetPtrHash(player)
    local targetSize = self.RenderLogPending[playerHash]

    if not targetSize then
        return
    end

    self.RenderLogPending[playerHash] = nil
    Isaac.DebugString(string.format(
        "[Character Enhance] Rendered player size: actual=%.3f target=%.3f "
            .. "multi=(%.3f,%.3f) sprite=(%.3f,%.3f)",
        player.Size,
        targetSize,
        player.SizeMulti.X,
        player.SizeMulti.Y,
        player.SpriteScale.X,
        player.SpriteScale.Y
    ))
end

function PickupRangeModule:RefreshPlayers()
    local game = Game()
    local playerCount = game:GetNumPlayers()

    self.RefreshingPlayers = true
    self.AdjustedDuringRefresh = 0
    self.PendingSizes = {}
    self.MaintainedSizes = {}
    self.LastAppliedState = nil
    self.RenderLogPending = {}

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
        self.FinalLogPending = true
    elseif not active then
        self.FinalLogPending = false
        self.LoggedSafeRoomSize = false
    end
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
