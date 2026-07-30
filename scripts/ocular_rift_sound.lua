local OcularRiftSoundModule = {}
OcularRiftSoundModule.__index = OcularRiftSoundModule

local SETTING_KEY = "ocularRiftSoundFix"
local OCULAR_RIFT = CollectibleType.COLLECTIBLE_OCULAR_RIFT
local OCULAR_RIFT_SHOOT_SOUND = SoundEffect.SOUND_OCCULAR_RIFT_SHOOT
local LEGITIMATE_SHOT_GRACE_FRAMES = 8

function OcularRiftSoundModule.New(context)
    local self = setmetatable({
        Context = context,
        Sfx = SFXManager(),
        LastShotFrame = -LEGITIMATE_SHOT_GRACE_FRAMES - 1,
        ReportedSuppression = false,
    }, OcularRiftSoundModule)

    context.Mod:AddCallback(
        ModCallbacks.MC_POST_FIRE_TEAR,
        function(_, tear)
            self:OnPostFireTear(tear)
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_GAME_STARTED,
        function()
            self:OnGameStarted()
        end
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_POST_UPDATE,
        function()
            self:OnPostUpdate()
        end
    )

    return self
end

function OcularRiftSoundModule:HasOcularRiftHolder(frame)
    local game = Game()
    local foundHolder = false

    for playerIndex = 0, game:GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(playerIndex)

        if player and player:HasCollectible(OCULAR_RIFT) then
            foundHolder = true
            local input = player:GetShootingInput()

            if input and (input.X ~= 0 or input.Y ~= 0) then
                self.LastShotFrame = frame
            end
        end
    end

    return foundHolder
end

function OcularRiftSoundModule:GetTearOwner(tear)
    local spawner = tear and tear.SpawnerEntity
    local player = spawner and spawner:ToPlayer()

    if player then
        return player
    end

    local familiar = spawner and spawner:ToFamiliar()
    return familiar and familiar.Player or nil
end

function OcularRiftSoundModule:OnPostFireTear(tear)
    local player = self:GetTearOwner(tear)

    if self.Context:IsEnabled(SETTING_KEY)
        and player
        and player:HasCollectible(OCULAR_RIFT)
    then
        self.LastShotFrame = Game():GetFrameCount()
    end
end

function OcularRiftSoundModule:OnGameStarted()
    self.LastShotFrame = -LEGITIMATE_SHOT_GRACE_FRAMES - 1
end

function OcularRiftSoundModule:OnPostUpdate()
    if not self.Context:IsEnabled(SETTING_KEY) then
        return
    end

    local frame = Game():GetFrameCount()

    if not self:HasOcularRiftHolder(frame)
        or frame - self.LastShotFrame <= LEGITIMATE_SHOT_GRACE_FRAMES
        or not self.Sfx:IsPlaying(OCULAR_RIFT_SHOOT_SOUND)
    then
        return
    end

    -- Finger!, Aquarius, Spear of Destiny, and similar passive damage sources
    -- can roll Ocular Rift's tear effect while no tear is being fired. The
    -- engine starts the shoot sound anyway; stop only that dedicated sound and
    -- leave actual rift portals and every other sound untouched.
    self.Sfx:Stop(OCULAR_RIFT_SHOOT_SOUND)

    if not self.ReportedSuppression and Isaac.DebugString then
        Isaac.DebugString(
            "[Character Enhance] suppressed idle Ocular Rift shoot sound"
        )
        self.ReportedSuppression = true
    end
end

return OcularRiftSoundModule
