-- scripts/vscripts/bots/nevermore/lasthit.lua

local C = require("bots/nevermore/constants")
local U = require("bots/nevermore/utils")

local L = {}

function L.GetBestTarget(bot, enemyCreeps, allyCreeps, enemyAttackers, allyAttackers)
    local bestTarget = nil
    local bestTime = math.huge
    local isTargetDeny = false

    -- Enemy creeps: last hit
    for _, c in pairs(enemyCreeps or {}) do
        if c and c:IsAlive() then
            local t_killable = U.GetTimeToKillable(bot, c, allyAttackers)
            if t_killable >= 0 and t_killable < 5.0 then
                local name = c:GetUnitName() or ""
                local score = t_killable
                if name:find("ranged") then score = score - 6.0 end
                if name:find("flagbearer") then score = score - 5.0 end
                if name:find("siege") then score = score - 4.0 end
                if score < bestTime then
                    bestTime = score
                    bestTarget = c
                    isTargetDeny = false
                end
            end
        end
    end

    -- Ally creeps: deny
    for _, c in pairs(allyCreeps or {}) do
        if c and c:IsAlive() then
            local maxHp = c:GetMaxHealth() or 1
            if (c:GetHealth() / maxHp) <= C.LASTHIT.DENY_HP_THRESHOLD then
                local t_killable = U.GetTimeToKillable(bot, c, enemyAttackers)
                if t_killable >= 0 and t_killable < 5.0 then
                    local name = c:GetUnitName() or ""
                    local score = t_killable
                    if name:find("ranged") then score = score - 6.0 end
                    if name:find("flagbearer") then score = score - 5.0 end
                    if name:find("siege") then score = score - 4.0 end
                    score = score + 0.2 -- deny is slightly less important than last hit
                    if score < bestTime then
                        bestTime = score
                        bestTarget = c
                        isTargetDeny = true
                    end
                end
            end
        end
    end

    return bestTarget, isTargetDeny
end

return L
