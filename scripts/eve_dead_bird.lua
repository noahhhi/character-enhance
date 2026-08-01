local EveDeadBirdModule = {}
EveDeadBirdModule.__index = EveDeadBirdModule

local SETTING_KEY = "eveDeadBirdRedHeartTrigger"
local EVE = PlayerType.PLAYER_EVE
local DEAD_BIRD = CollectibleType.COLLECTIBLE_DEAD_BIRD
local ACTIVE_DEAD_BIRD_VARIANT = FamiliarVariant.DEAD_BIRD
local PERMANENT_DEAD_BIRD_VARIANT = 219
local MANAGED_DATA_KEY = "CharacterEnhanceRedHeartDeadBirdOwner"
local HALF_RED_HEART = 1
local EVE_RED_HEART_THRESHOLD = 2
local RNG_SHIFT_INDEX = 35
local TARGET_DISTANCE = 1000
local TARGET_INTERVAL = 13
local MOVE_SPEED = 6
local MOVE_ACCELERATION = 0.25
local IDLE_FRICTION = 0.8
local MISSING_BIRD_RETRY_INTERVAL = 30

function EveDeadBirdModule.New(context)
    local self = setmetatable({
        Context = context,
        PlayerStates = {},
    }, EveDeadBirdModule)

    context.Mod:AddCallback(
        ModCallbacks.MC_EVALUATE_CACHE,
        function(_, player)
            self:OnEvaluateFamiliars(player)
        end,
        CacheFlag.CACHE_FAMILIARS
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_PEFFECT_UPDATE,
        function(_, player)
            self:OnPlayerEffectUpdate(player)
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_FAMILIAR_INIT,
        function(_, familiar)
            self:OnFamiliarInit(familiar)
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_FAMILIAR_UPDATE,
        function(_, familiar)
            self:OnPermanentBirdUpdate(familiar)
        end,
        PERMANENT_DEAD_BIRD_VARIANT
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_GAME_STARTED,
        function()
            self:OnGameStarted()
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_NEW_ROOM,
        function()
            self:OnNewRoom()
        end
    )

    return self
end

function EveDeadBirdModule:HasDeadBird(player)
    -- Repentance+ treats normal Eve's starting Dead Bird as an innate
    -- character ability, so it is not required to appear in her inventory.
    if player:GetPlayerType() == EVE then
        return true
    end

    return player:GetCollectibleNum(DEAD_BIRD, true) > 0
end

function EveDeadBirdModule:IsAtRedHeartThreshold(player)
    local threshold = player:GetPlayerType() == EVE
        and EVE_RED_HEART_THRESHOLD
        or HALF_RED_HEART

    return player:GetHearts() <= threshold
end

function EveDeadBirdModule:ShouldKeepDeadBirdActive(player)
    return self.Context:IsEnabled(SETTING_KEY)
        and player
        and not player:IsDead()
        and self:HasDeadBird(player)
        and self:IsAtRedHeartThreshold(player)
end

function EveDeadBirdModule:GetPlayerState(player)
    local playerHash = GetPtrHash(player)
    local state = self.PlayerStates[playerHash]

    if not state then
        state = {
            Active = false,
            Bird = nil,
            NextRetryFrame = 0,
        }
        self.PlayerStates[playerHash] = state
    end

    return state
end

function EveDeadBirdModule:GetData(familiar)
    if type(familiar.GetData) == "function" then
        return familiar:GetData()
    end

    familiar.CharacterEnhanceData = familiar.CharacterEnhanceData or {}
    return familiar.CharacterEnhanceData
end

function EveDeadBirdModule:ResolveOwner(familiar)
    if familiar and familiar.Player then
        return familiar.Player
    end

    if Game():GetNumPlayers() == 1 then
        return Isaac.GetPlayer(0)
    end

    return nil
end

function EveDeadBirdModule:IsOwnedBy(familiar, player)
    local owner = self:ResolveOwner(familiar)

    return owner and GetPtrHash(owner) == GetPtrHash(player)
end

function EveDeadBirdModule:IsEntityAlive(entity)
    if not entity then
        return false
    end

    if type(entity.Exists) == "function" and not entity:Exists() then
        return false
    end

    return type(entity.IsDead) ~= "function" or not entity:IsDead()
