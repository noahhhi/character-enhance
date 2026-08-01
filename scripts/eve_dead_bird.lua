local EveDeadBirdModule = {}
EveDeadBirdModule.__index = EveDeadBirdModule

local SETTING_KEY = "eveDeadBirdRedHeartTrigger"
local EVE = PlayerType.PLAYER_EVE
local DEAD_BIRD = CollectibleType.COLLECTIBLE_DEAD_BIRD
local ACTIVE_DEAD_BIRD_VARIANT = FamiliarVariant.DEAD_BIRD
local PERMANENT_DEAD_BIRD_VARIANT = 219
local HALF_RED_HEART = 1
local EVE_RED_HEART_THRESHOLD = 2
local RNG_SHIFT_INDEX = 35

function EveDeadBirdModule.New(context)
    local self = setmetatable({
        Context = context,
        ActiveStates = {},
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
        ModCallbacks.MC_POST_GAME_STARTED,
        function()
            self:OnGameStarted()
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_NEW_ROOM,
        function()
            self:RefreshPlayers()
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

function EveDeadBirdModule:CreateFamiliarRNG(player)
    local rng = RNG()
    rng:SetSeed(math.max(1, player.InitSeed or 1), RNG_SHIFT_INDEX)
    return rng
end

function EveDeadBirdModule:OnEvaluateFamiliars(player)
    if not self:ShouldKeepDeadBirdActive(player) then
        return
    end

    local itemConfig = Isaac.GetItemConfig():GetCollectible(DEAD_BIRD)
    local rng = self:CreateFamiliarRNG(player)

    -- Repentance+'s variant 219 only attacks while the engine's native
    -- total-health state owns it. Replace it throughout this Red-Heart-driven
    -- state with one normal attacking bird. A vanilla damage activation uses
    -- the same variant 14, so CheckFamiliar reuses it instead of adding a copy.
    player:CheckFamiliar(
        PERMANENT_DEAD_BIRD_VARIANT,
        0,
        rng,
        itemConfig
    )
    player:CheckFamiliar(
        ACTIVE_DEAD_BIRD_VARIANT,
        1,
        rng,
        itemConfig
    )
end

function EveDeadBirdModule:RefreshPlayer(player)
    if not player then
        return
    end

    self.ActiveStates[GetPtrHash(player)] =
        self:ShouldKeepDeadBirdActive(player)
    player:AddCacheFlags(CacheFlag.CACHE_FAMILIARS)
    player:EvaluateItems()
end

function EveDeadBirdModule:RefreshPlayers()
    local game = Game()

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        self:RefreshPlayer(Isaac.GetPlayer(playerIndex))
    end
end

function EveDeadBirdModule:OnPlayerEffectUpdate(player)
    if not player or not self.Context:IsEnabled(SETTING_KEY) then
        return
    end

    local playerHash = GetPtrHash(player)
    local active = self:ShouldKeepDeadBirdActive(player)

    if self.ActiveStates[playerHash] == active then
        return
    end

    self:RefreshPlayer(player)
end

function EveDeadBirdModule:OnGameStarted()
    self.ActiveStates = {}
    self:RefreshPlayers()
end

function EveDeadBirdModule:OnSettingChanged()
    self.ActiveStates = {}
    self:RefreshPlayers()
end

return EveDeadBirdModule
