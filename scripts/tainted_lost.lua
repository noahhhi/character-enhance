local TaintedLostModule = {}
TaintedLostModule.__index = TaintedLostModule

local SETTING_KEY = "taintedLostWoodenCross"
local TAINTED_LOST = PlayerType.PLAYER_THELOST_B
local WOODEN_CROSS = 121
local CHARACTER_SELECT_PATHS = {
    "resources/gfx/ui/main menu/charactermenualt.anm2",
    "resources.zh/gfx/ui/main menu/charactermenualt.anm2",
}
local CHARACTER_SELECT_ANIMATION = '<Animation Name="11_TheLost"'
local CHARACTER_SELECT_LAYER_IDS = { 12, 13 }
local ENABLED_ALPHA = "255"
local DISABLED_ALPHA = "000"

local function GetRuntimeModRoot()
    if type(debug) ~= "table" or type(debug.getinfo) ~= "function" then
        return nil
    end

    local sourceInfo = debug.getinfo(GetRuntimeModRoot, "S")
    local source = sourceInfo and sourceInfo.source

    if type(source) ~= "string" or source:sub(1, 1) ~= "@" then
        return nil
    end

    local normalized = source:sub(2):gsub("\\", "/")
    local suffix = "/scripts/tainted_lost.lua"

    if normalized:lower():sub(-#suffix) ~= suffix then
        return nil
    end

    local root = normalized:sub(1, #normalized - #suffix)

    -- Deterministic tests load this module from the source tree. Runtime asset
    -- synchronization must only ever mutate the installed mod copy.
    if not root:lower():find("/mods/", 1, true) then
        return nil
    end

    return root .. "/"
end

local function ReadFile(path)
    if type(io) ~= "table" or type(io.open) ~= "function" then
        return nil, "Lua file access is unavailable"
    end

    local file, openError = io.open(path, "rb")

    if not file then
        return nil, openError
    end

    local content = file:read("*a")
    file:close()
    return content
end

local function WriteAlphaValues(path, offsets, alpha)
    if type(io) ~= "table" or type(io.open) ~= "function" then
        return false, "Lua file access is unavailable"
    end

    local file, openError = io.open(path, "r+b")

    if not file then
        return false, openError
    end

    for _, offset in ipairs(offsets) do
        local seekResult, seekError = file:seek("set", offset - 1)

        if not seekResult then
            file:close()
            return false, seekError
        end

        local writeResult, writeError = file:write(alpha)

        if not writeResult then
            file:close()
            return false, writeError
        end
    end

    local flushResult, flushError = file:flush()
    file:close()

    if not flushResult then
        return false, flushError
    end

    return true
end

local function FindCharacterSelectAlphaOffsets(content)
    local animationStart = content:find(CHARACTER_SELECT_ANIMATION, 1, true)

    if not animationStart then
        return nil, "Tainted Lost animation is missing"
    end

    local animationEnd = content:find("</Animation>", animationStart, true)

    if not animationEnd then
        return nil, "Tainted Lost animation is incomplete"
    end

    local offsets = {}
    local values = {}
    local alphaPrefix = 'AlphaTint="'

    for _, layerId in ipairs(CHARACTER_SELECT_LAYER_IDS) do
        local layerTag = '<LayerAnimation LayerId="' .. layerId .. '"'
        local layerStart = content:find(layerTag, animationStart, true)

        if not layerStart or layerStart >= animationEnd then
            return nil, "Tainted Lost layer " .. layerId .. " is missing"
        end

        local layerEnd = content:find("</LayerAnimation>", layerStart, true)

        if not layerEnd or layerEnd >= animationEnd then
            return nil, "Tainted Lost layer " .. layerId .. " is incomplete"
        end

        local alphaTag = content:find(alphaPrefix, layerStart, true)

        if not alphaTag or alphaTag >= layerEnd then
            return nil, "Tainted Lost layer " .. layerId .. " has no alpha"
        end

        local valueStart = alphaTag + #alphaPrefix
        local value = content:sub(valueStart, valueStart + 2)

        if value ~= ENABLED_ALPHA and value ~= DISABLED_ALPHA then
            return nil, "Tainted Lost layer " .. layerId .. " has unknown alpha"
        end

        offsets[#offsets + 1] = valueStart
        values[#values + 1] = value
    end

    return offsets, values
end

local function LogAssetSyncFailure(message)
    if type(Isaac) == "table" and type(Isaac.DebugString) == "function" then
        Isaac.DebugString(
            "[Character Enhance] Character-select sync failed: " .. message
        )
    end
end

function TaintedLostModule.New(context, assetAccess)
    local self = setmetatable({
        Context = context,
        AssetAccess = assetAccess or {
            Root = GetRuntimeModRoot(),
            Read = ReadFile,
            WriteAlphaValues = WriteAlphaValues,
        },
    }, TaintedLostModule)

    context.Mod:AddCallback(
        ModCallbacks.MC_POST_GAME_STARTED,
        function(_, isContinued)
            self:OnGameStarted(isContinued)
        end
    )

    self:SynchronizeCharacterSelectAssets(
        context:IsEnabled(SETTING_KEY)
    )

    return self
end

function TaintedLostModule:SynchronizeCharacterSelectAssets(enabled)
    local access = self.AssetAccess

    if not access or type(access.Root) ~= "string"
        or type(access.Read) ~= "function"
        or type(access.WriteAlphaValues) ~= "function"
    then
        return false
    end

    local desiredAlpha = enabled and ENABLED_ALPHA or DISABLED_ALPHA
    local synchronized = true

    for _, relativePath in ipairs(CHARACTER_SELECT_PATHS) do
        local path = access.Root .. relativePath
        local content, readError = access.Read(path)

        if not content then
            LogAssetSyncFailure(relativePath .. ": " .. tostring(readError))
            synchronized = false
        else
            local offsets, valuesOrError = FindCharacterSelectAlphaOffsets(
                content
            )

            if not offsets then
                LogAssetSyncFailure(relativePath .. ": " .. valuesOrError)
                synchronized = false
            else
                local needsWrite = false

                for _, value in ipairs(valuesOrError) do
                    if value ~= desiredAlpha then
                        needsWrite = true
                        break
                    end
                end

                if needsWrite then
                    local written, writeError = access.WriteAlphaValues(
                        path,
                        offsets,
                        desiredAlpha
                    )

                    if not written then
                        LogAssetSyncFailure(
                            relativePath .. ": " .. tostring(writeError)
                        )
                        synchronized = false
                    else
                        local verifiedContent = access.Read(path)
                        local verifiedValues = nil

                        if verifiedContent then
                            local verifiedOffsets
                            verifiedOffsets, verifiedValues =
                                FindCharacterSelectAlphaOffsets(
                                    verifiedContent
                                )

                            if not verifiedOffsets then
                                verifiedValues = nil
                            end
                        end

                        if type(verifiedValues) ~= "table"
                            or verifiedValues[1] ~= desiredAlpha
                            or verifiedValues[2] ~= desiredAlpha
                        then
                            LogAssetSyncFailure(
                                relativePath .. ": verification failed"
                            )
                            synchronized = false
                        end
                    end
                end
            end
        end
    end

    return synchronized
end


function TaintedLostModule:OnSettingChanged(enabled)
    self:SynchronizeCharacterSelectAssets(enabled)
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
