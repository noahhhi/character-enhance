local CubeBabyRoomPositionModule = {}
CubeBabyRoomPositionModule.__index = CubeBabyRoomPositionModule

local SETTING_KEY = "cubeBabyRoomPosition"
local CUBE_BABY = FamiliarVariant.CUBE_BABY
local HORIZONTAL_OFFSET = 80
local FAMILIAR_RADIUS = 13
local FREE_TILE_SEARCH_RADIUS = 40
local ROOM_ENTRY_WINDOW_FRAMES = 2

local ROCK_TYPES = {
    [GridEntityType.GRID_ROCK] = true,
    [GridEntityType.GRID_ROCKB] = true,
    [GridEntityType.GRID_ROCKT] = true,
    [GridEntityType.GRID_ROCK_BOMB] = true,
    [GridEntityType.GRID_ROCK_ALT] = true,
    [GridEntityType.GRID_ROCK_SS] = true,
    [GridEntityType.GRID_ROCK_SPIKED] = true,
    [GridEntityType.GRID_ROCK_ALT2] = true,
    [GridEntityType.GRID_ROCK_GOLD] = true,
}

local function AddRockScore(score, deltaX, deltaY)
    local distanceSquared = deltaX * deltaX + deltaY * deltaY

    if distanceSquared <= 20 * 20 then
        return score + 10000
    elseif distanceSquared <= 60 * 60 then
        return score + 1000
    elseif distanceSquared <= 100 * 100 then
        return score + 50
    elseif distanceSquared <= 140 * 140 then
        return score + 1
    end

    return score
end

function CubeBabyRoomPositionModule.New(context)
    local self = setmetatable({
        Context = context,
        RoomToken = 0,
        RoomEntryDeadline = -1,
        TargetPosition = nil,
    }, CubeBabyRoomPositionModule)

    self.NewRoomCallback = function()
        self:OnNewRoom()
    end
    self.FamiliarUpdateCallback = function(_, familiar)
        self:OnFamiliarUpdate(familiar)
    end

    context.Mod:AddCallback(
        ModCallbacks.MC_POST_NEW_ROOM,
        self.NewRoomCallback
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_FAMILIAR_UPDATE,
        self.FamiliarUpdateCallback,
        CUBE_BABY
    )

    return self
end

function CubeBabyRoomPositionModule:OnNewRoom()
    self.RoomToken = self.RoomToken + 1
    self.TargetPosition = nil

    if not self.Context:IsEnabled(SETTING_KEY) then
        self.RoomEntryDeadline = -1
        return
    end

    self.RoomEntryDeadline = Game():GetFrameCount()
        + ROOM_ENTRY_WINDOW_FRAMES
end

function CubeBabyRoomPositionModule:GetRoomTarget()
    if self.TargetPosition ~= nil then
        return self.TargetPosition
    end

    local room = Game():GetRoom()
    local center = room:GetCenterPos()
    local left = Vector(center.X - HORIZONTAL_OFFSET, center.Y)
    local right = Vector(center.X + HORIZONTAL_OFFSET, center.Y)
    local leftScore = 0
    local rightScore = 0

    for gridIndex = 0, room:GetGridSize() - 1 do
        local gridEntity = room:GetGridEntity(gridIndex)

        if gridEntity
            and ROCK_TYPES[gridEntity:GetType()] == true
            and gridEntity.CollisionClass ~= GridCollisionClass.COLLISION_NONE
        then
            local position = gridEntity.Position
            leftScore = AddRockScore(
                leftScore,
                position.X - left.X,
                position.Y - left.Y
            )
            rightScore = AddRockScore(
                rightScore,
                position.X - right.X,
                position.Y - right.Y
            )
        end
    end

    local leftCollision = room:GetGridCollisionAtPos(left)
    local rightCollision = room:GetGridCollisionAtPos(right)

    if leftCollision ~= GridCollisionClass.COLLISION_NONE then
        leftScore = leftScore + 20000
    end

    if rightCollision ~= GridCollisionClass.COLLISION_NONE then
        rightScore = rightScore + 20000
    end

    local target

    if leftScore < rightScore then
        target = left
    elseif rightScore < leftScore then
        target = right
    elseif room:GetDecorationSeed() % 2 == 0 then
        target = left
    else
        target = right
    end

    target = room:GetClampedPosition(target, FAMILIAR_RADIUS)
    self.TargetPosition = room:FindFreeTilePosition(
        target,
        FREE_TILE_SEARCH_RADIUS
    )

    return self.TargetPosition
end

function CubeBabyRoomPositionModule:OnFamiliarUpdate(familiar)
    if not self.Context:IsEnabled(SETTING_KEY)
        or Game():GetFrameCount() > self.RoomEntryDeadline
    then
        return
    end

    local data = familiar:GetData()

    if data.CharacterEnhanceCubeBabyRoomToken == self.RoomToken then
        return
    end

    familiar.Position = self:GetRoomTarget()
    familiar.Velocity = Vector.Zero
    data.CharacterEnhanceCubeBabyRoomToken = self.RoomToken
end

function CubeBabyRoomPositionModule:OnSettingChanged(enabled)
    if not enabled then
        self.RoomEntryDeadline = -1
        self.TargetPosition = nil
    end
end

return CubeBabyRoomPositionModule
