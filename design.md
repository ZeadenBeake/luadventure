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
log"). The inventory, Medical (see "Medical"), Apparel (see "Apparel"),
Character (see "Leveling & talents"), Quests (see "Quest log"), and any
blurb/dialogue interaction take over the whole screen as their own modal
window instead of sharing the four corners.

The stats pane (`engine.drawStats`) shows name, an "HP" line, level, an
"XP" line (`stats.xp` / `engine.xpForNextLevel(stats.level)`), and step
count. HP is health/maxHealth summed across the whole body
(`engine.getBodyHealthTotals`), not `stats.health`/`max_health` - those
are stat-block fields set once at creation and never updated (see "Stats
& combat"), so they'd read a frozen 100/100 all game regardless of
damage taken.

Combat gets its *own* four-corner layout rather than a single full-screen
window - map (top-left), the action menu (bottom-left), a combat-scoped log
(top-right - see "Activity log"), and the enemies in the scene (bottom-right
- see "Combat menu & movement"). The map pane is the real room the fight
started in, not a separate arena - it shares `drawRoomView` (see "Camera")
with the overworld's own map, camera and line-of-sight masking included.
Combat's own sub-pickers (choosing an attack, a limb, an ability, a
reload/belt target) and the two moments that still genuinely warrant
stopping the player in their tracks (victory, death) fall back to the same
full-screen window the inventory and dialogue use.

Controls: arrow keys move, `Space` interacts with whatever's cardinally
adjacent (see "Environment objects & symbols"), `i` opens the inventory,
`m` opens Medical (see "Medical"), `a` opens Apparel (see "Apparel"), `c`
opens Character (see "Leveling & talents"), `j` opens Quests (see "Quest
log"), `f` opens Factions (see "Factions screen" - its own `Left`/`Right`/
`Up`/`Down` bindings only apply once it's open, so this doesn't collide
with movement), `q` quits immediately. `Tab` opens a slim top-bar strip
that jumps straight to any of the six (`Left`/`Right` to choose, `Enter`
to open) without needing its own dedicated key - all six exist mainly for
that shortcut's own sake. Six page names don't all fit on a real 51-wide
computer screen at once, so `engine.drawTopBar` scrolls the strip
horizontally to keep whichever page is currently selected centered,
clamped so it never scrolls past either end - the same "compute a
centered window into a longer string, then clamp" idea, just horizontal
here rather than a vertical list scroll. Menus almost everywhere use digit
keys `1`-`9`/
`0` then `a`-`z` for lists longer than ten items (see "Digit/letter menus"
below).

Every full-screen page's own bottom-row control hint (`[Enter] take  [S]
spend skill point  [C] close`, and its siblings on every other page) is
colored yellow, `colors.white` everywhere else - purely a readability
fix: a hint line that sits flush against a pane's own edge (no margin to
spare on an already-tight screen) can otherwise read as if it's part of
whatever text happens to be immediately next to it, especially on the
Factions screen (see "Factions screen"), where two independent real
windows sit directly edge-to-edge with no gap between them at all. A
distinct color makes a hint unambiguously its own thing regardless of
what's touching it.

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

`activityLog` (not `combatActivityLog` - a fight's own scrollback is
scoped to that one encounter and reset the next, nothing worth
remembering past it) is part of save data (see "Save & load") - restored
as the same already-wrapped lines it held at save time, not replayed
from some underlying event history (there isn't one), so a loaded game's
scrollback picks up exactly where it left off rather than starting
blank.

`logActivity` is for things that happen **outside combat**: picking
something up, a door opening or closing, using an item outside a fight
(the salve, the splint - see "Inventory & equipment"/"Medical"), changing
region, and the moment a fight actually starts, wins, or is fled from
(not what happens *during* one - that's `logCombat`, in its own pane,
visible for the whole fight rather than only once it's over). `logCombat`
is for everything routine that happens mid-fight - a swing landing or
missing, a status tick, an enemy closing in - so only the small handful
of moments that actually warrant the player's full attention
(`showCombatMessage` - victory, death) still interrupt. `joinEnemyNames`
turns `scene` into "the test dummy" for one foe, an Oxford-comma list for
more - a real group, not just a one-at-a-time convention (see "Victory"
and "Sight-triggered combat").

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
fine through CraftOS-PC's ncurses CLI renderer). `combatState.flash` restores
to yellow rather than white afterward if the cell it just painted belongs to
the currently-selected enemy (see "Enemy selection" below) - it can flash a
foe that isn't the one selected (a grenade's blast, say) or the player's own
`@`, so it checks by comparing the flashed coordinates against
`combatState.scene[combatState.selectedIndex]`'s own `gridX`/`gridY` rather
than assuming. Both share `engine.paintFieldCell(x, y, glyph, color)` - the
same camera-translated, off-screen-safe single-cell repaint, extracted so
the selection highlight and the flash always agree on what "on-screen"
means. Since a fullscreen
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

- **Region graph** (`world`) - a handful of named places (`village`,
  `grasslands` right now) connected by `directions` (up/down/left/right).
  This is the coarse map.
- **Walkable grid** - each location also has its own grid (`width`/
  `height` - both existing rooms are 40x30, big enough for exploration and
  the camera below to mean something) you move around one cell at a time.
  Walking off the edge of a grid in a direction that has a matching
  region-graph connection moves you to the connected location, entering
  from the opposite edge (walk off the right edge, arrive on the left edge
  of wherever's next).

### Camera

`drawRoomView` (shared by the overworld's `drawMain` and combat's
`drawCombatField`) draws a scrolling, player-centered viewport rather than
the whole grid at once - `getCameraOrigin` clamps independently per axis so
it never scrolls past a room's edge, and collapses to no scrolling at all
whenever the room is smaller than the viewport in that dimension. Cells
outside the room's own bounds (the camera showing past a small room's edge)
render as `~`. `extraCells` is how a caller overlays things that aren't
part of the room itself - the player's own `@` always, combat's enemies
too (see "Combat menu & movement"). `drawRoomView` returns the camera
origin it used so a caller that needs to translate grid coordinates back
into screen ones later can (`combatState.flash`, which stashes it via
`combatState.cameraX/cameraY`, set each time `drawCombatField` runs).

### Line of sight & room zones

A room seals itself off visually the same simple rule decides everything
else by: walls and doors (open or closed) are opaque, glass and open floor
aren't. Rather than flood-filling the room fresh every render (most tiles
never move - only a door's own open/closed state ever changes what's
reachable), this is precomputed once as a static **zone graph**
(`computeRoomZones`, run once per location at startup and again after a
load, since a load replaces every location's objects wholesale - see
"Save & load"): a wall or a door (regardless of state) is a zone boundary,
glass and floor are freely connected. Two areas joined only by glass
permanently merge into one zone (matches "vision is one room if a wall has
glass in it" exactly); a door always separates two zones, but its own
open/closed state gates them at runtime instead (`doorZones[door] = {a=,
b=}`, the zone on each side). Wall/door tiles themselves have no zone at
all - they're the boundary, always rendered regardless of visibility,
same as you can always see a door whether or not you can see through it.

The **currently visible set** (`loc.visibleZones`) starts from whichever
zone the player is standing in and spreads through any *open* door to
whatever's on the other side (`recomputeVisibleZones` - a small
fixed-point loop over the room's doors, not its tiles). Standing exactly
on an open door tile (the one walkable tile with no zone of its own) seeds
both zones it borders instead, since being in the doorway means seeing
both ways at once. This only ever gets recomputed on the two things that
can actually change it - a door toggling (`toggleDoor`) or the player's
own tile landing in a different zone than before (`refreshPlayerZone`,
cheaply no-op'ing via `loc.playerZone` when it hasn't) - never per render.
`drawRoomView` masks anything outside the visible set to a blank space,
distinct from the `~` out-of-room-bounds margin - "something's here, you
can't see it" as opposed to "there's nothing here at all".

### Environment objects & symbols

Each location has an `objects` list. `findObjectAt` resolves collisions,
`getObjectGlyph` decides what a given object currently looks like:

| Glyph | Kind | Notes |
|---|---|---|
| `#` | wall | Solid rectangle (`x1,y1,x2,y2`), blocks movement, no interaction, always a zone boundary |
| `*` | item | Auto-collected the moment you step onto it (`collectItem`) - logged, no prompt |
| `-` / `\|` | door | Horizontal/vertical; see below - opens/closes without a prompt either, always a zone boundary regardless of state |
| `:` | window | Blocks movement like a wall, but never a zone boundary - glass merges whatever's on either side into one visible zone permanently |
| `!` | person (quest) | A quest step this NPC (`npcId`) owns is offerable or ready to turn in - see "Quests" |
| `?` | person (quest) | A quest step this NPC owns is in progress, not yet ready to turn in |
| `0` | person | Flavor-only NPC, or nothing actionable from this NPC right now |
| `E` | enemy | Fight starts the moment it's aware of you (see "Sight-triggered combat") - walking into it directly still works too. `enemyType` (defaulting to the test dummy) says which NPC type actually spawns - see "NPCs" |
| `$` | save point | Save / Load / Quit Game (see "Save & load") |

Two different ways to trigger a reaction from something on the map:

