local EdenBlessingDuplicatesModule = {}
EdenBlessingDuplicatesModule.__index = EdenBlessingDuplicatesModule

local SETTING_KEY = "edenBlessingDuplicateFix"
local EDEN = PlayerType.PLAYER_EDEN
local ACTIVE = ItemType.ITEM_ACTIVE
local PASSIVE = ItemType.ITEM_PASSIVE
local FAMILIAR = ItemType.ITEM_FAMILIAR
local PRIMARY_SLOT = ActiveSlot.SLOT_PRIMARY
local NO_EDEN_TAG = ItemConfig.TAG_NO_EDEN or (1 << 32)
local RNG_SHIFT_INDEX = 35

local function NormalizeSeed(seed)
    local normalized = math.abs(math.floor(tonumber(seed) or 1)) % 2147483647
    return normalized == 0 and 1 or normalized
end

function EdenBlessingDuplicatesModule.New(context)
    local self = setmetatable({
        Context = context,
        MaxCollectibleId = 1,
        Rng = RNG(),
    }, EdenBlessingDuplicatesModule)

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

function EdenBlessingDuplicatesModule:GetReplacement(player)
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

    return candidates[self.Rng:RandomInt(#candidates) + 1]
end

function EdenBlessingDuplicatesModule:GetRemovalSlot(player, collectibleType)
    local config = Isaac.GetItemConfig():GetCollectible(collectibleType)

    if not config or config.Type ~= ACTIVE then
        return PRIMARY_SLOT
    end

    local matchingSlots = {}

    for _, slot in ipairs({
        ActiveSlot.SLOT_PRIMARY,
        ActiveSlot.SLOT_SECONDARY,
        ActiveSlot.SLOT_POCKET,
        ActiveSlot.SLOT_POCKET2,
    }) do
        if player:GetActiveItem(slot) == collectibleType then
            matchingSlots[#matchingSlots + 1] = slot
        end
    end

    -- Never remove the only visible active item. A duplicated active is safe
    -- to replace only when the engine placed both copies in distinct slots.
    return #matchingSlots >= 2 and matchingSlots[#matchingSlots] or nil
end

function EdenBlessingDuplicatesModule:ReplaceOneDuplicate(
    player,
    collectibleType
)
    local replacement = self:GetReplacement(player)
    local removalSlot = self:GetRemovalSlot(player, collectibleType)

    if not replacement or removalSlot == nil then
        return false
    end

    local countBefore = player:GetCollectibleNum(collectibleType, true)
    player:RemoveCollectible(
        collectibleType,
        true,
        removalSlot,
        true
    )

    if player:GetCollectibleNum(collectibleType, true) >= countBefore then
        return false
    end

    player:AddCollectible(replacement, 0, true)
    return true
end

function EdenBlessingDuplicatesModule:FixPlayer(player)
    for collectibleType = 1, self.MaxCollectibleId do
        while player:GetCollectibleNum(collectibleType, true) > 1 do
            if not self:ReplaceOneDuplicate(player, collectibleType) then
                break
            end
        end
    end
end

function EdenBlessingDuplicatesModule:OnGameStarted(isContinued)
    if isContinued or not self.Context:IsEnabled(SETTING_KEY) then
        return
    end

    local game = Game()
    local seeds = game:GetSeeds()
    self.Rng:SetSeed(
        NormalizeSeed(seeds and seeds:GetStartSeed()),
        RNG_SHIFT_INDEX
    )
    self:RefreshMaxCollectibleId()

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(playerIndex)

        if player and player:GetPlayerType() == EDEN then
            self:FixPlayer(player)
        end
    end
end

return EdenBlessingDuplicatesModule
