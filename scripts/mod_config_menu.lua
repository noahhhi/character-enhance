local ModConfigMenuModule = {}
ModConfigMenuModule.__index = ModConfigMenuModule

local CATEGORY = "Character Enhance"
local LANGUAGE_SETTING_KEY = "menuLanguage"
local LANGUAGE_ZH = 1
local LANGUAGE_EN = 2
local SUBCATEGORY = {
    general = 1,
    taintedLost = 2,
    taintedBlueBaby = 3,
    taintedEden = 4,
    bethany = 5,
}
local SUBCATEGORY_ORDER = {
    "general",
    "taintedLost",
    "taintedBlueBaby",
    "taintedEden",
    "bethany",
}
local TMTRAINER_CHANCE_KEY = "rerollTmtrainerChance"

local TEXT = {
    zh = {
        language = "语言",
        chinese = "简体中文",
        enabled = "开启",
        disabled = "关闭",
        version = "版本",
        subcategories = {
            general = "通用",
            taintedLost = "里游魂",
            taintedBlueBaby = "里蓝人",
            taintedEden = "里伊甸",
            bethany = "伯大尼",
        },
        languageInfo = {
            "选择此 Mod 的菜单语言。",
            "左右切换，设置会自动保存。",
        },
    },
    en = {
        language = "Language",
        chinese = "Simplified Chinese",
        enabled = "ON",
        disabled = "OFF",
        version = "Version",
        subcategories = {
            general = "General",
            taintedLost = "T-Lost",
            taintedBlueBaby = "T-Blue Baby",
            taintedEden = "T-Eden",
            bethany = "Bethany",
        },
        languageInfo = {
            "Select the menu language for this mod.",
            "Use left/right; the choice is saved automatically.",
        },
    },
}

local MENU_SETTINGS = {
    {
        key = "taintedLostWoodenCross",
        group = "taintedLost",
        zhName = "初始木十字架",
        enName = "Starting Wooden Cross",
        zhInfo = {
            "堕化游魂新开局时携带木十字架。",
            "饰品编号：121。",
            "关闭后不会删除本局已获得的饰品。",
            "角色选择图片不会随开关变化。",
        },
        enInfo = {
            "Tainted Lost starts new runs with Wooden Cross.",
            "Trinket ID: 121.",
            "Turning this off does not remove an owned trinket.",
            "The character-select image is static.",
        },
    },
    {
        key = "taintedBlueBabyDevilDeals",
        group = "taintedBlueBaby",
        zhName = "等价魂心交易",
        enName = "Equivalent Soul Deals",
        zhInfo = {
            "里蓝人的恶魔交易采用小蓝人的等价魂心价格。",
            "1/2 个心之容器分别对应 1/2 颗魂心。",
            "联机时只对实际购买的里蓝人生效。",
        },
        enInfo = {
            "Tainted Blue Baby uses Blue Baby's equivalent Soul Heart prices.",
            "One/two containers cost one/two Soul Hearts respectively.",
            "In co-op, only the purchasing Tainted Blue Baby gets the price.",
        },
    },
    {
        key = "taintedBlueBabyPoopCapacity",
        group = "taintedBlueBaby",
        zhName = "大便满容量保护",
        enName = "Full Poop Protection",
        zhInfo = {
            "里蓝人的大便队列满容量时不会继续拾取大便。",
            "小型与大型大便都会留在地上以便之后使用。",
            "未满容量时保持原版拾取行为。",
            "与等价魂心交易开关相互独立。",
        },
        enInfo = {
            "Tainted Blue Baby leaves poop pickups when his queue is full.",
            "Both small and large pickups stay available for later.",
            "Below capacity, pickup behavior remains vanilla.",
            "Independent from the equivalent Soul Deal option.",
        },
    },
    {
        key = "rerollHealthProtection",
        group = "taintedEden",
        zhName = "重随血量保护",
        enName = "Reroll Health Protection",
        zhInfo = {
            "全身道具重随前后保持基础血量不变。",
            "覆盖里伊甸、D4/D100、D 无限、编号丢失和 1/6 点骰子房。",
            "里伊甸仍会正常承受触发重随的伤害。",
            "套装状态仍由当前道具和原版一次性记录决定。",
        },
        enInfo = {
            "Keeps base health unchanged by inventory rerolls.",
            "Covers T-Eden, D4/D100, D Infinity, Missing No. and Dice 1/6.",
            "Tainted Eden still takes the hit that caused the reroll.",
            "Forms still follow current items and vanilla one-time records.",
        },
    },
    {
        key = "esauJrFirstPickup",
        group = "taintedEden",
        zhName = "小以扫首次拾取登记",
        enName = "Esau Jr. First Pickup",
        zhInfo = {
            "首次生成小以扫时登记身上道具的拾取效果与套装进度。",
            "实验性疗法、妈妈的零钱包和弹珠袋等只触发一次。",
            "之后切换身体不会重复触发。",
            "与同栏的重随血量保护相互独立。",
        },
        enInfo = {
            "Registers pickup effects/forms when Esau Jr. is first generated.",
            "Experimental Treatment, Mom's Coin Purse and Marbles run once.",
            "Later body swaps never replay them.",
            "Independent from the reroll-health option in this tab.",
        },
    },
    {
        key = "bethanySoulCharge",
        group = "bethany",
        zhName = "魂心充能增强",
        enName = "Soul Charge Bonus",
        zhInfo = {
            "伯大尼一整颗魂心获得 4 点充能。",
            "半颗魂心获得 2 点充能。",
            "充能达到 99 时不会拾取魂心或黑心。",
            "不控制充能伤害护盾。",
        },
        enInfo = {
            "Bethany gains 4 charge per full Soul Heart.",
            "A half Soul Heart grants 2 charge.",
            "Soul and Black Hearts stay uncollected at 99 charge.",
            "This does not control the charge damage shield.",
        },
    },
    {
        key = "bethanyDamageShield",
        group = "bethany",
        zhName = "充能伤害护盾",
        enName = "Charge Damage Shield",
        zhInfo = {
            "惩罚性伤害优先消耗魂心充能。",
            "该次伤害不会扣除红心或交易房概率。",
            "乞丐、赌命和献血等自愿伤害不消耗充能。",
            "不控制魂心充能增强。",
        },
        enInfo = {
            "Penalty damage spends Soul Charge first.",
            "The hit does not remove red health or deal chance.",
            "Beggar, Hell Game and blood payments spend no charge.",
            "This does not control the Soul Charge bonus.",
        },
    },
    {
        key = "familiarCapacity",
        group = "general",
        zhName = "跟班容量保护",
        enName = "Familiar Capacity",
        zhInfo = {
            "溢出的蓝苍蝇和蓝蜘蛛存入缓冲池。",
            "为其他重要跟班保留真实位置。",
            "关闭时暂停处理，但不会清空缓冲池。",
        },
        enInfo = {
            "Banks overflow Blue Flies and Blue Spiders.",
            "Reserves real slots for important familiars.",
            "Turning it off pauses processing without data loss.",
        },
    },
}

