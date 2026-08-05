local MomsKnifeHomingModule = {}
MomsKnifeHomingModule.__index = MomsKnifeHomingModule

local SETTING_KEY = "momsKnifeHomingFix"
local MOMS_KNIFE_VARIANT = 0
local STATE_KEY = "CharacterEnhanceMomsKnifeHoming"
local STATE_VERSION = 7
local HOMING_FLAG = TearFlags.TEAR_HOMING
local TRACKING_CONE = 40
local MAX_ANGULAR_SPEED = 15
local MAX_ANGULAR_ACCELERATION = 6
local STEERING_RESPONSE = 0.75
local MIN_INTERCEPT_FRAMES = 1
local MAX_INTERCEPT_FRAMES = 18
local MOTION_EPSILON = 0.05
local INTERCEPT_EPSILON = 0.001
local MAX_TRACKED_SPEED = 20
local TELEPORT_DISPLACEMENT_THRESHOLD = 40
local MAX_TRACKED_SPEED_CHANGE = 2.5
local MIN_TURN_TRACKING_SPEED = 0.5
local MAX_TRACKED_TURN_RATE = 12
local MAX_PREDICTED_HEADING_CHANGE = 75
local TURN_RATE_CURRENT_WEIGHT = 0.65
local SPEED_CHANGE_CURRENT_WEIGHT = 0.45
local CURVED_INTERCEPT_STEP = 0.5
local CONTACT_LEAD_FRAMES = 0.5
local CONTACT_RADIAL_MARGIN = 24
local MAX_DISTANCE_PERCENT = 100
local MAX_RANGE_EXTENSION = 1.3
local HOLD_SWITCH_MARGIN = 6
local HOLD_MAX_RADIAL_SPEED = 8
local HOLD_RADIAL_ACCELERATION = 1.5
local HOLD_RADIAL_RESPONSE = 0.45
local HOLD_DISTANCE_EPSILON = 0.25
local PREPARED_DISTANCE_MATCH_EPSILON = 0.5
local RANGE_MATCH_EPSILON = 0.5
local LAYOUT_SHAPE_EPSILON = 0.1
local LAYOUT_OFFSET_SYMMETRY_EPSILON = 0.5
local WIDE_LAYOUT_SPAN = 179.5
local FLIGHT_ORIGIN_FOLLOW = 0.4

local function NormalizeAngle(angle)
    return (angle + 180) % 360 - 180
end

local function AngleDifference(target, current)
    return NormalizeAngle(target - current)
end

local function MoveTowards(current, target, maximumStep)
    local difference = target - current

    if difference > maximumStep then
        difference = maximumStep
    elseif difference < -maximumStep then
        difference = -maximumStep
    end

    return current + difference
end

local function GetBrakingLimitedSpeed(distance)
    local low = 0
    local high = MAX_ANGULAR_SPEED

    -- Include the current step plus every future step after decelerating by
    -- MAX_ANGULAR_ACCELERATION. This starts braking early enough that ordinary
    -- target motion does not require an abrupt final-frame speed truncation.
    for _ = 1, 12 do
        local candidate = (low + high) * 0.5
        local stoppingDistance = 0
        local speed = candidate

        while speed > INTERCEPT_EPSILON do
            stoppingDistance = stoppingDistance + speed
            speed = math.max(0, speed - MAX_ANGULAR_ACCELERATION)
        end

        if stoppingDistance <= distance then
            low = candidate
        else
            high = candidate
        end
    end

    return low
end

local function ClampAngleAround(angle, center, maximumDeviation)
    local difference = AngleDifference(angle, center)

    if difference > maximumDeviation then
        difference = maximumDeviation
    elseif difference < -maximumDeviation then
        difference = -maximumDeviation
    end

    return center + difference
end

local function VectorAngle(vector)
    return math.deg(math.atan(vector.Y, vector.X))
end

local function EntityHash(entity)
    return tostring(GetPtrHash(entity))
end

local function GetWorldRotation(knife)
    return (knife.Rotation or 0) + (knife.RotationOffset or 0)
end

