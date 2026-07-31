local IncubusCSectionAnimationModule = {}
IncubusCSectionAnimationModule.__index = IncubusCSectionAnimationModule

local SETTING_KEY = "incubusCSectionAnimation"
local C_SECTION = CollectibleType.COLLECTIBLE_C_SECTION
local INCUBUS = FamiliarVariant.INCUBUS
local FLIGHT_FRAME_COUNT = 16
local STUCK_CHARGE_ANIMATIONS = {
    FloatChargeDown = "FloatDown",
    FloatChargeSide = "FloatSide",
    FloatChargeUp = "FloatUp",
}

function IncubusCSectionAnimationModule.New(context)
    local self = setmetatable({
        Context = context,
    }, IncubusCSectionAnimationModule)

    self.FamiliarUpdateCallback = function(_, familiar)
        self:OnFamiliarUpdate(familiar)
    end

    context.Mod:AddCallback(
        ModCallbacks.MC_FAMILIAR_UPDATE,
        self.FamiliarUpdateCallback,
        INCUBUS
    )

    return self
end

function IncubusCSectionAnimationModule:OnFamiliarUpdate(familiar)
    if not self.Context:IsEnabled(SETTING_KEY) then
        return
    end

    local player = familiar.Player

    if player == nil or not player:HasCollectible(C_SECTION) then
        return
    end

    local sprite = familiar:GetSprite()
    local currentAnimation = sprite:GetAnimation()
    local floatAnimation = STUCK_CHARGE_ANIMATIONS[currentAnimation]

    if floatAnimation ~= nil then
        local shootingInput = player:GetShootingInput()

        if shootingInput.X ~= 0 or shootingInput.Y ~= 0 then
            return
        end

        -- C Section reasserts FloatCharge at frame 0 while no firing input is
        -- held. Select the matching verified 16-frame idle flight pose from
        -- the familiar's own age so vanilla may still own active attacks.
        local flightFrame = familiar.FrameCount % FLIGHT_FRAME_COUNT
        sprite:SetFrame(floatAnimation, flightFrame)
    end
end

return IncubusCSectionAnimationModule
