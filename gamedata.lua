--[[
    Luadventure game content - organs, body parts, statuses, weapons, items,
    abilities, species, the world map, quests, and dynamic greetings. This
    is the file to edit (or replace/extend) to add new content; the engine
    itself (combat resolution, rendering, save/load, the body/tag system)
    all lives in luadventure.lua and doesn't need touching for most content
    additions.

    HOW THIS FILE IS LOADED

    luadventure.lua does `local gamedata = require("gamedata")` very early
    (right after declaring the `Luadventure` global table), and everything
    below is returned as one table at the bottom of this file. Every
    reference elsewhere in the engine to, say, `itemEntries` is actually
    `gamedata.itemEntries`.

    HOW TO REACH ENGINE STATE/FUNCTIONS FROM HERE (custom abilities, quest
    checks, species builders, ...)

    Anything defined in this file that needs to run engine logic - reading
    the live player, dealing damage, logging a combat message, applying a
    status - does it through the `Luadventure` global table, NOT by
    referencing engine functions directly (they don't exist as locals in
    this file's scope at all). `Luadventure` is populated by luadventure.lua
    itself, in one block, after all the engine functions it exposes are
    defined but before this file is required - so by the time any function
    written below actually RUNS (during real gameplay), everything on
    `Luadventure` is guaranteed to exist, regardless of the order these two
    files happen to load in.

    The full list of what's exposed - `Luadventure.player` (the live
    player object), `Luadventure.logCombat`/`.logActivity` (report
    something, see the ability effects below for examples), `.dialogue`
    (fills `{{name}}`/`{{subject}}`/`{{object}}` templates), `.pickLimb`
    (prompt to target a limb on a body), `.pickSpecialAmmo` (prompt to pick
    a reserve-shell item from inventory - see the shotgun's Special Shot),
    `.pickThrowTarget`/`.queuePendingGrenade` (aim and register a delayed
    blast - see the grenade's Throw Grenade), `.removeInventoryItems`,
    `.damagePart`/`.healPart`,
    `.applyPartStatus`/`.applyCharacterStatus`, `.isDead`/`.isLimbFunctional`,
    `.getLimbStrength`/`.getFinalHitChance`, `.gridDistance`,
    `.collectLabeledParts`/`.getPartLocalTags`/`.walkBody`, `.combatState`
    (`.flash(x, y, symbol)` briefly highlights a map cell red,
    `.redrawPanes()` restores the combat screen after a fullscreen prompt -
    see any ability effect below that calls `pickLimb` for why),
    `.newTorso`/`.attachPart`/`.installCategoryOrgan`/`.installGenericOrgan`/
    `.recalcGlobalTags`/`.newHumanBody`/`.newInsectoidBody` (body
    construction, for a custom species' own `build` function) - is
    documented in full, with signatures, in design.md under "Modding".

    A WORKED EXAMPLE: a custom ability that reads player data

    abilityEntries.my_custom_heal = { name = "Custom Heal", speed = "quick" }
    abilityEntries.my_custom_heal.effect = function(user, enemy)
        -- `user` is already whoever's using it (the live player, in
        -- practice) - most effects don't need Luadventure.player at all,
        -- only something that looks at the player *regardless* of who's
        -- acting would (nothing currently does, but the hook's there).
        local healed = Luadventure.healPart(user.body, 10)
        Luadventure.logCombat("You feel a little better. Healed " .. healed .. ".")
    end

    Everything below this comment is unchanged in spirit from before the
    split - only cross-references to engine functions were rewritten to go
    through `Luadventure`.
--]]

-- Organs can't be damaged directly; they add abilities/modifiers to the part
-- they're installed in (or, for global grants, to the whole character), and
-- can require/forbid tags the same way slots can.
local organEntries = {
    -- Baseline human organs. No grants, no requires, no conflicts - every
    -- other organ in the game is defined relative to these doing nothing.
    human_skin = { category = "skin", grantsLocal = { "SKIN" } },
    human_bone = { category = "bone" },
    human_muscle = { category = "muscle" },
    human_vitals = { category = "vitals" },
    human_auxiliary = { category = "auxiliary" },

    -- Insectoid's skin/bone: chitin instead of the human baseline. The
    -- exoskeleton is what actually supports a tail or wings at all, hence
    -- granting TAILED/WINGED globally here rather than on the torso itself
    -- - swap the bone organ out and those slots would lock again. The
    -- species' own reflex penalty/endurance bonus (see speciesEntries)
    -- isn't modeled as an organ modifier - there's no live system that
    -- consumes a per-part reflex modifier yet, so it's just a flat
    -- character-stat adjustment applied once at creation instead.
    chitin_skin = { category = "skin", grantsLocal = { "SKIN" } },
    chitin_bone = { category = "bone", grantsLocal = { "CHITIN" }, grantsGlobal = { "TAILED", "WINGED" } },

    -- Compound eyes, mandibles, the general look - a generic organ (not a
    -- swappable category slot) since it's about the head's fundamental
    -- shape rather than something you could organ-swap away.
    insectoid_features = { grantsGlobal = { "UNSIGHTLY" } },

    subdermal_plating = { -- generic organ, not tied to a hardcoded category
        requires = { "SKIN" },
        conflicts = { "SUBDERMAL", "CHITIN" },
        grantsLocal = { "SUBDERMAL" },
        modifiers = { defense = 2 }, -- data only for now, nothing consumes this yet
    },

    -- Test organ for the strength system: a muscle-slot swap that boosts
    -- STRENGTH for whatever's attached below it (a hand punching with a
    -- reinforced arm behind it hits harder).
    reinforced_muscle = { category = "muscle", modifiers = { strength = 1.5 } },

    spinal_graft = { -- meant for the torso itself; unlocks the extra-arm slots
        grantsLocal = { "MULTI_LIMBED" },
    },

    cybernetic_eye = { -- grants a tag body-wide, not just to its own limb
        grantsGlobal = { "OCULAR_IMPLANT" },
    },
    neural_targeting_suite = { -- needs an eye installed *somewhere* on the body
        requires = { "OCULAR_IMPLANT" },
        abilities = { "called_shot" }, -- data only for now, nothing consumes this yet
    },

    -- Generic chest implant granting the adrenaline_shot ability (see
    -- abilityEntries below).
    adrenal_auto_injector = { abilities = { "adrenaline_shot" } },
}

-- Library of every swappable bodypart template in the game. The torso itself
-- is never swapped wholesale - see Luadventure.newTorso - everything that
-- attaches to it comes from here.
--
-- `zone` is which apparel coverage zone this part draws its protection from
-- (see COVERAGE_AREAS/AREA_TO_ZONE below) - horns, antennae, and a stinger
-- can't be covered at all, so their templates just don't set one, which
-- makes them fall through to whatever zone their parent has instead.
--
-- `aimDifficulty` (default 1, omitted where it doesn't apply) divides both
-- this part's hit chance (see the engine's getFinalHitChance) and its own
-- health at creation by the same factor - a small or fast-moving part (a
-- hand, a head, and more so a stinger) is harder to land a hit on than
-- aiming dead center, but folds faster once it's actually hit.
local partEntries = {
    human_head = {
        tags = { MORTAL = true },
        health = 100,
        zone = "head",
        aimDifficulty = 1.5,
        organSlots = { skin = "human_skin", bone = "human_bone", muscle = "human_muscle" },
        subSlots = {
            horns = { requires = {} },
        },
    },
    human_arm = {
        tags = {},
        health = 100,
        zone = "arms",
        organSlots = { skin = "human_skin", bone = "human_bone", muscle = "human_muscle" },
        subSlots = {
            hand = { requires = {} },
        },
    },
    human_hand = {
        tags = { MANIPULATE = true }, -- can hold something, so can also throw an unarmed punch
        health = 100,
        zone = "hands",
        aimDifficulty = 1.5,
        organSlots = { skin = "human_skin", bone = "human_bone", muscle = "human_muscle" },
        subSlots = {},
    },
    human_leg = {
        tags = {},
        health = 100,
        zone = "legs",
        organSlots = { skin = "human_skin", bone = "human_bone", muscle = "human_muscle" },
        subSlots = {
            foot = { requires = {} },
        },
    },
    human_foot = {
        tags = {},
        health = 100,
        zone = "feet",
        organSlots = { skin = "human_skin", bone = "human_bone", muscle = "human_muscle" },
        subSlots = {},
    },

    -- No species uses this one for real yet, but a horn can't be covered
    -- by anything, so it has no zone of its own - getPartZone falls
    -- through to whatever it's attached to (the head).
    horn = {
        tags = {},
        health = 100,
        organSlots = { skin = "human_skin", bone = "human_bone", muscle = "human_muscle" },
        subSlots = {},
    },

    -- Insectoid's head - same shape as a human head (subSlots is where the
    -- horns/antennae/etc difference actually lives), just chitin instead of
    -- skin/bone, and unsettling enough to grant UNSIGHTLY globally (see
    -- insectoid_features). Its antennae subslot below attaches a real,
    -- separate part (the `antenna` template) - the head shape itself
    -- doesn't otherwise change to accommodate it.
    insectoid_head = {
        tags = { MORTAL = true },
        health = 100,
        zone = "head",
        aimDifficulty = 1.5,
        organSlots = { skin = "chitin_skin", bone = "chitin_bone", muscle = "human_muscle" },
        subSlots = {
            antennae = { requires = {} },
        },
    },

    -- Insectoid's abdomen - the part that fills the torso's tail slot once
    -- chitin_bone unlocks it (see Luadventure.newInsectoidBody), never the
    -- torso itself: a torso is what every creature has, so it's never
    -- relabeled or repurposed into a species' own anatomy. Not a literal
    -- tail, but it sits where one would and is structurally treated like
    -- one. Chitin skin/bone same as the rest of the insectoid plan; its own
    -- stinger subslot below is where the sting attaches (as a real part,
    -- not folded into the abdomen itself) - future cybernetics that modify
    -- the sting or its venom would be organs installed on *that* part, once
    -- those exist.
    abdomen = {
        tags = {},
        health = 100,
        zone = "tail",
        organSlots = { skin = "chitin_skin", bone = "chitin_bone", muscle = "human_muscle" },
        subSlots = {
            stinger = { requires = {} },
        },
    },

    -- An antenna can't be covered by apparel at all, same reasoning as horn
    -- above, so it has no zone of its own either.
    antenna = {
        tags = {},
        health = 100,
        organSlots = { skin = "chitin_skin", bone = "chitin_bone", muscle = "human_muscle" },
        subSlots = {},
    },

    -- The stinger itself: a small, precise structure at the tip of the
    -- abdomen rather than the abdomen's whole mass, hence the hefty
    -- aimDifficulty - notably harder to land a hit on (and far more
    -- fragile once it is) than the merely-small hand/head above. Can't be
    -- covered by apparel, same reasoning as horn/antenna. naturalWeapon
    -- marks it as its own unarmed attack, separate from (and not
    -- requiring) MANIPULATE/equipped-gear - see the engine's pickAttack.
    stinger = {
        tags = {},
        health = 100,
        aimDifficulty = 2.5,
        organSlots = { skin = "chitin_skin", bone = "chitin_bone", muscle = "human_muscle" },
        subSlots = {},
        naturalWeapon = "stinger_sting",
    },
}

-- All damage types in the game, for reference - physical and (now that
-- we're going sci-fi) energy alike. untyped is the odd one out: it never
-- gets a resistance multiplier of any kind, for stuff like bleeding that
-- doesn't cleanly fit a "real" type. toxic is poison's own damage type - a
-- real one (unlike untyped), just one nothing resists yet.
local damageTypes = { "bludgeoning", "piercing", "slashing", "fire", "frost", "radiation", "toxic", "untyped" }

-- Every coverage zone (a body part category - see partEntries' `zone`) and
-- the finer-grained areas within it. Areas only matter for apparel-vs-
-- apparel overlap (two things on the same layer can't both claim an area);
-- damage reduction itself only cares about the zone as a whole, since the
-- engine doesn't track hit location any finer than "which part got hit."
-- Note: "belt" here is a coverage area (a waist accessory slot), unrelated
-- to the combat belt slots.
local COVERAGE_AREAS = {
    head = { "face", "head", "neck" },
    torso = { "upper_body", "lower_body", "pelvis", "belt" },
    arms = { "upper_arm", "lower_arm" },
    hands = { "hand" },
    legs = { "upper_leg", "lower_leg" },
    feet = { "foot" },
    tail = { "upper_tail", "lower_tail" },
}

-- Reverse lookup: which zone a given area belongs to.
local AREA_TO_ZONE = {}
for zone, areas in pairs(COVERAGE_AREAS) do
    for _, area in ipairs(areas) do
        AREA_TO_ZONE[area] = zone
    end
end

-- Status effects can be applied to a single part (an injury like a fracture)
-- or to the whole character (a body-wide condition like adrenaline).
--
-- duration counts down by one every full round; -1 means permanent (needs
-- explicit removal instead, which nothing does yet). `stacks` controls what
-- happens when the same status gets applied again on top of an existing
-- one: true duration (stacks unset/false) takes the higher of the two,
-- while a stacking status (like bleed) adds them together instead.
--
-- damagePerStack names a damage type dealt equal to the current duration,
-- once per round, right before it decrements - that's how bleed works: each
-- "stack" is really just a turn of duration that hurts on its way out.
local statusEntries = {
    fracture = { scope = "part", modifiers = { strength = 0.5 }, duration = -1 },
    adrenaline = { scope = "character", ignoresCondition = true, duration = 1 },
    bleed = { scope = "part", duration = 1, stacks = true, damagePerStack = "untyped" },
    poison = { scope = "part", duration = 1, stacks = true, damagePerStack = "toxic" },
}

-- Verb for reporting a damagePerStack tick - keyed by statusId since
-- "bleeds" wouldn't make sense for poison. Falls back to a generic phrase
-- for any future damagePerStack status that doesn't bother adding its own.
local DOT_VERBS = {
    bleed = "bleeds",
    poison = "is poisoned",
}

-- Weapons have a damage range rather than a flat number, since real weapons
-- will vary; fists just happen to have min == max for now. `type` is a plain
-- field rather than a tag - tags are for binary presence/absence, and this is
-- meaningfully more than that (it decides whether STRENGTH even applies).
-- range is a hard cap (a square, not a circle - cheap and simple): beyond it
-- the attack isn't available at all. spread is a per-tile-of-distance hit
-- chance penalty, applied on top of the aim/reflex roll; melee weapons only
-- feel it if they have reach beyond range 1 (a flail, say), since at range 1
-- there are zero tiles between attacker and target.
local weaponEntries = {
    -- The generic bare-handed attack any MANIPULATE limb falls back to when
    -- nothing (or nothing anymore) is equipped there. Named generically
    -- ("Strike") rather than "Fist" since not every species punches with a
    -- fist specifically.
    strike = { name = "Strike", damage = { min = 10, max = 10 }, type = "melee", range = 1, spread = 0, damageType = "bludgeoning", handedness = "one-handed" },

    -- `itemId` is what lets a weapon exist outside a hand at all - the
    -- carryable, inventory-and-bulk-having form it becomes when unequipped
    -- (see itemEntries below), looked up by the inventory screen's
    -- equip-slot swapping. Strike has none - it's never a real, droppable
    -- item, just what an empty hand always falls back to.
    chain_sword = { name = "Chain Sword", damage = { min = 15, max = 25 }, type = "melee", range = 1, spread = 0, damageType = "slashing", handedness = "one-handed", abilities = { "rev_it_up" }, itemId = "chain_sword" },
    laser_pistol = {
        name = "Laser Pistol",
        damage = { min = 10, max = 15 },
        type = "ranged",
        range = 5,
        spread = 2,
        damageType = "fire",
        handedness = "one-handed",
        ammoCapacity = 10,
        ammoPerShot = 1,
        ammoClass = "energy",
        abilities = { "charge_shot" },
        itemId = "laser_pistol",
    },

    -- A natural weapon (see partEntries.stinger), not equipment - barely
    -- any direct damage, but onHit below stacks a hefty dose of poison on
    -- every landed hit.
    stinger_sting = { name = "Sting", damage = { min = 1, max = 1 }, type = "melee", range = 1, spread = 0, damageType = "piercing", handedness = "one-handed" },

    -- The first two-handed weapon: needs both of a wielder's hands (see
    -- the inventory screen's pickWieldingHands, and getWieldingHands/
    -- getWeaponStrength for how combat reads a weapon spanning two of
    -- them), which is what earns it a full action to fire instead of a
    -- pistol's quick one - and, as the tradeoff for that, real stopping
    -- power: roughly double a pistol's damage per shot, plus better range
    -- and a steadier aim (lower spread) from being braced two-handed
    -- rather than held out at arm's length.
    rifle = {
        name = "Rifle",
        damage = { min = 20, max = 30 },
        type = "ranged",
        range = 8,
        spread = 1,
        damageType = "piercing",
        handedness = "two-handed",
        ammoCapacity = 12,
        ammoPerShot = 1,
        ammoClass = "kinetic",
        abilities = { "spray" },
        itemId = "rifle",
    },

    -- The first `imprecise` weapon (see engine.pickAttack/engine.pickWeightedPart) -
    -- there's no limb to pick at all, just one roll for whether the whole
    -- spread connects (at the generic aimDifficulty-1 chance every weapon's
    -- own preview line already shows), then `pellets` separate rolls for
    -- which part each one happens to catch, weighted by the inverse of that
    -- part's own aimDifficulty - a part that's already hard to aim for on
    -- purpose is also less likely to catch a stray pellet by chance. `damage`
    -- is read per-pellet here, not per-shot, so the real payout is `pellets`
    -- times this range - roughly double a rifle's already-high average, at
    -- the cost of a much shorter range and spread heavy enough to make that
    -- range mostly theoretical (an all-or-nothing miss on the whole volley,
    -- not just a per-pellet penalty). Grants no ability of its own the usual
    -- way - see abilityEntries.special_shot and itemEntries.slug_round for
    -- what it does instead.
    shotgun = {
        name = "Shotgun",
        damage = { min = 5, max = 9 },
        type = "ranged",
        range = 8,
        spread = 6,
        imprecise = true,
        pellets = 8,
        damageType = "piercing",
        handedness = "two-handed",
        ammoCapacity = 6,
        ammoPerShot = 1,
        ammoClass = "shotgun",
        abilities = { "special_shot" },
        itemId = "shotgun",
    },
}

-- A chain sword bites deep and keeps bleeding; a sting is barely a scratch
-- on its own, but 5 stacks of poison at once is a real threat over the next
-- few rounds. `onHit(target)` is called with the part that just got hit.
weaponEntries.chain_sword.onHit = function(target)
    Luadventure.applyPartStatus(target, "bleed", 2)
end
weaponEntries.stinger_sting.onHit = function(target)
    Luadventure.applyPartStatus(target, "poison", 5)
end

-- Carried items, Pathfinder-style: bulk is a plain number, except 0.1
-- ("Light") which displays as "L" instead. `abilities` works exactly like
-- an organ's or weapon's: anything in the belt grants whatever it lists.
-- Unlike a reusable organ/weapon ability, using an item-granted ability
-- consumes it from the belt instead of starting a cooldown - that's
-- handled generically by the engine, keyed off whether the ability entry
-- came from an item.
local itemEntries = {
    dermoregenesis_salve = {
        name = "Dermoregenesis Salve",
        bulk = 1,
        abilities = { "use_dermoregenesis_salve" },
    },

    -- A belt item, same as the salve above - never equipped, just thrown
    -- straight from the belt via Throw Grenade. `range` is how far it can
    -- be lobbed (see engine.pickThrowTarget), `radius` how far its blast
    -- reaches from wherever it lands (engine.gridDistance, same metric
    -- weapon range/spread already use); `damage`/`damageType` are read by
    -- engine.resolvePendingGrenade, not by a weapon's own Fight
    -- resolution - a grenade throw is its own action, not an attack roll
    -- against a chosen limb.
    grenade = {
        name = "Grenade",
        bulk = 1,
        abilities = { "throw_grenade" },
        range = 4,
        radius = 2,
        damage = { min = 20, max = 35 },
        damageType = "bludgeoning",
    },

    -- A weapon's carryable form - `weaponId` is what tells the inventory
    -- screen "moving this into an equip slot means wielding that weapon",
    -- the reverse of the weapon's own `itemId` (used going the other way,
    -- putting a *displaced* weapon back into the bag). Name is duplicated
    -- from the weapon entry rather than looked up, same as any other item.
    chain_sword = { name = "Chain Sword", bulk = 2, weaponId = "chain_sword" },
    laser_pistol = { name = "Laser Pistol", bulk = 1, weaponId = "laser_pistol" },
    rifle = { name = "Rifle", bulk = 4, weaponId = "rifle" },
    shotgun = { name = "Shotgun", bulk = 4, weaponId = "shotgun" },

    -- Kinetic ammo: a bullet is one shot, plain and simple, reloaded exactly
    -- like you'd expect - pull however many are missing from the gun out of
    -- inventory.
    bullet = { name = "Bullet", bulk = 0.1, ammoClass = "kinetic" },

    -- Shotgun shells are their own ammo class - different enough from a
    -- bullet or a charge to deserve one - but reload the exact same way,
    -- one shell in inventory per shot of capacity regained (see
    -- engine.getAmmoItemId).
    shotgun_shell = { name = "Shotgun Shell", bulk = 0.1, ammoClass = "shotgun" },

    -- A "special" shell: never loaded into the gun's ordinary ammo pool at
    -- all (no ammoClass - engine.getAmmoItemId/engine.reloadWeapon never
    -- see it), just a loose reserve round the Special Shot ability (see
    -- abilityEntries.special_shot) picks straight out of inventory and
    -- fires on its own, one at a time. `specialAmmoFor` is what makes it
    -- show up in that picker (engine.pickSpecialAmmo) at all - matched
    -- against a weapon id, not an ammo class, since a special round is
    -- its own one-off thing rather than a fungible restock. A slug is a
    -- single solid piece of metal rather than a shell full of pellets -
    -- real single-target stopping power (`damage`, read by
    -- special_shot's own effect rather than the weapon's ordinary
    -- per-pellet one) and `ignoresEndurance` (a target's flat damage-
    -- reduction shrug, see engine.damagePart) to sell "armor-piercing",
    -- at the cost of drawing (and paying for) each one individually
    -- rather than just topping up a magazine.
    slug_round = {
        name = "Slug Round",
        bulk = 0.3,
        specialAmmoFor = "shotgun",
        damage = { min = 35, max = 50 },
        ignoresEndurance = true,
    },

    -- Energy ammo is fudged, since we can't store a partial charge on a
    -- single stateful "battery" item without a bigger inventory rework.
    -- Instead: energy_charge is one shot, just like a bullet, except it
    -- weighs nothing (0 bulk) - a battery doesn't hold charges at all, it
    -- just raises how many energy_charge items you're allowed to carry by
    -- chargeCapacity each, which is what actually keeps two batteries'
    -- worth of charges at a svelte 0.2 Bulk instead of the 2.0 Bulk the
    -- same twenty shots would cost as bullets.
    battery = { name = "Battery", bulk = 0.1, ammoClass = "energy", chargeCapacity = 10 },
    energy_charge = { name = "Energy Charge", bulk = 0, ammoClass = "energy" },

    -- Apparel: `layer` is "inner" or "outer" (can't stack two of the same
    -- layer over overlapping areas), `covers` is which areas it claims, and
    -- `coverage` is flat damage reduction per type, applied to whichever
    -- zone(s) those areas belong to. Ballistic armor covers the three
    -- physical types; a shield-type item would instead lean on energy
    -- types like fire/radiation.
    padded_shirt = {
        name = "Padded Shirt", bulk = 1, layer = "inner",
        covers = { "upper_body", "lower_body" },
        coverage = { bludgeoning = 2, piercing = 1, slashing = 1 },
    },
    ballistic_vest = {
        name = "Ballistic Vest", bulk = 2, layer = "outer",
        covers = { "upper_body" },
        coverage = { bludgeoning = 5, piercing = 8, slashing = 5 },
    },
    helmet = {
        name = "Helmet", bulk = 1, layer = "outer",
        covers = { "head" },
        coverage = { bludgeoning = 4, piercing = 3, slashing = 3 },
    },
}

-- Abilities can come from anything the combatant is holding, carrying, or
-- has installed in them - organs, equipped weapons, and belt items all
-- grant them. `speed` is one of "full" (the default - takes the whole
-- turn), "quick" (half a turn), or "instant" (doesn't cost anything).
-- `cooldown` is turns before it can be used again, tracked per-combatant -
-- item-granted abilities ignore this and get consumed instead. `effect` is
-- given (user, opponent, sourcePart, sourceSlot) and can return "noop"
-- (didn't actually do anything, e.g. out of range - don't spend the turn)
-- or "miss" (attack rolled, but didn't land - spend the turn, but refund
-- the cooldown); anything else resolves normally at whatever speed this
-- ability is. Killing the opponent needs no special signal - the engine
-- checks the scene for survivors at the start of every turn regardless of
-- what killed them.
local abilityEntries = {
    adrenaline_shot = {
        name = "Adrenal Auto-Injector",
        speed = "instant",
        cooldown = 5,
    },
    rev_it_up = {
        name = "Rev it up!",
        speed = "full", -- a committed special attack, not a quick one
        cooldown = 3,
    },
    use_dermoregenesis_salve = {
        name = "Use Dermoregenesis Salve",
        speed = "quick", -- most item interactions are
    },
    charge_shot = {
        name = "Charge Shot",
        speed = "full", -- always, even wielded one-handed - no cooldown to offset it
    },
    spray = {
        name = "Spray",
        speed = "full", -- the rifle's own normal shot already is, being two-handed
        cooldown = 3,
    },
    special_shot = {
        name = "Special Shot",
        speed = "full", -- the shotgun's own normal shot already is, being two-handed
        -- No cooldown at all - the real constraint is stocking special
        -- shells in the first place (see itemEntries.slug_round), not
        -- waiting one out.
    },
    throw_grenade = {
        name = "Throw Grenade",
        speed = "quick", -- the throw itself is quick; the blast is delayed, not the action
    },
}

abilityEntries.adrenaline_shot.effect = function(user)
    Luadventure.applyCharacterStatus(user, "adrenaline")
    Luadventure.logCombat("You use the Adrenal Auto-Injector!")
end

-- A special attack in its own right rather than an instant buff: one single
-- swing (one hit roll) that, on a hit, saws through the target for five
-- separate 5-10 damage instances (still STRENGTH-scaled, still slashing),
-- each triggering the chain sword's onHit individually - five landed cuts
-- stacks a full ten bleed. It's one swing, not five, so a miss is a miss
-- for the whole thing; the engine refunds the cooldown in that case (see
-- the "miss" return below), since revving up for nothing shouldn't cost you
-- the same as connecting. Melee range still applies, same as any other
-- attack with this weapon.
abilityEntries.rev_it_up.effect = function(user, enemy, sourcePart)
    local weapon = weaponEntries.chain_sword
    local distance = Luadventure.gridDistance(user.gridX, user.gridY, enemy.gridX, enemy.gridY)

    if distance > weapon.range then
        Luadventure.logCombat("Nothing is in range.")
        return "noop"
    end

    local target, label = Luadventure.pickLimb("Target the " .. enemy.name .. "'s:", enemy.body)
    if not target then
        return "noop"
    end
    Luadventure.combatState.redrawPanes()
    local hitChance = Luadventure.getFinalHitChance(user, enemy, weapon, distance, target)

    if math.random() > hitChance then
        Luadventure.logCombat("You rev up your Chain Sword and swing at the " .. enemy.name .. "'s " .. label .. "... You miss!")
        return "miss"
    end

    local strength = user.stats.strength * Luadventure.getLimbStrength(user, sourcePart)
    Luadventure.logCombat("The Chain Sword saws through the " .. enemy.name .. "'s " .. label .. "!")

    local totalDealt = 0
    for i = 1, 5 do
        if Luadventure.isDead(enemy.body) then
            break
        end

        local roll = math.random(5, 10)
        local raw = math.floor(roll * strength + 0.5)
        local dealt = Luadventure.damagePart(enemy, target, raw, weapon.damageType)
        if weapon.onHit then
            weapon.onHit(target)
        end
        totalDealt = totalDealt + dealt
        Luadventure.logCombat("Cut " .. i .. " deals " .. dealt .. "!")
        Luadventure.combatState.flash(enemy.gridX, enemy.gridY, "E")
    end

    Luadventure.logCombat("You dealt " .. totalDealt .. " damage to the " .. enemy.name .. "'s " .. label .. "!")
end

-- Heals yourself, not the opponent - a wound-tending action, not an attack.
-- `enemy` is only ever real when this is called mid-fight (the inventory
-- screen's own "use immediately" doesn't have one at all) - used here
-- purely to decide how to report the result, not for anything about the
-- heal itself.
abilityEntries.use_dermoregenesis_salve.effect = function(user, enemy)
    local target, label = Luadventure.pickLimb("Target your own:", user.body)
    if not target then
        return "noop"
    end
    local healed = Luadventure.healPart(target, 25)
    if enemy then
        Luadventure.combatState.redrawPanes()
        Luadventure.logCombat("You apply the salve to your " .. label .. "! Healed " .. healed .. " (" .. target.health .. "/" .. target.maxHealth .. ")")
    else
        -- Outside a fight there's no combat log to report to - this goes
        -- to the overworld's activity log instead.
        Luadventure.logActivity(Luadventure.dialogue("{{name}} used the Dermoregenesis Salve on {{him}}self.", user))
        Luadventure.logActivity(Luadventure.dialogue("{{name}} healed for " .. healed .. ".", user))
    end
end

-- A single heavy shot: double a normal shot's damage, three shots of ammo,
-- no cooldown to make up for always costing the full turn. Fires (and
-- burns ammo) whether it hits or not, same as an ordinary shot.
local CHARGE_SHOT_AMMO_COST = 3

abilityEntries.charge_shot.effect = function(user, enemy, sourcePart, sourceSlot)
    local weapon = weaponEntries.laser_pistol
    local distance = Luadventure.gridDistance(user.gridX, user.gridY, enemy.gridX, enemy.gridY)

    if distance > weapon.range then
        Luadventure.logCombat("Nothing is in range.")
        return "noop"
    end

    if (user.ammo[sourceSlot] or 0) < CHARGE_SHOT_AMMO_COST then
        Luadventure.logCombat("Not enough ammo to charge a shot.")
        return "noop"
    end

    local target, label = Luadventure.pickLimb("Target the " .. enemy.name .. "'s:", enemy.body)
    if not target then
        return "noop"
    end
    Luadventure.combatState.redrawPanes()
    local hitChance = Luadventure.getFinalHitChance(user, enemy, weapon, distance, target)
    local hitPercent = math.floor(hitChance * 100 + 0.5)

    user.ammo[sourceSlot] = user.ammo[sourceSlot] - CHARGE_SHOT_AMMO_COST

    Luadventure.logCombat("You charge the Laser Pistol and fire at the " .. enemy.name .. "'s " .. label .. " (" .. hitPercent .. "% to hit)...")

    if math.random() > hitChance then
        Luadventure.logCombat("You miss!")
        return
    end

    local roll = math.random(weapon.damage.min, weapon.damage.max)
    local dealt = Luadventure.damagePart(enemy, target, roll * 2, weapon.damageType)

    Luadventure.logCombat("The charged shot hits for " .. dealt .. "! (" .. target.health .. "/" .. target.maxHealth .. ")")
    Luadventure.combatState.flash(enemy.gridX, enemy.gridY, "E")
end

-- Three separate shots at one target, each its own hit roll (not one roll
-- covering all three the way Rev it up!'s single swing does - a spray is
-- three separate trigger pulls, so three separate chances to actually
-- connect), each at a small accuracy penalty for the sake of speed over
-- precision. Ammo burns per shot fired regardless of whether it lands,
-- same as an ordinary one; unlike Charge Shot there's no single roll to
-- gate the whole thing on, so this always resolves at its full cooldown
-- once it actually starts firing - some rounds landing and some missing
-- is the point, not an edge case to refund.
local SPRAY_SHOTS = 3
local SPRAY_ACCURACY_PENALTY = 0.1

abilityEntries.spray.effect = function(user, enemy, sourcePart, sourceSlot)
    local weapon = weaponEntries.rifle
    local distance = Luadventure.gridDistance(user.gridX, user.gridY, enemy.gridX, enemy.gridY)

    if distance > weapon.range then
        Luadventure.logCombat("Nothing is in range.")
        return "noop"
    end

    if (user.ammo[sourceSlot] or 0) < SPRAY_SHOTS then
        Luadventure.logCombat("Not enough ammo to spray.")
        return "noop"
    end

    local target, label = Luadventure.pickLimb("Target the " .. enemy.name .. "'s:", enemy.body)
    if not target then
        return "noop"
    end
    Luadventure.combatState.redrawPanes()

    Luadventure.logCombat("You spray the " .. enemy.name .. "'s " .. label .. " with the Rifle!")

    local totalDealt = 0
    for i = 1, SPRAY_SHOTS do
        if Luadventure.isDead(enemy.body) then
            break
        end

        user.ammo[sourceSlot] = user.ammo[sourceSlot] - 1
        local hitChance = math.max(0, Luadventure.getFinalHitChance(user, enemy, weapon, distance, target) - SPRAY_ACCURACY_PENALTY)

        if math.random() > hitChance then
            Luadventure.logCombat("Shot " .. i .. " misses!")
        else
            local roll = math.random(weapon.damage.min, weapon.damage.max)
            local dealt = Luadventure.damagePart(enemy, target, roll, weapon.damageType)
            totalDealt = totalDealt + dealt
            Luadventure.logCombat("Shot " .. i .. " deals " .. dealt .. "!")
            Luadventure.combatState.flash(enemy.gridX, enemy.gridY, "E")
        end
    end

    Luadventure.logCombat("You dealt " .. totalDealt .. " damage to the " .. enemy.name .. "'s " .. label .. "!")
end

-- The shotgun's whole "special attack" is that it doesn't really have one
-- - no cooldown to wait out, just whether there's still a special shell
-- (see itemEntries.slug_round) actually in the bag. Luadventure.pickSpecialAmmo
-- surfaces every distinct one carried (matched by `specialAmmoFor`, not a
-- fixed ammo class - a special round is a one-off pull from inventory,
-- never the gun's ordinary loaded pool); picking one, then a limb same as
-- any other precise attack, fires that single shell on its own terms
-- (its own `damage`, and `ignoresEndurance` if it sets that) rather than
-- the weapon's usual per-pellet spread.
abilityEntries.special_shot.effect = function(user, enemy, sourcePart, sourceSlot)
    local weapon = weaponEntries.shotgun
    local distance = Luadventure.gridDistance(user.gridX, user.gridY, enemy.gridX, enemy.gridY)

    if distance > weapon.range then
        Luadventure.logCombat("Nothing is in range.")
        return "noop"
    end

    local shellId = Luadventure.pickSpecialAmmo(user, "shotgun", "Fire which shell?")
    Luadventure.combatState.redrawPanes()
    if not shellId or shellId == "back" then
        return "noop"
    end
    local shell = itemEntries[shellId]

    local target, label = Luadventure.pickLimb("Target the " .. enemy.name .. "'s:", enemy.body)
    if not target then
        return "noop"
    end
    Luadventure.combatState.redrawPanes()
    local hitChance = Luadventure.getFinalHitChance(user, enemy, weapon, distance, target)
    local hitPercent = math.floor(hitChance * 100 + 0.5)

    -- The shell's spent the instant it's chambered, hit or miss - same
    -- "firing burns it either way" rule ordinary ammo follows.
    Luadventure.removeInventoryItems(user, shellId, 1)

    Luadventure.logCombat("You load a " .. shell.name .. " into the " .. weapon.name .. " and fire at the " .. enemy.name .. "'s " .. label .. " (" .. hitPercent .. "% to hit)...")

    if math.random() > hitChance then
        Luadventure.logCombat("You miss!")
        return "miss"
    end

    local roll = math.random(shell.damage.min, shell.damage.max)
    local dealt = Luadventure.damagePart(enemy, target, roll, weapon.damageType, shell.ignoresEndurance)

    Luadventure.logCombat("It punches through for " .. dealt .. "! (" .. target.health .. "/" .. target.maxHealth .. ")")
    Luadventure.combatState.flash(enemy.gridX, enemy.gridY, "E")
end

-- Doesn't target the enemy at all - a grenade goes wherever it's aimed
-- (Luadventure.pickThrowTarget, a whole different picker than every other
-- ability here: a reticle on the real map instead of a limb list), and
-- doesn't deal any damage itself either - Luadventure.queuePendingGrenade
-- just registers where it's going to land; engine.resolvePendingGrenade is
-- what actually detonates it, one full enemy turn later (see the design
-- doc's "Grenades" section for why). The item itself is consumed the
-- usual way for a belt-granted ability (see engine.collectAbilities) the
-- instant it's thrown, whether or not it ever gets to go off.
abilityEntries.throw_grenade.effect = function(user, enemy, sourcePart, sourceSlot)
    if Luadventure.combatState.pendingGrenade then
        Luadventure.logCombat("You've already got one in the air.")
        return "noop"
    end

    local grenade = itemEntries.grenade
    local tx, ty = Luadventure.pickThrowTarget(grenade.range)
    if not tx then
        return "noop"
    end
    Luadventure.combatState.redrawPanes()

    Luadventure.queuePendingGrenade(tx, ty, grenade.radius, grenade.damage, grenade.damageType)
    Luadventure.logCombat("You lob the grenade toward (" .. tx .. ", " .. ty .. "). It'll go off after this round.")
end

-- Every species a character can be built as. `build(globalTags)` returns a
-- fresh body (a torso with everything attached) - see Luadventure.newTorso/
-- .attachPart/.installCategoryOrgan/.installGenericOrgan/.recalcGlobalTags
-- for the primitives to build one from scratch, or reuse
-- Luadventure.newHumanBody/.newInsectoidBody as a starting point.
-- `statAdjustments` are flat, one-time deltas applied to character.stats
-- once at creation - the same granularity as character creation's own
-- +5%-per-point stat allocation, just species-driven instead of
-- player-chosen. Adding a new species here also needs its id added to
-- SPECIES_ORDER in luadventure.lua, which decides the creation menu's
-- display order (Lua tables don't otherwise guarantee one).
local speciesEntries = {
    human = {
        name = "Human",
        build = function(globalTags) return Luadventure.newHumanBody(globalTags) end,
        statAdjustments = {},
    },
    insectoid = {
        name = "Insectoid",
        build = function(globalTags) return Luadventure.newInsectoidBody(globalTags) end,
        statAdjustments = { reflex = -0.05 },
    },
}

--[[
    The world map. Each named location is a room: a walkable grid
    (width/height), which `objects` sit on it (items, walls, doors, people,
    save points, enemies - see luadventure.lua's rendering/interaction code
    for the full kind list), and `directions` naming which other location
    exiting off an edge leads to. Nothing here calls into the engine at
    all - it's plain data, read by the engine rather than driving it.
--]]
-- Both rooms grew from a snug 7x5 to a real 40x30 to give the camera and
-- (once it lands) the room-sealing/line-of-sight system something
-- meaningful to work with - placeholder-quality layouts for now (walls,
-- a door, a building), not narrative content. A real story and a
-- from-scratch starting area are their own separate thing later.
local world = {
    village = {
        name = "Village",
        directions = { right = "grasslands" },
        width = 40,
        height = 30,
        -- * is an item, auto-collected the moment the player steps onto
        -- it; !/?/0 are people (quest not yet taken / quest active /
        -- nothing more to say); $ is a save point - `saveId` is how a
        -- save file remembers which one made it.
        objects = {
            { kind = "item", x = 12, y = 12, itemId = "bullet" },
            { kind = "person", x = 10, y = 8, name = "Old Soldier", questId = "test_the_dummy" },
            { kind = "person", x = 18, y = 20, name = "Villager",
              greeting = { "\"Nice weather we're having, isn't it?\"" } },
            { kind = "person", x = 5, y = 25, name = "Villager", greetingId = "villager_gossip" },
            { kind = "person", x = 6, y = 25, name = "Villager", greetingId = "villager_gossip" },

            -- A small terminal building, walled and doored - a save
            -- point genuinely worth walking into rather than just
            -- another open-ground object, and a sealed room the
            -- line-of-sight system can actually seal once it lands.
            { kind = "wall", x1 = 30, y1 = 20, x2 = 36, y2 = 20 },
            { kind = "wall", x1 = 30, y1 = 26, x2 = 36, y2 = 26 },
            { kind = "wall", x1 = 30, y1 = 20, x2 = 30, y2 = 22 },
            { kind = "wall", x1 = 30, y1 = 24, x2 = 30, y2 = 26 },
            { kind = "wall", x1 = 36, y1 = 20, x2 = 36, y2 = 26 },
            { kind = "door", x = 30, y = 23, orientation = "vertical", open = false },
            { kind = "save_point", x = 33, y = 23, saveId = "village_terminal" },
        },
    },

    -- A walled arena with a door in it, hiding the test dummy in a back
    -- area - keeps it out of the way of ordinary exploration, but still
    -- right there to spar with whenever we want to test something.
    grasslands = {
        name = "Grasslands",
        directions = { left = "village" },
        width = 40,
        height = 30,
        objects = {
            { kind = "wall", x1 = 20, y1 = 10, x2 = 30, y2 = 10 },
            { kind = "wall", x1 = 20, y1 = 20, x2 = 30, y2 = 20 },
            { kind = "wall", x1 = 20, y1 = 10, x2 = 20, y2 = 14 },
            { kind = "wall", x1 = 20, y1 = 16, x2 = 20, y2 = 20 },
            { kind = "door", x = 20, y = 15, orientation = "vertical", open = false },
            -- A window in the east wall, opposite the entrance - lets
            -- anyone outside see the dummy waiting in here without a
            -- door for it to walk through (see the engine's zone/
            -- visibility system: glass merges zones permanently, unlike
            -- a door's own open/closed state).
            { kind = "wall", x1 = 30, y1 = 10, x2 = 30, y2 = 14 },
            { kind = "window", x = 30, y = 15 },
            { kind = "wall", x1 = 30, y1 = 16, x2 = 30, y2 = 20 },
            { kind = "enemy", x = 25, y = 15 },
        },
    },
}

-- A quest's own definition: dialogue for each state, its completion check,
-- and what it hands over on turn-in. `nextQuestId` is what the giver's
-- questId becomes after that (nil = nothing more, they go quiet).
local questEntries = {
    test_the_dummy = {
        name = "Blunt the Blade",
        offerLines = {
            "\"That test dummy out back in the grasslands",
            "could use a good working-over. Rough it up",
            "for me, would you?\"",
        },
        activeLines = { "\"Still waiting on that test dummy...\"" },
        turnInLines = { "\"Ha! Knew you had it in you. Here, take this.\"" },
        isReady = function() return (Luadventure.player.killLog.test_dummy or 0) > 0 end,
        rewardItemId = "dermoregenesis_salve",
        nextQuestId = nil,
    },
}

-- Greetings that depend on live player state (rather than always showing
-- the same lines) can't just be a table sitting on the object - a save
-- captures the whole world snapshot as plain data, and a function isn't
-- serializable at all. So a dynamic greeting is a plain string id
-- (`greetingId`, same convention as questId/itemId/saveId) looked up in
-- here at interaction time instead - never stored on the object itself.
local dynamicGreetings = {
    -- Two villagers gossiping about the player right in front of them,
    -- without realizing {{subject}} can hear every word - functionally
    -- just two adjacent people who happen to say the exact same thing, not
    -- a real NPC-to-NPC conversation system. An UNSIGHTLY player (an
    -- insectoid's freaky-looking head, so far) gets gossiped about
    -- differently.
    villager_gossip = function()
        if Luadventure.player.globalTags.UNSIGHTLY then
            return {
                "\"Psst - have you seen {{name}}?\"",
                "\"Something about {{object}} just... unsettles",
                "me. Can't put my finger on why.\"",
            }
        end
        return {
            "\"Psst - have you heard about {{name}}?\"",
            "\"They say {{subject}} walked right up to that",
            "test dummy without blinking. Word is nothing",
            "rattles {{object}} one bit!\"",
        }
    end,
}

return {
    organEntries = organEntries,
    partEntries = partEntries,
    damageTypes = damageTypes,
    COVERAGE_AREAS = COVERAGE_AREAS,
    AREA_TO_ZONE = AREA_TO_ZONE,
    statusEntries = statusEntries,
    DOT_VERBS = DOT_VERBS,
    weaponEntries = weaponEntries,
    itemEntries = itemEntries,
    abilityEntries = abilityEntries,
    speciesEntries = speciesEntries,
    world = world,
    questEntries = questEntries,
    dynamicGreetings = dynamicGreetings,
}