- **Bumping into it** (walking into a cell that isn't clear) - `tryMove`
  (via the shared `resolveStep` - see below) handles an item or a closed
  door itself, without a prompt; anything else still blocking (a person, a
  save point, an enemy, a wall, a window) goes through `interactWithObject`,
  which dispatches on `obj.kind` and returns `(playerDied, quitRequested)` -
  both bubble all the way up to the main loop, since either one ends the
  program.
- **`Space`** (`tryInteract`, via the shared `resolveInteract(loc, x, y,
  blockedKinds)`) - checks each of the four cardinal-adjacent tiles (never
  diagonals, so two interactables sitting right next to each other don't
  create ambiguity) and acts on the first one found. This is the only way
  to *close* a door again - bumping one only ever opens it - but works
  generically on anything adjacent, routing to the same
  `interactWithObject` for a person/save point/enemy. Combat has its own
  Interact action (see "Combat menu & movement") built on this same
  function, `blockedKinds` set to keep a save point (and, later, anything
  else added to `COMBAT_BLOCKED_INTERACT_KINDS`) out of reach mid-fight -
  the overworld's own call passes `nil`, so nothing's off-limits out here.

Items and doors got simplified on the theory that there's no harm in just
doing the thing: standing on an item just picks it up (`collectItem` -
inserts it, removes the map object, logs it - see "Activity log"); bumping
a closed door just opens it (`toggleDoor`), logged the same way, but that's
the whole action for that move - stepping through still takes a second one,
same as bumping into anything else that was blocking the way. Both are
handled by `resolveStep(loc, nx, ny)` - a shared step-resolution helper
returning `"moved"`, `"door_opened"`, or `"blocked"` - rather than each
caller reaching `interactWithObject` directly for them. `tryMove` (the
overworld) and combat's own move action (see "Combat menu & movement") both
call it, so a fight plays out with the same collision, item pickup, and
door-opening rules exploration has, just without the overworld's
edge-of-room region transition (leaving the room entirely is simply
blocked mid-fight - Flee is its own explicit action). A person, a save
point, and a fight still go through a real prompt via `interactWithObject`
- those have actual stakes or a meaningful back-and-forth, so simplifying
them away wouldn't make sense.

### Sight-triggered combat

A fight starts the instant a hostile becomes *aware* of the player - no
bump required - using the same rule the zone/visibility system above
already tracks: `findAwareEnemies` (called from `checkAwareness`, itself
called after every player action that could reveal something or close
distance - a step, a door toggling either way, combat's own move action)
collects *every* `enemy` object whose own zone is in `loc.visibleZones`
and within `SIGHT_DISTANCE` (15 tiles, a flat cap independent of however
far a zone/glass chain might otherwise let you see - checked against real
weapon ranges so a big sealed room can't start a fight with something too
far away to reasonably close distance on) of the player - not just the
first one found, so two enemies aware of the player at the same time join
as a single fight rather than only ever whichever one the game happens to
notice first.

That direct set is then expanded by `propagateAwareness`: anyone else
within `SIGHT_DISTANCE` of an *already-aware* enemy joins too, repeating
until a full pass adds nothing new - a distant enemy that couldn't itself
see or reach the player yet still joins once whoever's between them
noticed first, one hop at a time (a friend noticing a friend's fight
starting). This is breadth-first over however many enemies a location
actually has, not over tiles or distance, so it stays cheap regardless of
room size - trivial at the handful of enemies any real room has today,
and still just `O(n^2)` worst case for a much larger `n`. The direct-bump
path (`interactWithObject`'s `enemy` branch) runs the exact same
propagation, seeded with just the bumped object (which always joins,
bypassing the usual sight/zone check outright, since walking onto its
tile makes awareness a foregone conclusion) - a group can start a fight
either by being seen or by having one of their own bumped into.

Fights happen on the real map now, not a separate arena - `runEncounter`
takes a list of triggering objects (not just one) and spawns one live
combatant per object into `scene`, tagging each with `enemy.spawnObject`
to keep the two linked. Every triggering object is pulled off `loc.objects`
for the fight's duration (so none of them also sit there as a stale marker
while their own live combatant is walking around the battlefield), and put
back (wherever it actually ended up) for anyone who survives if the player
flees; gone for good on a win. This is safe against a save happening
mid-fight - the overworld's own main loop that reaches the save prompt is
fully suspended for the whole encounter's duration, and combat's own
Interact action (see "Combat menu & movement") deliberately keeps a save
point out of reach too (`COMBAT_BLOCKED_INTERACT_KINDS`) even though it
reaches the same `interactWithObject` dispatch a save point would
otherwise go through - without that, a save point standing right next to a
fight would have reopened exactly the case this was meant to rule out.

Every living member of `scene` gets its own `decide()`-driven turn each
round (Tab already cycles Fight/Look/an ability's targeting across all of
them - see "Combat menu & movement"), not just a single hardcoded enemy -
a dead one just sits out the rest of the fight, same as
`engine.sceneCleared` already expects. Surrendering (see "Surrender")
removes only that one combatant from `scene` rather than ending the whole
encounter outright, so anyone else in the fight keeps going; only ending
up with nobody left in `scene` at all (everyone spared or already
surrendered, nobody actually dying) counts as the fight itself being over
that way - dying still ends things the usual route, `engine.sceneCleared`
at the top of the loop.

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

- **Health/max health** - damaged independently, not a global HP pool.
  Death (`isDead`) is either any MORTAL-tagged part (torso, head - see
  "Tags" below) reaching 0, *or* cumulative health across every part
  combined dropping to `ATTRITION_DEATH_HEALTH` (25%, i.e. 75% taken -
  see `getBodyHealthFraction`) - a fighter covered in serious
  wounds doesn't need one of them to be individually fatal to actually
  die. A template's `aimDifficulty` (default 1, most omit it) divides its
  starting health at creation - see "Stats & combat" for the other half
  of what it does.
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

## Backgrounds

`backgroundEntries` - who the player was before the game started. Each
entry has a `name`, an in-world `description` blurb, and `statAdjustments`
(the exact same flat, one-time-delta shape as `speciesEntries`' own field
below - stacking on top of whatever species already adjusted, applied once
in `engine.runCharacterCreation`). Picked first in character creation,
right after name/pronouns, via a dedicated `engine.pickBackground()`
picker (`Up`/`Down` to browse, `Enter` to confirm) rather than
`showInteraction`'s flat numbered list, so the currently-highlighted
background's own description previews live before committing - the same
reason the Factions screen needed real scrolling instead of a static blurb.
The chosen id is stored on `player.background` (a plain string, `nil` until
creation runs, same defaulting convention as `player.name`/`pronouns`), and
persisted through save/load exactly like `specialFaction` (a single scalar
value, `data.background or nil` on load for backward compatibility with a
pre-Backgrounds save).

An optional `reputationBonus` (a single `{ factionId, amount }` pair, absent
on backgrounds that don't have one) is applied the same moment, via
`engine.adjustReputation(factionId, amount)` - uncapped, since it's meant to
land exactly on the number the background's own backstory implies, not
simulate a repeatable in-game gain. This is also what actually makes a
faction "known" (see "Factions & reputation") straight out of character
creation, before the player has done anything in play yet.

Five backgrounds exist so far:

- **Lab Volunteer** - a Signus Biomedical employee who volunteered for the
  splicing program (the game's own opening - waking up from a test tube,
  not quite human - is this background's backstory). No stat bonus;
  `reputationBonus = { signus, +30 }`, landing at Liked (Signus has the
  paperwork proving it was voluntary, even if the result is unrecognizable).
- **Ex-Peacekeeper** - a former UGFC Peacekeeper who saw too much and was
  abducted. `statAdjustments = { aim = 0.10 }` (what's left of the
  training); no `reputationBonus` at all - UGFC doesn't recognize them
  anymore. The relationship is meant to matter later even so (easier to
  rebuild than starting cold), which is exactly why `player.background`
  itself is kept around rather than just being spent on a stat bonus and
  discarded - future dialogue/quest content can check it directly.
- **Incarcerated Separatist** - a death-row Kaeravoli Separatist, sprung
  and spared through illegal back channels. `statAdjustments = { strength =
  0.10 }`; `reputationBonus = { kaeravoli, +20 }` (Neutral band - proving
  who they once were is what's meant to make climbing back to Sympathizer
  or further easy, not a free head start into it).
- **Gravely Wounded Trader** - a wealthy MITG tradesman, gravely wounded by
  pirates, who took the splicing program as his only way to recover. No
  stat bonus - his real starting edge is social, and social stats don't
  exist yet, so `statAdjustments` is deliberately left empty rather than
  standing in with something unrelated; `reputationBonus = { mitg, +30 }`
  (Liked - paperwork of who he was, done willingly, buys real standing with
  the Guild).
- **Sacrificed Wayfarer** - a member of the Wayfarer pirate gangs, handed to
  Signus Biomedical as punishment for breaking the pirate code.
  `statAdjustments = { reflex = 0.10 }`; `reputationBonus = { wayfarers,
  -25 }` (the exact bottom edge of Neutral - the gang making an example of
  them).

Every background's `description` (the in-world flavor text shown in the
picker) is still blank - narrative content, not mechanical wiring, and
still future work. Nothing about the picker, `runCharacterCreation`, or
save/load needs to change once it's written, the same "proof of structure
first, content later" shape the talent tree and quest step system were
both introduced with.

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
`level`, plus a few fields (`dr`, `defense`, `speed`, `weight`,
`max_inventory`) that are declared but not wired into anything yet.
`stats.health`/`max_health` are set once at creation and never read
again - the corner HP readout (see "Screen layout") instead sums raw
health/maxHealth across the whole body (`engine.getBodyHealthTotals`,
shared with `getBodyHealthFraction` - see "Body system"), since that's
what the game's actual health tracking is.
plus `level`/`health`/`max_health`.

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
(`upper_body`, `left_hand`, `head`, ...), and flat per-damage-type
`coverage`. Areas roll up into **zones** (`COVERAGE_AREAS`/`AREA_TO_ZONE`)
that match a body part's own `zone` field. Two items on the same layer
can't claim overlapping areas (`canWearItem`, called live from Inventory's
`Enter` - see "Inventory & equipment" - and bypassed outright by the debug
console's `wear`/`unwear`).

A part that comes in a left/right pair (arm, hand, leg, foot) has its own
sided zone (`left_arm`/`right_arm`, `left_hand`/`right_hand`, ...) and
sided areas to match - `left_hand`/`right_hand` are genuinely separate
areas, not one `hand` area shared by both. head/torso/tail stay unsided
(one of each per body, nothing to side). A part's own `zone` field
(`partEntries`) is only ever the unsided base name (`hand`, not
`left_hand`) - the same template is reused for both sides, so it can't bake
a side into itself. The actual side gets stitched on once, at attach time
(`engine.sidedZone`, called from both `engine.attachPart` and
`engine.deserializeBodyPart` - a loaded save re-derives it fresh from the
slot tree rather than trusting a stored value, same reasoning as everything
else `engine.serializeBodyPart` leaves out): a slot itself sided
(`left_arm`/`right_arm`, attached straight onto the torso) carries it
directly, while a slot that isn't (`hand`, attached under an arm; `foot`,
under a leg) inherits whichever side its own parent's zone already has.
An item meaning to protect a symmetric pair either way (a jacket's sleeves,
`ballistic_underlayer_top`) lists both sides' areas explicitly rather than
one generic area standing in for both; a genuinely one-sided item (a single
glove, `left_glove`/`right_glove`) is its own separate item entry per side
instead - real one-sided coverage can't be expressed any other way, and
trying to teach one item entry "which side you put it on" would need a
whole extra picker for something two item entries already say for free.

A MULTI_LIMBED body's second arm pair (`left_arm_2`/`right_arm_2` - see
"Body system") carries its own numbered suffix through `engine.sidedZone`
too, all the way down to that pair's own hand (`left_hand_2`) - without
it, both pairs would collapse onto the exact same `left_arm` zone and a
single sleeve would protect two unrelated arms at once.
`engine.partLabel` (the same side-qualifying logic, but for a part's
*display* label rather than its coverage zone - see "Body system") needed
the identical suffix-carrying fix, for the same reason: without it, both
pairs' hands would render as an indistinguishable "left_hand" in the
Apparel/Medical part list, and the debug console's own `findPart`
(label-based) could never reach the second one at all. A zone
`COVERAGE_AREAS` doesn't declare - a second arm pair, before any real
content adds coverage for one - reads as plainly uncovered
(`getCoverage`/`getPartCoveringItems` both guard for this explicitly),
not a crash.

Damage reduction only cares about the zone as a whole, not which exact area
got hit - and critically, it's the **average** coverage across every area in
that zone (`getCoverage`/`getAreaCoverage`), not the full value of whichever
item happens to cover any one area of it. A vest that only covers
`upper_body` doesn't fully protect the torso; it raises the average while
the uncovered `lower_body`/`pelvis` drag it back down. The `belt` area is
excluded from this average entirely - reserved for future belt-slot-
expanding items, unrelated to armor. Both `getCoverage`/`getAreaCoverage`
take an optional trailing `layer` ("inner"/"outer") to scope the same
average to just one layer instead of both stacked together - the real
damage-reduction math (`damagePart`) never passes one at all, since actual
protection always stacks both layers; the Apparel screen (below) is what
actually uses it, to show what each layer is contributing on its own.

Parts that can't be covered (horns, antennae, a stinger) inherit whatever
coverage their parent's zone provides, via the same `getPartZone` fallback
used everywhere else. The insectoid's abdomen isn't one of these - it has a
real zone of its own (`tail`), same as any other limb.

### Status effects

Applied to a single part (`applyPartStatus`, an injury) or the whole
character (`applyCharacterStatus`, a condition). `duration` ticks down by
one every full round (`decrementStatuses`); `-1` is permanent, needing
explicit removal instead (`clearPartStatus` - a plain, no-questions-asked
delete regardless of remaining duration; the Medical screen's own Splint
is the first thing that actually calls it, curing a fracture - see
"Medical"). Applying the same status again combines with whatever's
already active (`combineDuration`): a stacking status (`stacks = true`,
like bleed) adds the two durations together, a non-stacking one just
takes the higher. `damagePerStack` deals a hit of that damage type equal
to the current duration, once per round, right before it decrements -
that's the entirety of how bleed works, there's no separate
damage-over-time system. `name` is display-only, for the Medical screen's
own status listing - nothing else ever shows one by anything but its raw
id.

Currently defined: `fracture` (permanent, halves limb strength - nothing
inflicts one yet outside the debug console, so the Splint curing it is
presently only exercised that way too), `adrenaline` (character-wide,
ignores condition penalties for its duration), `bleed` (stacking, untyped
damage-per-stack), `poison` (stacking, toxic damage-per-stack -
mechanically identical to bleed, just its own damage type and its own
tick message, via `DOT_VERBS`).

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
**Use Dermoregenesis Salve** (quick, `treats = "health"`, heals 25 to a
chosen part, consumed from the belt), **Use Splint** (quick, `treats =
"fracture"`, cures a fracture outright rather than dealing with health at
all - see "Status effects"), **Charge Shot** (laser pistol only, always a
full action even one-handed, no cooldown, double damage for 3 ammo
instead of 1), **Spray** (rifle only, full action, cooldown 3, three
separate shots at one target - each its own hit roll at a flat accuracy
penalty, unlike Rev it up!'s single roll covering every sub-hit - burning
3 ammo regardless of how many land; always resolves at full cooldown once
it starts firing, since there's no single roll to gate a refund on the
way Charge Shot and Rev it up! each have). `treats` is only ever set on
these two self-targeting ones - see "Medical" for what actually reads it.

### Victory

`runEncounter` checks the scene for survivors at the very start of every
player turn (`sceneCleared`), rather than every attack path individually
guessing whether its own hit was the killing blow. Once everyone in the
scene is down, `showVictoryScreen` logs each kill by `typeId` onto
`player.killLog` (a count table) and shows a summary - `killLog` is what
quests read (`(player.killLog.test_dummy or 0) > 0`), so a search-and-
destroy quest for, say, three bandits is just `>= 3` against that same
table, no bespoke flag per encounter needed. `scene` really can hold more
than one foe now (see "Sight-triggered combat" for how a group ends up in
it together) - a mixed outcome (one foe dies, another surrenders, see
"Surrender") logs correctly onto both `killLog`/`spareLog` and still ends
in this same victory screen once the last living member of `scene`
actually dies, rather than needing its own separate ending.

### Surrender

Not every foe fights to the death - `{action="surrender"}` is a fourth
`decide()` outcome (alongside attack/move/idle) that ends the encounter
outright, checked via `engine.checkSurrender(state, healthThreshold)`:
true once cumulative health across `state.self`'s WHOLE body (every part
combined, not just the torso - `engine.getBodyHealthFraction`, same
attrition reasoning `ATTRITION_DEATH_HEALTH` uses for death, see "Body
system") drops to or below `healthThreshold` (a fraction of total
health), *or* it's effectively disarmed (`engine.isDisarmed` - every
equipped weapon dropped or destroyed, every natural weapon too; a
functional hand alone doesn't count, since a bare-fisted Strike is always
available and isn't "armed" for this purpose). Both the raider and the
bandit use `0.5` - badly hurt overall (not necessarily near dead from a
single wound) is already enough to give up, matching the same "a body
riddled with damage eventually gives out" reasoning `ATTRITION_DEATH_HEALTH`
(0.25, i.e. death) uses for the more severe end of the same scale.
Nothing requires an NPC type to use this at all - the test dummy doesn't,
since it's a mindless sparring target with nothing really at stake.

