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
  <a href="#eve">Eve</a> •
  <a href="#eden">Eden</a> •
  <a href="#tainted-lost">Tainted Lost</a> •
  <a href="#tainted-blue-baby">Tainted Blue Baby</a> •
  <a href="#tainted-eden">Tainted Eden</a> •
  <a href="#bethany">Bethany</a> •
  <a href="#coupon-full-shop-discount">Coupon Full-Shop Discount</a> •
  <a href="#familiar-capacity">Protect Wisps from Temporary Familiars</a> •
  <a href="#incubus-c-section-animation-fix">C Section Incubus Animation Fix</a> •
  <a href="#moms-knife-homing-fix">Mom's Knife Homing Fix</a> •
  <a href="#small-player-pickup-range">Small Player Pickup Range Fix</a> •
  <a href="#clog-ground-damage">Clog Creep Damage Fix</a> •
  <a href="#lost-soul-white-fire-fix">Lost Soul White Fire Fix</a> •
  <a href="#held-item-protection">Pickup Animation Fix</a> •
  <a href="#kids-drawing-form-fix">Kid's Drawing Form Fix</a> •
  <a href="#ocular-rift-sound-fix">Ocular Rift Sound Fix</a> •
  <a href="#pill-rewind-fix">Pill Rewind Fix</a> •
  <a href="#zodiac-floor-item">Zodiac Floor Item</a> •
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

<a id="eve"></a>
## Eve

- Uses a `1.00x` damage multiplier at all times instead of her normal `0.75x`
  multiplier. Activating Whore of Babylon does not add another multiplier; its
  flat damage and speed bonuses remain unchanged.
- Dead Bird stays active whenever its owner has half a filled Red Heart or
  less, even with Soul or Black Hearts protecting that health. Normal Eve uses
  her one-full-Red-Heart threshold. The same attacking bird persists between
  rooms, taking damage does not create a duplicate while the rule is active,
  and multiplayer checks each owner separately.

<a id="eden"></a>
## Eden

- Eden's native random starting passive is removed without leaving its
  pickup-only health, consumables, or spawned pickups behind, and without
  consuming the sequence those pickups would have used. In its place, three
  random collectible pedestals appear and only one can be taken.
- Each Eden's Blessing collected creates its own three-pedestal choice at the
  start of the next run instead of adding one collectible directly.
- Both choices draw from all available active, passive, and familiar
  collectibles except items tagged `noeden`. Already-owned collectibles are
  excluded, and separate choices in the same starting room do not repeat one
  another. Every generated option is removed from the run's item pools, whether
  selected or not, so normal item-pool sources cannot offer it again.
  Continuing a saved run does not create the choices again.

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
- An independent fix preserves the permanent stat gains already awarded by
  Void and Black Rune. Gains are tracked per player; stats supplied by the old
  passive inventory still reroll normally.
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
  Rejected TMTRAINER results are replaced by a passive/familiar result before
  entering the inventory, so they cannot create extra glitched items, collide
  with an active-item slot, or change the rerolled item count.
- Items generated on Esau Jr.'s first use are registered once with vanilla
  transformation progress. Later body swaps do not replay first-pickup effects.
- When a full-inventory reroll grants PHD or False PHD, all pill names are
  revealed just as they are after a normal pickup. They stay identified if the
  item is later lost.

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
- While Gello is active, Book of Virtues wisps keep orbiting their owning
  player instead of moving their orbit center to Gello. Wisp and Gello stats,
  count, and lifetime remain unchanged.
- Book of Virtues and Lemegeton wisps become immune to explosion damage while
  their owner holds Pyromaniac or Host Hat. A Pyromaniac or Host Hat wisp from
  Lemegeton grants the same protection to all wisps owned by that player.
- Shield Effects offers a legacy translucent Soul Veil, a blue
  energy-pane Particle Wall, and a dense Frosted Soul shell, plus five
  bright-to-afterglow hit effects and three original Soul Shield sound sets.
  Each sound continuously blends custom thin, middle, and
  thick recordings; most visual and audio change occurs from 0–30 charge and
  then eases toward 99. Separate MCM previews test idle, hit, and 4/30/99-charge
  sound feedback without damage. Absorbed hits keep Bethany's pose and never
  play her hurt voice. Turning Shield Effects off fades the shield away with
  its selected disappearance sound.

<a id="coupon-full-shop-discount"></a>
## Coupon Full-Shop Discount

- Coupon recharges in three rooms instead of six. While held, every Coupon
  discounts all shop merchandise as one complete Steam Sale effect instead of
  guaranteeing a discount on only one random product.
