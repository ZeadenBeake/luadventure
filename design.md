# Luadventure design doc

This game isn't made by a professional developer, just by your local idiot
birb. The old version of this document was a couple of paragraphs about a
combat idea that isn't what got built. This version describes what's
actually in `luadventure.lua` today, so it's worth reading if you're picking
this project back up cold.

Sci-fi RPG, text-mode, single file, built against CraftOS-PC (a CC:Tweaked
emulator). Everything below is implemented and playable unless it says
otherwise.

### A note on locals

Lua's main chunk (the whole file, since none of this is wrapped in an outer
function) has a hard ceiling of 200 local variables - `luac -p` refuses to
compile at all, with a "too many local variables" error, if a change pushes
it over. This isn't a global budget across the file, though: each *function*
(including nested ones, and the main chunk itself) tracks its own currently-
active locals independently, so a local declared inside a `local function`
doesn't count against the main chunk's 200 at all, no matter how deeply
nested - only bare top-level locals do (declaring one, using it, and never
touching it again afterward doesn't help either: Lua only frees a slot once
its lexical scope actually closes, and a top-level local referenced by
anything defined later in the file - which is nearly everything here -
never closes before EOF).

Two things actually reduce the top-level count, then, both already in use:

- **A separate file.** `require`d code is its own chunk with its own fresh
  200-local ceiling - splitting `gamedata.lua` out (see its own header
  comment) freed real headroom this way, not just organizational tidiness.
- **A table.** Every engine-internal function that used to be its own
  `local function` now lives as a field on one `local engine = {}` instead
  (`function engine.foo(...) ... end`) - a table field costs nothing
  against the limit no matter how many hang off it, only the one bare
  `engine` local does. The same idea already covered *state* before this
  (`combatState`, `debugConsole`, `SAVE` - several things that would
  otherwise be separate top-level locals, grouped into one); `engine`
  is the same pattern applied to nearly everything that used to be a
  top-level `local function`, which is why call sites throughout this file
  read `engine.foo(...)` rather than a bare `foo(...)`. A function that's
  only ever called from exactly one other function is a third, narrower
  case - nesting it directly inside its one caller (`pickWieldingHands`,
  `changeGrip`) also costs the outer function's own local budget, not the
  main chunk's, without needing to go through `engine` at all.

Before adding a new top-level `local` (a constant, a piece of state that
doesn't fit `engine`), check whether one of these already covers it.

## Screen layout

Four corners while exploring: stats (top-left), a portrait placeholder
(top-right, nothing draws here yet), the walkable map (bottom-left, half the
width it used to be), and the activity log (bottom-right - see "Activity
log"). The inventory and any blurb/dialogue interaction take over the whole
screen as their own modal window instead of sharing the four corners.

Combat gets its *own* four-corner layout rather than a single full-screen
window - map (top-left), the action menu (bottom-left), a combat-scoped log
(top-right - see "Activity log"), and the enemies in the scene (bottom-right
- see "Combat menu & movement"). Combat's own sub-pickers (choosing an
attack, a limb, an ability, a reload/belt target) and the two moments that
still genuinely warrant stopping the player in their tracks (victory,
death) fall back to the same full-screen window the inventory and dialogue
use.

Controls: arrow keys move, `Space` interacts with whatever's cardinally
adjacent (see "Environment objects & symbols"), `i` opens the inventory,
`q` quits immediately. Menus almost everywhere use digit keys `1`-`9`/`0`
then `a`-`z` for lists longer than ten items (see "Digit/letter menus"
below).

### Activity log

Two separate logs sharing one pattern (`wrapText` wraps a line to the
pane's width, an ever-growing buffer of already-wrapped lines, a draw
function that redraws whatever tail end currently fits): `logActivity`/
`activityLog`/`drawLog` for the overworld's bottom-right corner, and
`logCombat`/`combatActivityLog`/`drawCombatLog` for combat's own top-right
corner (reset per encounter via `resetCombatLog`). A full-screen modal
draws right over whichever corner it's covering, so both `render()` (the
overworld) and `promptAction` (combat) redraw their log from its retained
buffer afterward rather than just reasserting visibility - toggling
`setVisible(true)` alone is a no-op if it's already `true`, so that alone
wouldn't actually restore anything a modal drew over it.

