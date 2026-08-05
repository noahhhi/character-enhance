local MomsKnifeHomingModule = {}
MomsKnifeHomingModule.__index = MomsKnifeHomingModule

local SETTING_KEY = "momsKnifeHomingFix"
local MOMS_KNIFE_VARIANT = 0
local STATE_KEY = "CharacterEnhanceMomsKnifeHoming"
local STATE_VERSION = 15
local HOMING_FLAG = TearFlags.TEAR_HOMING
local TRACKING_CONE = 40
local MAX_ANGULAR_SPEED = 15
local MAX_ANGULAR_ACCELERATION = 6
local MAX_TANGENTIAL_STEERING_SPEED = 14
local MAX_TANGENTIAL_STEERING_ACCELERATION = 3.5
local MIN_STEERING_RADIUS = 24
local TURN_FEASIBILITY_STEP = 0.5
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
local HOLD_RADIAL_FEED_FORWARD = 0.55
local HOLD_DISTANCE_EPSILON = 0.25
local PREPARED_DISTANCE_MATCH_EPSILON = 0.5
local RANGE_MATCH_EPSILON = 0.5
local LAYOUT_SHAPE_EPSILON = 0.1
local LAYOUT_OFFSET_SYMMETRY_EPSILON = 0.5
local WIDE_LAYOUT_SPAN = 179.5
local FLIGHT_ORIGIN_FOLLOW = 0.8
local TARGET_TURN_FEASIBILITY_SLACK = 1
local SEQUENCE_LOOKAHEAD_FRAMES = 1
local SEQUENCE_LOOKAHEAD_FRACTION = 0.35
local MAX_SEQUENCE_LOOKAHEAD_ANGLE = 6
local KNIFE_SPRITE_FORWARD_OFFSET = 90
local GROUP_CONTACT_RETENTION_FRAMES = 1
local MAX_NATIVE_BASE_EXTENSION = 60
local NATIVE_RADIAL_MATCH_EPSILON = 8

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

local function GetBrakingLimitedSpeed(
    distance,
    maximumSpeed,
    maximumAcceleration
)
    local low = 0
    local high = maximumSpeed or MAX_ANGULAR_SPEED
    local acceleration = maximumAcceleration
        or MAX_ANGULAR_ACCELERATION

    -- Include the current step plus every future step after decelerating by
    -- MAX_ANGULAR_ACCELERATION. This starts braking early enough that ordinary
    -- target motion does not require an abrupt final-frame speed truncation.
    for _ = 1, 12 do
        local candidate = (low + high) * 0.5
        local stoppingDistance = 0
        local speed = candidate

        while speed > INTERCEPT_EPSILON do
            stoppingDistance = stoppingDistance + speed
            speed = math.max(0, speed - acceleration)
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
    local isDebugDummy = entity ~= nil
        and entity.Type == EntityType.ENTITY_DUMMY

    return entity ~= nil
        and entity:Exists()
        and not entity:IsDead()
        and entity:ToNPC() ~= nil
        and (isDebugDummy
            or (entity:IsEnemy() and entity:IsActiveEnemy(false)))
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
    local knifeDistance = state.NativeRadialDistance
        or knife:GetKnifeDistance()
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

function MomsKnifeHomingModule:CaptureNativeRadialDistance(knife, state)
    local origin = self:GetRotationOrigin(knife, state)
    local actualDistance = (knife.Position - origin):Length()
    local pathDistance = knife:GetKnifeDistance()
    local radialOffset = state.NativeRadialOffset

    -- GetKnifeDistance excludes Mom's Knife's native base extension (about
    -- 30 world units in Repentance+ 1.9.7.15). Using it as a world radius
    -- makes a controlled write teleport between the native and shortened
    -- rays. Capture the real entity radius after every native knife update;
    -- the path value remains responsible only for native flight timing.
    if radialOffset == nil
        and actualDistance > MOTION_EPSILON
        and actualDistance >= pathDistance
        and actualDistance - pathDistance <= MAX_NATIVE_BASE_EXTENSION
    then
        state.NativeRadialDistance = actualDistance
        state.NativeRadialOffset = actualDistance - pathDistance
    elseif radialOffset ~= nil
        and math.abs(
            actualDistance - (pathDistance + radialOffset)
        ) <= NATIVE_RADIAL_MATCH_EPSILON
    then
        state.NativeRadialDistance = actualDistance
    else
        state.NativeRadialDistance = math.max(
            0,
            pathDistance + (radialOffset or 0)
        )
    end

    if state.PreviousKnifeDistance == nil then
        state.PreviousKnifeDistance = state.NativeRadialDistance
        state.DistanceFrame = Game():GetFrameCount()
    end

    return state.NativeRadialDistance
end

function MomsKnifeHomingModule:GetControlledRadialDistance(knife, state)
    if state.HoldDistance ~= nil then
        return state.HoldDistance
    end

    -- Preserve the engine's native world-space radius and render interpolation
    -- until final-target retention explicitly takes ownership of distance.
    return state.NativeRadialDistance
        or self:CaptureNativeRadialDistance(knife, state)
end

function MomsKnifeHomingModule:GetControlledRadialSpeed(knife, state)
    if state.HoldDistance ~= nil then
        return state.HoldRadialVelocity or 0
    end

    return state.RadialSpeed
        or knife:GetKnifeVelocity()
end

function MomsKnifeHomingModule:GetSteeringMotionLimits(knifeDistance)
    local steeringRadius = math.max(
        MIN_STEERING_RADIUS,
        knifeDistance or 0
    )
    local maximumAngularSpeed = math.min(
        MAX_ANGULAR_SPEED,
        math.deg(MAX_TANGENTIAL_STEERING_SPEED / steeringRadius)
    )
    local maximumAngularAcceleration = math.min(
        MAX_ANGULAR_ACCELERATION,
        math.deg(
            MAX_TANGENTIAL_STEERING_ACCELERATION / steeringRadius
        )
    )

    return maximumAngularSpeed, maximumAngularAcceleration
end

function MomsKnifeHomingModule:GetTurnCapacity(
    state,
    knifeDistance,
    radialSpeed,
    frames,
    direction
)
    if frames <= 0 or direction == 0 then
        return 0
    end

    local angularVelocity = state.AngularVelocity or 0
    local turned = 0
    local elapsed = 0

    while elapsed < frames - INTERCEPT_EPSILON do
        local step = math.min(
            TURN_FEASIBILITY_STEP,
            frames - elapsed
        )
        local projectedDistance = math.max(
            0,
            knifeDistance + radialSpeed * (elapsed + step)
        )
        local maximumSpeed, maximumAcceleration =
            self:GetSteeringMotionLimits(projectedDistance)
        local desiredVelocity = direction * maximumSpeed
        angularVelocity = MoveTowards(
            angularVelocity,
            desiredVelocity,
            maximumAcceleration * step
        )
        angularVelocity = math.max(
            -maximumSpeed,
            math.min(maximumSpeed, angularVelocity)
        )
        turned = turned + angularVelocity * step
        elapsed = elapsed + step
    end

    return math.max(0, turned * direction)
end

