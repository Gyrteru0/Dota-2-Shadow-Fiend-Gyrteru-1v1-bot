-- scripts/vscripts/bots/nevermore/constants.lua

local C = {}

C.HERO = {
    PROJECTILE_SPEED = 1200,
}

C.LASTHIT = {
    NET_LATENCY       = 0.05,
    DENY_HP_THRESHOLD = 0.50,
    CANCEL_WINDOW     = 0.08,
    COMMIT_HP_BUFFER  = 8,
}

C.RAZE = {
    NEAR_CENTER         = 200,
    MID_CENTER          = 450,
    FAR_CENTER          = 700,
    HIT_RADIUS          = 250,
    STRICT_RADIUS       = 190,
    CAST_POINT          = 0.55,
    PREDICT_DELAY       = 0.62,
    EXTEND_AT           = 3.05,
    MAX_ANGLE_TO_CAST   = 8,
    ENEMY_THREAT_RANGE  = 930,
    RETREAT_MIN_REMAIN  = 0.35,
    MISS_DETECT_WINDOW  = 0.75,
    MISS_ADVANTAGE_TIME = 6.0,
}

C.HARASS = {
    BASE_COOLDOWN          = 0.0,
    MISS_BONUS_COOLDOWN    = 0.0,
    APPROACH_DISTANCE      = 800,
    APPROACH_DISTANCE_MISS = 1100,
    MIN_HP_PCT             = 0.45,
    MIN_HP_PCT_MISS        = 0.35,
    INTERRUPT_APPROACH     = 1300,
}

C.NECROMASTERY = {
    BASE_DMG_PER_SOUL      = 1.35,
    DMG_PER_SOUL_PER_LEVEL = 0.15,
}

C.TP = {
    RETURN_DISTANCE_FROM_T1 = 3200,
    FOUNTAIN_RADIUS         = 400,
    RETURN_HP_PCT           = 0.50,
}

C.POSITIONS = {
    MID_LANE_CENTER      = Vector(503.58, -1010.36, 1124.97),
    MIDLANE_CENTER       = Vector(503.58, -1010.36, 1124.97),
    MID_FOUNTAIN_RADIANT = Vector(-6848, -6336, 384),
    MID_FOUNTAIN_DIRE    = Vector(6656, 6080, 384),
    RADIANT_T1           = Vector(-1544.00, -2008.00, 1144.05),
    RADIANT_T1_CLOSE     = Vector(-1200.00, -1700.00, 1144.00),
    RADIANT_FLANK_TOP    = Vector(-1417.84, -1061.84, 1123.81),
    RADIANT_FLANK_BOT    = Vector(-591.38, -1812.09, 1138.51),
    WARD_RADIANT         = Vector(-304.583435, -1010.216370, 128.000000),
    DIRE_T1              = Vector(521.28, 48.31, 1146.80),
    DIRE_T1_CLOSE        = Vector(250.00, -200.00, 1146.00),
    DIRE_FLANK_TOP       = Vector(-425.08, -37.47, 1123.98),
    DIRE_FLANK_BOT       = Vector(423.34, -847.56, 1117.69),
    WARD_DIRE            = Vector(-514.736816, 293.893494, 128.000000),
}

C.ITEM_PRIORITY = {
    ["item_kaya"]              = 100,
    ["item_dragon_lance"]      = 90,
    ["item_power_treads"]      = 80,
    ["item_boots"]             = 76,
    ["item_staff_of_wizardry"] = 75,
    ["item_blade_of_alacrity"] = 74,
    ["item_belt_of_strength"]  = 73,
    ["item_robe"]              = 72,
    ["item_bracer"]            = 70,
    ["item_magic_wand"]        = 60,
    ["item_magic_stick"]       = 50,
    ["item_circlet"]           = 40,
    ["item_gauntlets"]         = 35,
    ["item_faerie_fire"]       = 30,
    ["item_enchanted_mango"]   = 25,
    ["item_flask"]             = 20,
    ["item_tango"]             = 15,
    ["item_branches"]          = 10,
    ["item_ward_observer"]     = 5,
}

