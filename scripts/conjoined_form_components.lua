local ConjoinedFormComponentsModule = {}
ConjoinedFormComponentsModule.__index = ConjoinedFormComponentsModule

local SETTING_KEY = "conjoinedFamiliarComponents"
local LITTLE_GISH = CollectibleType.COLLECTIBLE_LITTLE_GISH
local LIL_MONSTRO = CollectibleType.COLLECTIBLE_LIL_MONSTRO
local HUSHY = CollectibleType.COLLECTIBLE_HUSHY
local LIL_SPEWER = CollectibleType.COLLECTIBLE_LIL_SPEWER
local BROTHER_BOBBY = CollectibleType.COLLECTIBLE_BROTHER_BOBBY
local GLOWING_HOUR_GLASS =
    CollectibleType.COLLECTIBLE_GLOWING_HOUR_GLASS
local MAX_COMPONENT_COPIES = 99
local CONJOINED_FORM = PlayerForm.PLAYERFORM_BABY
local REWIND_HISTORY_LIMIT = 256
local REWIND_REQUEST_TIMEOUT = 120

local COMPONENTS = {
    { key = "littleGish", collectible = LITTLE_GISH },
    { key = "lilMonstro", collectible = LIL_MONSTRO },
    { key = "hushy", collectible = HUSHY },
    { key = "lilSpewer", collectible = LIL_SPEWER },
}

function ConjoinedFormComponentsModule.New(context)
    local self = setmetatable({
        Context = context,
        SavedData = {},
        PreservedData = {},
        Applied = {},
        RunSeed = nil,
        RunActive = false,
        HasLoadedRun = false,
        RewindHistory = {},
        LastRoomTimeCounter = nil,
        AwaitingRewindRoom = false,
        PendingRewind = nil,
    }, ConjoinedFormComponentsModule)

    self:OnSaveDataLoaded(context:GetSavedModuleData(SETTING_KEY))

    context.Mod:AddCallback(
        ModCallbacks.MC_POST_GAME_STARTED,
        function(_, isContinued)
            self:OnGameStarted(isContinued)
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_PEFFECT_UPDATE,
        function(_, player)
            self:OnPlayerEffectUpdate(player)
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_NEW_ROOM,
        function()
            self:OnNewRoom()
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_PRE_USE_ITEM,
        function()
            self:RecordRewindRequest("hourglass")
        end,
        GLOWING_HOUR_GLASS
    )

    return self
end

function ConjoinedFormComponentsModule:OnSaveDataLoaded(savedData)
    self.SavedData = type(savedData) == "table" and savedData or {}
    self.PreservedData = self:SanitizeSavedData(self.SavedData)
end

function ConjoinedFormComponentsModule:SanitizeSavedData(savedData)
    local result = { applied = {} }

    if type(savedData) ~= "table" then
        return result
    end

    local runSeed = savedData.runSeed

    if type(runSeed) == "number" and runSeed == runSeed
        and runSeed ~= math.huge and runSeed ~= -math.huge
    then
        result.runSeed = math.floor(runSeed)
    end

    local pendingRewind = savedData.pendingRewind

    if type(pendingRewind) == "table" then
        local pendingRunSeed = pendingRewind.runSeed
        local pendingTimeCounter = pendingRewind.timeCounter

        if type(pendingRunSeed) == "number"
            and pendingRunSeed == pendingRunSeed
            and pendingRunSeed ~= math.huge
            and pendingRunSeed ~= -math.huge
            and type(pendingTimeCounter) == "number"
            and pendingTimeCounter == pendingTimeCounter
            and pendingTimeCounter >= 0
            and pendingTimeCounter <= 2147483647
        then
            result.pendingRewind = {
                runSeed = math.floor(pendingRunSeed),
                timeCounter = math.floor(pendingTimeCounter),
            }
        end
    end

    if type(savedData.applied) ~= "table" then
        return result
    end

    for playerKey, value in pairs(savedData.applied) do
        local playerIndex = tonumber(playerKey)

        if playerIndex
            and playerIndex == math.floor(playerIndex)
            and playerIndex >= 0 and playerIndex <= 15
        then
            local counts = {}

            -- Version 1.24.0 stored a two-bit presence mask. Migrate it so a
            -- hot reload does not apply Little Gish or Lil Monstro twice.
            if type(value) == "number"
                and value == math.floor(value)
                and value >= 1 and value <= 3
            then
                counts.littleGish = value % 2 == 1 and 1 or nil
                counts.lilMonstro = value >= 2 and 1 or nil
            elseif type(value) == "table" then
                for _, component in ipairs(COMPONENTS) do
                    local count = value[component.key]

                    if type(count) == "number"
                        and count == math.floor(count)
                        and count >= 1 and count <= MAX_COMPONENT_COPIES
                    then
                        counts[component.key] = count
                    end
                end
            end

            if next(counts) then
                result.applied[tostring(playerIndex)] = counts
            end
        end
    end

    return result