`logActivity` is for things that happen **outside combat**: picking
something up, a door opening or closing, using an item outside a fight (the
salve, so far - see "Inventory & equipment"), changing region, and the
moment a fight actually starts, wins, or is fled from (not what happens
*during* one - that's `logCombat`, in its own pane, visible for the whole
fight rather than only once it's over). `logCombat` is for everything
routine that happens mid-fight - a swing landing or missing, a status tick,
an enemy closing in - so only the small handful of moments that actually
warrant the player's full attention (`showCombatMessage` - victory, death)
still interrupt. `joinEnemyNames` turns `scene` into "the test dummy" for
one foe, an Oxford-comma list for more - nothing spawns more than one yet,
but `scene` is already a list (see "Victory").

**Pacing**: `logCombat` pauses for `combatState.logDelay` (0.5s, the one
knob for all of this) after drawing each line, so a turn's events reveal
one at a time instead of dumping the whole result at once - every call site
gets this for free rather than remembering to pace itself. Anything that
resolves in multiple steps (a swing, then a hit or miss; Rev it up!'s five
separate cuts) logs each step as its own `logCombat` call rather than one
combined line, so the delay actually paces them apart; a multi-hit ability
also logs a "dealt N damage" summary line once it's done. Landing a hit also
flashes the target's map glyph red for the same `logDelay`
(`combatState.flash`, straight ANSI color via `term`'s `colors` API - works
fine through CraftOS-PC's ncurses CLI renderer). Since a fullscreen
sub-picker (choosing an attack, a limb, an ability) draws right over the
map/enemy/log/action panes, whatever was showing needs putting back the
moment the picker closes - `combatState.redrawPanes` redraws the map, enemy
list, and log, and blanks the action pane (its actual content depends on
`restricted`, which isn't in scope from every call site - a blank pane is a
valid resting state since nothing reads a selection out of it
mid-resolution anyway), called right after every such picker returns and
before any of the paced logging above starts, so a flash never lands on
stale picker text instead of the actual map; `promptAction` redraws all of
this itself too at the top of every prompt, which is what catches an
instant action like Look (nothing else logs afterward to trigger a redraw
on its own).
`combatState` bundles all of this (the delay, the flash/redraw functions,
and the current encounter's loc/scene/selection - so ability effects can
reach them without loc/scene threaded through every function signature)
into one table rather than several more top-level locals - see "A note on
locals" below.

Combat deliberately never calls `drawStats()` (the overworld's own
top-left stats pane) - `render()` already refreshes it the moment control
returns to the overworld, and `statsWin` occupies the exact same screen
region as `combatMapWin`. Calling it mid-fight doesn't just waste the draw;
it overwrites the live map with the overworld panel underneath whatever
single cell a flash happens to repaint next, which briefly looks like the
exploration screen bleeding through the fight.

## World & movement

Two layers, intentionally not the same thing:

- **Region graph** (`world`, `location:new`) - a handful of named places
  (`village`, `grasslands` right now) connected by `directions` (up/down/
  left/right). This is the coarse map.
- **Walkable grid** - each location also has its own small grid
  (`width`/`height`, default 7x5) you move around one cell at a time. Walking
  off the edge of a grid in a direction that has a matching region-graph
  connection moves you to the connected location, entering from the
  opposite edge (walk off the right edge, arrive on the left edge of
  wherever's next).

### Environment objects & symbols

Each location has an `objects` list. `findObjectAt` resolves collisions,
`getObjectGlyph` decides what a given object currently looks like:

| Glyph | Kind | Notes |
|---|---|---|
| `#` | wall | Solid rectangle (`x1,y1,x2,y2`), blocks movement, no interaction |
| `*` | item | Auto-collected the moment you step onto it (`collectItem`) - logged, no prompt |
| `-` / `\|` | door | Horizontal/vertical; see below - opens/closes without a prompt either |
| `!` | person (quest) | Quest not yet taken, or done and ready to hand in |
| `?` | person (quest) | Quest active, not yet ready to turn in |
| `0` | person | Flavor-only NPC, or a quest giver with nothing left to give |
| `E` | enemy | Walking into it starts `runEncounter()` |
| `$` | save point | Save / Load / Quit Game (see "Save & load") |

Two different ways to trigger a reaction from something on the map:

- **Bumping into it** (walking into a cell that isn't clear) - `tryMove`
  handles an item or a closed door itself, without a prompt (see below);
  anything else still blocking (a person, a save point, an enemy, a wall)
  goes through `interactWithObject`, which dispatches on `obj.kind` and
  returns `(playerDied, quitRequested)` - both bubble all the way up to the
  main loop, since either one ends the program.
- **`Space`** (`tryInteract`) - checks each of the four cardinal-adjacent
  tiles (never diagonals, so two interactables sitting right next to each
  other don't create ambiguity) and acts on the first one found. This is
  the only way to *close* a door again - bumping one only ever opens it -
  but works generically on anything adjacent, routing to the same
  `interactWithObject` for a person/save point/enemy.

Items and doors got simplified on the theory that there's no harm in just
doing the thing: standing on an item just picks it up (`collectItem` -
inserts it, removes the map object, logs it - see "Activity log"); bumping
a closed door just opens it (`toggleDoor`), logged the same way, but that's
the whole action for that move - stepping through still takes a second one,
same as bumping into anything else that was blocking the way. Neither ever
reaches `interactWithObject` at all anymore; both callers (`tryMove`,
`tryInteract`) handle them directly. A person, a save point, and a fight
still go through a real prompt - those have actual stakes or a meaningful
back-and-forth, so simplifying them away wouldn't make sense.

## Body system

Bodies are trees, not fixed hit-location lists. The torso (`newTorso`) is
the root and is never swapped wholesale; everything else is a **part
template** (`partEntries`) instantiated (`instantiatePart`) and attached
into a named sub-slot (`attachPart`) - `head`, `left_arm`, `left_arm.hand`,
and so on. Extra slots (a second pair of arms, wings, a tail) exist on the
torso already, gated behind tags (`MULTI_LIMBED`, `WINGED`, `TAILED`) -
nothing grants `MULTI_LIMBED` yet, but the insectoid species grants
`WINGED`/`TAILED` (see "Species").

Each part has:

- **Health/max health** - damaged independently; death is torso health
  reaching 0 (`isDead`), not a global HP pool. A template's `aimDifficulty`
  (default 1, most omit it) divides its starting health at creation - see
  "Stats & combat" for the other half of what it does.
- **Organ slots** - hardcoded categories (`skin`, `bone`, `muscle`, plus
  torso-only `vitals`/`auxiliary`) that can be swapped (`installCategoryOrgan`),
  and a generic list for anything else installable (`installGenericOrgan`,
  cybernetics etc.).
- **Tags** - binary flags, split into **local** (this part and whatever's
  installed in it) and **global** (character-wide, recalculated via
  `recalcGlobalTags` whenever an organ that grants one changes). The two
  namespaces are assumed never to overlap. `metaTags` marks a few as
  engine-only (never shown on player-facing UI).
- **Zone** - which apparel coverage zone this part's protection comes from
  (see "Apparel & coverage"). Parts that can't be covered by clothing at all
  (horns, antennae, a stinger) just don't set one, and inherit whatever zone
  their parent has instead (`getPartZone` walks up the tree).

Organs and slots can `requires`/`conflicts` tags, and organs can
`grantsLocal`/`grantsGlobal` tags of their own - that's the whole
mod-slot-unlocks-another-mod-slot chain (a cybernetic eye grants
`OCULAR_IMPLANT` globally, which a targeting suite elsewhere on the body can
then require).

Numeric organ effects (`modifiers`, e.g. `strength`) aren't local to a part -
they flow up the ancestor chain (`getAncestorMultiplier`), so a reinforced
upper arm makes the hand attached to it hit harder too, not just the arm
itself. `getLimbStrength` combines that with each ancestor's own condition
(current health / max health), so a fracture on the arm still throttles a
perfectly healthy hand at the end of it.

## Species

`speciesEntries` - each has a `build(globalTags)` function (same signature
as `newHumanBody`) that constructs a fresh body, and `statAdjustments`, flat
one-time deltas applied to `character.stats` at creation (same granularity
as character creation's own stat points, just species-driven). Chosen
during character creation (see below); nothing about picking a species
touches anything species-specific elsewhere, so adding a new one is just
adding a `build` function and an entry in the table.

- **Human** (`newHumanBody`) - the original baseline, unchanged.
- **Insectoid** (`newInsectoidBody`) - chitin skin/bone on the torso itself
  instead of the human baseline (`chitin_skin`/`chitin_bone`); the bone
  organ is what actually grants `TAILED`/`WINGED` globally (swap it out and
  those slots would lock again), unlocking the torso's tail slot for a
  separate `abdomen` part (chitin-skinned too) and leaving the wing slots
  deliberately empty for now. The torso is never relabeled or otherwise
  treated as anything but a torso - a torso is what every creature has, so
  species-specific anatomy is expressed entirely in what attaches to it.
  The abdomen isn't a literal tail, just structurally treated like one
  (same slot, same `TAILED` gating); the sting itself is a further
  attached `stinger` part, its own `subSlots` entry on the abdomen (see
  "Natural weapons") rather than folded into the abdomen's own mass -
  small and precise enough to warrant a steeper `aimDifficulty` of its own
  (see "Stats & combat"), and a future home for cybernetics that modify
  the sting or its venom once those exist. Destroying the abdomen takes
  the sting down with it, same as destroying any other limb's parent
  would. The head
  (`insectoid_head`) has its own antennae slot, filled with a plain
  `antenna` part (does nothing on its own yet - body-part tuning is a later
  pass), and installs a generic `insectoid_features` organ that grants
  `UNSIGHTLY` globally - compound eyes, mandibles, the whole look, modeled
  as a generic organ rather than a part-intrinsic tag since there's no
  mechanism for a part's mere shape to grant a global tag outside the
  organ-grant system. Chitin skin's tradeoff (small reflex penalty, small
  endurance bonus) is split across two different mechanisms for two
  different reasons: the reflex penalty is a flat
  `statAdjustments.reflex = -0.05` (there's no per-part reflex modifier
  consumed by anything yet, so a real organ modifier wouldn't do anything);
  the endurance bonus is a flat 10% damage reduction (`part.endurance`,
  read by `damagePart`) applied to every part once after the whole body is
  built - real, immediate, and (unlike a type resistance) applies to every
  damage type with no exception, untyped included.

`UNSIGHTLY` doesn't affect anything mechanically yet beyond one hardcoded
example (see "Dialogue templating") - the intent is NPC reactions and
harder social situations (a shop haggling worse, say) once there's more of
either to react with.

## Stats & combat

Character-level stats (`character.stats`): `strength`, `aim`, `reflex`,
plus `level`/`health`/`max_health` and a few fields (`dr`, `defense`,
`speed`, `weight`, `max_inventory`) that are declared but not wired into
anything yet.

- **Hit chance**: `aim * (1 - target's reflex / 2)`, then a flat
  per-tile-of-distance penalty from the weapon's `spread` stat
  (`getFinalHitChance`) - melee weapons with range 1 never feel it, since
  there are zero tiles between attacker and target at point-blank.
  `aim`/`reflex` aren't read raw: `getEffectiveAim` scales by the
  attacker's own head condition, `getEffectiveReflex` by the average limb
  strength of both legs - a busted head throws off your own aim, worn-down
  legs make you easier to hit. Once a specific target part is known (both
  the player's own attacks and an enemy's now always pick their target
  before rolling, not after), that part's `aimDifficulty` (default 1)
  divides the chance again on top of spread - a hand or head (both 1.5),
  and more so a stinger (2.5, small and precise enough to warrant a
  steeper one of its own), is harder to land a hit on than aiming dead
  center, at the cost of the same divisor taken off its own health (see
  "Body system"). Reused by nothing else yet, but meant to be - a shared
  "small/fast target" factor rather than a hit-chance-only special case.
- **Melee damage**: `stats.strength * getLimbStrength(attacker, the limb
  doing the hitting)` - averaged across every hand for a two-handed weapon
  instead of read off just one (`getWeaponStrength`; see "Two-handed
  weapons"). Ranged weapons don't scale with strength at all, regardless
  of hand count.
- **Damage types**: `bludgeoning`, `piercing`, `slashing`, `fire`, `frost`,
  `radiation`, `toxic` (poison's own damage type), `untyped`. A part can
  have `resistances` per type (a multiplier, default 1); `untyped` never
  gets one, full stop - it's for things like bleed/poison that don't
  cleanly fit a "real" type.
- **Endurance**: a part can also have a flat `endurance` (0-1, a percentage)
  applied on top of - and independent from - type resistance, with no
  exceptions: unlike resistance, it reduces untyped damage too. Insectoid's
  chitin skin is the only source so far (see "Species"). Order of
  operations in `damagePart`: `amount * resistance * (1 - endurance)`,
  then apparel coverage subtracts a flat amount from that.

### Apparel & coverage

Worn items (`character.worn`, a flat list of item ids) each declare a
`layer` (`inner`/`outer`), which finer-grained **areas** they `covers`
(`upper_body`, `hand`, `head`, ...), and flat per-damage-type `coverage`.
Areas roll up into **zones** (`COVERAGE_AREAS`/`AREA_TO_ZONE`) that match a
body part's own `zone` field. Two items on the same layer can't claim
overlapping areas (`canWearItem`).

Damage reduction only cares about the zone as a whole, not which exact area
got hit - and critically, it's the **average** coverage across every area in
that zone (`getCoverage`/`getAreaCoverage`), not the full value of whichever
item happens to cover any one area of it. A vest that only covers
`upper_body` doesn't fully protect the torso; it raises the average while
the uncovered `lower_body`/`pelvis` drag it back down. The `belt` area is
excluded from this average entirely - reserved for future belt-slot-
expanding items, unrelated to armor.

Parts that can't be covered (horns, antennae, a stinger) inherit whatever
coverage their parent's zone provides, via the same `getPartZone` fallback
used everywhere else. The insectoid's abdomen isn't one of these - it has a
real zone of its own (`tail`), same as any other limb.

### Status effects

Applied to a single part (`applyPartStatus`, an injury) or the whole
character (`applyCharacterStatus`, a condition). `duration` ticks down by
one every full round (`decrementStatuses`); `-1` is permanent. Applying the
same status again combines with whatever's already active
(`combineDuration`): a stacking status (`stacks = true`, like bleed) adds
the two durations together, a non-stacking one just takes the higher.
`damagePerStack` deals a hit of that damage type equal to the current
duration, once per round, right before it decrements - that's the entirety
of how bleed works, there's no separate damage-over-time system.

Currently defined: `fracture` (permanent, halves limb strength),
`adrenaline` (character-wide, ignores condition penalties for its
duration), `bleed` (stacking, untyped damage-per-stack), `poison` (stacking,
toxic damage-per-stack - mechanically identical to bleed, just its own
damage type and its own tick message, via `DOT_VERBS`).

### Abilities & action economy

Anything installed/equipped/carried can grant abilities (organs, weapons,
belt items) - `collectAbilities` gathers them all into one list regardless
of source. Each has a `speed`:

- **`full`** - the whole turn, always ends the round.
- **`quick`** - half a turn. The *first* quick action taken in a round
  grants a bonus turn (tracked via a `quickened` flag); a *second* quick
  action (already quickened) spends the other half and ends the round.
  Once quickened, full actions are off the table for the rest of the round.
- **`instant`** - free. Always grants another turn, never touches
  `quickened` either way.

An ability's `effect` can return `"noop"` (nothing happened - e.g. out of
range, don't spend the turn) or `"miss"` (it swung and missed - spend the
turn, but refund the cooldown, since nothing about the ability actually
landed). Nothing needs to signal a kill; see "Victory" below.

Currently defined: **Adrenal Auto-Injector** (instant, pops adrenaline),
**Rev it up!** (chain sword only, full action, one hit roll covering five
5-10 damage sub-hits, refunds its cooldown on that single roll missing),
**Use Dermoregenesis Salve** (quick, heals 25 to a chosen part, consumed
from the belt), **Charge Shot** (laser pistol only, always a full action
even one-handed, no cooldown, double damage for 3 ammo instead of 1),
**Spray** (rifle only, full action, cooldown 3, three separate shots at
one target - each its own hit roll at a flat accuracy penalty, unlike Rev
it up!'s single roll covering every sub-hit - burning 3 ammo regardless of
how many land; always resolves at full cooldown once it starts firing,
since there's no single roll to gate a refund on the way Charge Shot and
Rev it up! each have).

### Victory

`runEncounter` checks the scene for survivors at the very start of every
player turn (`sceneCleared`), rather than every attack path individually
guessing whether its own hit was the killing blow. Once everyone in the
scene is down, `showVictoryScreen` logs each kill by `typeId` onto
`player.killLog` (a count table) and shows a summary - `killLog` is what
quests read (`(player.killLog.test_dummy or 0) > 0`), so a search-and-
destroy quest for, say, three bandits is just `>= 3` against that same
table, no bespoke flag per encounter needed. `scene` is already a list, so
multi-enemy encounters fall out for free whenever something spawns more
than one foe at once - nothing does yet.

### Combat menu & movement

`promptAction` builds the action menu dynamically rather than drawing fixed
numbered lines: **Fight**, **Look**, **Reload** (only shown at all when
`hasAmmoWeapon` says an equipped weapon actually uses ammo), **Ability**,
**Equipment** (see "Two-handed weapons" for what it's grown into beyond
its original "Belt" name - the internal action id/`runEquipmentAction`
function are unchanged, only the label shown to the player is), **Idle**,
**Flee**, numbered in that order with whichever entries
apply - drawn into its own bottom-left pane with no "What will you do?"
header, since between the numbered options and the move hint that's already
everything the pane has room for without needing to scroll. Movement isn't
a menu entry - arrow keys reposition immediately, same turn cost and
quickened/full gating as ever (a "You don't have time to move" rejection if
quickened and reflex isn't fast enough, silently no-op on stepping into a
wall), just without a separate confirmation step in between. A hint line
("Arrow keys to move (quick)" or "(full)", read off `getEffectiveReflex`)
sits under the numbered options so this isn't a hidden control. A
successful step calls `combatState.redrawPanes()` immediately, before
whatever comes next (ending the round, the enemy's own paced turn) - the
step itself should read as instant, not wait behind the round it might
trigger.

**Enemy selection**: the bottom-right pane (`drawEnemyList`) lists every foe
in `scene`, health included, with whichever one's currently selected marked
- `Tab` cycles it, handled right inside `promptAction`'s own key loop
(doesn't cost a turn or count as an action). **Fight** and **Look**, and
whatever enemy an ability's own effect targets, all act on this selection
rather than a hardcoded single opponent - `runEncounter` reads it back out
as `foe` (`scene[selectedEnemyIndex]`) once `promptAction` returns. Only one
enemy exists yet, so this never actually has anywhere to cycle *to*, but
every part of the plumbing (the selection index itself, the list drawing,
targeting reading off it instead of a bespoke variable) already treats
`scene` as a real list rather than assuming exactly one - the next enemy
type just has to show up in it.

**Look** is an instant action (`viewLimbs`, a read-only version of
`pickLimb` that shows the selected foe's whole limb list - health included
- without prompting to choose one, since sizing up an opponent isn't a
targeting decision). Being instant, it never touches `quickened` and always
grants another turn, same as the Adrenal Auto-Injector.

### Weapons

`strike` (baseline unarmed - see "Inventory & equipment"), `chain_sword`
(melee, slashing, applies 2 stacks of bleed on hit, grants Rev it up!),
`laser_pistol` (ranged, fire damage, 10-shot energy weapon, grants Charge
Shot), `stinger_sting` (melee, piercing, barely any damage but applies 5
stacks of poison - see "Natural weapons"), `rifle` (ranged, piercing,
12-shot kinetic weapon, roughly double a pistol's damage with better range
and less spread, grants Spray - see "Two-handed weapons" for what makes it
different to wield). `handedness` (`"one-handed"` or `"two-handed"`)
decides whether a normal attack with it is a quick or full action - and,
for `"two-handed"`, quite a bit more besides.

### Two-handed weapons

A `"two-handed"` weapon needs two of a wielder's MANIPULATE hands to
actually fire, not one - the rifle, so far. `getWieldingHands(combatant,
label)` is the one place that knows which hands currently share a given
weapon: every hand whose `equipped` slot names the same weapon id, in
stable body-tree order (`collectLabeledParts`). Its first entry is always
the **canonical** hand for the group - the only one that actually gets a
row in the inventory screen, an option in `pickAttack`, or an entry from
`collectAbilities` (every other function that touches equipped weapons
would otherwise list a two-handed one twice, once per hand) - and the only
one `character.ammo` is ever keyed under for it, since ammo tracking is
still per-slot and a two-handed weapon only has the one shared pool.
Melee damage for a two-handed weapon averages `getLimbStrength` across
every hand holding it (`getWeaponStrength`) rather than reading just one,
so a fracture on either side of the grip drags the whole swing down, not
only its own half; ranged weapons like the rifle don't scale with strength
at all regardless of hand count, same as ever.

**Improper grip**: `getWieldingHands` can come back with *fewer* hands
than a weapon actually needs - held, but not usable. `pickAttack` and
`collectAbilities` both gate on hand *count* now, not just whether every
holding hand is functional (a properly-gripped weapon with a destroyed
hand and an improperly-gripped one with two working hands fail the same
usability check for different reasons). This is a real, reachable state
rather than an edge case: the equipping picker (below) allows it directly,
and it's what a two-handed weapon drawn mid-fight always lands in.

**Equipping**: Move (see "Inventory & equipment") can express "this slot"
but not "these two slots at once", so dropping a two-handed weapon onto
*any* hand opens a dedicated picker (`pickWieldingHands`, nested inside
`runInventoryScreen` itself) instead of equipping it outright - every
MANIPULATE hand listed, toggled green/white with Enter, capped at two
selected (a Cancel option backs out with the weapon still carried, to try
again or Move it to the bag instead). Confirm needs at least one hand
picked, but not necessarily both: confirming with fewer than it needs
first warns ("you won't be able to fire the Rifle with just one hand -
equip anyway?") rather than silently locking Confirm until exactly two are
picked, since an improper grip is a legitimate choice (freeing a hand for
something else, say), just one worth flagging before it's made. Confirming
either way displaces whatever was on every chosen hand back to the bag
first, same as an ordinary one-handed equip does.

**Change Grip**: the Equipment action (see "Inventory & equipment" - it
outgrew the name "Belt") is where a two-handed weapon's grip changes
mid-fight, quick either direction. Selecting a slot holding one offers
*only* "Change grip" - not the ordinary swap-to-another-slot flow a
one-handed weapon gets, since a two-handed weapon can't go on the belt at
all (below) and relocating *which* hands hold it is exactly what grip-
changing already covers. Reducing to one hand asks which of the current
hands to keep if there's a real choice, freeing the other and moving the
ammo pool along if the freed hand happened to be canonical; regripping
properly claims however many free hands it's still missing, refusing if
there aren't enough, and migrates the ammo pool too if adding a hand
changes which one is canonical (canonical is always whichever hand comes
first in body-tree order - added a hand ahead of it in that order, and it
takes over).

**Drawing**: Equipment's empty-slot flow (draw a weapon from another slot
or `droppedItems` into an empty one) never produces a proper two-handed
grip on its own - drawing one always lands in just the one hand chosen as
the destination, clearing out wherever it came from (every hand it
occupied, if it was already improperly gripped elsewhere) rather than
trying to also claim a second hand nobody picked. Reaching a proper grip
from there is a follow-up Change Grip, a separate (quick) action. A
two-handed weapon can't be drawn into (or holstered onto) a **belt** slot
at all - it doesn't fit - so it's filtered out of the candidate list
whenever the chosen destination is a belt slot, same "just don't list it"
convention as everywhere else.

**Destruction**: a two-handed weapon can't fire at all without enough
functional hands (not just "the ones holding it happen to be alive," per
"Improper grip" above), but it doesn't actually clatter to the ground
until *every* hand holding it is destroyed (`dropEquippedItem` - see
"Limb destruction & disarming") - a fresh Dermoregenesis Salve on the
first hand lost can still save it before the second one goes. Once it
does drop, its one shared ammo pool returns to the bag exactly once, from
whichever hand was canonical, and every slot it occupied clears together.

### Natural weapons

Most attacks come from a MANIPULATE limb (a hand) using whatever's
equipped there, or a bare Strike if nothing is. A **natural weapon** is the
other case: a part template with its own fixed `naturalWeapon` (a
`weaponEntries` id) that attacks with it unconditionally - the insectoid's
sting, so far, its own `stinger` part attached to the abdomen (see
"Species") rather than folded into the abdomen itself, precisely so it can
carry its own steep `aimDifficulty` and, eventually, its own organ slots.
`getAttackWeapon` picks between MANIPULATE/`equipped` and a template's
`naturalWeapon` for any given part; `pickAttack` lists both kinds of
attacker side by side. A natural weapon is never read from `equipped`, so
unlike a held weapon it can't be swapped, dropped, or disarmed - the only
way to take it away is destroying the part carrying it (see "Limb
destruction & disarming", which every attacker - natural weapon or not -
is already subject to).

### Limb destruction & disarming

A destroyed limb takes everything attached to it (further from the root)
down with it: `isLimbFunctional` walks a part's whole ancestor chain, and
if *any* of them (including itself) is at 0 health, nothing there can
attack - `pickAttack` and weapon-granted abilities (`collectAbilities`)
both check it. A destroyed arm disables the hand hanging off it without
touching what's equipped there; a destroyed abdomen takes its stinger down
with it the same way, and a destroyed stinger just disables itself.

A destroyed **hand** specifically goes one step further: whatever it was
holding is knocked loose (`dropEquippedItem`, called from the enemy-attack
branch of `runEncounter` - not from an arm being destroyed, only a hand).
A dropped weapon is tracked per-encounter in `droppedItems`, not
`player.inventory` - the **Equipment** action's empty-slot flow (see
"Inventory & equipment") can draw one straight into another hand
mid-fight, which is the only sensible option when there's no time to open
the full inventory screen - still unusable, same as a bare-handed Strike
from that hand would be, until the hand itself heals. Anything left
unclaimed when
the encounter ends instead lands in the bag via its own `itemId` (see
"Inventory & equipment" - weapons as items), letting the player re-equip it
themselves once it's actually useful again. A plain consumable held in a
hand isn't "wielded" the same way, so it skips this whole dance - it just
falls straight back into the bag on the spot instead, same as unequipping
it manually would. `dropEquippedItem` takes a slot directly, so a future
disarm effect (an enemy skill, say - none exist yet) can reuse it without
knowing anything about *why* something got dropped.

### Ammo

Weapons with `ammoCapacity` need a matching ammo item to reload
(`ammoClass`/`getAmmoItemId`) - `bullet` for kinetic weapons, `energy_charge`
for energy weapons. Ammo is tracked per-**named-slot** on the combatant
(`character.ammo`) - an equip slot's own label, or a belt slot's synthetic
`"beltN"` one (see "Inventory & equipment") - never on the weapon template
itself, and never attached to the item sitting in the bag either, since
there's no mechanism to hang per-instance data off an item id at all. A
two-handed weapon still only ever gets the one named slot's worth (its
canonical hand's - see "Two-handed weapons"), not one per hand.
Energy ammo is deliberately fudged: there's no stateful partial-charge
battery item, instead a carried `battery` just raises how many loose
`energy_charge` items you're allowed to carry (`getMaxEnergyCharges`),
which is what keeps energy weapons meaningfully lighter than their kinetic
equivalents without tracking charge state per battery.

Since ammo lives on the *slot*, not the weapon, unequipping one (for any
reason - swapping it for another, a destroyed hand, eventually looting an
enemy's gun) has to do something with whatever was loaded. `depositAmmo`/
`returnAmmoToInventory` convert it back into loose ammo items in the bag
rather than leaving it stranded on a slot nothing occupies anymore -
"ammo follows the weapon" in spirit, even though it can't literally follow
the *item*. The one place this doesn't apply is a straight slot-to-slot
move (an equip slot to a belt slot or back, see "Inventory & equipment") -
there, the ammo count just travels along with the swap directly, since both
ends are real tracked slots and nothing needs to spill.

## Inventory & equipment

Full-screen modal (`inventoryWin`/`runInventoryScreen`), not the original
one-row bar - that bar still exists as a page-tab strip (`Tab` to toggle),
just repurposed. Rows, top to bottom: belt slots (always visible, even
empty), one **equip slot** per MANIPULATE limb (`getManipulateLimbs`,
derived from the body rather than a hardcoded pair of hands), that limb's
ammo (only shown if what's wielded there actually uses ammo), then
everything else in the bag, grouped by id with a count (five energy
charges are one row, not five).

Two keys do the work, split by what they mean rather than what they touch:

- **`Enter`** - use immediately. Reload for an ammo row (bypassing the
  in-combat reload action entirely - nothing special happens on reload, so
  there's no reason to make the player go through combat for it); whatever
  ability a belt/inventory entry grants otherwise (the salve, so far -
  `ability.effect` is called directly, works outside combat since nothing
  it does is combat-specific, and a cancelled limb-pick correctly doesn't
  consume it, same `"noop"` convention combat abilities already use). An
  ability that's ever usable both ways can tell which by whether it was
  handed a real `enemy` (only `runEncounter` ever passes one) - the salve
  uses this to show its usual full-screen confirmation in a fight, but just
  log the result (see "Activity log") outside one, where a "press any key"
  prompt would just be friction once the limb's already picked.
  Everything else (a spare weapon sitting in the bag, apparel, ammo itself,
  an equip slot) doesn't respond - equipping needs a chosen destination,
  which Enter alone can't express.
- **`M` (Move)** - picks up whatever's in the selected row (its ammo, if it's
  a weapon with any loaded, travels right along with it), then places it
  wherever you navigate to next and press `M` again. A weapon *or* a plain
  item dropped on an equip slot goes there - a hand can hold a consumable
  exactly like a weapon (see below) - and a weapon or plain item dropped on
  a belt slot works the same way (a belt slot can hold a loaded weapon
  exactly like an equip slot can - see below). Either way, whatever was
  already there is displaced back to the bag (its ammo spilled loose first
  - see "Ammo" - then its own item, via its `itemId`, unless it has none,
  like Strike, in which case nothing is added back). Dropped anywhere else,
  it just lands in the general bag instead (ammo included) - always a valid
  resting place regardless of where it came from, which is also how
  unequipping works: pick it up, then press `M` again without needing a
  matching slot at all. Closing the inventory mid-carry safely undoes the
  pickup rather than losing whatever was picked up. A two-handed weapon
  dropped on an equip slot is the one exception to "goes there outright" -
  see "Two-handed weapons" for the picker it opens instead.

**Weapons as items**: a weapon can have an `itemId` (chain_sword,
laser_pistol, rifle so far) naming its carryable, bulk-having form in
`itemEntries`, which in turn has a `weaponId` pointing back - the two
together are what let the inventory screen swap a weapon between
"wielded", "holstered", and "sitting loose in the bag". `strike` (the
generic bare-handed fallback every MANIPULATE limb reverts to - renamed
from "Fist", since not every species specifically punches) has neither;
it's never a real, droppable item.

**Bulk** is the carry-weight system (Pathfinder-esque): every item has a
flat `bulk` cost except 0.1 ("Light", displayed as `L`). Capacity
(`getBulkCapacity`) is `10 * average limb strength + bulkBonus` (equipment
like a backpack would raise `bulkBonus`; nothing does yet). Equipped (or
holstered) weapons don't count against it, same as worn clothes never
have - only what's actually sitting loose in the bag does.

**Belt**: a fixed number of slots (`beltSize`, currently 1) for
combat-usable items, separate from the main bag - and, like an equip slot,
able to hold a loaded weapon (its ammo tracked under the synthetic
`character.ammo` key `"belt" .. index`, see "Ammo") - **except** a
two-handed one, which physically doesn't fit in a belt slot at all (see
"Two-handed weapons"); one-handed weapons like the chain sword or laser
pistol are unaffected. A holstered weapon's row shows its loaded count in
place of the usual flat "1". A plain consumable can also sit in a hand
instead of the belt (an equip slot's `equipped[label]` holds either a
weaponId or a plain itemId - whichever table recognizes it decides which
it is; `getWieldedWeapon` naturally falls back to Strike for a hand
holding a non-weapon, so attack resolution needs no special casing at
all) - it acts exactly like a belt slot wherever that matters
(`getSlotContents`/`getAllSlots`, shared by the inventory screen and the
in-combat Equipment action below).

The in-combat **Equipment** action (`runEquipmentAction`, renamed from
"Belt" once it grew past just that - see "Two-handed weapons") replaced
the older dedicated Swap/Pick Up actions with one unified flow: it lists
every hand and belt slot together, then does whatever the chosen one's
contents imply. A one-handed **weapon** prompts a destination (any other
slot, shown with what's currently there) and does a true two-way exchange
(`swapSlots`) - ammo travels with it, and whatever was at the destination
comes back the other way, holstered rather than dropped. A **two-handed**
weapon offers *only* "Change grip" here instead (see "Two-handed
weapons") - no destination prompt, since it can't go on the belt and
relocating which hands hold it is what grip-changing already covers. A
**consumable** (hand or belt, no difference) is used on the spot - its
ability's `effect` is called with the real `enemy`, so it shows its usual
full-screen combat confirmation (see "Enter" above) rather than logging -
and the slot is cleared on success. An **empty** slot instead offers to
draw a weapon into it, sourced from any other slot currently holding one
*or* anything sitting in `droppedItems` this fight (a hand destroyed
mid-combat - see "Limb destruction & disarming") - a two-handed candidate
is left off the list entirely if the empty slot is on the belt (nowhere
for it to go), and always lands in just that one hand if it's a hand (see
"Two-handed weapons" - proper two-handed grip is a separate Change Grip
after). Swapping, changing grip, and drawing are otherwise full actions
except changing grip itself, which is always quick regardless of
direction; using a consumable takes whatever speed its own ability
declares (the salve is quick). Rather than filtering every slot up front
by what sub-action it implies, a swap/draw attempted while quickened is
simply rejected with a message and no turn spent, same pattern movement
has always used for a full action mid a quick action's bonus turn - using
a consumable, or changing grip, isn't gated this way at all, since both
are always quick. With only one belt slot right now hand-to-hand is the
common case, but every helper (`getAllSlots` and friends) is written
generically, so a second belt slot falls out for free. `getAllSlots`
itself leaves out a two-handed weapon's secondary hand entirely when
properly gripped (its canonical hand's row already represents the whole
thing) - gripped improperly, in just the one hand, there's no secondary
to leave out in the first place.

## Quests

`questEntries` - each has state-specific dialogue lines, an `isReady()`
check, a `rewardItemId`, and a `nextQuestId` (what the giver turns into
after turn-in; `nil` means they go quiet for good). Progress lives in
`player.quests` (`"active"`/`"done"`, not-yet-taken is just absent). One
quest exists so far: **Blunt the Blade**, offered by the Old Soldier in the
village, ready once the test dummy's been beaten at least once.

## Main menu

The very first thing shown at startup (`runMainMenu`, a `showInteraction`
loop) - **New Game** (runs "Character creation" below), **Load Save**, or
**Quit** (a bare top-level `return`, ending the script the same way
breaking out of the main loop already did). Load Save reuses
`pickSaveSlot`/`readSaveSlot`/`applySaveData` (see "Save & load") exactly
as the in-game save terminal's own Load does - since `applySaveData`
overwrites the live `player` object outright rather than assuming one
already went through creation, loading from here skips character creation
entirely rather than needing a throwaway character run through it first.
Cancelling out of the slot picker, or picking an empty slot, returns to the
main menu rather than falling through to anything else.

## Save & load

A `$` save point in the village (`village_terminal`) offers **Save**,
**Load**, or **Quit Game**, flavored as inserting an ID card. Five slots,
each shown with a summary (level, steps, which location's terminal made
it) instead of a bare number; saving over an occupied slot asks to confirm.

What's saved is deliberately "everything about the player, nothing about
position": full stats, inventory, equipped gear + ammo, worn apparel, belt,
statuses, cooldowns, quest progress, kill log, name, pronouns, and the
entire body tree (health/organs/statuses per part, rebuilt from templates
on load rather than trusting a frozen shape snapshot - self-healing against
future template tuning). Position itself isn't saved; only which save
point made the save is, and loading finds that same terminal again and
spawns you in an open cell beside it.

**World state** (which items have been picked up, which doors are open,
where each quest giver's dialogue cycle currently is) is saved too, as a
straight snapshot of every location's `objects` list - loading replaces
those lists wholesale rather than trying to reconcile individual entries.

Files are plain `textutils.serialize` output under `saves/slotN.sav`, in
the computer's own data directory - never inside the mounted project
folder, so nothing save-related touches this repo.

## Character creation

Runs once at startup, before the very first render: name (free text),
pronouns (Male/Female/Nonbinary presets, or "Custom pronouns" for two
direct text fields), species (see "Species" - this is where `player.body`
actually gets built, since it needs a menu, which needs the game's windows
to already exist), then 5 points to spend across strength/reflex/aim, each
worth a flat +5% (`stats.x = stats.x + points*0.05`, not compounding,
stacking on top of whatever the chosen species already adjusted). Confirm
is locked until all 5 points are spent; a Reset option clears an
in-progress allocation back to zero.

## Debug console

Gated behind `debugConsole.enabled`, set from a `--debug` argument on the
command line (`luadventure --debug`) - args reach the top-level chunk via
`...` like any CC program's, checked once at the very top of the file.
Opened with tilde/backtick from the overworld or mid-fight (checked
against `debugConsole.openKeys` rather than a single keycode - `keys.grave`
is the real CC:Tweaked constant for this key, but CraftOS-PC's ncurses CLI
renderer, what this project actually gets developed and tested against,
instead passes the raw ASCII value through for it: 96 unshifted, 126
shifted. Checking all three covers both). A slim scrollback + input line
(`debugConsole.run`, reusing `combatWin`) - type a command, see the result
appended below, keep going; `exit`/`close` returns control to whatever had
it (the overworld's main loop calls `render()` after, combat's
`promptAction` calls `combatState.redrawPanes()`), without costing a turn
or touching the action economy at all.

Commands (`debugConsole.commands`, name -> `function(args)`, `args` the
line's remaining space-separated tokens) all target the player's own body
only - no enemy-targeting syntax yet, nothing's needed it with only one
enemy type to test against:

- **`setHealth <limb> <health>`** - clamps to `[0, maxHealth]`.
- **`give <itemId> [count]`** - straight into the inventory, no bulk check.
- **`addStatus <limb> <status> [amount]`** - part-scoped statuses only
  (`bleed`/`poison`/`fracture` - `adrenaline` is character-wide, not
  reachable this way since every command here takes a limb); `amount`
  overrides the status's own default duration/stack count.
- **`clearStatus <limb> <status|all>`**

A bad limb/item/status name is reported back as an ordinary result rather
than raising - `debugConsole.runCommand` also wraps the actual call in
`pcall`, so a bug in a command itself can't take the whole game down either.

## Dialogue templating

`dialogue(str, who)` fills in `{{name}}`, `{{subject}}`, `{{object}}` (plus
the aliases `{{he}}`/`{{she}}` for subject and `{{him}}`/`{{her}}` for
object, so a line can be written with whichever gendered character in mind
reads most naturally, and it'll still come out matched to whoever's
actually playing) against a character's `name`/`pronouns` fields. Wired
transparently into `showInteraction`, so every blurb/greeting/quest line in
the game gets substitution for free without any call site needing to
remember to invoke it.

A greeting that depends on live player state (rather than always showing
the same lines) can't just be a table sitting on the object - saving
captures the whole world as plain data, and a function isn't serializable
at all. `dynamicGreetings` holds these instead, keyed by a plain string id
(`obj.greetingId`, same convention as `questId`/`itemId`/`saveId`) looked
up and called at interaction time. The one example so far: the village's
two gossiping NPCs (see "NPCs") say something different if the player is
`UNSIGHTLY`.

## Digit/letter menus

Any menu that can have more than nine entries (body part pickers, mainly -
attaching a horn was enough to push a body past ten parts) uses `1`-`9`,
then `0`, then `a`-`z` (`digitLabel`/`numberKeys`/`keyToNumber`), rather
than the plain `1`-`9`/`0` scheme shorter menus use. Body part pickers also
indent each entry like a folder tree, using the same parent-chain depth
that already drives tag/organ-modifier resolution - the eye can use the
same structure the engine already tracks internally to break up a long
flat list into something readable.

## NPCs

`npc` extends `character` with a `decide(state)` method each NPC type
overrides - given `{self, player, distance}`, returns one action for its
turn (`{action="attack"}`, `{action="move", dx=, dy=}`, or `{action=
"idle"}`). The only real one so far is `testDummyType`: closes to melee
range with cardinal-only movement (matching what the player can actually
do) and throws a fist punch once there. The dummy itself lives behind a
door in the grasslands specifically so it doesn't interrupt ordinary
exploration, but is still there to spar with on demand.

Two purely-flavor "Villager" NPCs stand next to each other in the village
sharing one dynamic gossip line about the player (see "Dialogue
templating") - functionally two adjacent people who happen to say the
exact same thing (whichever variant currently applies), not a real
NPC-to-NPC conversation system.

## Known gaps / likely next steps

- Portrait pane is still a placeholder - nothing draws there.
- `dr`/`defense`/`speed`/`weight`/`max_inventory` stats are declared but
  unused.
- No leveling system - `stats.level` exists and displays, nothing changes
  it.
- Only one enemy type (the test dummy) and one quest exist; multi-enemy
  scenes work mechanically (`scene` is already a list) but nothing spawns
  more than one foe at a time yet.
- Pronouns are consumed by name/`{{subject}}`/`{{object}}` templating;
  `UNSIGHTLY` by one hardcoded dialogue check. Neither affects anything
  beyond that yet - social mechanics (haggling, reactions) wait on NPCs and
  a shop system that don't exist yet either.
- Only one non-human species exists. Adding another is just a `build`
  function plus a `speciesEntries` entry - nothing else references a
  species by name anywhere.
- Save slots have no way to delete/rename, only overwrite.
- The test dummy always attacks with a bare Strike and doesn't go through
  `equipped` at all, so limb destruction never disables *its* attacks and
  it has nothing to drop - disarming (arm/hand destruction, a future disarm
  skill) is a player-only mechanic for now, same as the dropped-weapon
  system it's built on top of.
- No apparel-equipping UI exists yet - worn items are still only ever set
  directly in code (`spawnTestDummy`), never through anything the player
  can reach. Only weapons got the "equip slot" treatment.
- The activity log isn't part of save data - it's session-only scrollback,
  cleared on restart same as the screen itself would be.
- Quest/NPC dialogue still always shows a full prompt, even the purely
  flavor ones - only item pickup, doors, and outside-combat item use moved
  to the activity log so far.
