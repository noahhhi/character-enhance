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
        en = { "Soul Veil", "Particle Wall", "Frosted Soul" },
        zh = { "魂心薄幕", "粒子墙", "磨砂魂盾" },
    },
    sound = {
        en = { "Soul Glass", "Aether Veil", "Wraith Prism" },
        zh = { "魂晶冰盾", "以太灵幕", "幽魂棱晶" },
    },
    hit = {
        en = {
            "Stepped Flash",
            "Soft Pulse",
            "Echo Ring",
            "Crystal Burst",
            "Shadow Shock",
        },
        zh = {
            "阶梯闪光",
            "柔光脉冲",
            "回响光环",
            "水晶爆闪",
            "暗影震波",
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
            "选择菜单语言。",
            "左右切换，自动保存。",
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
            "Choose the menu language.",
            "Use left/right; saved automatically.",
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
            "里游魂新开局时自带木十字架。",
            "角色页会同步显示；已有饰品不会被移除。",
        },
        enInfo = {
            "Tainted Lost starts each run with Wooden Cross.",
            "Character page follows it; owned copies stay.",
        },
    },
    {
        key = "taintedBlueBabyDevilDeals",
        group = "taintedBlueBaby",
        zhName = "小蓝人交易价格",
        enName = "Blue Baby Deal Prices",
        zhInfo = {
            "里蓝人的恶魔交易改用小蓝人的价格。",
            "1或2个心之容器，改为消耗1或2颗魂心。",
        },
        enInfo = {
            "Tainted Blue Baby uses Blue Baby's deal prices.",
            "One/two containers cost one/two Soul Hearts.",
        },
    },
    {
        key = "taintedBlueBabyPoopCapacity",
        group = "taintedBlueBaby",
        zhName = "大便队列溢出修复",
        enName = "Poop Queue Overflow Fix",
        zhInfo = {
            "大便队列已满时，拾取物会留在地上。",
            "仍可推动；队列有空位后即可拾取。",
        },
        enInfo = {
            "Full queue: poop pickups stay on the ground.",
            "Pushable; collectible again when space opens.",
        },
    },
    {
        key = "rerollHealthProtection",
        group = "taintedEden",
        zhName = "Roll 全身道具后保留血量",
        enName = "Keep Health on Reroll",
        zhInfo = {
            "Roll 全身道具后，保留每位玩家的血量。",
            "覆盖里伊甸、D4/D100和骰子房。",
        },
        enInfo = {
            "Inventory rerolls keep each player's health.",
            "Covers Tainted Eden, reroll items, and Dice Rooms.",
        },
    },
    {
        key = "rerollAbsorbedStats",
        group = "taintedEden",
        zhName = "Roll 全身道具后保留吸收属性",
        enName = "Keep Absorbed Stats",
        zhInfo = {
            "Roll 全身道具后，保留虚空和黑符文属性。",
            "按玩家分别记录；不冻结道具本身的属性。",
        },
        enInfo = {
            "Rerolls keep stats gained from Void and Black Rune.",
            "Per player; item stats still reroll normally.",
        },
    },
    {
        key = "esauJrFirstPickup",
        group = "taintedEden",
        zhName = "小以扫拾取效果",
        enName = "Esau Jr. Pickup Effects",
        zhInfo = {
            "首次生成小以扫时，正常触发道具拾取效果。",
            "之后切换身体不会重复触发。",
        },
        enInfo = {
            "Runs pickup effects when Esau Jr. is first created.",
            "Later body swaps do not trigger them again.",
        },
    },
    {
        key = "bethanySoulCharge",
        group = "bethany",
        zhName = "双倍魂心充能",
        enName = "Double Soul Charges",
        zhInfo = {
            "伯大尼每颗魂心获得4点充能；半颗获得2点。",
            "达到99点后，魂心和黑心会留在地上。",
        },
        enInfo = {
            "Bethany gains 4 charges per Soul Heart; 2 per half.",
            "At 99, Soul and Black Hearts stay on the ground.",
        },
    },
    {
        key = "bethanyDamageShield",
        group = "bethany",
        zhName = "魂心充能护盾",
        enName = "Soul Charge Shield",
        zhInfo = {
            "消耗魂心充能，抵挡会降低交易房概率的伤害。",
            "献血、乞丐等自愿伤害仍正常生效。",
        },
        enInfo = {
            "Spends charges to block hits that lower deal chance.",
            "Voluntary damage still works and costs no charge.",
        },
    },
    {
        key = "bethanyShieldFeedback",
        group = "bethany",
        zhName = "护盾视听效果",
        enName = "Shield Effects",
        zhInfo = {
            "护罩外观和音效会随魂心充能增强。",
            "只影响视听；关闭后护盾功能仍然生效。",
        },
        enInfo = {
            "Shield visuals and sound grow with soul charge.",
            "Cosmetic only; Soul Charge Shield still works.",
        },
    },
    {
        key = "bethanyGelloWispOrbit",
        group = "bethany",
        zhName = "格罗魂火环绕修复",
        enName = "Gello Wisp Orbit Fix",
        zhInfo = {
            "格罗激活时，美德书魂火继续围绕玩家。",
            "只修正环绕中心，不改变魂火属性。",
        },
        enInfo = {
            "Virtues wisps orbit you while Gello is active.",
            "Only their orbit center changes.",
        },
    },
    {
        key = "familiarCapacity",
        group = "general",
        zhName = "跟班上限修复",
        enName = "Familiar Limit Fix",
        zhInfo = {
            "接近64个跟班上限时，暂存蓝苍蝇和蓝蜘蛛。",
            "有空位时自动补回；其他跟班不会被移除。",
        },
        enInfo = {
            "Banks extra flies/spiders before the 64 limit.",
            "Restores them later; other familiars stay safe.",
        },
    },
    {
        key = "smallPlayerPickupRange",
        group = "general",
        zhName = "小体型拾取范围修复",
        enName = "Small Player Pickup Range Fix",
        zhInfo = {
            "非战斗状态恢复默认拾取与接触范围。",
            "角色视觉体型保持不变，战斗中仍为小体型。",
        },
        enInfo = {
            "Non-combat: normal pickup/contact reach.",
            "Visual stays small; combat collision stays small.",
        },
    },
    {
        key = "clogGroundDamage",
        group = "general",
        zhName = "拦路屎水迹伤害修复",
        enName = "Clog Creep Damage Fix",
        zhInfo = {
            "玩家生成的伤害水迹可以伤害拦路屎。",
            "其他敌人和敌方水迹不受影响。",
        },
        enInfo = {
            "Player-made damaging creep can hurt The Clog.",
            "Other enemies and enemy creep are unchanged.",
        },
    },
    {
        key = "heldItemProtection",
        group = "general",
        zhName = "拾取动画修复",
        enName = "Pickup Animation Fix",
        zhInfo = {
            "使用R键或遗忘药前，先结算正在拾取的道具。",
            "避免道具在重置时消失。",
        },
        enInfo = {
            "R Key/Forget Me Now finish pending pickups first.",
            "Prevents the held item disappearing on reset.",
        },
    },
    {
        key = "kidsDrawingFormFix",
        group = "general",
        zhName = "儿童涂鸦套装修复",
        enName = "Kid's Drawing Form Fix",
        zhInfo = {
            "妈妈的盒子会让儿童涂鸦额外计1件。",
            "金色版本合计3件，可直接变身嗝屁猫。",
        },
        enInfo = {
            "Mom's Box adds one Guppy count to Kid's Drawing.",
            "Golden copies total three and trigger Guppy.",
        },
    },
    {
        key = "ocularRiftSoundFix",
        group = "general",
        zhName = "邪眼裂口音效修复",
        enName = "Ocular Rift Sound Fix",
        zhInfo = {
            "未发射泪弹时，阻止邪眼裂口误播音效。",
            "覆盖手指！等持续触发泪弹特效的道具。",
        },
        enInfo = {
            "Stops Ocular Rift sounds when no tear was fired.",
            "Covers Finger! and similar passive effect sources.",
        },
    },
    {
        key = "edenBlessingDuplicateFix",
        group = "general",
        zhName = "伊甸的祝福重复修复",
        enName = "Eden's Blessing Duplicate Fix",
        zhInfo = {
            "伊甸的祝福不会再复制伊甸的初始道具。",
            "重复奖励会改为另一件可用的被动道具。",
        },
        enInfo = {
            "Eden's Blessing won't copy Eden's starting item.",
            "Duplicates reroll into another available passive.",
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

            return "Roll 全身道具时错误技概率: " .. chance .. "%"
        end,
        OnChange = function(chance)
            self.Context:SetSetting(TMTRAINER_CHANCE_KEY, chance)
        end,
        Info = function()
            if self:GetLanguage() == "en" then
                return {
                    "TMTRAINER chance during an inventory reroll.",
                    "0% excludes it; 100% keeps vanilla odds.",
                }
            end

            return {
                "Roll 全身道具时，出现错误技的概率。",
                "0%完全排除；100%保持原版概率。",
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
                name = language == "en" and "Visual Style" or "护盾外观"
            elseif kind == "hit" then
                name = language == "en" and "Hit Effect" or "受击效果"
            else
                name = language == "en" and "Sound Style" or "护盾音效"
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
                        "Choose the shield's appearance.",
                        "Changing it previews the new style.",
                    }
                end

                if kind == "hit" then
                    return {
                        "Choose the shield's blocked-hit flash.",
                        "Changing it previews the effect.",
                    }
                end

                return {
                    "Choose the shield sound.",
                    "Changing it previews the 30-charge sound.",
                }
            end

            if kind == "visual" then
                return {
                    "选择护盾外观。",
                    "切换后立即预览。",
                }
            end

            if kind == "hit" then
                return {
                    "选择护盾抵挡伤害时的闪光效果。",
                    "切换后立即预览。",
                }
            end

            return {
                "选择护盾音效。",
                "切换后试听30充能时的音效。",
            }
        end,
    })
    self:RememberSubcategory(menu, "bethany")
