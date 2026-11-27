local MazeCursePillLabel = {}

local SETTING_KEY = "mazeCursePillLabel"
local LABELS = { en = "Maze Curse", zh = "混乱诅咒" }

function MazeCursePillLabel.New(context)
    local game = Game()
    local labelFont
    local labelWidths = {}
    local foreground = KColor(1, 1, 1, 1)
    local shadow = KColor(0, 0, 0, 0.9)

    local function DrawLabel(player)
        if not labelFont then
            labelFont = Font()
            labelFont:Load("font/cjk/lanapixel.fnt")
        end

        local label = LABELS[context.Settings.menuLanguage] or LABELS.en
        local width = labelWidths[label]
        if not width then
            width = labelFont:GetStringWidthUTF8(label)
            labelWidths[label] = width
        end

        local position = Isaac.WorldToScreen(player.Position) + player.PositionOffset
        local x = math.floor(position.X - width / 2)
        local y = math.floor(position.Y - 32 * player.SpriteScale.Y)
        labelFont:DrawStringUTF8(label, x + 1, y + 1, shadow, 0, false)
        labelFont:DrawStringUTF8(label, x, y, foreground, 0, false)
    end

    context.Mod:AddCallback(ModCallbacks.MC_POST_RENDER, function()
        if not context:IsEnabled(SETTING_KEY) or game:IsPaused()
            or (MCM and MCM.IsVisible) or (ModConfigMenu and ModConfigMenu.IsVisible)
            or not game:GetHUD():IsVisible()
        then
            return
        end

        local itemPool
        for index = 0, game:GetNumPlayers() - 1 do
            local player = Isaac.GetPlayer(index)
            local pill = player:GetPill(0)
            local color = pill & ~PillColor.PILL_GIANT_FLAG
            if color ~= PillColor.PILL_NULL and color ~= PillColor.PILL_GOLD
                and player.Visible and not player:IsDead() and not player:IsCoopGhost()
            then
                itemPool = itemPool or game:GetItemPool()
                if itemPool:IsPillIdentified(pill)
                    and itemPool:GetPillEffect(pill, player) == PillEffect.PILLEFFECT_QUESTIONMARK
                then
                    DrawLabel(player)
                end
            end
        end
    end)
end

return MazeCursePillLabel
