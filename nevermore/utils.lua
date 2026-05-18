-- scripts/vscripts/bots/nevermore/utils.lua

local C = require("bots/nevermore/constants")
local S = require("bots/nevermore/souls")

local U = {}

local SAFE_DISTANCE = C.SAFE_DISTANCE or {
    MIN_DISTANCE_FROM_ENEMY = 750,
    MIN_DISTANCE_CRITICAL   = 950,
    CRITICAL_HP_FACTOR      = 1.05,
    KILL_THREAT_FACTOR      = 1.20,
    SINGLE_KILL_FACTOR      = 1.10,
}

local function Atan2(y, x)
    if math.atan2 then return math.atan2(y, x) end
    if x > 0 then return math.atan(y / x) end
    if x < 0 and y >= 0 then return math.atan(y / x) + math.pi end
    if x < 0 and y < 0 then return math.atan(y / x) - math.pi end
    if x == 0 and y > 0 then return math.pi / 2 end
    if x == 0 and y < 0 then return -math.pi / 2 end
    return 0
end

local function Clamp(v, minValue, maxValue)
    if v < minValue then return minValue end
    if v > maxValue then return maxValue end
    return v
end

function U.CanQuery(unit)
    if not unit then return false end
    if not unit:IsAlive() then return false end
    if unit.CanBeSeen and not unit:CanBeSeen() then return false end
    return true
end

function U.MergeLists(list1, list2)
    local result = {}
    if list1 then for _, v in pairs(list1) do table.insert(result, v) end end
    if list2 then for _, v in pairs(list2) do table.insert(result, v) end end
    return result
end

function U.DistanceBetweenLocations(a, b)
    if not a or not b then return math.huge end
    local dx = a.x - b.x
    local dy = a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

function U.GetRazeLabelByDistance(dist, radius)
    radius = radius or C.RAZE.STRICT_RADIUS
    local candidates = {
        { label = "near", center = C.RAZE.NEAR_CENTER },
        { label = "mid",  center = C.RAZE.MID_CENTER  },
        { label = "far",  center = C.RAZE.FAR_CENTER  },
    }
    local bestLabel = nil
    local bestDiff = math.huge
    for _, v in ipairs(candidates) do
        local diff = math.abs(dist - v.center)
        if diff < bestDiff then
            bestDiff = diff
            bestLabel = v.label
        end
    end
    if bestDiff <= radius then
        return bestLabel, bestDiff
    end
    return nil, bestDiff
end

function U.GetRazeCenterByLabel(label)
    if label == "near" then return C.RAZE.NEAR_CENTER end
    if label == "mid"  then return C.RAZE.MID_CENTER end
    if label == "far"  then return C.RAZE.FAR_CENTER end
    return nil
end

function U.CanAcceptSingleRazeTrade(bot, enemy)
    if not U.CanQuery(enemy) then return true end
    if not U.EnemyHasRaze(enemy) then return true end
    local myLvl = bot:GetLevel() or 1
    local eLvl = enemy:GetLevel() or 1
    local tol = (C.RAZE and C.RAZE.SINGLE_TRADE_LEVEL_TOLERANCE) or 1
    return eLvl <= (myLvl + tol)
end

function U.GetTeamFountain(team)
    return team == TEAM_RADIANT and C.POSITIONS.MID_FOUNTAIN_RADIANT or C.POSITIONS.MID_FOUNTAIN_DIRE
end

function U.GetFountain(bot)
    return U.GetTeamFountain(bot:GetTeam())
end

function U.GetTargetPredictionContext(target, all_attackers)
    local ctx = {
        hp = target:GetHealth(),
        regen = target:GetHealthRegen(),
        projs = target:GetIncomingTrackingProjectiles() or {},
        dps = 0,
        virtual_projs = {},
    }

    local flying_casters = {}
    for _, p in pairs(ctx.projs) do
        if p.is_attack and p.caster and U.CanQuery(p.caster) then
            flying_casters[p.caster] = true
        end
    end

    if all_attackers then
        for _, atk in pairs(all_attackers) do
            if atk and U.CanQuery(atk) and atk:GetAttackTarget() == target and not flying_casters[atk] then
                if atk:IsTower() or ((atk:GetUnitName() or ""):find("siege")) then
                    local speed = atk:IsTower() and 750 or 1100
                    local dist = GetUnitToLocationDistance(target, atk:GetLocation())
                    local t_impact = (dist / speed) + (atk:IsTower() and 0.07 or 0) + 0.4
                    local avgDmg = atk:GetAttackDamage()
                    local actualDmg = target:GetActualIncomingDamage(avgDmg, DAMAGE_TYPE_PHYSICAL)
                    local bat = atk:GetSecondsPerAttack()
                    if not bat or bat <= 0 then bat = 1.0 end
                    table.insert(ctx.virtual_projs, { actualDmg = actualDmg, t_impact = t_impact, bat = bat })
                else
                    local avgDmg = atk:GetAttackDamage()
                    local bat = atk:GetSecondsPerAttack()
                    if bat and bat > 0 and avgDmg > 0 then
                        local actualDmg = target:GetActualIncomingDamage(avgDmg, DAMAGE_TYPE_PHYSICAL)
                        ctx.dps = ctx.dps + (actualDmg / bat)
                    end
                end
            end
        end
    end

    ctx.dps = ctx.dps * 0.70
    return ctx
end

function U.PredictHPWithContext(ctx, target, time_in_future)
    if ctx.hp <= 0 then return 0 end

    local predicted_hp = ctx.hp + (ctx.regen * time_in_future) - (ctx.dps * time_in_future)

    for _, p in pairs(ctx.projs) do
        if p.is_attack and p.caster and U.CanQuery(p.caster) then
            local speed = p.caster:GetAttackProjectileSpeed()
            local is_tower = false
            if not speed or speed <= 0 then
                local name = p.caster:GetUnitName() or ""
                if p.caster:IsTower() then
                    speed = 750
                    is_tower = true
                elseif name:find("siege") then
                    speed = 1100
                else
                    speed = 900
                end
            else
                if p.caster:IsTower() then is_tower = true end
            end

            local dist = GetUnitToLocationDistance(target, p.location)
            local t_impact = dist / speed
            if is_tower then t_impact = t_impact + 0.07 end

            if t_impact <= time_in_future then
                local avgDmg = p.caster:GetAttackDamage()
                if avgDmg > 0 then
                    local actualDmg = target:GetActualIncomingDamage(avgDmg, DAMAGE_TYPE_PHYSICAL)
                    predicted_hp = predicted_hp - actualDmg
                    local bat = p.caster:GetSecondsPerAttack()
                    if bat and bat > 0 then
                        local next_impact = t_impact + bat
                        while next_impact <= time_in_future do
                            predicted_hp = predicted_hp - actualDmg
                            next_impact = next_impact + bat
                        end
                    end
                end
            end
        end
    end

    for _, vp in pairs(ctx.virtual_projs) do
        if vp.t_impact <= time_in_future then
            predicted_hp = predicted_hp - vp.actualDmg
            local next_impact = vp.t_impact + vp.bat
            while next_impact <= time_in_future do
                predicted_hp = predicted_hp - vp.actualDmg
                next_impact = next_impact + vp.bat
            end
        end
    end

    return predicted_hp
end

function U.HasLasthitWindow(ctx, target, my_dmg, min_time)
    min_time = min_time or 0
    for t = 0.05, 3.0, 0.05 do
        local hp = U.PredictHPWithContext(ctx, target, t)
        if hp <= 0 then
            return false
        elseif hp <= my_dmg then
            if t >= min_time then return true end
        end
    end
    return false
end