- Multiple Coupons and real Steam Sales all stack through Repentance+'s normal
  discount rule, including copies held by different players.

<a id="familiar-capacity"></a>
## Protect Wisps from Temporary Familiars

- When Guppy, Parasitoid, and similar effects generate large numbers of Blue
  Flies and Blue Spiders, wisps and other important familiars will not be
  displaced by temporary familiars. Extra temporary familiars are banked and
  respawned when slots become available.
- Preserves the vanilla 64-real-familiar hard limit without REPENTOGON.
- Blue Flies and Blue Spiders occupy real slots only up to a soft total of 55.
  Overflow is stored by player and type, then restored up to 7 per frame as
  slots reopen.
- Permanent and quest familiars, wisps, Bone Spurs, and other important
  familiars are never deliberately banked. At the hard edge, an owned Blue Fly
  or Blue Spider is banked to reserve space for an important familiar.
- Overflow animation is coalesced and throttled. Banked counts survive
  continued games and remain stored while this module is disabled; a new run
  resets them.

<a id="incubus-c-section-animation-fix"></a>
## C Section Incubus Animation Fix

- While its owner holds C Section, Incubus plays its idle flying animation
  again when not firing. Shooting animations, behavior, and other familiars
  remain unchanged.

<a id="moms-knife-homing-fix"></a>
## Mom's Knife Homing Fix

- When Mom's Knife has homing, it continuously replans a short curved intercept
  from each hostile enemy's observed movement, turn, and speed change. Charmed
  or friendly enemies, mechanisms, and other non-target entities are ignored.
  Angular motion and the extra sideways world speed produced by steering are
  both speed- and acceleration-bounded. Every final world-space movement also
  shares one symmetric absolute acceleration limit, so speeding up, braking,
  turning, final-target hold, and movement of the range center cannot create a
  one-frame velocity jump. Targets that cannot be intercepted inside those
  limits are released, even when this reduces homing coverage. The engine's
  ordinary outward and return trajectory remains the reference and its native
  flight timer is unchanged, while both native sub-updates receive continuous
  physical motion for smoother animation.
  A knife that has already passed one target's reachable radial band yields to
  another feasible enemy, and begins a small contact-safe
  turn toward its next target immediately before the current hit. Multi-shot
  knives reuse the complete native knife layout collected at frame end instead
  of rebuilding item interactions. Each knife independently tracks a different
  reachable enemy whenever possible; additional knives reinforce the least
  covered targets only after unique enemy coverage is exhausted. When only one
  target remains, every reachable knife converges on it; entering its braking
  approach starts continuous acceleration-bounded deceleration tracking for
  the whole assigned volley so the outer blades connect instead of flying
  through. Every member
  uses the same selected-direction acquisition sector while retaining its own
  native launch line.
  Compact symmetric spreads use the middle knife—or the midpoint of an even
  spread—as their shared axis while retaining every native line; backward,
  omnidirectional, and random extra shots retain the player's native held axis.
- While approaching the last reachable enemy, the knife begins a visible,
  acceleration-bounded braking curve while continuing to turn and match that
  target's live radial movement; a confirmed hit retains the live farthest-hit
  enemy instead of stopping at its previous position. If that enemy dies, its
  last valid radial distance and direction remain the deceleration anchor.
  Native retraction then
  carries that held position smoothly inward instead of jumping out to the turnaround point.
  Native collision damage remains unchanged.
- Acquisition uses a hard sector 40 degrees to either side of the player's
  selected firing direction, and each knife's steering also stays within 40
  degrees of its own native launch line. A target is dropped as soon as it
  leaves that sector or exceeds the throw's calibrated maximum attack range.
  During the outbound phase, that sector center and the live knife follow
  80% of the owner's displacement from the release point; native retraction
  smoothly raises the follow ratio to 100% so the knife rejoins its owner.
  Burrows and teleports are treated as position discontinuities rather than
  high-speed movement, allowing another in-range enemy to take priority.
  Targets inside native range keep the original distance and timing. The
  farthest valid target present at release may extend only that throw by the
  distance it actually needs, up to 30%; that target-derived range and timer do
  not expand later when an enemy moves outward. Targets that cross it are
  dropped. Non-homing knives and other homing attacks stay vanilla.

<a id="small-player-pickup-range"></a>
## Small Player Pickup Range Fix

- In every non-combat room, size-down effects including Pluto retain their
  small appearance while the player's physical radius returns to its normal
  size for pickup and contact interactions. Active combat restores the smaller
  collision; pickup entities themselves are never resized.

<a id="clog-ground-damage"></a>
## The Clog Creep Damage Fix

