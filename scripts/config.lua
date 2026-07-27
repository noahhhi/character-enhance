local Config = {}
local NUMBER_RANGES = {
    bethanyShieldVisualStyle = { minimum = 1, maximum = 3 },
    bethanyShieldSoundStyle = { minimum = 1, maximum = 3 },
    rerollTmtrainerChance = { minimum = 0, maximum = 100 },
}

local function CopyDefaults(defaults)
    local result = {}

    for key, value in pairs(defaults) do
        result[key] = value
    end

    return result
end

function Config.Load(mod, defaults, jsonCodec)
    local settings = CopyDefaults(defaults)
    local rawSaveData = {}

    if mod:HasData() then
        local decoded, savedData = pcall(jsonCodec.decode, mod:LoadData())

        if decoded and type(savedData) == "table" then
            rawSaveData = savedData
        end
    end

    if type(rawSaveData.settings) == "table" then
        for settingKey, defaultValue in pairs(defaults) do
            local savedValue = rawSaveData.settings[settingKey]

            if type(savedValue) == type(defaultValue) then
                settings[settingKey] = savedValue
            else
                settings[settingKey] = defaultValue
            end
        end
    end

    if settings.menuLanguage ~= "zh" and settings.menuLanguage ~= "en" then
        settings.menuLanguage = defaults.menuLanguage
    end

    for settingKey, range in pairs(NUMBER_RANGES) do
        local value = settings[settingKey]

        if type(value) ~= "number" or value ~= value
            or value == math.huge or value == -math.huge
            or value < range.minimum or value > range.maximum
        then
            settings[settingKey] = defaults[settingKey]
        else
            settings[settingKey] = math.floor(value + 0.5)
        end
    end

    return settings, rawSaveData
end

return Config
