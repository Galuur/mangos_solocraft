--[[
    Solocraft for MaNGOS Zero (Vanilla 1.12.1)
    Ported from AzerothCore mod-solocraft by loopy
    Requires: Eluna scripting engine compiled into MaNGOS Zero

    Installation:
        Copy to: <mangos_root>/bin/lua_scripts/solocraft.lua
        Reload:  .reload eluna  (or restart server)

    Architecture:
        Eluna has per-map Lua state. Each map instance has its own globals.

        PLAYER_EVENT_ON_MAP_CHANGE (28) fires on the DESTINATION map.
          - Dungeon entry: destination = dungeon -> dungeon Lua state
          - Dungeon exit:  destination = world  -> world Lua state

        MAP_EVENT_ON_PLAYER_LEAVE (22) fires on the map being LEFT.
          - Dungeon exit: fires on dungeon Lua state (same state as entry)
          - Registered globally with RegisterServerEvent(22, handler).

        So: entry and exit both fire on the dungeon's Lua state.
        player_data[guid] written on entry is readable on exit.
--]]

-- ============================================================
-- CONFIG
-- ============================================================

local SOLOCRAFT_ENABLED     = true
local SOLOCRAFT_ANNOUNCE    = true
local STATS_MULT            = 100.0  -- health/mana scaling percentage
local DAMAGE_MULT           = 100.0  -- physical damage scaling percentage
local XP_ENABLED            = true
local XP_BAL_ENABLED        = true
local LEVEL_DIFF            = 10
local DEFAULT_DUNGEON_LEVEL = 60
local DEFAULT_5MAN          = 5.0
local DEFAULT_RAID_20       = 20.0
local DEFAULT_RAID_40       = 40.0

-- ============================================================
-- INSTANCE TABLES
-- ============================================================

local diff_multiplier = {
    [33]  = 5.0,   -- Shadowfang Keep
    [34]  = 5.0,   -- The Stockade
    [36]  = 5.0,   -- The Deadmines
    [43]  = 5.0,   -- Wailing Caverns
    [47]  = 5.0,   -- Razorfen Kraul
    [48]  = 5.0,   -- Blackfathom Deeps
    [70]  = 5.0,   -- Uldaman
    [90]  = 5.0,   -- Gnomeregan
    [109] = 5.0,   -- Sunken Temple
    [129] = 5.0,   -- Razorfen Downs
    [189] = 5.0,   -- Scarlet Monastery
    [209] = 5.0,   -- Zul'Farrak
    [229] = 10.0,  -- Blackrock Spire (UBRS 10-man)
    [230] = 5.0,   -- Blackrock Depths
    [289] = 5.0,   -- Scholomance
    [329] = 5.0,   -- Stratholme
    [349] = 5.0,   -- Maraudon
    [389] = 5.0,   -- Ragefire Chasm
    [429] = 5.0,   -- Dire Maul
    [249] = 40.0,  -- Onyxia's Lair
    [309] = 20.0,  -- Zul'Gurub
    [409] = 40.0,  -- Molten Core
    [469] = 40.0,  -- Blackwing Lair
    [509] = 20.0,  -- Ruins of Ahn'Qiraj
    [531] = 40.0,  -- Temple of Ahn'Qiraj
}

local dungeon_levels = {
    [33]=15,  [34]=22,  [36]=18,  [43]=17,  [47]=30,
    [48]=20,  [70]=40,  [90]=24,  [109]=50, [129]=40,
    [189]=35, [209]=44, [229]=55, [230]=50, [249]=60,
    [289]=55, [309]=60, [329]=55, [349]=48, [389]=15,
    [409]=60, [429]=48, [469]=60, [509]=60, [531]=60,
}

local class_balance = {
    [1]=100, [2]=100, [3]=100, [4]=100,  [5]=100,
    [7]=100, [8]=100, [9]=100, [11]=100,
}

local excluded_instances = {}

-- ============================================================
-- CONSTANTS
-- ============================================================

local STAT_STRENGTH  = 0
local STAT_AGILITY   = 1
local STAT_STAMINA   = 2
local STAT_INTELLECT = 3
local MOD_TOTAL_PCT  = 1  -- non-zero -> TOTAL_PCT in AddPctStatModifier
local POWER_MANA     = 0



-- ============================================================
-- STATE (per dungeon map Lua state)
-- Entry and exit share the same Lua state (confirmed via testing).
-- staminaBefore/intBefore stored on entry are readable on exit.
-- ============================================================

