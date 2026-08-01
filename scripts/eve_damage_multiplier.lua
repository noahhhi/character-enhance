local EveDamageMultiplierModule = {}
EveDamageMultiplierModule.__index = EveDamageMultiplierModule

local SETTING_KEY = "eveDamageMultiplier"
local EVE = PlayerType.PLAYER_EVE
local WHORE_OF_BABYLON = CollectibleType.COLLECTIBLE_WHORE_OF_BABYLON
local EVE_DAMAGE_MULTIPLIER = 0.75
local EVE_BABYLON_RED_HEARTS = 2

function EveDamageMultiplierModule.New(context)
    local self = setmetatable({
        Context = context,
    }, EveDamageMultiplierModule)

    context.Mod:AddCallback(
        ModCallbacks.MC_EVALUATE_CACHE,
        function(_, player)
            self:OnEvaluateDamage(player)
        end,
        CacheFlag.CACHE_DAMAGE
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_GAME_STARTED,
        function()
            self:RefreshPlayers()
        end
    )

    return self
end

function EveDamageMultiplierModule:IsBabylonActive(player)
    -- Eve's innate Whore of Babylon state activates at one filled Red Heart.
    -- Temporary collectible effects also cover activations such as The
    -- Empress and Birthright while Eve is above that health threshold.
    if player:GetHearts() <= EVE_BABYLON_RED_HEARTS then
        return true
    end

    local effects = player:GetEffects()

    return effects
        and effects:HasCollectibleEffect(WHORE_OF_BABYLON)
        or false
end

function EveDamageMultiplierModule:OnEvaluateDamage(player)
    if not self.Context:IsEnabled(SETTING_KEY)
        or not player
        or player:GetPlayerType() ~= EVE
        or self:IsBabylonActive(player)
    then
        return
    end

    -- Vanilla has already applied Eve's innate 0.75x multiplier at this point.
    -- Divide out only that character modifier, preserving every flat damage
    -- bonus and every unrelated multiplier already present in the cache value.
    player.Damage = player.Damage / EVE_DAMAGE_MULTIPLIER
end

function EveDamageMultiplierModule:RefreshPlayers()
    local game = Game()

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(playerIndex)

        if player then
            player:AddCacheFlags(CacheFlag.CACHE_DAMAGE)
            player:EvaluateItems()
        end
    end
end

function EveDamageMultiplierModule:OnGameStarted()
    self:RefreshPlayers()
end

function EveDamageMultiplierModule:OnSettingChanged()
    self:RefreshPlayers()
end

return EveDamageMultiplierModule
