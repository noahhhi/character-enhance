local RerollHealthModule = {}
RerollHealthModule.__index = RerollHealthModule

local REROLL_SETTING_KEY = "rerollHealthProtection"
local ESAU_JR_SETTING_KEY = "esauJrFirstPickup"
local TMTRAINER_SETTING_KEY = "rerollTmtrainerChance"
local TAINTED_EDEN = PlayerType.PLAYER_EDEN_B
local DAMAGE_NO_PENALTIES = DamageFlag.DAMAGE_NO_PENALTIES
local DAMAGE_FAKE = DamageFlag.DAMAGE_FAKE
local DAMAGE_CURSED_DOOR = DamageFlag.DAMAGE_CURSED_DOOR
local DAMAGE_IV_BAG = DamageFlag.DAMAGE_IV_BAG
local DAMAGE_SPIKES = DamageFlag.DAMAGE_SPIKES
local DICE_FLOOR = EffectVariant.DICE_FLOOR
local ENTITY_EFFECT = EntityType.ENTITY_EFFECT
local DICE_TRIGGER_DISTANCE_SQUARED = 40 * 40
local DIRECT_REROLL_ITEMS = {
    [CollectibleType.COLLECTIBLE_D4] = true,
    [CollectibleType.COLLECTIBLE_D100] = true,
}
local ESAU_JR = CollectibleType.COLLECTIBLE_ESAU_JR
local MISSING_NO = CollectibleType.COLLECTIBLE_MISSING_NO
local TMTRAINER = CollectibleType.COLLECTIBLE_TMTRAINER
local NULL_COLLECTIBLE = CollectibleType.COLLECTIBLE_NULL
local BREAKFAST = CollectibleType.COLLECTIBLE_BREAKFAST
local SECRET_POOL = ItemPoolType.POOL_SECRET
local REVERSE_WHEEL_OF_FORTUNE = Card.CARD_REVERSE_WHEEL_OF_FORTUNE
local PASSIVE = ItemType.ITEM_PASSIVE
local FAMILIAR = ItemType.ITEM_FAMILIAR

local function HasFlag(flags, flag)
    return flag ~= nil and (flags & flag) ~= 0
end

function RerollHealthModule.New(context)
    local self = setmetatable({
        Context = context,
        Players = {},
        MaxCollectibleId = 733,
        RunActive = false,
        PendingEsauJr = {},
        KnownEsauJrBodies = {},
        TmtrainerBlacklistMode = nil,
        TmtrainerPreparedDecisions = {},
        DiceRoomFace = nil,
        DiceRoomFloor = nil,
        DiceRoomTriggered = false,
    }, RerollHealthModule)

    -- Register before the Bethany module. A restored Soul Heart must already be
    -- present when Bethany's charge tracker runs, otherwise restoration could
    -- be mistaken for a newly collected heart.
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_GAME_STARTED,
        function()
            self:OnGameStarted()
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_PLAYER_INIT,
        function(_, player)
            self:TrackPlayer(player)
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_PEFFECT_UPDATE,
        function(_, player)
            self:OnPlayerEffectUpdate(player)
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_PRE_USE_ITEM,
        function(_, collectibleType, _, player)
            self:OnPreUseItem(collectibleType, player)
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_ENTITY_TAKE_DMG,
        function(_, entity, amount, flags, source)
            self:OnEntityTakeDamage(entity, amount, flags, source)
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_UPDATE,
        function()
            self:OnUpdate()
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_NEW_LEVEL,
        function()
            self:OnNewLevel()
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_NEW_ROOM,
        function()
            self:OnNewRoom()
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_USE_CARD,
        function(_, card, player)
            self:OnUseCard(card, player)
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_INPUT_ACTION,
        function(_, entity, inputHook, buttonAction)
            self:OnInputAction(entity, inputHook, buttonAction)
        end
    )

    return self
end

function RerollHealthModule:GetPlayerKey(player)
    return tostring(GetPtrHash(player))
end

