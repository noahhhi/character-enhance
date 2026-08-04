local MomsKnifeHomingModule = {}
MomsKnifeHomingModule.__index = MomsKnifeHomingModule

local SETTING_KEY = "momsKnifeHomingFix"
local MOMS_KNIFE_VARIANT = 0
local STATE_KEY = "CharacterEnhanceMomsKnifeHoming"
local HOMING_FLAG = TearFlags.TEAR_HOMING

local ACQUIRE_CONE = 42
local RETAIN_CONE = 85
local MAX_STEERING_DEVIATION = 80
local MAX_TURN_PER_FRAME = 10
local MIN_INTERCEPT_FRAMES = 1
local MAX_INTERCEPT_FRAMES = 18
local MOTION_EPSILON = 0.05
local INTERCEPT_EPSILON = 0.001
local MAX_TRACKED_SPEED = 20
local MIN_TURN_TRACKING_SPEED = 0.5
local MAX_TRACKED_TURN_RATE = 12
local MAX_PREDICTED_HEADING_CHANGE = 75
local TURN_RATE_CURRENT_WEIGHT = 0.65
local CURVED_INTERCEPT_STEP = 0.5
local CONTACT_LEAD_FRAMES = 0.5
local CONTACT_RADIAL_MARGIN = 24
local REACH_MARGIN = 48
local HOLD_REACH_MARGIN = 2
local HOLD_SWITCH_MARGIN = 6
local MAX_DISTANCE_VARIATION = 0.05
local MIN_DISTANCE_WINDOW = 2
local CHARGE_MATCH_EPSILON = 0.02
local RANGE_MATCH_EPSILON = 0.5

local function NormalizeAngle(angle)
    return (angle + 180) % 360 - 180
end

local function AngleDifference(target, current)
    return NormalizeAngle(target - current)
end

local function MoveAngleTowards(current, target, maximumStep)
    local difference = AngleDifference(target, current)

    if difference > maximumStep then
        difference = maximumStep
    elseif difference < -maximumStep then
        difference = -maximumStep
    end

    return current + difference
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
        and entity:IsActiveEnemy(false)
        and entity:IsVulnerableEnemy()
end

function MomsKnifeHomingModule.New(context)
    local self = setmetatable({
        Context = context,
        CandidateFrame = -1,
        Candidates = {},
        TargetMotion = {},
    }, MomsKnifeHomingModule)

    self.KnifeUpdateCallback = function(_, knife)
        self:OnKnifeUpdate(knife)
    end
    self.KnifeCollisionCallback = function(_, knife, collider)
        self:OnKnifeCollision(knife, collider)
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

            if previous ~= nil and previous.Frame == frame - 1 then
                local observedVelocity = entity.Position - previous.Position

                if observedVelocity:Length() > MOTION_EPSILON then
                    if nativeVelocity:Length() > MOTION_EPSILON then
                        -- Position displacement is the authoritative motion
                        -- that was actually rendered. Blend in a smaller part
                        -- of native Velocity as a one-frame look-ahead for AI
                        -- acceleration and direction changes.
                        measuredVelocity = observedVelocity * 0.8
                            + nativeVelocity * 0.2
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
            end

            currentMotion[hash] = {
                Frame = frame,
                Position = CopyVector(entity.Position),
                Velocity = ClampVectorLength(
                    measuredVelocity,
                    MAX_TRACKED_SPEED
                ),
                TurnRate = turnRate,
            }
        end
    end

    self.CandidateFrame = frame
    self.Candidates = candidates
    self.TargetMotion = currentMotion
    return candidates
end

function MomsKnifeHomingModule:GetTargetMotion(knife, target)
    local motion = self.TargetMotion[EntityHash(target)]
    local targetVelocity = motion and motion.Velocity
        or target.Velocity
        or Vector(0, 0)
    local turnRate = motion and motion.TurnRate or 0
    local sourceVelocity = Vector(0, 0)

    if knife.SpawnerEntity and knife.SpawnerEntity.Velocity then
        sourceVelocity = knife.SpawnerEntity.Velocity
    end

    return ClampVectorLength(targetVelocity, MAX_TRACKED_SPEED),
        turnRate,
        sourceVelocity
end

function MomsKnifeHomingModule:PredictTargetDisplacement(
    targetVelocity,
    turnRate,
    frames
)
    if frames <= 0 then
        return Vector(0, 0)
    end

    if math.abs(turnRate) <= INTERCEPT_EPSILON then
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

        velocity = RotateVector(velocity, stepTurn)
        displacement = displacement + velocity * step
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
    sourceVelocity,
    knifeDistance,
    radialSpeed,
    maximumFrames
)
    if math.abs(turnRate) <= INTERCEPT_EPSILON then
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

        velocity = RotateVector(velocity, stepTurn)
        targetDisplacement = targetDisplacement + velocity * step
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


