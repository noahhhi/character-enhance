local HabitSharpPlugModule = {}
HabitSharpPlugModule.__index = HabitSharpPlugModule

local SETTING_KEY = "habitSharpPlugSynergy"
local PRIMARY_SLOT = ActiveSlot.SLOT_PRIMARY
local ACTIVE_ACTION = ButtonAction.ACTION_ITEM
local TRIGGERED_INPUT = InputHook.IS_ACTION_TRIGGERED
local HABIT = CollectibleType.COLLECTIBLE_HABIT
local SHARP_PLUG = CollectibleType.COLLECTIBLE_SHARP_PLUG
local BATTERY = CollectibleType.COLLECTIBLE_BATTERY
local SHARP_PLUG_DAMAGE_FLAGS = DamageFlag.DAMAGE_NOKILL
    | DamageFlag.DAMAGE_RED_HEARTS
    | DamageFlag.DAMAGE_ISSAC_HEART
    | DamageFlag.DAMAGE_INVINCIBLE
    | DamageFlag.DAMAGE_IV_BAG
    | DamageFlag.DAMAGE_NO_MODIFIERS
local SHARP_PLUG_DAMAGE_AMOUNT = 1
local SHARP_PLUG_DAMAGE_COUNTDOWN = 30

function HabitSharpPlugModule.New(context)
    local self = setmetatable({
        Context = context,
        PendingFrames = {},
        InputProbeActive = false,
    }, HabitSharpPlugModule)

    context.Mod:AddCallback(
        ModCallbacks.MC_INPUT_ACTION,
        function(_, entity, inputHook, buttonAction)
            self:OnInputAction(entity, inputHook, buttonAction)
        end,
        EntityType.ENTITY_PLAYER
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_ENTITY_TAKE_DMG,
        function(_, entity, amount, flags, source, countdown)
            return self:OnEntityTakeDamage(
                entity,
                amount,
                flags,
                source,
                countdown
            )
        end,
        EntityType.ENTITY_PLAYER
    )

    return self
end

function HabitSharpPlugModule:GetPlayerKey(player)
    return tostring(GetPtrHash(player))
end

function HabitSharpPlugModule:IsEligible(player)
    return self.Context:IsEnabled(SETTING_KEY)
        and player:HasCollectible(HABIT)
        and player:HasCollectible(SHARP_PLUG)
        and not player:HasCollectible(BATTERY)
end

function HabitSharpPlugModule:IsActiveActionTriggered(player)
    if self.InputProbeActive then
        return false
    end

    -- MC_INPUT_ACTION reports engine polling. Query the underlying trigger
    -- once while guarding the nested callback produced by that query.
    self.InputProbeActive = true
    local triggered = Input.IsActionTriggered(
        ACTIVE_ACTION,
        player.ControllerIndex
    )
    self.InputProbeActive = false

    return triggered == true
end

function HabitSharpPlugModule:OnInputAction(
    entity,
    inputHook,
    buttonAction
)
    if inputHook ~= TRIGGERED_INPUT or buttonAction ~= ACTIVE_ACTION then
        return
    end

    local player = entity and entity:ToPlayer()

    if not player
        or not self:IsEligible(player)
        or not player:NeedsCharge(PRIMARY_SLOT)
        or not self:IsActiveActionTriggered(player)
    then
        return
    end

    self.PendingFrames[self:GetPlayerKey(player)] = Game():GetFrameCount()
end

function HabitSharpPlugModule:IsSharpPlugDamage(
    player,
    amount,
    flags,
    source,
    countdown
)
    if amount ~= SHARP_PLUG_DAMAGE_AMOUNT
        or flags ~= SHARP_PLUG_DAMAGE_FLAGS
        or countdown ~= SHARP_PLUG_DAMAGE_COUNTDOWN
    then
        return false
    end

    local sourceEntity = source and source.Entity
    local sourcePlayer = sourceEntity and sourceEntity:ToPlayer()

    return sourcePlayer ~= nil
        and GetPtrHash(sourcePlayer) == GetPtrHash(player)
end

function HabitSharpPlugModule:OnEntityTakeDamage(
    entity,
    amount,
    flags,
    source,
    countdown
)
    local player = entity and entity:ToPlayer()

    if not player then
        return
    end

    local playerKey = self:GetPlayerKey(player)
    local currentFrame = Game():GetFrameCount()

    if self.PendingFrames[playerKey] ~= currentFrame then
        self.PendingFrames[playerKey] = nil
        return
    end

    if not self:IsEligible(player)
        or not self:IsSharpPlugDamage(
            player,
            amount,
            flags,
            source,
            countdown
        )
    then
        return
    end

    -- Sharp Plug and Habit each grant one charge for every accepted hit.
    -- Once their combined gains have filled the active, cancel only the
    -- precomputed surplus hits. Odd charge deficits naturally round up.
    if not player:NeedsCharge(PRIMARY_SLOT) then
        return false
    end
end

function HabitSharpPlugModule:OnSettingChanged(enabled)
    if not enabled then
        self.PendingFrames = {}
    end
end

return HabitSharpPlugModule