function RerollHealthModule:RefreshMaxCollectibleId()
    local itemConfig = Isaac.GetItemConfig and Isaac.GetItemConfig()

    if itemConfig and itemConfig.GetCollectibles then
        local collectibles = itemConfig:GetCollectibles()

        if collectibles and type(collectibles.Size) == "number" then
            self.MaxCollectibleId = math.max(1, collectibles.Size - 1)
        end
    end
end

function RerollHealthModule:CaptureInventory(player)
    local inventory = {}

    for collectibleType = 1, self.MaxCollectibleId do
        local count = player:GetCollectibleNum(collectibleType, true)

        if count > 0 then
            inventory[collectibleType] = count
        end
    end

    return inventory
end


function RerollHealthModule:CaptureHealth(player)
    return {
        maxHearts = player:GetMaxHearts(),
        hearts = player:GetHearts(),
        soulHearts = player:GetSoulHearts(),
        blackHearts = player:GetBlackHearts(),
        boneHearts = player:GetBoneHearts(),
        rottenHearts = player:GetRottenHearts(),
        brokenHearts = player:GetBrokenHearts(),
        eternalHearts = player:GetEternalHearts(),
        goldenHearts = player:GetGoldenHearts(),
    }
end

function RerollHealthModule:AppendSoulLayout(player, target, startUnit)
    local unit = startUnit or 0

    while unit < target.soulHearts do
        local heartIndex = math.floor(unit / 2)
        local amount = math.min(2 - (unit % 2), target.soulHearts - unit)

        if target.blackHearts & (1 << heartIndex) ~= 0 then
            player:AddBlackHearts(amount)
        else
            player:AddSoulHearts(amount)
        end

        unit = unit + amount
    end
end

function RerollHealthModule:RestoreSoulLayout(player, target)
    if player:GetSoulHearts() == target.soulHearts
        and player:GetBlackHearts() == target.blackHearts
    then
        return
    end

    local temporaryRedHeart = target.soulHearts > 0
        and target.hearts == 0
        and target.maxHearts > 0
        and target.boneHearts == 0
    local temporaryBoneHeart = target.soulHearts > 0
        and target.maxHearts == 0
        and target.boneHearts == 0

    -- Keep soul-only characters alive while rebuilding the Soul/Black layout.
    -- The temporary health is removed before returning.
    if temporaryRedHeart then
        player:AddHearts(1)
    elseif temporaryBoneHeart then
        player:AddBoneHearts(1)
    end

    player:AddSoulHearts(-player:GetSoulHearts())
    self:AppendSoulLayout(player, target, 0)

    if temporaryBoneHeart then
        player:AddBoneHearts(-1)

        -- At a full 12-heart display, the temporary Bone Heart may have
        -- limited the first pass to 11 Soul/Black Hearts.
        if player:GetSoulHearts() < target.soulHearts then
            self:AppendSoulLayout(player, target, player:GetSoulHearts())
        end
    end

    if temporaryRedHeart and player:GetHearts() > target.hearts then
        player:AddHearts(target.hearts - player:GetHearts())
    end
end

function RerollHealthModule:ApplyDamageToSnapshot(health, amount)
    -- Player health APIs and damageAmount both count half-heart units: damage
    -- amount 1 removes one half-heart, while 2 removes one full heart.
    local remaining = math.max(1, math.floor(amount + 0.5))
    local target = {}

    for key, value in pairs(health) do
        target[key] = value
    end

    local soulDamage = math.min(target.soulHearts, remaining)
    target.soulHearts = target.soulHearts - soulDamage
    local soulHeartCount = math.ceil(target.soulHearts / 2)
    target.blackHearts = target.blackHearts & ((1 << soulHeartCount) - 1)
    remaining = remaining - soulDamage

    local redDamage = math.min(target.hearts, remaining)
    target.hearts = target.hearts - redDamage
    target.rottenHearts = math.min(target.rottenHearts, target.hearts)
    remaining = remaining - redDamage

    -- An empty Bone Heart is destroyed by the next hit. Bone Hearts are whole
    -- containers, while damage amount and the other heart APIs use half-hearts.
    if remaining > 0 and target.boneHearts > 0 then
        target.boneHearts = target.boneHearts - 1
    end

    return target
