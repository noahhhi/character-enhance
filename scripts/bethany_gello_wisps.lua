local BethanyGelloWispsModule = {}
BethanyGelloWispsModule.__index = BethanyGelloWispsModule

local SETTING_KEY = "bethanyGelloWispOrbit"
local GELLO = CollectibleType.COLLECTIBLE_GELLO
local BOOK_OF_VIRTUES = CollectibleType.COLLECTIBLE_BOOK_OF_VIRTUES
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

function BethanyGelloWispsModule.New(context)
    local self = setmetatable({ Context = context }, BethanyGelloWispsModule)

    self.WispUpdateCallback = function(_, familiar)
        self:OnWispUpdate(familiar)
    end

    context.Mod:AddCallback(
        ModCallbacks.MC_FAMILIAR_UPDATE,
        self.WispUpdateCallback,
        ITEM_WISP
    )

    return self
end


function BethanyGelloWispsModule:ShouldKeepPlayerOrbit(familiar, player)
    if not self.Context:IsEnabled(SETTING_KEY)
        or familiar.Variant ~= ITEM_WISP
        or player == nil
        or not player:HasCollectible(BOOK_OF_VIRTUES)
        or not player:HasCollectible(GELLO)
    then
        return false
    end

    local parent = familiar.Parent

    -- ITEM_WISP ignores Parent when vanilla selects Gello as its orbit target,
    -- but preserve unrelated explicit parents as a signal that another effect
    -- owns this familiar's movement.
    return parent == nil
        or SameEntity(parent, player)
        or IsGelloFamiliar(parent)
end

function BethanyGelloWispsModule:OnWispUpdate(familiar)
    local player = familiar.Player

    if not self:ShouldKeepPlayerOrbit(familiar, player) then
        return
    end

    -- A velocity override is replaced before it can affect the next frame.
    -- Set the completed familiar-update position directly, using this wisp's
    -- existing orbit geometry and its owning player as the center.
    familiar.Position = familiar:GetOrbitPosition(player.Position)
    familiar.Velocity = player.Velocity
end

function BethanyGelloWispsModule:OnSettingChanged()
    -- The next item-wisp update reads the new setting directly.
end

function BethanyGelloWispsModule:OnPreGameExit()
    -- No persistent entity state is changed by this module.
end

return BethanyGelloWispsModule
