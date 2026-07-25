local TaintedLostModule = {}
TaintedLostModule.__index = TaintedLostModule

local SETTING_KEY = "taintedLostWoodenCross"
local TAINTED_LOST = PlayerType.PLAYER_THELOST_B
local WOODEN_CROSS = 121

function TaintedLostModule.New(context)
    local self = setmetatable({
        Context = context,
    }, TaintedLostModule)

    context.Mod:AddCallback(
        ModCallbacks.MC_POST_GAME_STARTED,
        function(_, isContinued)
            self:OnGameStarted(isContinued)
        end
    )

    return self
end

function TaintedLostModule:OnGameStarted(isContinued)
    if isContinued or not self.Context:IsEnabled(SETTING_KEY) then
        return
    end

    local game = Game()

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(playerIndex)

        if player:GetPlayerType() == TAINTED_LOST then
            player:AddTrinket(WOODEN_CROSS, false)
        end
    end
end

return TaintedLostModule