local player_data = {}
-- player_data[guid] = {
--   bonusPct      = float,  -- percentage applied (for reference)
--   staminaBefore = float,  -- GetStat(STAT_STAMINA) captured before buff
--   intBefore     = float,  -- GetStat(STAT_INTELLECT) captured before buff
--   strenBefore   = float,  -- GetStat(STAT_STRENGTH) captured before buff
--   agiBefore     = float,  -- GetStat(STAT_AGILITY) captured before buff
--   isCaster      = bool,
--   xp_mod        = float,
-- }

-- ============================================================
-- HELPERS
-- ============================================================

local function GetDifficulty(mapId)
    if excluded_instances[mapId] then return 0 end
    return diff_multiplier[mapId] or 0
end

local function GetDungeonLevel(mapId)
    return dungeon_levels[mapId] or DEFAULT_DUNGEON_LEVEL
end

local function GetNumInGroup(player)
    local group = player:GetGroup()
    if not group then return 1 end
    return group:GetMembersCount()
end

local function GetClassBalance(player)
    return class_balance[player:GetClass()] or 100
end

-- Apply a percentage buff. apply=true always works in this Eluna build.
-- Removal uses the mathematical inverse so apply=false is never needed:
--   inversePct = (statBefore / statNow - 1) * 100
-- This brings the accumulator exactly back to its pre-buff value.
--
-- Health/mana scaling uses STATS_MULT (Stamina + Intellect).
-- Physical damage scaling uses DAMAGE_MULT (Strength + Agility).
-- The two multipliers are independent so they can be tuned separately.
-- Note: buffing Agility also increases dodge chance, crit chance, and
-- armor. Buffing Strength increases block value for Warrior/Paladin.
-- These are unavoidable side effects of the vanilla stat pipeline.
local function ApplyStatBuff(player, statMult, dmgMult)
    player:AddPctStatModifier(STAT_STAMINA,   MOD_TOTAL_PCT, statMult, true)
    player:AddPctStatModifier(STAT_STRENGTH,  MOD_TOTAL_PCT, dmgMult,  true)
    player:AddPctStatModifier(STAT_AGILITY,   MOD_TOTAL_PCT, dmgMult,  true)
    if player:GetPowerType() == POWER_MANA then
        player:AddPctStatModifier(STAT_INTELLECT, MOD_TOTAL_PCT, statMult, true)
    end
end

local function RemoveStatBuff(player, data)
    local function removeOne(stat, before)
        if not before or before <= 0 then return end
        local now = player:GetStat(stat)
        if now > before then
            local inv = (before / now - 1.0) * 100.0
            player:AddPctStatModifier(stat, MOD_TOTAL_PCT, inv, true)
        end
    end
    removeOne(STAT_STAMINA,   data.staminaBefore)
    removeOne(STAT_STRENGTH,  data.strenBefore)
    removeOne(STAT_AGILITY,   data.agiBefore)
    if data.isCaster then
        removeOne(STAT_INTELLECT, data.intBefore)
    end
end

-- ============================================================
-- ENTRY: PLAYER_EVENT_ON_MAP_CHANGE fires on destination map.
-- For dungeon entry, destination = dungeon -> dungeon Lua state.
-- ============================================================

