local EdenBlessingDuplicatesModule = {}
EdenBlessingDuplicatesModule.__index = EdenBlessingDuplicatesModule

local SETTING_KEY = "edenBlessingDuplicateFix"
local EDENS_BLESSING = CollectibleType.COLLECTIBLE_EDENS_BLESSING
local EDEN = PlayerType.PLAYER_EDEN
local COLLECTIBLE_PICKUP = PickupVariant.PICKUP_COLLECTIBLE
local PASSIVE = ItemType.ITEM_PASSIVE
local FAMILIAR = ItemType.ITEM_FAMILIAR
local NO_EDEN_TAG = ItemConfig.TAG_NO_EDEN or (1 << 32)
local SEED_STEP = 104729
local RNG_SHIFT_INDEX = 35

local function Debug(message)
    if type(Isaac.DebugString) == "function" then
        Isaac.DebugString("[Character Enhance][Eden's Blessing] " .. message)
    end
end

local function NormalizeSeed(seed)
    local normalized = math.abs(math.floor(tonumber(seed) or 1)) % 2147483647
    return normalized == 0 and 1 or normalized
end

function EdenBlessingDuplicatesModule.New(context)
    local self = setmetatable({
        Context = context,
        PendingRewards = 0,
        PendingPickups = {},
    }, EdenBlessingDuplicatesModule)

    self.PendingRewards = self:SanitizePendingRewards(
        context:GetSavedModuleData(SETTING_KEY)
    )

    context.Mod:AddCallback(
        ModCallbacks.MC_PRE_PICKUP_COLLISION,
        function(_, pickup, collider)
            self:OnPrePickupCollision(pickup, collider)
        end,
        COLLECTIBLE_PICKUP
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_PEFFECT_UPDATE,
        function(_, player)
            self:OnPlayerEffectUpdate(player)
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

function EdenBlessingDuplicatesModule:SanitizePendingRewards(savedData)
    if type(savedData) ~= "table" then
        return 0
    end

    local pendingRewards = savedData.pendingRewards

    if type(pendingRewards) ~= "number"
        or pendingRewards ~= pendingRewards
        or pendingRewards == math.huge
        or pendingRewards == -math.huge
    then
        return 0
    end

    return math.max(0, math.min(99, math.floor(pendingRewards)))
end

function EdenBlessingDuplicatesModule:GetPlayerKey(player)
    return tostring(GetPtrHash(player))
end

function EdenBlessingDuplicatesModule:OnPrePickupCollision(pickup, collider)
    if not pickup
        or pickup.Variant ~= COLLECTIBLE_PICKUP
        or pickup.SubType ~= EDENS_BLESSING
        or not collider
        or not self.Context:IsEnabled(SETTING_KEY)
    then
        return
    end

    local player = collider:ToPlayer()

    if not player then
        return
    end

    -- Set the pedestal's touched state before vanilla copies it into the
    -- player's queue. Changing QueueItemData after the collision is too late
    -- for Eden's Blessing: the engine has already captured its first-pickup
    -- state by then.
    pickup.Touched = true

    local playerKey = self:GetPlayerKey(player)

    if not self.PendingPickups[playerKey] then
        self.PendingPickups[playerKey] = {
            pickup = pickup,
            graceFrames = 10,
        }
    end
end

function EdenBlessingDuplicatesModule:RecordQueuedPickup(playerKey, queuedItem)
    -- The real pedestal's touched state was copied into this queue entry before
    -- collision handling completed. Keep it explicit while the queue exists,
    -- then persist exactly one module-owned future reward.
    queuedItem.Touched = true
    self.PendingRewards = math.min(99, self.PendingRewards + 1)
    self.PendingPickups[playerKey] = nil
    self.Context:Save()
    Debug(string.format(
        "recorded managed reward; pending=%d",
        self.PendingRewards
    ))
end

function EdenBlessingDuplicatesModule:OnPlayerEffectUpdate(player)
    local playerKey = self:GetPlayerKey(player)
    local pending = self.PendingPickups[playerKey]

    if not pending then
        return
    end

    local queuedItemData = player.QueuedItem
    local queuedItem = queuedItemData and queuedItemData.Item

    if queuedItem and queuedItem.ID == EDENS_BLESSING then
        self:RecordQueuedPickup(playerKey, queuedItemData)
        return
    end

    if not pending.pickup or not pending.pickup:Exists() then
        -- The pedestal can disappear one update before QueuedItem becomes
        -- observable. Keep a short grace period for that engine transition.
        pending.graceFrames = pending.graceFrames - 1

        if pending.graceFrames <= 0 then
            self.PendingPickups[playerKey] = nil
        end
    end
end

function EdenBlessingDuplicatesModule:IsDuplicateForEden(player, collectible)
    return player:GetPlayerType() == EDEN
        and player:GetCollectibleNum(collectible, true) > 0
end

function EdenBlessingDuplicatesModule:IsRewardCandidate(
    player,
    collectible
)
    local config = Isaac.GetItemConfig():GetCollectible(collectible)

    if not config or config.Hidden == true
        or (config.Type ~= PASSIVE
            and config.Type ~= FAMILIAR)
        or self:IsDuplicateForEden(player, collectible)
    then
        return false
    end

    if type(config.HasTags) == "function" then
        if config:HasTags(NO_EDEN_TAG) then
            return false
        end
    elseif type(config.Tags) == "number"
        and config.Tags & NO_EDEN_TAG ~= 0
    then
        return false
    end

    return type(config.IsAvailable) ~= "function" or config:IsAvailable()
end

function EdenBlessingDuplicatesModule:GetRewardCandidates(player)
    local itemConfig = Isaac.GetItemConfig()
    local collectibleList = itemConfig:GetCollectibles()
    local maxCollectible = math.max(0, (collectibleList.Size or 1) - 1)
    local candidates = {}

    for collectible = 1, maxCollectible do
        if self:IsRewardCandidate(player, collectible) then
            candidates[#candidates + 1] = collectible
        end
    end

    return candidates
end

function EdenBlessingDuplicatesModule:DrawReward(
    player,
    rewardIndex
)
    local game = Game()
    local startSeed = game:GetSeeds():GetStartSeed()
    local candidates = self:GetRewardCandidates(player)

    if #candidates == 0 then
        return nil
    end

    local rng = RNG()
    rng:SetSeed(
        NormalizeSeed(startSeed + rewardIndex * SEED_STEP),
        RNG_SHIFT_INDEX
    )
    return candidates[rng:RandomInt(#candidates) + 1]
end

function EdenBlessingDuplicatesModule:OnGameStarted(isContinued)
    self.PendingPickups = {}

    if isContinued or self.PendingRewards <= 0 then
        return
    end

    local game = Game()

    if game:GetNumPlayers() < 1 then
        return
    end

    local player = Isaac.GetPlayer(0)
    local rewardCount = self.PendingRewards
    local ungranted = 0
    self.PendingRewards = 0

    for rewardIndex = 1, rewardCount do
        local collectible = self:DrawReward(player, rewardIndex)

        if collectible then
            player:AddCollectible(collectible, 0, true)
            Debug(string.format(
                "granted managed reward %d/%d: collectible %d",
                rewardIndex,
                rewardCount,
                collectible
            ))
        else
            ungranted = ungranted + 1
        end
    end

    self.PendingRewards = ungranted
    self.Context:Save()
end

function EdenBlessingDuplicatesModule:GetSaveData()
    return { pendingRewards = self.PendingRewards }
end

return EdenBlessingDuplicatesModule
