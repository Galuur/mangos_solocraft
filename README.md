# Solocraft for MaNGOS Zero

A Lua/Eluna port of the [AzerothCore mod-solocraft](https://github.com/azerothcore/mod-solocraft) module for **MaNGOS Zero** . Allows solo players to experience dungeon and raid content by scaling their stats to compensate for missing group members.

---

## What it does

When a player enters a dungeon or raid instance, their Stamina (and Intellect for caster classes) are scaled up as if they had a full group. When they leave, the scaling is removed. This makes vanilla dungeons and raids soloable without requiring custom content or balance changes.

- **Health scaling** — Stamina is multiplied based on the dungeon's expected group size divided by the current number of players in the group. A solo player in a 5-man dungeon receives 5x Stamina; a duo receives 2.5x; a full group of five receives no buff.
- **Mana scaling** — Intellect is scaled by the same factor for mana-using classes, providing proportional mana pool increases. This also grants a minor spell crit bonus as a side effect of the vanilla stat pipeline.
- **XP balancing** — XP gained from kills is reduced proportionally to the stat buff applied, so that a heavily buffed solo player does not trivially out-level content.
- **Group awareness** — The buff scales dynamically with how many players are currently in your group at the time of dungeon entry. Re-entering after a group change will apply the correct buff for the new group size.
- **Per-class weighting** — Each class has a configurable balance weight (default 100%) allowing server operators to fine-tune the buff strength per class.
- **Level gating** — Players who have significantly outlevelled a dungeon (configurable threshold) do not receive a buff.
- **All vanilla instances supported** — All vanilla dungeons and raids are pre-configured.

---

## What it does not do

- **No spell power scaling.** Vanilla tracks spell damage per school with no unified spell power stat. There is no Lua API in this Eluna build to modify per-school damage bonuses without a custom DB spell aura or core patch.
- **No buff icon.** Stat changes are applied directly through the engine's modifier pipeline and are not visible as a buff on the player's unit frame. The stat sheet (`C`) will show the increased values.
- **No group offset tracking.** The original AzerothCore version debuffs players who join a dungeon where another player already holds the full difficulty offset. This port does not implement that logic. All group members are scaled equally by `difficulty / groupSize`.

---

## Installation

1. Copy `solocraft.lua` into your Eluna scripts directory:

```
<mangos_root>/bin/lua_scripts/solocraft.lua
```

2. Reload scripts in-game with a GM account, or restart the server:

```
.reload eluna
```

That's it. The script will announce itself to players on login.

---

## Configuration

All options are at the top of `solocraft.lua`:

| Option | Default | Description |
|---|---|---|
| `SOLOCRAFT_ENABLED` | `true` | Master on/off switch |
| `SOLOCRAFT_ANNOUNCE` | `true` | Send buff/debuff messages to players |
| `STATS_MULT` | `100.0` | Scaling percentage (100 = full, 50 = half) |
| `XP_ENABLED` | `true` | Allow XP gain inside instances |
| `XP_BAL_ENABLED` | `true` | Reduce XP proportional to buff strength |
| `LEVEL_DIFF` | `10` | Max levels above dungeon level to still receive buff |

### Per-class balance

Each class has a weight in the `class_balance` table (default 100 for all). Reducing a class's weight gives it a weaker buff; increasing it gives a stronger buff:

```lua
local class_balance = {
    [1]  = 100, -- Warrior
    [2]  = 100, -- Paladin
    [3]  = 100, -- Hunter
    [4]  = 100, -- Rogue
    [5]  = 100, -- Priest
    [7]  = 100, -- Shaman
    [8]  = 100, -- Mage
    [9]  = 100, -- Warlock
    [11] = 100, -- Druid
}
```

### Excluding instances

Add map IDs to `excluded_instances` to disable the buff for specific dungeons:

```lua
local excluded_instances = {
    [389] = true,  -- Ragefire Chasm (example)
}
```

## Known limitations

- **`.reload eluna` mid-dungeon** — If scripts are reloaded while a player is inside a dungeon, the Lua state is wiped but the C++ stat modifier persists. The player must exit and re-enter the instance to resync their stats. This only affects GM-initiated reloads.
- **Group size snapshot** — Group size is captured at dungeon entry. Joining or leaving a group mid-dungeon does not update the buff until the player exits and re-enters.
- **Mana crit side effect** — Buffing Intellect increases spell crit chance as a vanilla engine side effect. This is unavoidable without a custom aura spell in the database.

---

## Credits

- Original AzerothCore module by the [mod-solocraft](https://github.com/azerothcore/mod-solocraft) contributors
- MaNGOS Zero Lua port by loopy
