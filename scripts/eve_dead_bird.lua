local EveDeadBirdModule = {}
EveDeadBirdModule.__index = EveDeadBirdModule

local SETTING_KEY = "eveDeadBirdRedHeartTrigger"
local EVE = PlayerType.PLAYER_EVE
local DEAD_BIRD = CollectibleType.COLLECTIBLE_DEAD_BIRD
local ATTACKING_DEAD_BIRD_VARIANT = FamiliarVariant.DEAD_BIRD
local NATIVE_PERMANENT_DEAD_BIRD_VARIANT = 219
local MANAGED_DATA_KEY = "CharacterEnhanceRedHeartDeadBirdOwner"
local ALTAR_PROXY_DATA_KEY = "CharacterEnhanceSoulOfEveAltarProxy"
local HALF_RED_HEART = 1
local EVE_RED_HEART_THRESHOLD = 2
local RNG_SHIFT_INDEX = 35
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

function EveDeadBirdModule:IsSameEntity(left, right)
    return left
        and right
        and (left == right or GetPtrHash(left) == GetPtrHash(right))
end

function EveDeadBirdModule:CreateFamiliarRNG(player)
    local rng = RNG()
    rng:SetSeed(math.max(1, player.InitSeed or 1), RNG_SHIFT_INDEX)
    return rng
end

function EveDeadBirdModule:FindOwnedBird(player, managedOnly)
    local fallback = nil
    local playerHash = GetPtrHash(player)

    for _, entity in ipairs(Isaac.FindByType(
        EntityType.ENTITY_FAMILIAR,
        ATTACKING_DEAD_BIRD_VARIANT,
        -1,
        false,
        false
    )) do
        local familiar = entity:ToFamiliar()

        if familiar
            and self:IsEntityAlive(familiar)
            and self:IsOwnedBy(familiar, player)
            and not self:GetData(familiar)[ALTAR_PROXY_DATA_KEY]
        then
            if self:GetData(familiar)[MANAGED_DATA_KEY] == playerHash then
                return familiar
            end

            if not managedOnly and not fallback then
                fallback = familiar
            end
        end
    end

    return fallback
end

function EveDeadBirdModule:ManageAttackingBird(player, familiar)
    if not familiar then
        return nil
    end

    local playerHash = GetPtrHash(player)
    familiar:AddEntityFlags(EntityFlag.FLAG_PERSISTENT)
    self:GetData(familiar)[MANAGED_DATA_KEY] = playerHash
    self:GetPlayerState(player).Bird = familiar
    return familiar
end

function EveDeadBirdModule:AdoptAttackingBird(player)
    return self:ManageAttackingBird(
        player,
        self:FindOwnedBird(player, false)
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
        ATTACKING_DEAD_BIRD_VARIANT,
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

    -- Variant 14 contains the complete vanilla attacking, following, and
    -- animation state machine. Mark that original entity persistent instead of
    -- emulating variant 219's engine-private activation state in Lua.
    player:CheckFamiliar(
        NATIVE_PERMANENT_DEAD_BIRD_VARIANT,
        0,
        rng,
        itemConfig
    )
    player:CheckFamiliar(
        ATTACKING_DEAD_BIRD_VARIANT,
        1,
        rng,
        itemConfig
    )
    self:AdoptAttackingBird(player)
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
        -- Remove only the persistent attacking bird owned by this rule. Cache
        -- reevaluation then recreates any legitimate native damage, low-health,
        -- or Birthright bird with its unmodified lifetime and state.
        self:RemoveManagedBirds(player)
    end

    state.Active = active
    state.NextRetryFrame = 0
    self:EvaluateFamiliarCache(player)

    if active then
        self:AdoptAttackingBird(player)
    end
end

function EveDeadBirdModule:RefreshPlayers(force)
    local game = Game()

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        self:RefreshPlayer(Isaac.GetPlayer(playerIndex), force)
    end
end

function EveDeadBirdModule:EnsureAttackingBird(player, forceRetry)
    local state = self:GetPlayerState(player)

    if not state.Active then
        return
    end

    if self:IsEntityAlive(state.Bird)
        and self:IsManagedBird(state.Bird, player)
    then
        return
    end

    if self:AdoptAttackingBird(player) then
        return
    end

    local frameCount = Game():GetFrameCount()

    if not forceRetry and frameCount < state.NextRetryFrame then
        return
    end

    state.NextRetryFrame = frameCount + MISSING_BIRD_RETRY_INTERVAL
    self:EvaluateFamiliarCache(player)
    self:AdoptAttackingBird(player)
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
        self:EnsureAttackingBird(player, false)
    end
end

function EveDeadBirdModule:OnFamiliarInit(familiar)
    if not familiar then
        return
    end

    local variant = familiar.Variant

    if variant ~= ATTACKING_DEAD_BIRD_VARIANT
        and variant ~= NATIVE_PERMANENT_DEAD_BIRD_VARIANT
    then
        return
    end

    -- The Soul of Eve altar compatibility module creates hidden variant-14
    -- proxies synchronously around Sacrificial Altar's native familiar scan.
    -- They are sacrifice slots, not low-health birds to adopt or deduplicate.
    if self.Context.CreatingSoulOfEveAltarProxy then
        return
    end

    local player = self:ResolveOwner(familiar)

    if not player or not self:ShouldKeepDeadBirdActive(player) then
        return
    end

    if variant == NATIVE_PERMANENT_DEAD_BIRD_VARIANT then
        familiar:Remove()
        return
    end

    local existing = self:GetPlayerState(player).Bird

    if self:IsEntityAlive(existing)
        and self:IsManagedBird(existing, player)
        and not self:IsSameEntity(existing, familiar)
    then
        -- Native damage may request another room bird. Remove the new entity
        -- during initialization and retain the already-active original bird.
        familiar:Remove()
        return
    end

    self:ManageAttackingBird(player, familiar)
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
            -- FLAG_PERSISTENT normally preserves this exact variant-14 entity.
            -- Cache reevaluation remains a recovery path if another system
            -- deliberately removed it.
            self:EnsureAttackingBird(player, true)
        end
    end
end

function EveDeadBirdModule:OnSettingChanged()
    self:RefreshPlayers(true)
end

return EveDeadBirdModule
