local AttackResourcePreloadModule = {}
AttackResourcePreloadModule.__index = AttackResourcePreloadModule

local SETTING_KEY = "attackResourcePreload"
local MAX_PLAYERS = 16
local ITEMS = {
    "COLLECTIBLE_MARKED", "COLLECTIBLE_TECHNOLOGY_ZERO", "COLLECTIBLE_TRISAGION",
    "COLLECTIBLE_PARASITE", "COLLECTIBLE_CRICKETS_BODY", "COLLECTIBLE_COMPOUND_FRACTURE",
    "COLLECTIBLE_LACHRYPHAGY", "COLLECTIBLE_HAEMOLACRIA",
}
local RESOURCES = {
    "gfx/002.000_Tear.anm2",
    "gfx/002.001_Blood Tear.anm2",
    "gfx/007.003_Shoop Laser.anm2",
    "gfx/007.010_Electric Laser.anm2",
    "gfx/1000.011_Bullet Poof.anm2",
    "gfx/1000.012_Tear PoofA.anm2",
    "gfx/1000.013_Tear PoofB.anm2",
    "gfx/1000.030_Dr. Fetus Target.anm2",
    "gfx/1000.050_ShoopImpact.anm2",
    "gfx/1000.012_Tear Poof_Small.anm2",
}

function AttackResourcePreloadModule.New(context)
    local self = setmetatable({ Context = context, Sprites = {} }, AttackResourcePreloadModule)
    context.Mod:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, function(_, continued)
        self:OnGameStarted(continued, false)
    end)
    context.Mod:AddCallback(ModCallbacks.MC_PRE_MOD_UNLOAD, function()
        self:Clear()
    end)
    return self
end

function AttackResourcePreloadModule:Clear()
    -- Drop only our Lua references; do not unload engine/global sprite resources.
    self.Sprites = {}
end

function AttackResourcePreloadModule:HasRelatedItem()
    local count = Game():GetNumPlayers()
    if type(count) ~= "number" or count % 1 ~= 0 or count < 1 or count > MAX_PLAYERS then
        return false
    end
    for index = 0, count - 1 do
        local player = Isaac.GetPlayer(index)
        if player then
            for _, name in ipairs(ITEMS) do
                local id = CollectibleType[name]
                if type(id) == "number" and player:HasCollectible(id) then
                    return true
                end
            end
        end
    end
    return false
end

function AttackResourcePreloadModule:OnGameStarted(_, adopting)
    -- main.lua's console-reload adoption is NOT a native new/continued run.
    -- Enabling or reloading in a live room must never move loading into combat.
    if adopting then return end
    self:Clear()
    if not self.Context:IsEnabled(SETTING_KEY) then return end
    local inspected, related = pcall(function() return self:HasRelatedItem() end)
    if not inspected then
        Isaac.DebugString("[Character Enhance] Attack resource preload: player inspection failed; skipped")
        return
    end
    if not related then return end

    local failed = 0
    for _, path in ipairs(RESOURCES) do
        local ok, sprite = pcall(function()
            local resource = Sprite()
            resource:Load(path, true)
            return resource
        end)
        if ok then
            self.Sprites[#self.Sprites + 1] = sprite
        else
            failed = failed + 1
            Isaac.DebugString("[Character Enhance] Attack resource preload failed: " .. path)
        end
    end
    -- One bounded run-start summary. Load returning without a Lua exception is
    -- not a promise about another mod's replacement assets or GPU residency.
    Isaac.DebugString("[Character Enhance] Attack resource preload: attempted=" .. #RESOURCES
        .. " retained=" .. #self.Sprites .. " failed=" .. failed)
end

function AttackResourcePreloadModule:OnSettingChanged(enabled)
    if not enabled then self:Clear() end
    -- Enable takes effect at the next actual MC_POST_GAME_STARTED, never here.
end

function AttackResourcePreloadModule:OnSaveDataLoaded()
    self:Clear()
end

function AttackResourcePreloadModule:OnPreGameExit()
    self:Clear()
end

return AttackResourcePreloadModule