function ModConfigMenuModule.New(context)
    local self = setmetatable({
        Context = context,
        IsSetup = false,
        CreatedGroups = {},
        SubcategoryIds = {},
    }, ModConfigMenuModule)

    self:TrySetup()

    context.Mod:AddCallback(
        ModCallbacks.MC_POST_RENDER,
        function()
            if not self.IsSetup then
                self:TrySetup()
            end
        end
    )

    return self
end

function ModConfigMenuModule:GetLanguage()
    return self.Context.Settings[LANGUAGE_SETTING_KEY] == "en" and "en" or "zh"
end

function ModConfigMenuModule:GetText()
    return TEXT[self:GetLanguage()]
end

function ModConfigMenuModule:GetMenuApi()
    if type(MCM) == "table" and type(MCM.AddSetting) == "function" then
        return MCM
    end

    if type(ModConfigMenu) == "table"
        and type(ModConfigMenu.AddSetting) == "function"
    then
        return ModConfigMenu
    end

    return nil
end

function ModConfigMenuModule:GetSubcategory(menu, group)
    return self:GetText().subcategories[group]
end

function ModConfigMenuModule:UpdateSubcategoryNames(menu)
    local names = self:GetText().subcategories

    for _, group in ipairs(SUBCATEGORY_ORDER) do
        if self.CreatedGroups[group] then
            local subcategoryId = self.SubcategoryIds[group]
                or SUBCATEGORY[group]

            if type(menu.UpdateSubcategory) == "function" then
                menu.UpdateSubcategory(CATEGORY, subcategoryId, {
                    Name = names[group],
                    -- Localized MCM builds render NameTranslate before Name.
                    -- Setting both also keeps the Impure API compatible.
                    NameTranslate = names[group],
                })
            end

            -- Impure ignores NameTranslate while localized forks prioritize it.
            -- Update the live menu table as well so both renderers change tabs
            -- immediately, including while this category is already open.
            if menu.MenuData and menu.GetCategoryIDByName then
                local categoryId = menu.GetCategoryIDByName(CATEGORY)
                local category = categoryId and menu.MenuData[categoryId]
                local subcategory = category and category.Subcategories
                    and category.Subcategories[subcategoryId]

                if subcategory then
                    subcategory.Name = names[group]
                    subcategory.NameTranslate = names[group]
                end
            end
        end
    end
end

function ModConfigMenuModule:RememberSubcategory(menu, group)
    if not menu.GetSubcategoryIDByName then
        return
    end

    local name = self:GetSubcategory(menu, group)
    local subcategoryId = menu.GetSubcategoryIDByName(CATEGORY, name)

    if type(subcategoryId) == "number" then
        self.SubcategoryIds[group] = subcategoryId
    end
end

