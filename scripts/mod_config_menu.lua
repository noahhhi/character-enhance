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
            "里游魂每次新开局会自带木十字架。",
            "饰品编号：121。",
            "关闭后不会移除已经获得的木十字架。",
            "角色选择页的图标和文字也会跟随此选项。",
            "重新进入角色选择页即可刷新；若仍未变化，请重启游戏。",
        },
        enInfo = {
            "Tainted Lost starts each new run with Wooden Cross.",
            "Trinket ID: 121.",
            "Turning this off will not remove one you already have.",
            "The character-select icon and label follow this option.",
            "Reopen character select to refresh them.",
            "Restart the game if the page stays cached.",
        },
    },
    {
        key = "taintedBlueBabyDevilDeals",
        group = "taintedBlueBaby",
        zhName = "小蓝人交易价格",
        enName = "Blue Baby Deal Prices",
        zhInfo = {
            "里蓝人的恶魔交易改用小蓝人的价格。",
            "原价为 1 或 2 个心之容器的道具，分别消耗 1 或 2 颗魂心。",
            "联机时只影响实际购买道具的里蓝人。",
        },
        enInfo = {
            "Tainted Blue Baby pays the same Devil Deal prices as Blue Baby.",
            "Items worth one or two Red Heart containers cost one or two Soul Hearts.",
            "In co-op, only the purchasing Tainted Blue Baby gets this price.",
        },
    },
    {
        key = "taintedBlueBabyPoopCapacity",
        group = "taintedBlueBaby",
        zhName = "大便队列溢出修复",
        enName = "Poop Queue Overflow Fix",
        zhInfo = {
            "里蓝人的大便队列已满时，不再继续拾取大便。",
            "小型和大型大便都会留在地上，仍可被推动。",
            "队列腾出空间后即可正常拾取。",
            "不受“小蓝人交易价格”选项影响。",
        },
        enInfo = {
            "Stops Tainted Blue Baby collecting poop when the queue is full.",
            "Small and large poop pickups stay on the ground and remain pushable.",
            "Pickups work normally as soon as the queue has room.",
            "Independent of the Blue Baby Deal Prices option.",
        },
    },
    {
        key = "rerollHealthProtection",
        group = "taintedEden",
        zhName = "重随后保留血量",
        enName = "Keep Health on Reroll",
        zhInfo = {
            "全身道具重随后，保留每位玩家重随前的血量。",
            "覆盖里伊甸、D4/D100、D无限、编号丢失和 1/6 点骰子房。",
            "里伊甸仍会正常承受触发重随的伤害。",
            "套装仍由当前持有的道具决定。",
        },
        enInfo = {
            "Keeps each player's health unchanged when their inventory is rerolled.",
            "Covers Tainted Eden, D4, D100, D Infinity, and Missing No.",
            "Also covers one-pip and six-pip Dice Rooms.",
            "Tainted Eden still takes the hit that triggers the reroll.",
            "Transformations still follow the player's current items.",
        },
    },
    {
        key = "esauJrFirstPickup",
        group = "taintedEden",
        zhName = "小以扫拾取效果",
        enName = "Esau Jr. Pickup Effects",
        zhInfo = {
            "首次生成小以扫时，其道具会正常触发一次性拾取效果并记录套装进度。",
            "实验性疗法、妈妈的零钱包、弹珠袋等只会触发一次。",
            "之后切换身体不会重复触发。",
            "不受“重随后保留血量”选项影响。",
        },
        enInfo = {
            "Runs first-pickup effects when Esau Jr. is created for the first time.",
            "Experimental Treatment, Mom's Coin Purse, and Marbles trigger once.",
            "Similar first-pickup effects also trigger once.",
            "Switching bodies later will not trigger them again.",
            "Independent of Keep Health on Reroll.",
        },
    },
    {
        key = "bethanySoulCharge",
        group = "bethany",
        zhName = "双倍魂心充能",
        enName = "Double Soul Charges",
        zhInfo = {
            "伯大尼每获得一整颗魂心会获得 4 点魂心充能；半颗则获得 2 点。",
            "破损的口袋掉出半颗魂心时，共消耗 2 点充能，捡回后不会净赚充能。",
            "达到 99 点后，魂心和黑心会留在地上。",
            "不受“魂心充能护盾”选项影响。",
        },
        enInfo = {
            "Each full Soul Heart grants Bethany 4 soul charges; a half grants 2.",
            "Torn Pocket's half Soul Heart costs 2 charges, preventing a net gain.",
            "At 99 charges, Soul and Black Heart pickups stay on the ground.",
            "Independent of Soul Charge Shield.",
        },
    },
    {
        key = "bethanyDamageShield",
        group = "bethany",
        zhName = "魂心充能护盾",
        enName = "Soul Charge Shield",
        zhInfo = {
            "消耗伯大尼的魂心充能，抵挡会降低恶魔房/天使房概率的伤害。",
            "成功抵挡后不会损失红心或交易房概率。",
            "仍会获得正常的受伤无敌时间。",
            "献血、乞丐、献祭房等自愿伤害不会消耗充能。",
            "不受“双倍魂心充能”选项影响。",
        },
        enInfo = {
            "Uses Bethany's soul charges to block hits that lower deal chance.",
            "Blocked hits do not remove red health or deal chance.",
            "Bethany still gets the normal post-hit invincibility.",
            "Blood Donation Machines, beggars, and Sacrifice Rooms are exempt.",
            "Other voluntary damage also does not spend charges.",
            "Independent of Double Soul Charges.",
        },
    },
    {
        key = "bethanyShieldFeedback",
        group = "bethany",
        zhName = "护盾视听效果",
        enName = "Shield Effects",
        zhInfo = {
            "伯大尼拥有魂心充能时，会显示包围全身的护罩。",
            "充能越高，护罩的外观和音效越强。",
            "抵挡伤害时只让护罩闪光，不播放伯大尼的受伤动画或语音。",
            "关闭时，护罩会伴随轻微碎裂声淡出。",
            "此选项只影响视听效果；关闭后“魂心充能护盾”仍然生效。",
        },
        enInfo = {
            "Shows a shield around Bethany while she has soul charges.",
            "The shield's look and sound grow stronger with more charges.",
            "Blocked hits flash the shield.",
            "They do not play Bethany's hurt animation or voice.",
            "Turning this off fades the shield out with a soft crack.",
            "This option is cosmetic; Soul Charge Shield still works when it is off.",
        },
    },
    {
        key = "bethanyGelloWispOrbit",
        group = "bethany",
        zhName = "格罗魂火环绕修复",
        enName = "Gello Wisp Orbit Fix",
        zhInfo = {
            "格罗激活时，美德书魂火会继续围绕所属玩家。",
            "魂火不会再把环绕中心移到格罗身上。",
            "只修正环绕中心，不改变伤害、血量、数量和持续时间。",
            "联机时按魂火所属玩家分别处理。",
        },
        enInfo = {
            "While Gello is active, Book of Virtues wisps keep orbiting their owner.",
            "They no longer move their orbit center to Gello.",
            "Only the orbit center changes.",
            "Damage, health, count, and duration stay the same.",
            "In co-op, each player's wisps are handled separately.",
        },
    },
    {
        key = "familiarCapacity",
        group = "general",
        zhName = "跟班上限修复",
        enName = "Familiar Limit Fix",
        zhInfo = {
            "防止蓝苍蝇和蓝蜘蛛占满 64 个跟班位置。",
            "超出软上限的数量会暂存，有空位时自动补回。",
            "永久跟班、魂火、骨刺和任务跟班绝不会被移除。",
            "关闭后只暂停处理，不会清空已暂存数量。",
        },
        enInfo = {
            "Prevents Blue Flies and Blue Spiders from filling all 64 familiar slots.",
            "Overflow is stored and restored when slots open up.",
            "Permanent familiars, wisps, and Bone Spurs are never removed.",
            "Quest familiars are also preserved.",
            "Turning this off pauses the feature without losing stored overflow.",
        },
    },
    {
        key = "clogGroundDamage",
        group = "general",
        zhName = "拦路屎水迹伤害修复",
        enName = "Clog Creep Damage Fix",
        zhInfo = {
            "让玩家生成的伤害水迹能够伤害拦路屎（914.0.0）。",
            "修复原版因飞行判定而跳过水迹伤害的问题。",
            "伤害、范围和结算频率沿用当前水迹。",
            "不影响其他敌人或敌方水迹。",
        },
        enInfo = {
            "Allows player-made damaging creep to hurt The Clog (914.0.0).",
            "Fixes creep being ignored because the game treats The Clog as flying.",
            "Uses the creep's current damage, size, and normal tick rate.",
            "Other enemies and enemy-made creep are unchanged.",
        },
    },
    {
        key = "heldItemProtection",
        group = "general",
        zhName = "拾取动画修复",
        enName = "Pickup Animation Fix",
        zhInfo = {
            "使用R键或遗忘药时，会先完成正在播放的收藏品拾取动画。",
            "完成拾取后，再重置本局或当前层。",
            "避免道具尚未进入物品栏就随重置消失。",
            "联机时会分别完成每位玩家尚未结算的拾取。",
            "关闭后恢复原版行为。",
        },
        enInfo = {
            "Finishes any collectible pickup animation before a reset.",
            "Applies to R Key and Forget Me Now.",
            "Stops the item disappearing before it reaches your inventory.",
            "In co-op, each player's pending pickup is completed.",
            "Turning this off restores vanilla behavior.",
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
                    "Chance for TMTRAINER to appear during a full inventory reroll.",
                    "0% never rolls TMTRAINER; 100% keeps vanilla behavior.",
                    "Applies to D4/D100, D Infinity, Tainted Eden, and Missing No.",
                    "Also covers Dice Rooms 1/6 and Wheel of Fortune?.",
                    "Normal pedestal pickups are unaffected.",
                    "Rerolls that start with TMTRAINER are also unaffected.",
                    "Independent of the other options in this tab.",
                }
            end

            return {
                "全身重随时，出现错误技的概率。",
                "0% 时绝不会重随到错误技；100% 保持原版概率。",
                "覆盖 D4/D100、D无限、里伊甸、编号丢失、1/6 点骰子房和命运之轮？。",
                "正常拾取错误技，或重随前已持有错误技时，不受影响。",
                "不受同栏另外两个选项影响。",
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
                        "Changing it immediately previews the selected style.",
                        "At high charge, the rim, glow, and particles become stronger.",
                        "At low charge, the shield stays thin and faint.",
                    }
                end

                if kind == "hit" then
                    return {
                        "Choose the flash shown when the shield blocks a hit.",
                        "Each style starts bright and fades into an afterglow.",
                    }
                end

                return {
                    "Choose one of three original shield sounds.",
                    "Each sound blends smoothly from light to heavy as charge increases.",
                    "Changing it previews the 30-charge sound.",
                }
            end

            if kind == "visual" then
                return {
                    "选择护盾的外观样式。",
                    "切换后会立即预览所选样式。",
                    "充能越高，边缘、光晕和粒子效果越强。",
                    "充能较低时，护盾会保持轻薄。",
                }
            end

            if kind == "hit" then
                return {
                    "选择护盾抵挡伤害时显示的闪光效果。",
                    "每种样式都会先闪亮，再渐变为余辉。",
                }
            end

            return {
                "选择三种原创护盾音效之一。",
                "充能越高，音效会从轻盈平滑过渡到厚重。",
                "切换后会试听 30 充能时的音效。",
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

                return "Preview " .. previewCharge
                    .. "-Charge Sound: press right"
            end

            if kind == "visual" then
                return "预览护盾: 按右键"
            end

            if kind == "hit" then
                return "预览受击效果: 按右键"
            end

            return "预览" .. previewCharge .. "充能音效: 按右键"
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
                        "Previews the idle shield without taking damage.",
                        "Requires Bethany and Shield Effects to be enabled.",
                    }
                end

                if kind == "hit" then
                    return {
                        "Previews the selected hit effect without taking damage.",
                        "Does not play a sound or spend charges.",
                        "Does not trigger Bethany's hurt animation or voice.",
                    }
                end

                return {
                    "Previews the selected sound at a simulated charge level of "
                        .. previewCharge .. ".",
                    "Does not deal damage, spend charges, or play a hurt voice.",
                }
            end

            if kind == "visual" then
                return {
                    "无需受伤即可预览当前护盾的待机效果。",
                    "需要使用伯大尼并开启“护盾视听效果”。",
                }
            end

            if kind == "hit" then
                return {
                    "无需受伤即可预览所选受击效果。",
                    "不会播放音效、消耗充能，也不会触发伯大尼的受伤动画或语音。",
                }
            end

            return {
                "以模拟 " .. previewCharge .. " 充能试听所选护盾音效。",
                "不会造成伤害、消耗充能或播放受伤语音。",
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