end

function RerollHealthModule:RestoreHealth(player, target)
    -- Raise structural limits before filling health so a reroll that removed
    -- containers cannot leave the player dead or clamp restored health.
    if player:GetMaxHearts() < target.maxHearts then
        player:AddMaxHearts(target.maxHearts - player:GetMaxHearts(), false)
    end

    if player:GetBoneHearts() < target.boneHearts then
        player:AddBoneHearts(target.boneHearts - player:GetBoneHearts())
    end

    if player:GetBrokenHearts() ~= target.brokenHearts then
        player:AddBrokenHearts(target.brokenHearts - player:GetBrokenHearts())
    end

    if player:GetBoneHearts() > target.boneHearts then
        player:AddBoneHearts(target.boneHearts - player:GetBoneHearts())
    end

    if player:GetMaxHearts() > target.maxHearts then
        player:AddMaxHearts(target.maxHearts - player:GetMaxHearts(), false)
    end

    -- Rotten Hearts are part of GetHearts(), so restore their subtype first and
    -- then correct the total red-heart fill.
    if player:GetRottenHearts() ~= target.rottenHearts then
        player:AddRottenHearts(target.rottenHearts - player:GetRottenHearts())
    end

    if player:GetHearts() ~= target.hearts then
        player:AddHearts(target.hearts - player:GetHearts())
    end

    self:RestoreSoulLayout(player, target)

    if player:GetEternalHearts() ~= target.eternalHearts then
        player:AddEternalHearts(target.eternalHearts - player:GetEternalHearts())
    end

    if player:GetGoldenHearts() ~= target.goldenHearts then
        player:AddGoldenHearts(target.goldenHearts - player:GetGoldenHearts())
    end
end

function RerollHealthModule:InventoryWasRerolled(previous, current)
    local removed = false
    local added = false

    for collectibleType, oldCount in pairs(previous) do
        if (current[collectibleType] or 0) < oldCount then
            removed = true
            break
        end
    end

    for collectibleType, newCount in pairs(current) do
        if (previous[collectibleType] or 0) < newCount then
            added = true
            break
        end
    end

    return removed and added
end

function RerollHealthModule:TrackPlayer(player)
    if not player then
        return
    end

    self.Players[self:GetPlayerKey(player)] = {
        inventory = self:CaptureInventory(player),
        health = self:CaptureHealth(player),
        pending = nil,
    }
end

function RerollHealthModule:QueueRestore(
    player,
    damageAmount,
    preparedTmtrainerDecision
)
    local tmtrainerChance = self.Context.Settings[TMTRAINER_SETTING_KEY] or 0

    if not player or (not self.Context:IsEnabled(REROLL_SETTING_KEY)
        and tmtrainerChance >= 100)
    then
        return
    end

    local key = self:GetPlayerKey(player)
    local state = self.Players[key]

    if not state then
        self:TrackPlayer(player)
        state = self.Players[key]
    end

    -- D100 and D Infinity can invoke the D4 callback internally. Keep the
    -- earliest snapshot so nested effects cannot replace the true baseline.
    if not state.pending then
        local inventory = self:CaptureInventory(player)
        local tmtrainerAllowed = preparedTmtrainerDecision

        if tmtrainerAllowed == nil then
            tmtrainerAllowed = self:PrepareTmtrainerReroll(player, inventory)
        end

        state.pending = {
            health = self:CaptureHealth(player),
            inventory = inventory,
            damageAmount = damageAmount,
            tmtrainerAllowed = tmtrainerAllowed,
        }
    elseif damageAmount then
        state.pending.damageAmount = damageAmount
    end
end

function RerollHealthModule:GetInventoryDiceFloor()
    if Game():GetRoom():GetType() ~= RoomType.ROOM_DICE then
        return nil, nil
    end

    local floors = Isaac.FindByType(
        ENTITY_EFFECT,
        DICE_FLOOR,
        -1,
        false,
        false
    )

    for _, floor in ipairs(floors) do
        if floor.SubType == 1 or floor.SubType == 6 then
            return floor.SubType, floor
        end
    end

    return nil, nil
