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
local SHIELD_VISUAL_STYLE_KEY = "bethanyShieldVisualStyle"
local SHIELD_SOUND_STYLE_KEY = "bethanyShieldSoundStyle"
local SHIELD_HIT_STYLE_KEY = "bethanyShieldHitStyle"
local SHIELD_STYLES = {
    visual = {
        en = { "Soul Veil", "Shadow Sigil", "Crystal Heart" },
        zh = { "魂心薄幕", "影之书符印", "晶蓝魂心" },
    },
    sound = {
        en = { "Soul Ice", "Book of Shadows", "Holy Mantle" },
        zh = { "魂心冰层", "影之书", "神圣屏障" },
    },
    hit = {
        en = {
            "Bright Step",
            "Soft Pulse",
            "Echo Ring",
            "Crystal Burst",
            "Shadow Shock",
        },
        zh = {
            "亮度阶降",
            "柔和脉冲",
            "扩散回响",
            "冰晶爆闪",
            "暗影震荡",
        },
    },
}

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
            "角色选择页的图标与文字会同步显示或隐藏。",
            "返回角色选择页后生效；若页面已缓存，请重启游戏。",
        },
        enInfo = {
            "Tainted Lost starts new runs with Wooden Cross.",
            "Trinket ID: 121.",
            "Turning this off does not remove an owned trinket.",
            "The character-select icon and label follow this setting.",
            "Reopen character select; restart only if the page was cached.",
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
            "保留碰撞，但不会收进队列或消耗拾取物。",
            "小型与大型大便都会留在地上以便之后使用。",
            "未满容量时保持原版拾取行为。",
            "与等价魂心交易开关相互独立。",
        },
        enInfo = {
            "Tainted Blue Baby leaves poop pickups when his queue is full.",
            "Collision remains active without collecting the pickup.",
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
            "破损的口袋掉落半魂心时扣 2 点充能。",
            "充能达到 99 时不会拾取魂心或黑心。",
            "不控制充能伤害护盾。",
        },
        enInfo = {
            "Bethany gains 4 charge per full Soul Heart.",
            "A half Soul Heart grants 2 charge.",
            "Torn Pocket half Soul drops cost 2 charge.",
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
            "吸收后保留正常受伤保护时间。",
            "乞丐、赌命和献血等自愿伤害不消耗充能。",
            "不控制魂心充能增强。",
        },
        enInfo = {
            "Penalty damage spends Soul Charge first.",
            "The hit does not remove red health or deal chance.",
            "Absorbed hits keep normal damage invulnerability.",
            "Beggar, Hell Game and blood payments spend no charge.",
            "This does not control the Soul Charge bonus.",
        },
    },
    {
        key = "bethanyShieldFeedback",
        group = "bethany",
        zhName = "护盾反馈",
        enName = "Shield Feedback",
        zhInfo = {
            "每一点充能都会细微改变护罩与冰盾声。",
            "透明护罩包围全身，不是前方半球。",
            "移动和时间会使护罩渐隐渐现。",
            "受击时先明显增亮，再减弱为余辉。",
            "格挡时只播放冰盾声，不触发角色受伤表现。",
            "角色保持动作，并在受伤保护期间原地闪烁。",
            "关闭时护罩伴随轻微冰裂声渐隐消失。",
            "关闭后不影响充能伤害护盾本身。",
        },
        enInfo = {
            "Every charge point subtly changes the shield and sound.",
            "The translucent shield surrounds the full body.",
            "Movement and time make the shield gently fade and pulse.",
            "Hits flash brightly, then fall back to an afterglow.",
            "Blocks play only the shield sound, with no hurt response.",
            "Bethany keeps her pose and flashes during the cooldown.",
            "Turning it off fades the shield with a soft ice crack.",
            "Turning this off does not disable the damage shield itself.",
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
    {
        key = "clogGroundDamage",
        group = "general",
        zhName = "拦路屎地面伤害",
        enName = "Clog Ground Damage",
        zhInfo = {
            "让拦路屎（914.0.0）受到地面伤害。",
            "补偿原版内部飞行判定跳过的玩家水迹伤害。",
            "伤害、范围与频率沿用当前水迹的原版数值。",
            "只影响拦路屎，不改变其他敌人的判定。",
        },
        enInfo = {
            "Lets The Clog (914.0.0) take ground damage.",
            "Restores player-creep hits skipped by its internal flight state.",
            "Damage, radius and tick rate use the current creep's values.",
            "Only The Clog is affected; other enemies remain vanilla.",
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

    self.SetupRetryCallback = function()
        if self:TrySetup() then
            self.Context.Mod:RemoveCallback(
                ModCallbacks.MC_POST_RENDER,
                self.SetupRetryCallback
            )
        end
    end

    if not self:TrySetup() then
        context.Mod:AddCallback(
            ModCallbacks.MC_POST_RENDER,
            self.SetupRetryCallback
        )
    end

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

function ModConfigMenuModule:AddShieldStyle(menu, kind)
    self.CreatedGroups.bethany = true
    local settingKey = kind == "visual" and SHIELD_VISUAL_STYLE_KEY
        or kind == "sound" and SHIELD_SOUND_STYLE_KEY
        or SHIELD_HIT_STYLE_KEY
    local labels = SHIELD_STYLES[kind]
    local maximum = kind == "hit" and 5 or 3

    menu.AddSetting(CATEGORY, self:GetSubcategory(menu, "bethany"), {
        Type = menu.OptionType.NUMBER,
        Minimum = 1,
        Maximum = maximum,
        ModifyBy = 1,
        Default = 1,
        CurrentSetting = function()
            return self.Context.Settings[settingKey] or 1
        end,
        Display = function()
            local language = self:GetLanguage()
            local style = self.Context.Settings[settingKey] or 1
            local name

            if kind == "visual" then
                name = language == "en" and "Animation" or "动画"
            elseif kind == "hit" then
                name = language == "en" and "Hit FX" or "受击效果"
            else
                name = language == "en" and "Sound" or "音效"
            end

            return name .. ": " .. labels[language][style]
        end,
        OnChange = function(style)
            self.Context:SetSetting(settingKey, style)
            local feedback = self.Context.Modules
                and self.Context.Modules.bethanyShieldFeedback

            if not feedback then
                return
            end

            if kind == "visual" and feedback.PreviewAnimation then
                feedback:PreviewAnimation()
            elseif kind == "hit" and feedback.PreviewHit then
                feedback:PreviewHit()
            elseif kind == "sound" and feedback.PreviewSound then
                feedback:PreviewSound()
            end
        end,
        Info = function()
            if self:GetLanguage() == "en" then
                if kind == "visual" then
                    return {
                        "Choose one of three live shield animations.",
                        "Changing it immediately previews the selected style.",
                    }
                end

                if kind == "hit" then
                    return {
                        "Choose one of five absorbed-hit animations.",
                        "Each flashes brightly, then drops to an afterglow.",
                    }
                end

                return {
                    "Choose Soul Ice, Book of Shadows, or Holy Mantle sound.",
                    "Changing it immediately plays a safe preview.",
                }
            end

            if kind == "visual" then
                return {
                    "选择三种实时护盾动画之一。",
                    "切换后会立即预览所选样式。",
                }
            end

            if kind == "hit" then
                return {
                    "选择五种魂心护盾受击动画之一。",
                    "每种都会先明显增亮，再降为余辉。",
                }
            end

            return {
                "选择魂心冰层、影之书或神圣屏障音效。",
                "切换后会立即安全试听。",
            }
        end,
    })
    self:RememberSubcategory(menu, "bethany")
end

function ModConfigMenuModule:AddShieldPreview(menu, kind)
    self.CreatedGroups.bethany = true

    menu.AddSetting(CATEGORY, self:GetSubcategory(menu, "bethany"), {
        Type = menu.OptionType.NUMBER,
        Minimum = 0,
        Maximum = 1,
        ModifyBy = 1,
        Default = 0,
        CurrentSetting = function()
            return 0
        end,
        Display = function()
            if self:GetLanguage() == "en" then
                if kind == "visual" then
                    return "Test Idle: Press right"
                end

                return kind == "hit"
                    and "Test Hit FX: Press right"
                    or "Test Sound: Press right"
            end

            if kind == "visual" then
                return "测试待机: 按右键"
            end

            return kind == "hit"
                and "测试受击: 按右键"
                or "测试音效: 按右键"
        end,
        OnChange = function(value)
            if value <= 0 then
                return
            end

            local feedback = self.Context.Modules
                and self.Context.Modules.bethanyShieldFeedback

            if kind == "visual" and feedback
                and feedback.PreviewAnimation
            then
                feedback:PreviewAnimation()
            elseif kind == "hit" and feedback
                and feedback.PreviewHit
            then
                feedback:PreviewHit()
            elseif kind == "sound" and feedback
                and feedback.PreviewSound
            then
                feedback:PreviewSound()
            end
        end,
        Info = function()
            if self:GetLanguage() == "en" then
                if kind == "visual" then
                    return {
                        "Replays the idle shield without taking damage.",
                        "Requires Bethany and Shield Feedback to be enabled.",
                    }
                end

                if kind == "hit" then
                    return {
                        "Replays the selected hit flash without taking damage.",
                        "No sound, charge cost, hurt voice, or hit animation.",
                    }
                end

                return {
                    "Replays the selected shield impact without taking damage.",
                    "No hurt voice, damage, or charge is produced.",
                }
            end

            if kind == "visual" then
                return {
                    "无需受伤即可重播当前护盾待机动画。",
                    "需要使用伯大尼并开启护盾反馈。",
                }
            end

            if kind == "hit" then
                return {
                    "无需受伤即可重播所选受击闪光。",
                    "不会播放音效、扣充能、语音或受击动画。",
                }
            end

            return {
                "无需受伤即可重播所选护盾受击声。",
                "不会产生语音、伤害或消耗充能。",
            }
        end,
    })
    self:RememberSubcategory(menu, "bethany")
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

    self:AddShieldStyle(menu, "visual")
    self:AddShieldStyle(menu, "hit")
    self:AddShieldStyle(menu, "sound")
    self:AddShieldPreview(menu, "visual")
    self:AddShieldPreview(menu, "hit")
    self:AddShieldPreview(menu, "sound")

    self:AddTmtrainerChance(menu)

    self:UpdateSubcategoryNames(menu)

    self.IsSetup = true
    return true
end

return ModConfigMenuModule