function U.SFDamageRange(bot, target)
    local rawDmg = bot:GetAttackDamage()
    local variance = bot:GetBaseDamageVariance()
    local actualMin = target:GetActualIncomingDamage(rawDmg - variance, DAMAGE_TYPE_PHYSICAL)
    local actualAvg = target:GetActualIncomingDamage(rawDmg, DAMAGE_TYPE_PHYSICAL)

    if target and target:IsAlive() then
        local name = target:GetUnitName() or ""
        if name:find("siege") then
            actualMin = actualMin * 0.5
            actualAvg = actualAvg * 0.5
        end
    end

    return { min = actualMin, avg = actualAvg }
end

function U.GetEffectiveDamageAndMargin(bot, target, attackersCount)
    local range = U.SFDamageRange(bot, target)
    local base_margin = 0
    if attackersCount and attackersCount >= 3 then base_margin = 2 end
    return range.min, base_margin
end

function U.GetTimeToKillable(bot, target, attackers)
    local atkCount = 0
    if attackers then
        for _, atk in pairs(attackers) do
            if atk and U.CanQuery(atk) and atk:GetAttackTarget() == target then
                atkCount = atkCount + 1
            end
        end
    end

    local dmg, safety_margin = U.GetEffectiveDamageAndMargin(bot, target, atkCount)
    local kill_threshold = dmg - safety_margin
    local currentHP = target:GetHealth()
    if currentHP <= kill_threshold then return 0.0 end

    local ctx = U.GetTargetPredictionContext(target, attackers)
    for t = 0.05, 5.0, 0.05 do
        local predHP = U.PredictHPWithContext(ctx, target, t)
        if predHP <= kill_threshold and predHP > 0 then
            return t
        elseif predHP <= 0 then
            return -1
        end
    end

    return 999
end

function U.GetActiveItemByName(bot, name)
    local slot = bot:FindItemSlot(name)
    if slot >= 0 and slot <= 5 then
        local item = bot:GetItemInSlot(slot)
        if item and item:IsFullyCastable() then return item end
    end
    return nil
end

function U.GetTPScroll(bot)
    local slot = bot:FindItemSlot("item_tpscroll")
    if slot and slot >= 0 then
        local item = bot:GetItemInSlot(slot)
        if item then return item, slot end
    end
    for i = 0, 15 do
        local item = bot:GetItemInSlot(i)
        if item and item:GetName() == "item_tpscroll" then return item, i end
    end
    return nil, -1
end

function U.GetConsumableManaBurst(unit)
    if not unit then return 0 end
    local burst = 0
    if U.HasItem(unit, "item_enchanted_mango") then burst = burst + 100 end
    return burst
end

function U.GetStickCharges(unit)
    if not unit then return 0 end
    local best = 0
    for i = 0, 15 do
        local item = unit:GetItemInSlot(i)
        if item then
            local name = item:GetName()
            if name == "item_magic_wand" or name == "item_magic_stick" then
                local charges = (item.GetCurrentCharges and item:GetCurrentCharges()) or 0
                if charges > best then best = charges end
            end
        end
    end
    return best
end

function U.GetPotentialManaForRaze(unit)
    if not unit then return 0 end
    local mana = unit:GetMana() or 0
    mana = mana + U.GetConsumableManaBurst(unit)
    local charges = U.GetStickCharges(unit)
    if charges > 0 then
        mana = mana + charges * 15
    end
    return mana
end

function U.HasBoots(unit)
    if not unit then return false end
    return U.HasItem(unit, "item_boots") or U.HasItem(unit, "item_power_treads")
end

function U.HasItem(unit, item_name)
    if not unit then return false end
    if not U.CanQuery(unit) and not unit:IsBot() then return false end
    for i = 0, 15 do
        local item = unit:GetItemInSlot(i)
        if item and item:GetName() == item_name then return true end
    end
    return false
end

function U.GetItemCount(unit, item_name)
    if not unit then return 0 end
    if not U.CanQuery(unit) and not unit:IsBot() then return 0 end
    local count = 0
    for i = 0, 15 do
        local item = unit:GetItemInSlot(i)
        if item and item:GetName() == item_name then
            count = count + 1
        end
    end
    return count
end

function U.GetLaneItemPower(unit)
    if not unit then return 0 end
    local score = 0
    score = score + U.GetItemCount(unit, "item_bracer") * 0.90
    score = score + U.GetItemCount(unit, "item_magic_wand") * 0.35
    score = score + U.GetItemCount(unit, "item_magic_stick") * 0.20
    if U.HasItem(unit, "item_boots") then score = score + 0.25 end
    if U.HasItem(unit, "item_power_treads") then score = score + 0.50 end
    if U.HasItem(unit, "item_kaya") then score = score + 1.00 end
    if U.HasItem(unit, "item_dragon_lance") then score = score + 0.90 end
    return score
end

function U.ManageInventorySlots(bot)
    for bpSlot = 6, 8 do
        local bpItem = bot:GetItemInSlot(bpSlot)
        if bpItem then
            local bpPrio = C.ITEM_PRIORITY[bpItem:GetName()] or 0
            if bpItem:GetName() == "item_ward_observer" then bpPrio = 999 end
            local worstSlot = -1
            local worstPrio = 999
            local hasEmptySlot = false
            for invSlot = 0, 5 do
                local invItem = bot:GetItemInSlot(invSlot)
                if not invItem then
                    hasEmptySlot = true
                    worstSlot = invSlot
                    break
                else
                    local invPrio = C.ITEM_PRIORITY[invItem:GetName()] or 0
                    if invPrio < worstPrio then
                        worstPrio = invPrio
                        worstSlot = invSlot
                    end
                end
            end
            if hasEmptySlot or bpPrio > worstPrio then
                bot:ActionImmediate_SwapItems(bpSlot, worstSlot)
                return
            end
        end
    end
end

function U.GetSafeClosestTree(bot, enemyTowers)
    local trees = bot:GetNearbyTrees(1200)
    if not trees or #trees == 0 then return nil end
    if not enemyTowers or #enemyTowers == 0 then return trees[1] end
    for _, tree in ipairs(trees) do
        local treeLoc = GetTreeLocation(tree)
        local isSafe = true
        for _, tower in pairs(enemyTowers) do
            if tower:IsAlive() and GetUnitToLocationDistance(tower, treeLoc) < 850 then
                isSafe = false
                break
            end
        end
        if isSafe then return tree end
    end
    return nil
end

function U.IsEnemyCastingRaze(enemy)
    if not U.CanQuery(enemy) then return false end
    local r1 = enemy:GetAbilityByName("nevermore_shadowraze1")
    local r2 = enemy:GetAbilityByName("nevermore_shadowraze2")
    local r3 = enemy:GetAbilityByName("nevermore_shadowraze3")
    if (r1 and r1:IsInAbilityPhase()) or
       (r2 and r2:IsInAbilityPhase()) or
       (r3 and r3:IsInAbilityPhase()) then
        return true
    end
    return false
end

function U.EnemyHasRaze(enemy)
    if not U.CanQuery(enemy) then return false end
    local r1 = enemy:GetAbilityByName("nevermore_shadowraze1")
    if r1 and r1:GetLevel() > 0 then return true end
    local r2 = enemy:GetAbilityByName("nevermore_shadowraze2")
    if r2 and r2:GetLevel() > 0 then return true end
    local r3 = enemy:GetAbilityByName("nevermore_shadowraze3")
    if r3 and r3:GetLevel() > 0 then return true end
    return false
end

U._razeTracker = {
    enemies = {},
    lastMissTime = -math.huge,
    lastMissEntindex = nil,
}

