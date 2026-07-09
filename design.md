# Luadventure design doc

This game isn't made by a professional developer, just by your local idiot
birb. The old version of this document was a couple of paragraphs about a
combat idea that isn't what got built. This version describes what's
actually in `luadventure.lua` today, so it's worth reading if you're picking
this project back up cold.

Sci-fi RPG, text-mode, single file, built against CraftOS-PC (a CC:Tweaked
emulator). Everything below is implemented and playable unless it says
otherwise.

## Screen layout

Three panes while exploring: stats (top-left), a portrait placeholder
(top-right, nothing draws here yet), and the walkable map (bottom). Combat,
the inventory, and any blurb/dialogue interaction take over the whole screen
as their own modal window instead of sharing the three panes.

Controls: arrow keys move, `i` opens the inventory, `q` quits immediately.
Menus almost everywhere use digit keys `1`-`9`/`0` then `a`-`z` for lists
longer than ten items (see "Digit/letter menus" below).

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
| `*` | item | Blurb + "Pick it up"/"Leave it"; removed from the map on pickup |
| `-` / `\|` | door | Horizontal/vertical; "Open it" turns it into `.` (open, walkable) |
| `!` | person (quest) | Quest not yet taken, or done and ready to hand in |
| `?` | person (quest) | Quest active, not yet ready to turn in |
| `0` | person | Flavor-only NPC, or a quest giver with nothing left to give |
| `E` | enemy | Walking into it starts `runEncounter()` |
| `$` | save point | Save / Load / Quit Game (see "Save & load") |

Walking into anything blocking calls `interactWithObject`, which dispatches
on `obj.kind` and returns `(playerDied, quitRequested)` - both bubble all the
way up to the main loop, since either one ends the program.

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
  reaching 0 (`isDead`), not a global HP pool.
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
  (horns, a stinger, antennae) just don't set one, and inherit whatever zone
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
- **Insectoid** (`newInsectoidBody`) - chitin skin/bone instead of the human
  baseline (`chitin_skin`/`chitin_bone`); the bone organ is what actually
  grants `TAILED`/`WINGED` globally (swap it out and those slots would lock
  again), unlocking the torso's tail slot for a `stinger` and leaving the
  wing slots deliberately empty for now. The root part is relabeled
  "abdomen" instead of "torso" (`body.rootLabel`, read by
  `collectLabeledParts` - purely cosmetic, doesn't change how anything
  works structurally) and, same as `newTorso` always sets up, is MORTAL.
  The head (`insectoid_head`) has an antennae slot (also left unpopulated)
  and installs a generic `insectoid_features` organ that grants `UNSIGHTLY`
  globally - compound eyes, mandibles, the whole look, modeled as a generic
  organ rather than a part-intrinsic tag since there's no mechanism for a
  part's mere shape to grant a global tag outside the organ-grant system.
  Chitin skin's tradeoff (small reflex penalty, small endurance bonus) is
  split across two different mechanisms for two different reasons: the
  reflex penalty is a flat `statAdjustments.reflex = -0.05` (there's no
  per-part reflex modifier consumed by anything yet, so a real organ
  modifier wouldn't do anything); the endurance bonus is a flat +10 to
  every body part's max health, applied once after the whole body is built.

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
  legs make you easier to hit.
- **Melee damage**: `stats.strength * getLimbStrength(attacker, the limb
  doing the hitting)`. Ranged weapons don't scale with strength at all.
- **Damage types**: `bludgeoning`, `piercing`, `slashing`, `fire`, `frost`,
  `radiation`, `untyped`. A part can have `resistances` per type (a
  multiplier, default 1); `untyped` never gets one, full stop - it's for
  things like bleed that don't cleanly fit a "real" type.

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

Parts that can't be covered (horns, and by extension wings/antennae/stinger
whenever they exist) inherit whatever coverage their parent's zone provides,
via the same `getPartZone` fallback used everywhere else.

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
duration), `bleed` (stacking, untyped damage-per-stack).

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
even one-handed, no cooldown, double damage for 3 ammo instead of 1).

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

### Weapons

`fist` (baseline unarmed), `chain_sword` (melee, slashing, applies 2 stacks
of bleed on hit, grants Rev it up!), `laser_pistol` (ranged, fire damage,
10-shot energy weapon, grants Charge Shot). `handedness` decides whether a
normal attack with it is a quick or full action.

### Ammo

Weapons with `ammoCapacity` need a matching ammo item to reload
(`ammoClass`/`getAmmoItemId`) - `bullet` for kinetic weapons, `energy_charge`
for energy weapons. Ammo is tracked per-equip-slot on the combatant
(`character.ammo`), never on the weapon template itself. Energy ammo is
deliberately fudged: there's no stateful partial-charge battery item,
instead a carried `battery` just raises how many loose `energy_charge`
items you're allowed to carry (`getMaxEnergyCharges`), which is what keeps
energy weapons meaningfully lighter than their kinetic equivalents without
tracking charge state per battery.

## Inventory & equipment

Full-screen modal (`inventoryWin`/`runInventoryScreen`), not the original
one-row bar - that bar still exists as a page-tab strip (`Tab` to toggle),
just repurposed. The list groups items by id with a count (so five energy
charges are one row, not five), shows belt slots first (always visible,
even empty), then equipped weapons' ammo, then everything else. Enter on an
ammo row reloads that weapon directly, bypassing the in-combat reload
action entirely - nothing special happens on reload right now, so there's
no reason to make the player go through combat for it.

**Bulk** is the carry-weight system (Pathfinder-esque): every item has a
flat `bulk` cost except 0.1 ("Light", displayed as `L`). Capacity
(`getBulkCapacity`) is `10 * average limb strength + bulkBonus` (equipment
like a backpack would raise `bulkBonus`; nothing does yet).

**Belt**: a fixed number of slots (`beltSize`, currently 1) for combat-
usable items, separate from the main bag.

## Quests

`questEntries` - each has state-specific dialogue lines, an `isReady()`
check, a `rewardItemId`, and a `nextQuestId` (what the giver turns into
after turn-in; `nil` means they go quiet for good). Progress lives in
`player.quests` (`"active"`/`"done"`, not-yet-taken is just absent). One
quest exists so far: **Blunt the Blade**, offered by the Old Soldier in the
village, ready once the test dummy's been beaten at least once.

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