function MomsKnifeHomingModule:GetBoundedSteeringVelocity(
    state,
    desiredAngularVelocity,
    knifeDistance
)
    local radius = math.max(MOTION_EPSILON, knifeDistance or 0)
    local previousAngularVelocity = state.AngularVelocity or 0
    local previousTangentialVelocity = state.TangentialVelocity

    if previousTangentialVelocity == nil then
        previousTangentialVelocity = math.rad(previousAngularVelocity)
            * (state.PreviousControlledDistance or radius)
    end

    local minimumTangentialVelocity = math.max(
        -MAX_TANGENTIAL_STEERING_SPEED,
        previousTangentialVelocity
            - MAX_TANGENTIAL_STEERING_ACCELERATION
    )
    local maximumTangentialVelocity = math.min(
        MAX_TANGENTIAL_STEERING_SPEED,
        previousTangentialVelocity
            + MAX_TANGENTIAL_STEERING_ACCELERATION
    )
    local minimumAngularVelocity = math.max(
        -MAX_ANGULAR_SPEED,
        previousAngularVelocity - MAX_ANGULAR_ACCELERATION,
        math.deg(minimumTangentialVelocity / radius)
    )
    local maximumAngularVelocity = math.min(
        MAX_ANGULAR_SPEED,
        previousAngularVelocity + MAX_ANGULAR_ACCELERATION,
        math.deg(maximumTangentialVelocity / radius)
    )

    if minimumAngularVelocity > maximumAngularVelocity then
        -- Native knife distance changes gradually in normal flight, so these
        -- intervals ordinarily overlap. If another effect teleports the live
        -- radial hitbox, prioritize the world-speed boundary that prevents a
        -- large visible sideways jump.
        local absoluteLimit = math.min(
            MAX_ANGULAR_SPEED,
            math.deg(MAX_TANGENTIAL_STEERING_SPEED / radius)
        )
        minimumAngularVelocity = math.max(
            -absoluteLimit,
            previousAngularVelocity - MAX_ANGULAR_ACCELERATION
        )
        maximumAngularVelocity = math.min(
            absoluteLimit,
            previousAngularVelocity + MAX_ANGULAR_ACCELERATION
        )

        if minimumAngularVelocity > maximumAngularVelocity then
            minimumAngularVelocity = -absoluteLimit
            maximumAngularVelocity = absoluteLimit
        end
    end

    local angularVelocity = math.max(
        minimumAngularVelocity,
        math.min(maximumAngularVelocity, desiredAngularVelocity)
    )
    return angularVelocity, math.rad(angularVelocity) * radius
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

function MomsKnifeHomingModule:GetHardMaximumAttackRange(knife, state)
    return self:GetBaseMaximumAttackRange(knife, state)
        * MAX_RANGE_EXTENSION
end

function MomsKnifeHomingModule:GetMaximumAttackRange(knife, state)
    if state.RangeEvaluationLimit ~= nil then
        return state.RangeEvaluationLimit
    end

    if state.Flying and state.TrackingAttackRange ~= nil then
        return state.TrackingAttackRange
    end

    return self:GetHardMaximumAttackRange(knife, state)
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

function MomsKnifeHomingModule:GetTrackingAxis(state)
    return state.BaseAimAngle or state.LaunchAngle
end

function MomsKnifeHomingModule:IsInsideTrackingSector(
    knife,
    state,
    target,
    maximumReach
)
    if not IsTargetableEnemy(target) then
        return false
    end

    local trackingAxis = self:GetTrackingAxis(state)

    if trackingAxis == nil then
        return false
    end

    local origin = self:GetRotationOrigin(knife, state)
    local delta = target.Position - origin
    local radialDistance = delta:Length()

    if radialDistance <= 0.01 or radialDistance > maximumReach then
        return false
    end

    return math.abs(AngleDifference(
        VectorAngle(delta),
        trackingAxis
    )) <= TRACKING_CONE
end

function MomsKnifeHomingModule:ClampTrackedAngle(state, angle)
    local trackingAxis = self:GetTrackingAxis(state)
    local launchAngle = state.LaunchAngle

    if trackingAxis == nil or launchAngle == nil then
        return angle
    end

    local launchOffset = AngleDifference(launchAngle, trackingAxis)
    local minimumOffset = math.max(
        -TRACKING_CONE,
        launchOffset - TRACKING_CONE
    )
    local maximumOffset = math.min(
        TRACKING_CONE,
        launchOffset + TRACKING_CONE
    )

    if minimumOffset > maximumOffset then
        return launchAngle
    end

    local desiredOffset = AngleDifference(angle, trackingAxis)
    desiredOffset = math.max(
        minimumOffset,
        math.min(maximumOffset, desiredOffset)
    )
    return trackingAxis + desiredOffset
end

function MomsKnifeHomingModule:ApplyControlledTransform(
    knife,
    state,
    controlledDistance
)
    state.ControlledAngle = ClampAngleAround(
        state.ControlledAngle or state.LaunchAngle,
        state.LaunchAngle,
        TRACKING_CONE
    )
    knife.Rotation = state.ControlledAngle
        - (knife.RotationOffset or 0)

    -- EntityKnife's rendered sprite points along SpriteRotation + 90 degrees.
    -- Vanilla can leave SpriteRotation at a stale homing angle for the first
    -- multi-knife layout frame even after Rotation has been corrected. Write
    -- the final visible angle explicitly so the render and hitbox obey this
    -- knife's own independent launch cone on every flying frame.
    knife.SpriteRotation = state.ControlledAngle
        - KNIFE_SPRITE_FORWARD_OFFSET
    self:ApplyControlledPosition(knife, state, controlledDistance)
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
        group.TrackingAttackRange = nil
        group.TrackingRangeFrame = nil
        group.FlightReady = false
        group.LayoutCandidateAngles = nil
        group.LayoutCandidateOffsets = nil
        group.LayoutShape = nil
        group.CoveredTargets = {}
        group.AssignmentFrame = -1
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
            memberState.NativeLaunchAngle = launchAngle
            memberState.BaseAimAngle = centralAxis
            memberState.LaunchAngle = launchAngle
            memberState.ControlledAngle = memberState.LaunchAngle
            memberState.AngularVelocity = 0
            memberState.TangentialVelocity = 0
            memberState.TrackingAttackRange =
                group.TrackingAttackRange
                or memberState.TrackingAttackRange
            memberState.RangeCalibrated = true
            memberState.PreviousControlledDistance =
                memberState.NativeRadialDistance
                or entry.Knife:GetKnifeDistance()
            memberState.LastSteeringFrame = frame
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

        if group.FlightReady then
            -- Every knife callback updates its own radial and motion state.
            -- Allocate only after all members have completed that work so a
            -- later callback cannot clear its new target while the once-per-
            -- frame assignment guard leaves the volley partially unassigned.
            self:AssignGroupTargets(group, frame)

            for _, entry in pairs(group.Entries) do
                local knife = entry.Knife
                local state = knife and knife:GetData()[STATE_KEY]

                if knife ~= nil
                    and knife:Exists()
                    and knife:IsFlying()
                    and state ~= nil
                    and state.Flying
                    and state.ControlledAngle ~= nil
                then
                    if state.MultiKnifeGroup
                        and not state.HoldRetracting
                        and state.Target == nil
                    then
                        self:PrepareFarthestHitHold(knife, state)
                    end

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

    if state.RangeCalibrated then
        knife.MaxDistance = state.FlightMaxDistance or baseline
        return
    end

    local baseAttackRange = self:GetBaseMaximumAttackRange(knife, state)
    local maximumAttackRange = self:GetHardMaximumAttackRange(knife, state)
    local farthestDistance = baseAttackRange

    if baseAttackRange > 0 and state.LaunchAngle ~= nil then
        local origin = self:GetRotationOrigin(knife, state)
        state.RangeEvaluationLimit = maximumAttackRange

        for _, target in ipairs(self:GetCandidates()) do
            local delta = target.Position - origin
            local distance = delta:Length()
            local targetAngle = distance > 0.01
                    and VectorAngle(delta)
                or nil

            if targetAngle ~= nil
                and self:IsInsideTrackingSector(
                    knife,
                    state,
                    target,
                    maximumAttackRange
                )
                and math.abs(AngleDifference(
                    targetAngle,
                    state.LaunchAngle
                )) <= TRACKING_CONE
                and self:IsTargetMotionFeasible(knife, state, target)
            then
                farthestDistance = math.max(farthestDistance, distance)
            end
        end

        state.RangeEvaluationLimit = nil
    end

    -- A dead final target is no longer a room candidate, but its last valid
    -- contact distance still owns the outbound hold for this throw. Keep that
    -- exact in-range anchor without reopening acquisition all the way to the
    -- 130-percent hard cap.
    for _, distance in pairs(state.HitTargetDistances or {}) do
        if type(distance) == "number"
            and distance >= 0
            and distance <= maximumAttackRange
        then
            farthestDistance = math.max(farthestDistance, distance)
        end
    end

    state.TrackingAttackRange = math.min(
        maximumAttackRange,
        farthestDistance
    )

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
        local frame = Game():GetFrameCount()

        if group.TrackingRangeFrame ~= frame then
            group.TrackingRangeFrame = frame
            group.TrackingAttackRange = baseAttackRange
        end

        group.TrackingAttackRange = math.max(
            group.TrackingAttackRange or baseAttackRange,
            state.TrackingAttackRange
        )
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
                memberState.TrackingAttackRange =
                    group.TrackingAttackRange
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
    local radialSpeed = self:GetControlledRadialSpeed(knife, state)
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
    local maximumReach = self:GetMaximumAttackRange(knife, state)

    if not self:IsInsideTrackingSector(
        knife,
        state,
        target,
        maximumReach
    ) then
        return false
    end

    local origin = self:GetRotationOrigin(knife, state)
    local delta = target.Position - origin
    local targetAngle = VectorAngle(delta)
    return math.abs(AngleDifference(targetAngle, state.LaunchAngle)) <= cone
