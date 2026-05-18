-- scripts/vscripts/bots/bot_nevermore.lua

local C = require("bots/nevermore/constants")
local U = require("bots/nevermore/utils")
local S = require("bots/nevermore/souls")
local L = require("bots/nevermore/lasthit")
local P = require("bots/nevermore/positioning")

U.DEBUG = false

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

local State = {
    attackTarget              = nil,
    attackStartTime           = 0,
    deaggroTime               = 0,
    prepTarget                = nil,
    flyingProjectiles         = {},
    firedThisAttack           = false,
    lastAggroTime             = 0,
    aggroPullTime             = 0,
    lastItemUseTime           = 0,
    lastHarassTime            = 0,
    needsTP                   = false,
    aimingRaze                = nil,
    aimingTarget              = nil,
    aimingLoc                 = nil,
    aimingStartTime           = 0,
    aimingValidationRadius    = nil,
    forcedRetreatLoc          = nil,
    forcedRetreatUntil        = 0,
    lastMoveLoc               = nil,
    lastMoveTime              = 0,
    emergencyRetreat          = nil,
    emergencyRetreatStartTime = 0,
    emergencyTPQueued         = false,
    glyphUsedForDive          = false,
    glyphDiveTime             = 0,
    lastForceSalveTime        = 0,
    enemyT1ClosestCreepDist   = nil,
    enemyT1ClosestCreepTime   = 0,
    actionTaken               = false,
    goingToFountain           = false,
    fountainReason            = nil,
    enemyReachedLevel2First   = false,
    heroAttackTarget          = nil,
    heroAttackTime            = 0,
    _lastSalveAutoBuyTime     = 0,
}

local function SmartMove(bot, loc, threshold)
    if not loc then return end
    if State.actionTaken then return end
    threshold = threshold or 60
    local now = GameTime()
    local last = State.lastMoveLoc
    if last and U.DistanceBetweenLocations(last, loc) <= threshold and (now - State.lastMoveTime) < 0.6 then
        return
    end
    State.lastMoveLoc = loc
    State.lastMoveTime = now
    bot:Action_MoveToLocation(loc)
end

local function ClearMoveCache()
    State.lastMoveLoc = nil
    State.lastMoveTime = 0
end

local function ClearRazeState()
    State.aimingRaze = nil
    State.aimingTarget = nil
    State.aimingLoc = nil
    State.aimingStartTime = 0
    State.aimingValidationRadius = nil
end

local function StartRazeCast(ability, target, loc, validationRadius)
    State.aimingRaze = ability
    State.aimingTarget = target
    State.aimingLoc = loc
    State.aimingStartTime = GameTime()
    State.aimingValidationRadius = validationRadius or C.RAZE.HIT_RADIUS
    State.actionTaken = true
end

local function HandleActiveRazeValidation(bot)
    if not State.aimingRaze then return false end
    local now = GameTime()
    if bot:IsUsingAbility() or bot:IsChanneling() then
        if not State.aimingTarget or not State.aimingTarget:IsAlive() then
            bot:Action_ClearActions(true)
            ClearRazeState()
            ClearMoveCache()
            return true
        end

        local elapsed = now - State.aimingStartTime
        local remaining = C.RAZE.CAST_POINT - elapsed
        if remaining < 0.03 then remaining = 0.03 end

        local data = U.GetRazeAbilityData(State.aimingRaze)
        if not data then
            bot:Action_ClearActions(true)
            ClearRazeState()
            ClearMoveCache()
            return true
        end

        local predicted = U.PredictPosition(State.aimingTarget, remaining + 0.03)
        local error = U.GetRazeHitErrorWithCurrentFacing(bot, predicted, data.center)
        local limit = (State.aimingValidationRadius or C.RAZE.HIT_RADIUS) + 50

        if error > limit then
            bot:Action_ClearActions(true)
            ClearRazeState()
            ClearMoveCache()
        end
        return true
    end

    if now > State.aimingStartTime + 1.0 then
        ClearRazeState()
    end

    return false
end

local function SafeClearActions(bot)
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    bot:Action_ClearActions(true)
    ClearMoveCache()
    return true
end

local function BeginForcedRetreat(bot, loc, duration)
    if not loc then return false end
    State.forcedRetreatLoc = loc
    State.forcedRetreatUntil = GameTime() + (duration or 0.75)
    SafeClearActions(bot)
    bot:Action_MoveToLocation(loc)
    State.lastMoveLoc = loc
    State.lastMoveTime = GameTime()
    State.actionTaken = true
    return true
end

local function ClearForcedRetreat()
    State.forcedRetreatLoc = nil
    State.forcedRetreatUntil = 0
end

local function CastOrTurnRaze(bot, ability, actionType, aimLoc, target)
    if not ability then return false end
    if State.actionTaken then return false end

    local data = U.GetRazeAbilityData(ability)
    if data and target and U.CanQuery(target) then
        local distToTarget = GetUnitToLocationDistance(bot, target:GetLocation())
        local distError = math.abs(distToTarget - data.center)
        if distError > C.RAZE.STRICT_RADIUS + 25 then
            return false
        end
    end

    if actionType == "TURN" then
        local botLoc = bot:GetLocation()
        local turnLoc = aimLoc or (target and target:GetLocation()) or botLoc
        local dist = U.DistanceBetweenLocations(botLoc, turnLoc)
        local stepLoc = turnLoc
        if dist > 50 then
            local dir = (turnLoc - botLoc):Normalized()
            stepLoc = botLoc + dir * 12
        end
        SmartMove(bot, stepLoc, 20)
        return true
    elseif actionType == "CAST" then
        U.SwitchTreadsIfNeeded(bot, 1)
        bot:Action_UseAbility(ability)
        StartRazeCast(ability, target, aimLoc, C.RAZE.HIT_RADIUS)
        ClearMoveCache()
        return true
    end

    return false
end

local function GetRazeAbilityByLabel(bot, label)
    if label == "near" then return bot:GetAbilityByName("nevermore_shadowraze1") end
    if label == "mid"  then return bot:GetAbilityByName("nevermore_shadowraze2") end
    if label == "far"  then return bot:GetAbilityByName("nevermore_shadowraze3") end
    return nil
end

local function GetRazeActionType(bot, ability, target)
    if not ability or not target or not U.CanQuery(target) then return nil, nil end
    local willHit, _, predicted = U.WillRazeHit(bot, ability, target, C.RAZE.CAST_POINT, false)
    if not willHit then return nil, predicted end
    if U.GetAngleDifference(bot, predicted) <= C.RAZE.MAX_ANGLE_TO_CAST then
        return "CAST", predicted
    end
    return "TURN", predicted
end

local function GetStickLikeItem(bot)
    local wand = U.GetActiveItemByName(bot, "item_magic_wand")
    if wand and (not wand.GetCurrentCharges or wand:GetCurrentCharges() > 0) then return wand end
    local stick = U.GetActiveItemByName(bot, "item_magic_stick")
    if stick and (not stick.GetCurrentCharges or stick:GetCurrentCharges() > 0) then return stick end
    return nil
end

local function GetPotentialCombatMana(bot)
    local mana = bot:GetMana() or 0
    local wand = U.GetActiveItemByName(bot, "item_magic_wand")
    if wand and wand.GetCurrentCharges then
        mana = mana + (wand:GetCurrentCharges() or 0) * 15
    end
    local stick = U.GetActiveItemByName(bot, "item_magic_stick")
    if stick and stick.GetCurrentCharges then
        mana = mana + (stick:GetCurrentCharges() or 0) * 15
    end
    local mango = U.GetActiveItemByName(bot, "item_enchanted_mango")
    if mango then mana = mana + 100 end
    return mana
end

local function TryUseBurstManaItem(bot, allowMango)
    local item = GetStickLikeItem(bot)
    if not item and allowMango then
        item = U.GetActiveItemByName(bot, "item_enchanted_mango")
    end
    if not item then return false end
    bot:Action_UseAbility(item)
    State.lastItemUseTime = GameTime()
    State.actionTaken = true
    return true
end

local function IsInHeroAttackAnimation(bot)
    if not State.heroAttackTarget then return false end
    if not State.heroAttackTarget:IsAlive() then
        State.heroAttackTarget = nil
        State.heroAttackTime = 0
        return false
    end
    local target = bot:GetAttackTarget()
    if target ~= State.heroAttackTarget then
        State.heroAttackTarget = nil
        State.heroAttackTime = 0
        return false
    end
    local elapsed = GameTime() - State.heroAttackTime
    local bat = bot:GetSecondsPerAttack() or 1.7
    if elapsed < bat + 0.1 then
        return true
    end
    State.heroAttackTarget = nil
    State.heroAttackTime = 0
    return false
end

local function IsSameAttackTarget(bot, target)
    return bot:GetCurrentActionType() == BOT_ACTION_TYPE_ATTACK and bot:GetAttackTarget() == target
end

