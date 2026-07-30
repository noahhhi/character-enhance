local EdenBlessingDuplicatesModule = {}
EdenBlessingDuplicatesModule.__index = EdenBlessingDuplicatesModule

local SETTING_KEY = "edenBlessingDuplicateFix"
local EDENS_BLESSING = CollectibleType.COLLECTIBLE_EDENS_BLESSING
local PICKUP_PROXY = CollectibleType.COLLECTIBLE_SAD_ONION
local EDEN = PlayerType.PLAYER_EDEN
local COLLECTIBLE_PICKUP = PickupVariant.PICKUP_COLLECTIBLE
local TREASURE_POOL = ItemPoolType.POOL_TREASURE
local DEFAULT_COLLECTIBLE = CollectibleType.COLLECTIBLE_BREAKFAST
local PRIMARY_SLOT = ActiveSlot.SLOT_PRIMARY
local PASSIVE = ItemType.ITEM_PASSIVE
local FAMILIAR = ItemType.ITEM_FAMILIAR
local NO_EDEN_TAG = ItemConfig.TAG_NO_EDEN or (1 << 32)
local MAX_REPICKS = 100
local SEED_STEP = 104729

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
        PendingProxyPickups = 0,
        PendingConversions = {},
    }, EdenBlessingDuplicatesModule)

    self.PendingRewards = self:SanitizePendingRewards(
        context:GetSavedModuleData(SETTING_KEY)
    )

    context.Mod:AddCallback(
        ModCallbacks.MC_POST_PICKUP_SELECTION,
        function(_, pickup, variant, subtype)
            return self:OnPostPickupSelection(pickup, variant, subtype)
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_PICKUP_INIT,
        function(_, pickup)
            self:OnPickupInit(pickup)
        end,
        COLLECTIBLE_PICKUP
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

function EdenBlessingDuplicatesModule:OnPostPickupSelection(
    _pickup,
    variant,
    subtype
)
    if variant == COLLECTIBLE_PICKUP
        and subtype == EDENS_BLESSING
        and self.Context:IsEnabled(SETTING_KEY)
    then
        self.PendingProxyPickups = self.PendingProxyPickups + 1
        return { COLLECTIBLE_PICKUP, PICKUP_PROXY }
    end

    return nil
end

function EdenBlessingDuplicatesModule:OnPickupInit(pickup)
    if self.PendingProxyPickups <= 0
        or not pickup
        or pickup.Variant ~= COLLECTIBLE_PICKUP
        or pickup.SubType ~= PICKUP_PROXY
    then
        return
    end

    pickup:GetData().CharacterEnhanceEdenBlessingProxy = true
    self.PendingProxyPickups = self.PendingProxyPickups - 1
end

function EdenBlessingDuplicatesModule:GetPlayerKey(player)
    return tostring(GetPtrHash(player))
end

function EdenBlessingDuplicatesModule:OnPrePickupCollision(pickup, collider)
    if not pickup
        or pickup:GetData().CharacterEnhanceEdenBlessingProxy ~= true
        or not collider
    then
        return
    end

    local player = collider:ToPlayer()

    if not player then
        return
    end

    local playerKey = self:GetPlayerKey(player)

    if not self.PendingConversions[playerKey] then
        self.PendingConversions[playerKey] = {
            player = player,
            pickup = pickup,
            baseline = player:GetCollectibleNum(PICKUP_PROXY, true),
            graceFrames = 10,
        }
    end
end

function EdenBlessingDuplicatesModule:ConvertAcquiredProxy(player, pending)
    local currentCopies = player:GetCollectibleNum(PICKUP_PROXY, true)

    if currentCopies <= pending.baseline then
        return false
    end

    player:RemoveCollectible(
        PICKUP_PROXY,
        true,
        PRIMARY_SLOT,
        false
    )
    -- Vanilla has already completed price, option, and pickup-queue handling.
    -- The placeholder has no irreversible first-pickup grant. Add the real
    -- Blessing without arming vanilla's next-run counter; this module now owns
    -- exactly one future reward.
    player:AddCollectible(EDENS_BLESSING, 0, false)
    self.PendingRewards = math.min(99, self.PendingRewards + 1)
    self.Context:Save()
    Debug(string.format(
        "recorded managed reward; pending=%d",
        self.PendingRewards
    ))
    return true
end

function EdenBlessingDuplicatesModule:OnPlayerEffectUpdate(player)
    local playerKey = self:GetPlayerKey(player)
    local pending = self.PendingConversions[playerKey]

    if not pending then
        return
    end

    local queuedItem = player.QueuedItem and player.QueuedItem.Item
    local proxyIsQueued = queuedItem and queuedItem.ID == PICKUP_PROXY

    if self:ConvertAcquiredProxy(player, pending) then
        self.PendingConversions[playerKey] = nil
    elseif proxyIsQueued then
        return
    elseif not pending.pickup or not pending.pickup:Exists() then
        -- Repentance+ removes the pedestal before it inserts the collectible,
        -- and MC_POST_PEFFECT_UPDATE can run between those two operations.
        -- Keep the baseline briefly so the following frame can observe the
        -- acquired placeholder instead of discarding the conversion early.
        pending.graceFrames = pending.graceFrames - 1

        if pending.graceFrames <= 0 then
            self.PendingConversions[playerKey] = nil
        end
    end
end

function EdenBlessingDuplicatesModule:IsDuplicateForEden(player, collectible)
    return player:GetPlayerType() == EDEN
        and player:GetCollectibleNum(collectible, true) > 0
end

function EdenBlessingDuplicatesModule:IsReplacementCandidate(collectible)
    local config = Isaac.GetItemConfig():GetCollectible(collectible)

    if not config or config.Hidden == true
        or (config.Type ~= PASSIVE and config.Type ~= FAMILIAR)
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

function EdenBlessingDuplicatesModule:DrawReward(player, rewardIndex)
    local game = Game()
    local itemPool = game:GetItemPool()
    local startSeed = game:GetSeeds():GetStartSeed()
    local baseSeed = startSeed + rewardIndex * SEED_STEP
    local replacingDuplicate = false

    for attempt = 0, MAX_REPICKS do
        local collectible = itemPool:GetCollectible(
            TREASURE_POOL,
            true,
            NormalizeSeed(baseSeed + attempt),
            DEFAULT_COLLECTIBLE
        )

        if type(collectible) == "number" and collectible > 0 then
            if self:IsDuplicateForEden(player, collectible) then
                replacingDuplicate = true
            elseif not replacingDuplicate
                or self:IsReplacementCandidate(collectible)
            then
                return collectible
            end
        end
    end

    return nil
end

function EdenBlessingDuplicatesModule:OnGameStarted(isContinued)
    self.PendingProxyPickups = 0
    self.PendingConversions = {}

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
