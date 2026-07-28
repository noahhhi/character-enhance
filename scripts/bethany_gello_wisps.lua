local BethanyGelloWispsModule = {}
BethanyGelloWispsModule.__index = BethanyGelloWispsModule

local SETTING_KEY = "bethanyGelloWispOrbit"
local GELLO = CollectibleType.COLLECTIBLE_GELLO
local BOOK_OF_VIRTUES = CollectibleType.COLLECTIBLE_BOOK_OF_VIRTUES
local WISP = FamiliarVariant.WISP
local DISCOVERY_INTERVAL = 3
local WISP_REFRESH_INTERVAL = 15

local function SameEntity(left, right)
    return left ~= nil
        and right ~= nil
        and (left == right or GetPtrHash(left) == GetPtrHash(right))
end

local function HasGello(player)
    return player:HasCollectible(GELLO)
        or player:GetActiveItem(ActiveSlot.SLOT_PRIMARY) == GELLO
        or player:GetActiveItem(ActiveSlot.SLOT_SECONDARY) == GELLO
        or player:GetActiveItem(ActiveSlot.SLOT_POCKET) == GELLO
        or player:GetActiveItem(ActiveSlot.SLOT_POCKET2) == GELLO
end

function BethanyGelloWispsModule.New(context)
    local self = setmetatable({
        Context = context,
        GelloActive = false,
        TrackedWisps = {},
        TrackedPlayers = {},
        TrackedIndexes = {},
        TrackedCount = 0,
        ScanPending = true,
        DiscoveryCountdown = 0,
        RefreshCountdown = 0,
    }, BethanyGelloWispsModule)

    self.PostUpdateCallback = function()
        self:OnPostUpdate()
    end
    self.EntitySpawnCallback = function(_, entityType, variant)
        self:OnPreEntitySpawn(entityType, variant)
    end
    self.GameStartedCallback = function()
        self:OnGameStarted()
    end
    self.NewRoomCallback = function()
        self:OnNewRoom()
    end

    context.Mod:AddCallback(
        ModCallbacks.MC_POST_UPDATE,
        self.PostUpdateCallback
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_PRE_ENTITY_SPAWN,
        self.EntitySpawnCallback
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_GAME_STARTED,
        self.GameStartedCallback
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_NEW_ROOM,
        self.NewRoomCallback
    )

    return self
end

function BethanyGelloWispsModule:HasEligibleOwner()
    for playerIndex = 0, Game():GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(playerIndex)

        if player:HasCollectible(BOOK_OF_VIRTUES)
            and HasGello(player)
        then
            return true
        end
    end

    return false
end

function BethanyGelloWispsModule:ShouldKeepPlayerOrbit(familiar, player)
    if familiar.Variant ~= WISP
        or player == nil
        or not player:HasCollectible(BOOK_OF_VIRTUES)
        or not HasGello(player)
    then
        return false
    end

    local parent = familiar.Parent

    -- WISP ignores Parent when vanilla selects Gello as its orbit target,
    -- but preserve unrelated explicit parents as a signal that another effect
    -- owns this familiar's movement.
    return parent == nil
        or SameEntity(parent, player)
end

function BethanyGelloWispsModule:ClearTrackedWisps()
    for index = 1, self.TrackedCount do
        local familiar = self.TrackedWisps[index]

        if familiar ~= nil then
            self.TrackedIndexes[GetPtrHash(familiar)] = nil
        end

        self.TrackedWisps[index] = nil
        self.TrackedPlayers[index] = nil
    end

    self.TrackedCount = 0
end

function BethanyGelloWispsModule:ResetTracking()
    self:ClearTrackedWisps()
    self.GelloActive = false
    self.ScanPending = true
    self.DiscoveryCountdown = 0
    self.RefreshCountdown = 0
end

function BethanyGelloWispsModule:TrackWisp(familiar, player)
    local hash = GetPtrHash(familiar)

    if self.TrackedIndexes[hash] ~= nil then
        return
    end

    local index = self.TrackedCount + 1
    self.TrackedCount = index
    self.TrackedIndexes[hash] = index
    self.TrackedWisps[index] = familiar
    self.TrackedPlayers[index] = player