Once triggered, `runEncounter`'s own "surrender" branch stops the player
with a real choice (`showInteraction`, same Yes/No-style prompt the
overworld already uses) - not the normal victory screen, and (now that a
fight can hold more than one foe - see "Sight-triggered combat") not the
end of the whole encounter either, unless this happens to be the last one
left standing in `scene`:

- **Accept surrender** - logged onto `player.spareLog` (a count table
  shaped exactly like `killLog`, keyed the same way by `typeId`) instead
  of `killLog` - a quest that specifically wants a bloodless outcome
  checks this one instead. No loot.
- **Finish them off** - resolves like a kill (`killLog` increments, same
  as an ordinary victory) and drops everything in the foe's own `loot`
  (a list of item ids on the enemy instance) into the player's
  inventory.

Either way, this one combatant is removed from `scene` outright rather
than just marked dead - its own `spawnObject` stays off the map for good
(see "Sight-triggered combat") rather than getting re-inserted the way a
flee does, since neither outcome leaves anything to re-engage later. If
anyone else in `scene` is still alive, the fight just continues against
them with no further ceremony; only once `scene` ends up completely empty
this way (everyone spared or already surrendered, nobody actually dying)
does the encounter end on its own - same "back to the tile you started
on" reset a normal win gives, since sceneCleared/showVictoryScreen only
ever fire from someone actually dying, not from this.

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
quickened and reflex isn't fast enough), just without a separate
confirmation step in between. Stepping onto the real map now goes through
the same `resolveStep` the overworld uses (see "Environment objects &
symbols") - a wall silently blocks for free (re-prompts, no turn spent), an
item gets picked up, and a closed door swings open, spending the move the
same way an ordinary step does (the *next* step actually goes through it).
A hint line ("Arrow keys to move (quick)" or "(full)", read off
`getEffectiveReflex`) sits under the numbered options so this isn't a
hidden control. A successful step calls `combatState.redrawPanes()`
immediately, before whatever comes next (ending the round, the enemy's own
paced turn) - the step itself should read as instant, not wait behind the
round it might trigger.

Same idea for `Space` - not a menu entry either, a dedicated key
(`promptAction`'s key loop returns `"interact"` straight away, same as
`Tab` cycling the enemy selection does) with its own hint line under the
move one. It's a flat quick action regardless of reflex (unlike Move),
and shares `resolveInteract` with the overworld's own interact key (see
"Environment objects & symbols") - a closed door, or later an
environmental object like a button or lever, works exactly the same way
mid-fight it does outside one, `blockedKinds` set to
`COMBAT_BLOCKED_INTERACT_KINDS` - a save point stays unreachable while an
encounter's running (see "Save & load" for why that specifically can't be
allowed), and a person too, since stopping for dialogue mid-fight doesn't
make sense even though nothing about it would actually break. Finding
nothing adjacent, or finding something blocked, both stay free to
re-prompt - only actually reaching something spends the
turn.

**Enemy selection**: the bottom-right pane (`drawEnemyList`) lists every foe
in `scene`, health included (`foe.body.health/maxHealth` - the torso's own
two fields specifically, same as it's always shown; death/surrender's own
cumulative-across-every-part math, see "Body system"/"Surrender", is a
separate figure this list was never updated to reflect), with whichever
one's currently selected marked - `Tab` cycles it, handled right inside
`promptAction`'s own key loop
(doesn't cost a turn or count as an action). The selected foe's own map
glyph is highlighted yellow too (`engine.drawCombatField`'s `selectedIndex`
parameter, painted via `engine.paintFieldCell` right after `drawRoomView`
draws the plain map) - so the enemy list's own marker isn't the only place
the selection shows. `Tab` doesn't trigger a full `drawCombatField` redraw
for this, though; it repaints just the two affected cells directly (the
old selection back to white, the new one to yellow), the same
targeted-single-cell approach `combatState.flash` already uses, since
nothing else about the map needs to change for a selection change alone.
**Fight** and **Look**, and
whatever enemy an ability's own effect targets, all act on this selection
rather than a hardcoded single opponent - `runEncounter` reads it back out
as `foe` (`scene[selectedEnemyIndex]`) once `promptAction` returns. A group
fight (see "Sight-triggered combat") is exactly where this actually matters
- `selectedEnemyIndex` gets clamped back down if a Tab-selected foe
surrenders out of `scene` mid-round, same as it would if the last entry in
a shrinking list disappeared out from under it.

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
different to wield), `shotgun` (ranged, piercing, 6-shot, 8 pellets per
blast at a punishing spread - see "Imprecise weapons" - grants Special
Shot, which doesn't come from the shotgun itself so much as from whatever
special shells happen to be in the bag - see "Ammo"). `handedness`
(`"one-handed"` or `"two-handed"`) decides whether a normal attack with it
is a quick or full action - and, for `"two-handed"`, quite a bit more
besides.

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