end

function RerollHealthModule:IsDiceRoomAlreadyTriggered()
    local level = Game():GetLevel()
    local descriptor = level and level:GetCurrentRoomDesc()

    return descriptor and descriptor.PressurePlatesTriggered == true
end

function RerollHealthModule:IsPlayerOnDiceFloor(player)
    local floor = self.DiceRoomFloor

    if not player or not floor or not player.Position or not floor.Position then
        return false
    end

    local x = player.Position.X - floor.Position.X
    local y = player.Position.Y - floor.Position.Y

    return x * x + y * y <= DICE_TRIGGER_DISTANCE_SQUARED
end


function RerollHealthModule:PrepareDiceRoomDecision()
    local game = Game()
    local eventPlayer = nil
    local ownedBeforeReroll = false

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(playerIndex)
        eventPlayer = eventPlayer or player

        if player:GetCollectibleNum(TMTRAINER, true) > 0 then
            ownedBeforeReroll = true
        end
    end

    local allowed = ownedBeforeReroll or self:GetTmtrainerChance() >= 100

    if not allowed and eventPlayer then
        allowed = self:RollTmtrainerAllowed(eventPlayer)

        if not allowed then
            Game():GetItemPool():AddRoomBlacklist(TMTRAINER)
            self.TmtrainerBlacklistMode = "room"
        end
    end

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(playerIndex)
        self.TmtrainerPreparedDecisions[self:GetPlayerKey(player)] = allowed
    end
end

function RerollHealthModule:OnPlayerEffectUpdate(player)
    if not self.RunActive
        or self.DiceRoomTriggered
        or not self.DiceRoomFace
        or not self:IsPlayerOnDiceFloor(player)
    then
        return
    end

    self.DiceRoomTriggered = true

    if self.DiceRoomFace == 1 then
        local key = self:GetPlayerKey(player)
        self:QueueRestore(
            player,
            nil,
            self.TmtrainerPreparedDecisions[key]
        )
        return
    end

    -- A six-pip Dice Room applies the D100-style inventory reroll to every
    -- player. Snapshot everybody before the floor effect executes.
    local game = Game()

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        local affectedPlayer = Isaac.GetPlayer(playerIndex)
        local key = self:GetPlayerKey(affectedPlayer)
        self:QueueRestore(
            affectedPlayer,
            nil,
            self.TmtrainerPreparedDecisions[key]
        )
    end
end

function RerollHealthModule:GetTmtrainerChance()
    local chance = self.Context.Settings[TMTRAINER_SETTING_KEY]

    if type(chance) ~= "number" or chance ~= chance then
        return 0
    end

    return math.max(0, math.min(100, math.floor(chance + 0.5)))
end

function RerollHealthModule:RollTmtrainerAllowed(player)
    local chance = self:GetTmtrainerChance()

    if chance <= 0 then
        return false
    end
    if chance >= 100 then
        return true
    end

    return player:GetCollectibleRNG(TMTRAINER):RandomInt(100) < chance
end

function RerollHealthModule:PrepareTmtrainerReroll(
    player,
    inventory,
    blacklistMode
)
    if (inventory[TMTRAINER] or 0) > 0
        or self:GetTmtrainerChance() >= 100
    then
        return true
    end

    local allowed = self:RollTmtrainerAllowed(player)

    if not allowed then
        Game():GetItemPool():AddRoomBlacklist(TMTRAINER)
        if blacklistMode == "room" or self.TmtrainerBlacklistMode == nil then
            self.TmtrainerBlacklistMode = blacklistMode or "transient"
        end
    end

    return allowed
end

function RerollHealthModule:ClearTmtrainerBlacklist()
    if self.TmtrainerBlacklistMode then
        Game():GetItemPool():ResetRoomBlacklist()
        self.TmtrainerBlacklistMode = nil
    end
