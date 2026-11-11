-- Optional UI bridge. Gameplay remains independent of the native high-FPS mod.
local HighFpsControl = {}
HighFpsControl.__index = HighFpsControl
local KEYS = {
    highFpsAttackBudget = "attackBudget",
    highFpsPoofBudget = "poofBudget",
    highFpsAdaptiveBudget = "adaptiveBudget",
}

local function Read(bridge, key, value)
    local ok, result
    if value == nil then
        ok, result = pcall(bridge, key)
    else
        -- JSON may decode 0/1 as floats, but the native ABI uses lua_isinteger.
        -- Use literal integers without rounding invalid input into an enum.
        if value ~= -1 and value ~= 0 and value ~= 1 then
            return
        end
        local integer = value == -1 and -1 or value == 0 and 0 or 1
        ok, result = pcall(bridge, key, integer)
    end
    if ok and (result == 0 or result == 1) then
        return result
    end
end

function HighFpsControl.New(context)
    local self = setmetatable({
        Context = context, States = {}, Baselines = {}, Applied = {}, Ticks = 0,
    }, HighFpsControl)
    for key in pairs(KEYS) do
        context:RegisterSettingHandler(key, self)
    end
    context.Mod:AddCallback(ModCallbacks.MC_POST_RENDER, function()
        self.Ticks = self.Ticks + 1
        if self.Ticks >= 120 then
            self.Ticks = 0
            self:Refresh(false)
        end
    end)
    context.Mod:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, function()
        self:Refresh(true)
    end)
    self:Refresh(false)
    return self
end

function HighFpsControl:Refresh(force)
    local bridge = rawget(_G, "HIGH_FPS_CONTROL")
    if rawget(_G, "HIGH_FPS_CONTROL_VERSION") ~= 1 or type(bridge) ~= "function" then
        self.States = {}
        self.Applied = {}
        return
    end
    if self.Bridge ~= bridge then
        self.Bridge = bridge
        self.Baselines = {}
        self.Applied = {}
    end
    for setting, key in pairs(KEYS) do
        local current = Read(bridge, key)
        if current ~= nil then
            if self.Baselines[setting] == nil then
                -- Native startup values survive CE/VM reload and slot changes;
                -- the current value may already contain a prior CE override.
                self.Baselines[setting] = Read(bridge, key .. "Default")
            end
            local requested = self.Context.Settings[setting]
            local desired = (requested == 0 or requested == 1) and requested
                or self.Baselines[setting]
            -- Inherit uses the native reset command, not the aggregate default
            -- boolean: attack limits can start with two different INI flags.
            -- Reapplying an unchanged native tuple is an inexpensive no-op.
            if desired == nil then
                current = nil
            elseif force or self.Applied[setting] ~= requested then
                if requested == -1 then
                    current = Read(bridge, key, -1)
                else
                    current = Read(bridge, key, desired)
                end
                if current == desired then
                    self.Applied[setting] = requested
                end
            end
        end
        if current == nil then
            self.Applied[setting] = nil
        end
        self.States[setting] = current
    end
end

function HighFpsControl:GetState(setting)
    return self.States[setting]
end

function HighFpsControl:OnSettingChanged(_, setting)
    self.Applied[setting] = nil
    self:Refresh(false)
end

function HighFpsControl:OnSaveDataLoaded()
    self:Refresh(true)
end

return HighFpsControl
