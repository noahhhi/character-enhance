local LaserSpamFpsGuardModule = {}
LaserSpamFpsGuardModule.__index = LaserSpamFpsGuardModule

local SETTING_KEY = "laserSpamFpsGuard"
local PLAYER_LASER_LIMIT = 32
local DAMAGE_TEXT_LIMIT = 16
local PRESSURE_HOLD_FRAMES = 90
local TEXT_SWEEP_INTERVAL = 3
local OWNER_CHAIN_LIMIT = 6

function LaserSpamFpsGuardModule.New(context)
    local self = setmetatable({
        Context = context,
        TrackedLasers = {},
        TrackedLaserCount = 0,
        PressureUntilFrame = -1,
        NextTextSweepFrame = 0,
        CurrentFrame = Game():GetFrameCount(),
        NeedsAdoption = true,
        LoggedPressureThisRoom = false,
        CulledLaserCount = 0,
        CulledTextCount = 0,
    }, LaserSpamFpsGuardModule)

    context.Mod:AddCallback(
        ModCallbacks.MC_POST_LASER_INIT,
        function(_, laser)
            self:OnLaserInit(laser)
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_ENTITY_REMOVE,
        function(_, entity)
            self:OnLaserRemove(entity)
        end,
        EntityType.ENTITY_LASER
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_UPDATE,
        function()
            self:OnUpdate()
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_NEW_ROOM,
        function()
            self:OnNewRoom()
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_GAME_STARTED,
        function()
            self:OnGameStarted()
        end
    )

    return self
end

function LaserSpamFpsGuardModule:IsEnabled()
    return self.Context:IsEnabled(SETTING_KEY)
end

function LaserSpamFpsGuardModule:ResetRoomState()
    self.TrackedLasers = {}
    self.TrackedLaserCount = 0
    self.PressureUntilFrame = -1
    self.NextTextSweepFrame = 0
    self.NeedsAdoption = true
    self.LoggedPressureThisRoom = false
end

function LaserSpamFpsGuardModule:ResolvePlayerOwner(entity)
    local current = entity

    for _ = 1, OWNER_CHAIN_LIMIT do
        if not current then
            return nil
        end

        if current.Type == EntityType.ENTITY_PLAYER then
            return current:ToPlayer()
        elseif current.Type == EntityType.ENTITY_FAMILIAR then
            local familiar = current:ToFamiliar()

            if familiar and familiar.Player then
                return familiar.Player
            end
        end

        local nextEntity = current.SpawnerEntity or current.Parent

        if not nextEntity or nextEntity == current then
            return nil
        end

        current = nextEntity
    end

    return nil
end

function LaserSpamFpsGuardModule:MarkPressure(frame)
    self.PressureUntilFrame = math.max(
        self.PressureUntilFrame,
        frame + PRESSURE_HOLD_FRAMES
    )

    if not self.LoggedPressureThisRoom then
        self.LoggedPressureThisRoom = true

        if Isaac.DebugString then
            Isaac.DebugString(
                "[Character Enhance] Laser Spam FPS Guard engaged"
            )
        end
    end
end

function LaserSpamFpsGuardModule:TrackOrCull(laser, frame)
    if not self:ResolvePlayerOwner(laser) then
        return
    end

    local hash = GetPtrHash(laser)

    if self.TrackedLasers[hash] then
        return
    end

    if self.TrackedLaserCount >= PLAYER_LASER_LIMIT then
        laser:Remove()
        self.CulledLaserCount = self.CulledLaserCount + 1
        self:MarkPressure(frame)
        return
    end

    self.TrackedLasers[hash] = true
    self.TrackedLaserCount = self.TrackedLaserCount + 1
end

function LaserSpamFpsGuardModule:OnLaserInit(laser)
    if not self:IsEnabled() then
        return
    end

    self:TrackOrCull(laser, self.CurrentFrame)
end

function LaserSpamFpsGuardModule:OnLaserRemove(entity)
    local hash = GetPtrHash(entity)

    if self.TrackedLasers[hash] then
        self.TrackedLasers[hash] = nil
        self.TrackedLaserCount = self.TrackedLaserCount - 1
    end
end

function LaserSpamFpsGuardModule:AdoptExistingLasers(frame)
    self.NeedsAdoption = false

    for _, entity in ipairs(Isaac.FindByType(
        EntityType.ENTITY_LASER,
        -1,
        -1,
        false,
        false
    )) do
        local laser = entity:ToLaser()

        if laser then
            self:TrackOrCull(laser, frame)
        end
    end
end

function LaserSpamFpsGuardModule:CullDamageText()
    local kept = 0

    for _, entity in ipairs(Isaac.FindByType(
        EntityType.ENTITY_TEXT,
        -1,
        -1,
        false,
        false
    )) do
        if kept < DAMAGE_TEXT_LIMIT then
            kept = kept + 1
        else
            entity:Remove()
            self.CulledTextCount = self.CulledTextCount + 1
        end
    end
end

function LaserSpamFpsGuardModule:OnUpdate()
    if not self:IsEnabled() then
        return
    end

    local frame = Game():GetFrameCount()
    self.CurrentFrame = frame

    if self.NeedsAdoption then
        self:AdoptExistingLasers(frame)
    end

    if frame <= self.PressureUntilFrame
        and frame >= self.NextTextSweepFrame
    then
        self.NextTextSweepFrame = frame + TEXT_SWEEP_INTERVAL
        self:CullDamageText()
    end
end

function LaserSpamFpsGuardModule:OnNewRoom()
    self:ResetRoomState()
end

function LaserSpamFpsGuardModule:OnGameStarted()
    self:ResetRoomState()
end

function LaserSpamFpsGuardModule:OnSettingChanged(enabled)
    self:ResetRoomState()

    if not enabled then
        self.NeedsAdoption = false
    end
end

return LaserSpamFpsGuardModule