### Imprecise weapons

A weapon flagged `imprecise` (the shotgun, so far) skips limb-targeting
entirely - `pickAttack`'s Fight branch never calls `pickLimb` for one at
all. Instead: one roll decides whether the whole spread connects, at the
same generic (no target part chosen, `aimDifficulty` 1) chance every
weapon's own preview line already shows; a hit then rolls `pellets`
separate part hits, each via `pickWeightedPart` (a `collectLabeledParts`
list, weighted by the inverse of each part's own `aimDifficulty` - a part
that's already harder to aim for on purpose is also less likely to catch a
stray pellet by chance). `damage` on an imprecise weapon is read
per-pellet, not per-shot, so the real payout per trigger pull is `pellets`
times that range - a lot more than a single precise shot, offset by the
whole volley being one all-or-nothing roll (no partial credit for some
pellets connecting and others missing) rather than a per-pellet miss
chance, plus a short `range` and heavy `spread` that make that range mostly
theoretical in practice. Ammo still burns once per trigger pull
(`ammoPerShot`), same as any other weapon.

### Grenades

A grenade (`itemEntries.grenade`) is a belt item like the Dermoregenesis
Salve, not a weapon - Throw Grenade is granted and consumed exactly the
same way, via `collectAbilities`/the ability action's own item-consumption
branch, whether or not it ever actually goes off. Its own `effect` doesn't
target the currently-selected enemy at all: `pickThrowTarget(range)` opens
a dedicated aiming picker - arrow keys walk a reticle (`O`) around the
*real* map pane instead of a limb list, clamped to `range` tiles
(`gridDistance`) of the thrower and the room's own bounds, defaulting to
the selected enemy's tile if that's in range - Enter confirms, Backspace
cancels. Confirming doesn't deal any damage on the spot; it just registers
where the grenade's going to land (`queuePendingGrenade`, on
`combatState.pendingGrenade`) and logs that it's away.

**The delay is the whole point**: a thrown grenade doesn't detonate until
a full enemy turn has actually passed, not the instant it's thrown - a
`pendingGrenade` only arms (right after the enemy's own turn resolves, at
the bottom of the round-ending block) once the round it was thrown in
has actually ended, and only detonates (`resolvePendingGrenade`) at the
very top of the *next* pass through `runEncounter`'s own loop, before even
the scene-cleared check. Whatever's still standing within `radius` tiles
of where it landed when that moment comes - the player included, since a
grenade doesn't know whose hand it left - takes one damage roll against a
weighted-random part (`pickWeightedPart`, same logic the shotgun's pellets
use). A blast can't be dodged outright the way an aimed attack can, but
`getBlastDamageMultiplier` still lets good reflex soften it, capped
(`GRENADE_MAX_DAMAGE_REDUCTION`) so it's never a full dodge in disguise.
Only one grenade can be in the air at a time - `pendingGrenade` is a
single slot, not a queue, so Throw Grenade's own effect refuses (and
doesn't consume anything) rather than silently overwriting an already-
pending one and wasting it for nothing. A fight ending (win, death,
flee) before a pending grenade goes off just discards it - reset at the
top of every `runEncounter` call rather than resolved retroactively.

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
for energy weapons, `shotgun_shell` for the shotgun's own `"shotgun"` class
(different enough from either to warrant its own, though it reloads
exactly the same way). Ammo is tracked per-**named-slot** on the combatant
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