local function _getEnemyRazeTrackerEntry(enemy)
    if not enemy then return nil end
    local key = (enemy.GetPlayerID and enemy:GetPlayerID()) or tostring(enemy)
    if key == nil or (type(key) == "number" and key < 0) then key = tostring(enemy) end
    local entry = U._razeTracker.enemies[key]
    if not entry then
        entry = {
            wasCasting = false,
            lastPhaseEndTime = -math.huge,
            pendingMissCheck = false,
            pendingLabel = nil,
            prevDebuffStacks = 0,
            prevDebuffRemain = 0,
            lastHitLabel = nil,
            lastHitTime = -math.huge,
        }
        U._razeTracker.enemies[key] = entry
    end
    return entry
end

function U.UpdateEnemyRazeMissTracker(bot, enemy)
    if not U.CanQuery(enemy) then return end
    local entry = _getEnemyRazeTrackerEntry(enemy)
    if not entry then return end

    local now = GameTime()
    local casting = U.IsEnemyCastingRaze(enemy)

    if entry.wasCasting and not casting then
        entry.lastPhaseEndTime = now
        entry.pendingMissCheck = true
        entry.prevDebuffStacks = U.GetShadowrazeDebuff(bot) or 0
        local castDist = GetUnitToLocationDistance(enemy, bot:GetLocation())
        entry.pendingLabel = U.GetRazeLabelByDistance(castDist, C.RAZE.HIT_RADIUS)
    end

    entry.wasCasting = casting

    if entry.pendingMissCheck then
        local stacksNow = U.GetShadowrazeDebuff(bot) or 0
        if stacksNow > entry.prevDebuffStacks then
            entry.pendingMissCheck = false
            entry.lastHitLabel = entry.pendingLabel
                or U.GetRazeLabelByDistance(GetUnitToLocationDistance(enemy, bot:GetLocation()), C.RAZE.HIT_RADIUS)
            entry.lastHitTime = now
            entry.pendingLabel = nil
        elseif (now - entry.lastPhaseEndTime) >= C.RAZE.MISS_DETECT_WINDOW then
            entry.pendingMissCheck = false
            U._razeTracker.lastMissTime = now
            U._razeTracker.lastMissEntindex = (enemy.GetPlayerID and enemy:GetPlayerID()) or nil
            entry.pendingLabel = nil
        end
    end
end

function U.HasEnemyMissedRazeRecently()
    return (GameTime() - (U._razeTracker.lastMissTime or -math.huge)) <= C.RAZE.MISS_ADVANTAGE_TIME
end

function U.GetEnemyMissAge()
    return GameTime() - (U._razeTracker.lastMissTime or -math.huge)
end

function U.GetRecentEnemyRazeHitLabel(enemy)
    if not enemy then return nil end
    local entry = _getEnemyRazeTrackerEntry(enemy)
    if not entry then return nil end
    return entry.lastHitLabel
end

function U.GetRecentEnemyRazeHitAge(enemy)
    if not enemy then return math.huge end
    local entry = _getEnemyRazeTrackerEntry(enemy)
    if not entry then return math.huge end
    return GameTime() - (entry.lastHitTime or -math.huge)
end

function U.IsSecondStackDangerActive(bot, enemy)
    if not U.CanQuery(enemy) then return false, nil end
    local stacks, rem_time = U.GetShadowrazeDebuff(bot)
    if stacks < 1 or rem_time <= C.RAZE.RETREAT_MIN_REMAIN then
        return false, nil
    end
    local hitLabel = U.GetRecentEnemyRazeHitLabel(enemy)
    if not hitLabel then return false, nil end
    return true, hitLabel
end

function U.IsForbiddenSecondStackBand(bot, enemy, dist)
    local active, hitLabel = U.IsSecondStackDangerActive(bot, enemy)
    if not active then return false, nil, nil end
    local radius = (C.RAZE and C.RAZE.SECOND_STACK_AVOID_RADIUS) or C.RAZE.STRICT_RADIUS or 190
    local currentBand = U.GetRazeLabelByDistance(dist, radius)
    if currentBand and currentBand ~= hitLabel then
        return true, hitLabel, currentBand
    end
    return false, hitLabel, currentBand
end

function U.IsEnemyRegenerating(enemy)
    if not U.CanQuery(enemy) then return false, nil end
    local mods = {
        "modifier_flask_healing",
        "modifier_clarity_potion",
        "modifier_tango_heal",
        "modifier_bottle_regeneration",
    }
    for _, m in ipairs(mods) do
        if enemy:HasModifier(m) then return true, m end
    end
    return false, nil
end

function U.IsEnemyHighValueRegen(enemy)
    if not U.CanQuery(enemy) then return false end
    if enemy:HasModifier("modifier_flask_healing") then return true end
    if enemy:HasModifier("modifier_clarity_potion") then return true end
    if enemy:HasModifier("modifier_bottle_regeneration") then return true end
    return false
end

function U.GetPlaystyle(bot, enemy, allyCreeps, enemyCreeps)
    if not U.CanQuery(enemy) then return "NEUTRAL" end

    local score = 0
    local myLvl = bot:GetLevel() or 1
    local eLvl = enemy:GetLevel() or 1
    score = score + (myLvl - eLvl) * 1.5

    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    local eq = enemy:GetAbilityByName("nevermore_shadowraze1")
    local myRazeLvl = q and q:GetLevel() or 0
    local eRazeLvl = eq and eq:GetLevel() or 0
    if myRazeLvl > eRazeLvl then score = score + 2.5 end
    if myRazeLvl < eRazeLvl then score = score - 2.5 end

    local myHpPct = bot:GetHealth() / bot:GetMaxHealth()
    local eHpPct = enemy:GetHealth() / enemy:GetMaxHealth()
    score = score + (myHpPct - eHpPct) * 3.2
    if bot:GetHealth() < 400 then score = score - 2.0 end
    if enemy:GetHealth() < 350 then score = score + 0.8 end

    local eHasMango = U.HasItem(enemy, "item_enchanted_mango")
    local myHasMango = U.HasItem(bot, "item_enchanted_mango")
    local eTotalMana = enemy:GetMana() + (eHasMango and 100 or 0)
    local myTotalMana = bot:GetMana() + (myHasMango and 100 or 0)
    if myTotalMana >= 150 and eTotalMana < 75 then score = score + 2.0 end
    if eTotalMana >= 150 and myTotalMana < 75 then score = score - 1.5 end

    local soulDmgDiff = S.GetSoulDamageBonus(bot) - S.GetSoulDamageBonus(enemy)
    score = score + Clamp(soulDmgDiff / 14.0, -2.5, 2.5)

    local itemPowerDiff = U.GetLaneItemPower(bot) - U.GetLaneItemPower(enemy)
    score = score + Clamp(itemPowerDiff, -2.0, 2.0)

    local allyCount = allyCreeps and #allyCreeps or 0
    local enemyCount = enemyCreeps and #enemyCreeps or 0
    score = score + ((allyCount - enemyCount) * 0.25)

    if U.HasEnemyMissedRazeRecently() then score = score + 3.5 end
    if U.HasItem(bot, "item_power_treads") and not U.HasBoots(enemy) then
        score = score + 2.5
    end

    if score <= -2.0 then
        return "PASSIVE"
    elseif score >= 0.8 then
        return "AGGRESSIVE"
    else
        return "NEUTRAL"
    end
end

function U.GetShadowrazeDebuff(unit)
    if not unit then return 0, 0, -1 end
    local numModifiers = unit:NumModifiers()
    if numModifiers and numModifiers > 0 then
        for i = 0, numModifiers - 1 do
            local modName = unit:GetModifierName(i)
            if modName == "modifier_nevermore_shadowraze_debuff" then
                local stacks = unit:GetModifierStackCount(i) or 0
                local remaining = unit:GetModifierRemainingDuration(i) or 0
                return stacks, remaining, i
            end
        end
    end
    return 0, 0, -1