end

function RerollHealthModule:OnNewLevel()
    if not self.RunActive then
        return
    end

    local game = Game()

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(playerIndex)

        if player:GetCollectibleNum(MISSING_NO, true) > 0 then
            self:QueueRestore(player, nil)
        end
    end
end

function RerollHealthModule:OnNewRoom()
    self:ClearTmtrainerBlacklist()
    self.TmtrainerPreparedDecisions = {}
    self.DiceRoomFace = nil
    self.DiceRoomFloor = nil
    self.DiceRoomTriggered = false

    if not self.RunActive or self:IsDiceRoomAlreadyTriggered() then
        return
    end

    self.DiceRoomFace, self.DiceRoomFloor = self:GetInventoryDiceFloor()

    if self.DiceRoomFace then
        -- The room blacklist is global, so one roll decision is shared by the
        -- single Dice Room event. If any co-op player already owns TMTRAINER,
        -- preserve vanilla behavior instead of restricting that player's roll.
        self:PrepareDiceRoomDecision()
    end
end

function RerollHealthModule:OnUseCard(card, player)
    if card == REVERSE_WHEEL_OF_FORTUNE then
        self:QueueRestore(player, nil)
    end
end

function RerollHealthModule:OnInputAction(entity, inputHook, buttonAction)
    if inputHook ~= InputHook.IS_ACTION_TRIGGERED
        or buttonAction ~= ButtonAction.ACTION_PILLCARD
    then
        return
    end

    local player = entity and entity:ToPlayer()

    if player and player:GetCard(0) == REVERSE_WHEEL_OF_FORTUNE then
        self:QueueRestore(player, nil)
    end
end

function RerollHealthModule:GetSecretRoomReplacement(player)
    local itemPool = Game():GetItemPool()
    local rng = player:GetCollectibleRNG(TMTRAINER)

    for _ = 1, 20 do
        local collectibleType = itemPool:GetCollectible(
            SECRET_POOL,
            false,
            rng:Next(),
            NULL_COLLECTIBLE
        )

        if collectibleType ~= TMTRAINER and collectibleType > 0 then
            return collectibleType
        end
    end

    return BREAKFAST
end

function RerollHealthModule:ReplaceUnexpectedTmtrainer(
    player,
    previousInventory,
    currentInventory,
    fullInventoryReroll,
    preRollAllowed
)
    if not fullInventoryReroll
        or (previousInventory[TMTRAINER] or 0) > 0
        or self:GetTmtrainerChance() >= 100
    then
        return false
    end


    local tmtrainerAllowed = preRollAllowed

    if tmtrainerAllowed == nil then
        tmtrainerAllowed = self:RollTmtrainerAllowed(player)
    end

    if tmtrainerAllowed then
        return false
    end

    local unexpectedCount = currentInventory[TMTRAINER] or 0

    if unexpectedCount <= 0 then
        return false
    end

    local replaced = false

    for _ = 1, unexpectedCount do
        player:RemoveCollectible(
            TMTRAINER,
            true,
            ActiveSlot.SLOT_PRIMARY,
            true
        )
        player:AddCollectible(
            self:GetSecretRoomReplacement(player),
            0,
            true,
            ActiveSlot.SLOT_PRIMARY,
            0,
            SECRET_POOL
        )
        replaced = true
    end

    return replaced
end

function RerollHealthModule:OnPreUseItem(collectibleType, player)
    if DIRECT_REROLL_ITEMS[collectibleType] then
        -- D Infinity's D4/D100 faces, Void and Metronome dispatch the selected
        -- vanilla active effect through this callback too. Handling the inner
        -- D4/D100 callback covers those paths without affecting D Infinity's
        -- pedestal-only or stat-only faces.
        self:QueueRestore(player, nil)
    elseif collectibleType == ESAU_JR then
        self:QueueEsauJrScan(player)
    end
end

