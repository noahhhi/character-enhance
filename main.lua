local CharacterEnhance = RegisterMod("character-enhance", 1)

local VERSION = "1.9.6"
local DEFAULT_SETTINGS = {
    menuLanguage = "en",
    taintedLostWoodenCross = true,
    taintedBlueBabyDevilDeals = true,
    taintedBlueBabyPoopCapacity = true,
    bethanySoulCharge = true,
    bethanyDamageShield = true,
    bethanyShieldFeedback = true,
    bethanyShieldVisualStyle = 1,
    bethanyShieldSoundStyle = 1,
    bethanyShieldHitStyle = 1,
    bethanyGelloWispOrbit = true,
    familiarCapacity = true,
    clogGroundDamage = true,
    heldItemProtection = true,
    kidsDrawingFormFix = true,
    rerollHealthProtection = true,
    esauJrFirstPickup = true,
    rerollTmtrainerChance = 0,
}

local JSON = require("json")
local Config = include("scripts/config")
local settings, rawSaveData = Config.Load(
    CharacterEnhance,
    DEFAULT_SETTINGS,
    JSON
)

local Context = {
    Mod = CharacterEnhance,
    Version = VERSION,
    Defaults = DEFAULT_SETTINGS,
    Settings = settings,
    RawSaveData = rawSaveData,
    Modules = {},
    SettingHandlers = {},
}

local DamagePolicy = include("scripts/damage_policy")
Context.DamagePolicy = DamagePolicy.New()

function Context:IsEnabled(settingKey)
    return self.Settings[settingKey] ~= false
end

function Context:GetSavedModuleData(moduleKey)
    local modules = self.RawSaveData.modules

    if type(modules) == "table" and type(modules[moduleKey]) == "table" then
        return modules[moduleKey]
    end

    -- Version 1.4 stored the familiar bank at the root of the save table.
    if moduleKey == "familiarCapacity"
        and type(self.RawSaveData.temporaryFamiliarBank) == "table"
    then
        return {
            temporaryFamiliarBank = self.RawSaveData.temporaryFamiliarBank,
        }
    end

    return {}
end


function Context:RegisterModule(moduleKey, module)
    self.Modules[moduleKey] = module
    self.SettingHandlers[moduleKey] = module
end

function Context:RegisterSettingHandler(settingKey, module)
    self.SettingHandlers[settingKey] = module
end

function Context:BuildSaveData()
    local moduleData = {}

    for moduleKey, module in pairs(self.Modules) do
        if module.GetSaveData then
            moduleData[moduleKey] = module:GetSaveData()
        end
    end

    local savedSettings = {}

    for settingKey, defaultValue in pairs(self.Defaults) do
        local value = self.Settings[settingKey]

        if type(value) ~= type(defaultValue) then
            value = defaultValue
        end

        savedSettings[settingKey] = value
    end

    return {
        version = 2,
        settings = savedSettings,
        modules = moduleData,
    }
end

function Context:Save()
    self.Mod:SaveData(JSON.encode(self:BuildSaveData()))
end

function Context:SetSetting(settingKey, value)
    local defaultValue = self.Defaults[settingKey]

    if defaultValue == nil or type(value) ~= type(defaultValue) then
        return
    end

    if settingKey == "menuLanguage" and value ~= "zh" and value ~= "en" then
        return
    end

    if settingKey == "rerollTmtrainerChance" then
        if value ~= value or value == math.huge or value == -math.huge
            or value < 0 or value > 100
        then
            return
        end

        value = math.floor(value + 0.5)
    elseif settingKey == "bethanyShieldVisualStyle"
        or settingKey == "bethanyShieldSoundStyle"
    then
        if value ~= value or value == math.huge or value == -math.huge
            or value < 1 or value > 3
        then
            return
        end

        value = math.floor(value + 0.5)
    elseif settingKey == "bethanyShieldHitStyle" then
        if value ~= value or value == math.huge or value == -math.huge
            or value < 1 or value > 5
        then
            return
        end

        value = math.floor(value + 0.5)
    end

    if self.Settings[settingKey] == value then
        return
    end

    self.Settings[settingKey] = value

    local module = self.SettingHandlers[settingKey]

    if module and module.OnSettingChanged then
        module:OnSettingChanged(value, settingKey)
    end

    self:Save()