end

function U.PredictPosition(unit, delay)
    local loc = unit:GetLocation()
    if not loc then return loc end
    local stability = 1
    if unit.GetMovementDirectionStability then
        stability = unit:GetMovementDirectionStability() or 1
    end
    if stability < 0.5 then return loc end
    local speed = unit:GetCurrentMovementSpeed() or 0
    local facingRad = math.rad(unit:GetFacing() or 0)
    return Vector(
        loc.x + math.cos(facingRad) * speed * delay,
        loc.y + math.sin(facingRad) * speed * delay,
        loc.z
    )
end

function U.GetAngleDifference(bot, targetLoc)
    local botLoc = bot:GetLocation()
    local facing = bot:GetFacing()
    local angleToTarget = math.deg(Atan2(targetLoc.y - botLoc.y, targetLoc.x - botLoc.x))
    if angleToTarget < 0 then angleToTarget = angleToTarget + 360 end
    local diff = math.abs(facing - angleToTarget)
    if diff > 180 then diff = 360 - diff end
    return diff
end

function U.GetRazeAbilityData(ability)
    if not ability then return nil end
    local name = ability:GetName()
    if name == "nevermore_shadowraze1" then return { center = C.RAZE.NEAR_CENTER, label = "near" } end
    if name == "nevermore_shadowraze2" then return { center = C.RAZE.MID_CENTER,  label = "mid" } end
    if name == "nevermore_shadowraze3" then return { center = C.RAZE.FAR_CENTER,  label = "far" } end
    return nil
end

function U.GetFacingVector(unit)
    local rad = math.rad(unit:GetFacing() or 0)
    return Vector(math.cos(rad), math.sin(rad), 0)
end

function U.GetRazeCircleCenter(bot, centerDistance)
    local loc = bot:GetLocation()
    local forward = U.GetFacingVector(bot)
    return Vector(
        loc.x + forward.x * centerDistance,
        loc.y + forward.y * centerDistance,
        loc.z
    )
end

function U.GetRazeHitErrorWithCurrentFacing(bot, targetLoc, centerDistance)
    local center = U.GetRazeCircleCenter(bot, centerDistance)
    return U.DistanceBetweenLocations(center, targetLoc)
end

function U.GetRazeHitErrorWithDesiredFacing(bot, targetLoc, centerDistance)
    local dist = GetUnitToLocationDistance(bot, targetLoc)
    return math.abs(dist - centerDistance)
end

function U.IsRazeAbilityCastable(bot, ability)
    if not ability or not ability:IsFullyCastable() then return false end
    return bot:GetMana() >= 75
end

function U.WillRazeHit(bot, ability, target, delay, strict)
    if not ability or not target or not target:IsAlive() then return false end
    local data = U.GetRazeAbilityData(ability)
    if not data then return false end
    local predicted = U.PredictPosition(target, delay or C.RAZE.CAST_POINT)
    local error = U.GetRazeHitErrorWithCurrentFacing(bot, predicted, data.center)
    local limit = strict and C.RAZE.STRICT_RADIUS or C.RAZE.HIT_RADIUS
    return error <= limit, error, predicted
end

function U.GetBestRaze(bot, target, mode, isLethalChase, forceExtend)
    if bot:GetMana() < 75 then return nil, nil, nil end
    if not U.CanQuery(target) then return nil, nil, nil end

    isLethalChase = isLethalChase or false
    forceExtend = forceExtend or false

    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    local w = bot:GetAbilityByName("nevermore_shadowraze2")
    local e = bot:GetAbilityByName("nevermore_shadowraze3")

    local stacks, rem_time = U.GetShadowrazeDebuff(target)
    local lowHpFinish = target:GetHealth() <= 380
    local lethalWithTwo = U.GetTwoRazeDamage(bot, target) >= target:GetHealth() * 0.95
    local interruptRegen = U.IsEnemyHighValueRegen(target)
    local enemyMissed = U.HasEnemyMissedRazeRecently()
    local secondStackActive, safeReplyLabel = U.IsSecondStackDangerActive(bot, target)
    local mustKillNow = lethalWithTwo or lowHpFinish or isLethalChase or forceExtend

    if stacks > 0 and stacks < 2 and rem_time > C.RAZE.EXTEND_AT and not mustKillNow then
        return nil, nil, nil
    end

    local predLoc = U.PredictPosition(target, C.RAZE.PREDICT_DELAY)
    local angleDiff = U.GetAngleDifference(bot, predLoc)
    local myDist = GetUnitToLocationDistance(bot, predLoc)
    local bootsAdvantage = U.HasBoots(bot) and not U.HasBoots(target)

    local candidates = {
        { ability = q, center = C.RAZE.NEAR_CENTER, label = "near" },
        { ability = w, center = C.RAZE.MID_CENTER,  label = "mid"  },
        { ability = e, center = C.RAZE.FAR_CENTER,  label = "far"  },
    }

    local best = nil
    local bestScore = math.huge

    for _, candidate in ipairs(candidates) do
        local ability = candidate.ability
        local data = U.GetRazeAbilityData(ability)
        if data and U.IsRazeAbilityCastable(bot, ability) then
            local allow = true

            if secondStackActive and safeReplyLabel and data.label ~= safeReplyLabel then
                allow = false
            end

            if data.label == "far" and mode == "NEUTRAL" and stacks == 0
               and not secondStackActive
               and not U.IsEnemyCastingRaze(target)
               and not interruptRegen and not enemyMissed and not mustKillNow then
                allow = false
            end

            if allow then
                local plannedError = U.GetRazeHitErrorWithDesiredFacing(bot, predLoc, data.center)
                local limit = C.RAZE.STRICT_RADIUS
                if stacks >= 2 or mustKillNow or forceExtend then limit = C.RAZE.HIT_RADIUS end
                if interruptRegen then limit = C.RAZE.HIT_RADIUS end
                if secondStackActive then limit = C.RAZE.HIT_RADIUS end

                if data.label == "near" and not isLethalChase and not forceExtend then
                    local realDist = GetUnitToLocationDistance(bot, predLoc)
                    if realDist > (C.RAZE.NEAR_CENTER + C.RAZE.STRICT_RADIUS) then
                        plannedError = math.huge
                    end
                end

                if data.label == "near" and not mustKillNow then
                    if U.HasStackAndShouldFearNear(bot, target) then
                        plannedError = math.huge
                    end
                end

                if plannedError <= limit then
                    local score = plannedError

                    if secondStackActive and safeReplyLabel and data.label == safeReplyLabel then
                        score = score - 140
                    elseif stacks == 0 and not mustKillNow then
                        if data.label == "mid" then score = score - 60 end
                        if data.label == "far" then score = score + 20 end
                        if data.label == "near" then score = score + 10 end
                    else
                        local distDiff = math.abs(myDist - data.center)
                        score = score - math.max(0, 80 - distDiff * 0.5)
                        if stacks >= C.FINISH.MIN_STACKS_FOR_CLOSE and data.label == "near" then
                            score = score - 80
                        end
                    end

                    if forceExtend and bootsAdvantage then
                        if data.label == "far" then score = score + 120 end
                        if data.label == "mid" then score = score - 90 end
                    elseif forceExtend and not bootsAdvantage then
                        if data.label == "mid" then score = score - 30 end
                    end

                    if mustKillNow then
                        score = score - 200
                        local distDiff2 = math.abs(myDist - data.center)
                        if distDiff2 < 80 then score = score - 50 end
                    elseif forceExtend then
                        score = score - 150
                    elseif stacks > 0 and rem_time <= C.RAZE.EXTEND_AT + 0.6 then
                        score = score - 110
                    elseif stacks >= 2 then
                        score = score - 45
                    end

                    if interruptRegen then score = score - 130 end
                    if enemyMissed then score = score - 55 end

                    if score < bestScore then
                        bestScore = score
                        best = { ability = ability, data = data, predLoc = predLoc, limit = limit }
                    end
                end
            end
        end
    end

    if best then
        if angleDiff > C.RAZE.MAX_ANGLE_TO_CAST then
            return best.ability, "TURN", best.predLoc
        end
        local currentError = U.GetRazeHitErrorWithCurrentFacing(bot, best.predLoc, best.data.center)
        if currentError <= best.limit then
            return best.ability, "CAST", best.predLoc
        end
        return best.ability, "TURN", best.predLoc
    end

    return nil, nil, nil