function RerollHealthModule:QueueEsauJrScan(player)
    if not player or not self.Context:IsEnabled(ESAU_JR_SETTING_KEY) then
        return
    end

    local knownPlayers = {}
    local game = Game()

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        knownPlayers[tostring(GetPtrHash(Isaac.GetPlayer(playerIndex)))] = true
    end

    self.PendingEsauJr[#self.PendingEsauJr + 1] = {
        knownPlayers = knownPlayers,
        controllerIndex = player.ControllerIndex,
        framesLeft = 3,
    }
end

function RerollHealthModule:RegisterEsauJrInventory(player)
    local itemConfig = Isaac.GetItemConfig()

    for collectibleType = 1, self.MaxCollectibleId do
        local count = player:GetCollectibleNum(collectibleType, true)
        local config = count > 0 and itemConfig:GetCollectible(collectibleType)

        if config and (config.Type == PASSIVE or config.Type == FAMILIAR) then
            for _ = 1, count do
                -- Esau Jr.'s generated inventory skips normal first-pickup
                -- processing. Replay it once for every passive/familiar, not
                -- only tagged form items: untagged items such as Marbles also
                -- have first-pickup effects. Remove only the temporary copy;
                -- RemoveFromPlayerForm=false preserves any form progress.
                player:AddCollectible(collectibleType, 0, true)
                player:RemoveCollectible(
                    collectibleType,
                    true,
                    ActiveSlot.SLOT_PRIMARY,
                    false
                )
            end
        end
    end
end

function RerollHealthModule:ProcessPendingEsauJr()
    if #self.PendingEsauJr == 0 then
        return
    end

    local game = Game()

    for pendingIndex = #self.PendingEsauJr, 1, -1 do
        local pending = self.PendingEsauJr[pendingIndex]
        local foundPlayer = nil

        for playerIndex = 0, game:GetNumPlayers() - 1 do
            local player = Isaac.GetPlayer(playerIndex)
            local playerHash = tostring(GetPtrHash(player))

            if not pending.knownPlayers[playerHash]
                and (pending.controllerIndex == nil
                    or player.ControllerIndex == pending.controllerIndex)
            then
                foundPlayer = player
                break
            end
        end

        if foundPlayer then
            local playerHash = tostring(GetPtrHash(foundPlayer))

            -- Esau Jr. swaps between two already-created bodies on later uses.
            -- Only the newly generated body needs its skipped first-pickup
            -- processing replayed; revisiting either known body must do nothing.
            if not self.KnownEsauJrBodies[playerHash] then
                self:RegisterEsauJrInventory(foundPlayer)
                self.KnownEsauJrBodies[playerHash] = true
            end

            table.remove(self.PendingEsauJr, pendingIndex)
        else
            pending.framesLeft = pending.framesLeft - 1

            if pending.framesLeft <= 0 then
                table.remove(self.PendingEsauJr, pendingIndex)
            end
        end
    end
end

function RerollHealthModule:IsExcludedDamage(flags, source)
    if HasFlag(flags, DAMAGE_NO_PENALTIES)
        or HasFlag(flags, DAMAGE_FAKE)
        or HasFlag(flags, DAMAGE_CURSED_DOOR)
        or HasFlag(flags, DAMAGE_IV_BAG)
    then
        return true
    end

    if HasFlag(flags, DAMAGE_SPIKES)
        and Game():GetRoom():GetType() == RoomType.ROOM_SACRIFICE
    then
        return true
    end

    local sourceEntity = source and source.Entity

    return sourceEntity
        and sourceEntity.Type == EntityType.ENTITY_SLOT
        and sourceEntity.Variant == 2
end

function RerollHealthModule:OnEntityTakeDamage(entity, amount, flags, source)
    local player = entity and entity:ToPlayer()

    if not player or player:GetPlayerType() ~= TAINTED_EDEN then
        return
    end

    if self:IsExcludedDamage(flags, source) then
        return
    end

    self:QueueRestore(player, amount)
end