end

function ConjoinedFormComponentsModule:GetRunSeed()
    return Game():GetSeeds():GetStartSeed()
end

function ConjoinedFormComponentsModule:GetTimeCounter()
    local game = Game()

    if type(game.TimeCounter) == "number" then
        return game.TimeCounter
    end

    return game:GetFrameCount()
end

function ConjoinedFormComponentsModule:CopyApplied(applied)
    local result = {}

    for playerKey, counts in pairs(applied or {}) do
        local copiedCounts = {}

        for componentKey, count in pairs(counts) do
            copiedCounts[componentKey] = count
        end

        result[playerKey] = copiedCounts
    end

    return result
end

function ConjoinedFormComponentsModule:CaptureRewindSnapshot(timeCounter)
    local snapshot = {
        timeCounter = timeCounter or self:GetTimeCounter(),
        applied = self:CopyApplied(self.Applied),
    }

    self.RewindHistory[#self.RewindHistory + 1] = snapshot

    if #self.RewindHistory > REWIND_HISTORY_LIMIT then
        table.remove(self.RewindHistory, 1)
    end

    return snapshot
end


function ConjoinedFormComponentsModule:FindRewindSnapshot(timeCounter)
    for index = #self.RewindHistory, 1, -1 do
        local snapshot = self.RewindHistory[index]

        if snapshot.timeCounter <= timeCounter then
            return snapshot, index
        end
    end

    return nil, nil
end

function ConjoinedFormComponentsModule:CopyPendingRewind(pendingRewind)
    if not pendingRewind then
        return nil
    end

    return {
        runSeed = pendingRewind.runSeed,
        timeCounter = pendingRewind.timeCounter,
    }
end

function ConjoinedFormComponentsModule:IsPersistedRewind(isContinued)
    local pendingRewind = self.PreservedData.pendingRewind

    return isContinued
        and pendingRewind ~= nil
        and pendingRewind.runSeed == self.RunSeed
        and self:GetTimeCounter() < pendingRewind.timeCounter
end

function ConjoinedFormComponentsModule:RecordRewindRequest(source)
    if not self.RunActive then
        return
    end

    self.PendingRewind = {
        runSeed = self.RunSeed or self:GetRunSeed(),
        timeCounter = self:GetTimeCounter(),
    }
    self.AwaitingRewindRoom = true
    self.Context:Save()
    Isaac.DebugString(
        "[Character Enhance][Conjoined] " .. source
            .. " rewind request recorded at "
            .. tostring(self.PendingRewind.timeCounter)
    )
end

function ConjoinedFormComponentsModule:GetPlayerIndex(player)
    local playerHash = GetPtrHash(player)
    local game = Game()

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        if GetPtrHash(Isaac.GetPlayer(playerIndex)) == playerHash then
            return playerIndex
        end
    end

    return nil
end

function ConjoinedFormComponentsModule:LoadApplied(isContinued)
    self.Applied = {}

    if not isContinued
        or self.PreservedData.runSeed ~= self.RunSeed
    then
        return
    end

    for playerKey, value in pairs(self.PreservedData.applied) do
        local counts = {}

        for componentKey, count in pairs(value) do
            counts[componentKey] = count
        end

        self.Applied[playerKey] = counts
    end
end

function ConjoinedFormComponentsModule:GetTargetCount(player, collectible)
    if not self.Context:IsEnabled(SETTING_KEY) then
        return 0
    end

    return self:GetOwnedTargetCount(player, collectible)
end

function ConjoinedFormComponentsModule:GetOwnedTargetCount(
    player,
    collectible
)
    if player:IsDead() then
        return 0
    end

    return math.min(
        MAX_COMPONENT_COPIES,
        math.max(0, player:GetCollectibleNum(collectible, true))
    )
end

function ConjoinedFormComponentsModule:GetNativeComponentCount(player)
    local itemConfig = Isaac.GetItemConfig()
    local collectibleList = itemConfig:GetCollectibles()
    local count = 0

    for collectible = 1, collectibleList.Size - 1 do
        local config = itemConfig:GetCollectible(collectible)

        if config and config:HasTags(ItemConfig.TAG_BABY) then
            count = count + player:GetCollectibleNum(collectible, true)
        end
    end

    return count
end

function ConjoinedFormComponentsModule:GetSupplementalComponentCount(player)
    local count = 0

    for _, component in ipairs(COMPONENTS) do
        count = count + self:GetTargetCount(player, component.collectible)
    end

    return count
end

function ConjoinedFormComponentsModule:AdoptCurrentInventory(includeDisabled)
    local applied = {}
    local game = Game()

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(playerIndex)
        local counts = {}

        for _, component in ipairs(COMPONENTS) do
            local count

            if includeDisabled then
                count = self:GetOwnedTargetCount(
                    player,
                    component.collectible
                )
            else
                count = self:GetTargetCount(
                    player,
                    component.collectible
                )
            end

            if count > 0 then
                counts[component.key] = count
            end
        end

        if next(counts) then
            applied[tostring(playerIndex)] = counts
        end
    end

    self.Applied = applied
end

function ConjoinedFormComponentsModule:FinishRestoredRunAdoption()
    -- The engine restored one synthetic counter step per real supplemental
    -- copy. Adopt those physical copies before reconciling so a disabled
    -- setting removes exactly the restored steps instead of either keeping or
    -- over-subtracting them.
    self:AdoptCurrentInventory(true)
    self:ReconcileAll()
    self.RewindHistory = {}
    self.LastRoomTimeCounter = self:GetTimeCounter()
    self:CaptureRewindSnapshot(self.LastRoomTimeCounter)
    self.AwaitingRewindRoom = false
    self.PendingRewind = nil
    self.Context:Save()
    Isaac.DebugString(
        "[Character Enhance][Conjoined] restored inventory adopted"
    )
end

function ConjoinedFormComponentsModule:RepairMissingHotReloadProgress()
    local game = Game()

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(playerIndex)

        if not player:HasPlayerForm(CONJOINED_FORM)
            and self:GetNativeComponentCount(player)
                + self:GetSupplementalComponentCount(player) >= 3
        then
            -- If all module-owned counts were still present, an inventory
            -- total of three would already have completed Conjoined. Clear
            -- only this player's bookkeeping so reconciliation restores the
            -- missing supplemental progress at the settled live frame.
            self.Applied[tostring(playerIndex)] = nil
            Isaac.DebugString(
                "[Character Enhance][Conjoined] repairing overwritten "
                .. "supplemental progress for player " .. playerIndex
            )
        end
    end
end

function ConjoinedFormComponentsModule:AddContribution(player)
    -- The standard API has no form-counter setter. A first-pickup copy of a
    -- harmless native Conjoined component adds one count; removing only that
    -- temporary copy while preserving form progress leaves inventory intact.
    player:AddCollectible(BROTHER_BOBBY, 0, true)
    player:RemoveCollectible(
        BROTHER_BOBBY,
        true,
        ActiveSlot.SLOT_PRIMARY,
        false
    )
end

function ConjoinedFormComponentsModule:RemoveContribution(player)
    -- Mirror the synthetic addition without replaying first-pickup behavior,
    -- then remove that one copy from the form counter.
    player:AddCollectible(BROTHER_BOBBY, 0, false)
    player:RemoveCollectible(
        BROTHER_BOBBY,
        true,
        ActiveSlot.SLOT_PRIMARY,
        true
    )
end

function ConjoinedFormComponentsModule:ReconcilePlayer(player, playerIndex)
    if not self.RunActive or playerIndex == nil then
        return false
    end

    local playerKey = tostring(playerIndex)
    local currentCounts = self.Applied[playerKey] or {}
    local nextCounts = {}
    local changed = false

    for _, component in ipairs(COMPONENTS) do
        local current = currentCounts[component.key] or 0
        local target = self:GetTargetCount(player, component.collectible)

        if target > 0 then
            nextCounts[component.key] = target
        end

        if current ~= target then
            changed = true

            if target > current then
                for _ = current + 1, target do
                    self:AddContribution(player)
                end
            else
                for _ = target + 1, current do
                    self:RemoveContribution(player)
                end
            end
        end
    end

    if not changed then
        return false
    end

    if next(nextCounts) then
        self.Applied[playerKey] = nextCounts
    else
        self.Applied[playerKey] = nil
    end

    return true
end

function ConjoinedFormComponentsModule:ReconcileAll()
    if not self.RunActive then
        return false
    end

    local changed = false
    local game = Game()

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(playerIndex)

        if self:ReconcilePlayer(player, playerIndex) then
            changed = true
        end
    end

    return changed
end

function ConjoinedFormComponentsModule:OnGameStarted(
    isContinued,
    isHotReload
)
    local hadLoadedRun = self.HasLoadedRun
    self.RunSeed = self:GetRunSeed()
    self.RunActive = true
    self.HasLoadedRun = true
    local startTimeCounter = self:GetTimeCounter()
    local persistedRewind = self:IsPersistedRewind(isContinued)
    local managedContinue = isContinued
        and self.PreservedData.runSeed == self.RunSeed

    if isHotReload then
        -- A Lua reload leaves the live native form counter intact, so adopt
        -- the module-owned counts that were saved before the reload.
        self:LoadApplied(isContinued)
        self:RepairMissingHotReloadProgress()
        self.RewindHistory = {}
        self.LastRoomTimeCounter = self:GetTimeCounter()
        self:CaptureRewindSnapshot(self.LastRoomTimeCounter)
        self.AwaitingRewindRoom = false
        self.PendingRewind = nil
    elseif (hadLoadedRun and isContinued) or persistedRewind then
        -- A same-process save/Continue and a rewind preserve the live native
        -- form counter even though run callbacks restart. Rewind can reload
        -- the Lua VM, so its pre-rollback marker distinguishes that internal
        -- Continue from an ordinary save-file load. Keep live history when
        -- available; otherwise adopt current real inventory.
        self.AwaitingRewindRoom = true
        self.PendingRewind = self:CopyPendingRewind(
            self.PreservedData.pendingRewind
        ) or self.PendingRewind

        if persistedRewind then
            Isaac.DebugString(
                "[Character Enhance][Conjoined] resuming recorded rewind "
                    .. tostring(self.PendingRewind.timeCounter)
                    .. " -> " .. tostring(self:GetTimeCounter())
            )
        end
    elseif managedContinue then
        -- Native run saves retain synthetic form progress across both
        -- same-process and fresh-process Continue. Reuse the matching module
        -- bookkeeping so ordinary continuation never grants it again. A
        -- same-process module already owns the current table; a fresh Lua VM
        -- loads the persisted table for this run seed.
        if not hadLoadedRun then
            self:LoadApplied(true)
        end

        self.RewindHistory = {}
        self.LastRoomTimeCounter = startTimeCounter
        self:CaptureRewindSnapshot(self.LastRoomTimeCounter)
        self.AwaitingRewindRoom = false
        self.PendingRewind = nil
    else
        -- New runs and first-install continues have no matching module
        -- bookkeeping. Reconcile current real components once after native
        -- player initialization has settled.
        self.Applied = {}
        self.RewindHistory = {}
        self.LastRoomTimeCounter = self:GetTimeCounter()
        self:CaptureRewindSnapshot(self.LastRoomTimeCounter)
        self.AwaitingRewindRoom = false
        self.PendingRewind = nil
    end

    -- MC_POST_GAME_STARTED runs before Repentance+ finishes rebuilding native
    -- transformation counters. A real start must wait for the first player
    -- effect update or the engine will overwrite the supplemental progress.
    local hotReloadChanged = isHotReload and self:ReconcileAll()

    if hotReloadChanged then
        self:CaptureRewindSnapshot(self:GetTimeCounter())
    end

    if hotReloadChanged or not isContinued then
        self.Context:Save()
    end
end

function ConjoinedFormComponentsModule:OnPlayerEffectUpdate(player)
    if not self.RunActive then
        return
    end

    if self.AwaitingRewindRoom then
        local pendingRewind = self.PendingRewind
        local timeCounter = self:GetTimeCounter()

        if pendingRewind == nil
            or timeCounter < pendingRewind.timeCounter
        then
            -- Repentance+ can dispatch MC_POST_NEW_ROOM before the continued
            -- MC_POST_GAME_STARTED callback. The first settled player-effect
            -- update is therefore also a valid restoration boundary.
            self:FinishRestoredRunAdoption()
            return
        end

        if timeCounter
            <= pendingRewind.timeCounter + REWIND_REQUEST_TIMEOUT
        then
            return
        end

        -- A failed/fizzled request must not freeze reconciliation or turn a
        -- later ordinary room transition into a rewind.
        self.AwaitingRewindRoom = false
        self.PendingRewind = nil
        self.Context:Save()
    end

    local playerIndex = self:GetPlayerIndex(player)

    if self:ReconcilePlayer(player, playerIndex) then
        self:CaptureRewindSnapshot(self:GetTimeCounter())
        self.Context:Save()
    end
end

function ConjoinedFormComponentsModule:OnNewRoom()
    if not self.RunActive then
        return
    end

    local timeCounter = self:GetTimeCounter()
    local requestedRewind = self.PendingRewind ~= nil
        and timeCounter < self.PendingRewind.timeCounter
    local isRewind = requestedRewind
        or (self.AwaitingRewindRoom and self.PendingRewind == nil)
        or (self.LastRoomTimeCounter ~= nil
            and timeCounter < self.LastRoomTimeCounter)

    if isRewind then
        local snapshot, historyIndex = self:FindRewindSnapshot(timeCounter)

        if snapshot then
            -- The engine restored the native transformation counter from this
            -- room snapshot. Restore the matching module bookkeeping before
            -- inventory reconciliation so no count is added or removed twice.
            self.Applied = self:CopyApplied(snapshot.applied)

            for index = #self.RewindHistory, historyIndex + 1, -1 do
                self.RewindHistory[index] = nil
            end
        else
            -- A hot reload can start the history later than the room restored
            -- by Rewind. The engine already rolled its form counter back, so
            -- adopt current real ownership without adding or removing counts.
            -- Clearing Applied here would make the next player update grant
            -- every supplemental copy again on each consecutive rewind.
            self:AdoptCurrentInventory(true)
        end

        Isaac.DebugString(
            "[Character Enhance][Conjoined] restored-run bookkeeping restored"
        )
    else
        self:CaptureRewindSnapshot(timeCounter)
    end

    self.LastRoomTimeCounter = timeCounter
    self.AwaitingRewindRoom = false
    self.PendingRewind = nil
    self.Context:Save()
end

function ConjoinedFormComponentsModule:OnSettingChanged()
    if self:ReconcileAll() then
        self:CaptureRewindSnapshot(self:GetTimeCounter())
        self.Context:Save()
    end
end

function ConjoinedFormComponentsModule:GetSaveData()
    if self.RunSeed == nil then
        return self.PreservedData
    end

    return {
        runSeed = self.RunSeed,
        applied = self.Applied,
        pendingRewind = self:CopyPendingRewind(self.PendingRewind),
    }
end

function ConjoinedFormComponentsModule:OnPreGameExit()
    self.RunActive = false
    self.RewindHistory = {}
    self.AwaitingRewindRoom = false
end

return ConjoinedFormComponentsModule