end

function BethanyGelloWispsModule:RemoveTrackedWisp(index)
    local lastIndex = self.TrackedCount
    local familiar = self.TrackedWisps[index]

    self.TrackedIndexes[GetPtrHash(familiar)] = nil

    if index ~= lastIndex then
        local lastWisp = self.TrackedWisps[lastIndex]

        self.TrackedWisps[index] = lastWisp
        self.TrackedPlayers[index] = self.TrackedPlayers[lastIndex]
        self.TrackedIndexes[GetPtrHash(lastWisp)] = index
    end

    self.TrackedWisps[lastIndex] = nil
    self.TrackedPlayers[lastIndex] = nil
    self.TrackedCount = lastIndex - 1
end

function BethanyGelloWispsModule:DiscoverGello()
    local gelloWisps = Isaac.FindByType(
        EntityType.ENTITY_FAMILIAR,
        WISP,
        GELLO,
        false,
        false
    )

    self.GelloActive = #gelloWisps > 0

    if self.GelloActive then
        self:RefreshWisps()
        self.RefreshCountdown = WISP_REFRESH_INTERVAL
    end
end

function BethanyGelloWispsModule:RefreshWisps()
    for _, entity in ipairs(Isaac.FindByType(
        EntityType.ENTITY_FAMILIAR,
        WISP,
        -1,
        false,
        false
    )) do
        local familiar = entity:ToFamiliar()
        local player = familiar and familiar.Player

        if self:ShouldKeepPlayerOrbit(familiar, player) then
            self:TrackWisp(familiar, player)
        end
    end
end

function BethanyGelloWispsModule:ApplyPlayerOrbits()
    for index = self.TrackedCount, 1, -1 do
        local familiar = self.TrackedWisps[index]
        local player = self.TrackedPlayers[index]

        if familiar:Exists()
            and player:Exists()
            and self.GelloActive
            and self:ShouldKeepPlayerOrbit(familiar, player)
        then
            familiar.Position = familiar:GetOrbitPosition(player.Position)
            familiar.Velocity = player.Velocity
        else
            self:RemoveTrackedWisp(index)
        end
    end
end

function BethanyGelloWispsModule:OnPreEntitySpawn(entityType, variant)
    if entityType == EntityType.ENTITY_FAMILIAR
        and variant == WISP
    then
        self.ScanPending = true
    end
end

function BethanyGelloWispsModule:OnGameStarted()
    self:ResetTracking()
end

function BethanyGelloWispsModule:OnNewRoom()
    -- Gello's familiar effect is room-local, including when its wisps survive.
    self:ResetTracking()
end

function BethanyGelloWispsModule:OnPostUpdate()
    if not self.Context:IsEnabled(SETTING_KEY)
        or not self:HasEligibleOwner()
    then
        if self.GelloActive or self.TrackedCount > 0 then
            self:ResetTracking()
        end

        return
    end

    if not self.GelloActive then
        self:ClearTrackedWisps()

        if self.ScanPending or self.DiscoveryCountdown <= 0 then
            self.ScanPending = false
            self.DiscoveryCountdown = DISCOVERY_INTERVAL
            self:DiscoverGello()
        else
            self.DiscoveryCountdown = self.DiscoveryCountdown - 1
        end
    elseif self.ScanPending or self.RefreshCountdown <= 0 then
        self.ScanPending = false
        self.RefreshCountdown = WISP_REFRESH_INTERVAL
        self:RefreshWisps()
    else
        self.RefreshCountdown = self.RefreshCountdown - 1
    end

    self:ApplyPlayerOrbits()
end

function BethanyGelloWispsModule:OnSettingChanged()
    self:ResetTracking()
end

function BethanyGelloWispsModule:OnPreGameExit()
    self:ResetTracking()
end

return BethanyGelloWispsModule