end

function U.GetRazeSetupPosition(bot, target)
    if not U.CanQuery(target) then return nil end

    local targetLoc = U.PredictPosition(target, 0.35)
    local botLoc = bot:GetLocation()
    local myDist = GetUnitToLocationDistance(bot, targetLoc)
    local stacks = U.GetShadowrazeDebuff(target)
    local secondStackActive, safeReplyLabel = U.IsSecondStackDangerActive(bot, target)
    local bestCenter = nil
    local bestScore = math.huge
    local bootsAdvantage = U.HasBoots(bot) and not U.HasBoots(target)

    if secondStackActive and safeReplyLabel then
        local forcedAbility = nil
        if safeReplyLabel == "near" then forcedAbility = bot:GetAbilityByName("nevermore_shadowraze1") end
        if safeReplyLabel == "mid"  then forcedAbility = bot:GetAbilityByName("nevermore_shadowraze2") end
        if safeReplyLabel == "far"  then forcedAbility = bot:GetAbilityByName("nevermore_shadowraze3") end
        if forcedAbility and U.IsRazeAbilityCastable(bot, forcedAbility) then
            bestCenter = U.GetRazeCenterByLabel(safeReplyLabel)
        end
    end

    if not bestCenter then
        local abilities = {
            bot:GetAbilityByName("nevermore_shadowraze2"),
            bot:GetAbilityByName("nevermore_shadowraze3"),
            bot:GetAbilityByName("nevermore_shadowraze1"),
        }
        for _, ability in ipairs(abilities) do
            local data = U.GetRazeAbilityData(ability)
            if data and U.IsRazeAbilityCastable(bot, ability) then
                local distDiff = math.abs(myDist - data.center)
                local score = distDiff
                if stacks == 0 then
                    if data.label == "mid" then score = score - 80 end
                    if data.label == "far" then score = score + 30 end
                    if data.label == "near" then score = score + 20 end
                else
                    if data.label == "mid" then score = score - 15 end
                end
                if data.label == "near" and U.HasStackAndShouldFearNear(bot, target) then
                    score = score + 9999
                end
                if bootsAdvantage then
                    if data.label == "far" then score = score + 80 end
                    if data.label == "mid" then score = score - 50 end
                end
                if score < bestScore then
                    bestScore = score
                    bestCenter = data.center
                end
            end
        end
    end

    if not bestCenter then bestCenter = C.RAZE.MID_CENTER end

    local dir = botLoc - targetLoc
    if U.DistanceBetweenLocations(botLoc, targetLoc) < 1 then
        dir = U.GetFountain(bot) - botLoc
    end
    dir = dir:Normalized()
    return targetLoc + dir * bestCenter
end

function U.EnemyCanUseRaze(enemy)
    if not U.CanQuery(enemy) then return false end
    local totalMana = enemy:GetMana() + (U.HasItem(enemy, "item_enchanted_mango") and 100 or 0)
    if totalMana < 75 then return false end
    local q = enemy:GetAbilityByName("nevermore_shadowraze1")
    local w = enemy:GetAbilityByName("nevermore_shadowraze2")
    local e = enemy:GetAbilityByName("nevermore_shadowraze3")
    if (q and q:IsFullyCastable()) or (w and w:IsFullyCastable()) or (e and e:IsFullyCastable()) then
        return true
    end
    return false
end

function U.GetRetreatPositionFromEnemySF(bot, enemy)
    local botLoc = bot:GetLocation()
    local enemyLoc = enemy:GetLocation()
    local fountain = U.GetFountain(bot)
    local away = botLoc - enemyLoc
    if U.DistanceBetweenLocations(botLoc, enemyLoc) < 1 then
        away = fountain - botLoc
    end
    away = away:Normalized()
    local toFountain = (fountain - botLoc):Normalized()
    return botLoc + away * 680 + toFountain * 360
end

function U.ShouldRetreatFromEnemyRazeStack(bot, enemy)
    if not U.CanQuery(enemy) then return false, nil end
    if not U.EnemyCanUseRaze(enemy) then return false, nil end

    local dist = GetUnitToLocationDistance(enemy, bot:GetLocation())
    local stacks, rem_time = U.GetShadowrazeDebuff(bot)

    if stacks >= 2 and rem_time > C.RAZE.RETREAT_MIN_REMAIN then
        if dist <= (C.RAZE.FAR_CENTER + C.RAZE.HIT_RADIUS) then
            return true, U.GetRetreatPositionFromEnemySF(bot, enemy)
        end
    end

    if stacks >= 1 and rem_time > C.RAZE.RETREAT_MIN_REMAIN then
        local myHpPct = bot:GetHealth() / bot:GetMaxHealth()
        local eHpPct = enemy:GetHealth() / enemy:GetMaxHealth()
        local canTradeBack = bot:GetMana() >= 75
        local hpAdvantage = myHpPct > eHpPct or (bot:GetHealth() - enemy:GetHealth()) > 80
        if canTradeBack and hpAdvantage then
            return false, nil
        end

        local forbidden, hitLabel, currentBand = U.IsForbiddenSecondStackBand(bot, enemy, dist)
        if forbidden then
            return true, U.GetRetreatPositionFromEnemySF(bot, enemy)
        end

        if stacks == 1 and hitLabel == "near" and currentBand == "near" then
            return false, nil
        end

        return false, nil
    end

    local myOneRaze = U.GetNRazeDamage(bot, enemy, 1)
    local canKillBack = myOneRaze >= enemy:GetHealth()
    local radius = (C.RAZE and C.RAZE.SECOND_STACK_AVOID_RADIUS) or C.RAZE.STRICT_RADIUS or 190
    local currentBand = U.GetRazeLabelByDistance(dist, radius)

    if currentBand == "near" and not canKillBack then
        return true, U.GetRetreatPositionFromEnemySF(bot, enemy)
    end

    if (currentBand == "mid" or currentBand == "far")
        and not U.CanAcceptSingleRazeTrade(bot, enemy)
        and not canKillBack then
        return true, U.GetRetreatPositionFromEnemySF(bot, enemy)
    end

    return false, nil
end

function U.SwitchTreadsIfNeeded(bot, targetStat)
    local treadsSlot = bot:FindItemSlot("item_power_treads")
    if treadsSlot < 0 or treadsSlot > 5 then return end
    local pt = bot:GetItemInSlot(treadsSlot)
    if not pt or not pt:IsFullyCastable() then return end

    if not bot._pt_state then bot._pt_state = 0 end

    local current = bot._pt_state
    if type(pt.GetPowerTreadsStat) == "function" then
        current = pt:GetPowerTreadsStat()
        bot._pt_state = current
    end

    if current ~= targetStat then
        if GameTime() > (bot._lastTreadSwitchTime or 0) + 0.15 then
            bot:Action_UseAbility(pt)
            bot._pt_state = (bot._pt_state + 1) % 3
            bot._lastTreadSwitchTime = GameTime()
        end
    end
