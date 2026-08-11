local ConjoinedFormComponentsModule = {}
ConjoinedFormComponentsModule.__index = ConjoinedFormComponentsModule

local SETTING_KEY = "conjoinedFamiliarComponents"
local LITTLE_GISH = CollectibleType.COLLECTIBLE_LITTLE_GISH
local LIL_MONSTRO = CollectibleType.COLLECTIBLE_LIL_MONSTRO
local HUSHY = CollectibleType.COLLECTIBLE_HUSHY
local LIL_SPEWER = CollectibleType.COLLECTIBLE_LIL_SPEWER
local BROTHER_BOBBY = CollectibleType.COLLECTIBLE_BROTHER_BOBBY
local MAX_COMPONENT_COPIES = 99
local CONJOINED_FORM = PlayerForm.PLAYERFORM_BABY
local REWIND_HISTORY_LIMIT = 256

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
        RewindHistory = {},
        LastRoomTimeCounter = nil,
        AwaitingRewindRoom = false,
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
    if not self.Context:IsEnabled(SETTING_KEY) or player:IsDead() then
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

function ConjoinedFormComponentsModule:AdoptCurrentInventory()
    local applied = {}
    local game = Game()

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(playerIndex)
        local counts = {}

        for _, component in ipairs(COMPONENTS) do
            local count = self:GetTargetCount(player, component.collectible)

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
    local wasRunActive = self.RunActive
    self.RunSeed = self:GetRunSeed()
    self.RunActive = true

    if isHotReload then
        -- A Lua reload leaves the live native form counter intact, so adopt
        -- the module-owned counts that were saved before the reload.
        self:LoadApplied(isContinued)
        self:RepairMissingHotReloadProgress()
        self.RewindHistory = {}
        self.LastRoomTimeCounter = self:GetTimeCounter()
        self:CaptureRewindSnapshot(self.LastRoomTimeCounter)
        self.AwaitingRewindRoom = false
    elseif wasRunActive and isContinued then
        -- Rewind and Glowing Hourglass restore native player state without
        -- rolling Lua tables back. Keep the history until MC_POST_NEW_ROOM can
        -- adopt the bookkeeping snapshot that matches the restored room.
        self.AwaitingRewindRoom = true
    else
        -- A real new/continued game rebuilds native form progress from owned
        -- collectibles. Synthetic progress does not survive that rebuild, so
        -- persisted bookkeeping must never suppress reapplication (or remove
        -- nonexistent progress when the setting was disabled between runs).
        self.Applied = {}
        self.RewindHistory = {}
        self.LastRoomTimeCounter = self:GetTimeCounter()
        self:CaptureRewindSnapshot(self.LastRoomTimeCounter)
        self.AwaitingRewindRoom = false
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
        return
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
    local isRewind = self.AwaitingRewindRoom
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
            self:AdoptCurrentInventory()
        end

        Isaac.DebugString(
            "[Character Enhance][Conjoined] rewind bookkeeping restored"
        )
    else
        self:CaptureRewindSnapshot(timeCounter)
    end

    self.LastRoomTimeCounter = timeCounter
    self.AwaitingRewindRoom = false
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
    }
end

function ConjoinedFormComponentsModule:OnPreGameExit()
    self.RunActive = false
    self.RewindHistory = {}
    self.LastRoomTimeCounter = nil
    self.AwaitingRewindRoom = false
end

return ConjoinedFormComponentsModule