end

function MomsKnifeHomingModule:GetRadialApproachFrames(
    knife,
    state,
    target,
    knifeDistance
)
    local origin = self:GetRotationOrigin(knife, state)
    local delta = target.Position - origin
    local targetDistance = delta:Length()
    local contactWindow = (target.Size or 0)
        + (knife.Size or 0)
        + CONTACT_RADIAL_MARGIN
    local radialGap = targetDistance - knifeDistance
    local radialSpeed = self:GetControlledRadialSpeed(knife, state)
    local targetVelocity, _, _, sourceVelocity = self:GetTargetMotion(
        knife,
        state,
        target
    )
    local radialUnit = delta * (1 / math.max(MOTION_EPSILON, targetDistance))
    local relativeTargetVelocity = targetVelocity - sourceVelocity
    local targetRadialVelocity = Dot(relativeTargetVelocity, radialUnit)

    if math.abs(radialGap) <= contactWindow then
        -- Entering the broad radial contact band does not mean only one half
        -- update remains for steering. The blade still has the rest of that
        -- band to traverse before a radial miss. Use that physical exit time
        -- for feasibility while GetPredictedPosition keeps its half-update
        -- lead for near-contact aiming.
        if radialSpeed > MOTION_EPSILON then
            local exitSpeed = radialSpeed - targetRadialVelocity

            if exitSpeed > MOTION_EPSILON then
                return math.max(
                    CONTACT_LEAD_FRAMES,
                    (radialGap + contactWindow) / exitSpeed
                )
            end
        elseif radialSpeed < -MOTION_EPSILON then
            local exitSpeed = targetRadialVelocity - radialSpeed

            if exitSpeed > MOTION_EPSILON then
                return math.max(
                    CONTACT_LEAD_FRAMES,
                    (contactWindow - radialGap) / exitSpeed
                )
            end
        end

        return CONTACT_LEAD_FRAMES
    end

    local closingSpeed = radialGap > 0
            and (radialSpeed - targetRadialVelocity)
        or (targetRadialVelocity - radialSpeed)

    if closingSpeed <= MOTION_EPSILON then
        return nil
    end

    local approachFrames = (math.abs(radialGap) - contactWindow)
        / closingSpeed
    local maximumTravelFrames = MAX_INTERCEPT_FRAMES

    if radialSpeed > MOTION_EPSILON then
        maximumTravelFrames = math.max(
            MIN_INTERCEPT_FRAMES,
            (self:GetMaximumAttackRange(knife, state) - knifeDistance)
                / radialSpeed
        )
    elseif radialSpeed < -MOTION_EPSILON then
        maximumTravelFrames = math.max(
            MIN_INTERCEPT_FRAMES,
            knifeDistance / -radialSpeed
        )
    end

    if approachFrames > math.max(
        MAX_INTERCEPT_FRAMES,
        maximumTravelFrames
    ) + TARGET_TURN_FEASIBILITY_SLACK
    then
        return nil
    end

    return math.max(CONTACT_LEAD_FRAMES, approachFrames)
end

function MomsKnifeHomingModule:ScoreTarget(knife, state, target)
    local origin = self:GetRotationOrigin(knife, state)
    local knifeDistance = self:GetControlledRadialDistance(knife, state)
    local predicted, interceptFrames, radialError, predictedOrigin =
        self:GetPredictedPosition(
        knife,
        state,
        target,
        origin,
        knifeDistance
    )
    local delta = predicted - predictedOrigin
    local targetAngle = self:ClampTrackedAngle(
        state,
        VectorAngle(delta)
    )
    local angleError = AngleDifference(
        targetAngle,
        state.ControlledAngle
    )
    local angleCost = math.abs(angleError)
    local radialSpeed = self:GetControlledRadialSpeed(knife, state)
    local approachFrames = self:GetRadialApproachFrames(
        knife,
        state,
        target,
        knifeDistance
    )
    local steeringFrames = math.max(
        interceptFrames,
        approachFrames or 0
    )
    local turnCapacity = self:GetTurnCapacity(
        state,
        knifeDistance,
        radialSpeed,
        steeringFrames,
        angleError < 0 and -1 or (angleError > 0 and 1 or 0)
    )
    local angularContactAllowance = math.deg(math.atan(
        (target.Size or 0) + (knife.Size or 0),
        math.max(MIN_STEERING_RADIUS, delta:Length())
    ))
    local turnDeficit = math.max(
        0,
        angleCost - angularContactAllowance - turnCapacity
    )

    local physicalScore = turnDeficit * 100
        + radialError * 8
        + interceptFrames * 2
        + angleCost * 0.35
    return physicalScore,
        interceptFrames,
        radialError,
        turnDeficit
end

function MomsKnifeHomingModule:IsPlanEntryFeasible(
    knife,
    state,
    target,
    radialError,
    turnDeficit
)
    local contactWindow = (target.Size or 0)
        + (knife.Size or 0)
        + CONTACT_RADIAL_MARGIN

    local knifeDistance = self:GetControlledRadialDistance(knife, state)
    local radialApproach = self:GetRadialApproachFrames(
        knife,
        state,
        target,
        knifeDistance
    )

    return (radialError <= contactWindow or radialApproach ~= nil)
        and turnDeficit <= TARGET_TURN_FEASIBILITY_SLACK
end

