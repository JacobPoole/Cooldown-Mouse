# Cooldown Mouse

A cursor highlight and swing timer for **World of Warcraft: Forever** (interface 16001).

## What it does

- **Highlight ring.** A thin, faint ring follows your mouse cursor so you can always find it.
- **Timer ring.** When a timer starts, a second ring appears and eats itself, piece by piece, starting at the top. When it's gone, the timer is ready. Outside of timers you only see the highlight ring.
  - **Red: melee swing.** Starts when one of your swings actually lands on (or misses) your target while you're auto-attacking.
  - **Green: ranged.** Starts on each Auto Shot, wand Shoot, or bow, gun or crossbow Shoot.
  - **Blue: mana regen.** Starts whenever you spend mana and runs for 5 seconds. When it ends, your mana regenerates faster (the "five second rule"), and the highlight ring flashes blue.

## Which timer you see

| Class | Shows |
|---|---|
| Hunter | Ranged. Melee only while the ranged timer isn't running, then mana. |
| Warrior, Rogue | Melee, then ranged. |
| Mage, Priest, Warlock | Mana rule, then wand. |
| Druid, Shaman, Paladin | Melee while you're auto-attacking, otherwise the mana rule. |

This is what "Automatic" means. There are two timer rings, one just outside the highlight ring and one just inside it, and each can track something different: Automatic, Melee, Ranged, Mana, or Off. By default the outer ring is Automatic and the inner ring is Off. Change them in settings or with `/mouse outer` and `/mouse inner`. With the Boobs shape, each boob gets its own timer around its outside edge instead: the outer setting is the left boob and the inner setting is the right boob.

## Settings

Options > AddOns > Cooldown Mouse, or type `/mouse`.

- **Highlight ring:** shape (circle, square, diamond, triangle, hexagon, octagon, star, cross, heart, penis with a "How long are you?" length from 1 to 36, boobs), size, thickness, opacity, color, only in combat.
- **Timer rings:** what the outer ring and the inner ring each track, style (eats itself or fades out), direction, gap, thickness, opacity, and a color for each of melee, ranged and mana. You can also turn the mana flash on or off.
- **Test timer** and **Reset to defaults** buttons.

## Install

Copy or clone this folder into:

```
World of Warcraft\_forever_\Interface\AddOns\Cooldown-Mouse
```

The folder must be named `Cooldown-Mouse` to match `Cooldown-Mouse.toc`.

## Commands

| Command | What it does |
|---|---|
| `/mouse` | Open settings |
| `/mouse on\|off\|toggle` | Turn the addon on or off |
| `/mouse size <8-160>` | Highlight ring size |
| `/mouse alpha <0-1>` | Highlight ring opacity |
| `/mouse shape <name>` | circle, square, diamond, triangle, hexagon, octagon, star, cross, heart, penis or boobs |
| `/mouse length <1-36>` | "How long are you?" for the penis shape (stretches the shaft only) |
| `/mouse outer auto\|melee\|ranged\|mana\|none` | What the outer ring tracks |
| `/mouse inner auto\|melee\|ranged\|mana\|none` | What the inner ring tracks |
| `/mouse color highlight\|melee\|ranged\|mana` | Pick a color |
| `/mouse test` | Run a 3 second test timer |
| `/mouse debug` | Show what the addon sees (class, mana, timers) |
| `/mouse reset` | Restore default settings |
| `/mouse help` | List commands |

## Notes

- WoW Forever keeps the combat log to the Blizzard UI, so the addon can't see your swings directly. Instead it watches hits and misses on your target (the numbers on the target portrait). A physical hit counts as your swing only if you're auto-attacking and your next swing is due (in the last quarter of the timer, or after it). So a groupmate's hits and your own attacks mid-swing don't reset it. In a group, another player's hit can still be mistaken for your swing while yours is due.
- If the game hides those hit details too, the melee ring falls back to an estimate: it starts when you begin auto-attacking and repeats every weapon-speed seconds. `/mouse debug` shows which method is in use.
- Only the main hand is tracked when dual-wielding.
- The mana timer starts whenever your mana goes down or you cast a spell that costs mana, so effects that drain your mana also start it.

## Files

- `Core.lua`: the rings, timers, events and slash commands.
- `Options.lua`: settings panel and color picker.
