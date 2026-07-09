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

Four corners while exploring: stats (top-left), a portrait placeholder
(top-right, nothing draws here yet), the walkable map (bottom-left, half the
width it used to be), and the activity log (bottom-right - see "Activity
log"). Combat, the inventory, and any blurb/dialogue interaction take over
the whole screen as their own modal window instead of sharing the four
corners.

Controls: arrow keys move, `Space` interacts with whatever's cardinally
adjacent (see "Environment objects & symbols"), `i` opens the inventory,
`q` quits immediately. Menus almost everywhere use digit keys `1`-`9`/`0`
then `a`-`z` for lists longer than ten items (see "Digit/letter menus"
below).

### Activity log

A full-screen modal (combat, the inventory) draws right over this corner,
so `render()` always redraws it from its own retained buffer
(`activityLog`, `drawLog`) afterward rather than just reasserting
visibility - toggling `setVisible(true)` alone is a no-op if it's already
`true`, so that alone wouldn't actually restore anything a modal drew over
it.

`logActivity(message)` wraps a line to the log's width (`wrapText` - also
what `writeWrapped` itself is built on now) and appends it to the buffer,
which only ever grows; `drawLog` draws whatever tail end of it currently
fits. This is specifically for things that happen **outside combat** -
combat already has its own full-screen messaging (`showCombatMessage`) and
doesn't need it. Right now that's: picking something up, a door opening or
closing, using an item outside a fight (the salve, so far - see "Inventory
& equipment"), changing region, and the moment a fight actually starts,
wins, or is fled from (not what happens *during* one - that's still all
`showCombatMessage`; these four are logged right as the encounter begins or
ends, so they're only visible once the full-screen fight itself is over).
`joinEnemyNames` turns `scene` into "the test dummy" for one foe, an
Oxford-comma list for more - nothing spawns more than one yet, but `scene`
is already a list (see "Victory").

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
  again), unlocking the torso's tail slot for a `stinger` (see "Natural
  weapons") and leaving the wing slots deliberately empty for now. The root
  part is relabeled "abdomen" instead of "torso" (`body.rootLabel`, read by
  `collectLabeledParts` - purely cosmetic, doesn't change how anything
  works structurally) and, same as `newTorso` always sets up, is MORTAL.
  The head (`insectoid_head`) has an antennae slot, filled with a plain
  `antenna` (does nothing on its own yet - body-part tuning is a later
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
  legs make you easier to hit.
- **Melee damage**: `stats.strength * getLimbStrength(attacker, the limb
  doing the hitting)`. Ranged weapons don't scale with strength at all.
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

Parts that can't be covered (horns, a stinger, antennae) inherit whatever
coverage their parent's zone provides, via the same `getPartZone` fallback
used everywhere else.

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

`strike` (baseline unarmed - see "Inventory & equipment"), `chain_sword`
(melee, slashing, applies 2 stacks of bleed on hit, grants Rev it up!),
`laser_pistol` (ranged, fire damage, 10-shot energy weapon, grants Charge
Shot), `stinger_sting` (melee, piercing, barely any damage but applies 5
stacks of poison - see "Natural weapons"). `handedness` decides whether a
normal attack with it is a quick or full action.

### Natural weapons

Most attacks come from a MANIPULATE limb (a hand) using whatever's
equipped there, or a bare Strike if nothing is. A **natural weapon** is the
other case: a part template with its own fixed `naturalWeapon` (a
`weaponEntries` id) that attacks with it unconditionally - a stinger's
sting, so far. `getAttackWeapon` picks between the two for any given part;
`pickAttack` lists both kinds of attacker side by side. A natural weapon
is never read from `equipped`, so unlike a held weapon it can't be swapped,
dropped, or disarmed - the only way to take it away is destroying the part
itself (see "Limb destruction & disarming", which every attacker - natural
weapon or not - is already subject to).

### Limb destruction & disarming

A destroyed limb takes everything attached to it (further from the root)
down with it: `isLimbFunctional` walks a part's whole ancestor chain, and
if *any* of them (including itself) is at 0 health, nothing there can
attack - `pickAttack` and weapon-granted abilities (`collectAbilities`)
both check it. A destroyed arm disables the hand hanging off it without
touching what's equipped there; a destroyed stinger just disables itself.

A destroyed **hand** specifically goes one step further: whatever it was
holding is knocked loose (`dropEquippedItem`, called from the enemy-attack
branch of `runEncounter` - not from an arm being destroyed, only a hand).
Dropped weapons are tracked per-encounter in `droppedItems`, not
`player.inventory` - a new **Pick Up** combat action (always a full action)
re-equips one straight to its original slot mid-fight (`pickDroppedItem`,
same picker/Back convention as everywhere else), which is the only
sensible option there's no time to open the full inventory screen -
still unusable, same as a bare-handed Strike from that hand would be, until
the hand itself heals. Anything left unclaimed when the encounter ends
instead lands in the bag via its own `itemId` (see "Inventory & equipment"
- weapons as items), letting the player re-equip it themselves once it's
actually useful again. `dropEquippedItem` takes a slot directly, so a
future disarm effect (an enemy skill, say - none exist yet) can reuse it
without knowing anything about *why* something got dropped.

### Ammo

Weapons with `ammoCapacity` need a matching ammo item to reload
(`ammoClass`/`getAmmoItemId`) - `bullet` for kinetic weapons, `energy_charge`
for energy weapons. Ammo is tracked per-**named-slot** on the combatant
(`character.ammo`) - an equip slot's own label, or a belt slot's synthetic
`"beltN"` one (see "Inventory & equipment") - never on the weapon template
itself, and never attached to the item sitting in the bag either, since
there's no mechanism to hang per-instance data off an item id at all.
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
  wherever you navigate to next and press `M` again. A weapon dropped on an
  equip slot goes there; a weapon *or* plain item dropped on a belt slot
  works the same way (a belt slot can hold a loaded weapon exactly like an
  equip slot can - see below). Either way, whatever was already there is
  displaced back to the bag (its ammo spilled loose first - see "Ammo" -
  then its own item, via its `itemId`, unless it has none, like Strike, in
  which case nothing is added back). Dropped anywhere else, it just lands
  in the general bag instead (ammo included) - always a valid resting
  place regardless of where it came from, which is also how unequipping
  works: pick it up, then press `M` again without needing a matching slot
  at all. Closing the inventory mid-carry safely undoes the pickup rather
  than losing whatever was picked up.

**Weapons as items**: a weapon can have an `itemId` (chain_sword,
laser_pistol so far) naming its carryable, bulk-having form in
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
`character.ammo` key `"belt" .. index`, see "Ammo"). A holstered weapon's
row shows its loaded count in place of the usual flat "1", and a new
**Swap** combat action (`pickSwapTarget`, always a full action) lets the
player draw one straight into a hand mid-fight - a true swap, not a drop:
whatever was in that hand (if anything) goes into the vacated belt slot,
ammo and all, rather than falling to the ground or needing the inventory
screen at all. With only one belt slot right now this is really just
"which hand", but `pickSwapTarget` lists every (limb, holstered weapon)
pairing generically, so a second belt slot would fall out for free.

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