function MomsKnifeHomingModule:IsTargetMotionFeasible(
    knife,
    state,
    target
)
    if not self:IsReachable(knife, state, target, TRACKING_CONE) then
        return false
    end

    local _, _, radialError, turnDeficit = self:ScoreTarget(
        knife,
        state,
        target
    )
    return self:IsPlanEntryFeasible(
        knife,
        state,
        target,
        radialError,
        turnDeficit
    )
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
            local score, interceptFrames, radialError, turnDeficit =
                self:ScoreTarget(
                knife,
                state,
                target
            )
            local feasible = self:IsPlanEntryFeasible(
                knife,
                state,
                target,
                radialError,
                turnDeficit
            )

            if feasible then
                plan[#plan + 1] = {
                    Target = target,
                    Score = score,
                    InterceptFrames = interceptFrames,
                    RadialError = radialError,
                    TurnDeficit = turnDeficit,
                    Feasible = true,
                    Hash = hash,
                }
            end
        end
    end

    table.sort(plan, function(left, right)
        if left.Feasible ~= right.Feasible then
            return left.Feasible
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

function MomsKnifeHomingModule:HasMissedTargetRadially(
    knife,
    state,
    target
)
    local origin = self:GetRotationOrigin(knife, state)
    local targetDistance = (target.Position - origin):Length()
    local knifeDistance = self:GetControlledRadialDistance(knife, state)
    local radialSpeed = self:GetControlledRadialSpeed(knife, state)
    local contactWindow = (target.Size or 0)
        + (knife.Size or 0)
        + CONTACT_RADIAL_MARGIN

    if radialSpeed > MOTION_EPSILON then
        return targetDistance + contactWindow < knifeDistance
    elseif radialSpeed < -MOTION_EPSILON then
        return targetDistance - contactWindow > knifeDistance
    end

    return false
end


function MomsKnifeHomingModule:FindRadialMissReplacement(
    knife,
    state,
    currentTarget
)
    if not self:HasMissedTargetRadially(knife, state, currentTarget) then
        return nil
    end

    local plan = self:BuildTargetPlan(
        knife,
        state,
        false,
        currentTarget
    )
    local replacement = plan[1]

    if replacement ~= nil and replacement.Feasible then
        return replacement.Target
    end

    return nil
end

function MomsKnifeHomingModule:GetGroupFlightMembers(group)
    local members = {}
    local centralAxis = group.NativeCentralAimAngle

    for hash, entry in pairs(group.Entries) do
        local knife = entry.Knife
        local state = knife and knife:GetData()[STATE_KEY]

        if knife ~= nil
            and knife:Exists()
            and knife:IsFlying()
            and entry.LaunchFlightId == group.FlightId
            and state ~= nil
            and state.Flying
            and not state.HoldRetracting
        then
            members[#members + 1] = {
                Hash = hash,
                Knife = knife,
                State = state,
                LaunchDifference = AngleDifference(
                    state.LaunchAngle,
                    centralAxis or state.LaunchAngle
                ),
            }
        end
    end

    table.sort(members, function(left, right)
        if math.abs(left.LaunchDifference - right.LaunchDifference)
            > INTERCEPT_EPSILON
        then
            return left.LaunchDifference < right.LaunchDifference
        end

        return left.Hash < right.Hash
    end)

    return members
end

function MomsKnifeHomingModule:GetAllocationPlan(
    member,
    coveredTargets,
    frame
)
    local candidatePlan = self:BuildTargetPlan(
        member.Knife,
        member.State,
        true
    )
    local currentHash = member.State.Target
            and EntityHash(member.State.Target)
        or nil
    local retainsRecentContact = currentHash ~= nil
        and member.State.LastContactTargetHash == currentHash
        and frame - (member.State.LastContactFrame or -math.huge)
            <= GROUP_CONTACT_RETENTION_FRAMES
    local fullPlan = {}

    for _, entry in ipairs(candidatePlan) do
        if member.State.HitTargets[entry.Hash] ~= true
            or (retainsRecentContact and entry.Hash == currentHash)
        then
            fullPlan[#fullPlan + 1] = entry
        end
    end

    table.sort(fullPlan, function(left, right)
        local leftRetained = left.Hash == currentHash
        local rightRetained = right.Hash == currentHash

        if leftRetained ~= rightRetained then
            return leftRetained
        end

        if left.Feasible ~= right.Feasible then
            return left.Feasible
        end

        if math.abs(left.Score - right.Score) > INTERCEPT_EPSILON then
            return left.Score < right.Score
        end

        return left.Hash < right.Hash
    end)

    local uncoveredPlan = {}

    for _, entry in ipairs(fullPlan) do
        if entry.Feasible and not coveredTargets[entry.Hash] then
            uncoveredPlan[#uncoveredPlan + 1] = entry
        end
    end

    member.FullPlan = fullPlan
    member.PrimaryPlan = uncoveredPlan
    member.CurrentHash = currentHash
end

local function IsAssignmentCostLess(
    leftSwitches,
    leftPhysical,
    leftStable,
    rightSwitches,
    rightPhysical,
    rightStable
)
    if rightSwitches == nil then
        return true
    end

    if leftSwitches ~= rightSwitches then
        return leftSwitches < rightSwitches
    end

    if math.abs(leftPhysical - rightPhysical) > INTERCEPT_EPSILON then
        return leftPhysical < rightPhysical
    end

    return leftStable < rightStable
end

function MomsKnifeHomingModule:TryRetainCompleteCoverage(members)
    local targetSeen = {}
    local targetCount = 0

    for _, member in ipairs(members) do
        for _, option in ipairs(member.PrimaryPlan) do
            if not targetSeen[option.Hash] then
                targetSeen[option.Hash] = true
                targetCount = targetCount + 1
            end
        end
    end

    local requiredCoverage = math.min(#members, targetCount)

    if requiredCoverage == 0 then
        return {}
    end

    local assignments = {}
    local retainedTargets = {}
    local retainedCount = 0

    for _, member in ipairs(members) do
        if member.CurrentHash ~= nil
            and not retainedTargets[member.CurrentHash]
        then
            for _, option in ipairs(member.PrimaryPlan) do
                if option.Hash == member.CurrentHash then
                    assignments[member.Hash] = option
                    retainedTargets[option.Hash] = true
                    retainedCount = retainedCount + 1
                    break
                end
            end
        end
    end

    if retainedCount == requiredCoverage then
        return assignments
    end

    return nil
end

function MomsKnifeHomingModule:SolveDistinctAssignments(members)
    local targetHashes = {}
    local targetSeen = {}

    for _, member in ipairs(members) do
        for _, option in ipairs(member.PrimaryPlan) do
            if not targetSeen[option.Hash] then
                targetSeen[option.Hash] = true
                targetHashes[#targetHashes + 1] = option.Hash
            end
        end
    end

    table.sort(targetHashes)

    local assignments = {}

    if #members == 0 or #targetHashes == 0 then
        return assignments
    end

    local sourceNode = 1
    local memberNodeStart = 2
    local targetNodeStart = memberNodeStart + #members
    local sinkNode = targetNodeStart + #targetHashes
    local nodeCount = sinkNode
    local graph = {}

    for node = 1, nodeCount do
        graph[node] = {}
    end

    local function AddEdge(
        fromNode,
        toNode,
        capacity,
        switchCost,
        physicalCost,
        stableCost,
        option
    )
        local forward = {
            To = toNode,
            Capacity = capacity,
            SwitchCost = switchCost,
            PhysicalCost = physicalCost,
            StableCost = stableCost,
            Option = option,
        }
        local reverse = {
            To = fromNode,
            Capacity = 0,
            SwitchCost = -switchCost,
            PhysicalCost = -physicalCost,
            StableCost = -stableCost,
        }
        forward.Reverse = #graph[toNode] + 1
        reverse.Reverse = #graph[fromNode] + 1
        graph[fromNode][#graph[fromNode] + 1] = forward
        graph[toNode][#graph[toNode] + 1] = reverse
    end

    local targetIndexes = {}

    for index, hash in ipairs(targetHashes) do
        targetIndexes[hash] = index
        AddEdge(
            targetNodeStart + index - 1,
            sinkNode,
            1,
            0,
            0,
            0
        )
    end

    for memberIndex, member in ipairs(members) do
        local memberNode = memberNodeStart + memberIndex - 1
        AddEdge(sourceNode, memberNode, 1, 0, 0, 0)

        for _, option in ipairs(member.PrimaryPlan) do
            local targetIndex = targetIndexes[option.Hash]
            local losesStableLock = member.CurrentHash ~= nil
                and option.Hash ~= member.CurrentHash
            AddEdge(
                memberNode,
                targetNodeStart + targetIndex - 1,
                1,
                losesStableLock and 1 or 0,
                option.Score,
                memberIndex * targetIndex,
                option
            )
        end
    end

    -- Successive shortest augmenting paths produce maximum cardinality first.
    -- Three parallel numeric distances retain the lexicographic cost without
    -- allocating a new table for every graph relaxation on the Deck hot path.
    -- The cost maximizes retained valid locks before minimizing the whole
    -- volley's physical intercept cost. Unlike a plain DFS, this cannot keep
    -- coverage by crossing knives into the most expensive feasible pairing.
    while true do
        local switchDistances = {}
        local physicalDistances = {}
        local stableDistances = {}
        local previousNodes = {}
        local previousEdges = {}
        local inQueue = {}
        local queue = { sourceNode }
        local queueHead = 1
        switchDistances[sourceNode] = 0
        physicalDistances[sourceNode] = 0
        stableDistances[sourceNode] = 0
        inQueue[sourceNode] = true

        while queueHead <= #queue do
            local node = queue[queueHead]
            queueHead = queueHead + 1
            inQueue[node] = false

            for edgeIndex, edge in ipairs(graph[node]) do
                if edge.Capacity > 0 then
                    local candidateSwitches = switchDistances[node]
                        + edge.SwitchCost
                    local candidatePhysical = physicalDistances[node]
                        + edge.PhysicalCost
                    local candidateStable = stableDistances[node]
                        + edge.StableCost
                    if IsAssignmentCostLess(
                        candidateSwitches,
                        candidatePhysical,
                        candidateStable,
                        switchDistances[edge.To],
                        physicalDistances[edge.To],
                        stableDistances[edge.To]
                    ) then
                        switchDistances[edge.To] = candidateSwitches
                        physicalDistances[edge.To] = candidatePhysical
                        stableDistances[edge.To] = candidateStable
                        previousNodes[edge.To] = node
                        previousEdges[edge.To] = edgeIndex

                        if not inQueue[edge.To] then
                            queue[#queue + 1] = edge.To
                            inQueue[edge.To] = true
                        end
                    end
                end
            end
        end

        if previousNodes[sinkNode] == nil then
            break
        end

        local node = sinkNode

        while node ~= sourceNode do
            local previousNode = previousNodes[node]
            local edge = graph[previousNode][previousEdges[node]]
            edge.Capacity = edge.Capacity - 1
            local reverse = graph[node][edge.Reverse]
            reverse.Capacity = reverse.Capacity + 1
            node = previousNode
        end
    end

    for memberIndex, member in ipairs(members) do
        local memberNode = memberNodeStart + memberIndex - 1

        for _, edge in ipairs(graph[memberNode]) do
            if edge.Option ~= nil and edge.Capacity == 0 then
                assignments[member.Hash] = edge.Option
                break
            end
        end
    end

    return assignments
end

function MomsKnifeHomingModule:AssignGroupTargets(group, frame)
    if group == nil
        or not group.FlightReady
        or group.AssignmentFrame == frame
    then
        return
    end

    group.AssignmentFrame = frame
    group.CoveredTargets = group.CoveredTargets or {}
    local members = self:GetGroupFlightMembers(group)

    for _, member in ipairs(members) do
        self:GetAllocationPlan(member, group.CoveredTargets, frame)
    end

    local feasibleTargetCount = 0
    local feasibleTargetSeen = {}
    local soleTargetHash

    for _, member in ipairs(members) do
        for _, option in ipairs(member.FullPlan) do
            if not feasibleTargetSeen[option.Hash] then
                feasibleTargetSeen[option.Hash] = true
                feasibleTargetCount = feasibleTargetCount + 1
                soleTargetHash = option.Hash
            end
        end
    end

    if feasibleTargetCount ~= 1 then
        soleTargetHash = nil
    end

    -- Keep the graph order deterministic and let the global solver choose the
    -- lowest-cost maximum-coverage pairing across all knives at once.
    table.sort(members, function(left, right)
        if #left.PrimaryPlan ~= #right.PrimaryPlan then
            return #left.PrimaryPlan < #right.PrimaryPlan
        end

        if math.abs(left.LaunchDifference - right.LaunchDifference)
            > INTERCEPT_EPSILON
        then
            return left.LaunchDifference < right.LaunchDifference
        end

        return left.Hash < right.Hash
    end)

    -- A complete set of distinct, still-valid locks is already the
    -- lexicographic optimum: maximum coverage with zero switches. Reuse it
    -- without building the flow graph on the ordinary stable frame.
    local assignments = self:TryRetainCompleteCoverage(members)
        or self:SolveDistinctAssignments(members)

    local occupancy = {}

    for _, option in pairs(assignments) do
        occupancy[option.Hash] = (occupancy[option.Hash] or 0) + 1
    end

    -- More knives than enemies should not leave a knife idle. After maximum
    -- unique coverage is established, distribute extras to the least occupied
    -- feasible lanes. At equal occupancy prefer an unhit target; this lets a
    -- just-contacting surplus knife keep its still-active lane instead of
    -- converging on a target that another knife already owns.
    for _, member in ipairs(members) do
        if assignments[member.Hash] == nil then
            local bestOption

            for _, option in ipairs(member.FullPlan) do
                local optionCovered = group.CoveredTargets[option.Hash] == true
                local bestCovered = bestOption ~= nil
                    and group.CoveredTargets[bestOption.Hash] == true
                local optionOccupancy = occupancy[option.Hash] or 0
                local bestOccupancy = bestOption
                        and (occupancy[bestOption.Hash] or 0)
                    or math.huge
                local optionRetained = member.State.Target ~= nil
                    and EntityHash(member.State.Target) == option.Hash
                local bestRetained = bestOption ~= nil
                    and member.State.Target ~= nil
                    and EntityHash(member.State.Target) == bestOption.Hash

                if bestOption == nil
                    or optionOccupancy < bestOccupancy
                    or (optionOccupancy == bestOccupancy
                        and optionCovered ~= bestCovered
                        and not optionCovered)
                    or (optionOccupancy == bestOccupancy
                        and optionCovered == bestCovered
                        and optionRetained ~= bestRetained
                        and optionRetained)
                    or (optionOccupancy == bestOccupancy
                        and optionCovered == bestCovered
                        and optionRetained == bestRetained
                        and option.Feasible ~= bestOption.Feasible
                        and option.Feasible)
                    or (optionOccupancy == bestOccupancy
                        and optionCovered == bestCovered
                        and optionRetained == bestRetained
                        and option.Feasible == bestOption.Feasible
                        and option.Score < bestOption.Score)
                    or (optionOccupancy == bestOccupancy
                        and optionCovered == bestCovered
                        and optionRetained == bestRetained
                        and option.Feasible == bestOption.Feasible
                        and math.abs(option.Score - bestOption.Score)
                            <= INTERCEPT_EPSILON
                        and option.Hash < bestOption.Hash)
                then
                    bestOption = option
                end
            end

            if bestOption ~= nil then
                assignments[member.Hash] = bestOption
                occupancy[bestOption.Hash] =
                    (occupancy[bestOption.Hash] or 0) + 1
            end
        end
    end

    local groupApproachingSoleTarget = false

    if soleTargetHash ~= nil then
        for _, member in ipairs(members) do
            local assignment = assignments[member.Hash]

            if assignment ~= nil
                and assignment.Hash == soleTargetHash
                and self:ShouldBeginTargetApproachHold(
                    member.Knife,
                    member.State,
                    assignment.Target
                )
            then
                groupApproachingSoleTarget = true
                break
            end
        end
    end

    for _, member in ipairs(members) do
        local state = member.State
        local assignment = assignments[member.Hash]

        if assignment ~= nil then
            local assignmentCovered =
                group.CoveredTargets[assignment.Hash] == true
            local beginsGroupApproach = groupApproachingSoleTarget
                and soleTargetHash == assignment.Hash

            if (assignmentCovered or beginsGroupApproach)
                and self:IsWithinHoldRange(
                    member.Knife,
                    state,
                    assignment.Target
                )
            then
                -- Once any member reaches the final remaining lane, every
                -- surplus knife that can still reach it decelerates toward the
                -- same live target. Preserve an existing hold controller so
                -- frame-end allocation never creates a stop/forward/stop loop.
                self:BeginSharedTargetHold(
                    member.Knife,
                    state,
                    assignment.Target
                )
            else
                state.Target = assignment.Target
                state.HoldTarget = nil
                state.HoldTargetDistance = nil
                state.HoldAngle = nil
                state.HoldDistance = nil
                state.HoldRadialVelocity = nil
                state.HoldRetracting = false
                state.HoldRetractionNativeStart = nil
                state.HoldRetractionVisualStart = nil
            end
        else
            state.Target = nil
        end

        local continuation = {}

        for _, option in ipairs(member.FullPlan) do
            if assignment == nil or option.Hash ~= assignment.Hash then
                continuation[#continuation + 1] = option
            end
        end

        table.sort(continuation, function(left, right)
            local leftCovered = group.CoveredTargets[left.Hash] == true
            local rightCovered = group.CoveredTargets[right.Hash] == true

            if leftCovered ~= rightCovered then
                return not leftCovered
            end

            local leftOccupancy = occupancy[left.Hash] or 0
            local rightOccupancy = occupancy[right.Hash] or 0

            if leftOccupancy ~= rightOccupancy then
                return leftOccupancy < rightOccupancy
            end

            if left.Feasible ~= right.Feasible then
                return left.Feasible
            end

            if math.abs(left.Score - right.Score) > INTERCEPT_EPSILON then
                return left.Score < right.Score
            end

            return left.Hash < right.Hash
        end)

        state.TargetPlan = continuation
        state.NextTarget = nil

        -- Pre-turn only toward a genuinely unassigned, still-unhit enemy. A
        -- target already owned by another knife may be a valid fallback after
        -- a later collision, but biasing toward it now makes two otherwise
        -- well-distributed knives converge and weakens their current contact.
        for _, option in ipairs(continuation) do
            if not group.CoveredTargets[option.Hash]
                and (occupancy[option.Hash] or 0) == 0
            then
                state.NextTarget = option.Target
                break
            end
        end
    end
end

function MomsKnifeHomingModule:GetSequentialAimAngle(
    knife,
    state,
    target,
    currentAimAngle,
    interceptFrames,
    origin,
    controlledDistance
)
    local nextTarget = state.NextTarget

    if nextTarget == nil
        or nextTarget == target
        or state.HitTargets[EntityHash(nextTarget)] == true
        or interceptFrames > SEQUENCE_LOOKAHEAD_FRAMES
        or not self:IsReachable(
            knife,
            state,
            nextTarget,
            TRACKING_CONE
        )
    then
        return currentAimAngle
    end

    local targetDelta = target.Position - origin
    local contactWindow = (target.Size or 0)
        + (knife.Size or 0)
        + CONTACT_RADIAL_MARGIN

    if math.abs(targetDelta:Length() - controlledDistance) > contactWindow then
        return currentAimAngle
    end

    local _, _, nextRadialError, nextTurnDeficit = self:ScoreTarget(
        knife,
        state,
        nextTarget
    )

    if not self:IsPlanEntryFeasible(
        knife,
        state,
        nextTarget,
        nextRadialError,
        nextTurnDeficit
    ) then
        return currentAimAngle
    end

    local predicted, _, _, predictedOrigin = self:GetPredictedPosition(
        knife,
        state,
        nextTarget,
        origin,
        controlledDistance
    )
    local nextAimAngle = VectorAngle(predicted - predictedOrigin)
    local contactRadius = (target.Size or 0) + (knife.Size or 0)
    local contactAngle = math.deg(math.atan(
        contactRadius,
        math.max(MOTION_EPSILON, targetDelta:Length())
    ))
    local maximumBias = math.min(
        MAX_SEQUENCE_LOOKAHEAD_ANGLE,
        contactAngle * SEQUENCE_LOOKAHEAD_FRACTION
    )

    return currentAimAngle + math.max(
        -maximumBias,
        math.min(
            maximumBias,
            AngleDifference(nextAimAngle, currentAimAngle)
        )
    )
end

function MomsKnifeHomingModule:GetFarthestRecordedHitDistance(
    knife,
    state
)
    local maximumReach = self:GetMaximumAttackRange(knife, state)
    local farthestDistance

    for _, distance in pairs(state.HitTargetDistances or {}) do
        if type(distance) == "number"
            and distance >= 0
            and distance <= maximumReach
            and (farthestDistance == nil or distance > farthestDistance)
        then
            farthestDistance = distance
        end
    end

    return farthestDistance
end

function MomsKnifeHomingModule:PrepareFarthestHitHold(
    knife,
    state,
    preferredTarget
)
    state.HoldTarget = self:FindFarthestHitTarget(
        knife,
        state,
        preferredTarget
    )

    if state.HoldTarget ~= nil then
        local origin = self:GetRotationOrigin(knife, state)
        state.HoldTargetDistance = math.min(
            self:GetMaximumAttackRange(knife, state),
            (state.HoldTarget.Position - origin):Length()
        )
        state.Target = state.HoldTarget
    else
        state.HoldTargetDistance = state.HoldTargetDistance
            or self:GetFarthestRecordedHitDistance(knife, state)
        state.Target = nil
    end

    state.HoldAngle = state.HoldAngle or state.ControlledAngle
    state.NextTarget = nil
    state.TargetPlan = {}
end

function MomsKnifeHomingModule:IsWithinHoldRange(knife, state, target)
    return self:IsInsideTrackingSector(
        knife,
        state,
        target,
        self:GetMaximumAttackRange(knife, state)
    )
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
    if (state.HoldTarget == nil and state.HoldTargetDistance == nil)
        or state.HoldDistance ~= nil
    then
        return
    end

    local baseline = self:GetMaximumAttackRange(knife, state)
    local controlledDistance = self:GetControlledRadialDistance(knife, state)
    local controlledVelocity = self:GetControlledRadialSpeed(knife, state)
    state.HoldDistance = math.max(
        0,
        math.min(baseline, controlledDistance)
    )
    state.HoldRadialVelocity = math.max(
        -HOLD_MAX_RADIAL_SPEED,
        math.min(
            HOLD_MAX_RADIAL_SPEED,
            controlledVelocity
        )
    )
    state.HoldRetracting = false
    state.HoldRetractionNativeStart = nil
    state.HoldRetractionVisualStart = nil
    state.HoldAngle = state.HoldAngle or state.ControlledAngle
end

function MomsKnifeHomingModule:BeginSharedTargetHold(knife, state, target)
    local sameTarget = state.HoldTarget ~= nil
        and state.HoldTarget:Exists()
        and EntityHash(state.HoldTarget) == EntityHash(target)

    if not sameTarget then
        state.HoldDistance = nil
        state.HoldRadialVelocity = nil
        state.HoldRetracting = false
        state.HoldRetractionNativeStart = nil
        state.HoldRetractionVisualStart = nil
        state.HoldAngle = state.ControlledAngle
    end

    local origin = self:GetRotationOrigin(knife, state)
    state.HoldTarget = target
    state.HoldTargetDistance = math.min(
        self:GetMaximumAttackRange(knife, state),
        (target.Position - origin):Length()
    )
    state.Target = target
    state.NextTarget = nil
    state.TargetPlan = {}
    self:BeginHoldRadialMotion(knife, state)
end

function MomsKnifeHomingModule:BeginFinalGroupTargetHold(group, target)
    local targetHash = EntityHash(target)
    local members = self:GetGroupFlightMembers(group)

    -- AssignGroupTargets has already run for this collision frame. If any
    -- member owns another still-uncovered lane, this was not the final group
    -- target and the remaining knives must continue their sequence.
    for _, member in ipairs(members) do
        local assignedTarget = member.State.Target

        if assignedTarget ~= nil then
            local assignedHash = EntityHash(assignedTarget)

            if assignedHash ~= targetHash
                and not group.CoveredTargets[assignedHash]
            then
                return false
            end
        end
    end

    local started = false

    for _, member in ipairs(members) do
        if self:IsWithinHoldRange(
            member.Knife,
            member.State,
            target
        ) then
            self:BeginSharedTargetHold(
                member.Knife,
                member.State,
                target
            )
            started = true
        end
    end

    return started
end

function MomsKnifeHomingModule:ShouldBeginTargetApproachHold(
    knife,
    state,
    target
)
    if state.HoldRetracting
        or not self:IsWithinHoldRange(knife, state, target)
    then
        return false
    end

    local origin = self:GetRotationOrigin(knife, state)
    local targetDelta = target.Position - origin
    local targetDistance = targetDelta:Length()

    if targetDistance <= MOTION_EPSILON then
        return true
    end

    local controlledDistance = self:GetControlledRadialDistance(knife, state)
    local radialGap = targetDistance - controlledDistance
    local approachMargin = math.min(
        CONTACT_RADIAL_MARGIN,
        math.max(4, (target.Size or 0) * 0.25)
    )

    if radialGap <= approachMargin then
        return true
    end

    local radialUnit = targetDelta * (1 / targetDistance)
    local targetVelocity, _, _, sourceVelocity = self:GetTargetMotion(
        knife,
        state,
        target
    )
    local targetRadialVelocity = Dot(
        targetVelocity - sourceVelocity,
        radialUnit
    )
    local closingSpeed = math.max(
        0,
        self:GetControlledRadialSpeed(knife, state)
            - targetRadialVelocity
    )
    local brakingDistance = closingSpeed * closingSpeed
            / (2 * HOLD_RADIAL_ACCELERATION)
        + closingSpeed * 0.5

    return radialGap <= approachMargin + brakingDistance
end

function MomsKnifeHomingModule:UpdateHoldRadialMotion(knife, state)
    if state.HoldTarget == nil
        and state.HoldTargetDistance == nil
        and not state.HoldRetracting
    then
        state.HoldDistance = nil
        state.HoldRadialVelocity = nil
        state.HoldRetractionNativeStart = nil
        state.HoldRetractionVisualStart = nil
        state.HoldAngle = nil
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
    local liveTargetRadialVelocity = 0
    local hasLiveHoldTarget = false

    if state.HoldTarget ~= nil
        and self:IsWithinHoldRange(knife, state, state.HoldTarget)
    then
        local targetDelta = state.HoldTarget.Position - origin
        local targetDistance = targetDelta:Length()
        state.HoldTargetDistance = math.min(
            baseline,
            targetDistance
        )

        if targetDistance > MOTION_EPSILON then
            local targetVelocity, _, _, sourceVelocity =
                self:GetTargetMotion(knife, state, state.HoldTarget)
            local relativeVelocityX = targetVelocity.X - sourceVelocity.X
            local relativeVelocityY = targetVelocity.Y - sourceVelocity.Y
            liveTargetRadialVelocity = (
                relativeVelocityX * targetDelta.X
                + relativeVelocityY * targetDelta.Y
            ) / targetDistance
            liveTargetRadialVelocity = math.max(
                -HOLD_MAX_RADIAL_SPEED,
                math.min(
                    HOLD_MAX_RADIAL_SPEED,
                    liveTargetRadialVelocity
                )
            )
        end

        hasLiveHoldTarget = true
    end

    local desiredDistance = math.min(
        baseline,
        state.HoldTargetDistance or state.HoldDistance
    )

    local radialError = desiredDistance - state.HoldDistance
    local correctionSpeed = math.min(
        math.abs(radialError) * HOLD_RADIAL_RESPONSE,
        GetBrakingLimitedSpeed(
            math.abs(radialError),
            HOLD_MAX_RADIAL_SPEED,
            HOLD_RADIAL_ACCELERATION
        )
    )

    if radialError < 0 then
        correctionSpeed = -correctionSpeed
    end

    local desiredVelocity = math.max(
        -HOLD_MAX_RADIAL_SPEED,
        math.min(
            HOLD_MAX_RADIAL_SPEED,
            liveTargetRadialVelocity * HOLD_RADIAL_FEED_FORWARD
                + correctionSpeed
        )
    )

    if not hasLiveHoldTarget
        and math.abs(radialError) <= HOLD_DISTANCE_EPSILON
    then
        desiredVelocity = 0
    end

    state.HoldRadialVelocity = MoveTowards(
        state.HoldRadialVelocity or 0,
        desiredVelocity,
        HOLD_RADIAL_ACCELERATION
    )
    local nextDistance

    if not hasLiveHoldTarget
        and math.abs(radialError) <= HOLD_DISTANCE_EPSILON
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

    -- Keep the native entity, damage and flight timer. The live radial distance
    -- follows native flight through an acceleration-bounded controller, while
    -- the moving origin follows only part of the owner's outbound displacement
    -- and converges back throughout native retraction. A final-target hold may
    -- substitute its own controlled distance without changing that origin.
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


function MomsKnifeHomingModule:BeginFlight(knife, state, knifeGroup)
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
    local rotationOffset = knife.RotationOffset or 0
    state.BaseAimAngle = state.PreparedBaseAimAngle
        or (knifeGroup and knifeGroup.PreflightAimAngle)
        or GetWorldRotation(knife) - rotationOffset
    state.NativeLaunchAngle = state.PreparedLaunchAngle
        or GetWorldRotation(knife)

    -- Native shot multipliers can change a held knife's RotationOffset only
    -- on release. Carry that exact offset delta onto the member's own saved
    -- held angle instead of collapsing it onto the group center. Extras that
    -- exist only after release retain their first observed native world angle;
    -- the frame-end layout replaces either provisional value once complete.
    if state.PreparedLaunchAngle ~= nil
        and state.PreparedRotationOffset ~= nil
    then
        state.NativeLaunchAngle = state.PreparedLaunchAngle
            + rotationOffset - state.PreparedRotationOffset
    end

    state.LaunchAngle = state.NativeLaunchAngle
    state.ControlledAngle = state.LaunchAngle
    state.AngularVelocity = 0
    state.TangentialVelocity = 0
    state.NativeRadialDistance = nil
    state.NativeRadialOffset = nil
    state.PreviousControlledDistance = nil
    state.Target = nil
    state.NextTarget = nil
    state.TargetPlan = {}
    state.HitTargets = {}
    state.HitTargetDistances = {}
    state.HoldTarget = nil
    state.HoldTargetDistance = nil
    state.HoldAngle = nil
    state.HoldDistance = nil
    state.HoldRadialVelocity = nil
    state.HoldRetracting = false
    state.HoldRetractionNativeStart = nil
    state.HoldRetractionVisualStart = nil
    state.BaselineSourceRange = sourceRange
    state.FlightMaxDistance = state.BaselineMaxDistance
    state.TrackingAttackRange = self:GetBaseMaximumAttackRange(knife, state)
    state.RangeCalibrated = false
    state.RangeEvaluationLimit = nil
    state.PreviousKnifeDistance = nil
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
        state.TangentialVelocity = 0
        state.NativeRadialDistance = nil
        state.NativeRadialOffset = nil
        state.PreviousControlledDistance = nil
        state.HoldTarget = nil
        state.HoldTargetDistance = nil
        state.HoldAngle = nil
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
        state.TrackingAttackRange = nil
        state.RangeCalibrated = nil
        state.RangeEvaluationLimit = nil
        state.LastSteeringFrame = nil
        state.PreparedLaunchAngle = self:GetHeldAimAngle(knife, knifeGroup)
        state.PreparedBaseAimAngle = self:GetHeldBaseAimAngle(
            knife,
            knifeGroup
        )
        state.PreparedRotationOffset = knife.RotationOffset or 0
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
        self:BeginFlight(knife, state, knifeGroup)
    end

    -- MC_POST_KNIFE_UPDATE runs twice inside one Game frame on the tested
    -- build. Vanilla advances the native position before both callbacks, so
    -- capture the fresh world radius on every sub-update even though target
    -- planning and controller state advance only once per Game frame.
    self:CaptureNativeRadialDistance(knife, state)

    if state.MultiKnifeGroup and knifeGroup.NativeCentralAimAngle ~= nil then
        state.BaseAimAngle = knifeGroup.NativeCentralAimAngle
    end

    -- Keep every provisional member on its own captured native launch line
    -- until the frame-end collector has seen the complete volley. Do not plan
    -- targets yet, but reapply that provisional transform after each native
    -- sub-update so the renderer never alternates back to vanilla homing.
    if not knifeGroup.FlightReady then
        if state.DistanceFrame ~= frame then
            self:GetRadialSpeed(knife, state, frame)
        end
        self:StabilizeMaxDistance(knife, state)

        self:ApplyControlledTransform(
            knife,
            state,
            self:GetControlledRadialDistance(knife, state)
        )
        return
    end

    if state.LastSteeringFrame == frame then
        self:StabilizeMaxDistance(knife, state)
        self:ApplyControlledTransform(
            knife,
            state,
            self:GetControlledRadialDistance(knife, state)
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

    -- The release layout fixes any target-derived MaxDistance extension. Later
    -- target motion cannot enlarge this throw's tracking range or native timer,
    -- so outbound and return timing remain stable without reshooting or
    -- replacing the native knife.
    self:StabilizeMaxDistance(knife, state)

    local holdReturning = state.HoldDistance ~= nil
        and (state.RadialSpeed or 0) < -MOTION_EPSILON

    if holdReturning then
        state.Target = nil
        state.NextTarget = nil
        state.TargetPlan = {}
    else
        if state.Target ~= nil and (
            not self:IsReachable(
                knife,
                state,
                state.Target,
                TRACKING_CONE
            )
            or (state.HoldTarget == nil
                and not self:IsTargetMotionFeasible(
                    knife,
                    state,
                    state.Target
                ))
        ) then
            if state.Target == state.HoldTarget then
                state.HoldAngle = state.HoldAngle
                    or state.ControlledAngle
            end

            state.Target = nil
            state.NextTarget = nil
            state.TargetPlan = {}
            state.HoldTarget = nil

            if state.MultiKnifeGroup and knifeGroup ~= nil then
                knifeGroup.AssignmentFrame = -1
            end
        end

        if state.MultiKnifeGroup then
            -- The complete group is reassigned in MC_POST_UPDATE after every
            -- member has refreshed its radial speed and feasibility state.
            -- Keep this callback limited to validation and steering with the
            -- stable assignment prepared at the end of the preceding frame.
        else
            if state.Target ~= nil and state.HoldTarget == nil then
                local replacement = self:FindRadialMissReplacement(
                    knife,
                    state,
                    state.Target
                )

                if replacement ~= nil then
                    state.Target = replacement
                    state.NextTarget = nil
                    state.TargetPlan = {}
                    state.HoldTargetDistance = nil
                    state.HoldAngle = nil
                end
            end

            if state.HoldTarget ~= nil then
                local unhitTarget = self:FindTarget(knife, state, false)

                if unhitTarget ~= nil then
                    state.HoldTarget = nil
                    state.HoldTargetDistance = nil
                    state.HoldAngle = nil
                    state.HoldDistance = nil
                    state.HoldRadialVelocity = nil
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
                    self:PrepareFarthestHitHold(knife, state)
                end
            end

            if state.Target == nil then
                local plan
                state.Target, plan = self:FindTarget(knife, state, false)
                state.TargetPlan = plan
                state.NextTarget = plan[2] and plan[2].Target or nil

                if state.Target ~= nil then
                    state.HoldTargetDistance = nil
                    state.HoldAngle = nil
                    state.HoldDistance = nil
                    state.HoldRadialVelocity = nil
                else
                    -- After crossing every reachable target, stay aligned with
                    -- the farthest already-hit enemy still inside calibrated
                    -- range. Native timing continues to control retraction.
                    self:PrepareFarthestHitHold(knife, state)
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
    end

    local holdDistance = self:UpdateHoldRadialMotion(knife, state)
    local controlledDistance = holdDistance
        or self:GetControlledRadialDistance(knife, state)
    local steeringActive = state.Target ~= nil or holdDistance ~= nil

    local desiredAngle = state.HoldRetracting
            and state.ControlledAngle
        or (holdDistance ~= nil and state.Target == nil)
            and (state.HoldAngle or state.ControlledAngle)
        or state.LaunchAngle
    if state.Target ~= nil then
        local origin = self:GetRotationOrigin(knife, state)
        local predicted, interceptFrames, _, predictedOrigin =
            self:GetPredictedPosition(
            knife,
            state,
            state.Target,
            origin,
            controlledDistance
        )
        desiredAngle = VectorAngle(predicted - predictedOrigin)
        desiredAngle = self:GetSequentialAimAngle(
            knife,
            state,
            state.Target,
            desiredAngle,
            interceptFrames,
            origin,
            controlledDistance
        )
        desiredAngle = self:ClampTrackedAngle(state, desiredAngle)
    end

    desiredAngle = ClampAngleAround(
        desiredAngle,
        state.LaunchAngle,
        TRACKING_CONE
    )
    if steeringActive then
        desiredAngle = self:ClampTrackedAngle(state, desiredAngle)
    end

    local angleError = AngleDifference(
        desiredAngle,
        state.ControlledAngle
    )
    local maximumAngularSpeed, maximumAngularAcceleration =
        self:GetSteeringMotionLimits(controlledDistance)
    local desiredAngularSpeed = math.min(
        maximumAngularSpeed,
        math.abs(angleError) * STEERING_RESPONSE,
        GetBrakingLimitedSpeed(
            math.abs(angleError),
            maximumAngularSpeed,
            maximumAngularAcceleration
        )
    )
    local desiredAngularVelocity = angleError < 0
            and -desiredAngularSpeed
        or desiredAngularSpeed
    state.AngularVelocity, state.TangentialVelocity =
        self:GetBoundedSteeringVelocity(
            state,
            desiredAngularVelocity,
            controlledDistance
        )
    local previousControlledAngle = state.ControlledAngle
    local nextControlledAngle = ClampAngleAround(
        state.ControlledAngle + state.AngularVelocity,
        state.LaunchAngle,
        TRACKING_CONE
    )
    state.ControlledAngle = nextControlledAngle
    state.AngularVelocity = AngleDifference(
        state.ControlledAngle,
        previousControlledAngle
    )
    state.TangentialVelocity = math.rad(state.AngularVelocity)
        * controlledDistance
    state.PreviousControlledDistance = controlledDistance

    if state.HoldTarget ~= nil then
        state.HoldAngle = state.ControlledAngle
    end

    self:ApplyControlledTransform(
        knife,
        state,
        controlledDistance
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

    local colliderHash = EntityHash(collider)

    state.HitTargets[colliderHash] = true
    state.LastContactTargetHash = colliderHash
    state.LastContactFrame = Game():GetFrameCount()
    state.HitTargetDistances = state.HitTargetDistances or {}

    if self:IsWithinHoldRange(knife, state, collider) then
        local origin = self:GetRotationOrigin(knife, state)
        state.HitTargetDistances[colliderHash] = math.min(
            self:GetMaximumAttackRange(knife, state),
            (collider.Position - origin):Length()
        )
    end

    local group = state.KnifeGroup

    if state.MultiKnifeGroup and group ~= nil then
        group.CoveredTargets = group.CoveredTargets or {}
        group.CoveredTargets[colliderHash] = true
        group.AssignmentFrame = -1
    end

    local function IsUsableUnhitTarget(target)
        return target ~= nil
            and state.HitTargets[EntityHash(target)] ~= true
            and self:IsTargetMotionFeasible(knife, state, target)
    end

    local nextTarget
    local collidedWithCurrent = state.Target ~= nil
        and EntityHash(state.Target) == colliderHash

    if state.MultiKnifeGroup and group ~= nil and group.FlightReady then
        self:AssignGroupTargets(group, Game():GetFrameCount())
        self:BeginFinalGroupTargetHold(group, collider)

        if IsUsableUnhitTarget(state.Target) then
            nextTarget = state.Target
        end
    elseif not collidedWithCurrent and IsUsableUnhitTarget(state.Target) then
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
        self:PrepareFarthestHitHold(knife, state, collider)
        self:BeginHoldRadialMotion(knife, state)
        return
    end

    state.HoldTarget = nil
    state.HoldTargetDistance = nil
    state.HoldAngle = nil
    state.HoldDistance = nil
    state.HoldRadialVelocity = nil
    state.HoldRetracting = false
    state.HoldRetractionNativeStart = nil
    state.HoldRetractionVisualStart = nil
    state.Target = nextTarget

    if state.MultiKnifeGroup and group ~= nil and group.FlightReady then
        return
    end

    local _, plan = self:FindTarget(knife, state, false, nextTarget)
    state.TargetPlan = plan
    state.NextTarget = plan[1] and plan[1].Target or nil
end

return MomsKnifeHomingModule
