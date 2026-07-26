local ClogGroundDamageModule = {}
ClogGroundDamageModule.__index = ClogGroundDamageModule

local SETTING_KEY = "clogGroundDamage"
local CLOG_TYPE = EntityType.ENTITY_CLOG
local CLOG_VARIANT = 0
local CLOG_SUBTYPE = 0
local FLYING_FLAG = EntityFlag.FLAG_FLYING
local OWNERSHIP_KEY = "CharacterEnhanceClogGrounded"

function ClogGroundDamageModule.New(context)
    local self = setmetatable({
        Context = context,
    }, ClogGroundDamageModule)

    local function ApplyToClog(_, npc)
        self:ApplyToClog(npc)
    end

    context.Mod:AddCallback(
        ModCallbacks.MC_POST_NPC_INIT,
        ApplyToClog,
        CLOG_TYPE
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_NPC_UPDATE,
        ApplyToClog,
        CLOG_TYPE
    )
    context.Mod:AddCallback(
        ModCallbacks.MC_PRE_MOD_UNLOAD,
        function()
            self:RestoreExistingClogs()
        end
    )

    return self
end

function ClogGroundDamageModule:IsTarget(npc)
    return npc
        and npc.Type == CLOG_TYPE
        and npc.Variant == CLOG_VARIANT
        and npc.SubType == CLOG_SUBTYPE
end

function ClogGroundDamageModule:ApplyToClog(npc)
    if not self:IsTarget(npc) then
        return
    end

    local data = npc:GetData()

    if self.Context:IsEnabled(SETTING_KEY) then
        if npc:HasEntityFlags(FLYING_FLAG) then
            npc:ClearEntityFlags(FLYING_FLAG)
            data[OWNERSHIP_KEY] = true
        end
    elseif data[OWNERSHIP_KEY] then
        npc:AddEntityFlags(FLYING_FLAG)
        data[OWNERSHIP_KEY] = nil
    end
end

function ClogGroundDamageModule:RestoreExistingClogs()
    for _, entity in ipairs(Isaac.FindByType(
        CLOG_TYPE,
        CLOG_VARIANT,
        CLOG_SUBTYPE,
        false,
        false
    )) do
        local data = entity:GetData()

        if data[OWNERSHIP_KEY] then
            entity:AddEntityFlags(FLYING_FLAG)
            data[OWNERSHIP_KEY] = nil
        end
    end
end

function ClogGroundDamageModule:OnSettingChanged(enabled)
    if not enabled then
        self:RestoreExistingClogs()
    end
end

return ClogGroundDamageModule