function ModConfigMenuModule:AddLanguageSetting(menu)
    self.CreatedGroups.general = true
    menu.AddSetting(CATEGORY, self:GetSubcategory(menu, "general"), {
        Type = menu.OptionType.NUMBER,
        Minimum = LANGUAGE_ZH,
        Maximum = LANGUAGE_EN,
        ModifyBy = 1,
        Default = LANGUAGE_EN,
        CurrentSetting = function()
            return self:GetLanguage() == "en" and LANGUAGE_EN or LANGUAGE_ZH
        end,
        Display = function()
            local language = self:GetLanguage()
            local text = TEXT[language]
            local value = language == "en" and "English" or text.chinese
            return text.language .. ": " .. value
        end,
        OnChange = function(languageIndex)
            local language = languageIndex == LANGUAGE_EN and "en" or "zh"
            self.Context:SetSetting(LANGUAGE_SETTING_KEY, language)
            self:UpdateSubcategoryNames(menu)
        end,
        Info = function()
            return self:GetText().languageInfo
        end,
    })
    self:RememberSubcategory(menu, "general")
end

function ModConfigMenuModule:AddBoolean(menu, setting)
    self.CreatedGroups[setting.group] = true
    menu.AddSetting(CATEGORY, self:GetSubcategory(menu, setting.group), {
        Type = menu.OptionType.BOOLEAN,
        Default = true,
        CurrentSetting = function()
            return self.Context:IsEnabled(setting.key)
        end,
        Display = function()
            local language = self:GetLanguage()
            local text = TEXT[language]
            local name = language == "en" and setting.enName or setting.zhName
            local state = self.Context:IsEnabled(setting.key)
                and text.enabled
                or text.disabled
            return name .. ": " .. state
        end,
        OnChange = function(enabled)
            self.Context:SetSetting(setting.key, enabled)
        end,
        Info = function()
            return self:GetLanguage() == "en" and setting.enInfo or setting.zhInfo
        end,
    })
    self:RememberSubcategory(menu, setting.group)
end

function ModConfigMenuModule:AddTmtrainerChance(menu)
    self.CreatedGroups.taintedEden = true
    menu.AddSetting(CATEGORY, self:GetSubcategory(menu, "taintedEden"), {
        Type = menu.OptionType.NUMBER,
        Minimum = 0,
        Maximum = 100,
        ModifyBy = 1,
        Default = 0,
        CurrentSetting = function()
            return self.Context.Settings[TMTRAINER_CHANCE_KEY] or 0
        end,
        Display = function()
            local chance = self.Context.Settings[TMTRAINER_CHANCE_KEY] or 0

            if self:GetLanguage() == "en" then
                return "TMTRAINER Reroll Chance: " .. chance .. "%"
            end

            return "错误技重随概率: " .. chance .. "%"
        end,
        OnChange = function(chance)
            self.Context:SetSetting(TMTRAINER_CHANCE_KEY, chance)
        end,
        Info = function()
            if self:GetLanguage() == "en" then
                return {
                    "Chance to include TMTRAINER in each full-reroll pool.",
                    "0% always redraws it; 100% is vanilla behavior.",
                    "Covers D4/D100, D Infinity, T-Eden, Dice 1/6 and ? Card.",
                    "Normal pickup and already-owned TMTRAINER are unaffected.",
                    "Independent from the other two options in this tab.",
                }
            end

            return {
                "每次全身重随将错误技加入隐藏房道具池的概率。",
                "0% 时总会重抽；100% 为无 Mod 原版状态。",
                "覆盖 D4/D100、D 无限、里伊甸、编号丢失、1/6 点骰子房和命运之轮？。",
                "正常拾取及重随前已持有错误技时不受影响。",
                "与同栏其他两个选项相互独立。",
            }
        end,
    })
    self:RememberSubcategory(menu, "taintedEden")
end

function ModConfigMenuModule:TrySetup()
    local menu = self:GetMenuApi()

    if not menu or not menu.OptionType
        or not menu.OptionType.BOOLEAN
        or not menu.OptionType.NUMBER
    then
        return false
    end

    if menu.GetCategoryIDByName
        and menu.GetCategoryIDByName(CATEGORY) ~= nil
        and menu.RemoveCategory
    then
        menu.RemoveCategory(CATEGORY)
    end

    if menu.AddText then
        menu.AddText(
            CATEGORY,
            self:GetSubcategory(menu, "general"),
            function()
                local text = self:GetText()
                return text.version .. " " .. self.Context.Version
            end
        )
    end

    if menu.AddSpace then
        menu.AddSpace(CATEGORY, self:GetSubcategory(menu, "general"))
    end

    self:AddLanguageSetting(menu)

    if menu.AddSpace then
        menu.AddSpace(CATEGORY, self:GetSubcategory(menu, "general"))
    end

    for _, setting in ipairs(MENU_SETTINGS) do
        self:AddBoolean(menu, setting)
    end

    self:AddTmtrainerChance(menu)

    self:UpdateSubcategoryNames(menu)

    self.IsSetup = true
    return true
end

return ModConfigMenuModule
