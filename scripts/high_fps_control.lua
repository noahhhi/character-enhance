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
    self:RefreshRenderer()
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

-- Restart-only renderer controls have separate ABI and native persistence.
-- Never replay a per-slot preference or turn a refresh into a disk write.
local function RendererMode(value, inherit)
    if inherit and value == -1 then return -1 end
    if value == 0 then return 0 end
    if value == 80 then return 80 end
    if value == 90 then return 90 end
end

function HighFpsControl:RefreshRenderer()
    self.Renderer = nil
    local bridge = rawget(_G, "HIGH_FPS_RENDERER")
    if rawget(_G, "HIGH_FPS_RENDERER_VERSION") ~= 1 or type(bridge) ~= "function" then
        return
    end
    local state = {}
    for _, key in ipairs({ "override", "base", "startup", "next", "restartRequired", "state" }) do
        local ok, value = pcall(bridge, key)
        if not ok then return end
        if key == "restartRequired" then
            if value ~= 0 and value ~= 1 then return end
        elseif key == "state" then
            if value ~= 0 and value ~= 1 and value ~= 2 and value ~= 3 then return end
        else
            value = RendererMode(value, key == "override")
            if value == nil then return end
        end
        state[key] = value
    end
    local nextMode = state.override == -1 and state.base or state.override
    if state.next ~= nextMode
        or state.restartRequired ~= (state.next ~= state.startup and 1 or 0)
    then
        return
    end
    self.Renderer = state
end

function HighFpsControl:GetRendererState()
    return self.Renderer
end

function HighFpsControl:SetRendererOverride(value)
    local integer = RendererMode(value, true)
    if integer == nil then return false end
    self:RefreshRenderer()
    if not self.Renderer then return false end
    local ok, accepted = pcall(rawget(_G, "HIGH_FPS_RENDERER"), "override", integer)
    self:RefreshRenderer()
    local saved = ok and accepted == integer and self.Renderer
        and self.Renderer.override == integer
    self.RendererSaveFailed = not saved
    return not not saved
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