end

function U.GetRazeSetupPositionForAbility(bot, target, centerDistance)
    if not target then return bot:GetLocation() end
    local targetLoc = U.PredictPosition(target, 0.35)
    local botLoc = bot:GetLocation()
    local dir = botLoc - targetLoc
    if U.DistanceBetweenLocations(botLoc, targetLoc) < 1 then
        dir = U.GetFountain(bot) - botLoc
    end
    dir = dir:Normalized()
    return targetLoc + dir * centerDistance
end

function U.GetTwoRazeDamage(bot, target)
    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if not q or q:GetLevel() == 0 then return 0 end
    local baseDmg = q:GetSpecialValueInt("shadowraze_damage")
    local stackDmg = q:GetSpecialValueInt("stack_bonus_damage")
    local stacks = U.GetShadowrazeDebuff(target)
    local firstRazeDmg = baseDmg + (stacks * stackDmg)
    local secondRazeDmg = baseDmg + ((stacks + 1) * stackDmg)
    local actual1 = target:GetActualIncomingDamage(firstRazeDmg, DAMAGE_TYPE_MAGICAL)
    local actual2 = target:GetActualIncomingDamage(secondRazeDmg, DAMAGE_TYPE_MAGICAL)
    return actual1 + actual2
end

function U.GetNRazeDamage(bot, target, razeCount)
    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if not q or q:GetLevel() == 0 then return 0 end
    local baseDmg = q:GetSpecialValueInt("shadowraze_damage")
    local stackDmg = q:GetSpecialValueInt("stack_bonus_damage")
    local stacks = U.GetShadowrazeDebuff(target)
    local totalDmg = 0
    for i = 1, razeCount do
        local currentStacks = stacks + (i - 1)
        local rawDmg = baseDmg + (currentStacks * stackDmg)
        local actual = target:GetActualIncomingDamage(rawDmg, DAMAGE_TYPE_MAGICAL)
        totalDmg = totalDmg + actual
    end
    return totalDmg
end

function U.CanKillEnemyWithTwoRazes(bot, enemy)
    if not bot or not enemy or not U.CanQuery(enemy) then return false end
    return U.GetTwoRazeDamage(bot, enemy) >= enemy:GetHealth()
end

function U.EnemyHasTwoRazeManaThreat(enemy)
    if not enemy or not U.CanQuery(enemy) then return false end
    if not U.EnemyHasRaze(enemy) then return false end
    local manaThreat = U.GetPotentialManaForRaze(enemy)
    if manaThreat >= ((C.BOOT_FEAR and C.BOOT_FEAR.TWO_RAZE_MANA_COST) or 150) then
        return true
    end
    local charges = U.GetStickCharges(enemy)
    if charges >= ((C.BOOT_FEAR and C.BOOT_FEAR.STICK_CHARGES_THREAT) or 10) then
        return true
    end
    return false
end

function U.ShouldFearBootsMidRaze(bot, enemy)
    if not bot or not enemy or not U.CanQuery(enemy) then return false end
    if U.HasBoots(bot) then return false end
    if not U.HasBoots(enemy) then return false end
    if U.CanKillEnemyWithTwoRazes(bot, enemy) then return false end
    if not U.EnemyHasTwoRazeManaThreat(enemy) then return false end
    return true
end

function U.GetEnemyRazeBurstDamage(bot, enemy, razeCount)
    razeCount = razeCount or 2
    if not U.CanQuery(enemy) then return 0 end
    local eq = enemy:GetAbilityByName("nevermore_shadowraze1")
    if not eq or eq:GetLevel() == 0 then return 0 end
    local baseDmg = eq:GetSpecialValueInt("shadowraze_damage") or 0
    local stackDmg = eq:GetSpecialValueInt("stack_bonus_damage") or 0
    local myStacks = U.GetShadowrazeDebuff(bot) or 0
    local totalDmg = 0
    for i = 1, razeCount do
        local stk = myStacks + (i - 1)
        local rawDmg = baseDmg + (stk * stackDmg)
        local actual = bot:GetActualIncomingDamage(rawDmg, DAMAGE_TYPE_MAGICAL)
        totalDmg = totalDmg + actual
    end
    return totalDmg
end

function U.HasAnyHealing(bot)
    if bot:HasModifier("modifier_flask_healing") then return true end
    if bot:HasModifier("modifier_tango_heal") then return true end
    if U.HasItem(bot, "item_flask") then return true end
    if U.HasItem(bot, "item_tango") then return true end
    return false
end

function U.IsActivelyHealing(bot)
    if bot:HasModifier("modifier_flask_healing") then return true end
    if bot:HasModifier("modifier_tango_heal") then return true end
    return false
end

function U.IsCourierBringSalve(bot)
    local courier = GetCourier(0)
    if not courier then return false, nil end
    if not courier:IsAlive() then return false, nil end
    local hasSalve = false
    for i = 0, 8 do
        local item = courier:GetItemInSlot(i)
        if item and item:GetName() == "item_flask" then
            hasSalve = true
            break
        end
    end
    if not hasSalve then return false, nil end
    local courierLoc = courier:GetLocation()
    local botLoc = bot:GetLocation()
    local dist = U.DistanceBetweenLocations(botLoc, courierLoc)
    if dist <= C.EMERGENCY.COURIER_SEARCH_RANGE then
        return true, courierLoc
    end
    return false, nil
end

function U.GetEmergencyRetreatReason(bot, enemyHero)
    local hp = bot:GetHealth()
    if U.HasAnyHealing(bot) then return nil end
    local threat1 = 0
    local threat2 = 0
    if enemyHero and U.CanQuery(enemyHero) then
        threat1 = U.GetEnemyRazeBurstDamage(bot, enemyHero, 1)
        threat2 = U.GetEnemyRazeBurstDamage(bot, enemyHero, 2)
    end
    local isInKillRange = false
    if threat1 > 0 and hp <= threat1 * C.EMERGENCY.SINGLE_RAZE_FACTOR then isInKillRange = true end
    if threat2 > 0 and hp <= threat2 * C.EMERGENCY.RAZE_KILL_FACTOR then isInKillRange = true end
    if hp <= C.EMERGENCY.MIN_HP_ABSOLUTE then isInKillRange = true end
    if not isInKillRange then return nil end
    local courierHasSalve, courierLoc = U.IsCourierBringSalve(bot)
    if courierHasSalve and courierLoc then
        local dist = U.DistanceBetweenLocations(bot:GetLocation(), courierLoc)
        if dist <= C.EMERGENCY.COURIER_MEET_RANGE then
            return "COURIER", courierLoc
        end
    end
    return "FOUNTAIN", nil
end