end

function ModConfigMenuModule:AddShieldPreview(menu, kind, previewCharge)
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
                    return "Preview Shield: press right"
                end

                if kind == "hit" then
                    return "Preview Hit Effect: press right"
                end

                return "Preview Sound (" .. previewCharge .. "): press right"
            end

            if kind == "visual" then
                return "预览护盾: 按右键"
            end

            if kind == "hit" then
                return "预览受击效果: 按右键"
            end

            return "预览音效（" .. previewCharge .. "）: 按右键"
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
                feedback:PreviewSound(previewCharge)
            end
        end,
        Info = function()
            if self:GetLanguage() == "en" then
                if kind == "visual" then
                    return {
                        "Preview the idle shield without taking damage.",
                        "Requires Bethany and Shield Effects.",
                    }
                end

                if kind == "hit" then
                    return {
                        "Preview the hit effect without taking damage.",
                        "No sound, charge cost, hurt animation, or voice.",
                    }
                end

                return {
                    "Preview the sound at " .. previewCharge
                        .. " simulated charges.",
                    "No damage, charge cost, or hurt voice.",
                }
            end

            if kind == "visual" then
                return {
                    "无需受伤，预览护盾待机效果。",
                    "需要使用伯大尼并开启护盾视听效果。",
                }
            end

            if kind == "hit" then
                return {
                    "无需受伤，预览护盾受击效果。",
                    "不会播放音效、扣除充能或触发受伤表现。",
                }
            end

            return {
                "试听模拟" .. previewCharge .. "充能时的护盾音效。",
                "不会造成伤害、扣除充能或播放受伤语音。",
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
    self:AddShieldPreview(menu, "sound", 4)
    self:AddShieldPreview(menu, "sound", 30)
    self:AddShieldPreview(menu, "sound", 99)

    self:AddTmtrainerChance(menu)

    self:UpdateSubcategoryNames(menu)

    self.IsSetup = true
    return true
end

return ModConfigMenuModule