local function OnMapChange(event, player)
    if not SOLOCRAFT_ENABLED then return end

    local map = player:GetMap()
    if not map then return end
    if not map:IsDungeon() and not map:IsRaid() then return end

    local mapId = map:GetMapId()
    if excluded_instances[mapId] then return end

    local difficulty = GetDifficulty(mapId)
    if difficulty == 0 then return end

    local dunLevel   = GetDungeonLevel(mapId)
    local playerLvl  = player:GetLevel()
    local guid       = player:GetGUIDLow()

    if playerLvl > dunLevel + LEVEL_DIFF then
        if SOLOCRAFT_ANNOUNCE then
            player:SendBroadcastMessage(
                "[Solocraft] No buff - level exceeds threshold " .. tostring(dunLevel + LEVEL_DIFF)
            )
        end
        return
    end

    local numInGroup    = GetNumInGroup(player)
    local classPct      = GetClassBalance(player) / 100.0
    local effectiveMult = (classPct * difficulty) / numInGroup
    effectiveMult       = math.floor(effectiveMult * 100 + 0.5) / 100
    if effectiveMult <= 0 then return end

    -- Remove previous buff if re-entering without a clean exit
    local old = player_data[guid]
    if old then
        RemoveStatBuff(player, old)
    end

    -- Capture base stats AFTER removal, BEFORE applying new buff
    local isCaster      = (player:GetPowerType() == POWER_MANA)
    local staminaBefore = player:GetStat(STAT_STAMINA)
    local intBefore     = isCaster and player:GetStat(STAT_INTELLECT) or 0
    local strenBefore   = player:GetStat(STAT_STRENGTH)
    local agiBefore     = player:GetStat(STAT_AGILITY)

    local statMult = (effectiveMult - 1.0) * STATS_MULT
    local dmgMult  = (effectiveMult - 1.0) * DAMAGE_MULT
    ApplyStatBuff(player, statMult, dmgMult)

    local xp_mod = 1.0
    if XP_BAL_ENABLED then
        xp_mod = (1.04 / effectiveMult) - 0.02
        xp_mod = math.floor(xp_mod * 100 + 0.5) / 100
        if xp_mod < 0 then xp_mod = 0 end
        if xp_mod > 1 then xp_mod = 1.0 end
    end
    if not XP_ENABLED then xp_mod = 0 end

    player_data[guid] = {
        staminaBefore = staminaBefore,
        intBefore     = intBefore,
        strenBefore   = strenBefore,
        agiBefore     = agiBefore,
        isCaster      = isCaster,
        xp_mod        = xp_mod,
    }

    if SOLOCRAFT_ANNOUNCE then
        player:SendBroadcastMessage(
            "[Solocraft] " .. tostring(map:GetName())
            .. " - Mult: " .. tostring(effectiveMult)
            .. "x | Group: " .. tostring(numInGroup)
            .. " | XP: " .. tostring(math.floor(xp_mod * 100)) .. "%"
        )
    end
end

-- ============================================================
-- EXIT: MAP_EVENT_ON_PLAYER_LEAVE fires on the map being left.
-- For dungeon exit, this is the dungeon Lua state — same state
-- where player_data was written on entry.
-- ============================================================

local function OnPlayerLeave(event, map, player)
    if not SOLOCRAFT_ENABLED then return end
    local guid = player:GetGUIDLow()
    local data = player_data[guid]
    player_data[guid] = nil
    if not data then return end
    RemoveStatBuff(player, data)
    if SOLOCRAFT_ANNOUNCE then
        player:SendBroadcastMessage("[Solocraft] Stat scaling removed.")
    end
end

-- ============================================================
-- XP: fires on dungeon map Lua state (same as player_data)
-- ============================================================

local function OnGiveXP(event, player, amount, victim)
    if not SOLOCRAFT_ENABLED then return end
    local data = player_data[player:GetGUIDLow()]
    if not data then return end
    if not XP_ENABLED then return 0 end
    if XP_BAL_ENABLED and data.xp_mod then
        return math.floor(amount * data.xp_mod)
    end
end

local function OnLogin(event, player)
    player_data[player:GetGUIDLow()] = nil
    if SOLOCRAFT_ENABLED and SOLOCRAFT_ANNOUNCE then
        player:SendBroadcastMessage("[Solocraft] Solo dungeon scaling is active.")
    end
end

local function OnLogout(event, player)
    local guid = player:GetGUIDLow()
    local data = player_data[guid]
    player_data[guid] = nil
    if not data then return end
    RemoveStatBuff(player, data)
end

-- ============================================================
-- REGISTER
-- ============================================================

RegisterPlayerEvent(28, OnMapChange)  -- PLAYER_EVENT_ON_MAP_CHANGE
RegisterPlayerEvent(3,  OnLogin)      -- PLAYER_EVENT_ON_LOGIN
RegisterPlayerEvent(4,  OnLogout)     -- PLAYER_EVENT_ON_LOGOUT
RegisterPlayerEvent(12, OnGiveXP)     -- PLAYER_EVENT_ON_GIVE_XP

RegisterServerEvent(22, OnPlayerLeave)  -- MAP_EVENT_ON_PLAYER_LEAVE

--[[
KNOWN LIMITATIONS:

1. SPELL POWER: Not implemented. Buffing Intellect gives casters more
   mana and minor spell crit as a side effect. Unavoidable without a
   core patch to expose per-school damage to Lua.

2. NO BUFF ICON: Stat changes are invisible to the client UI.

3. RELOAD ELUNA: If .reload eluna is used while a player is inside a
   dungeon, player_data is wiped but the C++ modifier persists. The
   player must exit and re-enter to resync. Edge case, GM-only.

4. GROUP OFFSET TRACKING: Not implemented. All members scale equally
   by difficulty / current group size.
--]]
