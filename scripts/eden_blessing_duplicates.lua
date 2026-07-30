local EdenBlessingDuplicatesModule = {}
EdenBlessingDuplicatesModule.__index = EdenBlessingDuplicatesModule

local SETTING_KEY = "edenBlessingDuplicateFix"
local EDEN = PlayerType.PLAYER_EDEN
local PASSIVE = ItemType.ITEM_PASSIVE
local FAMILIAR = ItemType.ITEM_FAMILIAR
local NO_EDEN_TAG = ItemConfig.TAG_NO_EDEN or (1 << 32)
local RNG_SHIFT_INDEX = 35

local function NormalizeSeed(seed)
    local normalized = math.abs(math.floor(tonumber(seed) or 1)) % 2147483647
    return normalized == 0 and 1 or normalized
end

function EdenBlessingDuplicatesModule.New(context)
    local self = setmetatable({
        Context = context,
        StartupActive = false,
        MaxCollectibleId = 1,
        Rng = RNG(),
    }, EdenBlessingDuplicatesModule)

    context.Mod:AddCallback(
        ModCallbacks.MC_POST_PLAYER_INIT,
        function(_, player)
            self:OnPlayerInit(player)
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_GET_COLLECTIBLE,
        function(_, selectedCollectible, poolType, decrease, seed)
            return self:OnPostGetCollectible(
                selectedCollectible,
                poolType,
                decrease,
                seed
            )
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_GAME_STARTED,
        function(_, isContinued)
            self:OnGameStarted(isContinued)
        end
    )

    return self
end

function EdenBlessingDuplicatesModule:RefreshMaxCollectibleId()
    local itemConfig = Isaac.GetItemConfig and Isaac.GetItemConfig()
    local collectibles = itemConfig and itemConfig.GetCollectibles
        and itemConfig:GetCollectibles()

    if collectibles and type(collectibles.Size) == "number" then
        self.MaxCollectibleId = math.max(1, collectibles.Size - 1)
    end
end

function EdenBlessingDuplicatesModule:IsNoEdenItem(config)
    if type(config.HasTags) == "function" then
        return config:HasTags(NO_EDEN_TAG)
    end

    return type(config.Tags) == "number"
        and config.Tags & NO_EDEN_TAG ~= 0
end

function EdenBlessingDuplicatesModule:IsReplacementCandidate(
    player,
    collectibleType,
    config
)
    if not config or config.Hidden == true
        or (config.Type ~= PASSIVE and config.Type ~= FAMILIAR)
        or player:GetCollectibleNum(collectibleType, true) > 0
        or self:IsNoEdenItem(config)
    then
        return false
    end

    return type(config.IsAvailable) ~= "function" or config:IsAvailable()
end

function EdenBlessingDuplicatesModule:GetReplacement(player, seed)
    local itemConfig = Isaac.GetItemConfig()
    local candidates = {}

    for collectibleType = 1, self.MaxCollectibleId do
        local config = itemConfig:GetCollectible(collectibleType)

        if self:IsReplacementCandidate(player, collectibleType, config) then
            candidates[#candidates + 1] = collectibleType
        end
    end

    if #candidates == 0 then
        return nil
    end

    self.Rng:SetSeed(NormalizeSeed(seed), RNG_SHIFT_INDEX)
    return candidates[self.Rng:RandomInt(#candidates) + 1]
end

function EdenBlessingDuplicatesModule:GetPrimaryEden()
    local game = Game()

    if game:GetNumPlayers() < 1 then
        return nil
    end

    local player = Isaac.GetPlayer(0)

    if player and player:GetPlayerType() == EDEN then
        return player
    end

    return nil
end

function EdenBlessingDuplicatesModule:OnPlayerInit(player)
    if not self.Context:IsEnabled(SETTING_KEY)
        or Game():GetFrameCount() ~= 0
        or not player
        or player:GetPlayerType() ~= EDEN
    then
        return
    end

    self.StartupActive = true
    self:RefreshMaxCollectibleId()
end

function EdenBlessingDuplicatesModule:OnPostGetCollectible(
    selectedCollectible,
    _poolType,
    _decrease,
    seed
)
    if not self.StartupActive
        or not self.Context:IsEnabled(SETTING_KEY)
        or type(selectedCollectible) ~= "number"
        or selectedCollectible <= 0
    then
        return nil
    end

    local player = self:GetPrimaryEden()

    if not player
        or player:GetCollectibleNum(selectedCollectible, true) <= 0
    then
        return nil
    end

    return self:GetReplacement(player, seed)
end

function EdenBlessingDuplicatesModule:OnGameStarted(_isContinued)
    self.StartupActive = false
end

return EdenBlessingDuplicatesModule