end

function EveDeadBirdModule:CreateFamiliarRNG(player)
    local rng = RNG()
    rng:SetSeed(math.max(1, player.InitSeed or 1), RNG_SHIFT_INDEX)
    return rng
end

function EveDeadBirdModule:FindOwnedBird(player, variant)
    for _, entity in ipairs(Isaac.FindByType(
        EntityType.ENTITY_FAMILIAR,
        variant,
        -1,
        false,
        false
    )) do
        local familiar = entity:ToFamiliar()

        if familiar
            and self:IsEntityAlive(familiar)
            and self:IsOwnedBy(familiar, player)
        then
            return familiar
        end
    end

    return nil
end

function EveDeadBirdModule:ManagePermanentBird(player, familiar)
    if not familiar then
        return nil
    end

    local playerHash = GetPtrHash(player)
    self:GetData(familiar)[MANAGED_DATA_KEY] = playerHash
    self:GetPlayerState(player).Bird = familiar
    return familiar
end

function EveDeadBirdModule:AdoptPermanentBird(player)
    return self:ManagePermanentBird(
        player,
        self:FindOwnedBird(player, PERMANENT_DEAD_BIRD_VARIANT)
    )
end

function EveDeadBirdModule:IsManagedBird(familiar, player)
    return familiar
        and self:GetData(familiar)[MANAGED_DATA_KEY] == GetPtrHash(player)
end

function EveDeadBirdModule:RemoveManagedBirds(player)
    local playerHash = GetPtrHash(player)

    for _, entity in ipairs(Isaac.FindByType(
        EntityType.ENTITY_FAMILIAR,
        PERMANENT_DEAD_BIRD_VARIANT,
        -1,
        false,
        false
    )) do
        local familiar = entity:ToFamiliar()

        if familiar
            and self:IsOwnedBy(familiar, player)
            and self:GetData(familiar)[MANAGED_DATA_KEY] == playerHash
        then
            familiar:Remove()
        end
    end

    self:GetPlayerState(player).Bird = nil
end

function EveDeadBirdModule:OnEvaluateFamiliars(player)
    if not self:ShouldKeepDeadBirdActive(player) then
        return
    end

    local itemConfig = Isaac.GetItemConfig():GetCollectible(DEAD_BIRD)
    local rng = self:CreateFamiliarRNG(player)

    -- Variant 219 is Repentance+'s persistent Dead Bird. Keeping it at one
    -- lets the same entity cross room boundaries, while variant 14 is the
    -- room-only bird created by taking damage and would otherwise duplicate it.
    player:CheckFamiliar(
        ACTIVE_DEAD_BIRD_VARIANT,
        0,
        rng,
        itemConfig
    )
    player:CheckFamiliar(
        PERMANENT_DEAD_BIRD_VARIANT,
        1,
        rng,
        itemConfig
    )
    self:AdoptPermanentBird(player)
end

function EveDeadBirdModule:EvaluateFamiliarCache(player)
    player:AddCacheFlags(CacheFlag.CACHE_FAMILIARS)
    player:EvaluateItems()
end

function EveDeadBirdModule:RefreshPlayer(player, force)
    if not player then
        return
    end

    local state = self:GetPlayerState(player)
    local active = self:ShouldKeepDeadBirdActive(player)

    if not force and state.Active == active then
        return
    end

    if not active then
        -- A managed 219 may be dormant outside the Red-Heart rule. Remove it
        -- before reevaluation so the engine can recreate any legitimately
        -- native bird, such as Eve's Birthright bird, with its own AI state.
        self:RemoveManagedBirds(player)
    end

    state.Active = active
    state.NextRetryFrame = 0
    self:EvaluateFamiliarCache(player)

    if active then
        self:AdoptPermanentBird(player)
    end
end

function EveDeadBirdModule:RefreshPlayers(force)
    local game = Game()

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        self:RefreshPlayer(Isaac.GetPlayer(playerIndex), force)
    end
end

