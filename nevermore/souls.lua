-- scripts/vscripts/bots/nevermore/souls.lua

local C = require("bots/nevermore/constants")

local S = {}

function S.GetSouls(bot)
    local numModifiers = bot:NumModifiers()
    if numModifiers and numModifiers > 0 then
        for i = 0, numModifiers - 1 do
            local modName = bot:GetModifierName(i)
            if modName == "modifier_nevermore_necromastery" then
                return bot:GetModifierStackCount(i) or 0
            end
        end
    end
    return 0
end

function S.GetDamagePerSoul(bot)
    local level = (bot and bot:GetLevel()) or 0
    return (C.NECROMASTERY.BASE_DMG_PER_SOUL or 1.35)
        + (C.NECROMASTERY.DMG_PER_SOUL_PER_LEVEL or 0.15) * level
end

function S.GetSoulDamageBonus(bot)
    return S.GetSouls(bot) * S.GetDamagePerSoul(bot)
end

return S
