<p align="center">
  <img src="assets/workshop-preview.jpg" alt="Character Enhance" width="360" />
</p>

<h1 align="center">Character Enhance</h1>

<p align="center">
  <strong>Independently configurable character and familiar-capacity enhancements for The Binding of Isaac: Repentance.</strong>
</p>

<p align="center">
  <a href="README.md">English</a> |
  <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <a href="#tainted-lost">Tainted Lost</a> •
  <a href="#tainted-eden">Tainted Eden</a> •
  <a href="#bethany">Bethany</a> •
  <a href="#familiar-capacity">Familiar Capacity</a> •
  <a href="#mod-config-menu">Mod Config Menu</a> •
  <a href="#installation">Installation</a>
</p>

---

## Requirements

- *The Binding of Isaac: Repentance*
- Standard Lua Mod API; REPENTOGON is not required
- Mod Config Menu is optional

<a id="tainted-lost"></a>
## Tainted Lost

- Starts each new run with Wooden Cross (trinket ID 121). Continuing a saved
  run does not grant another copy.
- The character-select screen uses a static vanilla-style `WOODEN CROSS` image.
  Turning the module off does not dynamically change that image or remove a
  trinket already obtained during the run.

<a id="tainted-eden"></a>
## Tainted Eden and full-inventory rerolls

- Full-inventory rerolls preserve each player's pre-reroll health composition,
  including heart containers, filled Red Hearts, Soul/Black Hearts, Bone
  Hearts, Rotten Hearts, Broken Hearts, Eternal Hearts, and Golden Hearts.
- Covers Tainted Eden penalty hits, D4, D100, matching D Infinity faces,
  D4/D100 invoked through Void or Metronome, Missing No., one-pip and six-pip
  Dice Rooms, the reversed Wheel of Fortune card, and comparable passive-item
  replacement. Tainted Eden still takes the triggering damage exactly once.
- Voluntary damage such as blood donation, IV Bag, Curse Room doors, and
  Sacrifice Room spikes retains vanilla behavior.
- An independent TMTRAINER slider controls whether TMTRAINER is included in
  each full-reroll Secret Room pool. `0%` always excludes it, `50%` includes it
  for half of rerolls on average, and `100%` preserves vanilla behavior. Normal
  pedestal pickups and rerolls started while TMTRAINER is owned are unrestricted.
- Items generated on Esau Jr.'s first use are registered once with vanilla
  transformation progress. Later body swaps do not replay first-pickup effects.

<a id="bethany"></a>
## Bethany

- A full Soul Heart provides 4 Soul Charge; a half Soul Heart provides 2.
  Pickups and direct item grants are covered, including Book of Revelations,
  PJs, Satanic Bible, The Nail, Guppy's Paw, and comparable sources.
- Restored historical state, such as a Glowing Hour Glass rollback, is not
  mistaken for a newly gained Soul Heart.
- Penalty damage that would lower Devil/Angel Room chance consumes Soul Charge
  first and does not remove red health. Half-heart damage costs 2 and full-heart
  damage costs 4. Any positive charge can absorb one qualifying hit and clamps
  safely to 0 when insufficient.
- Safe damage, including Sacrifice Room spikes, Curse Room entry/exit, and blood
  donation, removes red health normally and never consumes Soul Charge.
- Absorbed penalty damage still destroys Perfection and affects its progress;
  only red health and room-deal probability are protected.

<a id="familiar-capacity"></a>
## Familiar capacity protection

- Preserves the vanilla 64-real-familiar hard limit without REPENTOGON.
- Blue Flies and Blue Spiders occupy real slots only up to a soft total of 60.
  Overflow is stored by player and type, then restored at most 2 every 3 frames
  when slots reopen.
- Permanent and quest familiars, wisps, Bone Spurs, and other important
  familiars are never deliberately banked. At the hard edge, an owned Blue Fly
  or Blue Spider is banked to reserve space for an important familiar.
- Overflow animation is coalesced and throttled. Banked counts survive
  continued games and remain stored while this module is disabled; a new run
  resets them.

<a id="mod-config-menu"></a>
## Mod Config Menu

The first option selects English (default) or Simplified Chinese. Only the
selected language is displayed, and the choice is saved independently from
gameplay settings.

All seven gameplay settings default to enabled and remain independently
configurable:

1. Familiar Capacity
2. Starting Wooden Cross
3. Reroll Health Protection
4. Esau Jr. First Pickup
5. TMTRAINER Reroll Chance
6. Soul Charge Bonus
7. Charge Damage Shield

Options are grouped under the compact tabs `General`, `T-Lost`, `T-Eden`, and
`Bethany`. The integration supports both
[Mod Config Menu Impure](https://github.com/piber20/Mod-Config-Menu-Impure)'s
global `MCM` API and legacy/localized editions exposing `ModConfigMenu`.
Without MCM, saved or default settings still work normally.

<a id="installation"></a>
## Installation

Copy the complete `character-enhance` folder into the game's `mods` directory,
then enable it from the in-game Mods menu.

Steam Deck/Linux:

```text
/home/deck/.local/share/Steam/steamapps/common/The Binding of Isaac Rebirth/mods/character-enhance
```

Windows:

```text
C:\Program Files (x86)\Steam\steamapps\common\The Binding of Isaac Rebirth\mods\character-enhance
```

In multiplayer, eligible effects and familiar banks are handled separately for
each player.
