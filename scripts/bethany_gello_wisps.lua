local BethanyGelloWispsModule = {}
BethanyGelloWispsModule.__index = BethanyGelloWispsModule

local SETTING_KEY = "bethanyGelloWispOrbit"
local BETHANY = PlayerType.PLAYER_BETHANY
local GELLO = CollectibleType.COLLECTIBLE_GELLO
local ITEM_WISP = FamiliarVariant.ITEM_WISP
local GELLO_FAMILIAR = FamiliarVariant.UMBILICAL_BABY

local function SameEntity(left, right)
    return left ~= nil
        and right ~= nil
        and (left == right or GetPtrHash(left) == GetPtrHash(right))
end

local function IsGelloFamiliar(entity)
    return entity ~= nil
        and entity.Type == EntityType.ENTITY_FAMILIAR
        and entity.Variant == GELLO_FAMILIAR
end

local function GetLiveEntity(entityPtr)
    local entity = entityPtr and entityPtr.Ref

    if entity and entity:Exists() then
        return entity
    end

    return nil
end

function BethanyGelloWispsModule.New(context)
    local self = setmetatable({
        Context = context,
        ManagedWisps = {},
    }, BethanyGelloWispsModule)

    self.WispUpdateCallback = function(_, familiar)
        self:OnWispUpdate(familiar)
    end
    self.PreUnloadCallback = function(_, unloadingMod)
        if unloadingMod == context.Mod then
            self:RestoreAll()
        end
    end

    context.Mod:AddCallback(
        ModCallbacks.MC_FAMILIAR_UPDATE,
        self.WispUpdateCallback,
        ITEM_WISP
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_PRE_MOD_UNLOAD,
        self.PreUnloadCallback
    )

    return self
end

function BethanyGelloWispsModule:ShouldKeepPlayerOrbit(familiar, player)
    return self.Context:IsEnabled(SETTING_KEY)
        and familiar.Variant == ITEM_WISP
        and player ~= nil
        and player:GetPlayerType() == BETHANY
        and player:HasCollectible(GELLO)
end

function BethanyGelloWispsModule:RestoreWisp(wispHash, state)
    local wisp = GetLiveEntity(state.Wisp)

    if wisp and wisp.Parent
        and GetPtrHash(wisp.Parent) == state.PlayerHash
    then
        -- Restore the exact parent that existed before this module took
        -- ownership. If it has disappeared, nil lets vanilla choose its
        -- current player/Gello fallback again.
        wisp.Parent = GetLiveEntity(state.OriginalParent)
    end

    self.ManagedWisps[wispHash] = nil
end

function BethanyGelloWispsModule:RestoreAll()
    local pending = self.ManagedWisps
    self.ManagedWisps = {}

    for wispHash, state in pairs(pending) do
        -- RestoreWisp writes to the fresh table, keeping iteration over the
        -- prior table stable even if an entity callback runs during cleanup.
        self:RestoreWisp(wispHash, state)
    end
end

function BethanyGelloWispsModule:OnWispUpdate(familiar)
    local wispHash = GetPtrHash(familiar)
    local state = self.ManagedWisps[wispHash]
    local player = familiar.Player

    if not self:ShouldKeepPlayerOrbit(familiar, player) then
        if state then
            self:RestoreWisp(wispHash, state)
        end

        return
    end

    local parent = familiar.Parent

    if state then
        if parent == nil or SameEntity(parent, player)
            or IsGelloFamiliar(parent)
        then
            -- Repentance+ chooses an item wisp's explicit Parent before its
            -- Book of Virtues + Gello fallback. Keep the owning Bethany as the
            -- explicit orbit target even if vanilla reapplies Gello.
            familiar.Parent = player
        else
            -- Another effect deliberately took this wisp. Preserve that
            -- unambiguous parent instead of fighting it every frame.
            self.ManagedWisps[wispHash] = nil
        end

        return
    end

    if SameEntity(parent, player) then
        return
    end

    if parent == nil or IsGelloFamiliar(parent) then
        self.ManagedWisps[wispHash] = {
            Wisp = EntityPtr(familiar),
            PlayerHash = GetPtrHash(player),
            OriginalParent = parent and EntityPtr(parent) or nil,
        }
        familiar.Parent = player
    end
end

function BethanyGelloWispsModule:OnSettingChanged(enabled)
    if not enabled then
        self:RestoreAll()
    end
end

function BethanyGelloWispsModule:OnPreGameExit()
    self:RestoreAll()
end

return BethanyGelloWispsModule