local function IssueHeroAttack(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    local sameTarget = IsSameAttackTarget(bot, enemyHero)
    if not sameTarget then
        bot:Action_AttackUnit(enemyHero, true)
        ClearMoveCache()
        State.attackTarget = enemyHero
        State.attackStartTime = GameTime()
        State.firedThisAttack = false
    elseif State.attackTarget ~= enemyHero then
        State.attackTarget = enemyHero
        State.attackStartTime = GameTime()
        State.firedThisAttack = false
    end
    State.heroAttackTarget = enemyHero
    State.heroAttackTime = GameTime()
    return true
end

local function IsHeroAttackWindupLocked(bot)
    local target = bot:GetAttackTarget()
    if bot:GetCurrentActionType() ~= BOT_ACTION_TYPE_ATTACK or not target or not target:IsAlive() then
        return false
    end
    if not (target.IsHero and target:IsHero()) then
        return false
    end
    if State.attackTarget ~= target then
        State.attackTarget = target
        State.attackStartTime = GameTime()
        State.firedThisAttack = false
    end
    local elapsed = GameTime() - (State.attackStartTime or 0)
    local ap = bot:GetAttackPoint() or 0
    return elapsed < (ap + 0.06)
end

local function _hasTankCreepUnderTower(tower, allyCreeps)
    if not tower or not tower:IsAlive() then return false end
    for _, c in pairs(allyCreeps or {}) do
        if c and c:IsAlive() then
            local name = c:GetUnitName() or ""
            local isSiege = name:find("siege") or name:find("catapult")
            if not isSiege then
                if GetUnitToLocationDistance(tower, c:GetLocation()) <= 760 then
                    return true
                end
            end
        end
    end
    return false
end

local function GetSafeApproach(bot, targetLoc, enemyTowers, allyCreeps)
    for _, tower in pairs(enemyTowers or {}) do
        if tower:IsAlive() then
            local distToTower = GetUnitToLocationDistance(tower, targetLoc)
            if distToTower < 830 then
                if not _hasTankCreepUnderTower(tower, allyCreeps) then
                    local dir = (targetLoc - tower:GetLocation()):Normalized()
                    return tower:GetLocation() + dir * 885
                end
            end
        end
    end
    return targetLoc
end

local function GetSafeApproachLoose(bot, targetLoc, enemyTowers, allyCreeps)
    for _, tower in pairs(enemyTowers or {}) do
        if tower:IsAlive() then
            local distToTower = GetUnitToLocationDistance(tower, targetLoc)
            if distToTower < 740 then
                if not _hasTankCreepUnderTower(tower, allyCreeps) then
                    local dir = (targetLoc - tower:GetLocation()):Normalized()
                    return tower:GetLocation() + dir * 815
                end
            end
        end
    end
    return targetLoc
end

local function IsSafeToAttack(bot, targetLoc, enemyTowers, allyCreeps)
    local botLoc = bot:GetLocation()
    for _, tower in pairs(enemyTowers or {}) do
        if tower:IsAlive() then
            if not _hasTankCreepUnderTower(tower, allyCreeps) then
                if GetUnitToLocationDistance(tower, targetLoc) < 420 then return false end
                if GetUnitToLocationDistance(tower, botLoc) < 860 then return false end
            end
        end
    end
    return true
end

local function IsSafeToHarass(bot, targetLoc, enemyTowers, allyCreeps)
    local botLoc = bot:GetLocation()
    for _, tower in pairs(enemyTowers or {}) do
        if tower:IsAlive() then
            if not _hasTankCreepUnderTower(tower, allyCreeps) then
                if GetUnitToLocationDistance(tower, targetLoc) < 320 then return false end
                if GetUnitToLocationDistance(tower, botLoc) < 760 then return false end
            end
        end
    end
    return true
end

local function IsSafeToCommitKillAttack(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    for _, tower in pairs(enemyTowers or {}) do
        if tower:IsAlive() then
            local towerToEnemy = GetUnitToLocationDistance(tower, enemyHero:GetLocation())
            if towerToEnemy <= 850 then
                if _hasTankCreepUnderTower(tower, allyCreeps) then
                    return true
                end
                if GetUnitToLocationDistance(bot, tower:GetLocation()) > 810 then
                    return true
                end
                return false
            end
        end
    end
    return true
end

local function GetEnemyT1Tower(enemyTowers)
    for _, tower in pairs(enemyTowers or {}) do
        if tower and tower:IsAlive() then
            local name = tower:GetUnitName() or ""
            if name:find("tower1") then
                return tower
            end
        end
    end
    return nil
end

local function IsBotUnderEnemyT1(bot, enemyTowers)
    local t1 = GetEnemyT1Tower(enemyTowers)
    if not t1 then return false, nil end
    if GetUnitToLocationDistance(bot, t1:GetLocation()) <= 880 then
        return true, t1
    end
    return false, t1
end

local function HasRazeResource(bot)
    return GetPotentialCombatMana(bot) >= 75
end

local function ShouldAllowRiskyT1Commit(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    local underT1, t1 = IsBotUnderEnemyT1(bot, enemyTowers)
    if not underT1 or not t1 then return false end
    if bot:GetLevel() < 5 then return false end
    if not HasRazeResource(bot) then return false end
    local enemyCanPunish = U.EnemyCanUseRaze(enemyHero)
    local atkActual = enemyHero:GetActualIncomingDamage(bot:GetAttackDamage() or 0, DAMAGE_TYPE_PHYSICAL)
    local oneRaze = U.GetNRazeDamage(bot, enemyHero, 1)
    local twoRaze = U.GetTwoRazeDamage(bot, enemyHero)
    local enemyVeryLow = enemyHero:GetHealth() <= (oneRaze + atkActual * 2.0) or enemyHero:GetHealth() <= (twoRaze + atkActual)
    if not enemyCanPunish then return true end
    if enemyVeryLow then return true end
    return false
end

local function TryUseGlyphForT1Retreat(bot, enemyTowers, allyCreeps)
    if not U.IsGlyphAvailable(bot) then return false end
    local underT1, t1 = IsBotUnderEnemyT1(bot, enemyTowers)
    if not underT1 or not t1 then return false end
    if not _hasTankCreepUnderTower(t1, allyCreeps) then return false end
    U.UseGlyph(bot)
    State.actionTaken = true
    return true
end

local function GetExtendedT1RetreatLocation(bot, enemyTowers, enemyCreeps, allyCreeps, mode)
    local safeLoc = P.GetLasthitPosition(bot, enemyCreeps or {}, allyCreeps or {}, nil, mode or "PASSIVE")
    local fountain = P.GetFountain(bot)
    local t1 = GetEnemyT1Tower(enemyTowers)
    if t1 and t1:IsAlive() then
        local dir = (fountain - t1:GetLocation()):Normalized()
        local extra = 150
        safeLoc = t1:GetLocation() + dir * (850 + C.T1_SAFETY.RETREAT_BUFFER + extra)
    end
    return safeLoc
end

local function HandleEnemyT1TowerDeaggro(bot, enemyTowers, allyCreeps, enemyCreeps)
    local underT1, t1 = IsBotUnderEnemyT1(bot, enemyTowers)
    if not underT1 or not t1 then return false end
    local towerAttackTarget = (t1.GetAttackTarget and t1:GetAttackTarget()) or nil
    if towerAttackTarget ~= bot then return false end

    local bestCreep = nil
    local bestDist = math.huge
    for _, c in pairs(allyCreeps or {}) do
        if c and c:IsAlive() then
            local name = c:GetUnitName() or ""
            local isSiege = name:find("siege") or name:find("catapult")
            if not isSiege and GetUnitToLocationDistance(t1, c:GetLocation()) <= 760 then
                local d = GetUnitToLocationDistance(bot, c:GetLocation())
                if d < bestDist then
                    bestDist = d
                    bestCreep = c
                end
            end
        end
    end
    if not bestCreep then return false end

    SafeClearActions(bot)
    bot:Action_AttackUnit(bestCreep, true)
    local fountain = P.GetFountain(bot)
    local safeLoc = bestCreep:GetLocation() + (fountain - bestCreep:GetLocation()):Normalized() * 180
    bot:ActionQueue_MoveToLocation(safeLoc)
    State.forcedRetreatLoc = safeLoc
    State.forcedRetreatUntil = GameTime() + 0.75
    State.lastMoveLoc = safeLoc
    State.lastMoveTime = GameTime()
    State.actionTaken = true
    return true
end

local function IsTowerDiveRazeUnsafe(bot, enemyHero, ability, enemyTowers, allyCreeps)
    if not ability or not enemyHero or not U.CanQuery(enemyHero) then return false end
    local t1 = GetEnemyT1Tower(enemyTowers)
    if not t1 or not t1:IsAlive() then return false end
    if _hasTankCreepUnderTower(t1, allyCreeps) then return false end
    if ShouldAllowRiskyT1Commit(bot, enemyHero, enemyTowers, allyCreeps) then return false end
    local data = U.GetRazeAbilityData(ability)
    if not data then return false end
    local enemyNearTower = GetUnitToLocationDistance(t1, enemyHero:GetLocation()) <= 900
    if not enemyNearTower then return false end
    local botUnderT1 = GetUnitToLocationDistance(bot, t1:GetLocation()) <= 880
    local setupPos = U.GetRazeSetupPositionForAbility(bot, enemyHero, data.center)
    local setupUnderT1 = setupPos and U.DistanceBetweenLocations(setupPos, t1:GetLocation()) < 900
    if botUnderT1 or setupUnderT1 then
        return true
    end
    return false
end

local function HandleMidStackSpacing(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local active, hitLabel = U.IsSecondStackDangerActive(bot, enemyHero)
    if not active or hitLabel ~= "mid" then return false end
    local botLoc = bot:GetLocation()
    local enemyLoc = enemyHero:GetLocation()
    local dist = U.DistanceBetweenLocations(botLoc, enemyLoc)
    local minHold = C.RAZE.NEAR_CENTER + 110
    local maxHold = C.RAZE.FAR_CENTER - 110
    local desired = C.RAZE.MID_CENTER
    if dist >= minHold and dist <= maxHold then return false end
    local dir = botLoc - enemyLoc
    if dist < 1 then
        dir = U.GetFountain(bot) - enemyLoc
    end
    dir = dir:Normalized()
    local holdLoc = enemyLoc + dir * desired
    holdLoc = GetSafeApproachLoose(bot, holdLoc, enemyTowers or {}, allyCreeps or {})
    SmartMove(bot, holdLoc, 35)
    return true
end

local function GetNearRazeAttackFollowupInfo(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false, nil, nil, nil end
    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if not q or q:GetLevel() == 0 then return false, nil, nil, nil end
    local nearRazeDmg = U.GetNRazeDamage(bot, enemyHero, 1)
    local atkRaw = bot:GetAttackDamage() or 0
    local atkActual = enemyHero:GetActualIncomingDamage(atkRaw, DAMAGE_TYPE_PHYSICAL)
    if atkActual <= 0 then return false, nil, nil, nil end
    local hpAfterRaze = enemyHero:GetHealth() - nearRazeDmg
    if hpAfterRaze <= 0 then return false, nearRazeDmg, atkActual, 0 end
    local attacksNeeded = math.ceil(hpAfterRaze / atkActual)
    if attacksNeeded >= 1 and attacksNeeded <= 2 then
        return true, nearRazeDmg, atkActual, attacksNeeded
    end
    return false, nearRazeDmg, atkActual, attacksNeeded
end

local function HandleCloseAttackFinish(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if not HasRazeResource(bot) then return false end
    if U.HasStackAndShouldFearNear(bot, enemyHero) then return false end
    local underT1 = IsBotUnderEnemyT1(bot, enemyTowers)
    if underT1 and not ShouldAllowRiskyT1Commit(bot, enemyHero, enemyTowers, allyCreeps) then
        return false
    end
    local canFinish, _, _, attacksNeeded = GetNearRazeAttackFollowupInfo(bot, enemyHero)
    if not canFinish then return false end
    local canOneShot, _ = U.CanOneShotEnemyHero(bot, enemyHero)
    if U.IsInEnemyRazeKillThreat(bot, enemyHero) and not canOneShot then return false end
    if not IsSafeToCommitKillAttack(bot, enemyHero, enemyTowers, allyCreeps) and not canOneShot then return false end
    local attackRange = bot:GetAttackRange() + 60
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    if dist <= attackRange then
        IssueHeroAttack(bot, enemyHero)
        return true
    end
    if dist <= attackRange + 260 then
        local botLoc = bot:GetLocation()
        local dir = (enemyHero:GetLocation() - botLoc):Normalized()
        local approachLoc = botLoc + dir * math.min(dist - attackRange + 20, 220)
        approachLoc = GetSafeApproachLoose(bot, approachLoc, enemyTowers or {}, allyCreeps or {})
        SmartMove(bot, approachLoc, 35)
        return true
    end
    return false
end

local function HandleLethalTwoRazeSequence(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if GetPotentialCombatMana(bot) < 150 then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if bot:GetMana() < 75 and TryUseBurstManaItem(bot, true) then return true end

    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    local w = bot:GetAbilityByName("nevermore_shadowraze2")
    local e = bot:GetAbilityByName("nevermore_shadowraze3")
    if not q or q:GetLevel() == 0 then return false end

    local stacks = U.GetShadowrazeDebuff(enemyHero)
    if stacks ~= 0 then return false end

    local oneRaze = U.GetNRazeDamage(bot, enemyHero, 1)
    local twoRaze = U.GetTwoRazeDamage(bot, enemyHero)
    if twoRaze < enemyHero:GetHealth() then return false end
    if oneRaze >= enemyHero:GetHealth() then return false end

    local candidates = {
        { label = "mid",  ability = w, center = C.RAZE.MID_CENTER  },
        { label = "far",  ability = e, center = C.RAZE.FAR_CENTER  },
        { label = "near", ability = q, center = C.RAZE.NEAR_CENTER },
    }

    for _, c in ipairs(candidates) do
        if c.ability and U.IsRazeAbilityCastable(bot, c.ability) and not IsTowerDiveRazeUnsafe(bot, enemyHero, c.ability, enemyTowers, allyCreeps) then
            local actionType, aimLoc = GetRazeActionType(bot, c.ability, enemyHero)
            if actionType and CastOrTurnRaze(bot, c.ability, actionType, aimLoc, enemyHero) then
                return true
            end
        end
    end

    local opener = nil
    if w and U.IsRazeAbilityCastable(bot, w) and not IsTowerDiveRazeUnsafe(bot, enemyHero, w, enemyTowers, allyCreeps) then
        opener = { ability = w, center = C.RAZE.MID_CENTER, label = "mid" }
    elseif e and U.IsRazeAbilityCastable(bot, e) and not IsTowerDiveRazeUnsafe(bot, enemyHero, e, enemyTowers, allyCreeps) then
        opener = { ability = e, center = C.RAZE.FAR_CENTER, label = "far" }
    elseif q and U.IsRazeAbilityCastable(bot, q) and not IsTowerDiveRazeUnsafe(bot, enemyHero, q, enemyTowers, allyCreeps) then
        opener = { ability = q, center = C.RAZE.NEAR_CENTER, label = "near" }
    end

    if opener then
        local setupPos = U.GetRazeSetupPositionForAbility(bot, enemyHero, opener.center)
        if setupPos then
            setupPos = GetSafeApproachLoose(bot, setupPos, enemyTowers or {}, allyCreeps or {})
            local currentDist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
            if math.abs(currentDist - opener.center) > 90 then
                SmartMove(bot, setupPos, 35)
                return true
            end
        end
    end

    return false
end

local function TryRazeEnemy(bot, enemyHero, current_mode, enemyTowers, allyCreeps, isLethalChase, forceExtend)
    if not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end

    if bot:GetMana() < 75 and GetPotentialCombatMana(bot) >= 75 then
        if TryUseBurstManaItem(bot, true) then return true end
    end

    local ability, actionType, aimLoc = U.GetBestRaze(bot, enemyHero, current_mode, isLethalChase or false, forceExtend or false)
    if ability then
        local data = U.GetRazeAbilityData(ability)
        local predDist = GetUnitToLocationDistance(bot, aimLoc or enemyHero:GetLocation())
        local underT1 = IsBotUnderEnemyT1(bot, enemyTowers)
        if data and data.label == "near" and predDist > (C.RAZE.NEAR_CENTER + C.RAZE.STRICT_RADIUS) and not isLethalChase and not forceExtend then
            ability, actionType, aimLoc = nil, nil, nil
        elseif data and data.label == "near" and underT1 and not ShouldAllowRiskyT1Commit(bot, enemyHero, enemyTowers, allyCreeps) and not isLethalChase and not forceExtend then
            ability, actionType, aimLoc = nil, nil, nil
        elseif data and (data.label == "mid" or data.label == "far") and IsTowerDiveRazeUnsafe(bot, enemyHero, ability, enemyTowers, allyCreeps) then
            ability, actionType, aimLoc = nil, nil, nil
        end
    end

    if CastOrTurnRaze(bot, ability, actionType, aimLoc, enemyHero) then return true end

    local stacks, rem_time = U.GetShadowrazeDebuff(enemyHero)
    if (forceExtend or (stacks > 0 and rem_time <= C.RAZE.EXTEND_AT + 0.6) or isLethalChase) and bot:GetMana() >= 75 then
        local setupPos = U.GetRazeSetupPosition(bot, enemyHero)
        if setupPos then
            setupPos = GetSafeApproachLoose(bot, setupPos, enemyTowers or {}, allyCreeps or {})
            local beforeLoc = State.lastMoveLoc
            local beforeTime = State.lastMoveTime
            SmartMove(bot, setupPos, 35)
            if State.lastMoveLoc ~= beforeLoc or State.lastMoveTime ~= beforeTime then
                return true
            end
        end
    end

    return false
end

local function EnemyStackNeedsImmediateExtension(bot, enemyHero)
    if not U.CanQuery(enemyHero) then return false end
    if bot:GetMana() < 75 then return false end
    local stacks, rem_time = U.GetShadowrazeDebuff(enemyHero)
    if stacks <= 0 then return false end
    if rem_time <= 0.15 then return false end
    if rem_time > C.RAZE.EXTEND_AT + 0.6 then return false end
    return true
end

local function ForceExtendEnemyStack(bot, enemyHero, enemyTowers, allyCreeps)
    if not EnemyStackNeedsImmediateExtension(bot, enemyHero) then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return true end
    if State.actionTaken then return false end

    State.prepTarget = nil
    State.attackTarget = nil
    State.attackStartTime = 0
    State.firedThisAttack = false
    State.aggroPullTime = 0
    State.deaggroTime = 0

    local stacks, rem_time = U.GetShadowrazeDebuff(enemyHero)
    local isLethal = U.GetTwoRazeDamage(bot, enemyHero) >= enemyHero:GetHealth() * 0.90
    local ability, actionType, aimLoc = U.GetBestRaze(bot, enemyHero, "AGGRESSIVE", isLethal, true)
    if ability and actionType then
        local data = U.GetRazeAbilityData(ability)
        if data and data.label == "near" and actionType == "TURN" then
            local distToEnemy = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
            if distToEnemy > (C.RAZE.NEAR_CENTER + C.RAZE.STRICT_RADIUS) then
                ability = nil
                actionType = nil
            end
        end
        if ability and actionType and CastOrTurnRaze(bot, ability, actionType, aimLoc, enemyHero) then
            return true
        end
    end

    local shouldCloseIn, closePos = U.ShouldApproachForNearRazeFinish(bot, enemyHero)
    if shouldCloseIn and closePos then
        closePos = GetSafeApproachLoose(bot, closePos, enemyTowers or {}, allyCreeps or {})
        SmartMove(bot, closePos, 35)
        return true
    end

    local setupPos = U.GetRazeSetupPosition(bot, enemyHero)
    if setupPos then
        setupPos = GetSafeApproachLoose(bot, setupPos, enemyTowers or {}, allyCreeps or {})
        SmartMove(bot, setupPos, 45)
        return true
    end

    local desiredCenter = C.RAZE.MID_CENTER
    local enemyLoc = enemyHero:GetLocation()
    local botLoc = bot:GetLocation()
    local dist = U.DistanceBetweenLocations(botLoc, enemyLoc)
    local desired = nil
    if dist > desiredCenter + 60 then
        local dir = (enemyLoc - botLoc):Normalized()
        desired = botLoc + dir * math.min(dist - desiredCenter, 380)
    elseif dist < desiredCenter - 100 then
        local dir = (botLoc - enemyLoc):Normalized()
        desired = enemyLoc + dir * desiredCenter
    else
        return true
    end
    desired = GetSafeApproachLoose(bot, desired, enemyTowers or {}, allyCreeps or {})
    SmartMove(bot, desired, 45)
    return true
end

local function LevelUpAbilities(bot)
    if bot:GetAbilityPoints() == 0 then return end
    local order = {
        "nevermore_dark_lord", "nevermore_shadowraze1", "nevermore_shadowraze1",
        "nevermore_dark_lord", "nevermore_shadowraze1", "nevermore_dark_lord",
        "nevermore_shadowraze1", "nevermore_dark_lord", "nevermore_requiem",
        "special_bonus_attack_speed_20",
        "special_bonus_unique_nevermore_1",
        "nevermore_requiem",
        "special_bonus_unique_nevermore_2",
    }
    local lvl = bot:GetLevel()
    if order[lvl] then bot:ActionImmediate_LevelAbility(order[lvl]) end
end

local function IsInDangerForRegen(bot, heroDist)
    heroDist = heroDist or 850
    local heroes = bot:GetNearbyHeroes(heroDist, true, BOT_MODE_NONE)
    if heroes and #heroes > 0 then return true end
    local creeps = bot:GetNearbyLaneCreeps(600, true)
    if creeps and #creeps > 0 then return true end
    local projs = bot:GetIncomingTrackingProjectiles()
    if projs and #projs > 0 then return true end
    return false
end

local function HasEnemyProjectileIncoming(bot)
    local projs = bot:GetIncomingTrackingProjectiles() or {}
    for _, p in pairs(projs) do
        local caster = p and p.caster
        if caster then
            local isEnemy = true
            if caster.GetTeam then
                isEnemy = caster:GetTeam() ~= bot:GetTeam()
            end
            if isEnemy then
                return true, p
            end
        end
    end
    return false, nil
end

local function GetSalveSafeRetreatLocation(bot, enemyHero)
    local fountain = P.GetFountain(bot)
    local botLoc = bot:GetLocation()
    local safeDistance = (C.REGEN and C.REGEN.FLASK_SAFE_DISTANCE) or (C.RAZE.FAR_CENTER + C.RAZE.HIT_RADIUS + 200) or 1150
    if enemyHero and U.CanQuery(enemyHero) then
        local enemyLoc = enemyHero:GetLocation()
        local dir = fountain - enemyLoc
        if U.DistanceBetweenLocations(fountain, enemyLoc) < 1 then
            dir = fountain - botLoc
        end
        dir = dir:Normalized()
        return enemyLoc + dir * safeDistance
    end
    local dir = fountain - botLoc
    if U.DistanceBetweenLocations(fountain, botLoc) < 1 then
        return fountain
    end
    dir = dir:Normalized()
    return botLoc + dir * 450
end

local function HandleActiveSalveSafety(bot, enemyHero)
    if not bot:HasModifier("modifier_flask_healing") then
        return false
    end
    local safeDistance = (C.REGEN and C.REGEN.FLASK_SAFE_DISTANCE) or (C.RAZE.FAR_CENTER + C.RAZE.HIT_RADIUS + 200) or 1150
    local incomingProjectile = HasEnemyProjectileIncoming(bot)
    local tooCloseToEnemy = false
    if enemyHero and U.CanQuery(enemyHero) then
        local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
        if dist < safeDistance then
            tooCloseToEnemy = true
        end
    end
    if incomingProjectile or tooCloseToEnemy then
        local safeLoc = GetSalveSafeRetreatLocation(bot, enemyHero)
        BeginForcedRetreat(bot, safeLoc, 0.85)
        return true
    end
    State.actionTaken = true
    return true
end

local function HandleEnemyNearRazeCounter(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end

    local q_enemy = enemyHero:GetAbilityByName("nevermore_shadowraze1")
    if not q_enemy or not q_enemy:IsInAbilityPhase() then return false end

    local enemyLoc = enemyHero:GetLocation()
    local enemyFacing = enemyHero:GetFacing()
    local rad = math.rad(enemyFacing)
    local forward = Vector(math.cos(rad), math.sin(rad), 0)
    local center = enemyLoc + forward * C.RAZE.NEAR_CENTER
    if U.DistanceBetweenLocations(center, bot:GetLocation()) > C.RAZE.HIT_RADIUS then
        return false
    end

    local q_bot = bot:GetAbilityByName("nevermore_shadowraze1")
    if not q_bot or not U.IsRazeAbilityCastable(bot, q_bot) then return false end

    local botPred = U.PredictPosition(enemyHero, C.RAZE.CAST_POINT)
    local myError = U.GetRazeHitErrorWithDesiredFacing(bot, botPred, C.RAZE.NEAR_CENTER)
    if myError <= C.RAZE.HIT_RADIUS + 30 then
        local actionType = "TURN"
        if U.GetAngleDifference(bot, botPred) <= C.RAZE.MAX_ANGLE_TO_CAST then
            actionType = "CAST"
        end
        if CastOrTurnRaze(bot, q_bot, actionType, botPred, enemyHero) then
            return true
        end
    end

    return false
end

local function GetPotentialRecallHpPct(bot)
    local hp = bot:GetHealth() or 0
    local maxHp = math.max(1, bot:GetMaxHealth() or 1)
    local bonus = 0
    if bot:HasModifier("modifier_flask_healing") then
        bonus = bonus + 390
    elseif U.HasItem(bot, "item_flask") then
        bonus = bonus + 390
    end
    return math.min(maxHp, hp + bonus) / maxHp
end

local function GetPotentialRecallManaPct(bot)
    local mana = bot:GetMana() or 0
    local maxMana = math.max(1, bot:GetMaxMana() or 1)
    local bonus = 0
    if U.HasItem(bot, "item_enchanted_mango") then
        bonus = bonus + 100
    end
    local charges = U.GetStickCharges(bot)
    if charges > 0 then
        bonus = bonus + charges * 15
    end
    if bot:HasModifier("modifier_clarity_potion") or U.GetActiveItemByName(bot, "item_clarity") then
        bonus = math.max(bonus, 100)
    end
    return math.min(maxMana, mana + bonus) / maxMana
end

local function ShouldGoToFountain(bot)
    local hpCritical = (C.FOUNTAIN and C.FOUNTAIN.GO_HP_CRITICAL_PCT) or 0.15
    local potentialHpPct = GetPotentialRecallHpPct(bot)
    if potentialHpPct < hpCritical then
        return true, "HP"
    end
    return false, nil
end

local function ShouldAbortFountainRecall(bot)
    local hpCritical = (C.FOUNTAIN and C.FOUNTAIN.GO_HP_CRITICAL_PCT) or 0.15
    local hpPct = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
    if hpPct >= hpCritical then
        return true
    end
    local potentialHpPct = GetPotentialRecallHpPct(bot)
    return potentialHpPct >= hpCritical
end

local function IsAtFountain(bot)
    local fountain = P.GetFountain(bot)
    local radius = (C.FOUNTAIN and C.FOUNTAIN.AT_FOUNTAIN_RADIUS) or 500
    return GetUnitToLocationDistance(bot, fountain) <= radius
end

local function IsFountainFullyRestored(bot)
    local hp = bot:GetHealth()
    local maxHp = bot:GetMaxHealth()
    local mana = bot:GetMana()
    local maxMana = bot:GetMaxMana()
    local hpPct = hp / maxHp
    local manaPct = (maxMana > 0) and (mana / maxMana) or 1.0
    local waitHpPct = (C.FOUNTAIN and C.FOUNTAIN.WAIT_FULL_HP_PCT) or 0.98
    local waitManaPct = (C.FOUNTAIN and C.FOUNTAIN.WAIT_FULL_MANA_PCT) or 0.98
    return hpPct >= waitHpPct and manaPct >= waitManaPct
end

local function HandleFountainRecall(bot)
    if State.goingToFountain then
        if not bot:IsAlive() then
            State.goingToFountain = false
            State.fountainReason = nil
            return false
        end
        if not IsAtFountain(bot) and State.fountainReason ~= "EMERGENCY" and ShouldAbortFountainRecall(bot) then
            State.goingToFountain = false
            State.fountainReason = nil
            ClearMoveCache()
            return false
        end
        if IsAtFountain(bot) then
            if IsFountainFullyRestored(bot) then
                State.goingToFountain = false
                State.fountainReason = nil
                State.needsTP = true
                return false
            else
                State.actionTaken = true
                return true
            end
        else
            local fountain = P.GetFountain(bot)
            SmartMove(bot, fountain, 80)
            State.actionTaken = true
            return true
        end
    end

    if State.emergencyRetreat then return false end
    if bot:HasModifier("modifier_flask_healing") or bot:HasModifier("modifier_tango_heal") then return false end
    if IsInDangerForRegen(bot, 900) then return false end
    local should, reason = ShouldGoToFountain(bot)
    if should then
        State.goingToFountain = true
        State.fountainReason = reason
        ClearForcedRetreat()
        local fountain = P.GetFountain(bot)
        SmartMove(bot, fountain, 80)
        State.actionTaken = true
        return true
    end
    return false
end

local function HandleReturnTP(bot)
    local t1 = P.GetT1Close(bot)
    local fountain = P.GetFountain(bot)
    local farFromT1 = GetUnitToLocationDistance(bot, t1) > C.TP.RETURN_DISTANCE_FROM_T1
    local nearFount = GetUnitToLocationDistance(bot, fountain) < (C.TP.FOUNTAIN_RADIUS or 400)
    if not (State.needsTP or (nearFount and farFromT1)) then return false end
    if not IsFountainFullyRestored(bot) then
        State.actionTaken = true
        return true
    end
    local tp = U.GetTPScroll(bot)
    if not tp then
        if bot:GetGold() >= 100 then
            bot:ActionImmediate_PurchaseItem("item_tpscroll")
            return true
        end
        State.needsTP = false
        return false
    end
    if tp:IsFullyCastable() then
        bot:Action_UseAbilityOnLocation(tp, t1)
        State.needsTP = false
        State.actionTaken = true
        return true
    end
    State.needsTP = false
    return false
end

local function ShouldTryRazePressure(bot, enemyHero, current_mode, aggroCount)
    if not U.CanQuery(enemyHero) then return false, current_mode end
    if current_mode == "NEUTRAL" or current_mode == "AGGRESSIVE" then return true, current_mode end
    if bot:GetLevel() > 1 and U.HasEnemyMissedRazeRecently() and GetPotentialCombatMana(bot) >= 75 then
        return true, "AGGRESSIVE"
    end
    if aggroCount > 1 or GetPotentialCombatMana(bot) < 75 then return false, current_mode end
    local levelDiff = bot:GetLevel() - enemyHero:GetLevel()
    local soulDiff = S.GetSouls(bot) - S.GetSouls(enemyHero)
    local bracerDiff = U.GetItemCount(bot, "item_bracer") - U.GetItemCount(enemyHero, "item_bracer")
    if levelDiff > 0 or soulDiff >= 6 or bracerDiff > 0 then return true, "NEUTRAL" end
    return false, current_mode
end

local function ShouldAttackHarassEnemy(bot, enemyHero, current_mode, aggroCount, enemyTowers, allyCreeps)
    if not U.CanQuery(enemyHero) then return false end
    local interruptRegen = U.IsEnemyHighValueRegen(enemyHero)
    local enemyMissed = U.HasEnemyMissedRazeRecently() and bot:GetLevel() > 1
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local attackRange = bot:GetAttackRange() + 60
    if dist > attackRange then return false end
    local minDistStack = U.GetMinDistWithStack(bot, enemyHero)
    if minDistStack > 0 and dist < minDistStack then return false end
    if not IsSafeToHarass(bot, enemyHero:GetLocation(), enemyTowers, allyCreeps) then
        if interruptRegen then
            for _, tower in pairs(enemyTowers or {}) do
                if tower:IsAlive() and GetUnitToLocationDistance(tower, bot:GetLocation()) < 720 then
                    return false
                end
            end
        else
            return false
        end
    end
    if interruptRegen then
        return (bot:GetHealth() / bot:GetMaxHealth()) >= 0.30
    end
    local maxAggro = enemyMissed and 2 or 1
    if aggroCount > maxAggro then return false end
    if (bot:GetHealth() / bot:GetMaxHealth()) < C.HARASS.MIN_HP_PCT then return false end
    if current_mode == "PASSIVE" and not enemyMissed then
        local myHpPct = bot:GetHealth() / bot:GetMaxHealth()
        local eHpPct = enemyHero:GetHealth() / enemyHero:GetMaxHealth()
        if (myHpPct - eHpPct) < -0.15 then
            local levelDiff = bot:GetLevel() - enemyHero:GetLevel()
            local soulDiff = S.GetSouls(bot) - S.GetSouls(enemyHero)
            if levelDiff <= 0 and soulDiff < 6 then return false end
        end
    end
    return true
end

local function GetEnemyApproachDistance(enemyMissed)
    return enemyMissed and C.HARASS.APPROACH_DISTANCE_MISS or C.HARASS.APPROACH_DISTANCE
end

local function ShouldPrioritizeStackExtensionOverUtility(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if bot:GetMana() < 75 then return false end
    local stacks, rem_time = U.GetShadowrazeDebuff(enemyHero)
    if stacks <= 0 then return false end
    if rem_time <= 0.15 then return false end
    if rem_time > C.RAZE.EXTEND_AT + 0.8 then return false end
    return true
end

local function GetSaferTangoTree(bot, enemyTowers)
    local trees = bot:GetNearbyTrees(1200)
    if not trees or #trees == 0 then return nil end
    if not enemyTowers or #enemyTowers == 0 then return trees[1] end
    local fountain = P.GetFountain(bot)
    local bestTree = nil
    local bestScore = math.huge
    for _, tree in ipairs(trees) do
        local treeLoc = GetTreeLocation(tree)
        local isSafe = true
        local safetyPenalty = 0
        for _, tower in pairs(enemyTowers) do
            if tower:IsAlive() then
                local dTower = GetUnitToLocationDistance(tower, treeLoc)
                if dTower < 1125 then
                    isSafe = false
                    break
                end
                safetyPenalty = safetyPenalty + dTower * 0.02
            end
        end
        if isSafe then
            local score = U.DistanceBetweenLocations(bot:GetLocation(), treeLoc)
            score = score + U.DistanceBetweenLocations(fountain, treeLoc) * 0.15
            score = score + safetyPenalty * -1
            if score < bestScore then
                bestScore = score
                bestTree = tree
            end
        end
    end
    return bestTree
end

local function IsDryVsEnemyRaze(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if not U.EnemyHasRaze(enemyHero) then return false end
    local myHasResource = GetPotentialCombatMana(bot) >= 75
    if myHasResource then return false end
    local enemyHasResource = enemyHero:GetMana() >= 75 or U.HasItem(enemyHero, "item_enchanted_mango") or U.HasItem(enemyHero, "item_magic_wand") or U.HasItem(enemyHero, "item_magic_stick")
    if not enemyHasResource then return false end
    return true
end

local function HandleRazeRangedCreepWithHero(bot, enemyHero, enemyCreeps, allyAttackers, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if GetPotentialCombatMana(bot) < 75 then return false end
    if bot:GetMana() < 75 and TryUseBurstManaItem(bot, true) then return true end

    local heroPred = U.PredictPosition(enemyHero, C.RAZE.CAST_POINT)
    local abilities = {
        bot:GetAbilityByName("nevermore_shadowraze2"),
        bot:GetAbilityByName("nevermore_shadowraze3"),
    }

    for _, creep in pairs(enemyCreeps or {}) do
        if creep and creep:IsAlive() then
            local name = creep:GetUnitName() or ""
            if name:find("ranged") then
                local creepPred = U.PredictPosition(creep, C.RAZE.CAST_POINT)
                if U.DistanceBetweenLocations(creepPred, heroPred) <= 180 then
                    local ctx = U.GetTargetPredictionContext(creep, allyAttackers)
                    local predHp = U.PredictHPWithContext(ctx, creep, C.RAZE.CAST_POINT + 0.07)
                    for _, ability in ipairs(abilities) do
                        if ability and U.IsRazeAbilityCastable(bot, ability) and not IsTowerDiveRazeUnsafe(bot, enemyHero, ability, enemyTowers, allyCreeps) then
                            local data = U.GetRazeAbilityData(ability)
                            local baseDmg = ability:GetSpecialValueInt("shadowraze_damage") or 0
                            local actualCreepDmg = creep:GetActualIncomingDamage(baseDmg, DAMAGE_TYPE_MAGICAL)
                            local midPoint = Vector(
                                (creepPred.x + heroPred.x) * 0.5,
                                (creepPred.y + heroPred.y) * 0.5,
                                (creepPred.z + heroPred.z) * 0.5
                            )
                            local plannedError = U.GetRazeHitErrorWithDesiredFacing(bot, midPoint, data.center)
                            if predHp > 0 and predHp <= actualCreepDmg + 12 and plannedError <= C.RAZE.HIT_RADIUS then
                                local actionType = "TURN"
                                if U.GetAngleDifference(bot, midPoint) <= C.RAZE.MAX_ANGLE_TO_CAST then
                                    actionType = "CAST"
                                end
                                if CastOrTurnRaze(bot, ability, actionType, midPoint, enemyHero) then
                                    return true
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return false
end

local function HandleItemsAndConsumables(bot, bestTarget, enemyCreeps, allyAttackers, enemyTowers, enemyHero)
    U.ManageInventorySlots(bot)
    if GameTime() < State.lastItemUseTime + 0.3 then return false end
    if ShouldPrioritizeStackExtensionOverUtility(bot, enemyHero) then return false end

    local hpPct = bot:GetHealth() / bot:GetMaxHealth()
    if hpPct < 0.10 then
        local stickItem = GetStickLikeItem(bot)
        if stickItem then
            bot:Action_UseAbility(stickItem)
            State.lastItemUseTime = GameTime()
            State.actionTaken = true
            return true
        end
    end

    if hpPct < 0.20 then
        local faerie = U.GetActiveItemByName(bot, "item_faerie_fire")
        if faerie then
            bot:Action_UseAbility(faerie)
            State.lastItemUseTime = GameTime()
            State.actionTaken = true
            return true
        end
    end

    if bot:GetMana() < 75 then
        if TryUseBurstManaItem(bot, true) then return true end
    end

    local isHighValueBeingAttacked = false
    for _, c in pairs(enemyCreeps or {}) do
        if c:IsAlive() then
            local name = c:GetUnitName() or ""
            if name:find("ranged") or name:find("flagbearer") or name:find("siege") then
                if (c:GetHealth() / c:GetMaxHealth()) < 0.50 then
                    isHighValueBeingAttacked = true
                    break
                end
                for _, atk in pairs(allyAttackers or {}) do
                    if atk:IsAlive() and atk:GetAttackTarget() == c then
                        isHighValueBeingAttacked = true
                        break
                    end
                end
                if isHighValueBeingAttacked then break end
            end
        end
    end

    if hpPct < 0.60 and not bot:HasModifier("modifier_tango_heal") then
        if not isHighValueBeingAttacked then
            local tango = U.GetActiveItemByName(bot, "item_tango")
            if tango then
                local tree = GetSaferTangoTree(bot, enemyTowers)
                if tree then
                    local treeLoc = GetTreeLocation(tree)
                    local distToTree = U.DistanceBetweenLocations(bot:GetLocation(), treeLoc)
                    if distToTree > 165 then
                        SmartMove(bot, treeLoc, 40)
                        return true
                    end
                    bot:Action_UseAbilityOnTree(tango, tree)
                    State.lastItemUseTime = GameTime()
                    State.actionTaken = true
                    return true
                end
            end
        end
    end

    return false
end

local function ProcessTelemetry(bot)
    local now = GameTime()
    for i = #State.flyingProjectiles, 1, -1 do
        local proj = State.flyingProjectiles[i]
        if now > proj.impactTime + 0.15 then
            table.remove(State.flyingProjectiles, i)
        end
    end
end

local function HandleEmergencyRetreat(bot, enemyHero)
    local fountain = P.GetFountain(bot)
    local distToFountain = GetUnitToLocationDistance(bot, fountain)
    local returnHpPct = (C.TP and C.TP.RETURN_HP_PCT) or 0.50
    local hpPct = bot:GetHealth() / bot:GetMaxHealth()

    if enemyHero and U.CanQuery(enemyHero) then
        local canOneShot, oneShotMethod = U.CanOneShotEnemyHero(bot, enemyHero)
        local canRazeKill, razeLabel = U.CanKillEnemyWithOneRaze(bot, enemyHero)
        if canOneShot then
            return false
        end
        if canRazeKill then
            return false
        end
    end

    if State.emergencyRetreat == "FOUNTAIN" and hpPct >= returnHpPct then
        if IsAtFountain(bot) then
            State.emergencyRetreat = nil
            State.emergencyRetreatStartTime = 0
            State.emergencyTPQueued = false
            State.goingToFountain = true
            State.fountainReason = "HP"
        end
        return false
    end

    local committedFountain = State.emergencyRetreat == "FOUNTAIN"
        and State.emergencyRetreatStartTime > 0
        and (GameTime() - State.emergencyRetreatStartTime) >= 5.0
        and distToFountain > ((C.FOUNTAIN and C.FOUNTAIN.AT_FOUNTAIN_RADIUS) or 500)

    if committedFountain then
        BeginForcedRetreat(bot, fountain, 1.0)
        return true
    end

    local reason, extraLoc = U.GetEmergencyRetreatReason(bot, enemyHero)
    if not reason then
        if State.emergencyRetreat then
            State.emergencyRetreat = nil
            State.emergencyRetreatStartTime = 0
            State.emergencyTPQueued = false
        end
        return false
    end

    if reason == "COURIER" and extraLoc then
        State.emergencyRetreat = "COURIER"
        State.emergencyRetreatStartTime = 0
        local botLoc = bot:GetLocation()
        local dist = U.DistanceBetweenLocations(botLoc, extraLoc)
        if dist > 150 then
            local toFountain = (fountain - botLoc):Normalized()
            local toCourier = (extraLoc - botLoc):Normalized()
            local blended = (toCourier * 0.8 + toFountain * 0.2):Normalized()
            SmartMove(bot, botLoc + blended * math.min(dist, 400), 60)
        end
        State.actionTaken = true
        return true
    end

    if State.emergencyRetreat ~= "FOUNTAIN" then
        State.emergencyRetreatStartTime = GameTime()
    end
    State.emergencyRetreat = "FOUNTAIN"

    if distToFountain < ((C.FOUNTAIN and C.FOUNTAIN.AT_FOUNTAIN_RADIUS) or 500) then
        State.emergencyRetreat = nil
        State.goingToFountain = true
        State.fountainReason = "EMERGENCY"
        State.actionTaken = true
        return true
    end

    BeginForcedRetreat(bot, fountain, 1.0)
    return true
end

local function HandleGlyph(bot, enemyHero, enemyTowers, allyTowers, allyCreeps)
    if U.ShouldUseGlyphDefensive(bot, allyTowers) then
        U.UseGlyph(bot)
        State.actionTaken = true
        return true
    end
    if U.ShouldUseGlyphForKillDive(bot, enemyHero, enemyTowers, allyTowers, allyCreeps) then
        U.UseGlyph(bot)
        State.glyphUsedForDive = true
        State.glyphDiveTime = GameTime()
        State.actionTaken = true
        return true
    end
    return false
end

local function HandleForcedSalve(bot)
    if not U.ShouldForceSalve(bot) then return false end
    if GameTime() < State.lastForceSalveTime + 1.0 then return false end
    local nearbyEnemyHeroes = bot:GetNearbyHeroes(700, true, BOT_MODE_NONE)
    if nearbyEnemyHeroes and #nearbyEnemyHeroes > 0 then
        local fountain = P.GetFountain(bot)
        local botLoc = bot:GetLocation()
        SmartMove(bot, botLoc + (fountain - botLoc):Normalized() * 400, 60)
        State.actionTaken = true
        return true
    end
    local nearbyEnemyCreeps = bot:GetNearbyLaneCreeps(500, true) or {}
    for _, c in pairs(nearbyEnemyCreeps) do
        if c:IsAlive() and c:GetAttackTarget() == bot then
            local fountain = P.GetFountain(bot)
            local botLoc = bot:GetLocation()
            SmartMove(bot, botLoc + (fountain - botLoc):Normalized() * 350, 60)
            State.actionTaken = true
            return true
        end
    end
    local flask = U.GetActiveItemByName(bot, "item_flask")
    if flask then
        if HasEnemyProjectileIncoming(bot) then
            local safeLoc = GetSalveSafeRetreatLocation(bot, nil)
            BeginForcedRetreat(bot, safeLoc, 0.65)
            return true
        end
        bot:Action_UseAbilityOnEntity(flask, bot)
        State.lastForceSalveTime = GameTime()
        State.lastItemUseTime = GameTime()
        State.actionTaken = true
        return true
    end
    return false
end

local function HandleAutoBuySalveInsteadOfFountain(bot)
    local cfg = C.SALVE_AUTOBUY or { HP_PCT_THRESHOLD = 0.40, MIN_GOLD = 110, BUY_COOLDOWN = 8.0 }
    if State.goingToFountain then return false end
    if bot:HasModifier("modifier_flask_healing") then return false end
    local hpPct = bot:GetHealth() / math.max(1, bot:GetMaxHealth())
    if hpPct > (cfg.HP_PCT_THRESHOLD or 0.40) then return false end
    if U.HasItem(bot, "item_flask") then return false end
    local stashHasFlask = false
    for i = 9, 14 do
        local it = bot:GetItemInSlot(i)
        if it and it:GetName() == "item_flask" then
            stashHasFlask = true
            break
        end
    end
    if stashHasFlask then return false end
    if (bot:GetGold() or 0) < (cfg.MIN_GOLD or 110) then return false end
    local now = GameTime()
    if now < (State._lastSalveAutoBuyTime or 0) + (cfg.BUY_COOLDOWN or 8.0) then
        return false
    end
    bot:ActionImmediate_PurchaseItem("item_flask")
    State._lastSalveAutoBuyTime = now
    return false
end

local function HandleSafeDistanceFromEnemy(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    local canOneShot, _ = U.CanOneShotEnemyHero(bot, enemyHero)
    if canOneShot then
        IssueHeroAttack(bot, enemyHero)
        State.lastHarassTime = GameTime()
        State.lastAggroTime = GameTime()
        State.aggroPullTime = GameTime() + 0.25
        return true
    end
    local canQuickRazeKill, razeLabel = U.CanQuickTurnKillWithRaze(bot, enemyHero)
    if canQuickRazeKill then
        local ability = GetRazeAbilityByLabel(bot, razeLabel)
        if ability then
            local predLoc = U.PredictPosition(enemyHero, C.RAZE.CAST_POINT)
            local angleDiff = U.GetAngleDifference(bot, predLoc)
            local actionType = angleDiff <= C.RAZE.MAX_ANGLE_TO_CAST and "CAST" or "TURN"
            if CastOrTurnRaze(bot, ability, actionType, predLoc, enemyHero) then
                return true
            end
        end
    end
    if not U.IsInEnemyRazeKillThreat(bot, enemyHero) then return false end
    if bot:HasModifier("modifier_flask_healing") then return false end
    local safeLoc = U.GetSafeDistancePosition(bot, enemyHero)
    if not safeLoc then return false end
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local hp = bot:GetHealth()
    local threat1 = U.GetEnemyRazeBurstDamage(bot, enemyHero, 1)
    local isCritical = (threat1 > 0 and hp <= threat1 * SAFE_DISTANCE.CRITICAL_HP_FACTOR)
    local minDist = isCritical and (SAFE_DISTANCE.MIN_DISTANCE_CRITICAL or 950) or SAFE_DISTANCE.MIN_DISTANCE_FROM_ENEMY
    if dist < minDist then
        local duration = isCritical and 1.20 or 0.80
        BeginForcedRetreat(bot, safeLoc, duration)
        return true
    end
    return false
end

local function HandleDryManaMidRazeAvoidance(bot, enemyHero)
    if not IsDryVsEnemyRaze(bot, enemyHero) then return false end
    if State.actionTaken then return false end
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local midDangerRadius = math.max(C.RAZE.STRICT_RADIUS, 210)
    if math.abs(dist - C.RAZE.MID_CENTER) > midDangerRadius then return false end
    local retreatLoc = U.GetRetreatPositionFromEnemySF(bot, enemyHero)
    BeginForcedRetreat(bot, retreatLoc, 0.75)
    return true
end

local function HoldNearRazeReplySpacing(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local botLoc = bot:GetLocation()
    local enemyLoc = enemyHero:GetLocation()
    local dist = U.DistanceBetweenLocations(botLoc, enemyLoc)
    local desired = (C.NEAR_REPLY and C.NEAR_REPLY.HOLD_DISTANCE) or 215
    local minDist = (C.NEAR_REPLY and C.NEAR_REPLY.HOLD_MIN_DISTANCE) or 150
    local maxDist = (C.NEAR_REPLY and C.NEAR_REPLY.HOLD_MAX_DISTANCE) or 250
    local tol = (C.NEAR_REPLY and C.NEAR_REPLY.HOLD_TOLERANCE) or 25
    if dist >= minDist and dist <= maxDist then
        SafeClearActions(bot)
        bot:Action_MoveToLocation(botLoc)
        State.lastMoveLoc = botLoc
        State.lastMoveTime = GameTime()
        State.actionTaken = true
        return true
    end
    local dir = botLoc - enemyLoc
    if dist < 1 then
        dir = U.GetFountain(bot) - enemyLoc
    end
    dir = dir:Normalized()
    local holdLoc = enemyLoc + dir * desired
    holdLoc = GetSafeApproachLoose(bot, holdLoc, enemyTowers or {}, allyCreeps or {})
    SmartMove(bot, holdLoc, tol)
    State.actionTaken = true
    return true
end

local function HandleNearRazeReplyPressure(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end

    local secondStackActive, hitLabel = U.IsSecondStackDangerActive(bot, enemyHero)
    if not secondStackActive or hitLabel ~= "near" then return false end
    local myStacks, myRemain = U.GetShadowrazeDebuff(bot)
    if myStacks ~= 1 or myRemain <= C.RAZE.RETREAT_MIN_REMAIN then return false end

    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if q and U.IsRazeAbilityCastable(bot, q) then
        local willHit, _, predicted = U.WillRazeHit(bot, q, enemyHero, C.RAZE.CAST_POINT, false)
        if willHit then
            local actionType = U.GetAngleDifference(bot, predicted) <= C.RAZE.MAX_ANGLE_TO_CAST and "CAST" or "TURN"
            if CastOrTurnRaze(bot, q, actionType, predicted, enemyHero) then
                return true
            end
        end
    end

    local enemyIsHittingUs = false
    if enemyHero.GetAttackTarget and enemyHero:GetAttackTarget() == bot then
        enemyIsHittingUs = true
    end
    if not enemyIsHittingUs and bot.WasRecentlyDamagedByHero then
        enemyIsHittingUs = bot:WasRecentlyDamagedByHero(enemyHero, 1.0)
    end

    if enemyIsHittingUs then
        local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
        local attackRange = bot:GetAttackRange() + 60
        if dist <= attackRange then
            IssueHeroAttack(bot, enemyHero)
            State.lastHarassTime = GameTime()
            State.lastAggroTime = GameTime()
            State.aggroPullTime = GameTime() + 0.25
            return true
        end
    end

    return HoldNearRazeReplySpacing(bot, enemyHero, enemyTowers, allyCreeps)
end

local function HandleMirrorRazeTrade(bot, enemyHero, enemyTowers, allyCreeps, allyCreepsData, enemyCreepsData)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    local isAggressive = U.IsAggressivePlaystyle(bot, enemyHero, allyCreepsData, enemyCreepsData)
    if isAggressive then
        local active, hitLabel = U.IsSecondStackDangerActive(bot, enemyHero)
        if active and hitLabel then
            local targetCenter = U.GetRazeCenterByLabel(hitLabel)
            if targetCenter then
                local setupPos = U.GetRazeSetupPositionForAbility(bot, enemyHero, targetCenter)
                if setupPos then
                    setupPos = GetSafeApproachLoose(bot, setupPos, enemyTowers, allyCreeps)
                    SmartMove(bot, setupPos, 35)
                    return true
                end
            end
        end
    end

    local active, hitLabel = U.IsSecondStackDangerActive(bot, enemyHero)
    if not active or not hitLabel then return false end
    local eStacks, eRem = U.GetShadowrazeDebuff(enemyHero)
    if eStacks > 0 and eRem > C.RAZE.EXTEND_AT then
        local targetCenter = U.GetRazeCenterByLabel(hitLabel)
        if targetCenter then
            local setupPos = U.GetRazeSetupPositionForAbility(bot, enemyHero, targetCenter)
            if setupPos then
                setupPos = GetSafeApproachLoose(bot, setupPos, enemyTowers, allyCreeps)
                SmartMove(bot, setupPos, 35)
                return true
            end
        end
        return false
    end

    local ability = GetRazeAbilityByLabel(bot, hitLabel)
    if not ability or not U.IsRazeAbilityCastable(bot, ability) then return false end

    local willHit, _, predicted = U.WillRazeHit(bot, ability, enemyHero, C.RAZE.CAST_POINT, false)
    if not willHit then
        local targetCenter = U.GetRazeCenterByLabel(hitLabel)
        if targetCenter then
            local setupPos = U.GetRazeSetupPositionForAbility(bot, enemyHero, targetCenter)
            if setupPos then
                setupPos = GetSafeApproachLoose(bot, setupPos, enemyTowers, allyCreeps)
                SmartMove(bot, setupPos, 35)
                return true
            end
        end
        return false
    end

    local actionType = "TURN"
    if U.GetAngleDifference(bot, predicted) <= C.RAZE.MAX_ANGLE_TO_CAST then
        actionType = "CAST"
    end
    if CastOrTurnRaze(bot, ability, actionType, predicted, enemyHero) then
        return true
    end
    return false
end

local function HandleNearRazeFinish(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    local secondStackActive, hitLabel = U.IsSecondStackDangerActive(bot, enemyHero)
    if secondStackActive and hitLabel ~= "near" then return false end
    local shouldClose, closePos = U.ShouldApproachForNearRazeFinish(bot, enemyHero)
    if not shouldClose or not closePos then return false end
    if U.HasStackAndShouldFearNear(bot, enemyHero) then return false end
    local canQuickRazeKill, _ = U.CanQuickTurnKillWithRaze(bot, enemyHero)
    if canQuickRazeKill then
    elseif U.IsInEnemyRazeKillThreat(bot, enemyHero) then
        return false
    end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end

    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if q and U.IsRazeAbilityCastable(bot, q) then
        local willHit, _, predicted = U.WillRazeHit(bot, q, enemyHero, C.RAZE.CAST_POINT, false)
        if willHit then
            local angleDiff = U.GetAngleDifference(bot, predicted)
            if angleDiff <= C.RAZE.MAX_ANGLE_TO_CAST then
                U.SwitchTreadsIfNeeded(bot, 1)
                bot:Action_UseAbility(q)
                StartRazeCast(q, enemyHero, predicted, C.RAZE.HIT_RADIUS)
                ClearMoveCache()
                return true
            else
                SmartMove(bot, predicted, 12)
                State.actionTaken = true
                return true
            end
        end
    end

    closePos = GetSafeApproachLoose(bot, closePos, enemyTowers or {}, allyCreeps or {})
    SmartMove(bot, closePos, 35)
    State.actionTaken = true
    return true
end

local function HandleImmediateNearRazePunish(bot, enemyHero, current_mode, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if bot:GetMana() < 75 and GetPotentialCombatMana(bot) >= 75 then
        if TryUseBurstManaItem(bot, true) then return true end
    end
    local q = bot:GetAbilityByName("nevermore_shadowraze1")
    if not q or not U.IsRazeAbilityCastable(bot, q) then return false end
    if U.HasStackAndShouldFearNear(bot, enemyHero) then return false end
    local secondStackActive, safeReplyLabel = U.IsSecondStackDangerActive(bot, enemyHero)
    if secondStackActive and safeReplyLabel ~= "near" then return false end
    local predicted = U.PredictPosition(enemyHero, C.RAZE.CAST_POINT)
    local plannedError = U.GetRazeHitErrorWithDesiredFacing(bot, predicted, C.RAZE.NEAR_CENTER)
    if plannedError > C.RAZE.HIT_RADIUS then return false end
    local distToEnemy = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    if distToEnemy > (C.RAZE.NEAR_CENTER + C.RAZE.STRICT_RADIUS) then return false end
    if IsTowerDiveRazeUnsafe(bot, enemyHero, q, enemyTowers, allyCreeps) then
        local oneRaze = U.GetNRazeDamage(bot, enemyHero, 1)
        if oneRaze < enemyHero:GetHealth() then return false end
    end
    local actionType = "TURN"
    if U.GetAngleDifference(bot, predicted) <= C.RAZE.MAX_ANGLE_TO_CAST then
        actionType = "CAST"
    end
    if CastOrTurnRaze(bot, q, actionType, predicted, enemyHero) then
        return true
    end
    return false
end

local function HandleBootDisadvantageMidRazeFear(bot, enemyHero)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if not U.ShouldFearBootsMidRaze(bot, enemyHero) then return false end
    if U.IsInEnemyRazeKillThreat(bot, enemyHero) then return false end
    if U.CanKillEnemyWithTwoRazes(bot, enemyHero) then return false end
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local midRadius = (C.BOOT_FEAR and C.BOOT_FEAR.MID_RAZE_RADIUS) or 220
    if math.abs(dist - C.RAZE.MID_CENTER) > midRadius then return false end
    local retreatLoc = U.GetRetreatPositionFromEnemySF(bot, enemyHero)
    BeginForcedRetreat(bot, retreatLoc, (C.BOOT_FEAR and C.BOOT_FEAR.RETREAT_DURATION) or 0.95)
    return true
end

local function HandleEnemyLevel2FirstMidRazeFear(bot, enemyHero)
    if not State.enemyReachedLevel2First then return false end
    if bot:GetLevel() >= 2 then
        State.enemyReachedLevel2First = false
        return false
    end
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if not U.EnemyHasRaze(enemyHero) then return false end
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    local midRadius = 220
    if math.abs(dist - C.RAZE.MID_CENTER) > midRadius then return false end
    local retreatLoc = U.GetRetreatPositionFromEnemySF(bot, enemyHero)
    BeginForcedRetreat(bot, retreatLoc, 0.90)
    return true
end

local function HandleEnemyT1WaveDriftRetreat(bot, enemyHero, enemyTowers, allyCreeps, enemyCreeps)
    local underT1, t1 = IsBotUnderEnemyT1(bot, enemyTowers)
    if not underT1 or not t1 then
        State.enemyT1ClosestCreepDist = nil
        State.enemyT1ClosestCreepTime = 0
        return false
    end
    if ShouldAllowRiskyT1Commit(bot, enemyHero, enemyTowers, allyCreeps) then
        State.enemyT1ClosestCreepDist = nil
        State.enemyT1ClosestCreepTime = 0
        return false
    end
    local closestDist = math.huge
    local closestCreep = nil
    for _, c in pairs(allyCreeps or {}) do
        if c and c:IsAlive() then
            local name = c:GetUnitName() or ""
            local isSiege = name:find("siege") or name:find("catapult")
            if not isSiege then
                local d = GetUnitToLocationDistance(t1, c:GetLocation())
                if d < closestDist then
                    closestDist = d
                    closestCreep = c
                end
            end
        end
    end
    local prevDist = State.enemyT1ClosestCreepDist
    State.enemyT1ClosestCreepDist = (closestCreep and closestDist) or nil
    State.enemyT1ClosestCreepTime = GameTime()
    local driftStart = (C.T1_SAFETY and C.T1_SAFETY.CREEP_DRIFT_START) or 620
    local driftHard = (C.T1_SAFETY and C.T1_SAFETY.CREEP_DRIFT_HARD) or 700
    local driftDelta = (C.T1_SAFETY and C.T1_SAFETY.CREEP_DRIFT_DELTA) or 22
    local shouldRetreat = false
    if not closestCreep then
        shouldRetreat = true
    elseif closestDist >= driftHard then
        shouldRetreat = true
    elseif prevDist and closestDist >= driftStart and closestDist > (prevDist + driftDelta) then
        shouldRetreat = true
    end
    if not shouldRetreat then return false end
    if TryUseGlyphForT1Retreat(bot, enemyTowers, allyCreeps) then return true end
    local safeLoc = GetExtendedT1RetreatLocation(bot, enemyTowers, enemyCreeps, allyCreeps, "PASSIVE")
    BeginForcedRetreat(bot, safeLoc, 0.90)
    return true
end

local function GetBestPushTarget(bot, enemyCreeps, enemyTowers, allyCreeps)
    local bestTarget = nil
    local bestScore = math.huge
    for _, c in pairs(enemyCreeps or {}) do
        if c and c:IsAlive() then
            local dist = GetUnitToLocationDistance(bot, c:GetLocation())
            if dist <= (C.PUSH.PUSH_ATTACK_RANGE or 700) then
                local hp = c:GetHealth()
                local name = c:GetUnitName() or ""
                local score = dist
                if hp < 200 then score = score - 300 end
                if name:find("ranged") then score = score - 50 end
                if score < bestScore then
                    bestScore = score
                    bestTarget = c
                end
            end
        end
    end
    return bestTarget
end

local function HandleWavePush(bot, enemyHero, enemyCreeps, allyCreeps, enemyTowers, allyTowers, current_mode)
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if current_mode ~= "AGGRESSIVE" then return false end
    if not U.HasTreadsAdvantage(bot, enemyHero) then return false end
    local myHpPct = bot:GetHealth() / bot:GetMaxHealth()
    if myHpPct < (C.PUSH.MIN_HP_PCT_TO_PUSH or 0.50) then return false end
    if not enemyCreeps or #enemyCreeps == 0 then return false end
    if enemyHero and U.IsInEnemyRazeKillThreat(bot, enemyHero) then return false end
    if enemyHero and U.CanQuery(enemyHero) then
        local myStacks = U.GetShadowrazeDebuff(bot)
        if myStacks >= 1 then return false end
    end
    local pushTarget = GetBestPushTarget(bot, enemyCreeps, enemyTowers, allyCreeps)
    if not pushTarget then return false end
    if not IsSafeToAttack(bot, pushTarget:GetLocation(), enemyTowers, allyCreeps) then return false end
    if bot:GetCurrentActionType() ~= BOT_ACTION_TYPE_ATTACK or bot:GetAttackTarget() ~= pushTarget then
        bot:Action_AttackUnit(pushTarget, false)
        ClearMoveCache()
    end
    State.actionTaken = true
    return true
end

local function HandleT1TowerAttack(bot, enemyHero, enemyTowers, allyCreeps, allyTowers, current_mode)
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    if current_mode ~= "AGGRESSIVE" then return false end
    if not U.HasTreadsAdvantage(bot, enemyHero) then return false end
    local myHpPct = bot:GetHealth() / bot:GetMaxHealth()
    if myHpPct < (C.PUSH.MIN_HP_PCT_TO_PUSH or 0.50) then return false end
    if enemyHero and U.IsInEnemyRazeKillThreat(bot, enemyHero) then return false end
    local t1 = GetEnemyT1Tower(enemyTowers)
    if not t1 or not t1:IsAlive() then return false end
    local botDist = GetUnitToLocationDistance(bot, t1:GetLocation())
    if botDist > (C.PUSH.T1_ATTACK_RANGE or 900) then return false end
    local tankCount = 0
    for _, c in pairs(allyCreeps or {}) do
        if c and c:IsAlive() then
            local name = c:GetUnitName() or ""
            local isSiege = name:find("siege") or name:find("catapult")
            if not isSiege and GetUnitToLocationDistance(t1, c:GetLocation()) <= 760 then
                if c:GetHealth() >= (C.PUSH.TOWER_SAFE_CREEP_HP or 200) then
                    tankCount = tankCount + 1
                end
            end
        end
    end
    if tankCount < (C.PUSH.MIN_CREEPS_TO_TANK or 2) then return false end
    if enemyHero and U.CanQuery(enemyHero) then
        local eDist = GetUnitToLocationDistance(enemyHero, t1:GetLocation())
        if eDist <= 1200 then
            if U.EnemyCanUseRaze(enemyHero) and not U.CanKillEnemyWithTwoRazes(bot, enemyHero) then
                return false
            end
        end
    end
    if bot:GetCurrentActionType() ~= BOT_ACTION_TYPE_ATTACK or bot:GetAttackTarget() ~= t1 then
        bot:Action_AttackUnit(t1, true)
        ClearMoveCache()
    end
    State.actionTaken = true
    return true
end

local function HandleGuaranteedAttackKill(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local canOneShot, _ = U.CanOneShotEnemyHero(bot, enemyHero)
    if not canOneShot then return false end
    local attackRange = bot:GetAttackRange() + 60
    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    if dist <= attackRange then
        IssueHeroAttack(bot, enemyHero)
        State.lastHarassTime = GameTime()
        State.lastAggroTime = GameTime()
        State.aggroPullTime = GameTime() + 0.25
        return true
    end
    if dist <= attackRange + 300 then
        local botLoc = bot:GetLocation()
        local dir = (enemyHero:GetLocation() - botLoc):Normalized()
        local approachLoc = botLoc + dir * math.min(dist - attackRange + 20, 250)
        approachLoc = GetSafeApproachLoose(bot, approachLoc, enemyTowers or {}, allyCreeps or {})
        SmartMove(bot, approachLoc, 35)
        return true
    end
    return false
end

local function HandleGuaranteedRazeKill(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end
    local canKill, razeLabel = U.CanQuickTurnKillWithRaze(bot, enemyHero)
    if not canKill then return false end
    local ability = GetRazeAbilityByLabel(bot, razeLabel)
    if ability then
        local predLoc = U.PredictPosition(enemyHero, C.RAZE.CAST_POINT)
        local angleDiff = U.GetAngleDifference(bot, predLoc)
        if angleDiff <= C.RAZE.MAX_ANGLE_TO_CAST then
            U.SwitchTreadsIfNeeded(bot, 1)
            bot:Action_UseAbility(ability)
            StartRazeCast(ability, enemyHero, predLoc, C.RAZE.HIT_RADIUS)
            ClearMoveCache()
            return true
        else
            local botLoc = bot:GetLocation()
            local dir = (predLoc - botLoc):Normalized()
            local stepLoc = botLoc + dir * math.min(15, U.DistanceBetweenLocations(botLoc, predLoc))
            SmartMove(bot, stepLoc, 15)
            return true
        end
    end
    return false
end

local function HandleRetaliationAttack(bot, enemyHero, enemyTowers, allyCreeps)
    if not enemyHero or not U.CanQuery(enemyHero) then return false end
    if State.actionTaken then return false end
    if bot:IsUsingAbility() or bot:IsChanneling() then return false end

    local enemyIsHittingUs = false
    if enemyHero.GetAttackTarget and enemyHero:GetAttackTarget() == bot then
        enemyIsHittingUs = true
    end
    if not enemyIsHittingUs and bot.WasRecentlyDamagedByHero then
        enemyIsHittingUs = bot:WasRecentlyDamagedByHero(enemyHero, 1.5)
    end

    if not enemyIsHittingUs then return false end

    local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
    if dist > bot:GetAttackRange() + 50 then return false end

    local myHpPct = bot:GetHealth() / bot:GetMaxHealth()
    if myHpPct < 0.25 then return false end

    if not IsSafeToHarass(bot, enemyHero:GetLocation(), enemyTowers, allyCreeps) then return false end

    IssueHeroAttack(bot, enemyHero)
    State.lastHarassTime = GameTime()
    State.lastAggroTime = GameTime()
    State.aggroPullTime = GameTime() + 0.25
    return true
end

local function RealThink()
    local bot = GetBot()
    if not bot or not bot:IsAlive() then return end

    State.actionTaken = false

    if HandleActiveRazeValidation(bot) then return end
    if bot:IsChanneling() or bot:IsUsingAbility() then return end

    if State.forcedRetreatLoc and GameTime() < (State.forcedRetreatUntil or 0) then
        bot:Action_MoveToLocation(State.forcedRetreatLoc)
        State.lastMoveLoc = State.forcedRetreatLoc
        State.lastMoveTime = GameTime()
        State.actionTaken = true
        return
    elseif State.forcedRetreatLoc then
        ClearForcedRetreat()
    end

    ProcessTelemetry(bot)
    LevelUpAbilities(bot)

    if not State.aimingRaze then
        local hpPct = bot:GetHealth() / bot:GetMaxHealth()
        if hpPct < 0.30 then
            U.SwitchTreadsIfNeeded(bot, 0)
        else
            U.SwitchTreadsIfNeeded(bot, 2)
        end
    end

    local enemyHeroes = bot:GetNearbyHeroes(1600, true, BOT_MODE_NONE) or {}
    local enemyHero = nil
    for _, h in ipairs(enemyHeroes) do
        if U.CanQuery(h) then
            enemyHero = h
            break
        end
    end

    local earlyEnemyTowers = bot:GetNearbyTowers(1200, true) or {}
    local earlyAllyCreeps = bot:GetNearbyLaneCreeps(1200, false) or {}

    if HandleActiveSalveSafety(bot, enemyHero) then return end
    if HandleEnemyNearRazeCounter(bot, enemyHero) then return end

    if bot:GetLevel() >= 2 then
        State.enemyReachedLevel2First = false
    end
    if enemyHero and U.CanQuery(enemyHero) and U.EnemyHasRaze(enemyHero) then
        if bot:GetLevel() < 2 and enemyHero:GetLevel() >= 2 then
            State.enemyReachedLevel2First = true
        end
    end

    if enemyHero then
        if HandleGuaranteedRazeKill(bot, enemyHero, earlyEnemyTowers, earlyAllyCreeps) then return end
        if HandleGuaranteedAttackKill(bot, enemyHero, earlyEnemyTowers, earlyAllyCreeps) then return end
    end

    if HandleEmergencyRetreat(bot, enemyHero) then return end
    if HandleForcedSalve(bot) then return end
    HandleAutoBuySalveInsteadOfFountain(bot)
    if HandleFountainRecall(bot) then return end
    if HandleReturnTP(bot) then return end

    local myHpPct = bot:GetHealth() / bot:GetMaxHealth()
    local mpPct = bot:GetMana() / bot:GetMaxMana()
    local flask = U.GetActiveItemByName(bot, "item_flask")
    local clarity = U.GetActiveItemByName(bot, "item_clarity")
    local hasMango = U.HasItem(bot, "item_enchanted_mango")
    local isHealing = bot:HasModifier("modifier_flask_healing") or bot:HasModifier("modifier_clarity_potion")
    local returnHpPct = (C.TP and C.TP.RETURN_HP_PCT) or 0.50

    if bot:HasModifier("modifier_clarity_potion") and not bot:HasModifier("modifier_flask_healing") and myHpPct >= returnHpPct then
        isHealing = false
        ClearForcedRetreat()
    end

    local needsFlask = (myHpPct < 0.5 and flask and not isHealing)
    local needsClarity = (mpPct < 0.4 and clarity and not isHealing and not hasMango)

    if isHealing or needsFlask or needsClarity then
        local fountain = P.GetFountain(bot)
        local dangerRange = 850
        if enemyHero and enemyHero:GetUnitName() == "npc_dota_hero_nevermore" then
            if bot:HasModifier("modifier_flask_healing") or needsFlask then
                dangerRange = C.REGEN.FLASK_SAFE_DISTANCE or 1150
            else
                dangerRange = C.REGEN.ENEMY_SAFE_DISTANCE or 1100
            end
        end
        if IsInDangerForRegen(bot, dangerRange) then
            local moveLoc = P.GetT1Close(bot)
            if enemyHero then
                local dir = (fountain - enemyHero:GetLocation()):Normalized()
                moveLoc = enemyHero:GetLocation() + dir * dangerRange
            end
            BeginForcedRetreat(bot, moveLoc, 0.85)
            return
        end
        if needsFlask and GameTime() > State.lastItemUseTime + 0.3 then
            if HasEnemyProjectileIncoming(bot) then
                local safeLoc = GetSalveSafeRetreatLocation(bot, enemyHero)
                BeginForcedRetreat(bot, safeLoc, 0.65)
                return
            end
            bot:Action_UseAbilityOnEntity(flask, bot)
            State.lastItemUseTime = GameTime()
            State.actionTaken = true
            return
        elseif needsClarity and GameTime() > State.lastItemUseTime + 0.3 then
            bot:Action_UseAbilityOnEntity(clarity, bot)
            State.lastItemUseTime = GameTime()
            return
        elseif isHealing then
            local enemyCreepsNearby = bot:GetNearbyLaneCreeps(1200, true) or {}
            local allyCreepsNearby = bot:GetNearbyLaneCreeps(1200, false) or {}
            if #enemyCreepsNearby == 0 and #allyCreepsNearby == 0 then
                local targetPos = bot:HasModifier("modifier_flask_healing") and P.GetT1Close(bot) or C.POSITIONS.MIDLANE_CENTER
                if GetUnitToLocationDistance(bot, targetPos) > 200 then
                    SmartMove(bot, targetPos, 60)
                end
            elseif bot:HasModifier("modifier_flask_healing") then
                local safeLoc = P.GetLasthitPosition(bot, enemyCreepsNearby, allyCreepsNearby, nil, "PASSIVE")
                if enemyHero and U.CanQuery(enemyHero) then
                    local distToEnemy = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
                    if distToEnemy < dangerRange then
                        local dir = (fountain - enemyHero:GetLocation()):Normalized()
                        safeLoc = enemyHero:GetLocation() + dir * dangerRange
                    end
                end
                if not IsInDangerForRegen(bot, dangerRange) then
                    SmartMove(bot, safeLoc, 60)
                end
            end
            return
        end
    end

    local enemyCreeps = bot:GetNearbyLaneCreeps(1200, true) or {}
    local allyCreeps = bot:GetNearbyLaneCreeps(1200, false) or {}
    local enemyTowers = bot:GetNearbyTowers(1200, true) or {}
    local allyTowers = bot:GetNearbyTowers(1200, false) or {}
    local enemyAttackers = U.MergeLists(enemyCreeps, enemyTowers)
    local allyAttackers = U.MergeLists(allyCreeps, allyTowers)

    if enemyHero then U.UpdateEnemyRazeMissTracker(bot, enemyHero) end
    U.UpdateAllyCreepHealthTracking(allyCreeps)

    if HandleEnemyT1TowerDeaggro(bot, enemyTowers, allyCreeps, enemyCreeps) then return end

    local current_mode = U.GetPlaystyle(bot, enemyHero, allyCreeps, enemyCreeps)
    local enemyMissed = U.HasEnemyMissedRazeRecently()
    local enemyMissedAggro = enemyMissed and bot:GetLevel() > 1
    if bot:GetLevel() <= 1 and enemyMissed and current_mode == "AGGRESSIVE" then
        current_mode = "NEUTRAL"
    end

    if HandleGlyph(bot, enemyHero, enemyTowers, allyTowers, allyCreeps) then return end
    if HandleEnemyT1WaveDriftRetreat(bot, enemyHero, enemyTowers, allyCreeps, enemyCreeps) then return end

    local inKillThreat = U.IsInEnemyRazeKillThreat(bot, enemyHero)
    local secondStackActive, secondStackLabel = false, nil
    if enemyHero then
        secondStackActive, secondStackLabel = U.IsSecondStackDangerActive(bot, enemyHero)
    end

    if enemyHero and secondStackActive and secondStackLabel == "near" then
        if HandleNearRazeReplyPressure(bot, enemyHero, enemyTowers, allyCreeps) then return end
    end

    if inKillThreat then
        if HandleSafeDistanceFromEnemy(bot, enemyHero) then return end
    end

    if enemyHero and HandleEnemyLevel2FirstMidRazeFear(bot, enemyHero) then return end
    if enemyHero and HandleDryManaMidRazeAvoidance(bot, enemyHero) then return end

    local myStacks, myRemain = U.GetShadowrazeDebuff(bot)
    if enemyHero and myStacks >= 2 and myRemain > C.RAZE.RETREAT_MIN_REMAIN then
        local retreatLoc = U.GetRetreatPositionFromEnemySF(bot, enemyHero)
        BeginForcedRetreat(bot, retreatLoc, 1.20)
        return
    end

    if enemyHero and HandleBootDisadvantageMidRazeFear(bot, enemyHero) then return end

    local isHealingNow = U.IsActivelyHealing(bot)
    local hasCreeps = (#allyCreeps > 0) or (#enemyCreeps > 0)
    if not isHealingNow and not hasCreeps then
        local targetPos = P.GetT1Close(bot)
        if GetUnitToLocationDistance(bot, C.POSITIONS.MIDLANE_CENTER) > 1500 then
            targetPos = C.POSITIONS.MIDLANE_CENTER
        end
        if GetUnitToLocationDistance(bot, targetPos) > 200 then
            SmartMove(bot, targetPos, 80)
        end
    end

    local mustRetreatFromT1Soon = U.ShouldRetreatFromT1LastCreep(bot, allyCreeps, enemyTowers, enemyHero)
    if mustRetreatFromT1Soon and not ShouldAllowRiskyT1Commit(bot, enemyHero, enemyTowers, allyCreeps) then
        if TryUseGlyphForT1Retreat(bot, enemyTowers, allyCreeps) then return end
        local safeLoc = GetExtendedT1RetreatLocation(bot, enemyTowers, enemyCreeps, allyCreeps, "PASSIVE")
        BeginForcedRetreat(bot, safeLoc, 0.85)
        return
    end

    if enemyHero and not inKillThreat then
        if HandleImmediateNearRazePunish(bot, enemyHero, current_mode, enemyTowers, allyCreeps) then return end
    end

    if enemyHero and GetPotentialCombatMana(bot) >= 150 and not inKillThreat then
        local q = bot:GetAbilityByName("nevermore_shadowraze1")
        if q and q:GetLevel() > 0 then
            local dmg2 = U.GetTwoRazeDamage(bot, enemyHero)
            local lethal = dmg2 >= enemyHero:GetHealth()
            if lethal then
                local myBoots = U.HasItem(bot, "item_boots") or U.HasItem(bot, "item_power_treads")
                local eBoots = U.HasItem(enemyHero, "item_boots") or U.HasItem(enemyHero, "item_power_treads")
                local canChase = myBoots and not eBoots
                local chaseTargetLoc = enemyHero:GetLocation()
                local isSafeChase = true
                for _, tower in pairs(enemyTowers) do
                    if tower:IsAlive() then
                        local name = tower:GetUnitName() or ""
                        if name:find("tower2") or name:find("tower3") or name:find("tower4") then
                            if GetUnitToLocationDistance(tower, chaseTargetLoc) < 850 then
                                isSafeChase = false
                                break
                            end
                        end
                    end
                end
                local glyphActive = State.glyphUsedForDive and (GameTime() - State.glyphDiveTime) < 5.0
                local normalSafe = (GetSafeApproachLoose(bot, chaseTargetLoc, enemyTowers, allyCreeps) == chaseTargetLoc)
                if (canChase and isSafeChase) or normalSafe or glyphActive then
                    if HandleLethalTwoRazeSequence(bot, enemyHero, enemyTowers, allyCreeps) then
                        return
                    end
                    if HandleNearRazeFinish(bot, enemyHero, enemyTowers, allyCreeps) then
                        return
                    end
                    if TryRazeEnemy(bot, enemyHero, "AGGRESSIVE", enemyTowers, allyCreeps, true, false) then
                        return
                    end
                end
            end
        end
    end

    if enemyHero and not inKillThreat then
        if HandleMirrorRazeTrade(bot, enemyHero, enemyTowers, allyCreeps, allyCreeps, enemyCreeps) then return end
    end

    if enemyHero and not inKillThreat and secondStackActive then
        if secondStackLabel == "mid" then
            if HandleMidStackSpacing(bot, enemyHero, enemyTowers, allyCreeps) then return end
        elseif secondStackLabel == "near" then
            if HoldNearRazeReplySpacing(bot, enemyHero, enemyTowers, allyCreeps) then return end
        end
    end

    if enemyHero and not inKillThreat then
        if HandleCloseAttackFinish(bot, enemyHero, enemyTowers, allyCreeps) then return end
    end

    if enemyHero and not inKillThreat and not secondStackActive then
        if HandleNearRazeFinish(bot, enemyHero, enemyTowers, allyCreeps) then return end
    end

    if enemyHero and not inKillThreat and not secondStackActive then
        if ForceExtendEnemyStack(bot, enemyHero, enemyTowers, allyCreeps) then return end
    end

    local ward = U.GetActiveItemByName(bot, "item_ward_observer")
    if ward and not ShouldPrioritizeStackExtensionOverUtility(bot, enemyHero) then
        local wardLoc = (bot:GetTeam() == TEAM_RADIANT) and C.POSITIONS.WARD_RADIANT or C.POSITIONS.WARD_DIRE
        local distToWard = GetUnitToLocationDistance(bot, wardLoc)
        if distToWard > 450 then
            SmartMove(bot, wardLoc, 60)
        else
            bot:Action_UseAbilityOnLocation(ward, wardLoc)
            ClearMoveCache()
        end
        return
    end

    local shouldFearRaze, retreatLoc = U.ShouldRetreatFromEnemyRazeStack(bot, enemyHero)
    if shouldFearRaze then
        if retreatLoc then
            BeginForcedRetreat(bot, retreatLoc, 0.80)
        end
        return
    end

    local aggroCount = 0
    local closeCreepsCount = 0
    local hasRangedAggro = false
    local is_taking_damage = bot:WasRecentlyDamagedByCreep(1.5)
    for _, c in pairs(enemyCreeps) do
        if c:IsAlive() then
            if U.CanQuery(c) and c:GetAttackTarget() == bot then
                aggroCount = aggroCount + 1
                local name = c:GetUnitName() or ""
                if name:find("ranged") or name:find("siege") then hasRangedAggro = true end
            end
            if GetUnitToLocationDistance(bot, c:GetLocation()) < 350 then
                closeCreepsCount = closeCreepsCount + 1
            end
        end
    end

    if U.ShouldRetreatFromT1LastCreep(bot, allyCreeps, enemyTowers, enemyHero) then
        if TryUseGlyphForT1Retreat(bot, enemyTowers, allyCreeps) then return end
        local safeLoc = GetExtendedT1RetreatLocation(bot, enemyTowers, enemyCreeps, allyCreeps, "PASSIVE")
        BeginForcedRetreat(bot, safeLoc, 0.85)
        return
    end

    local is_under_my_tower = false
    for _, t in pairs(allyTowers) do
        if GetUnitToLocationDistance(bot, t:GetLocation()) < 850 then
            is_under_my_tower = true
            break
        end
    end

    if GameTime() > State.deaggroTime then
        local should_deaggro = false
        if allyCreeps and #allyCreeps > 0 then
            if aggroCount >= 2 or closeCreepsCount >= 2 or hasRangedAggro or is_taking_damage then
                should_deaggro = true
            end
        else
            if is_under_my_tower and bot:GetHealth() > 300 then
                if aggroCount >= 2 or (aggroCount >= 1 and is_taking_damage) then
                    should_deaggro = true
                end
            else
                if aggroCount >= 2 or (aggroCount >= 1 and bot:GetHealth() < 450) or hasRangedAggro then
                    should_deaggro = true
                end
            end
        end
        if should_deaggro then
            bot:Action_ClearActions(false)
            ClearMoveCache()
            State.heroAttackTarget = nil
            State.heroAttackTime = 0
            local fountain = P.GetFountain(bot)
            if allyCreeps and #allyCreeps > 0 then
                local closestAlly = allyCreeps[1]
                local minDist2 = 9999
                for _, c in pairs(allyCreeps) do
                    local d = GetUnitToLocationDistance(bot, c:GetLocation())
                    if d < minDist2 then
                        minDist2 = d
                        closestAlly = c
                    end
                end
                local safe_pos = bot:GetLocation() + (fountain - bot:GetLocation()):Normalized() * 400
                bot:ActionQueue_AttackUnit(closestAlly, true)
                bot:ActionQueue_MoveToLocation(safe_pos)
                State.deaggroTime = GameTime() + 1.2
            else
                local kite_pos = bot:GetLocation() + (fountain - bot:GetLocation()):Normalized() * 300
                bot:Action_MoveToLocation(kite_pos)
                State.deaggroTime = GameTime() + 0.6
            end
            return
        end
    end

    if GameTime() < State.aggroPullTime then
        if IsHeroAttackWindupLocked(bot) then return end
        if IsInHeroAttackAnimation(bot) then return end
        SmartMove(bot, P.GetLasthitPosition(bot, enemyCreeps, allyCreeps, nil, current_mode), 60)
        return
    end

    local bestTarget, isDeny = L.GetBestTarget(bot, enemyCreeps, allyCreeps, enemyAttackers, allyAttackers)

    local am_i_tanking_too_much = false
    if not allyCreeps or #allyCreeps == 0 then
        if aggroCount >= 2 or (aggroCount >= 1 and bot:GetHealth() < 450) then am_i_tanking_too_much = true end
    else
        if aggroCount >= 3 or (aggroCount >= 2 and bot:GetHealth() < 400) then am_i_tanking_too_much = true end
    end

    if is_under_my_tower and bot:GetHealth() > 300 then
        if aggroCount <= 1 then am_i_tanking_too_much = false end
    end

    if am_i_tanking_too_much then
        if not (bestTarget and U.GetTimeToKillable(bot, bestTarget, isDeny and enemyAttackers or allyAttackers) <= 0.6) then
            local fountain = P.GetFountain(bot)
            local safe_pos = bot:GetLocation() + (fountain - bot:GetLocation()):Normalized() * 250
            SmartMove(bot, safe_pos, 60)
            return
        end
    end

    if is_under_my_tower and bot:GetHealth() > 300 then am_i_tanking_too_much = false end

    if am_i_tanking_too_much then
        if not (bestTarget and U.GetTimeToKillable(bot, bestTarget, isDeny and enemyAttackers or allyAttackers) <= 0.6) then
            SmartMove(bot, P.GetLasthitPosition(bot, enemyCreeps, allyCreeps, nil, current_mode), 60)
            return
        end
    end

    if enemyHero and not am_i_tanking_too_much and not inKillThreat and not secondStackActive then
        if HandleRazeRangedCreepWithHero(bot, enemyHero, enemyCreeps, allyAttackers, enemyTowers, allyCreeps) then return end
    end

    if enemyHero and not am_i_tanking_too_much and not inKillThreat and not secondStackActive and U.IsEnemyHighValueRegen(enemyHero) then
        local distToEnemy = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
        if bot:GetMana() >= 75 and distToEnemy <= 1100 then
            if TryRazeEnemy(bot, enemyHero, "AGGRESSIVE", enemyTowers, allyCreeps, false, false) then return end
        end
        local attackRange = bot:GetAttackRange() + 60
        if distToEnemy <= attackRange then
            if myHpPct > 0.30 and IsSafeToHarass(bot, enemyHero:GetLocation(), enemyTowers, allyCreeps) then
                IssueHeroAttack(bot, enemyHero)
                State.lastHarassTime = GameTime()
                State.lastAggroTime = GameTime()
                State.aggroPullTime = GameTime() + 0.25
                return
            end
        elseif distToEnemy <= C.HARASS.INTERRUPT_APPROACH and myHpPct > 0.40 and GetPotentialCombatMana(bot) >= 75 then
            local botLoc = bot:GetLocation()
            local dir = (enemyHero:GetLocation() - botLoc):Normalized()
            local approachLoc = botLoc + dir * math.min(distToEnemy - attackRange + 50, 400)
            approachLoc = U.ClampMinDistFromEnemy(bot, enemyHero, approachLoc)
            approachLoc = GetSafeApproachLoose(bot, approachLoc, enemyTowers, allyCreeps)
            SmartMove(bot, approachLoc, 60)
            return
        end
    end

    if enemyHero and not am_i_tanking_too_much and not inKillThreat and not secondStackActive then
        local eStacks, eRem = U.GetShadowrazeDebuff(enemyHero)
        if eStacks >= 2 and eRem <= C.RAZE.EXTEND_AT + 0.6 then
            if TryRazeEnemy(bot, enemyHero, "AGGRESSIVE", enemyTowers, allyCreeps, false, false) then return end
        end
    end

    if enemyHero and not am_i_tanking_too_much and not inKillThreat and not secondStackActive and enemyMissedAggro and bot:GetMana() >= 75 then
        local distToEnemy = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
        if distToEnemy <= 950 then
            if TryRazeEnemy(bot, enemyHero, "AGGRESSIVE", enemyTowers, allyCreeps, false, false) then return end
        end
    end

    if HandleItemsAndConsumables(bot, bestTarget, enemyCreeps, allyAttackers, enemyTowers, enemyHero) then return end

    if bot:GetGold() >= 65 then
        if current_mode == "PASSIVE" and myHpPct < 0.60 then
            if not U.HasItem(bot, "item_flask") and bot:GetItemInSlot(14) == nil and bot:GetGold() >= 100 then
                bot:ActionImmediate_PurchaseItem("item_flask")
            end
        end
        if bot:GetMana() < 75 and not U.HasItem(bot, "item_enchanted_mango") and bot:GetItemInSlot(14) == nil then
            bot:ActionImmediate_PurchaseItem("item_enchanted_mango")
        end
    end

    local is_free_to_prehit = true
    if bestTarget then
        local t_killable = U.GetTimeToKillable(bot, bestTarget, isDeny and enemyAttackers or allyAttackers)
        if t_killable < (bot:GetSecondsPerAttack() + 0.3) then is_free_to_prehit = false end
    end

    local prehit_target = nil
    if is_free_to_prehit and not State.prepTarget and not am_i_tanking_too_much then
        local attack_cd = bot:GetSecondsPerAttack()
        for _, c in pairs(enemyCreeps) do
            if c:IsAlive() then
                local in_tower_range = false
                for _, t in pairs(allyTowers) do
                    if GetUnitToLocationDistance(t, c:GetLocation()) < 750 then
                        in_tower_range = true
                        break
                    end
                end
                if in_tower_range then
                    local myDmg = U.SFDamageRange(bot, c).min
                    local hp = c:GetHealth()
                    if hp > (myDmg * 1.5) then
                        local ctx_normal = U.GetTargetPredictionContext(c, allyAttackers)
                        if not U.HasLasthitWindow(ctx_normal, c, myDmg, 0) then
                            local ctx_prehit = U.GetTargetPredictionContext(c, allyAttackers)
                            ctx_prehit.hp = ctx_prehit.hp - myDmg
                            if U.HasLasthitWindow(ctx_prehit, c, myDmg, attack_cd) then
                                prehit_target = c
                                break
                            end
                        end
                    end
                end
            end
        end

        if not prehit_target then
            for _, c in pairs(allyCreeps) do
                if c:IsAlive() and (c:GetHealth() / c:GetMaxHealth()) < 0.5 then
                    local in_enemy_tower_range = false
                    for _, t in pairs(enemyTowers) do
                        if GetUnitToLocationDistance(t, c:GetLocation()) < 750 then
                            in_enemy_tower_range = true
                            break
                        end
                    end
                    if in_enemy_tower_range then
                        local eSF = enemyHero
                        local eDmg = eSF and U.CanQuery(eSF) and eSF:GetAttackDamage() or U.SFDamageRange(bot, c).min
                        local myDmg = U.SFDamageRange(bot, c).min
                        local hp = c:GetHealth()
                        if hp > myDmg then
                            local ctx_normal = U.GetTargetPredictionContext(c, enemyAttackers)
                            if U.HasLasthitWindow(ctx_normal, c, eDmg, 0) then
                                local ctx_prehit = U.GetTargetPredictionContext(c, enemyAttackers)
                                ctx_prehit.hp = ctx_prehit.hp - myDmg
                                if not U.HasLasthitWindow(ctx_prehit, c, eDmg, 0) then
                                    prehit_target = c
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end

        if prehit_target then
            local tower_proj_flying = false
            local projs = prehit_target:GetIncomingTrackingProjectiles()
            if projs then
                for _, p in pairs(projs) do
                    if p.is_attack and p.caster and p.caster:IsTower() then
                        tower_proj_flying = true
                        break
                    end
                end
            end
            if not tower_proj_flying then
                State.prepTarget = prehit_target
                if IsSafeToAttack(bot, prehit_target:GetLocation(), enemyTowers, allyCreeps) then
                    if bot:GetCurrentActionType() ~= BOT_ACTION_TYPE_ATTACK or bot:GetAttackTarget() ~= prehit_target then
                        bot:Action_AttackUnit(prehit_target, false)
                        ClearMoveCache()
                    end
                else
                    SmartMove(bot, GetSafeApproach(bot, bot:GetLocation(), enemyTowers, allyCreeps), 60)
                end
                return
            end
        end
    end

    local allowHarass = (is_free_to_prehit or enemyMissedAggro) and not State.prepTarget and not inKillThreat and not secondStackActive
    
    if HandleRetaliationAttack(bot, enemyHero, enemyTowers, allyCreeps) then return end

    if allowHarass and enemyHero then
        local canRazePressure, razeMode = ShouldTryRazePressure(bot, enemyHero, current_mode, aggroCount)
        if canRazePressure then
            if TryRazeEnemy(bot, enemyHero, razeMode, enemyTowers, allyCreeps, false, false) then return end
        end
        if ShouldAttackHarassEnemy(bot, enemyHero, current_mode, aggroCount, enemyTowers, allyCreeps) then
            IssueHeroAttack(bot, enemyHero)
            State.lastHarassTime = GameTime()
            State.lastAggroTime = GameTime()
            State.aggroPullTime = GameTime() + 0.25
            return
        end

        local dist = GetUnitToLocationDistance(bot, enemyHero:GetLocation())
        local approachThreshold = GetEnemyApproachDistance(enemyMissedAggro)
        local minHpPct = enemyMissedAggro and C.HARASS.MIN_HP_PCT_MISS or C.HARASS.MIN_HP_PCT
        local effectiveMode = enemyMissedAggro and "AGGRESSIVE" or current_mode
        if (effectiveMode == "AGGRESSIVE" or (effectiveMode == "NEUTRAL" and enemyMissedAggro))
            and aggroCount <= 1
            and myHpPct >= minHpPct
            and dist > bot:GetAttackRange() + 50
            and dist < approachThreshold then
            local botLoc = bot:GetLocation()
            local dir = (enemyHero:GetLocation() - botLoc):Normalized()
            local stepIn = math.min(dist - bot:GetAttackRange() + 30, 350)
            local rawApproach = botLoc + dir * stepIn
            local futureDist = U.DistanceBetweenLocations(rawApproach, enemyHero:GetLocation())
            if U.ShouldFearBootsMidRaze(bot, enemyHero) and math.abs(futureDist - C.RAZE.MID_CENTER) <= 220 then
                return
            end
            local rawApproachClamped = U.ClampMinDistFromEnemy(bot, enemyHero, rawApproach)
            local approachLoc = GetSafeApproachLoose(bot, rawApproachClamped, enemyTowers, allyCreeps)
            SmartMove(bot, approachLoc, 60)
            return
        end
    end

    local isAttacking = (bot:GetCurrentActionType() == BOT_ACTION_TYPE_ATTACK)
    local target = bot:GetAttackTarget()
    if isAttacking and target and target:IsAlive() then
        if State.attackTarget ~= target then
            State.attackTarget = target
            State.attackStartTime = GameTime()
            State.firedThisAttack = false
        end
        if State.prepTarget == target then return end
        local targetIsHero = target.IsHero and target:IsHero()
        local elapsed = GameTime() - State.attackStartTime
        local ap = bot:GetAttackPoint()
        local remaining_windup = math.max(0, ap - elapsed)
        if targetIsHero then return end
        local dist = GetUnitToLocationDistance(bot, target:GetLocation())
        local projSpeed = bot:GetAttackProjectileSpeed() or C.HERO.PROJECTILE_SPEED
        local impact_time = remaining_windup + (dist / projSpeed) + C.LASTHIT.NET_LATENCY
        local isAlly = (target:GetTeam() == bot:GetTeam())
        local attackers = isAlly and enemyAttackers or allyAttackers
        local ctx = U.GetTargetPredictionContext(target, attackers)
        local predHP = U.PredictHPWithContext(ctx, target, impact_time)
        local atkCount = 0
        for _, atk in pairs(attackers) do
            if atk and U.CanQuery(atk) and atk:GetAttackTarget() == target then atkCount = atkCount + 1 end
        end
        local dmg, safety_margin = U.GetEffectiveDamageAndMargin(bot, target, atkCount)
        local kill_threshold = dmg - safety_margin
        local dmgRange = U.SFDamageRange(bot, target)
        local commit_threshold = math.max(kill_threshold, dmgRange.avg)
        local commit_buffer = C.LASTHIT.COMMIT_HP_BUFFER or 8
        local cancel_window = C.LASTHIT.CANCEL_WINDOW or math.max(0.03, math.min(0.08, ap * 0.20))
        local shouldCancel = (predHP <= 0) or (predHP > commit_threshold + commit_buffer)
        if shouldCancel then
            if remaining_windup > 0.01 and remaining_windup <= cancel_window then
                bot:Action_ClearActions(true)
                ClearMoveCache()
                State.attackTarget = nil
                State.attackStartTime = 0
                State.firedThisAttack = false
            end
            return
        else
            if remaining_windup <= 0.05 and not State.firedThisAttack then
                State.firedThisAttack = true
            end
            return
        end
    else
        State.attackTarget = nil
        State.attackStartTime = 0
        State.firedThisAttack = false
    end

    if bestTarget then
        local targetLoc = bestTarget:GetLocation()
        local botLoc = bot:GetLocation()
        local dist = GetUnitToLocationDistance(bot, targetLoc)
        local projSpeed = bot:GetAttackProjectileSpeed() or C.HERO.PROJECTILE_SPEED
        local ap = bot:GetAttackPoint()
        local ms = bot:GetCurrentMovementSpeed() or 305
        local botFacing = bot:GetFacing()
        local angleToTarget = math.deg(Atan2(targetLoc.y - botLoc.y, targetLoc.x - botLoc.x))
        if angleToTarget < 0 then angleToTarget = angleToTarget + 360 end
        local angleDiff = math.abs(botFacing - angleToTarget)
        if angleDiff > 180 then angleDiff = 360 - angleDiff end
        local turn_time = angleDiff > 15 and (math.rad(angleDiff) / (0.6 * math.pi)) or 0
        local current_t_attack = turn_time + ap + (dist / projSpeed) + C.LASTHIT.NET_LATENCY
        local DESIRED_ATK_RANGE = 450
        local time_to_walk = math.max(0, dist - DESIRED_ATK_RANGE) / ms
        local ranged_t_attack = ap + (DESIRED_ATK_RANGE / projSpeed) + C.LASTHIT.NET_LATENCY
        local attackers = isDeny and enemyAttackers or allyAttackers
        local t_killable = U.GetTimeToKillable(bot, bestTarget, attackers)
        if (time_to_walk + ranged_t_attack + 0.1) < t_killable then
            if dist > DESIRED_ATK_RANGE then
                local dir = (botLoc - targetLoc):Normalized()
                local moveTarget = GetSafeApproach(bot, targetLoc + dir * DESIRED_ATK_RANGE, enemyTowers, allyCreeps)
                SmartMove(bot, moveTarget, 60)
            else
                if isAttacking then
                    bot:Action_ClearActions(true)
                    ClearMoveCache()
                end
            end
            return
        elseif t_killable <= (current_t_attack + 0.05) then
            if not (isAttacking and target == bestTarget) then
                if IsSafeToAttack(bot, targetLoc, enemyTowers, allyCreeps) then
                    bot:Action_AttackUnit(bestTarget, true)
                    ClearMoveCache()
                else
                    SmartMove(bot, GetSafeApproach(bot, botLoc, enemyTowers, allyCreeps), 60)
                end
            end
            return
        else
            if dist > 500 then
                local dir = (botLoc - targetLoc):Normalized()
                local moveTarget = GetSafeApproach(bot, targetLoc + dir * 480, enemyTowers, allyCreeps)
                SmartMove(bot, moveTarget, 60)
            end
            return
        end
    end

    if not bestTarget and not State.prepTarget then
        if HandleWavePush(bot, enemyHero, enemyCreeps, allyCreeps, enemyTowers, allyTowers, current_mode) then return end
    end

    if not bestTarget and not State.prepTarget then
        if HandleT1TowerAttack(bot, enemyHero, enemyTowers, allyCreeps, allyTowers, current_mode) then return end
        if not enemyHero or GetUnitToLocationDistance(bot, enemyHero:GetLocation()) > 1500 then
            for _, tower in pairs(enemyTowers) do
                if tower:IsAlive() and GetUnitToLocationDistance(bot, tower:GetLocation()) < 1000 and _hasTankCreepUnderTower(tower, allyCreeps) then
                    if bot:GetCurrentActionType() ~= BOT_ACTION_TYPE_ATTACK or bot:GetAttackTarget() ~= tower then
                        bot:Action_AttackUnit(tower, true)
                        ClearMoveCache()
                    end
                    return
                end
            end
        end
    end

    local pos = P.GetLasthitPosition(bot, enemyCreeps, allyCreeps, nil, current_mode)
    pos = GetSafeApproach(bot, pos, enemyTowers, allyCreeps)
    if GetUnitToLocationDistance(bot, pos) > 100 then
        SmartMove(bot, pos, 60)
    end
end

function Think()
    local bot = GetBot()
    if not bot or not bot:IsAlive() then
        State.needsTP = true
        State.emergencyRetreat = nil
        State.emergencyRetreatStartTime = 0
        State.emergencyTPQueued = false
        State.enemyT1ClosestCreepDist = nil
        State.enemyT1ClosestCreepTime = 0
        State.goingToFountain = false
        State.fountainReason = nil
        State.enemyReachedLevel2First = false
        State.heroAttackTarget = nil
        State.heroAttackTime = 0
        ClearForcedRetreat()
        ClearRazeState()
        ClearMoveCache()
        return
    end

    local success, err = pcall(RealThink)
    if not success then
        print("[SF-BOT CRITICAL ERROR] " .. tostring(err))
    end
end