- The Clog (entity 914.0.0) can take damage from player creep, including Free
  Lemonade. Damage, radius, and tick rate follow the creep's current values;
  other enemies remain unchanged.

<a id="lost-soul-white-fire-fix"></a>
## Lost Soul White Fire Fix

- The Lost Soul familiar (entity 3.211.0) can pass through White Fire Places
  (entity 33.4.0) without taking damage or being knocked away. Players still
  enter the Lost form normally when touching the fire.
- The enabled-by-default child option grants Lost Soul a visible, one-use Holy
  Mantle with a brief choir cue when it touches white fire. White fire
  does not consume that shield; the next other damaging hit does.

<a id="held-item-protection"></a>
## Pickup Animation Fix

- Using R Key or Forget Me Now during a collectible's pickup animation finishes
  the pickup before the run or floor resets. This prevents the item from
  disappearing before it reaches the inventory. In multiplayer, each player's
  pending pickup is completed independently.

<a id="kids-drawing-form-fix"></a>
## Kid's Drawing Form Fix

- Mom's Box adds one Guppy transformation count to Kid's Drawing, for two
  counts with a normal copy and three with a golden copy. A golden Kid's
  Drawing with Mom's Box therefore triggers the Guppy transformation directly.

<a id="ocular-rift-sound-fix"></a>
## Ocular Rift Sound Fix

- While an Ocular Rift holder is not firing tears, passive tear-effect sources
  such as Finger! no longer replay Ocular Rift's shoot sound. Actual fired
  tears and the portal sound retain vanilla behavior.

<a id="pill-rewind-fix"></a>
## Pill Rewind Fix

- After a pill is used, rewinding the same room with Glowing Hour Glass keeps
  its effect identified in the built-in Item Descriptions and the bottom-right
  HUD instead of changing it back to `???`.

<a id="zodiac-floor-item"></a>
## Zodiac Floor Item

- After Zodiac is picked up, its original tracker icon remains and an inert gray
  item beside it shows the current one of its twelve sign effects. Vanilla
  Zodiac alone supplies the matching ability. On every new floor, including
  console `stage` transitions, the old marker is replaced with the current sign
  through the standard tracker without removing or reacquiring Zodiac or any
  other real item. Refreshed markers follow the tracker's normal newest-item
  ordering. Display-only markers are excluded from Death Certificate rooms.
- The marker's pause-menu **My Stuff** page lists the current sign's effects,
  followed by a blank line and Zodiac's random-effect/floor-reroll explanation.
  Repentance+ currently mispositions custom death-item thumbnails in the left
  inventory grid, so that small slot is left empty instead of overlapping a
  different item; the page icon and description remain available.
- Before a supported full-inventory reroll or Reverse Stars, the inert marker is
  removed so only the real Zodiac participates. If Zodiac remains afterward,
  the current floor marker returns automatically.

<a id="mod-config-menu"></a>
## [Mod Config Menu Impure](https://steamcommunity.com/sharedfiles/filedetails/?id=3701683951)

The first option selects English (default) or Simplified Chinese. Only the
selected language is displayed, and the choice is saved independently from
gameplay settings.

All thirty-one gameplay settings remain independently configurable:

1. Coupon Full-Shop Discount
2. Soul of Eve Bird Fixes
3. Protect Wisps from Temporary Familiars
4. C Section Incubus Animation Fix
5. Small Player Pickup Range Fix
6. Clog Creep Damage Fix
7. Lost Soul White Fire Fix
8. White Fire Grants Mantle
9. Pickup Animation Fix
10. Kid's Drawing Form Fix
11. Ocular Rift Sound Fix
12. Pill Rewind Fix
13. Show Zodiac's Floor Item
14. Mom's Knife Homing Fix
15. Keep 1.00x Damage Multiplier
16. Keep Dead Bird Active
17. Eden Starting Passive Choice
18. Eden's Blessing Choice
19. Starting Wooden Cross
20. Blue Baby Deal Prices
21. Poop Queue Overflow Fix
22. Keep Health on Reroll
23. Keep Absorbed Stats
24. Reveal Pills with Rerolled PHD
25. Esau Jr. Pickup Effects
26. TMTRAINER Reroll Chance
27. Double Soul Charges
28. Soul Charge Shield
29. Shield Effects
30. Gello Wisp Orbit Fix
31. Explosion-proof Wisps

Options are grouped under the tabs `General`, `Eve`, `Eden`, `T-Lost`,
`T-Blue Baby`, `T-Eden`, and `Bethany`. The integration supports both Mod
Config Menu Impure's global `MCM` API and legacy/localized editions exposing
`ModConfigMenu`. Without MCM, saved or default settings still work normally.

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