function RerollHealthModule:SyncPlayer(player)
    local key = self:GetPlayerKey(player)
    local state = self.Players[key]

    if not state then
        self:TrackPlayer(player)
        return
    end

    local currentInventory = self:CaptureInventory(player)
    local detectedReroll = self:InventoryWasRerolled(
        state.inventory,
        currentInventory
    )
    local fullInventoryReroll = detectedReroll or state.pending ~= nil
    local previousInventory = state.pending and state.pending.inventory
        or state.inventory
    local preRollAllowed = self.TmtrainerPreparedDecisions[key]

    if state.pending and state.pending.tmtrainerAllowed ~= nil then
        preRollAllowed = state.pending.tmtrainerAllowed
    end

    if self:ReplaceUnexpectedTmtrainer(
        player,
        previousInventory,
        currentInventory,
        fullInventoryReroll,
        preRollAllowed
    ) then
        currentInventory = self:CaptureInventory(player)
    end

    if self.Context:IsEnabled(REROLL_SETTING_KEY)
        and fullInventoryReroll
    then
        local baseline = state.pending and state.pending.health or state.health

        if state.pending and state.pending.damageAmount then
            baseline = self:ApplyDamageToSnapshot(
                baseline,
                state.pending.damageAmount
            )
        end

        self:RestoreHealth(player, baseline)
    end

    state.inventory = currentInventory
    state.health = self:CaptureHealth(player)
    state.pending = nil

    if detectedReroll then
        self.TmtrainerPreparedDecisions[key] = nil
    end
end

function RerollHealthModule:OnUpdate()
    if not self.RunActive then
        return
    end

    self:ProcessPendingEsauJr()

    local game = Game()
    local present = {}

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(playerIndex)
        local key = self:GetPlayerKey(player)
        present[key] = true
        self:SyncPlayer(player)
        self.KnownEsauJrBodies[key] = true
    end

    for key in pairs(self.Players) do
        if not present[key] then
            self.Players[key] = nil
        end
    end


    -- MC_PRE_USE_ITEM and the damage callback run before vanilla's inventory
    -- reroll. Keep the temporary blacklist through that effect, then restore
    -- normal room-pool behavior once this update has completed.
    if self.TmtrainerBlacklistMode == "transient" then
        self:ClearTmtrainerBlacklist()
    end
end

function RerollHealthModule:OnGameStarted()
    self:ClearTmtrainerBlacklist()
    self.RunActive = true
    self.Players = {}
    self.PendingEsauJr = {}
    self.KnownEsauJrBodies = {}
    self.TmtrainerPreparedDecisions = {}
    self.DiceRoomFace = nil
    self.DiceRoomFloor = nil
    self.DiceRoomTriggered = false
    self:RefreshMaxCollectibleId()

    local game = Game()

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(playerIndex)
        self:TrackPlayer(player)
        self.KnownEsauJrBodies[self:GetPlayerKey(player)] = true
    end
end

function RerollHealthModule:OnSettingChanged(_, settingKey)
    if settingKey == ESAU_JR_SETTING_KEY then
        -- Disabling pauses future first-use registration. Keep known bodies so
        -- toggling the option cannot replay one-time pickup effects.
        self.PendingEsauJr = {}
        return
    end

    if settingKey == TMTRAINER_SETTING_KEY then
        self:ClearTmtrainerBlacklist()
        self.TmtrainerPreparedDecisions = {}

        if self.RunActive and Game():GetRoom():GetType() == RoomType.ROOM_DICE then
            self:OnNewRoom()
        end

        return
    end

    self.Players = {}

    if self.RunActive then
        local game = Game()

        for playerIndex = 0, game:GetNumPlayers() - 1 do
            local player = Isaac.GetPlayer(playerIndex)
            self:TrackPlayer(player)
        end
    end
end

function RerollHealthModule:OnPreGameExit()
    self:ClearTmtrainerBlacklist()
    self.RunActive = false
    self.Players = {}
    self.PendingEsauJr = {}
    self.KnownEsauJrBodies = {}
    self.TmtrainerPreparedDecisions = {}
    self.DiceRoomFace = nil
    self.DiceRoomFloor = nil
    self.DiceRoomTriggered = false
end

return RerollHealthModule
