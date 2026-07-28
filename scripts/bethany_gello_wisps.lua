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

    self.PostUpdateCallback = function()
        self:OnPostUpdate()
    end

    context.Mod:AddCallback(
        ModCallbacks.MC_POST_UPDATE,
        self.PostUpdateCallback
    )

    return self
end


function BethanyGelloWispsModule:ShouldKeepPlayerOrbit(familiar, player)
    if not self.Context:IsEnabled(SETTING_KEY)
        or familiar.Variant ~= ITEM_WISP
        or player == nil
        or player:GetPlayerType() ~= BETHANY
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

function BethanyGelloWispsModule:OnPostUpdate()
    if not self.Context:IsEnabled(SETTING_KEY) or not HasActiveGello() then
        return
    end

    local itemWisps = Isaac.FindByType(
        EntityType.ENTITY_FAMILIAR,
        ITEM_WISP,
        -1,
        false,
        false
    )

    for _, entity in ipairs(itemWisps) do
        local familiar = entity:ToFamiliar()
        local player = familiar and familiar.Player or nil

        if familiar ~= nil and self:ShouldKeepPlayerOrbit(familiar, player) then
            -- A familiar-update velocity override is not late enough to win
            -- against ITEM_WISP's native Gello movement. Constrain the fully
            -- updated entity to its own orbit geometry around its Bethany.
            familiar.Position = familiar:GetOrbitPosition(player.Position)
            familiar.Velocity = player.Velocity
        end
    end
end

function BethanyGelloWispsModule:OnSettingChanged()
    -- The next completed game update reads the new setting directly.
end

function BethanyGelloWispsModule:OnPreGameExit()
    -- No persistent entity state is changed by this module.
end

return BethanyGelloWispsModule