end

local TaintedLostModule = include("scripts/tainted_lost")
local TaintedBlueBabyDealsModule = include("scripts/tainted_bluebaby_deals")
local TaintedBlueBabyPoopCapacityModule = include(
    "scripts/tainted_bluebaby_poop_capacity"
)
local RerollHealthModule = include("scripts/reroll_health")
local BethanyChargeModule = include("scripts/bethany_charge")
local BethanyShieldModule = include("scripts/bethany_shield")
local BethanyShieldFeedbackModule = include(
    "scripts/bethany_shield_feedback"
)
local BethanyGelloWispsModule = include("scripts/bethany_gello_wisps")
local FamiliarCapacityModule = include("scripts/familiar_capacity")
local ClogGroundDamageModule = include("scripts/clog_ground_damage")
local HeldItemProtectionModule = include("scripts/held_item_protection")
local KidsDrawingFormModule = include("scripts/kids_drawing_form")
local ModConfigMenuModule = include("scripts/mod_config_menu")

local rerollHealthModule = RerollHealthModule.New(Context)
Context:RegisterModule("rerollHealthProtection", rerollHealthModule)
Context:RegisterSettingHandler("esauJrFirstPickup", rerollHealthModule)
Context:RegisterSettingHandler("rerollTmtrainerChance", rerollHealthModule)
Context:RegisterModule(
    "taintedLostWoodenCross",
    TaintedLostModule.New(Context)
)
Context:RegisterModule(
    "taintedBlueBabyDevilDeals",
    TaintedBlueBabyDealsModule.New(Context)
)
Context:RegisterModule(
    "taintedBlueBabyPoopCapacity",
    TaintedBlueBabyPoopCapacityModule.New(Context)
)
Context:RegisterModule(
    "bethanySoulCharge",
    BethanyChargeModule.New(Context)
)
local bethanyShieldFeedbackModule = BethanyShieldFeedbackModule.New(Context)
Context:RegisterModule(
    "bethanyShieldFeedback",
    bethanyShieldFeedbackModule
)
Context:RegisterSettingHandler(
    "bethanyShieldVisualStyle",
    bethanyShieldFeedbackModule
)
Context:RegisterSettingHandler(
    "bethanyShieldSoundStyle",
    bethanyShieldFeedbackModule
)
Context:RegisterSettingHandler(
    "bethanyShieldHitStyle",
    bethanyShieldFeedbackModule
)
Context:RegisterModule(
    "bethanyDamageShield",
    BethanyShieldModule.New(Context)
)
Context:RegisterModule(
    "bethanyGelloWispOrbit",
    BethanyGelloWispsModule.New(Context)
)
Context:RegisterModule(
    "familiarCapacity",
    FamiliarCapacityModule.New(Context)
)
Context:RegisterModule(
    "clogGroundDamage",
    ClogGroundDamageModule.New(Context)
)
Context:RegisterModule(
    "heldItemProtection",
    HeldItemProtectionModule.New(Context)
)
Context:RegisterModule(
    "kidsDrawingFormFix",
    KidsDrawingFormModule.New(Context)
)

ModConfigMenuModule.New(Context)

-- MC_POST_GAME_STARTED is not replayed when the debug console reloads a mod.
-- Re-establish run-local baselines without granting new-run-only rewards.
if Game():GetFrameCount() > 0 then
    for _, moduleKey in ipairs({
        "rerollHealthProtection",
        "taintedLostWoodenCross",
        "bethanySoulCharge",
        "familiarCapacity",
        "kidsDrawingFormFix",
    }) do
        local module = Context.Modules[moduleKey]

        if module and module.OnGameStarted then
            module:OnGameStarted(true)
        end
    end
end

local function SaveBeforeGameExit(_, shouldSave)
    for _, module in pairs(Context.Modules) do
        if module.OnPreGameExit then
            module:OnPreGameExit(shouldSave)
        end
    end

    if shouldSave then
        Context:Save()
    end
end

CharacterEnhance:AddCallback(
    ModCallbacks.MC_PRE_GAME_EXIT,
    SaveBeforeGameExit
)