function MomsKnifeHomingModule:GetMaximumInterceptFrames(
    knife,
    knifeDistance,
    radialSpeed
)
    local maximumFrames = MAX_INTERCEPT_FRAMES

    if radialSpeed > MOTION_EPSILON and knife.MaxDistance ~= nil then
        maximumFrames = math.min(
            maximumFrames,
            math.max(
                MIN_INTERCEPT_FRAMES,
                (knife.MaxDistance - knifeDistance) / radialSpeed
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

function MomsKnifeHomingModule:GetRotationOrigin(knife)
    local source = knife.SpawnerEntity

    if source ~= nil and source.Position ~= nil then
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

function MomsKnifeHomingModule:GetHeldAimAngle(knife)
    local player = self:GetSourcePlayer(knife)
    local rotationOffset = knife.RotationOffset or 0

    if player ~= nil then
        local shootingInput = player:GetShootingInput()

        if shootingInput:Length() > 0.01 then
            return VectorAngle(shootingInput) + rotationOffset
        end
    end

    return GetWorldRotation(knife)
end

function MomsKnifeHomingModule:MatchesDistanceCalibration(
    state,
    charge,
    sourceRange
)
    if state.CalibratedMaxDistance == nil
        or state.CalibratedCharge == nil
        or math.abs(state.CalibratedCharge - charge) > CHARGE_MATCH_EPSILON
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

    local window = math.max(
        baseline * MAX_DISTANCE_VARIATION,
        MIN_DISTANCE_WINDOW
    )
    local minimum = baseline - window
    local maximum = baseline + window

    if knife.MaxDistance < minimum then
        knife.MaxDistance = minimum
    elseif knife.MaxDistance > maximum then
        knife.MaxDistance = maximum
    end
end

function MomsKnifeHomingModule:GetPredictedPosition(
    knife,
    state,
    target,
    origin,
    knifeDistance
)
    local relativePosition = target.Position - origin
    local targetVelocity, turnRate, sourceVelocity = self:GetTargetMotion(
        knife,
        target
    )
    local radialSpeed = state.RadialSpeed or knife:GetKnifeVelocity()
    local maximumFrames = self:GetMaximumInterceptFrames(
        knife,
        knifeDistance,
        radialSpeed
    )
    local interceptFrames = self:SolveCurvedInterceptTime(
        relativePosition,
        targetVelocity,
        turnRate,
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

    return target.Position + self:PredictTargetDisplacement(
        targetVelocity,
        turnRate,
        interceptFrames
    )
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

    local origin = self:GetRotationOrigin(knife)
    local knifeDistance = knife:GetKnifeDistance()
    local predicted = self:GetPredictedPosition(
        knife,
        state,
        target,
        origin,
        knifeDistance
    )
    local delta = predicted - origin
    local radialDistance = delta:Length()
    local targetSize = target.Size or 0
    local maximumReach = math.max(
        knifeDistance,
        knife.MaxDistance or 0
    ) + targetSize + REACH_MARGIN

    if radialDistance <= 0.01 or radialDistance > maximumReach then
        return false
    end

    local targetAngle = VectorAngle(delta)
    return math.abs(AngleDifference(targetAngle, state.LaunchAngle)) <= cone
end

function MomsKnifeHomingModule:ScoreTarget(knife, state, target)
    local origin = self:GetRotationOrigin(knife)
    local knifeDistance = knife:GetKnifeDistance()
    local predicted = self:GetPredictedPosition(
        knife,
        state,
        target,
        origin,
        knifeDistance
    )
    local delta = predicted - origin
    local radialDistance = delta:Length()
    local targetAngle = VectorAngle(delta)
    local angleCost = math.abs(
        AngleDifference(targetAngle, state.ControlledAngle)
    )
    local travelCost = math.abs(radialDistance - knifeDistance) * 0.08

    return angleCost * 3 + travelCost
end

function MomsKnifeHomingModule:FindTarget(knife, state, allowHitTargets)
    local bestTarget
    local bestScore

    for _, target in ipairs(self:GetCandidates()) do
        local wasHit = state.HitTargets[EntityHash(target)] == true

        if (allowHitTargets or not wasHit)
            and self:IsReachable(knife, state, target, ACQUIRE_CONE)
        then
            local score = self:ScoreTarget(knife, state, target)

            if bestScore == nil or score < bestScore then
                bestTarget = target
                bestScore = score
            end
        end
    end

    return bestTarget
end

function MomsKnifeHomingModule:IsWithinHoldRange(knife, state, target)
    if not IsTargetableEnemy(target) then
        return false
    end

    local targetSize = target.Size or 0
    local maximumReach = (state.BaselineMaxDistance or knife.MaxDistance or 0)
        + targetSize
        + HOLD_REACH_MARGIN
    local origin = self:GetRotationOrigin(knife)
    local currentDelta = target.Position - origin

    if currentDelta:Length() > maximumReach then
        return false
    end

    local predicted = self:GetPredictedPosition(
        knife,
        state,
        target,
        origin,
        knife:GetKnifeDistance()
    )
    local predictedAngle = VectorAngle(predicted - origin)

    return math.abs(AngleDifference(predictedAngle, state.LaunchAngle))
        <= RETAIN_CONE
end

function MomsKnifeHomingModule:FindFarthestHitTarget(knife, state)
    local bestTarget
    local bestDistance

    if state.HoldTarget ~= nil
        and state.HitTargets[EntityHash(state.HoldTarget)] == true
        and self:IsWithinHoldRange(knife, state, state.HoldTarget)
    then
        bestTarget = state.HoldTarget
        local origin = self:GetRotationOrigin(knife)
        bestDistance = (state.HoldTarget.Position - origin):Length()
    end

    for _, target in ipairs(self:GetCandidates()) do
        if state.HitTargets[EntityHash(target)] == true
            and self:IsWithinHoldRange(knife, state, target)
        then
            local origin = self:GetRotationOrigin(knife)
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

    if self:MatchesDistanceCalibration(state, charge, sourceRange) then
        state.BaselineMaxDistance = state.CalibratedMaxDistance
    else
        state.BaselineMaxDistance = preparedMaxDistance
        state.CalibratedMaxDistance = preparedMaxDistance
        state.CalibratedCharge = charge
        state.CalibratedSourceRange = sourceRange
    end

    state.Flying = true
    -- MC_POST_KNIFE_UPDATE observes the first flying frame only after vanilla
    -- homing has already rotated toward its stale target position. Preserve
    -- the player's last charging/held angle from the preceding idle frame.
    state.LaunchAngle = state.PreparedLaunchAngle
        or GetWorldRotation(knife)
    state.ControlledAngle = state.LaunchAngle
    state.Target = nil
    state.HitTargets = {}
    state.HoldTarget = nil
    state.PreviousKnifeDistance = knife:GetKnifeDistance()
    state.DistanceFrame = Game():GetFrameCount()
    state.RadialSpeed = knife:GetKnifeVelocity()
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

    if state == nil then
        state = {
            Flying = false,
            HitTargets = {},
        }
        data[STATE_KEY] = state
    end

    local flying = knife:IsFlying()

    if not flying then
        state.Flying = false
        state.Target = nil
        state.PreparedLaunchAngle = self:GetHeldAimAngle(knife)
        state.PreparedMaxDistance = knife.MaxDistance
        state.PreparedCharge = knife.Charge or 0
        state.PreparedSourceRange = self:GetSourceRange(knife)
        return
    end

    if not state.Flying then
        self:BeginFlight(knife, state)
    end

    local frame = Game():GetFrameCount()
    self:GetRadialSpeed(knife, state, frame)

    -- Refresh target positions once before validating an existing lock. This
    -- also derives real per-frame displacement for NPCs whose Velocity field
    -- lags behind their visible movement.
    self:GetCandidates()

    -- Homing can rewrite MaxDistance according to the current target. Reuse
    -- the calibration for the same charge/range and retain only a five-percent
    -- window. Knife travel time follows this radial limit, so both properties
    -- stay consistent without reshooting or replacing the native knife.
    self:StabilizeMaxDistance(knife, state)

    if state.Target ~= nil
        and not self:IsReachable(knife, state, state.Target, RETAIN_CONE)
    then
        state.Target = nil
        state.HoldTarget = nil
    end

    if state.HoldTarget ~= nil then
        local unhitTarget = self:FindTarget(knife, state, false)

        if unhitTarget ~= nil then
            state.HoldTarget = nil
            state.Target = unhitTarget
        else
            state.HoldTarget = self:FindFarthestHitTarget(knife, state)
            state.Target = state.HoldTarget
        end
    end

    if state.Target == nil then
        state.Target = self:FindTarget(knife, state, false)

        if state.Target == nil then
            -- After crossing every reachable target, stay aligned with the
            -- farthest already-hit enemy still inside the calibrated range.
            -- Native knife distance and timing continue to control retraction.
            state.HoldTarget = self:FindFarthestHitTarget(knife, state)
            state.Target = state.HoldTarget
        end
    end

    local desiredAngle = state.LaunchAngle
    if state.Target ~= nil then
        local origin = self:GetRotationOrigin(knife)
        local predicted = self:GetPredictedPosition(
            knife,
            state,
            state.Target,
            origin,
            knife:GetKnifeDistance()
        )
        desiredAngle = VectorAngle(predicted - origin)
    end

    desiredAngle = ClampAngleAround(
        desiredAngle,
        state.LaunchAngle,
        MAX_STEERING_DEVIATION
    )
    state.ControlledAngle = MoveAngleTowards(
        state.ControlledAngle,
        desiredAngle,
        MAX_TURN_PER_FRAME
    )
    knife.Rotation = state.ControlledAngle - (knife.RotationOffset or 0)
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

    if state.Target ~= nil
        and EntityHash(state.Target) == EntityHash(collider)
        and state.HoldTarget == nil
    then
        state.Target = nil
    end
end

return MomsKnifeHomingModule
