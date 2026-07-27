<p align="center">
  <img src="assets/workshop-preview.jpg" alt="Character Enhance" width="360" />
</p>

<h1 align="center">Character Enhance</h1>

<p align="center">
  <strong>Independently configurable character enhancements for The Binding of Isaac: Repentance+.</strong>
</p>

<p align="center">
  <a href="README.md">English</a> |
  <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <a href="#tainted-lost">Tainted Lost</a> •
  <a href="#tainted-blue-baby">Tainted Blue Baby</a> •
  <a href="#tainted-eden">Tainted Eden</a> •
  <a href="#bethany">Bethany</a> •
  <a href="#familiar-capacity">Familiar Capacity</a> •
  <a href="#clog-ground-damage">Clog Ground Damage</a> •
  <a href="#mod-config-menu">Mod Config Menu</a> •
  <a href="#installation">Installation</a>
</p>

---

## Requirements

- *The Binding of Isaac: Repentance+*, version `1.9.7.15`
- This mod is tested only on game version `1.9.7.15`; other versions are
  unverified.
- Standard Lua Mod API; REPENTOGON is not required
- [Mod Config Menu Impure](https://steamcommunity.com/sharedfiles/filedetails/?id=3701683951) is optional

<a id="tainted-lost"></a>
## Tainted Lost

- Starts each new run with Wooden Cross (trinket ID 121). Continuing a saved
  run does not grant another copy.

<a id="tainted-blue-baby"></a>
## Tainted Blue Baby

- Devil Deals use Blue Baby's equivalent Soul Heart prices: items worth one or two
  Red Heart containers cost one or two Soul Hearts instead of always costing
  three. In multiplayer, the adjusted payment applies only to Tainted Blue Baby.
- At full poop capacity, both small and large poop pickups retain collision but
  are not collected, staying on the ground for later. Below capacity, they
  retain vanilla behavior.

<a id="tainted-eden"></a>
## Tainted Eden and full-inventory rerolls

- Full-inventory rerolls preserve each player's pre-reroll health composition,
  including heart containers, filled Red Hearts, Soul/Black Hearts, Bone
  Hearts, Rotten Hearts, Broken Hearts, Eternal Hearts, and Golden Hearts.
- Covers Tainted Eden penalty hits, D4, D100, matching D Infinity faces,
  D4/D100 invoked through Void or Metronome, Missing No., one-pip and six-pip
  Dice Rooms, the reversed Wheel of Fortune card, and comparable passive-item
  replacement.
- Voluntary damage such as Blood Donation Machines, Devil Beggars, Hell Games,
  IV Bag, Curse Room doors, and Sacrifice Room spikes retains vanilla behavior.
- An independent TMTRAINER slider controls whether TMTRAINER is included in
  each full-reroll Secret Room pool. `0%` always excludes it, `50%` includes it
  for half of rerolls on average, and `100%` preserves vanilla behavior. Normal
  pedestal pickups and rerolls started while TMTRAINER is owned are unrestricted.
- Items generated on Esau Jr.'s first use are registered once with vanilla
  transformation progress. Later body swaps do not replay first-pickup effects.

<a id="bethany"></a>
## Bethany

- Soul Heart gains provide double Soul Charge: a full Soul Heart grants 4 and a
  half Soul Heart grants 2. Pickups and direct item grants are both covered.
- Soul Charge absorbs penalty damage that would lower Devil/Angel Room chance,
  protecting both red health and deal chance. Half-heart damage costs 2 and
  full-heart damage costs 4; any positive charge can absorb one qualifying hit.
- Safe damage, including Devil Beggars, Hell Games, blood donation, Sacrifice
  Room spikes, and Curse Room entry/exit, removes red health normally and never
  consumes Soul Charge.
- Absorbed penalty damage still destroys Perfection and affects its progress;
  only red health and room-deal probability are protected.
- Independent shield feedback offers a legacy translucent Soul Veil, a blue
  energy-pane Particle Wall, and a dense Frosted Soul shell, plus five
  bright-to-afterglow hit effects and three original Soul Shield sound sets.
  Each sound continuously blends custom thin, middle, and
  thick recordings; most visual and audio change occurs from 0–30 charge and
  then eases toward 99. Separate MCM previews test idle, hit, and 4/30/99-charge
  sound feedback without damage. Absorbed hits keep Bethany's pose and never
  play her hurt voice. Turning feedback off fades the shield away with its
  selected disappearance sound.

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

<a id="clog-ground-damage"></a>
## The Clog ground damage

- The Clog (entity 914.0.0) can take damage from player creep, including Free
  Lemonade. Damage, radius, and tick rate follow the creep's current values;
  other enemies remain unchanged.

<a id="mod-config-menu"></a>
## [Mod Config Menu Impure](https://steamcommunity.com/sharedfiles/filedetails/?id=3701683951)

The first option selects English (default) or Simplified Chinese. Only the
selected language is displayed, and the choice is saved independently from
gameplay settings.

All eleven gameplay settings remain independently configurable:

1. Familiar Capacity
2. Clog Ground Damage
3. Starting Wooden Cross
4. Equivalent Soul Deals
5. Full Poop Protection
6. Reroll Health Protection
7. Esau Jr. First Pickup
8. TMTRAINER Reroll Chance
9. Soul Charge Bonus
10. Charge Damage Shield
11. Shield Feedback

Options are grouped under the tabs `General`, `T-Lost`, `T-Blue Baby`,
`T-Eden`, and `Bethany`. The integration supports both Mod Config Menu Impure's
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