**Special ammo**: some items (the shotgun's `slug_round`) never enter a
weapon's ordinary loaded pool at all - no `ammoClass`, so
`reloadWeapon`/`getAmmoItemId` don't recognize them, and `Reload` never
lists them. Instead an item's `specialAmmoFor` names which weapon id can
fire it, and a weapon-granted ability (`special_shot`, on the shotgun)
reads that off inventory directly: `pickSpecialAmmo(combatant, weaponId,
prompt)` lists every distinct matching item id still carried (with a
count), the ability's own `effect` removes exactly one on firing
(`removeInventoryItems`), same "burns whether it hits or not" rule ordinary
ammo follows. This is a one-off pull from the bag, not a restock of
anything - there's no cooldown to gate it either, the way there is for
Rev it up!/Charge Shot/Spray; the real cost is just having stocked one in
the first place. A special round can also declare its own `damage` (read
by the ability, not the weapon's own per-pellet one) and `ignoresEndurance`
- passed straight through to `damagePart`'s own optional argument, skipping
a target's flat endurance reduction (but not its resistance or worn
coverage) entirely, for something billed as armor-piercing enough to earn
that.

## Leveling & talents

XP is banked on `stats.xp`, alongside the pre-existing `stats.level`
(`character.stats`'s default table, `character:new`) - both ride along for
free through save/load, since `buildSaveData`/`applySaveData` already copy
the whole `stats` table wholesale via `pairs()`.

**The curve**: `XP_CURVE = { base = 100, step = 100 }`,
`engine.xpForNextLevel(level)` returns `(level + 1) * XP_CURVE.step` - level
0→1 costs 100, 1→2 costs 200, 2→3 costs 300, and so on. A small, clearly
tunable local, same convention as `STAT_ALLOCATION`/
`ATTRITION_DEATH_HEALTH`/`REFLEX_QUICK_THRESHOLD`.

**`engine.grantExperience(combatant, amount)`** adds `amount` to
`stats.xp`, then loops while it clears `xpForNextLevel(stats.level)`
(subtracting the threshold, incrementing `level`), so one big grant (a
quest reward, say) can chain multiple level-ups in a single call. Only the
player has a skill/talent point economy or a display for either - a
non-player combatant's xp/level still tracks harmlessly on its own stats
table if ever granted any, but nothing surfaces it. Each level gained
awards the player one skill point and one talent point (`player.
skillPoints`/`player.talentPoints`), and the final reached level (not one
line per level, if several were gained at once) gets logged via
`engine.logActivity`. Bridged as `Luadventure.grantExperience`, so a
future dialogue-choice effect (the "cleverly avoided a fight" case) can
call it exactly like `Luadventure.logCombat` - no such branching dialogue
exists yet to wire it up to (see "Known gaps"), but the primitive itself
needs no dialogue-system changes to become usable the moment one does.

**Sources implemented so far**: a quest step's own `xpReward` field,
granted on that step's completion (`engine.completeQuestStep`, see
"Quests") alongside its `rewardItemId`; an enemy type's own `xpReward`
field on `enemyEntries`
(test_dummy 10, raider 20, bandit 25 - the dummy cheapest since it can't
fight back), granted per foe in `engine.showVictoryScreen`'s own kill-log
loop once the whole scene clears.

**Skill points**: `engine.spendSkillPoint()` is a single-point pick -
`[1] Strength (+5%) [2] Reflex [3] Aim [4] Back` - applying
`STAT_ALLOCATION.step` once (same non-compounding rule character
creation's own five-point `runStatAllocation` uses, same constant reused
directly, no new one needed). Spent from the Character screen (below), any
time, not forced the instant a level-up happens.

**Talents** are a real prerequisite-gated tree (`talentEntries`,
gamedata.lua), rooted at `root` - display-only, does nothing itself, and
is granted free to every combatant at construction (`character:new`'s
`o.talents = { root = true }`) so a root-child's own prerequisite check
never needs a special case for the root. `engine.hasTalent(combatant,
talentId)` reads `combatant.talents[id] == true`; `engine.canTakeTalent`
additionally checks the talent's own `parent` has been taken;
`engine.takeTalent` marks it taken and applies a `statBonus` once if the
talent declares one (same flat, non-compounding rule as everywhere else) -
a pure `passive` talent has no mechanical field here at all, it's checked
live by id at whichever specific call site cares (Quick Draw, below); an
active one names a `grantsAbility` id instead, folded into `engine.
collectAbilities` (one more source block, alongside organs/weapons/belt
items) the moment it's taken - `part`/`itemId`/`slot` all come back nil
for a talent-granted ability, since it isn't tied to any specific limb or
item the way the others are.

The starter tree (five talents, meant as a working proof of the structure
rather than a final roster - see "Known gaps"): `root` → `quick_draw`
(passive), `steady_grip` (passive, +5% aim), and `melee_specialist`
(passive, +5% strength) as three direct children, with `melee_specialist`
→ `flurry` (active) one level deeper - both a multi-branch root and a
real two-deep prerequisite chain, so the tree's actual shape gets
exercised, not just a flat list dressed up as one.

**Quick Draw** hooks the exact `return "full"` at the end of `engine.
runEquipmentAction`'s draw-candidate loop: a belt-origin candidate
(`candidate.kind == "slot"` with `candidate.slotDescriptor.kind ==
"belt"` - `engine.getAllSlots` confirms belt descriptors are literally
`{kind="belt", index=i}`, distinct from an equip-slot or a
ground-dropped-item origin) whose `weaponEntries[...].type == "ranged"`
returns `"quick"` instead when the talent's taken - excludes ground draws,
other-equip-slot draws, and melee weapons, matching "drawing a *ranged*
weapon from *the belt*" literally.

**Flurry** (`abilityEntries.flurry`, gamedata.lua) is three independent
one-handed melee swings in one full action. Unlike `rev_it_up` (one hit
roll gating a fixed five-hit combo, tied to the chain sword specifically -
see "Weapons"), Flurry belongs to the fighter, not one weapon: it picks
whichever equipped one-handed melee weapon/hand qualifies itself
(`engine.pickOneHandedMeleeSlot` - silent if exactly one qualifies, a
digit-select prompt mirroring `engine.pickLimb`'s own shape if more than
one, nil if none do), then rolls each of its three strikes' hit chance
independently rather than one roll gating the whole burst - three real
swings, not one connect-or-whiff combo, a deliberate distinction from Rev
It Up's guaranteed-or-nothing feel. `cooldown = 3`, and unlike Rev It Up
(whose "miss" refund is the documented exception - it doesn't semantically
activate until the blade connects), a total miss on Flurry does **not**
refund the cooldown: three real swings happened either way.

## Inventory & equipment

Full-screen modal (`inventoryWin`/`runInventoryScreen`), not the original
one-row bar - that bar still exists as a page-tab strip (`Tab` to toggle),
just repurposed. Rows, top to bottom: belt slots (always visible, even
empty), one **equip slot** per MANIPULATE limb (`getManipulateLimbs`,
derived from the body rather than a hardcoded pair of hands), that limb's
ammo (only shown if what's wielded there actually uses ammo), one row per
currently-**worn** apparel item (`"Outer: "`/`"Inner: "` plus its name, by
`layer`), then everything else in the bag, grouped by id with a count
(five energy charges are one row, not five).

Two keys do the work, split by what they mean rather than what they touch:

- **`Enter`** - use immediately. Reload for an ammo row (bypassing the
  in-combat reload action entirely - nothing special happens on reload, so
  there's no reason to make the player go through combat for it); take a
  worn row back off (straight back into the bag, no check needed - taking
  something off can't conflict with anything); put on a bagged/belted item
  that has a `layer` (apparel), checking `engine.canWearItem`'s layer/area
  overlap rule first and, on a conflict, logging which already-worn item
  it collides with instead of moving it (see "Apparel & coverage"); or
  whatever ability a belt/inventory entry grants otherwise (the salve, the
  splint - `ability.effect` is called directly, works outside combat since
  nothing it does is combat-specific, and a cancelled limb-pick correctly
  doesn't consume it, same `"noop"` convention combat abilities already
  use). An ability that's ever usable both ways can tell which by whether
  it was handed a real `enemy` (only `runEncounter` ever passes one) - the
  salve uses this to show its usual full-screen confirmation in a fight,
  but just log the result (see "Activity log") outside one, where a "press
  any key" prompt would just be friction once the limb's already picked.
  Wearing/removing apparel always just logs the result the same way,
  success or conflict alike. Everything else (a spare weapon sitting in
  the bag, ammo itself, an equip slot) doesn't respond - equipping a
  weapon needs a chosen destination, which Enter alone can't express.
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
have - only what's actually sitting loose in the bag does. `engine.
formatBulk` rounds to the nearest tenth before displaying anything - no
item's own `bulk` is ever finer than that, but `getBulkCapacity` is a real
average of several parts' own health/maxHealth ratios chained up the body
tree (see "Stats & combat"), which can otherwise come out as a long,
meaningless decimal (health ratios like `41/67` aren't clean to begin
with, and the ancestor-chain multiplication compounds that further) the
moment a limb takes anything but a round chunk of damage.

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

## Medical

A second full-screen page (`engine.runMedicalScreen`, `m` to open/close,
reachable from the top bar too - see "Screen layout") alongside Inventory,
reusing the same `inventoryWin` the same way every full-screen modal here
does, since the two are never open at once. Same two-pane layout as
Inventory: left half is every labeled body part (`engine.collectLabeledParts`,
same depth-indented list `pickLimb`/`viewLimbs` already use), health and a
`*` flag for anyone currently carrying an active status - health is right-
aligned flush to the pane's own edge in a fixed-width trailing column, so
a deeply-indented part name (a hand three levels deep, say) gets whatever
width is actually left over rather than a small hardcoded cap; right half is
full detail on whichever part is selected - health, every active status
by name and remaining duration (`engine.formatPartStatuses`, blank for a
permanent one - "Fractured" rather than "Fractured (-1)"), and every organ
installed (`engine.formatPartOrgans`, category slots and generic organs
alike, by name rather than raw id - organEntries/statusEntries both grew
a `name` field purely so this screen has something readable to show,
since nothing else in the game ever displayed either by anything but its
own id before this existed).

Selecting a part (arrow keys + Enter, or its own digit straight away - both
land on the same list index, so either works identically) opens a second,
smaller picker: whichever carried items are actually relevant to *that*
part right now (`engine.collectMedicalOptions`) - relevance test:

- `treats == "health"` (see below) and the part isn't already at full, or
- `treats` names a status the part currently has active (permanent ones
  included).

Duplicate copies of the same item collapse into one entry with a count
(`Dermoregenesis Salve x2`), same convention `engine.getInventoryRows`
already uses for its own inventory rows. Unlike combat's own Ability menu
(`engine.collectAbilities` - belt/equip only, skips anything on cooldown),
this also reaches into loose inventory - Medical isn't gated by turn
economy at all, so there's no reason to require pre-belting an item
first. Picking one applies it immediately and consumes it
(`engine.consumeCarriedItem`, shared with the inventory screen's own "use
immediately" - see "Inventory & equipment"), reporting the outcome to the
activity log exactly the way using an item outside combat always has,
since Medical is overworld-only (never reachable mid-fight, same as
Inventory).

`treats` (on the *ability* entry, not the item - an organ or weapon could
in principle grant the same ability someday) is what an ability actually
addresses: `"health"` for the Dermoregenesis Salve, or a statusId for
anything that cures one - the Splint (`use_splint`) is the first, curing
a fracture outright, the one thing its own permanent (-1) duration
otherwise has no way to end (see "Status effects"). Both effects accept
an optional `presetTarget`/`presetLabel` pair (on top of the usual
`user, enemy, sourcePart, sourceSlot` every ability effect already takes)
- when Medical calls one, it passes the part it already picked instead of
letting the effect call `Luadventure.pickLimb` itself the way it does for
every other caller (combat's Ability menu, the inventory screen's own
"use immediately") - the same function serves both flows, it just skips
its own picker when the part's already chosen for it.

## Apparel

A third full-screen page (`engine.runApparelScreen`, `a` to open/close,
reachable from the top bar too - see "Screen layout"), same two-pane
layout and shared `inventoryWin` every other one here uses. This is a
pure viewer - putting apparel on and taking it off both happen from the
Inventory screen instead (see "Inventory & equipment"), same as every
other item action; Apparel only ever displays the result. Left half is
the same per-part list `collectLabeledParts` always gives (see
"Medical"); right half is full coverage detail on whichever part is
currently selected.

Two independent cursors, since they answer different questions and
shouldn't have to share one: arrow keys (or a part's own digit straight
away) move which part's detail shows on the right - what's actually
protecting it - while `Tab` cycles through every currently-worn item in
its own strip (row 2, same bracket convention `engine.drawTopBar`'s page
tabs already use) and turns yellow whichever part rows fall within *that*
item's own coverage (`engine.getItemCoveredZones`, mapping its `covers`
areas up to zones, then checking every part's own `engine.getPartZone`
against them) - what a single item actually protects, read straight off
the list without cross-referencing zone names by hand. Neither cursor
moves the other.

The detail pane lists, separately, everything actually covering the
selected part on each layer (`engine.getPartCoveringItems`, by name) and
that layer's own per-damage-type coverage (`engine.formatPartCoverage`,
one decimal place - the underlying average, per "Apparel & coverage", is
rarely a whole number, and this is meant to be read at a glance rather
than computed by hand), then the same breakdown combined across both
layers - the real number `damagePart` actually reduces by, the two
separate layer numbers above it are its own inner/outer components. A
damage type with nothing covering it on either layer is left out
entirely rather than shown as a bare "0" - most parts only have two or
three types actually covered at once.

The debug console's own `wear`/`unwear <itemId>` (bypassing
`engine.canWearItem`'s layer/area overlap check entirely, same as every
other debug command bypasses whatever rule would normally apply) still
exists alongside the real action, for setting up a scenario without
having to actually carry the item first.

## Quests

A quest (`questEntries`) is a `name`/`description` (the latter is what the
Quest log screen shows - see below) plus a `startStep` and a `steps` table -
a graph, not a flat list, since real content wants multi-beat chains that
can branch, not just one boolean condition per quest the way this used to
work. Each step:

- **`npc`** - an `npcId` (see below) that has to be talked to for this step
  to progress, or `nil` for a step that advances the instant its own
  `condition()` goes true, no interaction needed ("moves on right away").
  The **start step** always has one - that's the only way a quest is ever
  discovered or accepted in the first place; only a step *after* the first
  can omit it.
- **`condition`** - a plain no-argument boolean function, exactly today's
  `isReady` idiom just scoped to one step instead of the whole quest - "as
  simple as a comparison, or very complex," reading whatever state it wants
  (`Luadventure.player.killLog`/`spareLog`/`globalTags`/stats/inventory,
  already bridged - see "Leveling & talents"/"NPCs"). This is also what
  keeps the mechanism ready for a future faction-reputation number: a step
  reading `Luadventure.player.reputation.someFaction` needs no engine
  changes at all, the same way today's steps already read `killLog` -
  reputation itself isn't built yet, just left room for.
- **`waitingLines`** - shown if the player talks to `npc` before
  `condition()` is true (meaningless if `npc` is nil).
- **`completeLines`** - shown as the turn-in prompt when `npc` is set and
  `condition()` is true; logged to the activity log one line at a time
  instead (via `engine.logActivity`/`engine.dialogue`) when `npc` is nil
  and the step auto-advances, since there's no dialogue interaction to
  show it through.
- **`rewardItemId`/`xpReward`** - optional, applied once, per step (not
  once per whole quest anymore).
- **`onComplete`** - optional no-argument function, run once when this step
  finishes, independent of (and in addition to) the reward above - for a
  step whose real payoff isn't loot at all, but a change to the world
  itself: an NPC doing the player a favor (unlocking a door, adding an
  object, changing what someone says from here on). Reaches
  `Luadventure.world` (a live reference to the same `world` table
  `engine.buildWorldSnapshot`/`applyWorldSnapshot` already treat as the
  source of truth - bridged the same way `Luadventure.player` already is)
  directly - deliberately the only new bridge this needed, rather than a
  bespoke "world-editing API" for cases nothing's asked for yet.
- **`next`** - a string (the next step id), `nil` (this step finishes the
  whole quest), or a `function() -> stepId|nil` for a branch, resolved at
  the exact moment this step completes - the entire branching mechanism is
  this one field.

Quests generally shouldn't loop back on themselves - the convention is to
let a quest finish and become offerable again rather than a step's `next`
cycling into its own graph - but this is a preference, not something the
engine checks for or blocks; `next` is free to point anywhere, including
backward, if a real case ever calls for it.

**Progress** (`player.quests[questId]`) is still a single string: absent
(not taken), a valid step id (in progress, currently at that step), or
`"done"` (`"done"` is reserved and can never be a real step id - same
convention as `"none"` meaning an empty equip slot elsewhere in this
codebase). No save-code changes were needed for this - `buildSaveData`/
`applySaveData`'s existing `player.quests` copy-loops are opaque-string
passthroughs regardless of what the string means.

**`npcId` replaces the old `questId` on a person map object.** Previously a
person object *held* the quest it was giving (`obj.questId`), rewritten to
`nextQuestId` on turn-in - that breaks down the moment a chain's steps want
*different* NPCs, since one object can't hold more than one quest's state.
Instead, any person object that matters to quest content gets a stable
`npcId` (its own identity, independent of which quest or step currently
cares about it - e.g. the village's Old Soldier is `npcId = "old_soldier"`),
and a step's `npc` field references that same id.
`engine.findActionableQuestStep(npcId)` is the reverse lookup both
`engine.interactWithPerson` and `engine.getObjectGlyph`'s person branch use
instead of reading a field the object carries directly: it walks
`questEntries`, and for each quest checks whether `npcId` owns the start
step (not yet taken - "offer") or the player's current step (in progress -
"waiting" or "turnin", depending on `condition()`); returns `nil` if
nothing's actionable, in which case the object just falls back to its
plain `greeting`/`greetingId` flavor line, same as any non-quest NPC. An
`npcId` field round-trips through save/load for free, exactly like
`questId` used to, since `engine.buildWorldSnapshot`/`applyWorldSnapshot`
already snapshot every location's whole `objects` list wholesale.

`engine.completeQuestStep(questId, quest, stepId, step)` is where a step
actually finishes - applies the reward, calls `onComplete` if present,
resolves `next`, and either moves `player.quests[questId]` to the next
step or marks it `"done"`. Shared by both the NPC turn-in path
(`engine.interactWithPerson`) and the auto-advance checker below, so
reward/effect/branch logic lives in exactly one place regardless of which
path completed a step.

**Auto-advance** (`engine.checkQuestProgress`) is what makes a no-`npc`
step actually move on right away: it walks every in-progress quest, and
while the current step has no `npc` and its `condition()` is already true,
completes it (logging `completeLines` to the activity log instead of a
dialogue prompt) and re-checks the new current step - so several
already-satisfied free steps in a row resolve in one pass, not one per
action. This is called from the main loop (luadventure.lua, right
alongside every existing `engine.render()` call, not inside `render()`
itself) - `engine.render()` is a pure draw function
(`drawStats`/`drawSprite`/`drawMain`/`drawLog`, no state mutation
anywhere else in it) and the codebase is deliberate about keeping it that
way (see "Combat deliberately never calls `drawStats()`..." above), so
`checkQuestProgress` sits next to `render()`'s call sites rather than
inside it. The main loop already calls `render()` after *every*
state-changing action (screens, interact, movement, the debug console),
so this one set of call sites covers everything, the same idiom
`engine.checkAwareness` already established for "recheck a background
condition after anything that could matter."

**Old-save backward compatibility**: no migration shim. An old save with
`player.quests.test_the_dummy = "active"` (the previous system's only
state string) loads fine - the load loop doesn't validate values. At
runtime, `"active"` simply isn't a valid step id;
`findActionableQuestStep`/`checkQuestProgress` both guard `quest.steps[state]`
for `nil` and skip that quest entirely if so, so an old save's quest just
goes inert (glyph `"0"`, no interaction offered, no auto-advance) rather
than erroring. This matches this project's existing backward-compat bar
(`data.spareLog or {}` - "default a missing field," not "upgrade an old
value's meaning") - deliberate, not an oversight.

One quest exists so far: **Blunt the Blade** (`test_the_dummy`), a single
step (`beat_the_dummy`) offered by the Old Soldier (`npcId = "old_soldier"`)
in the village, ready once the test dummy's been beaten at least once,
worth 50 XP on top of its item reward, and completing the whole quest
(`next = nil`).

## Quest log

A 5th top-bar page (`TOP_BAR_PAGES` gains `"Quests"`, hotkey `j` for
Journal), reachable the same way Inventory/Medical/Apparel/Character
already are. Modeled directly on the Character screen (the newest, most
similar two-pane list+detail full-screen modal): left half
(`engine.collectQuestLog`) lists every quest the player has ever started
(skips ones never taken - nothing to show), green once `"done"`, white
while still in progress; right half shows the selected quest's own
`description`, plus a rough "what's next" hint - the current step's own
`waitingLines` first line while in progress (an in-progress auto-advance
step just reads "In progress." instead, since there's no dialogue line
written for one to borrow), or "Complete." once done. Read-only - unlike
Character's talent-taking, there's nothing to pick here, just navigation
(`engine.runQuestLogScreen`, closes on `j` again).

## Factions & reputation

A faction (`factionEntries`) is a `name`/`abbreviation`/`description` (the
description is the in-world blurb the Factions screen's own description
pane shows, already authored to width rather than re-wrapped), a `ranks`
array (5 entries, own name + a one-line `effect` summary), and a `special`
tier (`name`/`description`/`condition`).

**`player.reputation`** is a plain `{ [factionId] = integer }` table.
Absence of a key is a real, meaningful third state - "this faction has
never interacted with the player" - distinct from a present value of `0`
("Neutral, and they know you exist"), same convention `player.quests`
already uses for "not yet taken." Range is `[-100, 100]`
(`REPUTATION_MIN`/`REPUTATION_MAX`), mapped onto five shared bands via six
boundary numbers (a band is the space between two of them):
`REPUTATION_TIERS = { -100, -75, -25, 25, 75, 100 }` - Hated/Disliked/
Neutral/Liked/Loved. Every faction reuses this same scale
(`engine.getReputationTierIndex`) and only supplies its own rank *names*
via `ranks` (index 1 = Hated band ... 5 = Loved band) - UGFC's own are
Most Wanted/Criminal/Citizen/Vigilante/Peacekeeper.

`engine.adjustReputation(factionId, delta, cap)` is the one mutator - lazy-
inits a faction's entry to `0` the first time it's touched (this is the
moment it "learns of" the player), then applies `delta`. `cap` is optional:
the ceiling (or floor, for a negative `delta`) *this specific call* can
push reputation to - repeatable low-stakes actions (routine patrol work,
say) can cap out well short of a faction's top rank without that cap ever
pulling back reputation already earned by bigger means (a capped call
never lowers reputation below whatever it already was, only stops it
*overshooting* past the cap). Bridged as `Luadventure.adjustReputation` for
a future quest step's `onComplete` to call - no real content calls it with
either argument yet.

**Special (a sixth tier, per faction)** is "who you work for" - a
discrete, sticky commitment, not something derived from the reputation
number at all. `player.specialFaction` is a single value (not per-faction)
- the one faction, if any, the player has committed to; mutually exclusive
with every other faction's own special tier by construction.
`engine.setSpecialFaction(factionId)` is the one commitment primitive:
succeeds only if `player.specialFaction` is currently `nil`, otherwise
refuses - "by default you can't switch away from one" lives in exactly
this one place. Nothing here auto-grants Special just from reputation
crossing into the Loved band - a faction's own `special.condition` (the
same no-argument "as simple as a comparison, or very complex" idiom quest
step conditions use) is free to check that band as one of its
requirements, but reaching Special always goes through
`engine.setSpecialFaction` explicitly, called by whatever real content
offers it (a quest, eventually - not built yet). `engine.getFactionRankName`
is what actually resolves display: `special.name` if
`player.specialFaction == factionId`, otherwise whichever band name the
raw reputation number falls into.

Five factions exist so far - the setting's five main powers, per the
user's own framing, though not necessarily the only ones that will ever
exist:

- **U.G.F.C.** (United Galactic Federal Coalition) - the settled galaxy's
  primary governing body: largest, most professional, generally
  well-meaning, but buried in bureaucracy and badly under-resourced in
  places. Ranks Most Wanted/Criminal/Citizen/Vigilante/Peacekeeper, special
  tier **Enforcer**.
- **Kaeravoli Separatists** (`kaeravoli`) - planetary governments in open
  rebellion against the Coalition, originating from Kaeravol III, with no
  central command and wildly varying tone cell to cell. Ranks Coalition
  Stooge/Suspect/Outsider/Sympathizer/Comrade, special tier **Vanguard**.
- **Markenson's Interstellar Trading Guild** (`mitg`) - a trading guild
  turned political power through wealth, corruption, and backstabbing;
  membership is restricted to the wealthy or well-connected, and it quietly
  pays the Wayfarers for protection. Ranks Marked Debtor/Bad Risk/Client/
  Preferred Client/Guild Asset, special tier **Guild Partner**.
- **Wayfarers** (`wayfarers`) - pirates, with no real code beyond a loose
  agreement not to shoot each other; order comes from whoever has the ego
  and the guns to back a claim. Ranks Marked/Unwelcome/Unknown Face/Crew
  Friend/Captain's Word, special tier **Fleet Captain**.
- **Signus Biomedical** (`signus`) - "Blooming a better tomorrow": a
  profit-driven genetics corporation with real scientific breakthroughs
  (splicing, GMO agriculture, animal domestication) and a habit of skirting
  human experimentation law through technicalities the UGFC has never
  closed. Ranks Terminated Subject/Problem Case/Unlisted/Program Associate/
  Flagship Result, special tier **In-House Asset**.

Every faction's `special.condition` is currently the same placeholder
(`player.stats.level >= 5`) - real faction-quest content to gate each
Special tier properly is future work, same proof-of-structure-first spirit
the talent tree and the quest step system were both introduced with. Four
of the five (all but Ex-Peacekeeper's own UGFC) are reachable as "known"
straight out of character creation, via a background's `reputationBonus`
(see "Backgrounds") - the only reputation content that exists in play so
far; nothing else yet calls `engine.adjustReputation`.

## Factions screen

A 6th top-bar page (`TOP_BAR_PAGES` gains `"Factions"`, hotkey `f`),
reachable the same way every other page is - but unlike
Inventory/Medical/Apparel/Character/Quests (which all share one full-
screen `inventoryWin`, split into panes by cursor position), this is a
genuine four-window screen, the same real-window four-corner layout the
overworld and combat each already use (`factionListWin`/`factionLogoWin`/
`factionStatusWin`/`factionDescWin`, right alongside `combatMapWin` and
friends) - all four panes need to redraw independently, the same reason
combat's own four corners aren't a single shared window either.

- **Top-left**: every faction the player has ever interacted with
  (`engine.collectKnownFactions` - walks `player.reputation`'s own keys),
  current selection marked. `Left`/`Right` change it - not `Tab`, which has
  to stay free for the shared top-bar strip this screen is also reachable
  through, same as every other page.
- **Bottom-left**: mostly empty - a placeholder (`"[ no logo ]"`), exactly
  like the overworld's own portrait pane, except its own last two rows
  carry the control hint every other page has (`[Left/Right]`/`[Up/Down]`/
  `[F] close`) - this pane's own bottom row happens to be the screen's
  actual last row too, so the hint lives here rather than needing a 5th
  window just for it.
- **Top-right**: the selected faction's current rank
  (`engine.getFactionRankName`), a progress bar (`engine.formatProgressBar`,
  new - nothing like it existed before this), and the current rank's
  `effect` line (or `special.description` if the player is Special with
  this faction). Three bar cases: bands 1-4 fill toward the next band's
  boundary; band 5 (Loved) with no Special committed to *anyone* yet reads
  full plus a `"SPECIAL RANK AVAILABLE"` line (there's no higher
  *reputation* band left - only the faction's own `special.condition`
  stands between here and Special); band 5 (or any band, once committed)
  with `player.specialFaction` already set - just the full bar, no extra
  text, since claiming it's "available" would be wrong once the player's
  mutually-exclusive choice is already made (to this faction or a
  different one).
- **Bottom-right**: the faction's own `description`, scrolled by `Up`/
  `Down` (independent of which faction is selected) - modeled on
  `engine.drawLog`'s own scroll-to-window pattern.

`engine.runFactionsScreen()` closes on `f` again, same self-closing
convention every other page uses.

A faction's `description` (gamedata.lua) is authored as one plain string,
not pre-broken into lines - `engine.wrapTextToWindow(win, text)` (a sibling
of `engine.wrapText`/`engine.writeWrapped` that reads `win`'s own current
width instead of a caller-supplied one) wraps it fresh every draw to
whatever the description pane's own width actually turns out to be, so
writing one of these doesn't mean guessing a screen size up front, and the
same content wraps correctly on a narrow real computer screen and a wide
one alike. Scrolling (`descScroll`, the `Up`/`Down` handlers) works
against this same freshly-wrapped line list each time, not a stored one.

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
**Load**, **Manage Saves**, or **Quit Game**, flavored as inserting an ID
card. Five slots, each shown with a summary (level, steps, which
location's terminal made it, plus a custom nickname if one's been set -
see below) instead of a bare number; saving over an occupied slot asks to
confirm.

What's saved is deliberately "everything about the player, nothing about
position": full stats, inventory, equipped gear + ammo, worn apparel, belt,
statuses, cooldowns, quest progress, kill/spare log, the activity log's own
scrollback (restored exactly as it read at save time, not replayed - see
"Activity log"), name, pronouns, and the entire body tree
(health/organs/statuses per part, rebuilt from templates on load rather
than trusting a frozen shape snapshot - self-healing against future
template tuning). Position itself isn't saved; only which save point made
the save is, and loading finds that same terminal again and spawns you in
an open cell beside it.

**World state** (which items have been picked up, which doors are open,
where each quest giver's dialogue cycle currently is) is saved too, as a
straight snapshot of every location's `objects` list - loading replaces
those lists wholesale rather than trying to reconcile individual entries.

**Manage Saves** (`engine.doManageSaves`) is the one thing Save/Load
themselves can't do: rename or delete a slot without touching what's
actually saved there. Rename (`engine.renameSaveSlot`) just overwrites the
slot's own `label` field and rewrites the file - a nickname a save
already had survives a later overwrite too (`engine.doSave` reads the
existing slot first specifically to carry it forward, rather than
silently clearing it back to nothing). Delete (`engine.deleteSaveSlot`)
removes the file outright, back to "Empty" in every slot listing - no
undo, confirmed once before it happens.

Files are plain `textutils.serialize` output under `saves/slotN.sav`, in
the computer's own data directory - never inside the mounted project
folder, so nothing save-related touches this repo.

## Character creation

Runs once at startup, before the very first render: name (free text),
pronouns (Male/Female/Nonbinary presets, or "Custom pronouns" for two
direct text fields), background (see "Backgrounds" - who the player was
before any of this), species (see "Species" - this is where `player.body`
actually gets built, since it needs a menu, which needs the game's windows
to already exist), then 5 points to spend across strength/reflex/aim, each
worth a flat +5% (`stats.x = stats.x + points*0.05`, not compounding,
stacking on top of whatever the chosen background/species already
adjusted). Confirm
is locked until all 5 points are spent; a Reset option clears an
in-progress allocation back to zero. `STAT_ALLOCATION.step` (the +5%
figure) is reused directly by the single-point skill spend a level-up
grants later (see "Leveling & talents") - same rule, same constant, just
one point at a time instead of five up front.

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
line's remaining space-separated tokens) default to the player's own body,
but `setHealth`/`addStatus`/`clearStatus` all accept an optional
`@<target>` token - anywhere among their other arguments, since nothing
else any command here takes ever starts with `@`
(`debugConsole.extractTarget` pulls it out first and hands every other
command its remaining args reindexed from 1, same as if the token was
never there at all) - resolved (`debugConsole.resolveTarget`) to either
the player (no token, or the literal `@player`) or a 1-based index into
the current fight's `combatState.scene`, same numbering the Enemies pane's
own list already uses. Reaches an enemy mid-fight, not just the player:

- **`setHealth <limb> <health> [@target]`** - clamps to `[0, maxHealth]`.
- **`give <itemId> [count]`** - straight into the player's own inventory,
  no bulk check - an enemy has no inventory to give into, so this one
  never takes a target at all.
- **`wear <itemId>`** / **`unwear <itemId>`** - straight onto/off of
  `player.worn`, bypassing `engine.canWearItem`'s layer/area overlap
  check entirely (see "Apparel & coverage") - alongside, not instead of,
  the real wear/unwear action Inventory's own `Enter` offers (see
  "Inventory & equipment"). Player-only, same reasoning as `give`.
- **`attachLimb <parentLimb> <slotName> <templateId> [@target]`** -
  bypasses `engine.attachPart`'s own tag-lock check entirely, so a slot
  normally gated behind an organ (`left_arm_2`/`right_arm_2`, behind
  MULTI_LIMBED - see "Body system") can be exercised without actually
  installing one. `parentLimb` is looked up by its display label
  (`debugConsole.findPart`), same as every other limb argument here.
  Reports the zone `engine.sidedZone` actually derived, for checking it
  landed right without a trip through the Apparel screen.
- **`setLevel <level>`** - a raw poke: sets `stats.level` directly and
  zeroes `stats.xp`, bypassing `engine.grantExperience`'s loop and
  skill/talent point awards entirely (see "Leveling & talents"). For
  jumping straight to a level to test late-game numbers, not a substitute
  for `grantExperience` when the point-award flow itself is what's being
  tested. Player-only, same reasoning as `give`.
- **`grantExperience <amount>`** - routes through the real
  `engine.grantExperience`, so it chains multi-level-ups and awards
  skill/talent points exactly like a quest/kill reward would - reports
  levels gained and current banked points. Player-only.
- **`setQuestStep <questId> <stepId>`** - a raw poke, the direct analog to
  `setLevel`: sets `player.quests[questId]` straight to `stepId` (or
  `"done"`), bypassing offer/condition/reward/`onComplete` logic entirely
  (see "Quests"). What makes a branching path's later steps actually
  testable without playing through everything ahead of them for real.
  Player-only.
- **`setReputation <factionId> <amount>`** - a raw poke: sets
  `player.reputation[factionId]` directly (creating the entry if it wasn't
  there), clamped to `[REPUTATION_MIN, REPUTATION_MAX]` (see "Factions &
  reputation"). No `cap` parameter - a debug set is meant to land exactly
  on the requested number for testing, not simulate a capped in-game gain.
  Player-only.
- **`setSpecialFaction <factionId|none>`** - bypasses
  `engine.setSpecialFaction`'s own single-committer check entirely (that
  check would otherwise make testing a second faction's Special impossible
  without restarting); `none` clears the commitment back to `nil`.
  Player-only.
- **`addStatus <limb> <status> [amount] [@target]`** - part-scoped
  statuses only (`bleed`/`poison`/`fracture` - `adrenaline` is
  character-wide, not reachable this way since every command here takes a
  limb); `amount` overrides the status's own default duration/stack count.
- **`clearStatus <limb> <status|all> [@target]`**
- **`targets`** - lists every currently valid `@target`: the player,
  plus whoever's actually in `combatState.scene` right now (empty outside
  a fight).

A bad limb/item/status/target is reported back as an ordinary result
rather than raising - `debugConsole.runCommand` also wraps the actual call
in `pcall`, so a bug in a command itself can't take the whole game down
either.

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

Every actual NPC opponent is content, defined entirely in gamedata.lua
(see its own NPCs section) the same way weapons/items/species are - the
engine only supplies the base class and a handful of reusable building
blocks. `npc` extends `character` with a `decide(state)` method each NPC
type overrides, given `{self, player, distance}`. A `decide()` returns
either a single decision or a list of them (the endTurn block in
`runEncounter` normalizes either shape into a list and executes each
entry in order) - a decision is one of `{action="attack", weapon=}`
(`weapon` optional, falls back to a bare Strike), `{action="move", dx=,
dy=}`, `{action="idle"}`, or `{action="surrender"}` (see "Surrender" -
stops the rest of the list from resolving, same as it would stop a later
round from ever happening).

**There's deliberately no dedicated "AI action economy" system** - no
enemy-side equivalent of the player's own quickened/restricted bonus-turn
tracking. A fixed framework would only constrain whatever a real one
eventually needs; instead, an NPC type that wants to emulate a multi-
action turn just returns more than one decision from a single `decide()`
call. `gamedata.lua`'s unused `quickExampleType` (never registered in
`enemyEntries`, so it can't actually be spawned) is a reference for this:
checks its own reflex against `REFLEX_QUICK_THRESHOLD` (the exact
constant the player's own move-speed gating uses), and if it qualifies,
returns two decisions instead of one. Nothing enforces this is legal or
sane - a `decide()` chaining two full-speed attacks in a row is just as
"valid" as returning one, so restraint is entirely on whoever writes a
real one.

Rather than each NPC type writing its own movement/targeting logic from
scratch, `decide()` is meant to compose a small set of generic, reusable
behaviors exposed the same way body-construction primitives are
(`Luadventure.fleeX(state, ...) or Luadventure.fleeY(state, ...) or
Luadventure.someFallback(state, ...)`, first non-nil one wins):

- **`fleeDanger(state)`** - steps away from wherever a thrown grenade is
  about to land (`combatState.pendingGrenade`) if `state.self` is within
  its blast radius; `nil` otherwise. The one turn between a grenade
  landing and it actually going off (see "Grenades") is exactly the
  window this checks.
- **`fleeMelee(state, keepDistance)`** - steps away from the player once
  they're within `keepDistance` tiles; `nil` otherwise. For an NPC type
  better suited to fighting at range than getting swung at - see
  `banditType` below for the one that actually uses it.
- **`checkSurrender(state, healthThreshold)`** - see "Surrender".
- **`approachAndStrike(state, weapon, slot)`** - the generic "close and
  attack" fallback: attacks with `weapon` once in range, otherwise closes
  distance one cardinal step at a time. Works the same for melee or
  ranged - `slot` is optional and only matters for a weapon with
  `ammoCapacity` (the equip slot it lives in, e.g. `"right_hand"`, same
  key `state.self.ammo` already uses): passing it tracks and burns ammo
  the same way the player's own Fight action does, and this returns `nil`
  once it runs dry rather than ever attacking for free - the one case
  this can return `nil` at all (without a `slot`, or for a weapon that
  doesn't use ammo, something always has to happen every turn). A
  decide() relying on that for its own fallback needs something after it
  in the chain, same as `fleeDanger`/`checkSurrender` already expect.
- **`hasAmmo(combatant, slot, weapon)`** - the same ammo check
  `approachAndStrike` makes internally, exposed on its own for a
  `decide()` that needs to pick a whole strategy around it rather than
  just the one attack decision - see `banditType` below, which only
  bothers keeping its distance (`fleeMelee`) while this is still true.
  Checking ammo only at the attack step (kiting regardless) would fight
  its own melee fallback into a permanent stalemate once the pistol's
  dry: `fleeMelee` backing away the instant it's within
  `BANDIT_KEEP_DISTANCE`, the bare-Strike fallback immediately closing
  back in since `Strike`'s own range (1) is well inside that, forever,
  without ever landing a punch - caught by actually playtesting a bandit
  down to empty, not just reading the chain.

`stepToward`/`stepAway` are the shared single-cardinal-step building
blocks underneath all of these (whichever axis has more ground left to
cover, same "one axis per turn" rule the player's own arrow-key movement
follows) - a mirror pair, not something a `decide()` would call directly.
`isDisarmed`, `getEffectiveReflex`/`getEffectiveAim`, and
`REFLEX_QUICK_THRESHOLD` are the raw building blocks behind
`checkSurrender` and the player's own move-speed gating, exposed for
anything even more custom.

Three real NPC types exist so far. Which one `runEncounter` actually
spawns is read straight off the triggering map object's own `enemyType`
field (looked up in gamedata's `enemyEntries`, defaulting to
`"test_dummy"` for any object that doesn't set one - every enemy object
did, before this existed):

- **`testDummyType`**: `fleeDanger(state) or approachAndStrike(state,
  weaponEntries.strike)` - flee a grenade first, brawl bare-fisted
  otherwise. A mindless sparring target with nothing really at stake, so
  it never surrenders. Lives behind a door in the grasslands specifically
  so it doesn't interrupt ordinary exploration, but is still there to
  spar with on demand.
- **`raiderType`**: `fleeDanger(state) or checkSurrender(state,
  RAIDER_SURRENDER_HEALTH) or approachAndStrike(state,
  weaponEntries.chain_sword)` - flees a grenade, gives up once badly hurt
  or disarmed, otherwise fights with a chain sword. Exists specifically
  to exercise surrender.
- **`banditType`**: `fleeDanger(state) or checkSurrender(state,
  BANDIT_SURRENDER_HEALTH)`, then - only while `hasAmmo(state.self,
  "right_hand", weaponEntries.laser_pistol)` - `fleeMelee(state,
  BANDIT_KEEP_DISTANCE) or approachAndStrike(state,
  weaponEntries.laser_pistol, "right_hand")`, otherwise
  `approachAndStrike(state, weaponEntries.strike)`. The ranged
  counterpart to the raider, specifically to exercise the ranged/ammo
  side of enemy combat: keeps its distance and shoots rather than
  closing in like a melee brawler, tracking real ammo the same way the
  player's own sidearm does (`spawnBandit` starts it loaded off
  `weaponEntries.laser_pistol.ammoCapacity`), and commits to a brawl
  bare-fisted once it runs dry rather than ever firing for free.
  Gating `fleeMelee` on `hasAmmo` (rather than just chaining it ahead of
  both attack fallbacks) matters: kiting unconditionally would have it
  backing away the instant the bare-Strike fallback closes back within
  `BANDIT_KEEP_DISTANCE`, forever, once genuinely out of ammo - a real
  stalemate caught by playtesting a fight all the way to empty, not just
  reading the chain. Placed 13 tiles from the raider - deliberately
  *within* `SIGHT_DISTANCE`, not clear of it, to exercise group/chain
  awareness (see "Sight-triggered combat"): approaching from the open
  west side of the village, the player enters the bandit's own radius
  well before the raider's, and the raider joins anyway purely because
  it's within range of the now-aware bandit.

Enemy attacks only scale damage by `enemy.stats.strength` for a `"melee"`
weapon, matching the player's own Fight action exactly (a flat multiplier
on *every* weapon, ranged included, was a real bug here until the bandit
above needed it fixed) - and, same as the player, burn one unit of ammo
per shot for whichever weapon/slot `approachAndStrike` was given, whether
the shot actually lands or not.

No pathfinding exists yet for any of this - see "Known gaps" for what
that means once a room has more shape to it than an empty rectangle.

Two purely-flavor "Villager" NPCs stand next to each other in the village
sharing one dynamic gossip line about the player (see "Dialogue
templating") - functionally two adjacent people who happen to say the
exact same thing (whichever variant currently applies), not a real
NPC-to-NPC conversation system.

## Known gaps / likely next steps

- Portrait pane is still a placeholder - nothing draws there.
- The talent tree (`talentEntries`, see "Leveling & talents") is
  intentionally small - five talents, meant to prove the prerequisite-gated
  structure works end to end, not a final roster. Both mechanical shapes a
  talent can have (`statBonus`, `grantsAbility`) are exercised at least
  once; growing the tree from here is just adding more entries with a real
  `parent`.
- `engine.grantExperience` is bridged (`Luadventure.grantExperience`) so a
  future dialogue-choice effect (rewarding a player for cleverly avoiding
  a fight, say) can call it directly - no such branching dialogue exists
  yet (quest accept/decline is still the only real choice any dialogue
  offers), so this XP source is a capability, not something reachable in
  play today.
- Only three enemy types (test dummy, raider, bandit) and one quest
  exist - real group fights do happen now (see "Sight-triggered combat"),
  just only ever among these three.
- The step-based quest system (see "Quests") is only exercised by one
  real, single-step quest - multi-step chains, branching `next` functions,
  auto-advance steps, and `onComplete` world effects were all verified
  live with temporary test content (a second NPC, a small branching test
  quest) that was removed once confirmed working, so none of that is
  reachable in play yet. The mechanism itself is proven end to end; real
  multi-step content is just future work.
- All five factions' (see "Factions & reputation") Special tiers share the
  same placeholder `special.condition` (`player.stats.level >= 5`) - real
  faction-quest content to gate each one properly doesn't exist yet, same
  proof-of-structure-first spirit as the talent tree and the quest step
  system. Reputation itself is only ever granted once, at creation, via a
  background's `reputationBonus` (see "Backgrounds") - nothing in play
  after that point calls `engine.adjustReputation` (no quest reward,
  encounter outcome, etc.), so beyond that starting value the system is
  reachable only through the `setReputation`/`setSpecialFaction` debug
  commands, same "capability before content" situation
  `engine.grantExperience`'s own dialogue-choice hook is in.
- Pronouns are consumed by name/`{{subject}}`/`{{object}}` templating;
  `UNSIGHTLY` by one hardcoded dialogue check. Neither affects anything
  beyond that yet - social mechanics (haggling, reactions) wait on NPCs and
  a shop system that don't exist yet either.
- `backgroundEntries` (see "Backgrounds") has five ids with real names,
  stat/reputation bonuses, and `player.background` is kept around
  specifically for future content (dialogue, quests) to check directly -
  but every `description` (the in-world flavor text shown in the picker)
  is still blank. Narrative content, not mechanical wiring; nothing else
  about the feature needs to change once it's written.
- Only one non-human species exists. Adding another is just a `build`
  function plus a `speciesEntries` entry - nothing else references a
  species by name anywhere.
- Enemy movement (`approachAndStrike`) only clamps to room bounds -
  no wall/door awareness at all, so it can walk straight through one
  closing distance on the player. Deliberately left alone for now (the
  dummy's AI is meant to stay simple for testing) - real pathfinding is a
  later pass.
- The test dummy always attacks with a bare Strike and doesn't go through
  `equipped` at all, so limb destruction never disables *its* attacks and
  it has nothing to drop - disarming (arm/hand destruction, a future disarm
  skill) is a player-only mechanic for now, same as the dropped-weapon
  system it's built on top of.
- Quest/NPC dialogue still always shows a full prompt, even the purely
  flavor ones - only item pickup, doors, and outside-combat item use moved
  to the activity log so far.
- Fleeing and later re-engaging the same fight fully heals whoever's still
  alive in it - `engine.runEncounter` calls a fresh `enemyEntries[...].spawn()`
  every time an encounter starts, and a flee (see "Sight-triggered combat")
  only carries a surviving foe's *position* forward via its own
  `spawnObject`, not the combatant instance itself (body, health, statuses,
  cooldowns) - a new one is built from scratch on the next engagement.
  Deliberate for now, not an oversight: each encounter starting clean keeps
  the flee/re-engage loop simple, at the cost of a partial win before
  retreating not actually carrying forward. Persisting real combatant state
  across a flee (storing it on `spawnObject` itself, restoring it in
  `spawn()`) would be the fix if that ever matters more than the
  simplicity does.
