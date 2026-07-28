local BethanyGelloWispsModule = {}
BethanyGelloWispsModule.__index = BethanyGelloWispsModule

local SETTING_KEY = "bethanyGelloWispOrbit"
local BETHANY = PlayerType.PLAYER_BETHANY
local GELLO = CollectibleType.COLLECTIBLE_GELLO
local ITEM_WISP = FamiliarVariant.ITEM_WISP
local GELLO_FAMILIAR = FamiliarVariant.UMBILICAL_BABY
local MAX_CHASE_SPEED = 8

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

local function HasActiveGello()
    return #Isaac.FindByType(
        EntityType.ENTITY_FAMILIAR,
        GELLO_FAMILIAR,
        -1,
        false,
        false
    ) > 0
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
        or player:GetPlayerType() ~= BETHANY
        or not player:HasCollectible(GELLO)
        or not HasActiveGello()
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

    -- Vanilla ITEM_WISP target selection ignores Parent. Drive the same orbit
    -- geometry around Bethany explicitly, retaining the wisp's own orbit layer,
    -- distance, angle, health, damage, subtype, and lifetime.
    local orbitPosition = familiar:GetOrbitPosition(player.Position)
    local correction = (orbitPosition - familiar.Position) * 0.5

    if correction:Length() > MAX_CHASE_SPEED then
        correction = correction:Resized(MAX_CHASE_SPEED)
    end

    familiar.Velocity = correction + player.Velocity * 0.5
end

function BethanyGelloWispsModule:OnSettingChanged()
    -- Movement ownership returns to vanilla on the next familiar update.
end

function BethanyGelloWispsModule:OnPreGameExit()
    -- No persistent entity state is changed by this module.
end

return BethanyGelloWispsModule