local function GetMedianAngle(angles)
    if #angles == 0 then
        return nil
    end

    local reference = angles[1]
    local differences = {}

    for _, angle in ipairs(angles) do
        differences[#differences + 1] = AngleDifference(angle, reference)
    end

    table.sort(differences)
    local middleIndex = math.floor((#differences + 1) * 0.5)
    local middleDifference = differences[middleIndex]

    if #differences % 2 == 0 then
        middleDifference = (
            middleDifference + differences[middleIndex + 1]
        ) * 0.5
    end

    return reference + middleDifference
end

local function GetCircularSpan(angles)
    if #angles <= 1 then
        return 0
    end

    local normalized = {}

    for _, angle in ipairs(angles) do
        normalized[#normalized + 1] = angle % 360
    end

    table.sort(normalized)
    local largestGap = 0

    for index = 1, #normalized - 1 do
        largestGap = math.max(
            largestGap,
            normalized[index + 1] - normalized[index]
        )
    end

    largestGap = math.max(
        largestGap,
        normalized[1] + 360 - normalized[#normalized]
    )
    return 360 - largestGap
end

local function CopyVector(vector)
    return Vector(vector.X, vector.Y)
end

local function ClampVectorLength(vector, maximumLength)
    local length = vector:Length()

    if length <= maximumLength or length <= 0.01 then
        return vector
    end

    return vector * (maximumLength / length)
end

local function SetVectorLength(vector, length)
    local currentLength = vector:Length()

    if currentLength <= 0.01 then
        return Vector(0, 0)
    end

    return vector * (length / currentLength)
end

local function Dot(left, right)
    return left.X * right.X + left.Y * right.Y
end

local function RotateVector(vector, degrees)
    if math.abs(degrees) <= INTERCEPT_EPSILON then
        return CopyVector(vector)
    end

    local radians = math.rad(degrees)
    local cosine = math.cos(radians)
    local sine = math.sin(radians)

    return Vector(
        vector.X * cosine - vector.Y * sine,
        vector.X * sine + vector.Y * cosine
    )
end

local function IsTargetableEnemy(entity)
    return entity ~= nil
        and entity:Exists()
        and not entity:IsDead()
        and entity:ToNPC() ~= nil
        and entity:IsEnemy()
        and entity:IsActiveEnemy(false)
        and entity:IsVulnerableEnemy()
        and not entity:HasEntityFlags(EntityFlag.FLAG_NO_TARGET)
        and not entity:HasEntityFlags(EntityFlag.FLAG_CHARM)
        and not entity:HasEntityFlags(EntityFlag.FLAG_FRIENDLY)
end

function MomsKnifeHomingModule.New(context)
    local self = setmetatable({
        Context = context,
        CandidateFrame = -1,
        Candidates = {},
        TargetMotion = {},
        KnifeGroups = {},
    }, MomsKnifeHomingModule)

    self.KnifeUpdateCallback = function(_, knife)
        self:OnKnifeUpdate(knife)
    end
    self.KnifeCollisionCallback = function(_, knife, collider)
        self:OnKnifeCollision(knife, collider)
    end
    self.PostUpdateCallback = function()
        self:OnPostUpdate()
    end

    context.Mod:AddCallback(
        ModCallbacks.MC_POST_KNIFE_UPDATE,
        self.KnifeUpdateCallback,
        MOMS_KNIFE_VARIANT
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_PRE_KNIFE_COLLISION,
        self.KnifeCollisionCallback,
        MOMS_KNIFE_VARIANT
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_UPDATE,
        self.PostUpdateCallback
    )

    return self
end

function MomsKnifeHomingModule:GetCandidates()
    local frame = Game():GetFrameCount()

    if self.CandidateFrame == frame then
        return self.Candidates
    end

    local candidates = {}
    local previousMotion = self.TargetMotion
    local currentMotion = {}

    for _, entity in ipairs(Isaac.GetRoomEntities()) do
        if IsTargetableEnemy(entity) then
            candidates[#candidates + 1] = entity
            local hash = EntityHash(entity)
            local previous = previousMotion[hash]
            local nativeVelocity = entity.Velocity or Vector(0, 0)
            local measuredVelocity = nativeVelocity
            local turnRate = 0
            local speedChange = 0
            local hasObservedMotion = false

            if previous ~= nil and previous.Frame == frame - 1 then
                local observedVelocity = entity.Position - previous.Position

                if observedVelocity:Length()
                    > TELEPORT_DISPLACEMENT_THRESHOLD
                then
                    -- Burrowing and teleporting enemies can replace their
                    -- position in one update. Do not turn that discontinuity
                    -- into a high-speed trajectory aimed across the room.
                    measuredVelocity = nativeVelocity
                elseif observedVelocity:Length() > MOTION_EPSILON then
                    hasObservedMotion = true
                    if nativeVelocity:Length() > MOTION_EPSILON then
                        -- Position displacement is the authoritative motion
                        -- that was actually rendered. Blend in a smaller part
                        -- of native Velocity as a one-frame look-ahead for AI
                        -- acceleration and direction changes.
                        measuredVelocity = observedVelocity * 0.65
                            + nativeVelocity * 0.35
                    else
                        measuredVelocity = observedVelocity
                    end

                    if measuredVelocity:Length() >= MIN_TURN_TRACKING_SPEED
                        and previous.Velocity:Length()
                            >= MIN_TURN_TRACKING_SPEED
                    then
                        local observedTurn = AngleDifference(
                            VectorAngle(measuredVelocity),
                            VectorAngle(previous.Velocity)
                        )

                        if math.abs(observedTurn)
                            <= MAX_TRACKED_TURN_RATE * 2
                        then
                            observedTurn = math.max(
                                -MAX_TRACKED_TURN_RATE,
                                math.min(
                                    observedTurn,
                                    MAX_TRACKED_TURN_RATE
                                )
                            )
                            turnRate = (previous.TurnRate or 0)
                                    * (1 - TURN_RATE_CURRENT_WEIGHT)
                                + observedTurn * TURN_RATE_CURRENT_WEIGHT
                        end
                    end
                elseif nativeVelocity:Length() <= MOTION_EPSILON
                    and previous.Velocity:Length() > MOTION_EPSILON
                then
                    -- Some NPCs update their position only on alternating
                    -- frames. Retain a short decaying observation instead of
                    -- treating that single quiet frame as a full stop.
                    measuredVelocity = previous.Velocity * 0.5
                    turnRate = (previous.TurnRate or 0) * 0.5
                elseif nativeVelocity:Length() > MOTION_EPSILON then
                    turnRate = (previous.TurnRate or 0) * 0.5
                end

                if hasObservedMotion then
                    local observedSpeedChange = measuredVelocity:Length()
                        - previous.Velocity:Length()
                    observedSpeedChange = math.max(
                        -MAX_TRACKED_SPEED_CHANGE,
                        math.min(
                            MAX_TRACKED_SPEED_CHANGE,
                            observedSpeedChange
                        )
                    )
                    speedChange = (previous.SpeedChange or 0)
                            * (1 - SPEED_CHANGE_CURRENT_WEIGHT)
                        + observedSpeedChange
                            * SPEED_CHANGE_CURRENT_WEIGHT
                else
                    speedChange = (previous.SpeedChange or 0) * 0.5
                end
            end

            currentMotion[hash] = {
                Frame = frame,
                Position = CopyVector(entity.Position),
                Velocity = ClampVectorLength(
                    measuredVelocity,
                    MAX_TRACKED_SPEED
                ),
                TurnRate = turnRate,
                SpeedChange = speedChange,
            }
        end
    end

    self.CandidateFrame = frame
    self.Candidates = candidates
    self.TargetMotion = currentMotion
    return candidates
end

function MomsKnifeHomingModule:GetTargetMotion(knife, state, target)
    local motion = self.TargetMotion[EntityHash(target)]
    local targetVelocity = motion and motion.Velocity
        or target.Velocity
        or Vector(0, 0)
    local turnRate = motion and motion.TurnRate or 0
    local speedChange = motion and motion.SpeedChange or 0
    local sourceVelocity = Vector(0, 0)

    if knife.SpawnerEntity and knife.SpawnerEntity.Velocity then
        sourceVelocity = knife.SpawnerEntity.Velocity
            * self:GetOriginFollowFactor(knife, state)
    end

    return ClampVectorLength(targetVelocity, MAX_TRACKED_SPEED),
        turnRate,
        speedChange,
        sourceVelocity
end

function MomsKnifeHomingModule:PredictTargetDisplacement(
    targetVelocity,
    turnRate,
    frames,
    speedChange
)
    if frames <= 0 then
        return Vector(0, 0)
    end

    speedChange = speedChange or 0

    if math.abs(turnRate) <= INTERCEPT_EPSILON
        and math.abs(speedChange) <= INTERCEPT_EPSILON
    then
        return targetVelocity * frames
    end

    local displacement = Vector(0, 0)
    local velocity = CopyVector(targetVelocity)
    local accumulatedTurn = 0
    local remainingFrames = frames

    while remainingFrames > INTERCEPT_EPSILON do
        local step = math.min(CURVED_INTERCEPT_STEP, remainingFrames)
        local stepTurn = turnRate * step
        local remainingTurn = math.max(
            0,
            MAX_PREDICTED_HEADING_CHANGE - math.abs(accumulatedTurn)
        )

        if math.abs(stepTurn) > remainingTurn then
            stepTurn = remainingTurn

            if turnRate < 0 then
                stepTurn = -stepTurn
            end
        end

        local currentSpeed = velocity:Length()
        local nextVelocity = RotateVector(velocity, stepTurn)
        local nextSpeed = math.max(
            0,
            math.min(
                MAX_TRACKED_SPEED,
                currentSpeed + speedChange * step
            )
        )
        local averageVelocity = SetVectorLength(
            nextVelocity,
            (currentSpeed + nextSpeed) * 0.5
        )
        displacement = displacement + averageVelocity * step
        velocity = SetVectorLength(nextVelocity, nextSpeed)
        accumulatedTurn = accumulatedTurn + stepTurn
        remainingFrames = remainingFrames - step
    end

    return displacement
end

function MomsKnifeHomingModule:GetRadialSpeed(knife, state, frame)
    local knifeDistance = knife:GetKnifeDistance()
    local nativeSpeed = knife:GetKnifeVelocity()
    local radialSpeed = nativeSpeed

    if state.DistanceFrame == frame - 1
        and state.PreviousKnifeDistance ~= nil
    then
        local observedSpeed = knifeDistance - state.PreviousKnifeDistance

        if math.abs(observedSpeed) > MOTION_EPSILON then
            -- GetKnifeVelocity is available, but observed distance change is
            -- the exact radial motion that occurred in this game state. This
            -- also preserves the sign when the knife starts returning.
            radialSpeed = observedSpeed
        end
    end

    state.PreviousKnifeDistance = knifeDistance
    state.DistanceFrame = frame
    state.RadialSpeed = radialSpeed
    return radialSpeed
end

local function AddInterceptCandidate(candidates, value, maximumFrames)
    if value ~= nil
        and value >= MIN_INTERCEPT_FRAMES
        and value <= maximumFrames
    then
        candidates[#candidates + 1] = value
    end
end

function MomsKnifeHomingModule:SolveInterceptTime(
    relativePosition,
    targetVelocity,
    knifeDistance,
    radialSpeed,
    maximumFrames
)
    if maximumFrames < MIN_INTERCEPT_FRAMES then
        return MIN_INTERCEPT_FRAMES
    end

    local speedSquared = Dot(targetVelocity, targetVelocity)
    local a = speedSquared - radialSpeed * radialSpeed
    local b = 2 * (
        Dot(relativePosition, targetVelocity)
            - knifeDistance * radialSpeed
    )
    local c = Dot(relativePosition, relativePosition)
        - knifeDistance * knifeDistance
    local candidates = {}

    if math.abs(a) <= INTERCEPT_EPSILON then
        if math.abs(b) > INTERCEPT_EPSILON then
            AddInterceptCandidate(candidates, -c / b, maximumFrames)
        end
    else
        local discriminant = b * b - 4 * a * c

        if discriminant >= 0 then
            local root = math.sqrt(discriminant)
            AddInterceptCandidate(
                candidates,
                (-b - root) / (2 * a),
                maximumFrames
            )
            AddInterceptCandidate(
                candidates,
                (-b + root) / (2 * a),
                maximumFrames
            )
        end
    end

    local bestTime

    for _, candidate in ipairs(candidates) do
        if knifeDistance + radialSpeed * candidate >= 0
            and (bestTime == nil or candidate < bestTime)
        then
            bestTime = candidate
        end
    end

    if bestTime ~= nil then
        return bestTime
    end

    -- An accelerating target or a knife close to its turnaround can have no
    -- exact constant-velocity root. Use the bounded time with the smallest
    -- radial miss instead of falling back to the enemy's current position.
    local bestError

    for frame = MIN_INTERCEPT_FRAMES, math.floor(maximumFrames) do
        local targetDistance = (
            relativePosition + targetVelocity * frame
        ):Length()
        local futureKnifeDistance = math.max(
            0,
            knifeDistance + radialSpeed * frame
        )
        local error = math.abs(targetDistance - futureKnifeDistance)

        if bestError == nil or error < bestError then
            bestError = error
            bestTime = frame
        end
    end

    return bestTime or MIN_INTERCEPT_FRAMES
end

function MomsKnifeHomingModule:SolveCurvedInterceptTime(
    relativePosition,
    targetVelocity,
    turnRate,
    speedChange,
    sourceVelocity,
    knifeDistance,
    radialSpeed,
    maximumFrames
)
    if math.abs(turnRate) <= INTERCEPT_EPSILON
        and math.abs(speedChange) <= INTERCEPT_EPSILON
    then
        return self:SolveInterceptTime(
            relativePosition,
            targetVelocity - sourceVelocity,
            knifeDistance,
            radialSpeed,
            maximumFrames
        )
    end

    local bestTime = MIN_INTERCEPT_FRAMES
    local bestError
    local previousTime = 0
    local previousSignedError = relativePosition:Length() - knifeDistance
    local time = 0
    local targetDisplacement = Vector(0, 0)
    local velocity = CopyVector(targetVelocity)
    local accumulatedTurn = 0

    while time < maximumFrames - INTERCEPT_EPSILON do
        local step = math.min(
            CURVED_INTERCEPT_STEP,
            maximumFrames - time
        )
        local stepTurn = turnRate * step
        local remainingTurn = math.max(
            0,
            MAX_PREDICTED_HEADING_CHANGE - math.abs(accumulatedTurn)
        )

        if math.abs(stepTurn) > remainingTurn then
            stepTurn = remainingTurn

            if turnRate < 0 then
                stepTurn = -stepTurn
            end
        end

        local currentSpeed = velocity:Length()
        local nextVelocity = RotateVector(velocity, stepTurn)
        local nextSpeed = math.max(
            0,
            math.min(
                MAX_TRACKED_SPEED,
                currentSpeed + speedChange * step
            )
        )
        local averageVelocity = SetVectorLength(
            nextVelocity,
            (currentSpeed + nextSpeed) * 0.5
        )
        targetDisplacement = targetDisplacement + averageVelocity * step
        velocity = SetVectorLength(nextVelocity, nextSpeed)
        accumulatedTurn = accumulatedTurn + stepTurn
        time = time + step

        local relativeDisplacement = targetDisplacement
            - sourceVelocity * time
        local targetDistance = (
            relativePosition + relativeDisplacement
        ):Length()
        local futureKnifeDistance = math.max(
            0,
            knifeDistance + radialSpeed * time
        )
        local signedError = targetDistance - futureKnifeDistance

        if time >= MIN_INTERCEPT_FRAMES then
            local absoluteError = math.abs(signedError)

            if bestError == nil or absoluteError < bestError then
                bestError = absoluteError
                bestTime = time
            end

            if previousTime >= MIN_INTERCEPT_FRAMES
                and signedError * previousSignedError <= 0
            then
                local errorSum = math.abs(previousSignedError)
                    + absoluteError

                if errorSum <= INTERCEPT_EPSILON then
                    return time
                end

                return previousTime
                    + (time - previousTime)
                        * math.abs(previousSignedError)
                        / errorSum
            end
        end

        previousTime = time
        previousSignedError = signedError
    end

    return bestTime
end


function MomsKnifeHomingModule:GetBaseMaximumAttackRange(knife, state)
    local maximumDistance = state.BaselineMaxDistance
        or knife.MaxDistance
        or 0
    local sourceRange = state.BaselineSourceRange
        or state.CalibratedSourceRange
        or state.PreparedSourceRange
        or self:GetSourceRange(knife)

    if maximumDistance > 0 and sourceRange ~= nil and sourceRange > 0 then
        -- Native Mom's Knife MaxDistance uses 100 as the full-range scale;
        -- GetKnifeDistance and entity positions are world units. Keep the
        -- native percentage for flight timing, but convert it before target
        -- acquisition and radial contact retention.
        return sourceRange * maximumDistance / MAX_DISTANCE_PERCENT
    end

    return maximumDistance
end

function MomsKnifeHomingModule:GetMaximumAttackRange(knife, state)
    return self:GetBaseMaximumAttackRange(knife, state)
        * MAX_RANGE_EXTENSION
end

function MomsKnifeHomingModule:GetMaximumInterceptFrames(
    knife,
    state,
    knifeDistance,
    radialSpeed
)
    local maximumFrames = MAX_INTERCEPT_FRAMES
    local maximumAttackRange = self:GetMaximumAttackRange(knife, state)

    if radialSpeed > MOTION_EPSILON and maximumAttackRange > 0 then
        maximumFrames = math.min(
            maximumFrames,
            math.max(
                MIN_INTERCEPT_FRAMES,
                (maximumAttackRange - knifeDistance) / radialSpeed
            )
        )
    elseif radialSpeed < -MOTION_EPSILON then
        maximumFrames = math.min(
            maximumFrames,
            math.max(
                MIN_INTERCEPT_FRAMES,
                knifeDistance / -radialSpeed
            )
        )
    end

    return maximumFrames
end

function MomsKnifeHomingModule:GetSourcePlayer(knife)
    local source = knife.SpawnerEntity

    if source == nil then
        return nil
    end

    local player = source:ToPlayer()

    if player == nil then
        local familiar = source:ToFamiliar()
        player = familiar and familiar.Player or nil
    end

    return player
end

function MomsKnifeHomingModule:GetSourceRange(knife)
    local player = self:GetSourcePlayer(knife)
    return player and player.TearRange or nil
end

function MomsKnifeHomingModule:GetOriginFollowFactor(knife, state)
    if state == nil
        or not state.Flying
        or state.LaunchSourcePosition == nil
        or state.LaunchOrigin == nil
    then
        return 1
    end

    if not state.OriginRetracting then
        return FLIGHT_ORIGIN_FOLLOW
    end

    local nativeStart = math.max(
        MOTION_EPSILON,
        state.OriginRetractionNativeStart or knife:GetKnifeDistance()
    )
    local projectedDistance = math.max(
        0,
        knife:GetKnifeDistance() + math.min(0, state.RadialSpeed or 0)
    )
    local returnProgress = 1 - math.max(
        0,
        math.min(1, projectedDistance / nativeStart)
    )

    return FLIGHT_ORIGIN_FOLLOW
        + (1 - FLIGHT_ORIGIN_FOLLOW) * returnProgress
end

function MomsKnifeHomingModule:GetRotationOrigin(knife, state)
    local source = knife.SpawnerEntity

    if source ~= nil and source.Position ~= nil then
        if state ~= nil
            and state.Flying
            and state.LaunchSourcePosition ~= nil
            and state.LaunchOrigin ~= nil
        then
            local sourceDisplacement = source.Position
                - state.LaunchSourcePosition
            return state.LaunchOrigin + sourceDisplacement
                * self:GetOriginFollowFactor(knife, state)
        end

        return source.Position
    end

    -- EntityKnife.Position is the moving knife hitbox, while Rotation turns
    -- the knife around its source. Reconstruct that pivot only for unusual
    -- knives whose source has disappeared during flight.
    local radians = math.rad(GetWorldRotation(knife))
    local distance = knife:GetKnifeDistance()
    return knife.Position - Vector(
        math.cos(radians) * distance,
        math.sin(radians) * distance
    )
end

function MomsKnifeHomingModule:GetHeldAimAngle(knife, group)
    local rawWorldAngle = GetWorldRotation(knife)

    if group ~= nil
        and group.Count > 1
        and group.NativeCentralAimAngle ~= nil
    then
        -- Native multi-knife layouts are not represented uniformly. Derive
        -- compact spreads from the complete native group and preserve each raw
        -- deviation. Wide/backward/random layouts select their held vanilla
        -- input later; callback order never defines either kind of axis.
        return group.NativeCentralAimAngle + AngleDifference(
            rawWorldAngle,
            group.NativeCentralAimAngle
        )
    end

    return self:GetHeldBaseAimAngle(knife, group)
        + (knife.RotationOffset or 0)
end

function MomsKnifeHomingModule:GetHeldBaseAimAngle(knife, group)
    if group ~= nil
        and group.Count > 1
        and group.NativeCentralAimAngle ~= nil
    then
        return group.NativeCentralAimAngle
    end

    local player = self:GetSourcePlayer(knife)

    if player ~= nil then
        local shootingInput = player:GetShootingInput()

        if shootingInput:Length() > 0.01 then
            return VectorAngle(shootingInput)
        end
    end

    return GetWorldRotation(knife) - (knife.RotationOffset or 0)
end

function MomsKnifeHomingModule:RegisterKnifeGroup(knife, frame)
    local source = knife.SpawnerEntity

    if source == nil then
        return nil
    end

    local owner = self:GetSourcePlayer(knife) or source
    local ownerHash = EntityHash(owner)
    local group = self.KnifeGroups[ownerHash]

    if group == nil then
        group = {
            Entries = {},
            FlightId = 0,
            LastFlyingFrame = -2,
        }
        self.KnifeGroups[ownerHash] = group
    end

    local flying = knife:IsFlying()

    if flying and group.LastFlyingFrame < frame - 1 then
        group.FlightId = group.FlightId + 1
        group.FlightStartFrame = frame
        group.FlightMaxDistance = nil
        group.FlightReady = false
        group.LayoutCandidateAngles = nil
        group.LayoutCandidateOffsets = nil
        group.LayoutShape = nil
        group.PreflightAimAngle = group.NativePlayerAimAngle
            or group.NativeCentralAimAngle

        for _, oldEntry in pairs(group.Entries) do
            oldEntry.NativeLaunchAngle = nil
            oldEntry.LaunchFlightId = nil
            oldEntry.NativeLaunchCaptureFrame = nil
            oldEntry.ObservedNativeAngle = nil
            oldEntry.ObservedOffset = nil
            oldEntry.ObservedFrame = nil
        end
    end

    if flying then
        group.LastFlyingFrame = frame
    end

    local knifeHash = EntityHash(knife)
    local knifeEntry = group.Entries[knifeHash]

    if knifeEntry == nil then
        knifeEntry = {}
        group.Entries[knifeHash] = knifeEntry
    end

    knifeEntry.Knife = knife
    knifeEntry.SeenFrame = frame

    if not flying then
        knifeEntry.NativeHeldAngle = GetWorldRotation(knife)
        local player = self:GetSourcePlayer(knife)

        if player ~= nil then
            local shootingInput = player:GetShootingInput()

            if shootingInput:Length() > 0.01 then
                group.NativePlayerAimAngle = VectorAngle(shootingInput)
            end
        end
    end

    if flying and knifeEntry.LaunchFlightId ~= group.FlightId then
        -- Release-spawned extras arrive in an arbitrary callback order. Record
        -- each native member independently and defer every group-wide write
        -- until MC_POST_UPDATE has seen the complete layout.
        knifeEntry.LaunchFlightId = group.FlightId

        if group.FlightReady then
            -- A genuinely late native member invalidates the completed
            -- snapshot. Re-open collection instead of assigning that knife an
            -- item-specific guessed angle.
            group.FlightReady = false
            group.LayoutCandidateAngles = nil
            group.LayoutCandidateOffsets = nil
            group.LayoutShape = nil
        end
    end

    if flying then
        knifeEntry.ObservedNativeAngle = GetWorldRotation(knife)
        knifeEntry.ObservedOffset = knife.RotationOffset or 0
        knifeEntry.ObservedFrame = frame
    end

    local count = 0
    local spreadReference
    local spreadDifferences = {}

    for knifeHash, entry in pairs(group.Entries) do
        if entry.SeenFrame < frame - 1
            or entry.Knife == nil
            or not entry.Knife:Exists()
        then
            group.Entries[knifeHash] = nil
        else
            count = count + 1
            local memberAngle

            if flying
                and group.FlightReady
                and entry.LaunchFlightId == group.FlightId
            then
                memberAngle = entry.NativeLaunchAngle
            elseif flying
                and entry.LaunchFlightId == group.FlightId
                and entry.ObservedNativeAngle ~= nil
            then
                memberAngle = entry.ObservedNativeAngle
            elseif not flying and not entry.Knife:IsFlying() then
                memberAngle = GetWorldRotation(entry.Knife)
            end

            if memberAngle ~= nil then
                if spreadReference == nil then
                    spreadReference = memberAngle
                end

                spreadDifferences[#spreadDifferences + 1] = AngleDifference(
                    memberAngle,
                    spreadReference
                )
            end
        end
    end

    group.Count = count

    if not flying and #spreadDifferences > 0 then
        local heldAngles = {}

        for _, difference in ipairs(spreadDifferences) do
            heldAngles[#heldAngles + 1] = spreadReference + difference
        end

        group.NativeCentralAimAngle = GetMedianAngle(heldAngles)
    else
        group.NativeCentralAimAngle = group.NativeCentralAimAngle
            or GetWorldRotation(knife)
    end

    return group
end

function MomsKnifeHomingModule:BuildKnifeLayout(group, frame)
    local members = {}

    for hash, entry in pairs(group.Entries) do
        if entry.LaunchFlightId == group.FlightId
            and entry.ObservedFrame == frame
            and entry.Knife ~= nil
            and entry.Knife:Exists()
            and entry.Knife:IsFlying()
        then
            members[#members + 1] = {
                Hash = hash,
                Entry = entry,
                Angle = entry.ObservedNativeAngle,
                Offset = entry.ObservedOffset or 0,
            }
        end
    end

    table.sort(members, function(left, right)
        return left.Hash < right.Hash
    end)

    if #members == 0 then
        return nil
    end

    if #members == 1 then
        local memberState = members[1].Entry.Knife:GetData()[STATE_KEY]

        -- A lone knife can safely retain the held direction captured before
        -- vanilla homing receives its first flying update. Multi-knife volleys
        -- must instead use the complete native release layout below.
        if memberState ~= nil and memberState.LaunchAngle ~= nil then
            members[1].Angle = memberState.LaunchAngle
        end
    end

    local anchorAngle = members[1].Angle
    local shape = {}
    local angles = {}
    local offsets = {}

    for _, member in ipairs(members) do
        shape[#shape + 1] = {
            Hash = member.Hash,
            Difference = AngleDifference(member.Angle, anchorAngle),
        }
        angles[member.Hash] = member.Angle
        offsets[member.Hash] = member.Offset
    end

    return {
        Members = members,
        Shape = shape,
        Angles = angles,
        Offsets = offsets,
    }
end

function MomsKnifeHomingModule:LayoutShapeMatches(left, right)
    if left == nil or right == nil or #left ~= #right then
        return false
    end

    for index, member in ipairs(left) do
        if member.Hash ~= right[index].Hash
            or math.abs(AngleDifference(
                member.Difference,
                right[index].Difference
            )) > LAYOUT_SHAPE_EPSILON
        then
            return false
        end
    end

    return true
end

function MomsKnifeHomingModule:GetNativeCentralAxis(group, angles, offsets)
    local angleList = {}
    local minimumOffset
    local maximumOffset

    for hash, angle in pairs(angles) do
        angleList[#angleList + 1] = angle
        local offset = offsets[hash] or 0
        minimumOffset = minimumOffset == nil
                and offset
            or math.min(minimumOffset, offset)
        maximumOffset = maximumOffset == nil
                and offset
            or math.max(maximumOffset, offset)
    end

    local symmetricNativeOffsets = minimumOffset ~= nil
        and maximumOffset ~= nil
        and math.abs(minimumOffset + maximumOffset)
            <= LAYOUT_OFFSET_SYMMETRY_EPSILON
    local compactLayout = GetCircularSpan(angleList) < WIDE_LAYOUT_SPAN

    -- Ordinary shot multipliers expose a compact spread with symmetric native
    -- offsets: odd groups use the middle knife and even groups use the middle
    -- pair. Omnidirectional/backward/random emitters do not have one geometric
    -- middle that represents the player's shot; retain the held vanilla axis
    -- for those layouts while still preserving every individual launch line.
    if (#angleList > 1 and (not symmetricNativeOffsets or not compactLayout))
        and group.PreflightAimAngle ~= nil
    then
        return group.PreflightAimAngle
    end

    return GetMedianAngle(angleList) or group.PreflightAimAngle
end

function MomsKnifeHomingModule:FinalizeKnifeLayout(group, frame)
    local angles = group.LayoutCandidateAngles
    local offsets = group.LayoutCandidateOffsets

    if angles == nil or offsets == nil then
        return
    end

    local centralAxis = self:GetNativeCentralAxis(group, angles, offsets)
    group.NativeCentralAimAngle = centralAxis
    group.FlightReady = true
    group.NativeLayoutFrame = frame

    for hash, launchAngle in pairs(angles) do
        local entry = group.Entries[hash]
        local memberState = entry
            and entry.Knife
            and entry.Knife:GetData()[STATE_KEY]

        if entry ~= nil
            and memberState ~= nil
            and memberState.Flying
            and entry.LaunchFlightId == group.FlightId
        then
            entry.NativeLaunchAngle = launchAngle
            entry.NativeLaunchCaptureFrame = frame
            memberState.LaunchAngle = launchAngle
            memberState.BaseAimAngle = centralAxis
            memberState.ControlledAngle = launchAngle
            memberState.AngularVelocity = 0
            entry.Knife.Rotation = launchAngle
                - (entry.Knife.RotationOffset or 0)
        end
    end
end

function MomsKnifeHomingModule:OnPostUpdate()
    local frame = Game():GetFrameCount()

    for _, group in pairs(self.KnifeGroups) do
        if not group.FlightReady
            and group.FlightStartFrame ~= nil
            and group.LastFlyingFrame == frame
        then
            local layout = self:BuildKnifeLayout(group, frame)

            if layout ~= nil then
                if group.LayoutShape == nil then
                    group.LayoutCandidateAngles = layout.Angles
                    group.LayoutCandidateOffsets = layout.Offsets
                    group.LayoutShape = layout.Shape
                elseif self:LayoutShapeMatches(
                    group.LayoutShape,
                    layout.Shape
                ) then
                    -- Retain the first absolute native axes when only a common
                    -- rotation changed; the relative spread is already stable.
                else
                    -- Keep observing without steering when vanilla changes the
                    -- relative spread itself (rather than applying one common
                    -- homing rotation). The new layout becomes the candidate.
                    group.LayoutCandidateAngles = layout.Angles
                    group.LayoutCandidateOffsets = layout.Offsets
                    group.LayoutShape = layout.Shape
                end

                local memberCount = #layout.Members
                local elapsed = frame - group.FlightStartFrame

                if memberCount == 1 or elapsed >= 1 then
                    self:FinalizeKnifeLayout(group, frame)
                end
            end
        end
    end
end

function MomsKnifeHomingModule:MatchesDistanceCalibration(
    state,
    preparedMaxDistance,
    sourceRange
)
    if state.CalibratedMaxDistance == nil
        or state.CalibratedPreparedMaxDistance == nil
        or math.abs(
            state.CalibratedPreparedMaxDistance - preparedMaxDistance
        ) > PREPARED_DISTANCE_MATCH_EPSILON
    then
        return false
    end

    if state.CalibratedSourceRange == nil or sourceRange == nil then
        return state.CalibratedSourceRange == sourceRange
    end

    return math.abs(state.CalibratedSourceRange - sourceRange)
        <= RANGE_MATCH_EPSILON
end

function MomsKnifeHomingModule:StabilizeMaxDistance(knife, state)
    local baseline = state.BaselineMaxDistance

    if baseline == nil or baseline <= 0 then
        return
    end

    local baseAttackRange = self:GetBaseMaximumAttackRange(knife, state)
    local maximumAttackRange = baseAttackRange * MAX_RANGE_EXTENSION
    local origin = self:GetRotationOrigin(knife, state)
    local aimAngle = state.MultiKnifeGroup and state.BaseAimAngle
        or state.LaunchAngle
    local farthestDistance = baseAttackRange

    if baseAttackRange > 0 and aimAngle ~= nil then
        for _, target in ipairs(self:GetCandidates()) do
            local delta = target.Position - origin
            local distance = delta:Length()

            if distance <= maximumAttackRange
                and math.abs(AngleDifference(
                    VectorAngle(delta),
                    aimAngle
                )) <= TRACKING_CONE
            then
                farthestDistance = math.max(farthestDistance, distance)
            end
        end
    end

    local requiredDistance = baseline

    if baseAttackRange > 0 then
        requiredDistance = baseline * math.min(
            MAX_RANGE_EXTENSION,
            farthestDistance / baseAttackRange
        )
    end

    state.FlightMaxDistance = math.max(
        state.FlightMaxDistance or baseline,
        requiredDistance
    )

    local group = state.KnifeGroup

    if state.MultiKnifeGroup and group ~= nil then
        group.FlightMaxDistance = math.max(
            group.FlightMaxDistance or baseline,
            state.FlightMaxDistance
        )
        state.FlightMaxDistance = group.FlightMaxDistance

        for _, entry in pairs(group.Entries) do
            local memberState = entry.Knife
                and entry.Knife:GetData()[STATE_KEY]

            if memberState ~= nil
                and memberState.Flying
                and entry.LaunchFlightId == group.FlightId
            then
                memberState.FlightMaxDistance = math.max(
                    memberState.FlightMaxDistance
                        or memberState.BaselineMaxDistance
                        or baseline,
                    group.FlightMaxDistance
                )
                entry.Knife.MaxDistance = memberState.FlightMaxDistance
            end
        end
    end

    knife.MaxDistance = state.FlightMaxDistance
end

function MomsKnifeHomingModule:GetPredictedPosition(
    knife,
    state,
    target,
    origin,
    knifeDistance
)
    local relativePosition = target.Position - origin
    local targetVelocity, turnRate, speedChange, sourceVelocity =
        self:GetTargetMotion(
            knife,
            state,
            target
        )
    local radialSpeed = state.HoldDistance ~= nil
            and state.HoldRadialVelocity
        or state.RadialSpeed
        or knife:GetKnifeVelocity()
    local maximumFrames = self:GetMaximumInterceptFrames(
        knife,
        state,
        knifeDistance,
        radialSpeed
    )
    local interceptFrames = self:SolveCurvedInterceptTime(
        relativePosition,
        targetVelocity,
        turnRate,
        speedChange,
        sourceVelocity,
        knifeDistance,
        radialSpeed,
        maximumFrames
    )

    -- Mom's Knife and NPCs collide as extended bodies, not points. Once the
    -- blade is already crossing the target's radial band, a long intercept
    -- lead steers past fast orbiters before collision is evaluated. Retain a
    -- half-update lead for motion continuity while aligning for contact.
    local contactWindow = (target.Size or 0)
        + (knife.Size or 0)
        + CONTACT_RADIAL_MARGIN

    if math.abs(relativePosition:Length() - knifeDistance) <= contactWindow then
        interceptFrames = math.min(interceptFrames, CONTACT_LEAD_FRAMES)
    end

    local predictedPosition = target.Position + self:PredictTargetDisplacement(
        targetVelocity,
        turnRate,
        interceptFrames,
        speedChange
    )
    local predictedOrigin = origin + sourceVelocity * interceptFrames
    local predictedDistance = (predictedPosition - predictedOrigin):Length()
    local futureKnifeDistance = math.max(
        0,
        knifeDistance + radialSpeed * interceptFrames
    )

    return predictedPosition,
        interceptFrames,
        math.abs(predictedDistance - futureKnifeDistance),
        predictedOrigin
end

function MomsKnifeHomingModule:IsReachable(
    knife,
    state,
    target,
    cone
)
    if not IsTargetableEnemy(target) then
        return false
    end

    local origin = self:GetRotationOrigin(knife, state)
    local delta = target.Position - origin
    local radialDistance = delta:Length()
    local maximumReach = self:GetMaximumAttackRange(knife, state)

    if radialDistance <= 0.01 or radialDistance > maximumReach then
        return false
    end

    local targetAngle = VectorAngle(delta)
    return math.abs(AngleDifference(targetAngle, state.LaunchAngle)) <= cone
end

function MomsKnifeHomingModule:ScoreTarget(knife, state, target)
    local origin = self:GetRotationOrigin(knife, state)
    local knifeDistance = knife:GetKnifeDistance()
    local predicted, interceptFrames, radialError, predictedOrigin =
        self:GetPredictedPosition(
        knife,
        state,
        target,
        origin,
        knifeDistance
    )
    local delta = predicted - predictedOrigin
    local targetAngle = VectorAngle(delta)
    local angleCost = math.abs(
        AngleDifference(targetAngle, state.ControlledAngle)
    )
    local turnFrames = angleCost / MAX_ANGULAR_SPEED
    local turnDeficit = math.max(0, turnFrames - interceptFrames)

    local physicalScore = turnDeficit * 100
        + radialError * 8
        + interceptFrames * 2
        + angleCost * 0.35
    local consensusScore = physicalScore

    if state.MultiKnifeGroup and state.BaseAimAngle ~= nil then
        -- Multi-shot Mom's Knife throws should agree on a target whenever it
        -- remains reachable from each individual spread line. Use the owner's
        -- central aim for a deterministic shared ordering, while retaining the
        -- physical score as the tie-breaker for each knife.
        local centralAngleCost = math.abs(
            AngleDifference(targetAngle, state.BaseAimAngle)
        )
        consensusScore = radialError * 8
            + interceptFrames * 2
            + centralAngleCost * 0.35
    end

    return physicalScore,
        interceptFrames,
        consensusScore
end

function MomsKnifeHomingModule:BuildTargetPlan(
    knife,
    state,
    allowHitTargets,
    excludedTarget
)
    local plan = {}
    local excludedHash = excludedTarget and EntityHash(excludedTarget) or nil

    for _, target in ipairs(self:GetCandidates()) do
        local hash = EntityHash(target)
        local wasHit = state.HitTargets[hash] == true

        if hash ~= excludedHash
            and (allowHitTargets or not wasHit)
            and self:IsReachable(knife, state, target, TRACKING_CONE)
        then
            local score, interceptFrames, consensusScore = self:ScoreTarget(
                knife,
                state,
                target
            )
            plan[#plan + 1] = {
                Target = target,
                Score = score,
                ConsensusScore = consensusScore,
                InterceptFrames = interceptFrames,
                Hash = hash,
            }
        end
    end

    table.sort(plan, function(left, right)
        if state.MultiKnifeGroup
            and math.abs(left.ConsensusScore - right.ConsensusScore)
                > INTERCEPT_EPSILON
        then
            return left.ConsensusScore < right.ConsensusScore
        end

        if state.MultiKnifeGroup and left.Hash ~= right.Hash then
            return left.Hash < right.Hash
        end

        if math.abs(left.Score - right.Score) > INTERCEPT_EPSILON then
            return left.Score < right.Score
        end

        return left.Hash < right.Hash
    end)

    return plan
end

function MomsKnifeHomingModule:FindTarget(
    knife,
    state,
    allowHitTargets,
    excludedTarget
)
    local plan = self:BuildTargetPlan(
        knife,
        state,
        allowHitTargets,
        excludedTarget
    )

    return plan[1] and plan[1].Target or nil, plan
end

function MomsKnifeHomingModule:IsWithinHoldRange(knife, state, target)
    if not IsTargetableEnemy(target) then
        return false
    end

    local maximumReach = self:GetMaximumAttackRange(knife, state)
    local origin = self:GetRotationOrigin(knife, state)
    local currentDelta = target.Position - origin

    if currentDelta:Length() > maximumReach then
        return false
    end

    local targetAngle = VectorAngle(currentDelta)

    return math.abs(AngleDifference(targetAngle, state.LaunchAngle))
        <= TRACKING_CONE
end

function MomsKnifeHomingModule:FindFarthestHitTarget(
    knife,
    state,
    preferredTarget
)
    local bestTarget
    local bestDistance

    if state.HoldTarget ~= nil
        and state.HitTargets[EntityHash(state.HoldTarget)] == true
        and self:IsWithinHoldRange(knife, state, state.HoldTarget)
    then
        bestTarget = state.HoldTarget
        local origin = self:GetRotationOrigin(knife, state)
        bestDistance = (state.HoldTarget.Position - origin):Length()
    end

    if preferredTarget ~= nil
        and state.HitTargets[EntityHash(preferredTarget)] == true
        and self:IsWithinHoldRange(knife, state, preferredTarget)
    then
        local origin = self:GetRotationOrigin(knife, state)
        local distance = (preferredTarget.Position - origin):Length()

        if bestDistance == nil or distance > bestDistance then
            bestTarget = preferredTarget
            bestDistance = distance
        end
    end

    for _, target in ipairs(self:GetCandidates()) do
        if state.HitTargets[EntityHash(target)] == true
            and self:IsWithinHoldRange(knife, state, target)
        then
            local origin = self:GetRotationOrigin(knife, state)
            local distance = (target.Position - origin):Length()
            local switchMargin = bestTarget == state.HoldTarget
                    and state.HoldTarget ~= nil
                and HOLD_SWITCH_MARGIN
                or 0

            if bestDistance == nil
                or distance > bestDistance + switchMargin
            then
                bestTarget = target
                bestDistance = distance
            end
        end
    end

    return bestTarget
end

function MomsKnifeHomingModule:BeginHoldRadialMotion(knife, state)
    if state.HoldTarget == nil or state.HoldDistance ~= nil then
        return
    end

    local baseline = self:GetMaximumAttackRange(knife, state)
    state.HoldDistance = math.max(
        0,
        math.min(baseline, knife:GetKnifeDistance())
    )
    state.HoldRadialVelocity = math.max(
        -HOLD_MAX_RADIAL_SPEED,
        math.min(
            HOLD_MAX_RADIAL_SPEED,
            state.RadialSpeed or knife:GetKnifeVelocity()
        )
    )
    state.HoldRetracting = false
    state.HoldRetractionNativeStart = nil
    state.HoldRetractionVisualStart = nil
end

function MomsKnifeHomingModule:UpdateHoldRadialMotion(knife, state)
    if state.HoldTarget == nil and not state.HoldRetracting then
        state.HoldDistance = nil
        state.HoldRadialVelocity = nil
        state.HoldRetractionNativeStart = nil
        state.HoldRetractionVisualStart = nil
        return nil
    end

    local baseline = self:GetMaximumAttackRange(knife, state)

    self:BeginHoldRadialMotion(knife, state)

    local nativeDistance = math.max(0, knife:GetKnifeDistance())

    if state.HoldRetracting
        or (state.RadialSpeed or 0) < -MOTION_EPSILON
    then
        if not state.HoldRetracting then
            state.HoldRetracting = true
            state.HoldRetractionVisualStart = state.HoldDistance
            state.HoldRetractionNativeStart = math.max(
                nativeDistance,
                nativeDistance - (state.RadialSpeed or 0)
            )
        end

        local nativeStart = math.max(
            MOTION_EPSILON,
            state.HoldRetractionNativeStart or nativeDistance
        )
        local previousDistance = state.HoldDistance
        local returnProgress = math.max(
            0,
            math.min(1, nativeDistance / nativeStart)
        )
        state.HoldDistance = math.min(
            previousDistance,
            (state.HoldRetractionVisualStart or previousDistance)
                * returnProgress
        )
        state.HoldRadialVelocity = state.HoldDistance - previousDistance
        return state.HoldDistance
    end

    local origin = self:GetRotationOrigin(knife, state)
    local desiredDistance = math.min(
        baseline,
        (state.HoldTarget.Position - origin):Length()
    )

    local radialError = desiredDistance - state.HoldDistance
    local desiredVelocity = math.max(
        -HOLD_MAX_RADIAL_SPEED,
        math.min(
            HOLD_MAX_RADIAL_SPEED,
            radialError * HOLD_RADIAL_RESPONSE
        )
    )

    if math.abs(radialError) <= HOLD_DISTANCE_EPSILON then
        desiredVelocity = 0
    end

    state.HoldRadialVelocity = MoveTowards(
        state.HoldRadialVelocity or 0,
        desiredVelocity,
        HOLD_RADIAL_ACCELERATION
    )
    local nextDistance

    if math.abs(radialError) <= HOLD_DISTANCE_EPSILON
        and math.abs(state.HoldRadialVelocity)
            <= HOLD_RADIAL_ACCELERATION
    then
        nextDistance = desiredDistance
        state.HoldRadialVelocity = 0
    else
        nextDistance = state.HoldDistance + state.HoldRadialVelocity
    end

    local clampedDistance = math.max(
        0,
        math.min(baseline, nextDistance)
    )

    if math.abs(clampedDistance - nextDistance) > INTERCEPT_EPSILON then
        state.HoldRadialVelocity = 0
    end

    state.HoldDistance = clampedDistance
    return state.HoldDistance
end

function MomsKnifeHomingModule:ApplyControlledPosition(
    knife,
    state,
    controlledDistance
)
    local origin = self:GetRotationOrigin(knife, state)
    local radians = math.rad(state.ControlledAngle)

    -- Keep the native entity, damage, radial distance and flight timer. Its
    -- live hitbox follows only part of the owner's displacement during the
    -- outbound phase, then converges smoothly back to the owner throughout
    -- native retraction. A final-target hold may substitute its own controlled
    -- radial distance without changing this shared moving origin.
    knife.Position = origin + Vector(
        math.cos(radians) * controlledDistance,
        math.sin(radians) * controlledDistance
    )
end

function MomsKnifeHomingModule:UpdateOriginRetraction(knife, state)
    if state.OriginRetracting
        or (state.RadialSpeed or 0) >= -MOTION_EPSILON
    then
        return
    end

    local nativeDistance = math.max(0, knife:GetKnifeDistance())
    state.OriginRetracting = true
    state.OriginRetractionNativeStart = math.max(
        nativeDistance,
        nativeDistance - (state.RadialSpeed or 0)
    )
end


function MomsKnifeHomingModule:BeginFlight(knife, state)
    local charge = state.PreparedCharge or knife.Charge or 0
    local sourceRange = state.PreparedSourceRange

    if sourceRange == nil then
        sourceRange = self:GetSourceRange(knife)
    end

    local preparedMaxDistance = state.PreparedMaxDistance

    if preparedMaxDistance == nil or preparedMaxDistance <= 0 then
        preparedMaxDistance = knife.MaxDistance
    end

    if self:MatchesDistanceCalibration(
        state,
        preparedMaxDistance,
        sourceRange
    ) then
        state.BaselineMaxDistance = state.CalibratedMaxDistance
    else
        state.BaselineMaxDistance = preparedMaxDistance
        state.CalibratedMaxDistance = preparedMaxDistance
        state.CalibratedPreparedMaxDistance = preparedMaxDistance
        state.CalibratedCharge = charge
        state.CalibratedSourceRange = sourceRange
    end

    local source = knife.SpawnerEntity
    state.LaunchOrigin = CopyVector(self:GetRotationOrigin(knife))
    state.LaunchSourcePosition = source ~= nil
            and source.Position ~= nil
        and CopyVector(source.Position)
        or nil
    state.OriginRetracting = false
    state.OriginRetractionNativeStart = nil
    state.Flying = true
    -- MC_POST_KNIFE_UPDATE observes the first flying frame only after vanilla
    -- homing has already rotated toward its stale target position. Preserve
    -- the player's last charging/held angle from the preceding idle frame.
    state.LaunchAngle = state.PreparedLaunchAngle
        or GetWorldRotation(knife)
    state.BaseAimAngle = state.PreparedBaseAimAngle
        or state.LaunchAngle - (knife.RotationOffset or 0)
    state.ControlledAngle = state.LaunchAngle
    state.AngularVelocity = 0
    state.Target = nil
    state.NextTarget = nil
    state.TargetPlan = {}
    state.HitTargets = {}
    state.HoldTarget = nil
    state.HoldDistance = nil
    state.HoldRadialVelocity = nil
    state.HoldRetracting = false
    state.HoldRetractionNativeStart = nil
    state.HoldRetractionVisualStart = nil
    state.BaselineSourceRange = sourceRange
    state.FlightMaxDistance = state.BaselineMaxDistance
    state.PreviousKnifeDistance = knife:GetKnifeDistance()
    state.DistanceFrame = Game():GetFrameCount()
    state.RadialSpeed = knife:GetKnifeVelocity()
    state.LastSteeringFrame = nil
end

function MomsKnifeHomingModule:OnKnifeUpdate(knife)
    local data = knife:GetData()
    local state = data[STATE_KEY]

    if not self.Context:IsEnabled(SETTING_KEY)
        or knife.Variant ~= MOMS_KNIFE_VARIANT
        or not knife:HasTearFlags(HOMING_FLAG)
    then
        data[STATE_KEY] = nil
        return
    end

    if state == nil or state.Version ~= STATE_VERSION then
        state = {
            Version = STATE_VERSION,
            Flying = false,
            HitTargets = {},
        }
        data[STATE_KEY] = state
    end

    local frame = Game():GetFrameCount()
    local knifeGroup = self:RegisterKnifeGroup(knife, frame)
    state.MultiKnifeGroup = knifeGroup ~= nil and knifeGroup.Count > 1
    state.KnifeGroup = knifeGroup
    local flying = knife:IsFlying()

    if not flying then
        local finishedFlight = state.Flying

        -- A target beyond native range may temporarily extend MaxDistance for
        -- this throw. Some native knife states leave that written value on the
        -- entity when flight ends. Restore only the value that this module
        -- wrote, before recording the next held/charging baseline, so a far
        -- target cannot silently lengthen every later throw. If vanilla has
        -- already supplied a different charged/range-dependent value, retain
        -- it as the new baseline instead.
        if finishedFlight
            and state.BaselineMaxDistance ~= nil
            and state.FlightMaxDistance ~= nil
            and math.abs(knife.MaxDistance - state.FlightMaxDistance)
                <= PREPARED_DISTANCE_MATCH_EPSILON
        then
            knife.MaxDistance = state.BaselineMaxDistance
        end

        state.Flying = false
        state.Target = nil
        state.NextTarget = nil
        state.TargetPlan = {}
        state.AngularVelocity = 0
        state.HoldTarget = nil
        state.HoldDistance = nil
        state.HoldRadialVelocity = nil
        state.HoldRetracting = false
        state.HoldRetractionNativeStart = nil
        state.HoldRetractionVisualStart = nil
        state.LaunchOrigin = nil
        state.LaunchSourcePosition = nil
        state.OriginRetracting = false
        state.OriginRetractionNativeStart = nil
        state.FlightMaxDistance = nil
        state.LastSteeringFrame = nil
        state.PreparedLaunchAngle = self:GetHeldAimAngle(knife, knifeGroup)
        state.PreparedBaseAimAngle = self:GetHeldBaseAimAngle(
            knife,
            knifeGroup
        )
        state.PreparedMaxDistance = knife.MaxDistance
        state.PreparedCharge = knife.Charge or 0
        state.PreparedSourceRange = self:GetSourceRange(knife)
        -- Build observed velocity, turn-rate and acceleration history while
        -- the homing knife is held. The first release then leads a moving
        -- target immediately instead of spending one throw learning motion.
        self:GetCandidates()
        return
    end

    if not state.Flying then
        self:BeginFlight(knife, state)
    end

    if state.MultiKnifeGroup and knifeGroup.NativeCentralAimAngle ~= nil then
        state.BaseAimAngle = knifeGroup.NativeCentralAimAngle
    end

    -- Do not write any flying member until the frame-end collector has seen
    -- the complete native volley. This prevents a release-spawned knife that
    -- updates late (20/20 and stacked shot multipliers in particular) from
    -- inheriting whichever earlier member happened to run first.
    if not knifeGroup.FlightReady then
        self:StabilizeMaxDistance(knife, state)
        return
    end

    if state.LastSteeringFrame == frame then
        self:StabilizeMaxDistance(knife, state)
        knife.Rotation = state.ControlledAngle
            - (knife.RotationOffset or 0)
        self:ApplyControlledPosition(
            knife,
            state,
            state.HoldDistance or knife:GetKnifeDistance()
        )
        return
    end
    state.LastSteeringFrame = frame

    self:GetRadialSpeed(knife, state, frame)
    self:UpdateOriginRetraction(knife, state)

    -- Refresh target positions once before validating an existing lock. This
    -- also derives real per-frame displacement for NPCs whose Velocity field
    -- lags behind their visible movement.
    self:GetCandidates()

    -- Homing can rewrite MaxDistance according to the current target. Reuse
    -- one exact calibration for the same prepared distance/range. Knife
    -- travel time follows this radial limit, so outbound and return timing
    -- stay consistent without reshooting or replacing the native knife.
    self:StabilizeMaxDistance(knife, state)

    local holdReturning = state.HoldDistance ~= nil
        and (state.RadialSpeed or 0) < -MOTION_EPSILON

    if holdReturning then
        state.Target = nil
        state.NextTarget = nil
        state.TargetPlan = {}
    else
        if state.Target ~= nil
            and not self:IsReachable(
                knife,
                state,
                state.Target,
                TRACKING_CONE
            )
        then
            state.Target = nil
            state.NextTarget = nil
            state.TargetPlan = {}
            state.HoldTarget = nil
        end

        if state.HoldTarget ~= nil then
            local unhitTarget = self:FindTarget(knife, state, false)

            if unhitTarget ~= nil then
                state.HoldTarget = nil
                state.Target = unhitTarget
                local _, plan = self:FindTarget(
                    knife,
                    state,
                    false,
                    unhitTarget
                )
                state.TargetPlan = plan
                state.NextTarget = plan[1] and plan[1].Target or nil
            else
                state.HoldTarget = self:FindFarthestHitTarget(knife, state)
                state.Target = state.HoldTarget
                state.NextTarget = nil
                state.TargetPlan = {}
            end
        end

        if state.Target == nil then
            local plan
            state.Target, plan = self:FindTarget(knife, state, false)
            state.TargetPlan = plan
            state.NextTarget = plan[2] and plan[2].Target or nil

            if state.Target == nil then
                -- After crossing every reachable target, stay aligned with the
                -- farthest already-hit enemy still inside the calibrated range.
                -- Native knife distance and timing continue to control retraction.
                state.HoldTarget = self:FindFarthestHitTarget(knife, state)
                state.Target = state.HoldTarget
                state.NextTarget = nil
                state.TargetPlan = {}
            end
        elseif state.HoldTarget == nil then
            local _, plan = self:FindTarget(
                knife,
                state,
                false,
                state.Target
            )
            state.TargetPlan = plan
            state.NextTarget = plan[1] and plan[1].Target or nil
        end
    end

    local holdDistance = self:UpdateHoldRadialMotion(knife, state)

    local desiredAngle = state.HoldRetracting
            and state.ControlledAngle
        or state.LaunchAngle
    if state.Target ~= nil then
        local origin = self:GetRotationOrigin(knife, state)
        local predicted, _, _, predictedOrigin = self:GetPredictedPosition(
            knife,
            state,
            state.Target,
            origin,
            holdDistance or knife:GetKnifeDistance()
        )
        desiredAngle = VectorAngle(predicted - predictedOrigin)
    end

    desiredAngle = ClampAngleAround(
        desiredAngle,
        state.LaunchAngle,
        TRACKING_CONE
    )
    local angleError = AngleDifference(
        desiredAngle,
        state.ControlledAngle
    )
    local desiredAngularSpeed = math.min(
        MAX_ANGULAR_SPEED,
        math.abs(angleError) * STEERING_RESPONSE,
        GetBrakingLimitedSpeed(math.abs(angleError))
    )
    local desiredAngularVelocity = angleError < 0
            and -desiredAngularSpeed
        or desiredAngularSpeed
    state.AngularVelocity = MoveTowards(
        state.AngularVelocity or 0,
        desiredAngularVelocity,
        MAX_ANGULAR_ACCELERATION
    )
    local previousControlledAngle = state.ControlledAngle
    state.ControlledAngle = ClampAngleAround(
        state.ControlledAngle + state.AngularVelocity,
        state.LaunchAngle,
        TRACKING_CONE
    )
    state.AngularVelocity = AngleDifference(
        state.ControlledAngle,
        previousControlledAngle
    )

    knife.Rotation = state.ControlledAngle - (knife.RotationOffset or 0)
    self:ApplyControlledPosition(
        knife,
        state,
        holdDistance or knife:GetKnifeDistance()
    )
end

function MomsKnifeHomingModule:OnKnifeCollision(knife, collider)
    if not self.Context:IsEnabled(SETTING_KEY)
        or knife.Variant ~= MOMS_KNIFE_VARIANT
        or not knife:HasTearFlags(HOMING_FLAG)
        or not IsTargetableEnemy(collider)
    then
        return
    end

    local state = knife:GetData()[STATE_KEY]

    if state == nil or not state.Flying then
        return
    end

    state.HitTargets[EntityHash(collider)] = true

    local function IsUsableUnhitTarget(target)
        return target ~= nil
            and state.HitTargets[EntityHash(target)] ~= true
            and self:IsReachable(knife, state, target, TRACKING_CONE)
    end

    local nextTarget
    local collidedWithCurrent = state.Target ~= nil
        and EntityHash(state.Target) == EntityHash(collider)

    if not collidedWithCurrent and IsUsableUnhitTarget(state.Target) then
        -- Crossing a non-selected enemy must not discard the still-reachable
        -- target that this knife was already steering toward.
        nextTarget = state.Target
    else
        if IsUsableUnhitTarget(state.NextTarget) then
            nextTarget = state.NextTarget
        end

        if nextTarget == nil then
            for _, entry in ipairs(state.TargetPlan or {}) do
                if IsUsableUnhitTarget(entry.Target) then
                    nextTarget = entry.Target
                    break
                end
            end
        end

        if nextTarget == nil then
            nextTarget = self:FindTarget(knife, state, false)
        end
    end

    if nextTarget == nil then
        state.HoldTarget = self:FindFarthestHitTarget(
            knife,
            state,
            collider
        )
        state.Target = state.HoldTarget
        state.NextTarget = nil
        state.TargetPlan = {}
        self:BeginHoldRadialMotion(knife, state)
        return
    end

    state.HoldTarget = nil
    state.HoldDistance = nil
    state.HoldRadialVelocity = nil
    state.HoldRetracting = false
    state.HoldRetractionNativeStart = nil
    state.HoldRetractionVisualStart = nil
    state.Target = nextTarget
    local _, plan = self:FindTarget(knife, state, false, nextTarget)
    state.TargetPlan = plan
    state.NextTarget = plan[1] and plan[1].Target or nil
end

return MomsKnifeHomingModule