function U.IsInEnemyRazeKillThreat(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    local hp = bot:GetHealth()
    local threat1 = U.GetEnemyRazeBurstDamage(bot, enemyHero, 1)
    local threat2 = U.GetEnemyRazeBurstDamage(bot, enemyHero, 2)
    if threat1 > 0 and hp <= threat1 * SAFE_DISTANCE.SINGLE_KILL_FACTOR then return true end
    if threat2 > 0 and hp <= threat2 * SAFE_DISTANCE.KILL_THREAT_FACTOR then return true end
    local critFactor = SAFE_DISTANCE.CRITICAL_HP_FACTOR or 1.05
    if threat1 > 0 and hp <= threat1 * critFactor then return true end
    return false
end

function U.GetSafeDistancePosition(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return nil end
    local botLoc = bot:GetLocation()
    local enemyLoc = enemyHero:GetLocation()
    local dist = U.DistanceBetweenLocations(botLoc, enemyLoc)
    local hp = bot:GetHealth()
    local threat1 = U.GetEnemyRazeBurstDamage(bot, enemyHero, 1)
    local isCritical = (threat1 > 0 and hp <= threat1 * SAFE_DISTANCE.CRITICAL_HP_FACTOR)
    local minDist = SAFE_DISTANCE.MIN_DISTANCE_FROM_ENEMY
    if isCritical then
        minDist = SAFE_DISTANCE.MIN_DISTANCE_CRITICAL or 950
    end
    if dist >= minDist then return nil end
    local fountain = U.GetFountain(bot)
    local away = botLoc - enemyLoc
    if dist < 1 then away = fountain - botLoc end
    away = away:Normalized()
    local toFountain = (fountain - botLoc):Normalized()
    local moveAmount = minDist - dist + 80
    local awayWeight = isCritical and 0.5 or 0.7
    local fountainWeight = isCritical and 0.5 or 0.3
    return botLoc + away * moveAmount * awayWeight + toFountain * moveAmount * fountainWeight
end

function U.ShouldApproachForNearRazeFinish(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false, nil end
    if bot:GetMana() < 75 then return false, nil end
    if U.HasStackAndShouldFearNear(bot, enemyHero) then return false, nil end
    local secondStackActive, hitLabel = U.IsSecondStackDangerActive(bot, enemyHero)
    if secondStackActive and hitLabel ~= "near" then return false, nil end
    local myHpPct = bot:GetHealth() / bot:GetMaxHealth()
    if myHpPct < C.FINISH.MIN_HP_PCT_FOR_CLOSE then return false, nil end
    local stacks, rem_time = U.GetShadowrazeDebuff(enemyHero)
    if stacks < C.FINISH.MIN_STACKS_FOR_CLOSE then return false, nil end
    if rem_time <= 0.3 then return false, nil end
    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if not q or not U.IsRazeAbilityCastable(bot, q) then return false, nil end
    local baseDmg = q:GetSpecialValueInt("shadowraze_damage") or 0
    local stackDmg = q:GetSpecialValueInt("stack_bonus_damage") or 0
    local razeDmg = baseDmg + (stacks * stackDmg)
    local actualDmg = enemyHero:GetActualIncomingDamage(razeDmg, DAMAGE_TYPE_MAGICAL)
    local enemyHP = enemyHero:GetHealth()
    local atkDmg = bot:GetAttackDamage() or 0
    local actualAtk = enemyHero:GetActualIncomingDamage(atkDmg, DAMAGE_TYPE_PHYSICAL)
    if actualDmg >= enemyHP * 0.85 or (actualDmg + actualAtk) >= enemyHP then
        local botLoc = bot:GetLocation()
        local enemyLoc = enemyHero:GetLocation()
        local dist = U.DistanceBetweenLocations(botLoc, enemyLoc)
        if dist <= C.FINISH.CLOSE_APPROACH_RANGE then
            local dir = (enemyLoc - botLoc):Normalized()
            local approachLoc = enemyLoc - dir * C.RAZE.NEAR_CENTER
            return true, approachLoc
        end
    end
    return false, nil
end

function U.ShouldForceSalve(bot)
    if bot:HasModifier("modifier_flask_healing") then return false end
    if bot:HasModifier("modifier_tango_heal") then return false end
    local hpPct = bot:GetHealth() / bot:GetMaxHealth()
    if hpPct > C.FORCED_SALVE.HP_PCT_THRESHOLD then return false end
    local flask = U.GetActiveItemByName(bot, "item_flask")
    if not flask then return false end
    return true
end

U._lastAllyCreepHP = {}

function U.UpdateAllyCreepHealthTracking(allyCreeps)
    local newTracker = {}
    for _, c in pairs(allyCreeps or {}) do
        if c and c:IsAlive() then
            local key = tostring(c)
            newTracker[key] = {
                hp = c:GetHealth(),
                prevHp = (U._lastAllyCreepHP[key] and U._lastAllyCreepHP[key].hp) or c:GetHealth(),
                unit = c,
            }
        end
    end
    U._lastAllyCreepHP = newTracker
end

function U.ShouldRetreatFromT1LastCreep(bot, allyCreeps, enemyTowers, enemyHero)
    if not enemyTowers or #enemyTowers == 0 then return false end
    if not allyCreeps or #allyCreeps == 0 then return false end
    local t1Tower = nil
    for _, tower in pairs(enemyTowers) do
        if tower:IsAlive() then
            local name = tower:GetUnitName() or ""
            if name:find("tower1") then
                t1Tower = tower
                break
            end
        end
    end
    if not t1Tower then
        t1Tower = enemyTowers[1]
        if not t1Tower or not t1Tower:IsAlive() then return false end
    end
    local botDist = GetUnitToLocationDistance(bot, t1Tower:GetLocation())
    if botDist > 1000 then return false end
    local towerAggroRadius = 800
    local allyNearTower = {}
    for _, c in pairs(allyCreeps) do
        if c and c:IsAlive() then
            local name = c:GetUnitName() or ""
            local isSiege = name:find("siege") or name:find("catapult")
            if not isSiege then
                if GetUnitToLocationDistance(t1Tower, c:GetLocation()) <= towerAggroRadius then
                    table.insert(allyNearTower, c)
                end
            end
        end
    end
    if #allyNearTower == 1 then
        local creep = allyNearTower[1]
        local key = tostring(creep)
        local tracked = U._lastAllyCreepHP[key]
        if tracked then
            if creep:GetHealth() < tracked.prevHp then
                if enemyHero and U.CanQuery(enemyHero) then
                    local twoRazeDmg = U.GetTwoRazeDamage(bot, enemyHero)
                    local atkDmg = bot:GetAttackDamage() or 0
                    local enemyHp = enemyHero:GetHealth()
                    if (twoRazeDmg + atkDmg * 2) >= enemyHp and bot:GetMana() > 150 then
                        return false
                    end
                end
                return true
            end
        end
        if creep:GetHealth() < 200 then
            if enemyHero and U.CanQuery(enemyHero) then
                local twoRazeDmg = U.GetTwoRazeDamage(bot, enemyHero)
                local atkDmg = bot:GetAttackDamage() or 0
                local enemyHp = enemyHero:GetHealth()
                if (twoRazeDmg + atkDmg * 2) >= enemyHp and bot:GetMana() > 150 then
                    return false
                end
            end
            return true
        end
    end
    if #allyNearTower == 0 and botDist < 850 then
        return true
    end
    return false
end

U._lastGlyphTime = -math.huge

function U.IsGlyphAvailable(bot)
    local now = GameTime()
    if now < C.GLYPH.AVAILABLE_AT then return false end
    if GetGlyphCooldown and type(GetGlyphCooldown) == "function" then
        local cd = GetGlyphCooldown()
        if cd and cd > 0 then return false end
    else
        if (now - U._lastGlyphTime) < C.GLYPH.COOLDOWN then return false end
    end
    return true
end

function U.UseGlyph(bot)
    if bot.ActionImmediate_Glyph then
        bot:ActionImmediate_Glyph()
    elseif Glyph then
        Glyph()
    end
    U._lastGlyphTime = GameTime()
end

function U.ShouldUseGlyphDefensive(bot, allyTowers)
    if not U.IsGlyphAvailable(bot) then return false end
    for _, tower in pairs(allyTowers or {}) do
        if tower and tower:IsAlive() then
            local name = tower:GetUnitName() or ""
            if name:find("tower1") then
                local hp = tower:GetHealth()
                local maxHp = tower:GetMaxHealth()
                local hpPct = hp / maxHp
                if hpPct <= C.GLYPH.T1_HP_PCT_THRESHOLD or hp <= C.GLYPH.T1_HP_ABS_THRESHOLD then
                    local projs = tower:GetIncomingTrackingProjectiles()
                    local isUnderAttack = (projs and #projs > 0)
                    if not isUnderAttack then
                        local nearbyEnemies = tower:GetNearbyLaneCreeps(900, true)
                        if nearbyEnemies and #nearbyEnemies > 0 then isUnderAttack = true end
                        if not isUnderAttack then
                            local nearbyHeroes = tower:GetNearbyHeroes(900, true, BOT_MODE_NONE)
                            if nearbyHeroes and #nearbyHeroes > 0 then isUnderAttack = true end
                        end
                    end
                    if isUnderAttack then return true end
                end
            end
        end
    end
    return false
end

function U.ShouldUseGlyphForKillDive(bot, enemyHero, enemyTowers, allyTowers, allyCreeps)
    if not U.IsGlyphAvailable(bot) then return false end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    local twoRazeDmg = U.GetTwoRazeDamage(bot, enemyHero)
    local atkDmg = bot:GetAttackDamage() or 0
    local enemyHp = enemyHero:GetHealth()
    if not ((twoRazeDmg + atkDmg * 2) >= enemyHp and bot:GetMana() >= 150) then
        return false
    end
    local enemyLoc = enemyHero:GetLocation()
    local t1Tower = nil
    for _, tower in pairs(enemyTowers or {}) do
        if tower:IsAlive() then
            local name = tower:GetUnitName() or ""
            if name:find("tower1") then
                if GetUnitToLocationDistance(tower, enemyLoc) <= C.GLYPH.KILL_DIVE_RANGE then
                    t1Tower = tower
                    break
                end
            end
        end
    end
    if not t1Tower then return false end
    local hasAllyCreepUnderT1 = false
    for _, c in pairs(allyCreeps or {}) do
        if c and c:IsAlive() then
            if GetUnitToLocationDistance(t1Tower, c:GetLocation()) <= 750 then
                hasAllyCreepUnderT1 = true
                break
            end
        end
    end
    if not hasAllyCreepUnderT1 then
        return false
    end
    local botDist = GetUnitToLocationDistance(bot, enemyLoc)
    if botDist > 1100 then return false end
    local botUnderTower = false
    for _, tower in pairs(enemyTowers or {}) do
        if tower:IsAlive() and GetUnitToLocationDistance(bot, tower:GetLocation()) <= 880 then
            botUnderTower = true
            break
        end
    end
    if not botUnderTower then return false end
    return true
end

function U.HasTreadsAdvantage(bot, enemy)
    if not bot then return false end
    if not U.HasItem(bot, "item_power_treads") then return false end
    if enemy and U.CanQuery(enemy) and U.HasBoots(enemy) then return false end
    return true
end

function U.ShouldPushWave(bot, enemy, allyCreeps, enemyCreeps)
    if not U.HasTreadsAdvantage(bot, enemy) then return false end
    local myHpPct = bot:GetHealth() / bot:GetMaxHealth()
    if myHpPct < (C.PUSH.MIN_HP_PCT_TO_PUSH or 0.50) then return false end
    if not enemyCreeps or #enemyCreeps == 0 then return false end
    return true
end

function U.HasStackAndShouldFearNear(bot, enemy)
    if not enemy or not U.CanQuery(enemy) then return false end
    if not U.EnemyCanUseRaze(enemy) then return false end
    local stacks, rem_time = U.GetShadowrazeDebuff(bot)
    if stacks < 1 then return false end
    if rem_time <= C.RAZE.RETREAT_MIN_REMAIN then return false end
    local secondStackActive, hitLabel = U.IsSecondStackDangerActive(bot, enemy)
    if stacks == 1 and secondStackActive and hitLabel == "near" then
        return false
    end
    return true
end

function U.GetMinDistWithStack(bot, enemy)
    if not U.HasStackAndShouldFearNear(bot, enemy) then return 0 end
    return (C.STACK_NEAR_FEAR and C.STACK_NEAR_FEAR.MIN_DISTANCE) or 470
end

function U.ClampMinDistFromEnemy(bot, enemy, loc)
    if not enemy or not U.CanQuery(enemy) then return loc end
    local minDist = U.GetMinDistWithStack(bot, enemy)
    if minDist <= 0 then return loc end
    local enemyLoc = enemy:GetLocation()
    local dist = U.DistanceBetweenLocations(loc, enemyLoc)
    if dist >= minDist then return loc end
    local dir = loc - enemyLoc
    if dist < 1 then
        dir = U.GetFountain(bot) - enemyLoc
    end
    dir = dir:Normalized()
    return enemyLoc + dir * (minDist + ((C.STACK_NEAR_FEAR and C.STACK_NEAR_FEAR.RETREAT_BUFFER) or 60))
end

function U.CanOneShotEnemyHero(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false, nil end
    local atkDmg = bot:GetAttackDamage() or 0
    local actualDmg = enemyHero:GetActualIncomingDamage(atkDmg, DAMAGE_TYPE_PHYSICAL)
    if actualDmg >= enemyHero:GetHealth() then
        return true, "ATTACK"
    end
    return false, nil
end

function U.CanKillEnemyWithOneRaze(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false, nil end
    local mana = bot:GetMana() + (U.GetStickCharges(bot) * 15) + (U.HasItem(bot, "item_enchanted_mango") and 100 or 0)
    if mana < 75 then return false, nil end

    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    local w = bot:GetAbilityByName("nevermore_shadowraze2")
    local e = bot:GetAbilityByName("nevermore_shadowraze3")
    local candidates = {
        { ability = q, label = "near" },
        { ability = w, label = "mid" },
        { ability = e, label = "far" },
    }

    for _, c in ipairs(candidates) do
        local ability = c.ability
        if ability and U.IsRazeAbilityCastable(bot, ability) then
            local willHit = U.WillRazeHit(bot, ability, enemyHero, C.RAZE.CAST_POINT, false)
            local oneRazeDmg = U.GetNRazeDamage(bot, enemyHero, 1)
            if willHit and oneRazeDmg >= enemyHero:GetHealth() then
                return true, c.label
            end
        end
    end
    return false, nil
end

function U.CanQuickTurnKillWithRaze(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false, nil end
    local mana = bot:GetMana() + (U.GetStickCharges(bot) * 15) + (U.HasItem(bot, "item_enchanted_mango") and 100 or 0)
    if mana < 75 then return false, nil end

    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    local w = bot:GetAbilityByName("nevermore_shadowraze2")
    local e = bot:GetAbilityByName("nevermore_shadowraze3")
    local candidates = {
        { ability = q, label = "near" },
        { ability = w, label = "mid" },
        { ability = e, label = "far" },
    }

    for _, c in ipairs(candidates) do
        local ability = c.ability
        if ability and U.IsRazeAbilityCastable(bot, ability) then
            local willHit, _, predLoc = U.WillRazeHit(bot, ability, enemyHero, C.RAZE.CAST_POINT, false)
            if willHit then
                local oneRazeDmg = U.GetNRazeDamage(bot, enemyHero, 1)
                if oneRazeDmg >= enemyHero:GetHealth() then
                    local angleDiff = U.GetAngleDifference(bot, predLoc)
                    if angleDiff <= 45 then
                        return true, c.label
                    end
                end
            end
        end
    end
    return false, nil
end

function U.IsAggressivePlaystyle(bot, enemyHero, allyCreeps, enemyCreeps)
    if not bot or not enemyHero then return false end
    local style = U.GetPlaystyle(bot, enemyHero, allyCreeps, enemyCreeps)
    return style == "AGGRESSIVE"
end

U.DEBUG = false

function U.Log(...)
end

return U