function EveDeadBirdModule:EnsurePermanentBird(player, forceRetry)
    local state = self:GetPlayerState(player)

    if not state.Active then
        return
    end

    if self:IsEntityAlive(state.Bird)
        and self:IsManagedBird(state.Bird, player)
    then
        return
    end

    if self:AdoptPermanentBird(player) then
        return
    end

    local frameCount = Game():GetFrameCount()

    if not forceRetry and frameCount < state.NextRetryFrame then
        return
    end

    state.NextRetryFrame = frameCount + MISSING_BIRD_RETRY_INTERVAL
    self:EvaluateFamiliarCache(player)
    self:AdoptPermanentBird(player)
end

function EveDeadBirdModule:OnPlayerEffectUpdate(player)
    if not player then
        return
    end

    local state = self:GetPlayerState(player)
    local active = self:ShouldKeepDeadBirdActive(player)

    if state.Active ~= active then
        self:RefreshPlayer(player, true)
        return
    end

    if active then
        self:EnsurePermanentBird(player, false)
    end
end

function EveDeadBirdModule:OnFamiliarInit(familiar)
    if not familiar then
        return
    end

    local variant = familiar.Variant

    if variant ~= ACTIVE_DEAD_BIRD_VARIANT
        and variant ~= PERMANENT_DEAD_BIRD_VARIANT
    then
        return
    end

    local player = self:ResolveOwner(familiar)

    if not player or not self:ShouldKeepDeadBirdActive(player) then
        return
    end

    if variant == ACTIVE_DEAD_BIRD_VARIANT then
        -- Damage can still ask the closed-source item code for its room bird.
        -- Remove it during initialization, before it can render or attack, so
        -- it never becomes a second Dead Bird beside the persistent one.
        familiar:Remove()
        return
    end

    self:ManagePermanentBird(player, familiar)
end

function EveDeadBirdModule:IsValidTarget(target)
    if not self:IsEntityAlive(target) or not target.Position then
        return false
    end

    return type(target.IsVulnerableEnemy) ~= "function"
        or target:IsVulnerableEnemy()
end

function EveDeadBirdModule:EnsureFlyingAnimation(familiar)
    if type(familiar.GetSprite) ~= "function" then
        return
    end

    local sprite = familiar:GetSprite()

    if not sprite then
        return
    end

    local animation = sprite:GetAnimation()

    if animation == "Flying" or animation == "FlyingTransparent" then
        return
    end

    local flyingAnimation = animation == "IdleTransparent"
        and "FlyingTransparent"
        or "Flying"
    sprite:Play(flyingAnimation, true)
end

function EveDeadBirdModule:OnPermanentBirdUpdate(familiar)
    local player = self:ResolveOwner(familiar)

    if not player
        or not self:ShouldKeepDeadBirdActive(player)
        or not self:IsManagedBird(familiar, player)
    then
        return
    end

    self:GetPlayerState(player).Bird = familiar
    self:EnsureFlyingAnimation(familiar)
    familiar:PickEnemyTarget(TARGET_DISTANCE, TARGET_INTERVAL)

    local target = familiar.Target

    if not self:IsValidTarget(target) then
        familiar.Velocity = familiar.Velocity * IDLE_FRICTION
        return
    end

    local offset = target.Position - familiar.Position

    if offset:Length() <= 0 then
        familiar.Velocity = familiar.Velocity * IDLE_FRICTION
        return
    end

    local targetVelocity = offset:Resized(MOVE_SPEED)
    familiar.Velocity = familiar.Velocity * (1 - MOVE_ACCELERATION)
        + targetVelocity * MOVE_ACCELERATION
end

function EveDeadBirdModule:OnGameStarted()
    self.PlayerStates = {}
    self:RefreshPlayers(true)
end

function EveDeadBirdModule:OnNewRoom()
    local game = Game()

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(playerIndex)
        local state = self:GetPlayerState(player)
        local active = self:ShouldKeepDeadBirdActive(player)

        if state.Active ~= active then
            self:RefreshPlayer(player, true)
        elseif active then
            -- Usually this only reuses the same 219. Cache reevaluation is a
            -- recovery path for an entity removed by a familiar cap or mod.
            self:EnsurePermanentBird(player, true)
        end
    end
end

function EveDeadBirdModule:OnSettingChanged()
    self:RefreshPlayers(true)
end

return EveDeadBirdModule