C.EMERGENCY = {
    RAZE_KILL_FACTOR     = 1.15,
    SINGLE_RAZE_FACTOR   = 1.05,
    MIN_HP_ABSOLUTE      = 180,
    COURIER_SEARCH_RANGE = 3000,
    COURIER_MEET_RANGE   = 1500,
}

C.GLYPH = {
    AVAILABLE_AT        = 180,
    COOLDOWN            = 300,
    T1_HP_PCT_THRESHOLD = 0.15,
    T1_HP_ABS_THRESHOLD = 400,
    KILL_DIVE_RANGE     = 900,
}

C.T1_SAFETY = {
    LAST_CREEP_HP_LOSS_CHECK = true,
    RETREAT_BUFFER           = 250,
    CREEP_DRIFT_START        = 620,
    CREEP_DRIFT_HARD         = 700,
    CREEP_DRIFT_DELTA        = 22,
}

C.FORCED_SALVE = {
    HP_PCT_THRESHOLD = 0.50,
}

C.SALVE_AUTOBUY = {
    HP_PCT_THRESHOLD = 0.40,
    MIN_GOLD         = 110,
    BUY_COOLDOWN     = 8.0,
}

C.SAFE_DISTANCE = {
    MIN_DISTANCE_FROM_ENEMY = 750,
    MIN_DISTANCE_CRITICAL   = 950,
    CRITICAL_HP_FACTOR      = 1.05,
    KILL_THREAT_FACTOR      = 1.20,
    SINGLE_KILL_FACTOR      = 1.10,
}

C.FINISH = {
    MIN_STACKS_FOR_CLOSE = 2,
    CLOSE_APPROACH_RANGE = 600,
    MIN_HP_PCT_FOR_CLOSE = 0.30,
}

C.BOOT_FEAR = {
    MID_RAZE_RADIUS       = 220,
    RETREAT_DURATION      = 0.95,
    RETREAT_DISTANCE_BONUS = 140,
    TWO_RAZE_MANA_COST    = 150,
    STICK_CHARGES_THREAT  = 10,
}

C.NEAR_REPLY = {
    WAIT_AFTER_HIT   = 1.0,
    HOLD_DISTANCE    = 215,
    HOLD_MIN_DISTANCE = 150,
    HOLD_MAX_DISTANCE = 250,
    HOLD_TOLERANCE    = 25,
}

C.FORCE_EXTEND = {
    PREFER_MID_WITH_BOOTS = true,
    FAR_DOWNGRADE_TO_MID  = true,
    FAR_CANCEL_TOLERANCE  = 60,
}

C.PUSH = {
    TREADS_ADVANTAGE_PUSH = true,
    PUSH_ATTACK_RANGE     = 700,
    T1_ATTACK_RANGE       = 900,
    MIN_CREEPS_TO_TANK    = 2,
    MIN_HP_PCT_TO_PUSH    = 0.50,
    TOWER_SAFE_CREEP_HP   = 200,
}

C.REGEN = {
    ENEMY_SAFE_DISTANCE = 1100,
    FLASK_SAFE_DISTANCE = 1150,
}

C.FOUNTAIN = {
    GO_HP_CRITICAL_PCT  = 0.15,
    GO_HP_WITH_MANA_PCT = 0.0,
    GO_MANA_WITH_HP_PCT = 0.0,
    STICK_CHARGES_ENOUGH = 10,
    WAIT_FULL_HP_PCT    = 0.98,
    WAIT_FULL_MANA_PCT  = 0.98,
    AT_FOUNTAIN_RADIUS  = 500,
}

C.STACK_NEAR_FEAR = {
    MIN_DISTANCE   = 470,
    RETREAT_BUFFER = 60,
}

return C