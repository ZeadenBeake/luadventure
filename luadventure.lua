-- Fuck it, why not? Sci-fi fantasy RPG game, in lua, designed for CraftOS.

local world = {} -- Gotta define this early...

-- A single, uniquely-named global for if I need one.
Luadventure = {

}

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
    -- abilityEntries, defined later once applyCharacterStatus exists).
    adrenal_auto_injector = { abilities = { "adrenaline_shot" } },
}

-- Library of every swappable bodypart template in the game. The torso is the
-- one part that's never swapped wholesale (see newTorso below) - everything
-- that attaches to it comes from here.
--
-- `zone` is which apparel coverage zone this part draws its protection from
-- (see COVERAGE_AREAS/getPartZone below) - horns, antennae, wings and
-- stingers can't be covered at all, so their templates just don't set one,
-- which makes them fall through to whatever zone their parent has instead.
local partEntries = {
    human_head = {
        tags = { MORTAL = true },
        health = 100,
        zone = "head",
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
    -- insectoid_features).
    insectoid_head = {
        tags = { MORTAL = true },
        health = 100,
        zone = "head",
        organSlots = { skin = "chitin_skin", bone = "chitin_bone", muscle = "human_muscle" },
        subSlots = {
            antennae = { requires = {} },
        },
    },

    -- Neither of these have a zone of their own, same reasoning as horn
    -- above - a stinger or antenna can't be covered by apparel, so they
    -- inherit whatever protects the part they're attached to instead.
    -- naturalWeapon marks a part as its own unarmed attack, separate from
    -- (and not requiring) MANIPULATE/equipped-gear - see pickAttack. Unlike
    -- a hand's weapon, it's never equipped and so can never be dropped or
    -- disarmed; destroying the stinger itself is the only way to disable it
    -- (see isLimbFunctional, which pickAttack already checks for everyone).
    stinger = {
        tags = {},
        health = 100,
        organSlots = { skin = "chitin_skin", bone = "chitin_bone", muscle = "human_muscle" },
        subSlots = {},
        naturalWeapon = "stinger_sting",
    },
    antenna = {
        tags = {},
        health = 100,
        organSlots = { skin = "chitin_skin", bone = "chitin_bone", muscle = "human_muscle" },
        subSlots = {},
    },
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
-- All damage types in the game, for reference - physical and (now that
-- we're going sci-fi) energy alike. Lasers will deal fire once they exist.
-- untyped is the odd one out: it never gets a resistance multiplier of any
-- kind, for stuff like bleeding that doesn't cleanly fit a "real" type.
-- toxic is poison's own damage type - a real one (unlike untyped), just one
-- nothing resists yet.
local damageTypes = { "bludgeoning", "piercing", "slashing", "fire", "frost", "radiation", "toxic", "untyped" }

-- Every coverage zone (a body part category - see partEntries' `zone`) and
-- the finer-grained areas within it. Areas only matter for apparel-vs-
-- apparel overlap (two things on the same layer can't both claim an area -
-- see canWearItem); damage reduction itself only cares about the zone as a
-- whole (see getCoverage), since we don't track hit location any finer than
-- "which part got hit." Note: "belt" here is a coverage area (a waist
-- accessory slot), unrelated to the combat belt slots.
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
-- or to the whole character (a body-wide condition like adrenaline). A
-- part-scoped status is just another source of the same organ-style
-- `modifiers`, folded in wherever a limb's own contribution is computed.
-- A character-scoped status instead sets flags read by specific mechanics -
-- `ignoresCondition` is the only one so far, read by getConditionMultiplier.
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

-- Verb for reporting a damagePerStack tick (see applyDamageOverTime) -
-- keyed by statusId since "bleeds" wouldn't make sense for poison. Falls
-- back to a generic phrase for any future damagePerStack status that
-- doesn't bother adding its own.
local DOT_VERBS = {
    bleed = "bleeds",
    poison = "is poisoned",
}

-- chain_sword's onHit is attached later, once applyPartStatus exists (see
-- below the organ/status install functions) - can't reference it yet here.
-- handedness determines an attack's action speed: one-handed weapons are a
-- quick action, freeing up the rest of your turn; two-handed weapons (none
-- yet) are a full action, the tradeoff being room for much bigger numbers.
-- ammoCapacity/ammoClass mark a weapon as needing ammo at all (melee
-- weapons just don't have these fields); ammoPerShot is how many rounds a
-- normal shot burns, in case a future weapon needs something other than 1.
-- Current ammo lives per-combatant in .ammo (see character:new), keyed by
-- equip slot - never on the weapon entry itself, since that's a shared
-- template every wielder of this weapon would otherwise be reading/draining
-- from together.
local weaponEntries = {
    -- The generic bare-handed attack any MANIPULATE limb falls back to when
    -- nothing (or nothing anymore - see the inventory's equip slots) is
    -- equipped there. Named generically ("Strike") rather than "Fist" since
    -- not every species punches with a fist specifically.
    strike = { name = "Strike", damage = { min = 10, max = 10 }, type = "melee", range = 1, spread = 0, damageType = "bludgeoning", handedness = "one-handed" },

    -- `itemId` is what lets a weapon exist outside a hand at all - the
    -- carryable, inventory-and-bulk-having form it becomes when unequipped
    -- (see itemEntries), looked up by the inventory screen's equip-slot
    -- swapping. Strike has none - it's never a real, droppable item, just
    -- what an empty hand always falls back to.
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
    -- any direct damage, but onHit (attached below once applyPartStatus
    -- exists) stacks a hefty dose of poison on every landed hit.
    stinger_sting = { name = "Sting", damage = { min = 1, max = 1 }, type = "melee", range = 1, spread = 0, damageType = "piercing", handedness = "one-handed" },
}

-- Carried items, Pathfinder-style: bulk is a plain number, except 0.1
-- ("Light") which displays as "L" instead - see formatBulk. `abilities`
-- works exactly like an organ's or weapon's: anything in the belt grants
-- whatever it lists. Unlike a reusable organ/weapon ability, using an
-- item-granted ability consumes it from the belt instead of starting a
-- cooldown - that's handled generically in runEncounter, keyed off whether
-- collectAbilities tagged the entry with an itemId.
local itemEntries = {
    dermoregenesis_salve = {
        name = "Dermoregenesis Salve",
        bulk = 1,
        abilities = { "use_dermoregenesis_salve" },
    },

    -- A weapon's carryable form - `weaponId` is what tells the inventory
    -- screen "moving this into an equip slot means wielding that weapon",
    -- the reverse of the weapon's own `itemId` (used going the other way,
    -- putting a *displaced* weapon back into the bag). Name is duplicated
    -- from the weapon entry rather than looked up, same as any other item.
    chain_sword = { name = "Chain Sword", bulk = 2, weaponId = "chain_sword" },
    laser_pistol = { name = "Laser Pistol", bulk = 1, weaponId = "laser_pistol" },

    -- Kinetic ammo: a bullet is one shot, plain and simple, reloaded exactly
    -- like you'd expect - pull however many are missing from the gun out of
    -- inventory.
    bullet = { name = "Bullet", bulk = 0.1, ammoClass = "kinetic" },

    -- Energy ammo is fudged, since we can't store a partial charge on a
    -- single stateful "battery" item without a bigger inventory rework.
    -- Instead: energy_charge is one shot, just like a bullet, except it
    -- weighs nothing (0 bulk) - a battery doesn't hold charges at all, it
    -- just raises how many energy_charge items you're allowed to carry by
    -- chargeCapacity each (see getMaxEnergyCharges), which is what actually
    -- keeps two batteries' worth of charges at a svelte 0.2 Bulk instead of
    -- the 2.0 Bulk the same twenty shots would cost as bullets.
    battery = { name = "Battery", bulk = 0.1, ammoClass = "energy", chargeCapacity = 10 },
    energy_charge = { name = "Energy Charge", bulk = 0, ammoClass = "energy" },

    -- Apparel: `layer` is "inner" or "outer" (can't stack two of the same
    -- layer over overlapping areas - see canWearItem), `covers` is which
    -- areas it claims, and `coverage` is flat damage reduction per type,
    -- applied to whichever zone(s) those areas belong to (see getCoverage).
    -- Ballistic armor covers the three physical types; a shield-type item
    -- would instead lean on energy types like fire/radiation.
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

-- Tags in here exist for engine bookkeeping only and should never be shown on
-- normal player-facing UI (e.g. gating body access during a tutorial).
local metaTags = {
    TUTORIAL_LOCK = true,
}

local function isMetaTag(tag)
    return metaTags[tag] == true
end

local function shallowCopySet(set)
    local copy = {}
    for k, v in pairs(set or {}) do copy[k] = v end
    return copy
end

-- A part's *local* tags are its own inherent tags plus whatever's granted by
-- every organ currently installed in it, hardcoded category slots and
-- generic slots alike.
local function getPartLocalTags(part)
    local tags = shallowCopySet(part.tags)
    for _, organId in pairs(part.organs) do
        for _, tag in ipairs(organEntries[organId].grantsLocal or {}) do
            tags[tag] = true
        end
    end
    for _, organId in ipairs(part.genericOrgans) do
        for _, tag in ipairs(organEntries[organId].grantsLocal or {}) do
            tags[tag] = true
        end
    end
    return tags
end

local function walkBody(part, fn)
    fn(part)
    for _, sub in pairs(part.subSlots) do
        if sub then walkBody(sub, fn) end
    end
end

-- Global tags are gathered from every organ anywhere on the body that grants
-- one. Call this again after installing/removing any organ that touches
-- globals - it isn't tracked incrementally.
local function recalcGlobalTags(torso)
    local tags = {}
    walkBody(torso, function(part)
        for _, organId in pairs(part.organs) do
            for _, tag in ipairs(organEntries[organId].grantsGlobal or {}) do
                tags[tag] = true
            end
        end
        for _, organId in ipairs(part.genericOrgans) do
            for _, tag in ipairs(organEntries[organId].grantsGlobal or {}) do
                tags[tag] = true
            end
        end
    end)
    return tags
end

-- Tag presence is checked against local and global tags identically - the two
-- namespaces are assumed never to overlap, so there's nothing to disambiguate.
local function tagsSatisfied(requiredTags, localTags, globalTags)
    for _, tag in ipairs(requiredTags or {}) do
        if not (localTags[tag] or globalTags[tag]) then
            return false
        end
    end
    return true
end

local function tagsAbsent(forbiddenTags, localTags, globalTags)
    for _, tag in ipairs(forbiddenTags or {}) do
        if localTags[tag] or globalTags[tag] then
            return false
        end
    end
    return true
end

local function instantiatePart(templateId)
    local template = partEntries[templateId] or error("Unknown part template: " .. tostring(templateId), 2)
    local organs = {}
    for category, organId in pairs(template.organSlots or {}) do
        organs[category] = organId
    end
    return {
        template = templateId,
        tags = shallowCopySet(template.tags),
        health = template.health,
        maxHealth = template.health,
        zone = template.zone,
        organs = organs,
        genericOrgans = {},
        statuses = {},
        subSlotDefs = template.subSlots or {},
        subSlots = {},
    }
end

local function newTorso()
    return {
        template = "torso",
        tags = { MORTAL = true },
        health = 100,
        maxHealth = 100,
        zone = "torso",
        organs = {
            skin = "human_skin",
            bone = "human_bone",
            muscle = "human_muscle",
            vitals = "human_vitals",
            auxiliary = "human_auxiliary",
        },
        genericOrgans = {},
        statuses = {},
        subSlotDefs = {
            head = { requires = {} },
            left_arm = { requires = {} },
            right_arm = { requires = {} },
            left_leg = { requires = {} },
            right_leg = { requires = {} },
            left_arm_2 = { requires = { "MULTI_LIMBED" } },
            right_arm_2 = { requires = { "MULTI_LIMBED" } },
            left_wing = { requires = { "WINGED" } },
            right_wing = { requires = { "WINGED" } },
            tail = { requires = { "TAILED" } },
        },
        subSlots = {},
    }
end

-- Attaches a whole new part into one of a parent part's sub-slots (a hand into
-- an arm, a leg into the torso, ...). Fails if the slot is tag-locked.
local function attachPart(parent, slotName, templateId, globalTags)
    local slotDef = parent.subSlotDefs[slotName] or error("No such slot: " .. slotName, 2)
    local localTags = getPartLocalTags(parent)
    if not tagsSatisfied(slotDef.requires, localTags, globalTags) then
        return false, "slot locked"
    end
    local child = instantiatePart(templateId)
    child.parent = parent
    parent.subSlots[slotName] = child
    return true
end

-- Swaps the organ filling one of a part's hardcoded category slots.
local function installCategoryOrgan(part, category, organId, globalTags)
    local organDef = organEntries[organId] or error("Unknown organ: " .. tostring(organId), 2)
    local localTags = getPartLocalTags(part)
    if not tagsSatisfied(organDef.requires, localTags, globalTags) then
        return false, "missing required tag"
    end
    if not tagsAbsent(organDef.conflicts, localTags, globalTags) then
        return false, "conflicting tag present"
    end
    part.organs[category] = organId
    return true
end

-- Installs an organ into the next free generic (cybernetic) slot.
local function installGenericOrgan(part, organId, globalTags)
    local organDef = organEntries[organId] or error("Unknown organ: " .. tostring(organId), 2)
    local localTags = getPartLocalTags(part)
    if not tagsSatisfied(organDef.requires, localTags, globalTags) then
        return false, "missing required tag"
    end
    if not tagsAbsent(organDef.conflicts, localTags, globalTags) then
        return false, "conflicting tag present"
    end
    table.insert(part.genericOrgans, organId)
    return true
end

-- Captures a body part's mutable state (health, installed organs, statuses)
-- plus its shape (template id, subSlots), recursively - for save games.
-- Deliberately drops `parent` (a back-reference, which would make this a
-- cycle) and `subSlotDefs`/`tags`/`zone` (all three come straight back off
-- the template on reload, via instantiatePart/newTorso, so saving them too
-- would just be redundant and risks going stale if templates ever change).
local function serializeBodyPart(part)
    local organs = {}
    for category, organId in pairs(part.organs) do
        organs[category] = organId
    end
    local genericOrgans = {}
    for i, organId in ipairs(part.genericOrgans) do
        genericOrgans[i] = organId
    end
    local statuses = {}
    for statusId, duration in pairs(part.statuses) do
        statuses[statusId] = duration
    end
    local subSlots = {}
    for slotName, sub in pairs(part.subSlots) do
        subSlots[slotName] = serializeBodyPart(sub)
    end
    return {
        template = part.template,
        health = part.health,
        maxHealth = part.maxHealth,
        rootLabel = part.rootLabel, -- only ever set on the root; nil elsewhere
        endurance = part.endurance, -- a species trait, not template-derived (see newInsectoidBody) - nil for anyone without one
        organs = organs,
        genericOrgans = genericOrgans,
        statuses = statuses,
        subSlots = subSlots,
    }
end

-- Rebuilds a body part (and everything attached below it) from
-- serializeBodyPart's output. The root is always a fresh torso; every other
-- part is re-instantiated from its own template rather than trusting saved
-- shape data directly, so a loaded body can't desync from what a freshly
-- created one would look like. Bypasses attachPart's slot-lock checks on
-- purpose - the save already proves this exact tree once existed.
local function deserializeBodyPart(data, isRoot)
    local part = isRoot and newTorso() or instantiatePart(data.template)
    part.health = data.health
    part.maxHealth = data.maxHealth
    part.rootLabel = data.rootLabel
    part.endurance = data.endurance
    part.organs = {}
    for category, organId in pairs(data.organs) do
        part.organs[category] = organId
    end
    part.genericOrgans = {}
    for i, organId in ipairs(data.genericOrgans) do
        part.genericOrgans[i] = organId
    end
    part.statuses = {}
    for statusId, duration in pairs(data.statuses) do
        part.statuses[statusId] = duration
    end
    part.subSlots = {}
    for slotName, childData in pairs(data.subSlots) do
        local child = deserializeBodyPart(childData, false)
        child.parent = part
        part.subSlots[slotName] = child
    end
    return part
end

-- Combines a fresh application with whatever's already active: -1
-- (permanent) always wins outright; otherwise a stacking status adds the
-- two together, while a true-duration status just takes the higher one.
local function combineDuration(existing, incoming, stacks)
    if existing == nil then
        return incoming
    end
    if existing == -1 or incoming == -1 then
        return -1
    end
    if stacks then
        return existing + incoming
    end
    return math.max(existing, incoming)
end

-- No requires/conflicts gating here (unlike organs) - statuses are applied
-- by game logic (injuries, conditions, consumables), not chosen by a player
-- picking from a compatible list. `amount` overrides the status's own
-- default duration/dose (e.g. the chain sword applying 2 stacks of bleed
-- instead of bleed's baseline 1), and combines with any existing instance
-- per that status's own stacking rule.
local function applyPartStatus(part, statusId, amount)
    local def = statusEntries[statusId]
    part.statuses[statusId] = combineDuration(part.statuses[statusId], amount or def.duration, def.stacks)
end

local function applyCharacterStatus(combatant, statusId, amount)
    local def = statusEntries[statusId]
    combatant.statuses[statusId] = combineDuration(combatant.statuses[statusId], amount or def.duration, def.stacks)
end

-- Attached here rather than in weaponEntries itself, since applyPartStatus
-- didn't exist yet up there: a chain sword bites deep and keeps bleeding.
weaponEntries.chain_sword.onHit = function(target)
    applyPartStatus(target, "bleed", 2)
end

-- Barely a scratch on its own, but 5 stacks of poison at once is a real
-- threat over the next few rounds.
weaponEntries.stinger_sting.onHit = function(target)
    applyPartStatus(target, "poison", 5)
end

-- Ticks every active status on a combatant (itself and every part of its
-- body) down by one round, removing anything that hits 0. Permanent (-1)
-- statuses are left untouched. Called once a full round has actually
-- elapsed - an instant ability doesn't trigger this, since the turn hasn't
-- ended yet.
local function decrementStatuses(combatant)
    local function tick(statuses)
        for statusId, duration in pairs(statuses) do
            if duration > 0 then
                if duration == 1 then
                    statuses[statusId] = nil
                else
                    statuses[statusId] = duration - 1
                end
            end
        end
    end
    tick(combatant.statuses)
    walkBody(combatant.body, function(part)
        tick(part.statuses)
    end)
end

-- Same idea as decrementStatuses, but for ability cooldowns - those are
-- character-wide only, never part-scoped.
local function decrementCooldowns(combatant)
    for abilityId, remaining in pairs(combatant.cooldowns) do
        if remaining <= 1 then
            combatant.cooldowns[abilityId] = nil
        else
            combatant.cooldowns[abilityId] = remaining - 1
        end
    end
end

-- Abilities can come from anything the combatant is holding, carrying, or
-- has installed in them - organs, equipped weapons, and belt items all
-- grant them. `speed` is one of "full" (the default - takes the whole
-- turn), "quick" (half a turn - see the action-economy comment above
-- runEncounter), or "instant" (doesn't cost anything, same as it always
-- has). `cooldown` is turns before it can be used again, tracked per-
-- combatant in `cooldowns` (see character:new) - item-granted abilities
-- ignore this and get consumed instead (see the itemId handling in
-- runEncounter). `effect` is attached down near runEncounter instead of
-- here, once showCombatMessage/pickLimb/etc actually exist - it's given
-- (user, opponent, sourcePart) and can return "noop" (didn't actually do
-- anything, e.g. out of range - don't spend the turn) or "miss" (attack
-- rolled, but didn't land - spend the turn, but refund the cooldown);
-- anything else resolves normally at whatever speed this ability is. Killing
-- the opponent needs no special signal - runEncounter checks the scene for
-- survivors at the start of every turn regardless of what killed them.
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
}

-- Unlike tags, numeric modifiers (like STRENGTH) flow up through a part's
-- ancestors - a reinforced upper arm makes the hand attached to it hit
-- harder, not just the arm itself.
local function getOwnModifier(part, key)
    local mult = 1
    for _, organId in pairs(part.organs) do
        local m = organEntries[organId].modifiers
        if m and m[key] then mult = mult * m[key] end
    end
    for _, organId in ipairs(part.genericOrgans) do
        local m = organEntries[organId].modifiers
        if m and m[key] then mult = mult * m[key] end
    end
    for statusId in pairs(part.statuses) do
        local status = statusEntries[statusId]
        if status.scope == "part" and status.modifiers and status.modifiers[key] then
            mult = mult * status.modifiers[key]
        end
    end
    return mult
end

local function getAncestorMultiplier(part, key)
    local mult = 1
    local current = part
    while current do
        mult = mult * getOwnModifier(current, key)
        current = current.parent
    end
    return mult
end

-- The apparel coverage zone that protects this part. Most parts just have
-- their own (see partEntries); an exposed one (horns, antennae, wings, a
-- stinger) never sets one at all, so this walks up to the nearest ancestor
-- that does - a horn on the head is protected exactly as well as the head
-- itself, never independently covered.
local function getPartZone(part)
    local current = part
    while current do
        if current.zone then
            return current.zone
        end
        current = current.parent
    end
    return nil
end

-- True if the combatant has any active character-scoped status that flags
-- condition as ignored (adrenaline: full strength regardless of injury,
-- until a part is destroyed outright).
local function hasIgnoreCondition(combatant)
    for statusId in pairs(combatant.statuses) do
        local status = statusEntries[statusId]
        if status.scope == "character" and status.ignoresCondition then
            return true
        end
    end
    return false
end

-- 1 for full health, 0.5 for half health, etc - unless the combatant is
-- running on adrenaline, in which case it's pinned at 1 until the part is
-- actually destroyed (0 health), at which point even adrenaline can't help.
local function getConditionMultiplier(combatant, part)
    if part.health <= 0 then
        return 0
    end
    if hasIgnoreCondition(combatant) then
        return 1
    end
    return part.health / part.maxHealth
end

-- A limb's effective strength: walk the same ancestor chain as
-- getAncestorMultiplier, but fold in each ancestor's own condition right
-- alongside its own organ/status modifier - a damaged (or fractured) upper
-- arm should weaken a punch the same way either way, not just via organs.
-- This is what actually feeds the STRENGTH and REFLEX stats now, rather
-- than raw condition or raw organ bonus alone.
local function getLimbStrength(combatant, part)
    local strength = 1
    local current = part
    while current do
        strength = strength * getOwnModifier(current, "strength") * getConditionMultiplier(combatant, current)
        current = current.parent
    end
    return strength
end

-- True once any MORTAL-tagged part (torso, head, ...) has hit 0 health.
local function isDead(torso)
    local dead = false
    walkBody(torso, function(part)
        if getPartLocalTags(part).MORTAL and part.health <= 0 then
            dead = true
        end
    end)
    return dead
end

-- A destroyed limb takes everything attached to it down with it - a
-- destroyed arm can't attack, and neither can a perfectly healthy hand
-- still hanging off the end of it. Checked by both pickAttack (unarmed or
-- otherwise) and weapon-granted abilities.
local function isLimbFunctional(part)
    local current = part
    while current do
        if current.health <= 0 then
            return false
        end
        current = current.parent
    end
    return true
end

-- Gives a child slot a side-qualified label when its parent has one, so e.g.
-- the "hand" slot under "left_arm" is reported as "left_hand" rather than two
-- indistinguishable "hand" entries.
local function partLabel(parentLabel, slotName)
    local side = parentLabel:match("^(left)_") or parentLabel:match("^(right)_")
    if side and not slotName:match("^left_") and not slotName:match("^right_") then
        return side .. "_" .. slotName
    end
    return slotName
end

-- Flat list of every part in the body tree, each with a human-readable
-- label and its depth from the torso (0), e.g. for picking a random target,
-- listing limbs to attack, or indenting a limb picker like a folder tree.
-- The walk already visits a part's own children immediately after it and
-- before any sibling's subtree, so this is already in proper depth-first
-- tree order - nothing needed there, just carrying the depth along.
-- `torso.rootLabel` lets a species call the root part something other than
-- "torso" (an insectoid's is an abdomen) without changing anything about
-- how it actually works structurally.
local function collectLabeledParts(torso)
    local parts = {}
    local function walk(part, label, depth)
        table.insert(parts, { label = label, part = part, depth = depth })
        for slotName, sub in pairs(part.subSlots) do
            if sub then
                walk(sub, partLabel(label, slotName), depth + 1)
            end
        end
    end
    walk(torso, torso.rootLabel or "torso", 0)
    return parts
end

-- Carrying capacity: 10x average limb strength across the whole body, plus
-- whatever flat bonus equipment grants (backpacks etc - none exist yet, but
-- bulkBonus is where they'd add in).
local function getAverageLimbStrength(combatant)
    local parts = collectLabeledParts(combatant.body)
    local total = 0
    for _, entry in ipairs(parts) do
        total = total + getLimbStrength(combatant, entry.part)
    end
    return total / #parts
end

local function getBulkCapacity(combatant)
    return 10 * getAverageLimbStrength(combatant) + combatant.bulkBonus
end

-- "Light" bulk (0.1) displays as L rather than a fraction; anything else is
-- just the plain number.
local function formatBulk(bulk)
    if bulk == 0.1 then
        return "L"
    end
    return tostring(bulk)
end

-- Total bulk currently carried, belt and main inventory both counting
-- toward the same cap - the belt doesn't grant extra capacity, just a
-- combat-usable place to keep a few things.
local function getTotalBulk(combatant)
    local total = 0
    for _, itemId in ipairs(combatant.inventory) do
        total = total + itemEntries[itemId].bulk
    end
    for i = 1, combatant.beltSize do
        local itemId = combatant.belt[i]
        if itemId then
            total = total + itemEntries[itemId].bulk
        end
    end
    return total
end

-- How many of a given item id are carried (inventory + belt).
local function countCarriedItem(combatant, itemId)
    local count = 0
    for _, id in ipairs(combatant.inventory) do
        if id == itemId then count = count + 1 end
    end
    for i = 1, combatant.beltSize do
        if combatant.belt[i] == itemId then count = count + 1 end
    end
    return count
end

-- The energy_charge cap: batteries don't hold charges (see itemEntries),
-- they just each raise how many charges you're allowed to be carrying.
-- Nothing enforces this yet since there's no way to acquire loose ammo
-- besides the initial loadout, but it's here for whenever that exists.
local function getMaxEnergyCharges(combatant)
    return countCarriedItem(combatant, "battery") * itemEntries.battery.chargeCapacity
end

-- Removes up to `amount` of a given item id from a combatant's inventory
-- (never the belt - ammo isn't something you'd keep there). Returns how
-- many were actually removed.
local function removeInventoryItems(combatant, itemId, amount)
    local removed = 0
    for i = #combatant.inventory, 1, -1 do
        if removed >= amount then break end
        if combatant.inventory[i] == itemId then
            table.remove(combatant.inventory, i)
            removed = removed + 1
        end
    end
    return removed
end

-- Which item id a weapon's ammo class actually consumes on a reload.
local function getAmmoItemId(weapon)
    if weapon.ammoClass == "kinetic" then
        return "bullet"
    elseif weapon.ammoClass == "energy" then
        return "energy_charge"
    end
    return nil
end

-- Tops a weapon up from inventory: pulls in whatever's missing (or as much
-- of it as inventory actually has), one ammo item per shot of capacity
-- regained - bullets and energy_charges both work exactly the same way
-- here, that's the whole point of fudging energy ammo into discrete units.
-- Returns how many shots were actually loaded.
local function reloadWeapon(combatant, slot)
    local weapon = weaponEntries[combatant.equipped[slot]]
    local missing = weapon.ammoCapacity - (combatant.ammo[slot] or 0)
    local loaded = removeInventoryItems(combatant, getAmmoItemId(weapon), missing)
    combatant.ammo[slot] = (combatant.ammo[slot] or 0) + loaded
    return loaded
end

-- Ammo can't ride along with a weapon the way it would in real life -
-- there's no way to attach per-instance data to an item sitting in the
-- inventory, only a fixed count per named slot (character.ammo, keyed by
-- an equip slot's own label or a belt slot's synthetic "beltN" one - see
-- the inventory screen). So rather than pretend otherwise, `amount` units
-- of a weapon's ammo just convert into loose ammo items in the inventory.
-- A no-op if the weapon doesn't use ammo at all (or there's no weapon).
local function depositAmmo(combatant, weaponId, amount)
    local weapon = weaponEntries[weaponId]
    if not weapon or not weapon.ammoCapacity or not amount or amount <= 0 then
        return
    end
    local ammoItemId = getAmmoItemId(weapon)
    for _ = 1, amount do
        table.insert(combatant.inventory, ammoItemId)
    end
end

-- Unequipping a weapon (for any reason - swapping it out, a destroyed
-- hand, eventually looting an enemy's gun) spills whatever it had loaded
-- back into the inventory (see depositAmmo) and clears the slot's count -
-- whatever ends up there next reloads from scratch, same as picking up a
-- stranger's weapon in real life would need to.
local function returnAmmoToInventory(combatant, weaponId, ammoKey)
    depositAmmo(combatant, weaponId, combatant.ammo[ammoKey])
    combatant.ammo[ammoKey] = nil
end

-- True if wearing this item wouldn't put it on the same layer as, and
-- overlapping any area with, something already worn - clothing can't
-- overlap. Not wired into any live "wear it" action yet (nothing offers one
-- this turn), but it's the rule anything that does add one should call.
local function canWearItem(combatant, itemId)
    local item = itemEntries[itemId]
    for _, wornId in ipairs(combatant.worn) do
        local worn = itemEntries[wornId]
        if worn.layer == item.layer then
            for _, area in ipairs(item.covers) do
                for _, wornArea in ipairs(worn.covers) do
                    if area == wornArea then
                        return false, wornId
                    end
                end
            end
        end
    end
    return true
end

-- Total coverage protecting one specific area, for one damage type: every
-- worn item that covers this exact area contributes its coverage (inner and
-- outer both - protection from both layers stacks).
local function getAreaCoverage(combatant, area, damageType)
    local total = 0
    for _, itemId in ipairs(combatant.worn) do
        local item = itemEntries[itemId]
        for _, coveredArea in ipairs(item.covers or {}) do
            if coveredArea == area then
                total = total + (item.coverage and item.coverage[damageType] or 0)
                break
            end
        end
    end
    return total
end

-- A part's effective coverage is the *average* protection across every
-- relevant area in its zone, not the coverage of whatever happens to cover
-- any one area of it - a vest that only covers the upper body doesn't fully
-- protect the whole torso, it just raises the average, with the bare
-- pelvis/lower body dragging it back down. "belt" is excluded from the
-- torso average - that area is reserved for expanding combat belt slots,
-- not body armor.
local function getCoverage(combatant, part, damageType)
    local zone = getPartZone(part)
    if not zone then
        return 0
    end
    local total, count = 0, 0
    for _, area in ipairs(COVERAGE_AREAS[zone]) do
        if area ~= "belt" then
            total = total + getAreaCoverage(combatant, area, damageType)
            count = count + 1
        end
    end
    if count == 0 then
        return 0
    end
    return total / count
end

-- Applies damage to a single part, adjusted by that part's own resistance to
-- the given damage type (1 if the part doesn't specify one) - except
-- untyped, which never gets a resistance multiplier of any kind, full stop -
-- then by `endurance` (a flat percentage, e.g. an insectoid's chitin shell
-- at 0.1 - unlike resistance, this one applies to every damage type with no
-- exception, untyped included), and then by the owner's worn coverage
-- against that type, as a flat reduction. Returns the actual amount
-- applied, post-everything, so callers can report it honestly. Otherwise
-- doesn't do anything beyond tracking health yet - stat penalties for
-- damaged/destroyed limbs are a later concern. Only a MORTAL part reaching
-- 0 has any effect right now (see isDead).
local function damagePart(owner, part, amount, damageType)
    local resistance = 1
    if damageType ~= "untyped" then
        resistance = (part.resistances and part.resistances[damageType]) or 1
    end
    local endurance = part.endurance or 0
    local coverage = getCoverage(owner, part, damageType)
    local applied = math.max(0, math.floor(amount * resistance * (1 - endurance) - coverage + 0.5))
    part.health = math.max(0, part.health - applied)
    return applied
end

-- The healing counterpart to damagePart: never overheals past maxHealth,
-- returns the actual amount restored.
local function healPart(part, amount)
    local healed = math.min(amount, part.maxHealth - part.health)
    part.health = part.health + healed
    return healed
end

-- Runs once a round, before decrementStatuses: any part-scoped status with
-- damagePerStack (bleed, poison) deals damage equal to its *current* stack
-- count to its own part, using that status's own damage type. Returns a
-- list of {label, dealt, statusId} for whatever ticked, so the caller can
-- report it (statusId picks the right verb - see DOT_VERBS) - the actual
-- stack removal is decrementStatuses' ordinary decrement, run right after
-- this.
local function applyDamageOverTime(combatant)
    local ticks = {}
    for _, entry in ipairs(collectLabeledParts(combatant.body)) do
        for statusId, duration in pairs(entry.part.statuses) do
            local def = statusEntries[statusId]
            if def.damagePerStack and duration > 0 then
                local dealt = damagePart(combatant, entry.part, duration, def.damagePerStack)
                table.insert(ticks, { label = entry.label, dealt = dealt, statusId = statusId })
            end
        end
    end
    return ticks
end

-- Standard human body: torso plus the four default limbs, each with the
-- baseline human organ set already filling their hardcoded slots. Shared by
-- the player and any humanoid NPC.
local function newHumanBody(globalTags)
    globalTags = globalTags or {}
    local body = newTorso()
    attachPart(body, "head", "human_head", globalTags)
    attachPart(body, "left_arm", "human_arm", globalTags)
    attachPart(body, "right_arm", "human_arm", globalTags)
    attachPart(body, "left_leg", "human_leg", globalTags)
    attachPart(body, "right_leg", "human_leg", globalTags)
    attachPart(body.subSlots.left_arm, "hand", "human_hand", globalTags)
    attachPart(body.subSlots.right_arm, "hand", "human_hand", globalTags)
    attachPart(body.subSlots.left_leg, "foot", "human_foot", globalTags)
    attachPart(body.subSlots.right_leg, "foot", "human_foot", globalTags)
    return body
end

-- Insectoid body plan: an abdomen (same shape as a torso, just relabeled -
-- see collectLabeledParts) with chitin skin/bone, which is what unlocks its
-- tail (filled with a stinger) and wing slots (deliberately left empty -
-- nothing attaches there yet); a head with an antennae slot and an
-- inherent UNSIGHTLY global tag. Arms/legs/hands/feet are unchanged from
-- the human plan - nothing about this species is different there.
local function newInsectoidBody(globalTags)
    globalTags = globalTags or {}
    local body = newTorso()
    body.rootLabel = "abdomen"
    installCategoryOrgan(body, "skin", "chitin_skin", globalTags)
    installCategoryOrgan(body, "bone", "chitin_bone", globalTags)

    -- chitin_bone's global grants (TAILED, WINGED) need to be knowable
    -- right now to unlock the tail slot below, rather than waiting on the
    -- caller's own post-construction recalcGlobalTags pass.
    local unlockedTags = recalcGlobalTags(body)
    for tag in pairs(globalTags) do
        unlockedTags[tag] = true
    end

    attachPart(body, "head", "insectoid_head", unlockedTags)
    attachPart(body, "left_arm", "human_arm", unlockedTags)
    attachPart(body, "right_arm", "human_arm", unlockedTags)
    attachPart(body, "left_leg", "human_leg", unlockedTags)
    attachPart(body, "right_leg", "human_leg", unlockedTags)
    attachPart(body.subSlots.left_arm, "hand", "human_hand", unlockedTags)
    attachPart(body.subSlots.right_arm, "hand", "human_hand", unlockedTags)
    attachPart(body.subSlots.left_leg, "foot", "human_foot", unlockedTags)
    attachPart(body.subSlots.right_leg, "foot", "human_foot", unlockedTags)
    attachPart(body, "tail", "stinger", unlockedTags)
    attachPart(body.subSlots.head, "antennae", "antenna", unlockedTags)
    installGenericOrgan(body.subSlots.head, "insectoid_features", unlockedTags)

    -- The endurance side of chitin skin's tradeoff: not extra health, a
    -- flat 10% damage reduction on every hit (see damagePart) - applied to
    -- every part uniformly rather than baked into any one template, since
    -- most of these parts (arms/legs/hands/feet) are shared with the human
    -- body plan and shouldn't get it there. The reflex penalty side is
    -- applied separately, to the character stat itself - see speciesEntries.
    walkBody(body, function(part)
        part.endurance = 0.1
    end)

    return body
end

-- Every species a character can be built as. `build(globalTags)` mirrors
-- newHumanBody's own signature; `statAdjustments` are flat, one-time deltas
-- applied to character.stats once at creation - the same granularity as
-- character creation's own +5%-per-point stat allocation, just
-- species-driven instead of player-chosen.
local speciesEntries = {
    human = {
        name = "Human",
        build = newHumanBody,
        statAdjustments = {},
    },
    insectoid = {
        name = "Insectoid",
        build = newInsectoidBody,
        statAdjustments = { reflex = -0.05 },
    },
}

local location = {
    name = "",
    directions = {
        -- up = "somewhere"
        -- right = "somewhere_else"
        -- etc.
    }
}

function location:navigate(dir)
    if not dir then
        return self.directions
    else
        return world[self.directions[dir]]
    end
end

function location:new(
    o,
    name,
    locations, -- table of directions
    width, -- size of the walkable grid within this location
    height
)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o.name = name or error("Location must have a name!", 2)
    o.directions = locations or {}
    o.width = width or 7
    o.height = height or 5
    return o
end

local character = {
    stats = {
        level = 0,
        health = 100,
        max_health = 100, -- Modified by armor and possibly clothes
        dr = 0, -- Modified by some armors.
        defense = 5, -- Modified by armor.
        speed = 10, -- Modified by armor, usually negatively.
        weight = 0, -- How many things *currently* being held by the player.
        max_inventory = 5, -- Maximum things the player can carry, modified by clothes + possibly backpack
        strength = 1, -- Base multiplier for melee damage; a limb's own bonuses stack on top of this.
        aim = 1, -- Chance to hit is aim * (1 - target's reflex / 2); a busted head penalizes this.
        reflex = 1, -- Chance to be missed rides on this; worn-down legs penalize it.
    },
    inventory = {},
    equipped = {
        left_hand = "none",
        right_hand = "none",
        armor = "none",
        clothes = "basic_clothes", -- Default items don't take up inventory space and are always considered in the player's posession.
        backpack = "none"
    }
}

-- Generic character class used for anything that participates in combat.
function character:new(o, stats, inventory, equipped)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    
    -- Deep copy stats table
    o.stats = {}
    for k, v in pairs(stats or self.stats) do
        o.stats[k] = v
    end
    
    -- Deep copy inventory
    o.inventory = {}
    for i, v in ipairs(inventory or self.inventory) do
        o.inventory[i] = v
    end
    
    -- Deep copy equipped
    o.equipped = {}
    for k, v in pairs(equipped or self.equipped) do
        o.equipped[k] = v
    end

    -- Body-wide status effects (e.g. adrenaline) always start empty.
    o.statuses = {}

    -- Per-ability cooldowns (turns remaining before it can be used again).
    o.cooldowns = {}

    -- Belt: a fixed number of slots (indexed 1..beltSize, holes allowed)
    -- for items usable in combat, unlike the main inventory. bulkBonus is
    -- flat extra carrying capacity from equipment (backpacks etc, none yet).
    o.belt = {}
    o.beltSize = 1
    o.bulkBonus = 0

    -- Current loaded ammo per equip slot (e.g. o.ammo.right_hand), for
    -- whatever's equipped there and actually uses ammo. Empty until
    -- something's loaded.
    o.ammo = {}

    -- Currently worn apparel - a flat list of item ids (each item's own
    -- entry says what layer/areas it covers), same convention as inventory.
    o.worn = {}

    return o
end

local player = character:new()

-- Add player-specific fields
player.location = "village"
player.gridX = 1 -- Position within the current location's grid.
player.gridY = 1
player.steps = 0 -- Increments on every successful step, in or out of combat.

-- Overwritten by character creation (see runCharacterCreation, run once at
-- startup) - defaulted here so nothing reads a nil name/pronoun if that
-- somehow doesn't happen first.
player.name = "Adventurer"
player.pronouns = { subject = "they", object = "them" }

-- Per-quest progress ("active", "done" - not-yet-taken is just absent), and
-- a running tally of kills by typeId (see showVictoryScreen) - quest
-- completion conditions read these instead of a bespoke flag per encounter.
player.quests = {}
player.killLog = {}

-- Body/globalTags are built once species is actually chosen (see
-- runCharacterCreation, run once at startup, right before the first
-- render) - defaulted here only so nothing reads a nil body if that
-- somehow doesn't happen first.
player.globalTags = {}
player.body = newHumanBody(player.globalTags)

-- Starting loadout: a chain sword in the left hand, a laser pistol in the
-- right, starting fully loaded (reloading isn't built yet).
player.equipped.left_hand = "chain_sword"
player.equipped.right_hand = "laser_pistol"
player.ammo.right_hand = weaponEntries.laser_pistol.ammoCapacity

-- Test case for the inventory system: starts packed away, meant to be moved
-- to the belt (and then used) via the inventory bar.
table.insert(player.inventory, "dermoregenesis_salve")

-- Test case for reloading: one battery (raises the energy_charge cap to 10)
-- and a handful of spare charges for the laser pistol, well under that cap.
table.insert(player.inventory, "battery")
for _ = 1, 5 do
    table.insert(player.inventory, "energy_charge")
end

-- NPCs are, in the most literal sense, just non-player characters: the same
-- character base (stats/inventory/equipped) as the player, plus a body, a
-- grid position, and a decide() method. decide() reads the current board
-- state and returns a single action for its turn - each NPC *type* overrides
-- it (and its starting stats/loadout); character.new is reused directly as
-- the constructor since it already only cares about self.stats/inventory/
-- equipped, not which prototype self happens to be.
local npc = character:new()
npc.new = character.new

-- state = { self = this npc, player = player, distance = <cells apart> }.
-- Returns one of: {action="attack"}, {action="move", dx=, dy=}, {action="idle"}.
-- Base default just idles - every real NPC type overrides this.
function npc:decide(state)
    return { action = "idle" }
end

--[[
    So, worlds will work some funky ways.

    Entries in the world table are each a unique place. I don't need to fill in areas with lots of dead space since this is text-based,
    so that'll work fine. Each world has potential directions (up, down, left, right) and you can navigate them. I might make a "location"
    object that contains functions for this navigation, to let me define them fluidly.
--]]

world = {
    --[[
    village = {
        up = nil,
        down = nil,
        left = nil,
        right = "grasslands",
        name = "Village"
    },
    --]]
    village = location:new(
        nil,
        "Village",
        {
            right = "grasslands"
        }
    ),
    grasslands = location:new(
        nil,
        "Grasslands",
        {
            left = "village"
        }
    )
}

-- A quest's own definition: dialogue for each state, its completion check,
-- and what it hands over on turn-in. `nextQuestId` is what the giver's
-- questId becomes after that (nil = nothing more, they go quiet - see
-- getPersonSymbol/interactWithPerson).
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
        isReady = function() return (player.killLog.test_dummy or 0) > 0 end,
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
    -- just two adjacent people who happen to say the exact same thing (see
    -- dialogue()), rather than a real NPC-to-NPC conversation system. An
    -- UNSIGHTLY player (an insectoid's freaky-looking head, so far - see
    -- speciesEntries/insectoid_features) gets gossiped about differently.
    villager_gossip = function()
        if player.globalTags.UNSIGHTLY then
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

-- Environment interactions: * is an item, auto-collected (and logged, see
-- logActivity) the moment the player steps onto it - no blurb needed
-- anymore; # is a solid wall (just a rectangle); !/?/0 are people (quest
-- not yet taken / quest active / nothing more to say); -/| are doors
-- (horizontal/vertical), opened or closed with no prompt either (see
-- tryMove/tryInteract) and shown as `.` while open; $ is a save point -
-- `saveId` is how a save file remembers which one made it, so loading
-- knows where to put the player back (see findSavePointById).
world.village.objects = {
    { kind = "item", x = 3, y = 3, itemId = "bullet" },
    { kind = "person", x = 5, y = 2, name = "Old Soldier", questId = "test_the_dummy" },
    { kind = "person", x = 2, y = 4, name = "Villager",
      greeting = { "\"Nice weather we're having, isn't it?\"" } },
    { kind = "save_point", x = 6, y = 4, saveId = "village_terminal" },
    { kind = "person", x = 1, y = 5, name = "Villager", greetingId = "villager_gossip" },
    { kind = "person", x = 2, y = 5, name = "Villager", greetingId = "villager_gossip" },
}

-- A short wall with a door in it, hiding the test dummy in a small back
-- area - keeps it out of the way of ordinary exploration, but still right
-- there to spar with whenever we want to test something.
world.grasslands.objects = {
    { kind = "wall", x1 = 5, y1 = 1, x2 = 5, y2 = 2 },
    { kind = "door", x = 5, y = 3, orientation = "vertical", open = false },
    { kind = "wall", x1 = 5, y1 = 4, x2 = 5, y2 = 5 },
    { kind = "enemy", x = 6, y = 3 },
}

--[[
    Screen is split into four corners:
    top-left     - compact numeric stats
    top-right    - sprite/portrait (placeholder for now)
    bottom-left  - map/text/table area, currently the walkable grid
    bottom-right - activity log (see logActivity)
--]]

math.randomseed(os.time())

local screenW, screenH = term.getSize()
local topHeight = math.floor(screenH / 2)
local leftWidth = math.floor(screenW / 2)

local statsWin = window.create(term.current(), 1, 1, leftWidth, topHeight)
local spriteWin = window.create(term.current(), leftWidth + 1, 1, screenW - leftWidth, topHeight)
local mainWin = window.create(term.current(), 1, topHeight + 1, leftWidth, screenH - topHeight)

-- Where anything that happens outside of combat gets reported - simple
-- interactions (picking something up, opening/closing a door) don't
-- interrupt movement with a prompt anymore, so this is where their
-- feedback goes instead. See logActivity.
local logWin = window.create(term.current(), leftWidth + 1, topHeight + 1, screenW - leftWidth, screenH - topHeight)

-- Combat's "idle" state (waiting on the player's next action) gets the same
-- four-corner treatment as the overworld, rather than a single full-screen
-- window - map top-left, the action menu bottom-left, a scrolling combat
-- log top-right (see logCombat - routine events report here instead of
-- interrupting with a prompt), and the enemies in the scene bottom-right
-- (Tab cycles which one's selected - see drawEnemyList/promptAction).
local combatMapWin = window.create(term.current(), 1, 1, leftWidth, topHeight)
local combatLogWin = window.create(term.current(), leftWidth + 1, 1, screenW - leftWidth, topHeight)
local combatActionWin = window.create(term.current(), 1, topHeight + 1, leftWidth, screenH - topHeight)
local combatEnemyWin = window.create(term.current(), leftWidth + 1, topHeight + 1, screenW - leftWidth, screenH - topHeight)

-- A full-screen takeover, shared by combat's own sub-pickers (choosing an
-- attack, a limb, an ability, a reload/belt target), victory/death,
-- dialogue (showInteraction), and character creation - anything that needs
-- the player's full attention for a moment rather than coexisting with the
-- four-corner layout above.
local combatWin = window.create(term.current(), 1, 1, screenW, screenH)

-- The inventory is its own full-screen modal, same as combat - opening it
-- blocks the rest of the game entirely rather than coexisting with it, so
-- there's no need for it to share a window with anything else.
local inventoryWin = window.create(term.current(), 1, 1, screenW, screenH)

local message = ""

-- Breaks `text` into however many lines are needed to fit `maxWidth`,
-- breaking on word boundaries where possible - the pure logic behind both
-- writeWrapped (below) and the activity log, which needs the lines as data
-- (to keep in its own scrolling buffer) rather than written straight to a
-- window.
local function wrapText(text, maxWidth)
    local lines = {}
    while #text > maxWidth do
        local breakAt = maxWidth
        local spaceAt = text:sub(1, maxWidth):match(".*() ")
        if spaceAt and spaceAt > 1 then
            breakAt = spaceAt - 1
        end
        table.insert(lines, text:sub(1, breakAt))
        text = text:sub(breakAt + 1):gsub("^%s+", "")
    end
    table.insert(lines, text)
    return lines
end

-- Every wrapped line logged so far, oldest first - only the tail end that
-- actually fits gets drawn (see drawLog), so this can just grow forever
-- without needing to cap or scroll it manually.
local activityLog = {}

local function drawLog()
    logWin.setVisible(false)
    logWin.clear()
    local width, height = logWin.getSize()
    local startIndex = math.max(1, #activityLog - height + 1)
    for i = startIndex, #activityLog do
        logWin.setCursorPos(1, i - startIndex + 1)
        logWin.write(activityLog[i])
    end
    logWin.setVisible(true)
end

-- Reports something that happened outside of combat - wrapped to the log
-- pane's width and appended to the scrolling buffer. Combat has its own
-- full-screen messaging (showCombatMessage) and doesn't need this; this is
-- specifically for everything that used to need a "press any key" prompt
-- but really didn't (picking something up, a door opening) or is otherwise
-- worth a record of (using an item outside a fight).
local function logActivity(message)
    local width = logWin.getSize()
    for _, line in ipairs(wrapText(message, width)) do
        table.insert(activityLog, line)
    end
    drawLog()
end

-- {{token}} -> a bit of the given character's identity, for writing dialogue
-- without hardcoding whichever name/pronouns the player picked at character
-- creation. {{name}}, {{subject}}, and {{object}} are the real fields;
-- {{he}}/{{she}} and {{him}}/{{her}} are just aliases for subject/object, so
-- a line can be written with an imagined character in mind (he, she,
-- whichever reads naturally) and still come out in whoever's actually
-- playing. Unrecognized tokens are left alone rather than blanked out.
-- Moved up here (from beside showInteraction, which also uses it) so
-- logActivity's own callers - some of them well before that point in the
-- file - can use it too.
local DIALOGUE_ALIASES = {
    subject = "subject", he = "subject", she = "subject",
    object = "object", him = "object", her = "object",
}

local function dialogue(str, who)
    return (str:gsub("{{(%a+)}}", function(token)
        if token == "name" then
            return who.name
        end
        local field = DIALOGUE_ALIASES[token]
        if field then
            return who.pronouns[field]
        end
        return "{{" .. token .. "}}"
    end))
end

local function drawStats()
    statsWin.setVisible(false)
    statsWin.clear()
    statsWin.setCursorPos(1, 1)
    statsWin.write(player.name)
    statsWin.setCursorPos(1, 2)
    statsWin.write("HP " .. player.stats.health .. "/" .. player.stats.max_health)
    statsWin.setCursorPos(1, 3)
    statsWin.write("Lv " .. player.stats.level)
    statsWin.setCursorPos(1, 4)
    statsWin.write("Steps " .. player.steps)
    statsWin.setVisible(true)
end

local function drawSprite()
    spriteWin.setVisible(false)
    spriteWin.clear()
    spriteWin.setCursorPos(1, 1)
    spriteWin.write("[ no portrait ]")
    spriteWin.setVisible(true)
end

-- Finds whichever object occupies (x,y) - walls are checked by rectangle
-- containment rather than an exact match, everything else by exact
-- position. Shared by rendering and movement collision so they can never
-- disagree about what's actually there.
local function findObjectAt(loc, x, y)
    for _, obj in ipairs(loc.objects or {}) do
        if obj.kind == "wall" then
            if x >= obj.x1 and x <= obj.x2 and y >= obj.y1 and y <= obj.y2 then
                return obj
            end
        elseif obj.x == x and obj.y == y then
            return obj
        end
    end
    return nil
end

-- What a location object currently looks like on the map. Doors and people
-- change glyph over time (open vs closed, quest state); everything else is
-- fixed for its whole lifetime.
local function getObjectGlyph(obj)
    if obj.kind == "wall" then
        return "#"
    elseif obj.kind == "item" then
        return "*"
    elseif obj.kind == "enemy" then
        return "E"
    elseif obj.kind == "save_point" then
        return "$"
    elseif obj.kind == "door" then
        if obj.open then
            return "."
        end
        return obj.orientation == "horizontal" and "-" or "|"
    elseif obj.kind == "person" then
        if not obj.questId then
            return "0"
        end
        local quest = questEntries[obj.questId]
        if player.quests[obj.questId] == "active" then
            return quest.isReady() and "!" or "?"
        end
        return "!" -- not yet taken
    end
    return "?"
end

local function drawMain()
    local loc = world[player.location]

    mainWin.setVisible(false)
    mainWin.clear()
    mainWin.setCursorPos(1, 1)
    mainWin.write(loc.name)

    for y = 1, loc.height do
        local row = {}
        for x = 1, loc.width do
            if x == player.gridX and y == player.gridY then
                row[x] = "@"
            else
                local obj = findObjectAt(loc, x, y)
                row[x] = obj and getObjectGlyph(obj) or "."
            end
        end
        mainWin.setCursorPos(1, y + 1)
        mainWin.write(table.concat(row))
    end

    if message ~= "" then
        mainWin.setCursorPos(1, loc.height + 3)
        mainWin.write(message)
    end

    mainWin.setVisible(true)
end

local function render()
    drawStats()
    drawSprite()
    drawMain()
    -- Re-draws the log's corner from its own retained buffer - a full-
    -- screen modal (combat, the inventory) draws right over it, and
    -- toggling setVisible(true) alone is a no-op if it's already true, so
    -- this can't just reassert visibility; it has to actually redraw.
    drawLog()
end

-- A slim overlay strip - just the top two rows - for jumping straight to a
-- page (Inventory, so far) from ordinary exploration, without first
-- opening its full screen via `i`. Its own window, separate from
-- statsWin/spriteWin, so it can be shown deliberately overwriting the top
-- of the main UI - because that's exactly what it's doing, loading in on
-- top of whatever's already there - rather than needing to coexist with it.
local pageBarWin = window.create(term.current(), 1, 1, screenW, 2)
local TOP_BAR_PAGES = { "Inventory" }
local topBarPage = 1

local function drawTopBar()
    pageBarWin.setVisible(false)
    pageBarWin.clear()
    local tabs = {}
    for i, name in ipairs(TOP_BAR_PAGES) do
        table.insert(tabs, i == topBarPage and ("[" .. name .. "]") or (" " .. name .. " "))
    end
    pageBarWin.setCursorPos(1, 1)
    pageBarWin.write(table.concat(tabs, " "))
    pageBarWin.setCursorPos(1, 2)
    pageBarWin.write("[Enter] open  [Tab] close")
    pageBarWin.setVisible(true)
end

-- Generic "activate" key for the inventory - kept as its own variable so
-- it's a one-line change if enter turns out to be the wrong call.
local ACTIVATE_KEY = keys.enter

-- Moved up from beside pickAttack (which also uses it) so the inventory
-- screen's equip-slot detail panel can use it too.
local function formatDamageRange(range)
    if range.min == range.max then
        return tostring(range.min)
    end
    return range.min .. "-" .. range.max
end

-- Every MANIPULATE-tagged limb on a body, in the same stable depth-first
-- order collectLabeledParts already produces - the set of slots a weapon
-- can actually be equipped into (see the inventory's "equip" rows), rather
-- than a hardcoded pair of hands that wouldn't generalize to some future
-- multi-limbed species.
local function getManipulateLimbs(combatant)
    local limbs = {}
    for _, entry in ipairs(collectLabeledParts(combatant.body)) do
        if getPartLocalTags(entry.part).MANIPULATE then
            table.insert(limbs, entry)
        end
    end
    return limbs
end

-- A unified view of "a slot that can hold a weapon or a plain item" - a
-- hand (`{kind="equip", slot=label}`) or a belt slot
-- (`{kind="belt", index=N}`). Both the inventory screen and the in-combat
-- Belt action work with these, so what a slot holds and how it's read/
-- written lives in one place instead of two.

-- Every hand and belt slot, hands first, in the same stable order
-- getManipulateLimbs/1..beltSize already give.
local function getAllSlots(combatant)
    local slots = {}
    for _, limb in ipairs(getManipulateLimbs(combatant)) do
        table.insert(slots, { kind = "equip", slot = limb.label })
    end
    for i = 1, combatant.beltSize do
        table.insert(slots, { kind = "belt", index = i })
    end
    return slots
end

local function slotsEqual(a, b)
    return a.kind == b.kind and a.slot == b.slot and a.index == b.index
end

-- Whatever's in a slot: returns (weaponId, itemId) - at most one is ever
-- set, both nil if it's empty. A hand's own field (`equipped`) holds
-- either a weaponId or a plain itemId directly (disambiguated by which
-- table recognizes it - the two ids only ever collide when they *are* the
-- same thing, a weapon's own item form); a belt slot always holds an
-- itemId, which might itself represent a holstered weapon (`weaponId` on
-- the item entry) or a plain item.
local function getSlotContents(combatant, slotDescriptor)
    if slotDescriptor.kind == "equip" then
        local occupant = combatant.equipped[slotDescriptor.slot]
        if occupant == "none" or not occupant then
            return nil, nil
        elseif weaponEntries[occupant] then
            return occupant, nil
        end
        return nil, occupant
    else
        local itemId = combatant.belt[slotDescriptor.index]
        if not itemId then
            return nil, nil
        elseif itemEntries[itemId].weaponId then
            return itemEntries[itemId].weaponId, nil
        end
        return nil, itemId
    end
end

-- The character.ammo key a slot's own weapon (if it has one) is tracked
-- under - a hand's own label, or a belt slot's synthetic "beltN".
local function getSlotAmmoKey(slotDescriptor)
    if slotDescriptor.kind == "equip" then
        return slotDescriptor.slot
    end
    return "belt" .. slotDescriptor.index
end

-- Empties a slot and hands back whatever was in it (weaponId, itemId,
-- ammo) so the caller can decide where it goes - this never sends
-- anything to the inventory itself, see returnAmmoToInventory/
-- depositAmmo for that.
local function clearSlot(combatant, slotDescriptor)
    local weaponId, itemId = getSlotContents(combatant, slotDescriptor)
    local ammo = weaponId and combatant.ammo[getSlotAmmoKey(slotDescriptor)] or nil
    if weaponId then
        combatant.ammo[getSlotAmmoKey(slotDescriptor)] = nil
    end
    if slotDescriptor.kind == "equip" then
        combatant.equipped[slotDescriptor.slot] = "none"
    else
        combatant.belt[slotDescriptor.index] = nil
    end
    return weaponId, itemId, ammo
end

-- Fills an already-empty slot with a weapon (weaponId + ammo) or a plain
-- item (itemId) - exactly one of the two should be given. Doesn't displace
-- anything itself; clear the slot first (see clearSlot) if it might not be.
local function fillSlot(combatant, slotDescriptor, weaponId, itemId, ammo)
    if slotDescriptor.kind == "equip" then
        combatant.equipped[slotDescriptor.slot] = weaponId or itemId
        if weaponId then
            combatant.ammo[slotDescriptor.slot] = ammo
        end
    else
        combatant.belt[slotDescriptor.index] = weaponId and weaponEntries[weaponId].itemId or itemId
        if weaponId then
            combatant.ammo["belt" .. slotDescriptor.index] = ammo
        end
    end
end

-- Exchanges whatever's in two slots, ammo included for either side that's
-- a weapon - a true swap if both had something, just a move if one was
-- empty. Used for a deliberate reassignment (the Belt action) as well as
-- filling an empty slot from another one.
local function swapSlots(combatant, a, b)
    local aWeapon, aItem, aAmmo = clearSlot(combatant, a)
    local bWeapon, bItem, bAmmo = clearSlot(combatant, b)
    fillSlot(combatant, a, bWeapon, bItem, bAmmo)
    fillSlot(combatant, b, aWeapon, aItem, aAmmo)
end

-- Whether any currently-equipped weapon (either hand) actually uses ammo -
-- the action menu only shows Reload at all when this is true.
local function hasAmmoWeapon(combatant)
    for _, limb in ipairs(getManipulateLimbs(combatant)) do
        local weaponId = getSlotContents(combatant, { kind = "equip", slot = limb.label })
        if weaponId and weaponEntries[weaponId].ammoCapacity then
            return true
        end
    end
    return false
end

-- Every row the inventory list can show: belt slots (always, even empty),
-- one equip slot per MANIPULATE limb (showing whatever's wielded there, or
-- Strike if nothing is), that limb's ammo (only shown if what's equipped
-- there actually uses ammo), then main inventory items grouped by id with a
-- count - stackable stuff like energy charges would otherwise need one row
-- each. Each row carries enough to both render its own list line and build
-- a detail panel for it.
local function getInventoryRows(combatant)
    local rows = {}

    for i = 1, combatant.beltSize do
        local itemId = combatant.belt[i]
        if itemId then
            local item = itemEntries[itemId]
            local countText = "1"
            -- A holstered weapon (see the equip slots below - a belt slot
            -- can hold one too, ammo and all) shows its own loaded count
            -- instead of a flat "1", same convention as an ammo row.
            if item.weaponId and weaponEntries[item.weaponId].ammoCapacity then
                local weapon = weaponEntries[item.weaponId]
                countText = (combatant.ammo["belt" .. i] or 0) .. "/" .. weapon.ammoCapacity
            end
            table.insert(rows, {
                kind = "belt", index = i, itemId = itemId, weaponId = item.weaponId,
                name = "Belt: " .. item.name,
                countText = countText, bulkText = formatBulk(item.bulk),
            })
        else
            table.insert(rows, {
                kind = "belt", index = i, itemId = nil,
                name = "Belt: Empty", countText = "", bulkText = "",
            })
        end
    end

    for _, limb in ipairs(getManipulateLimbs(combatant)) do
        local weaponId, itemId = getSlotContents(combatant, { kind = "equip", slot = limb.label })
        if itemId then
            local item = itemEntries[itemId]
            table.insert(rows, {
                kind = "equip", slot = limb.label, itemId = itemId,
                name = limb.label .. ": " .. item.name,
                countText = "", bulkText = formatBulk(item.bulk),
            })
        else
            local weapon = weaponId and weaponEntries[weaponId] or weaponEntries.strike
            table.insert(rows, {
                kind = "equip", slot = limb.label, weaponId = weaponId,
                name = limb.label .. ": " .. weapon.name,
                countText = "", bulkText = "",
            })
            if weaponId and weapon.ammoCapacity then
                table.insert(rows, {
                    kind = "ammo", slot = limb.label, weapon = weapon,
                    name = weapon.name .. " Ammo",
                    countText = (combatant.ammo[limb.label] or 0) .. "/" .. weapon.ammoCapacity,
                    bulkText = "",
                })
            end
        end
    end

    local groups = {}
    for _, itemId in ipairs(combatant.inventory) do
        local group = groups[itemId]
        if not group then
            group = {
                kind = "inventory", itemId = itemId, count = 0,
                name = itemEntries[itemId].name, bulkText = formatBulk(itemEntries[itemId].bulk),
            }
            groups[itemId] = group
            table.insert(rows, group)
        end
        group.count = group.count + 1
    end
    for _, row in ipairs(rows) do
        if row.kind == "inventory" then
            row.countText = tostring(row.count)
        end
    end

    return rows
end

-- Keeps the selected row inside the visible window, scrolling the minimum
-- amount needed rather than always re-centering.
local function clampInventoryScroll(selection, scrollOffset, totalRows, visibleCount)
    if selection < scrollOffset + 1 then
        scrollOffset = selection - 1
    elseif selection > scrollOffset + visibleCount then
        scrollOffset = selection - visibleCount
    end
    return math.max(0, math.min(scrollOffset, math.max(0, totalRows - visibleCount)))
end

local INVENTORY_LIST_TOP = 4 -- row 1: title, row 2: page tabs, row 3: column headers

local function formatInventoryRow(name, countText, bulkText)
    return ("%-13s %-5s %-4s"):format(name:sub(1, 13), countText or "", bulkText or "")
end

-- Left half is the scrollable list (belt/ammo/inventory rows); right half is
-- detail on whatever's currently selected. Row 2 is the page-tab strip from
-- Tab - a skeleton for now (just the one "Inventory" page), meant for
-- whatever other pages come along later, exactly as originally pitched.
local function drawInventoryScreen(rows, selection, scrollOffset, pageBarVisible, currentPage, pages, carrying)
    inventoryWin.setVisible(false)
    inventoryWin.clear()

    local leftW = math.floor(screenW / 2)
    local rightX = leftW + 2

    inventoryWin.setCursorPos(1, 1)
    inventoryWin.write(carrying and ("Carrying: " .. carrying.name) or "Inventory")
    inventoryWin.setCursorPos(rightX, 1)
    inventoryWin.write(("Bulk %s/%s"):format(formatBulk(getTotalBulk(player)), formatBulk(getBulkCapacity(player))))

    if pageBarVisible then
        local tabs = {}
        for i, name in ipairs(pages) do
            table.insert(tabs, i == currentPage and ("[" .. name .. "]") or (" " .. name .. " "))
        end
        inventoryWin.setCursorPos(1, 2)
        inventoryWin.write(table.concat(tabs, " "))
    end

    inventoryWin.setCursorPos(1, 3)
    inventoryWin.write(formatInventoryRow("Name", "Count", "Bulk"))

    local visibleCount = screenH - 1 - INVENTORY_LIST_TOP + 1
    for i = 1, visibleCount do
        local row = rows[scrollOffset + i]
        if row then
            local marker = (scrollOffset + i == selection) and ">" or " "
            inventoryWin.setCursorPos(1, INVENTORY_LIST_TOP + i - 1)
            inventoryWin.write(marker .. formatInventoryRow(row.name, row.countText, row.bulkText))
        end
    end

    local selected = rows[selection]
    if selected then
        inventoryWin.setCursorPos(rightX, 3)
        inventoryWin.write(selected.name)

        local detail = {}
        if selected.kind == "belt" then
            if selected.weaponId then
                local weapon = weaponEntries[selected.weaponId]
                table.insert(detail, "Damage: " .. formatDamageRange(weapon.damage) .. " " .. weapon.damageType)
                table.insert(detail, "Range: " .. weapon.range)
                if weapon.ammoCapacity then
                    table.insert(detail, "Loaded: " .. selected.countText)
                end
                for _, abilityId in ipairs(weapon.abilities or {}) do
                    table.insert(detail, "Grants: " .. abilityEntries[abilityId].name)
                end
                table.insert(detail, "")
                table.insert(detail, "[Swap] to draw in combat")
            elseif selected.itemId then
                table.insert(detail, "Bulk: " .. formatBulk(itemEntries[selected.itemId].bulk))
                for _, abilityId in ipairs(itemEntries[selected.itemId].abilities or {}) do
                    table.insert(detail, "Grants: " .. abilityEntries[abilityId].name)
                end
            else
                table.insert(detail, "Empty belt slot.")
            end
        elseif selected.kind == "ammo" then
            table.insert(detail, "Class: " .. (selected.weapon.ammoClass or "n/a"))
            table.insert(detail, "Loaded: " .. selected.countText)
        elseif selected.kind == "equip" then
            if selected.itemId then
                table.insert(detail, "Bulk: " .. formatBulk(itemEntries[selected.itemId].bulk))
                for _, abilityId in ipairs(itemEntries[selected.itemId].abilities or {}) do
                    table.insert(detail, "Grants: " .. abilityEntries[abilityId].name)
                end
                table.insert(detail, "")
                table.insert(detail, "[Move] to unequip")
            else
                local weapon = selected.weaponId and weaponEntries[selected.weaponId] or weaponEntries.strike
                table.insert(detail, "Damage: " .. formatDamageRange(weapon.damage) .. " " .. weapon.damageType)
                table.insert(detail, "Range: " .. weapon.range)
                for _, abilityId in ipairs(weapon.abilities or {}) do
                    table.insert(detail, "Grants: " .. abilityEntries[abilityId].name)
                end
                if selected.weaponId then
                    table.insert(detail, "")
                    table.insert(detail, "[Move] to unequip")
                end
            end
        elseif selected.kind == "inventory" then
            table.insert(detail, "Bulk each: " .. selected.bulkText)
            table.insert(detail, "Carried: " .. selected.count)
            for _, abilityId in ipairs(itemEntries[selected.itemId].abilities or {}) do
                table.insert(detail, "Grants: " .. abilityEntries[abilityId].name)
            end
        end
        for i, line in ipairs(detail) do
            inventoryWin.setCursorPos(rightX, 3 + i)
            inventoryWin.write(line)
        end
    end

    inventoryWin.setCursorPos(1, screenH)
    inventoryWin.write("[Tab] pages  [Enter] use  [M] move  [I] close")

    inventoryWin.setVisible(true)
end

-- The dedicated "pick this up, then press again somewhere else to put it
-- down" key - needed once a weapon can go into more than one valid slot
-- (any MANIPULATE limb), which a single "Enter does everything" key can't
-- express unambiguously the way it could when there was only ever one
-- destination (the belt).
local MOVE_KEY = keys.m

-- Blocks until the player closes the inventory (I again) - fully modal, like
-- combat, rather than coexisting with the live game world.
local function runInventoryScreen()
    local selection = 1
    local scrollOffset = 0
    local pageBarVisible = false
    local currentPage = 1
    local pages = { "Inventory" } -- just the one for now; Tab's whole point is room to add more later
    local visibleCount = screenH - 1 - INVENTORY_LIST_TOP + 1

    -- Whatever's currently picked up mid-move, or nil. `name` is just for
    -- the "Carrying: X" header; `weaponId`/`itemId` is whichever of the two
    -- actually identifies what's being carried (a weapon looking for an
    -- equip slot, or a plain item looking for a belt slot); `from` is where
    -- it came from, so an invalid drop can put it right back.
    local carrying = nil

    local rows
    local function redraw()
        rows = getInventoryRows(player)
        selection = math.min(selection, math.max(1, #rows))
        scrollOffset = clampInventoryScroll(selection, scrollOffset, #rows, visibleCount)
        drawInventoryScreen(rows, selection, scrollOffset, pageBarVisible, currentPage, pages, carrying)
    end

    -- Undoes a pickup exactly, used both for "drop somewhere invalid" and
    -- for "close the inventory mid-move" (see the keys.i branch below) -
    -- nothing carried should ever just vanish.
    local function returnCarrying()
        if not carrying then
            return
        end
        if carrying.from.kind == "inventory" then
            table.insert(player.inventory, carrying.itemId)
        elseif carrying.from.kind == "belt" then
            player.belt[carrying.from.index] = carrying.itemId
            if carrying.weaponId then
                player.ammo["belt" .. carrying.from.index] = carrying.ammo
            end
        elseif carrying.from.kind == "equip" then
            player.equipped[carrying.from.slot] = carrying.weaponId or carrying.itemId
            if carrying.weaponId then
                player.ammo[carrying.from.slot] = carrying.ammo
            end
        end
        carrying = nil
    end

    redraw()

    while true do
        local _, key = os.pullEvent("key")

        if key == keys.i then
            returnCarrying()
            return
        elseif key == keys.tab then
            pageBarVisible = not pageBarVisible
            redraw()
        elseif pageBarVisible and key == keys.left then
            currentPage = (currentPage - 2) % #pages + 1
            redraw()
        elseif pageBarVisible and key == keys.right then
            currentPage = currentPage % #pages + 1
            redraw()
        elseif key == keys.up then
            selection = math.max(1, selection - 1)
            redraw()
        elseif key == keys.down then
            selection = math.min(#rows, selection + 1)
            redraw()
        elseif key == MOVE_KEY then
            local entry = rows[selection]

            if not carrying then
                -- Pick up whatever's here, if anything - empty slots and
                -- rows with nothing moveable just don't respond. A weapon's
                -- own ammo (if it has any loaded) travels along with it -
                -- an equip slot or a holstered belt slot both track one -
                -- so a swap doesn't need to spill and immediately re-collect
                -- the same rounds.
                if entry then
                    if entry.kind == "inventory" then
                        local item = itemEntries[entry.itemId]
                        removeInventoryItems(player, entry.itemId, 1)
                        carrying = {
                            weaponId = item.weaponId, itemId = entry.itemId,
                            name = item.name, from = { kind = "inventory" },
                        }
                    elseif entry.kind == "belt" and entry.itemId then
                        player.belt[entry.index] = nil
                        local ammo = nil
                        if entry.weaponId then
                            ammo = player.ammo["belt" .. entry.index]
                            player.ammo["belt" .. entry.index] = nil
                        end
                        carrying = {
                            weaponId = entry.weaponId, itemId = entry.itemId, ammo = ammo,
                            name = itemEntries[entry.itemId].name,
                            from = { kind = "belt", index = entry.index },
                        }
                    elseif entry.kind == "equip" and entry.weaponId then
                        local ammo = player.ammo[entry.slot]
                        player.ammo[entry.slot] = nil
                        player.equipped[entry.slot] = "none"
                        carrying = {
                            weaponId = entry.weaponId, itemId = weaponEntries[entry.weaponId].itemId, ammo = ammo,
                            name = weaponEntries[entry.weaponId].name,
                            from = { kind = "equip", slot = entry.slot },
                        }
                    elseif entry.kind == "equip" and entry.itemId then
                        player.equipped[entry.slot] = "none"
                        carrying = {
                            itemId = entry.itemId,
                            name = itemEntries[entry.itemId].name,
                            from = { kind = "equip", slot = entry.slot },
                        }
                    end
                end
            else
                -- Drop it. A weapon dropped on an equip slot goes there,
                -- swapping out whatever was already equipped (its ammo
                -- spilled to the inventory first, then back to the bag as
                -- its own item too - unless it has none, like Strike); a
                -- weapon or plain item dropped on a belt slot works the
                -- same way (a belt slot can hold a loaded weapon exactly
                -- like an equip slot can - see "Inventory & equipment").
                -- Dropped anywhere else, it just lands in the general
                -- inventory instead (ammo included) - always a valid
                -- resting place regardless of where it came from, which is
                -- also how unequipping works: pick it up here, then press
                -- Move again without needing a matching slot at all.
                if carrying.weaponId and entry and entry.kind == "equip" then
                    if entry.weaponId then
                        returnAmmoToInventory(player, entry.weaponId, entry.slot)
                        local oldItemId = weaponEntries[entry.weaponId].itemId
                        if oldItemId then
                            table.insert(player.inventory, oldItemId)
                        end
                    elseif entry.itemId then
                        table.insert(player.inventory, entry.itemId)
                    end
                    player.equipped[entry.slot] = carrying.weaponId
                    player.ammo[entry.slot] = carrying.ammo
                elseif carrying.itemId and not carrying.weaponId and entry and entry.kind == "equip" then
                    if entry.weaponId then
                        returnAmmoToInventory(player, entry.weaponId, entry.slot)
                        local oldItemId = weaponEntries[entry.weaponId].itemId
                        if oldItemId then
                            table.insert(player.inventory, oldItemId)
                        end
                    elseif entry.itemId then
                        table.insert(player.inventory, entry.itemId)
                    end
                    player.equipped[entry.slot] = carrying.itemId
                elseif entry and entry.kind == "belt" and (carrying.itemId or carrying.weaponId) then
                    if entry.itemId then
                        if entry.weaponId then
                            returnAmmoToInventory(player, entry.weaponId, "belt" .. entry.index)
                        end
                        table.insert(player.inventory, entry.itemId)
                    end
                    player.belt[entry.index] = carrying.itemId
                    if carrying.weaponId then
                        player.ammo["belt" .. entry.index] = carrying.ammo or 0
                    end
                else
                    if carrying.itemId then
                        table.insert(player.inventory, carrying.itemId)
                    end
                    if carrying.weaponId then
                        depositAmmo(player, carrying.weaponId, carrying.ammo)
                    end
                end
                carrying = nil
            end

            redraw()
        elseif key == ACTIVATE_KEY then
            -- "Use it immediately" - reload for ammo, or whatever ability
            -- an item/belt entry grants (the salve, so far); anything else
            -- (a weapon sitting in inventory, apparel, ammo itself, an
            -- equip slot) just doesn't respond - equipping a weapon needs a
            -- chosen destination, which is what Move is for.
            local entry = rows[selection]
            if entry then
                if entry.kind == "ammo" then
                    reloadWeapon(player, entry.slot)
                elseif entry.itemId then
                    local abilityId = itemEntries[entry.itemId].abilities and itemEntries[entry.itemId].abilities[1]
                    local ability = abilityId and abilityEntries[abilityId]
                    if ability and ability.effect then
                        local result = ability.effect(player)
                        if result ~= "noop" then
                            if entry.kind == "belt" then
                                player.belt[entry.index] = nil
                            elseif entry.kind == "equip" then
                                player.equipped[entry.slot] = "none"
                            else
                                removeInventoryItems(player, entry.itemId, 1)
                            end
                        end
                    end
                end
            end
            redraw()
        end
    end
end

-- Shared by overworld movement and in-combat repositioning alike.
local dirDelta = {
    up = { dx = 0, dy = -1 },
    down = { dx = 0, dy = 1 },
    left = { dx = -1, dy = 0 },
    right = { dx = 1, dy = 0 },
}

local keyToDir = {
    [keys.up] = "up",
    [keys.down] = "down",
    [keys.left] = "left",
    [keys.right] = "right",
}

-- Simple square range check (Chebyshev distance) rather than a circle -
-- cheap, and intuitive enough for a text grid.
local function gridDistance(ax, ay, bx, by)
    return math.max(math.abs(ax - bx), math.abs(ay - by))
end

-- Super simple test enemy, built from the same swappable-limb system the
-- player uses - torso and head are MORTAL the same way any torso is, so it
-- can be crippled or killed exactly like the player can. It's melee-only and
-- bare-fisted, so decide() paths straight toward the player (no pathfinding
-- needed - the rooms are empty rectangles) until its fist is in range, then
-- throws a punch every turn after that. Behavior is hard-coded rather than
-- data-driven, same as any other non-player creature - this is the "type",
-- inherited stats and all, from which live instances are spawned.
local testDummyType = npc:new()
testDummyType.name = "test dummy"

function testDummyType:decide(state)
    if state.distance <= weaponEntries.strike.range then
        return { action = "attack" }
    end

    -- Cardinal-only, same as the player's own arrow-key movement - one axis
    -- per turn, whichever has more ground left to cover.
    local dx = state.player.gridX - state.self.gridX
    local dy = state.player.gridY - state.self.gridY
    if math.abs(dx) >= math.abs(dy) then
        return { action = "move", dx = (dx > 0 and 1 or -1), dy = 0 }
    else
        return { action = "move", dx = 0, dy = (dy > 0 and 1 or -1) }
    end
end

local function spawnTestDummy()
    local enemy = testDummyType:new()
    enemy.body = newHumanBody()
    enemy.typeId = "test_dummy"

    -- Test case for damage types: a thick skull shrugs off blunt hits but is
    -- an easier target for anything that punches through.
    enemy.body.subSlots.head.resistances = { bludgeoning = 0.8, piercing = 1.2 }

    -- Test case for coverage inheritance: no species actually has horns yet,
    -- but attaching one anyway proves it protects exactly as well as the
    -- head it's stuck to, despite having no coverage zone of its own.
    attachPart(enemy.body.subSlots.head, "horns", "horn", {})

    -- Test case for apparel: two layers on the torso (should stack) plus a
    -- helmet on the head (which the horn above should inherit).
    table.insert(enemy.worn, "padded_shirt")
    table.insert(enemy.worn, "ballistic_vest")
    table.insert(enemy.worn, "helmet")

    return enemy
end

-- To-hit math works off any {stats, body} pair, so it's the same function
-- for the player and any hard-coded enemy. Injuries feed straight back in:
-- a busted head throws off your aim, worn-down legs make you slow to dodge.
local function getEffectiveAim(combatant)
    local head = combatant.body.subSlots.head
    local condition = (head and head.maxHealth > 0) and (head.health / head.maxHealth) or 1
    return combatant.stats.aim * condition
end

-- Reflex threshold above which moving only takes a quick action instead of
-- a full one - its own variable since it's exactly the kind of number
-- likely to get tuned later.
local REFLEX_QUICK_THRESHOLD = 1.25

-- Unlike aim, reflex reads each leg's full limb strength (organ/status
-- multiplier and condition together), not just raw health - a leg-strength
-- bonus or a fracture matters here exactly as it would for a punch.
local function getEffectiveReflex(combatant)
    local legs = { combatant.body.subSlots.left_leg, combatant.body.subSlots.right_leg }
    local total, count = 0, 0
    for _, leg in ipairs(legs) do
        if leg then
            total = total + getLimbStrength(combatant, leg)
            count = count + 1
        end
    end
    local condition = count > 0 and (total / count) or 1
    return combatant.stats.reflex * condition
end

local function getHitChance(attacker, defender)
    return getEffectiveAim(attacker) * (1 - getEffectiveReflex(defender) / 2)
end

-- Spread only bites once there's actual empty space between attacker and
-- target - point blank (distance 1) is zero tiles walked, so it's a no-op
-- for anything with range 1, which is why ordinary melee never feels it.
local function getFinalHitChance(attacker, defender, weapon, distance)
    local base = getHitChance(attacker, defender)
    local spreadPenalty = (weapon.spread / 100) * (distance - 1)
    return math.max(0, base - spreadPenalty)
end

-- Digit keys double as the selector for both the action menu and the limb
-- picker, 1-9 then 0 for a tenth entry - then a-z beyond that, since a body
-- can have more than 10 parts (a horn pushes a human past it already).
local numberKeys = {
    keys.one, keys.two, keys.three, keys.four, keys.five,
    keys.six, keys.seven, keys.eight, keys.nine, keys.zero,
    keys.a, keys.b, keys.c, keys.d, keys.e, keys.f, keys.g, keys.h, keys.i, keys.j,
    keys.k, keys.l, keys.m, keys.n, keys.o, keys.p, keys.q, keys.r, keys.s, keys.t,
    keys.u, keys.v, keys.w, keys.x, keys.y, keys.z,
}
local keyToNumber = {}
for i, k in ipairs(numberKeys) do
    keyToNumber[k] = i
end

-- Matching label for a numberKeys index: 1-9, 0, then a-z.
local function digitLabel(i)
    if i < 10 then
        return tostring(i)
    elseif i == 10 then
        return "0"
    else
        return string.char(string.byte("a") + i - 11)
    end
end

-- Window writes don't wrap on their own - text just runs past the edge and
-- gets silently clipped. Writes `text` at (x, y) using wrapText, and
-- returns how many rows it used so the caller can stack whatever comes
-- next below it instead of assuming one line is always one row.
local function writeWrapped(win, x, y, text)
    local width = win.getSize()
    local maxWidth = math.max(1, width - x + 1)
    local lines = wrapText(text, maxWidth)
    for i, line in ipairs(lines) do
        win.setCursorPos(x, y + i - 1)
        win.write(line)
    end
    return #lines
end

-- Reserved for the moments that genuinely warrant taking over the whole
-- screen and stopping the player in their tracks - victory, death - rather
-- than every routine swing and status tick (see logCombat below for those).
local function showCombatMessage(lines, wait)
    combatWin.setVisible(false)
    combatWin.clear()
    local row = 1
    for _, line in ipairs(lines) do
        row = row + writeWrapped(combatWin, 1, row, line)
    end
    combatWin.setVisible(true)
    if wait then
        os.pullEvent("key")
    end
end

-- Grab-bag of combat-only state that doesn't belong to any one function -
-- Lua's main chunk has a hard 200-local ceiling and this file sits close
-- to it, so this holds what would otherwise be several more top-level
-- locals (the pacing knob, plus the current encounter's loc/scene/
-- selection - see combatState.redrawPanes below - and the flash helper
-- itself)
-- as fields on one shared table instead.
-- `logDelay`: how long each combat log line lingers before the next one
-- appears, and how long a flashed map cell stays red - one shared knob for
-- both, tweak here to make combat resolve faster/slower.
local combatState = { logDelay = 0.5 }

-- Every wrapped line logged so far this encounter, oldest first - mirrors
-- activityLog/drawLog/logActivity (see those), just scoped to a single
-- fight and drawn into combatLogWin instead. Reset per encounter (see
-- resetCombatLog) rather than left to grow across fights.
local combatActivityLog = {}

local function drawCombatLog()
    combatLogWin.setVisible(false)
    combatLogWin.clear()
    local width, height = combatLogWin.getSize()
    local startIndex = math.max(1, #combatActivityLog - height + 1)
    for i = startIndex, #combatActivityLog do
        combatLogWin.setCursorPos(1, i - startIndex + 1)
        combatLogWin.write(combatActivityLog[i])
    end
    combatLogWin.setVisible(true)
end

-- Reports something routine that happened this fight - a swing landing or
-- missing, a status tick, an enemy closing in - without interrupting with
-- a "Press any key" prompt. showCombatMessage is still there for the small
-- handful of moments that actually deserve the player's full attention.
-- Pauses for combatState.logDelay after drawing so each line has a moment
-- to register before the next one appears - every call site gets this for
-- free, rather than each one having to remember to pace itself.
local function logCombat(message)
    local width = combatLogWin.getSize()
    for _, line in ipairs(wrapText(message, width)) do
        table.insert(combatActivityLog, line)
    end
    drawCombatLog()
    sleep(combatState.logDelay)
end

local function resetCombatLog()
    combatActivityLog = {}
    drawCombatLog()
end

-- Shows the room grid with every combatant in the scene on it, so position
-- (and thus range/spread) is something the player can actually see and
-- plan around. Drawn into its own top-left pane rather than sharing a
-- full-screen window with the action menu.
local function drawCombatField(loc, scene)
    combatMapWin.setVisible(false)
    combatMapWin.clear()
    combatMapWin.setCursorPos(1, 1)
    combatMapWin.write(loc.name)
    for y = 1, loc.height do
        local row = {}
        for x = 1, loc.width do
            row[x] = "."
        end
        for _, foe in ipairs(scene) do
            if foe.gridX >= 1 and foe.gridX <= loc.width and foe.gridY == y then
                row[foe.gridX] = "E"
            end
        end
        if player.gridY == y then
            row[player.gridX] = "@"
        end
        combatMapWin.setCursorPos(1, y + 1)
        combatMapWin.write(table.concat(row))
    end
    combatMapWin.setVisible(true)
end

-- Briefly flips a single map cell to red, for a hit landing - the map's
-- already sitting there visible from the last drawCombatField, so this
-- just paints straight over the one cell rather than redrawing the whole
-- pane, then paints it back once combatState.logDelay has passed.
function combatState.flash(x, y, symbol)
    combatMapWin.setTextColor(colors.red)
    combatMapWin.setCursorPos(x, y + 1)
    combatMapWin.write(symbol)
    sleep(combatState.logDelay)
    combatMapWin.setTextColor(colors.white)
    combatMapWin.setCursorPos(x, y + 1)
    combatMapWin.write(symbol)
end

-- The bottom-right pane: every foe still in the scene, health included, with
-- the currently-selected one marked - Tab cycles it (see promptAction).
-- Fight/Look/an ability's targeting all act on whichever's selected here.
local function drawEnemyList(scene, selectedIndex)
    combatEnemyWin.setVisible(false)
    combatEnemyWin.clear()
    combatEnemyWin.setCursorPos(1, 1)
    combatEnemyWin.write("Enemies (Tab to cycle)")
    for i, foe in ipairs(scene) do
        local marker = (i == selectedIndex) and ">" or " "
        local status = isDead(foe.body) and " (dead)" or ""
        writeWrapped(combatEnemyWin, 1, i + 2, ("%s%s  %d/%d%s"):format(
            marker, foe.name, foe.body.health, foe.body.maxHealth, status
        ))
    end
    combatEnemyWin.setVisible(true)
end

-- `combatState.loc`/`.scene` don't change for the life of an encounter, and
-- neither does `.selectedIndex` except via Tab - tracked here so anything
-- mid-resolution (an ability effect, runBeltAction, a picker returning) can
-- put the map/enemy panes back the way they should look without needing
-- loc/scene threaded all the way through every call. Set once near the top
-- of runEncounter and whenever the selection changes.

-- A fullscreen sub-picker (choosing an attack, a limb, an ability, a
-- reload/belt target) draws right over the map/enemy panes the same way
-- showCombatMessage does - unlike showCombatMessage's old blocking
-- "Press any key" though, resolution now continues straight into a paced
-- sequence of logCombat/combatState.flash calls, so whatever picker was
-- showing needs putting right first, or those would be flashing over stale
-- picker text instead of the actual map. Call this right after any such
-- picker returns, before resolution logging begins.
function combatState.redrawPanes()
    if combatState.loc then
        drawCombatField(combatState.loc, combatState.scene)
        drawEnemyList(combatState.scene, combatState.selectedIndex)
    end
end

-- restricted is true mid a quick action's bonus turn: Fight/Ability still
-- show up (some of what they offer might still be quick/instant), Look and
-- Idle always do since both are always quick or better, but Move's tag
-- reflects whether it would actually be allowed right now.
local ACTION_LABELS = {
    fight = "Fight", look = "Look (instant)", reload = "Reload (quick)",
    ability = "Ability", belt = "Belt", idle = "Idle (quick)", flee = "Flee",
}

-- The main in-combat menu: Fight/Look/[Reload]/Ability/Belt/Idle/Flee,
-- numbered dynamically since Reload only appears when an equipped weapon
-- actually uses ammo (see hasAmmoWeapon). Movement isn't a menu entry at
-- all - arrow keys reposition immediately, without a separate confirmation
-- step, so the player never has to open a sub-prompt just to take a step.
-- Tab cycles which enemy in the scene is selected (see drawEnemyList) right
-- here in the same loop, without counting as a turn or an action of its
-- own. Returns (action, moveDir, selectedIndex); moveDir is only
-- meaningful when action == "move".
local function promptAction(loc, scene, selectedIndex, restricted)
    drawCombatField(loc, scene)
    drawEnemyList(scene, selectedIndex)

    local moveTag = getEffectiveReflex(player) >= REFLEX_QUICK_THRESHOLD and "quick" or "full"

    local options = { "fight", "look" }
    if hasAmmoWeapon(player) then
        table.insert(options, "reload")
    end
    table.insert(options, "ability")
    table.insert(options, "belt")
    table.insert(options, "idle")
    table.insert(options, "flee")

    -- No "What will you do?" header - between this, the numbered options,
    -- and the move hint, that's already everything this pane has room for
    -- without needing to scroll (see "Combat menu & movement" in the
    -- design doc).
    combatActionWin.setVisible(false)
    combatActionWin.clear()
    local row = 1
    if restricted then
        combatActionWin.setCursorPos(1, row)
        combatActionWin.write("(quick/instant only)")
        row = row + 1
    end
    for i, action in ipairs(options) do
        combatActionWin.setCursorPos(1, row)
        combatActionWin.write("[" .. digitLabel(i) .. "] " .. ACTION_LABELS[action])
        row = row + 1
    end
    combatActionWin.setCursorPos(1, row)
    combatActionWin.write("Arrow keys to move (" .. moveTag .. ")")
    combatActionWin.setVisible(true)

    while true do
        local _, key = os.pullEvent("key")
        if key == keys.tab then
            selectedIndex = selectedIndex % #scene + 1
            drawEnemyList(scene, selectedIndex)
        else
            local dir = keyToDir[key]
            if dir then
                return "move", dir, selectedIndex
            end
            local index = keyToNumber[key]
            if index and options[index] then
                return options[index], nil, selectedIndex
            end
        end
    end
end

local function scaleDamageRange(range, mult)
    return {
        min = math.floor(range.min * mult + 0.5),
        max = math.floor(range.max * mult + 0.5),
    }
end

-- Whatever's equipped in a limb's matching equip slot, or a bare Strike if
-- there's nothing there (or nothing anymore - see the inventory's equip
-- slots).
local function getWieldedWeapon(equipped, label)
    local weaponId = equipped and equipped[label]
    -- A hand can also hold a plain consumable (see "Inventory & equipment")
    -- rather than a weapon - weaponEntries won't recognize its id, so it
    -- attacks bare-handed exactly like an empty hand does.
    if weaponId and weaponEntries[weaponId] then
        return weaponEntries[weaponId]
    end
    return weaponEntries.strike
end

-- Whatever a given limb would actually attack with: equipped gear (or a
-- bare Strike) for a MANIPULATE limb, or a fixed natural weapon for a part
-- whose template declares one (a stinger's sting, so far). Natural weapons
-- aren't equipment - never read from `equipped`, so they can't be swapped,
-- dropped, or disarmed the way a held weapon can. Returns nil if this part
-- has no way to attack at all.
local function getAttackWeapon(entry, equipped)
    if getPartLocalTags(entry.part).MANIPULATE then
        return getWieldedWeapon(equipped, entry.label)
    end
    local template = partEntries[entry.part.template]
    return template and template.naturalWeapon and weaponEntries[template.naturalWeapon] or nil
end

-- Lists every limb the attacker can actually fight with as a weapon choice
-- - MANIPULATE limbs (hands, by default) plus anything with a natural
-- weapon of its own (a stinger) - but only the ones currently in range and
-- still functional (see isLimbFunctional: a destroyed arm takes its hand
-- down with it, a destroyed stinger just takes itself). Range is a hard
-- cap, not a penalty. STRENGTH only scales melee weapons; spread is folded
-- into the shown hit chance for every weapon, melee included, since it's
-- driven by actual distance rather than weapon type. When restricted (mid a
-- quick action's bonus turn), two-handed weapons are left out entirely,
-- same as an out-of-range one - an out-of-ammo weapon is left out the same
-- way. Returns nil if nothing qualifies at all, or "back" (as the first
-- value) if the player explicitly backed out instead of picking one.
local function pickAttack(equipped, enemy, distance, restricted)
    local limbs = collectLabeledParts(player.body)
    local options = {}
    for _, entry in ipairs(limbs) do
        local weapon = getAttackWeapon(entry, equipped)
        if weapon and isLimbFunctional(entry.part) then
            local isQuick = weapon.handedness ~= "two-handed"
            local hasAmmo = not weapon.ammoCapacity
                or (player.ammo[entry.label] or 0) >= (weapon.ammoPerShot or 1)
            if distance <= weapon.range and (not restricted or isQuick) and hasAmmo then
                table.insert(options, entry)
            end
        end
    end

    if #options == 0 then
        return nil, nil
    end

    combatWin.setVisible(false)
    combatWin.clear()
    combatWin.setCursorPos(1, 1)
    combatWin.write("Choose your attack: (distance " .. distance .. ")")
    local row = 3
    for i, entry in ipairs(options) do
        local weapon = getAttackWeapon(entry, equipped)
        local hitPercent = math.floor(getFinalHitChance(player, enemy, weapon, distance) * 100 + 0.5)
        local speedTag = weapon.handedness == "two-handed" and " (full)" or " (quick)"
        local ammoTag = weapon.ammoCapacity and (" [%d/%d ammo]"):format(player.ammo[entry.label] or 0, weapon.ammoCapacity) or ""
        local line
        if weapon.type == "melee" then
            local strength = player.stats.strength * getLimbStrength(player, entry.part)
            local scaled = scaleDamageRange(weapon.damage, strength)
            line = ("[%s] %s - %s %s dmg x %d%% STR = %s dmg (%d%% to hit)%s%s"):format(
                digitLabel(i), entry.label, weapon.name, formatDamageRange(weapon.damage),
                math.floor(strength * 100 + 0.5), formatDamageRange(scaled), hitPercent, speedTag, ammoTag
            )
        else
            line = ("[%s] %s - %s %s dmg (ranged, %d%% to hit)%s%s"):format(
                digitLabel(i), entry.label, weapon.name, formatDamageRange(weapon.damage), hitPercent, speedTag, ammoTag
            )
        end
        row = row + writeWrapped(combatWin, 1, row, line)
    end
    local backIndex = #options + 1
    writeWrapped(combatWin, 1, row, "[" .. digitLabel(backIndex) .. "] Back")
    combatWin.setVisible(true)

    while true do
        local _, key = os.pullEvent("key")
        local index = keyToNumber[key]
        if index == backIndex then
            return "back", nil
        elseif index and options[index] then
            return options[index], getAttackWeapon(options[index], equipped)
        end
    end
end

-- Shows every limb on the target as a boxed name+health entry and waits for
-- the matching digit key. `prompt` is the full line to show (the caller
-- phrases it, since "Target the test dummy's:" and "Target your own:" don't
-- share a grammatical template). Names are indented like a folder tree by
-- depth from the torso - a bitmap body diagram would clutter a plain
-- terminal fast, but the body's already a tree internally, so this is a
-- cheap way to let the eye parse the list structurally instead of as a
-- flat wall of names.
-- Returns nil, nil if the player backs out instead of picking a limb.
local function pickLimb(prompt, torso)
    local parts = collectLabeledParts(torso)

    combatWin.setVisible(false)
    combatWin.clear()
    combatWin.setCursorPos(1, 1)
    combatWin.write(prompt)
    local row = 3
    for i, entry in ipairs(parts) do
        row = row + writeWrapped(combatWin, 1, row, ("[%s] %s%s  %d/%d"):format(
            digitLabel(i), string.rep("  ", entry.depth), entry.label, entry.part.health, entry.part.maxHealth
        ))
    end
    local backIndex = #parts + 1
    writeWrapped(combatWin, 1, row, "[" .. digitLabel(backIndex) .. "] Back")
    combatWin.setVisible(true)

    while true do
        local _, key = os.pullEvent("key")
        local index = keyToNumber[key]
        if index == backIndex then
            return nil, nil
        elseif index and parts[index] then
            return parts[index].part, parts[index].label
        end
    end
end

-- A read-only version of pickLimb's list, for the Look action - a size-up,
-- not a targeting prompt, so it never asks the player to choose one, just
-- waits for any key to close.
local function viewLimbs(prompt, torso)
    local parts = collectLabeledParts(torso)

    combatWin.setVisible(false)
    combatWin.clear()
    combatWin.setCursorPos(1, 1)
    combatWin.write(prompt)
    local row = 3
    for _, entry in ipairs(parts) do
        row = row + writeWrapped(combatWin, 1, row, ("%s%s  %d/%d"):format(
            string.rep("  ", entry.depth), entry.label, entry.part.health, entry.part.maxHealth
        ))
    end
    writeWrapped(combatWin, 1, row + 1, "Press any key.")
    combatWin.setVisible(true)

    os.pullEvent("key")
end

-- Every ability granted by any organ anywhere in the combatant's body, by
-- anything currently equipped (a weapon's own abilities, like the chain
-- sword's Rev it up! or the laser pistol's Charge Shot), or by anything in
-- the belt (a consumable's own use-ability). Entries on cooldown are left
-- out entirely, same as pickAttack simply not listing an out-of-range
-- weapon. Each entry carries the specific part that granted it (the
-- wielding hand, for a weapon ability), since an effect like Rev it up!
-- needs to know whose strength to use; a weapon ability also carries the
-- equip slot itself, since an ammo-based one (Charge Shot) needs to know
-- which ammo pool to draw from. itemId is set when it came from the belt,
-- so using it can consume it.
local function collectAbilities(combatant)
    local abilities = {}
    local function tryAdd(source, part, itemId, slot)
        for _, abilityId in ipairs(source.abilities or {}) do
            if abilityEntries[abilityId] and not combatant.cooldowns[abilityId] then
                table.insert(abilities, { id = abilityId, ability = abilityEntries[abilityId], part = part, itemId = itemId, slot = slot })
            end
        end
    end

    walkBody(combatant.body, function(part)
        for _, organId in pairs(part.organs) do
            tryAdd(organEntries[organId], part)
        end
        for _, organId in ipairs(part.genericOrgans) do
            tryAdd(organEntries[organId], part)
        end
    end)

    for slot, occupant in pairs(combatant.equipped) do
        local weapon = weaponEntries[occupant]
        if weapon then
            local handPart = nil
            for _, entry in ipairs(collectLabeledParts(combatant.body)) do
                if entry.label == slot then
                    handPart = entry.part
                    break
                end
            end
            -- A weapon's abilities need a working hand to use it with, same
            -- as an ordinary attack does (see pickAttack) - Rev it up!
            -- shouldn't be usable out of a hand that's been destroyed.
            if not handPart or isLimbFunctional(handPart) then
                tryAdd(weapon, handPart, nil, slot)
            end
        elseif occupant and occupant ~= "none" and itemEntries[occupant] then
            -- A plain item held in a hand acts as just another belt slot -
            -- `slot` (alongside itemId) is what tells the consumption logic
            -- this came from a hand rather than the belt.
            tryAdd(itemEntries[occupant], nil, occupant, slot)
        end
    end

    for i = 1, combatant.beltSize do
        local itemId = combatant.belt[i]
        if itemId then
            tryAdd(itemEntries[itemId], nil, itemId)
        end
    end

    return abilities
end

-- Returns nil if the combatant has nothing usable, same convention as
-- pickAttack coming up empty when nothing's in range. When restricted (mid
-- a quick action's bonus turn), full-speed abilities are left out entirely.
local function pickAbility(combatant, restricted)
    local abilities = collectAbilities(combatant)
    if restricted then
        local allowed = {}
        for _, entry in ipairs(abilities) do
            if entry.ability.speed ~= "full" then
                table.insert(allowed, entry)
            end
        end
        abilities = allowed
    end
    if #abilities == 0 then
        return nil
    end

    combatWin.setVisible(false)
    combatWin.clear()
    combatWin.setCursorPos(1, 1)
    combatWin.write("Choose an ability:")
    local row = 3
    for i, entry in ipairs(abilities) do
        local tag = entry.ability.speed ~= "full" and (" (" .. entry.ability.speed .. ")") or ""
        row = row + writeWrapped(combatWin, 1, row, "[" .. digitLabel(i) .. "] " .. entry.ability.name .. tag)
    end
    local backIndex = #abilities + 1
    writeWrapped(combatWin, 1, row, "[" .. digitLabel(backIndex) .. "] Back")
    combatWin.setVisible(true)

    while true do
        local _, key = os.pullEvent("key")
        local index = keyToNumber[key]
        if index == backIndex then
            return "back"
        elseif index and abilities[index] then
            return abilities[index]
        end
    end
end

-- Every equipped weapon that (a) actually uses ammo, (b) isn't already full,
-- and (c) has at least one matching ammo item to pull from - same "just
-- don't list it" convention as everything else. Returns nil if nothing
-- qualifies.
local function pickReloadTarget(combatant)
    local options = {}
    for slot, weaponId in pairs(combatant.equipped) do
        local weapon = weaponEntries[weaponId]
        if weapon and weapon.ammoCapacity and (combatant.ammo[slot] or 0) < weapon.ammoCapacity then
            if countCarriedItem(combatant, getAmmoItemId(weapon)) > 0 then
                table.insert(options, { slot = slot, weapon = weapon })
            end
        end
    end

    if #options == 0 then
        return nil
    end

    combatWin.setVisible(false)
    combatWin.clear()
    combatWin.setCursorPos(1, 1)
    combatWin.write("Reload which weapon?")
    local row = 3
    for i, opt in ipairs(options) do
        row = row + writeWrapped(combatWin, 1, row, ("[%s] %s (%s) - %d/%d ammo"):format(
            digitLabel(i), opt.weapon.name, opt.slot, combatant.ammo[opt.slot] or 0, opt.weapon.ammoCapacity
        ))
    end
    local backIndex = #options + 1
    writeWrapped(combatWin, 1, row, "[" .. digitLabel(backIndex) .. "] Back")
    combatWin.setVisible(true)

    while true do
        local _, key = os.pullEvent("key")
        local index = keyToNumber[key]
        if index == backIndex then
            return "back"
        elseif index and options[index] then
            return options[index]
        end
    end
end

-- Display helpers shared by the Belt action's pickers - "which slot" and
-- "what's in it", read off getSlotContents rather than duplicating the
-- weapon-vs-item-vs-empty branching at every call site.
local function slotDisplayName(slotDescriptor)
    if slotDescriptor.kind == "equip" then
        return slotDescriptor.slot
    end
    return "Belt " .. slotDescriptor.index
end

local function slotOccupantName(combatant, slotDescriptor)
    local weaponId, itemId = getSlotContents(combatant, slotDescriptor)
    if weaponId then
        return weaponEntries[weaponId].name
    elseif itemId then
        return itemEntries[itemId].name
    end
    return "Empty"
end

-- The Belt action: every hand and belt slot shown together (a consumable
-- held in a hand behaves exactly like one on the belt), doing whatever its
-- contents implies - swap a weapon to another slot, use up a consumable on
-- the spot, or holster a weapon from elsewhere (another slot, or one lying
-- on the ground this fight) into an empty one. When restricted (mid a
-- quick action's bonus turn), the swap/holster sub-actions are always full
-- - rather than filtering every slot up front by what sub-action it
-- implies, this follows the same "let them pick it, then reject it"
-- pattern Move has always used for a full action taken while quickened.
-- Returns the resolved speed, or nil if nothing happened.
local function runBeltAction(combatant, droppedItems, enemy, restricted)
    local slots = getAllSlots(combatant)

    combatWin.setVisible(false)
    combatWin.clear()
    combatWin.setCursorPos(1, 1)
    combatWin.write("Belt - which slot?")
    local row = 3
    for i, slotDescriptor in ipairs(slots) do
        row = row + writeWrapped(combatWin, 1, row, ("[%s] %s: %s"):format(
            digitLabel(i), slotDisplayName(slotDescriptor), slotOccupantName(combatant, slotDescriptor)
        ))
    end
    local backIndex = #slots + 1
    writeWrapped(combatWin, 1, row, "[" .. digitLabel(backIndex) .. "] Back")
    combatWin.setVisible(true)

    local chosen
    while true do
        local _, key = os.pullEvent("key")
        local index = keyToNumber[key]
        if index == backIndex then
            return nil
        elseif index and slots[index] then
            chosen = slots[index]
            break
        end
    end
    combatState.redrawPanes()

    local weaponId, itemId = getSlotContents(combatant, chosen)

    if weaponId then
        if restricted then
            logCombat("You don't have time to swap weapons.")
            return nil
        end

        local destinations = {}
        for _, slotDescriptor in ipairs(slots) do
            if not slotsEqual(slotDescriptor, chosen) then
                table.insert(destinations, slotDescriptor)
            end
        end

        combatWin.setVisible(false)
        combatWin.clear()
        combatWin.setCursorPos(1, 1)
        combatWin.write("Swap " .. weaponEntries[weaponId].name .. " to where?")
        local drow = 3
        for i, slotDescriptor in ipairs(destinations) do
            drow = drow + writeWrapped(combatWin, 1, drow, ("[%s] %s: %s"):format(
                digitLabel(i), slotDisplayName(slotDescriptor), slotOccupantName(combatant, slotDescriptor)
            ))
        end
        local dBackIndex = #destinations + 1
        writeWrapped(combatWin, 1, drow, "[" .. digitLabel(dBackIndex) .. "] Back")
        combatWin.setVisible(true)

        while true do
            local _, key = os.pullEvent("key")
            local index = keyToNumber[key]
            if index == dBackIndex then
                return nil
            elseif index and destinations[index] then
                local destination = destinations[index]
                local destWeaponId, destItemId = getSlotContents(combatant, destination)
                swapSlots(combatant, chosen, destination)
                combatState.redrawPanes()
                if destWeaponId then
                    logCombat("You swap your " .. weaponEntries[weaponId].name .. " for the " .. weaponEntries[destWeaponId].name .. "!")
                elseif destItemId then
                    logCombat("You stow your " .. weaponEntries[weaponId].name .. " and take the " .. itemEntries[destItemId].name .. " in hand.")
                else
                    logCombat("You holster your " .. weaponEntries[weaponId].name .. ".")
                end
                return "full"
            end
        end
    elseif itemId then
        local item = itemEntries[itemId]
        local abilityId = item.abilities and item.abilities[1]
        local ability = abilityId and abilityEntries[abilityId]
        if not ability or not ability.effect then
            return nil
        end
        local result = ability.effect(combatant, enemy)
        if result == "noop" then
            return nil
        end
        clearSlot(combatant, chosen)
        return ability.speed
    else
        if restricted then
            logCombat("You don't have time to holster a weapon.")
            return nil
        end

        local candidates = {}
        for _, slotDescriptor in ipairs(slots) do
            local candidateWeaponId = getSlotContents(combatant, slotDescriptor)
            if candidateWeaponId then
                table.insert(candidates, { kind = "slot", slotDescriptor = slotDescriptor, weaponId = candidateWeaponId })
            end
        end
        for i, dropped in ipairs(droppedItems) do
            table.insert(candidates, { kind = "dropped", index = i, weaponId = dropped.weaponId })
        end

        if #candidates == 0 then
            logCombat("Nothing to holster.")
            return nil
        end

        combatWin.setVisible(false)
        combatWin.clear()
        combatWin.setCursorPos(1, 1)
        combatWin.write("Holster which weapon?")
        local crow = 3
        for i, candidate in ipairs(candidates) do
            local source = candidate.kind == "slot" and slotDisplayName(candidate.slotDescriptor) or "ground"
            crow = crow + writeWrapped(combatWin, 1, crow, ("[%s] %s (%s)"):format(
                digitLabel(i), weaponEntries[candidate.weaponId].name, source
            ))
        end
        local cBackIndex = #candidates + 1
        writeWrapped(combatWin, 1, crow, "[" .. digitLabel(cBackIndex) .. "] Back")
        combatWin.setVisible(true)

        while true do
            local _, key = os.pullEvent("key")
            local index = keyToNumber[key]
            if index == cBackIndex then
                return nil
            elseif index and candidates[index] then
                local candidate = candidates[index]
                if candidate.kind == "slot" then
                    swapSlots(combatant, chosen, candidate.slotDescriptor)
                else
                    table.remove(droppedItems, candidate.index)
                    fillSlot(combatant, chosen, candidate.weaponId, nil, 0)
                end
                combatState.redrawPanes()
                logCombat("You draw the " .. weaponEntries[candidate.weaponId].name .. "!")
                return "full"
            end
        end
    end
end

-- Knocks whatever's equipped in a slot right out of the player's hands -
-- a destroyed hand (see runEncounter's enemy-attack branch), or later, some
-- disarm effect. A weapon is removed from `equipped` entirely and tracked
-- in `droppedItems` until it's picked back up mid-fight (see
-- runBeltAction's empty-slot branch) or auto-returned to the inventory
-- once the encounter ends; a plain consumable just falls straight back
-- into the pack instead, since it was never "wielded" in the first place -
-- there's nothing to clatter to the ground or reclaim. Returns the dropped
-- weapon's id, or nil if that slot had nothing equipped, or held a plain
-- item instead of a weapon.
local function dropEquippedItem(droppedItems, slot)
    local weaponId, itemId = getSlotContents(player, { kind = "equip", slot = slot })
    if itemId then
        player.equipped[slot] = "none"
        table.insert(player.inventory, itemId)
        return nil
    end
    if not weaponId then
        return nil
    end
    returnAmmoToInventory(player, weaponId, slot)
    player.equipped[slot] = "none"
    table.insert(droppedItems, { slot = slot, weaponId = weaponId })
    return weaponId
end

-- Effects attached here rather than up in abilityEntries itself, since they
-- need showCombatMessage/pickLimb/getFinalHitChance/etc, none of which
-- exist yet up there.
abilityEntries.adrenaline_shot.effect = function(user)
    applyCharacterStatus(user, "adrenaline")
    logCombat("You use the Adrenal Auto-Injector!")
end

-- A special attack in its own right rather than an instant buff: one single
-- swing (one hit roll) that, on a hit, saws through the target for five
-- separate 5-10 damage instances (still STRENGTH-scaled, still slashing),
-- each triggering the chain sword's onHit individually - five landed cuts
-- stacks a full ten bleed. It's one swing, not five, so a miss is a miss
-- for the whole thing; runEncounter refunds the cooldown in that case (see
-- the "miss" return below), since revving up for nothing shouldn't cost you
-- the same as connecting. Melee range still applies, same as any other
-- attack with this weapon.
abilityEntries.rev_it_up.effect = function(user, enemy, sourcePart)
    local weapon = weaponEntries.chain_sword
    local distance = gridDistance(user.gridX, user.gridY, enemy.gridX, enemy.gridY)

    if distance > weapon.range then
        logCombat("Nothing is in range.")
        return "noop"
    end

    local target, label = pickLimb("Target the " .. enemy.name .. "'s:", enemy.body)
    if not target then
        return "noop"
    end
    combatState.redrawPanes()
    local hitChance = getFinalHitChance(user, enemy, weapon, distance)

    if math.random() > hitChance then
        logCombat("You rev up your Chain Sword and swing at the " .. enemy.name .. "'s " .. label .. "... You miss!")
        return "miss"
    end

    local strength = user.stats.strength * getLimbStrength(user, sourcePart)
    logCombat("The Chain Sword saws through the " .. enemy.name .. "'s " .. label .. "!")

    local totalDealt = 0
    for i = 1, 5 do
        if isDead(enemy.body) then
            break
        end

        local roll = math.random(5, 10)
        local raw = math.floor(roll * strength + 0.5)
        local dealt = damagePart(enemy, target, raw, weapon.damageType)
        if weapon.onHit then
            weapon.onHit(target)
        end
        totalDealt = totalDealt + dealt
        logCombat("Cut " .. i .. " deals " .. dealt .. "!")
        combatState.flash(enemy.gridX, enemy.gridY, "E")
    end

    logCombat("You dealt " .. totalDealt .. " damage to the " .. enemy.name .. "'s " .. label .. "!")
end

-- Heals yourself, not the opponent - a wound-tending action, not an attack.
-- `enemy` is only ever real when this is called mid-fight (runEncounter
-- always passes one; the inventory screen's own "use immediately" doesn't
-- have one at all) - used here purely to decide how to report the result,
-- not for anything about the heal itself.
abilityEntries.use_dermoregenesis_salve.effect = function(user, enemy)
    local target, label = pickLimb("Target your own:", user.body)
    if not target then
        return "noop"
    end
    local healed = healPart(target, 25)
    if enemy then
        combatState.redrawPanes()
        logCombat("You apply the salve to your " .. label .. "! Healed " .. healed .. " (" .. target.health .. "/" .. target.maxHealth .. ")")
    else
        -- Outside a fight there's no combat log to report to (see
        -- logCombat) - this goes to the overworld's activity log instead.
        logActivity(dialogue("{{name}} used the Dermoregenesis Salve on {{him}}self.", user))
        logActivity(dialogue("{{name}} healed for " .. healed .. ".", user))
    end
end

-- A single heavy shot: double a normal shot's damage, three shots of ammo,
-- no cooldown to make up for always costing the full turn. Fires (and
-- burns ammo) whether it hits or not, same as an ordinary shot.
local CHARGE_SHOT_AMMO_COST = 3

abilityEntries.charge_shot.effect = function(user, enemy, sourcePart, sourceSlot)
    local weapon = weaponEntries.laser_pistol
    local distance = gridDistance(user.gridX, user.gridY, enemy.gridX, enemy.gridY)

    if distance > weapon.range then
        logCombat("Nothing is in range.")
        return "noop"
    end

    if (user.ammo[sourceSlot] or 0) < CHARGE_SHOT_AMMO_COST then
        logCombat("Not enough ammo to charge a shot.")
        return "noop"
    end

    local target, label = pickLimb("Target the " .. enemy.name .. "'s:", enemy.body)
    if not target then
        return "noop"
    end
    combatState.redrawPanes()
    local hitChance = getFinalHitChance(user, enemy, weapon, distance)
    local hitPercent = math.floor(hitChance * 100 + 0.5)

    user.ammo[sourceSlot] = user.ammo[sourceSlot] - CHARGE_SHOT_AMMO_COST

    logCombat("You charge the Laser Pistol and fire at the " .. enemy.name .. "'s " .. label .. " (" .. hitPercent .. "% to hit)...")

    if math.random() > hitChance then
        logCombat("You miss!")
        return
    end

    local roll = math.random(weapon.damage.min, weapon.damage.max)
    local dealt = damagePart(enemy, target, roll * 2, weapon.damageType)

    logCombat("The charged shot hits for " .. dealt .. "! (" .. target.health .. "/" .. target.maxHealth .. ")")
    combatState.flash(enemy.gridX, enemy.gridY, "E")
end

-- "The scene" is whoever's left to fight this encounter - just one enemy
-- for now, but written as a list so a real search-and-destroy encounter
-- (several foes at once) falls out for free later.
local function sceneCleared(scene)
    for _, foe in ipairs(scene) do
        if not isDead(foe.body) then
            return false
        end
    end
    return true
end

-- Fires once every foe in the scene is down, checked at the start of each of
-- the player's turns rather than guessed at from whichever attack happened
-- to land the killing blow. Logs each kill by typeId onto the player's kill
-- log - so a quest can ask "have you killed a test_dummy?" (or later, "3
-- bandits?") without a bespoke flag wired into every place damage happens -
-- then shows a summary of what went down before handing control back.
local function showVictoryScreen(scene)
    local lines = { "Victory!", "" }
    for _, foe in ipairs(scene) do
        player.killLog[foe.typeId] = (player.killLog[foe.typeId] or 0) + 1
        table.insert(lines, "The " .. foe.name .. " collapses.")
    end
    table.insert(lines, "")
    table.insert(lines, "Press any key.")
    showCombatMessage(lines, true)
end

-- "The test dummy" for one, "the test dummy and the goblin" for two, an
-- Oxford-comma list for more - for the activity log's "fought" line, which
-- otherwise reads oddly for a scene with more than one foe in it (nothing
-- spawns more than one yet, but scene's already a list - see "Victory").
local function joinEnemyNames(scene)
    local names = {}
    for _, foe in ipairs(scene) do
        table.insert(names, "the " .. foe.name)
    end
    if #names == 1 then
        return names[1]
    elseif #names == 2 then
        return names[1] .. " and " .. names[2]
    end
    return table.concat(names, ", ", 1, #names - 1) .. ", and " .. names[#names]
end

-- `triggeringObject` is whichever map object (an enemy-kind entry in the
-- current location's objects) started this fight, if any - used purely so
-- a win can remove it from the map afterward (see the victory branch
-- below); nothing else about the encounter depends on it.
local function runEncounter(triggeringObject)
    local startX, startY = player.gridX, player.gridY
    local enemy = spawnTestDummy()
    local scene = { enemy }
    local loc = world[player.location]

    -- Whichever entry in `scene` Fight/Look/an ability's targeting acts on
    -- - Tab cycles this in promptAction. Only one foe exists yet, so this
    -- never actually moves, but the plumbing's in place for whenever a
    -- second one shows up.
    local selectedEnemyIndex = 1
    combatState.loc, combatState.scene, combatState.selectedIndex = loc, scene, selectedEnemyIndex

    -- Enemy spawns somewhere else in the same room; retry a few times to
    -- avoid landing right on the player, but don't sweat a tiny room.
    for _ = 1, 20 do
        enemy.gridX = math.random(loc.width)
        enemy.gridY = math.random(loc.height)
        if enemy.gridX ~= player.gridX or enemy.gridY ~= player.gridY then
            break
        end
    end

    resetCombatLog()
    logActivity(dialogue("{{name}} fought " .. joinEnemyNames(scene) .. ".", player))
    logCombat("A " .. enemy.name .. " attacks!")

    -- Action economy: a full action always ends the round. Quick actions are
    -- half an action each - the first one taken this round flips
    -- `quickened` true and grants a bonus turn; a *second* quick action
    -- (quickened already true) spends the other half and ends the round.
    -- Instant actions always grant a bonus turn and never touch `quickened`
    -- either way - they're free, not half of anything. Once quickened,
    -- full actions are off the table entirely for the rest of the round.
    local quickened = false

    -- Whatever's currently lying on the ground this encounter (a weapon
    -- knocked out of a destroyed hand - see the enemy-attack branch below).
    -- Anything still here when the fight ends just lands in the bag, via
    -- its own itemId (see "Inventory & equipment" - weapons as items),
    -- same as unequipping it manually would; the player can re-equip it
    -- themselves once they're out of combat and it's actually useful again
    -- (a hand still at 0 health can't wield anything anyway - see
    -- isLimbFunctional).
    local droppedItems = {}
    local function returnUnclaimedDrops()
        for _, dropped in ipairs(droppedItems) do
            local itemId = weaponEntries[dropped.weaponId].itemId
            if itemId then
                table.insert(player.inventory, itemId)
            else
                -- No carryable form - shouldn't happen for anything that
                -- could actually end up equipped, but re-equip rather than
                -- lose it outright if it ever does.
                player.equipped[dropped.slot] = dropped.weaponId
            end
        end
    end

    while true do
        -- The start of the player's turn: check the scene before prompting
        -- for an action at all, rather than each attack path guessing
        -- whether its own hit was the one that won the fight.
        if sceneCleared(scene) then
            showVictoryScreen(scene)
            logActivity(dialogue("{{name}} won the fight!", player))

            -- Winning shouldn't leave you wherever the fight happened to
            -- wander to - back to the tile you were standing on when it
            -- started, and the enemy's map object (if any) is actually
            -- gone, not just a fresh dummy waiting to respawn on contact.
            player.gridX, player.gridY = startX, startY
            if triggeringObject then
                for i, o in ipairs(loc.objects) do
                    if o == triggeringObject then
                        table.remove(loc.objects, i)
                        break
                    end
                end
            end

            returnUnclaimedDrops()
            return false
        end

        local action, moveDir, newSelectedIndex = promptAction(loc, scene, selectedEnemyIndex, quickened)
        selectedEnemyIndex = newSelectedIndex
        combatState.selectedIndex = selectedEnemyIndex
        local foe = scene[selectedEnemyIndex]

        if action == "flee" then
            logCombat("You break off and flee.")
            logActivity(dialogue("{{name}} fled.", player))
            returnUnclaimedDrops()
            return false
        end

        -- Set by whichever branch below actually resolves something; nil
        -- means "nothing happened" (rejected/no-op), which re-prompts
        -- without changing `quickened` at all.
        local speed = nil

        if action == "move" then
            local moveIsQuick = getEffectiveReflex(player) >= REFLEX_QUICK_THRESHOLD
            if quickened and not moveIsQuick then
                logCombat("You don't have time to move.")
            else
                local delta = dirDelta[moveDir]
                local nx, ny = player.gridX + delta.dx, player.gridY + delta.dy
                if nx >= 1 and nx <= loc.width and ny >= 1 and ny <= loc.height then
                    player.gridX, player.gridY = nx, ny
                    speed = moveIsQuick and "quick" or "full"
                end
                -- Stepping into a wall silently does nothing - same as
                -- promptMove used to just ignore an out-of-bounds press
                -- rather than spend a turn on it.
            end
        end

        if action == "idle" then
            speed = "quick"
        end

        if action == "look" then
            viewLimbs("The " .. foe.name .. "'s condition:", foe.body)
            speed = "instant"
        end

        if action == "ability" then
            local entry = pickAbility(player, quickened)
            combatState.redrawPanes()
            if entry == "back" then
                -- cancelled, nothing happened
            elseif not entry then
                logCombat("You have nothing to use.")
            else
                local result = entry.ability.effect(player, foe, entry.part, entry.slot)

                if result ~= "noop" then
                    if entry.itemId and entry.slot then
                        -- A consumable held in a hand rather than the belt
                        -- (see collectAbilities) - consumed by clearing
                        -- that hand, not searching the belt for it.
                        player.equipped[entry.slot] = "none"
                    elseif entry.itemId then
                        -- Consumed, not cooled down - find and remove this
                        -- exact belt slot.
                        for i = 1, player.beltSize do
                            if player.belt[i] == entry.itemId then
                                player.belt[i] = nil
                                break
                            end
                        end
                    elseif entry.ability.cooldown and result ~= "miss" then
                        -- "miss" still spends the turn (you swung, it just
                        -- didn't connect) but refunds the cooldown, since
                        -- nothing about the ability actually happened.
                        player.cooldowns[entry.id] = entry.ability.cooldown
                    end
                    speed = entry.ability.speed
                end
            end
        end

        if action == "fight" then
            local distance = gridDistance(player.gridX, player.gridY, foe.gridX, foe.gridY)
            local attacker, weapon = pickAttack(player.equipped, foe, distance, quickened)
            combatState.redrawPanes()

            if attacker == "back" then
                -- cancelled, nothing happened
            elseif not attacker then
                logCombat("Nothing is in range.")
            else
                local target, label = pickLimb("Target the " .. foe.name .. "'s:", foe.body)
                combatState.redrawPanes()

                if target then
                    local hitChance = getFinalHitChance(player, foe, weapon, distance)
                    local hitPercent = math.floor(hitChance * 100 + 0.5)
                    speed = weapon.handedness == "two-handed" and "full" or "quick"

                    -- Firing burns ammo whether it hits or not.
                    if weapon.ammoCapacity then
                        player.ammo[attacker.label] = player.ammo[attacker.label] - (weapon.ammoPerShot or 1)
                    end

                    logCombat("Your " .. attacker.label .. " swings with " .. weapon.name .. " at the " .. foe.name .. "'s " .. label .. " (" .. hitPercent .. "% to hit)...")

                    if math.random() > hitChance then
                        logCombat("You miss!")
                    else
                        local strength = 1
                        if weapon.type == "melee" then
                            strength = player.stats.strength * getLimbStrength(player, attacker.part)
                        end
                        local roll = math.random(weapon.damage.min, weapon.damage.max)
                        local raw = math.floor(roll * strength + 0.5)
                        local dealt = damagePart(foe, target, raw, weapon.damageType)
                        if weapon.onHit then
                            weapon.onHit(target)
                        end

                        logCombat("Hits for " .. dealt .. "! (" .. target.health .. "/" .. target.maxHealth .. ")")
                        combatState.flash(foe.gridX, foe.gridY, "E")
                    end
                end
            end
        end

        if action == "reload" then
            local target = pickReloadTarget(player)
            combatState.redrawPanes()
            if target == "back" then
                -- cancelled, nothing happened
            elseif not target then
                logCombat("Nothing to reload.")
            else
                local loaded = reloadWeapon(player, target.slot)
                logCombat("You reload the " .. target.weapon.name .. ". Loaded " .. loaded .. " (" .. player.ammo[target.slot] .. "/" .. target.weapon.ammoCapacity .. ")")
                speed = "quick"
            end
        end

        if action == "belt" then
            speed = runBeltAction(player, droppedItems, foe, quickened)
        end

        -- nil: nothing happened, quickened untouched, prompt again.
        -- instant: another turn, quickened untouched either way.
        -- quick: first one just flips quickened true; a second one (already
        -- quickened) spends the other half and ends the round.
        -- full: always ends the round outright.
        local endTurn = false

        if speed == "quick" then
            if quickened then
                endTurn = true
            else
                quickened = true
            end
        elseif speed == "full" then
            endTurn = true
        end

        if endTurn then
            quickened = false

            -- A foe already dead this round (e.g. the blow that just landed
            -- was the killing one) doesn't get to act - the scene check at
            -- the top of the loop will end the encounter next turn.
            if not sceneCleared(scene) then
                local decision = enemy:decide({
                    self = enemy,
                    player = player,
                    distance = gridDistance(player.gridX, player.gridY, enemy.gridX, enemy.gridY),
                })

                if decision.action == "move" then
                    enemy.gridX = math.max(1, math.min(loc.width, enemy.gridX + decision.dx))
                    enemy.gridY = math.max(1, math.min(loc.height, enemy.gridY + decision.dy))
                    logCombat("The " .. enemy.name .. " closes in!")
                elseif decision.action == "attack" then
                    local weapon = weaponEntries.strike
                    local distance = gridDistance(player.gridX, player.gridY, enemy.gridX, enemy.gridY)
                    local enemyHitChance = getFinalHitChance(enemy, player, weapon, distance)
                    local enemyHitPercent = math.floor(enemyHitChance * 100 + 0.5)

                    logCombat("The " .. enemy.name .. " attacks (" .. enemyHitPercent .. "% to hit)...")

                    if math.random() > enemyHitChance then
                        logCombat("It misses!")
                    else
                        local parts = collectLabeledParts(player.body)
                        local pick = parts[math.random(#parts)]
                        local roll = math.random(weapon.damage.min, weapon.damage.max)
                        local raw = math.floor(roll * enemy.stats.strength + 0.5)
                        local dealt = damagePart(player, pick.part, raw, weapon.damageType)
                        if weapon.onHit then
                            weapon.onHit(pick.part)
                        end
                        drawStats()

                        logCombat("Hits your " .. pick.label .. " for " .. dealt .. "! (" .. pick.part.health .. "/" .. pick.part.maxHealth .. ")")
                        combatState.flash(player.gridX, player.gridY, "@")

                        -- Death is the one AI-turn outcome that still stops
                        -- the player in their tracks with a full screen,
                        -- same as victory - everything else here is routine
                        -- enough for the log.
                        if isDead(player.body) then
                            showCombatMessage({ "You died.", "", "Press any key." }, true)
                            returnUnclaimedDrops()
                            return true
                        end

                        -- A destroyed hand can't hold onto anything - the
                        -- weapon actually falls, rather than just sitting
                        -- unusable in a slot attached to a ruined hand (an
                        -- arm being destroyed instead just disables
                        -- attacking - see isLimbFunctional/pickAttack -
                        -- nothing gets dropped for that).
                        if pick.part.health <= 0 then
                            local droppedWeaponId = dropEquippedItem(droppedItems, pick.label)
                            if droppedWeaponId then
                                logCombat("Your " .. pick.label .. " goes limp - the " .. weaponEntries[droppedWeaponId].name .. " clatters to the ground!")
                            end
                        end
                    end
                end
                -- decision.action == "idle": nothing happens.
            end

            -- A full round has now actually elapsed - this is "the start of
            -- your next turn" as far as status durations (and anything that
            -- ticks damage before decrementing, like bleed) are concerned.
            for _, tick in ipairs(applyDamageOverTime(player)) do
                local verb = DOT_VERBS[tick.statusId] or "takes damage"
                logCombat("Your " .. tick.label .. " " .. verb .. " for " .. tick.dealt .. "!")
                combatState.flash(player.gridX, player.gridY, "@")
            end
            for _, tick in ipairs(applyDamageOverTime(enemy)) do
                local verb = DOT_VERBS[tick.statusId] or "takes damage"
                logCombat("The " .. enemy.name .. "'s " .. tick.label .. " " .. verb .. " for " .. tick.dealt .. "!")
                combatState.flash(enemy.gridX, enemy.gridY, "E")
            end
            drawStats()

            if isDead(player.body) then
                showCombatMessage({ "You died.", "", "Press any key." }, true)
                returnUnclaimedDrops()
                return true
            end

            decrementStatuses(player)
            decrementStatuses(enemy)
            decrementCooldowns(player)
            decrementCooldowns(enemy)
        end
    end
end

-- A blurb followed by a numbered menu of choices, for exploration-time
-- interactions - same digit/letter scheme as everywhere else, just outside
-- combat. Lines are run through dialogue() first, so any blurb/greeting/
-- quest line in the game can freely use {{name}}/{{subject}}/{{object}}
-- without every call site needing to remember to do it itself.
local function showInteraction(lines, options)
    combatWin.setVisible(false)
    combatWin.clear()
    local row = 1
    for _, line in ipairs(lines) do
        row = row + writeWrapped(combatWin, 1, row, dialogue(line, player))
    end
    row = row + 1 -- blank line before the option list
    for i, option in ipairs(options) do
        row = row + writeWrapped(combatWin, 1, row, "[" .. digitLabel(i) .. "] " .. option)
    end
    combatWin.setVisible(true)

    while true do
        local _, key = os.pullEvent("key")
        local index = keyToNumber[key]
        if index and options[index] then
            return index
        end
    end
end

-- A pure lore/flavor person just shows their greeting. A quest giver either
-- offers the quest (not yet taken), nudges you about it (active, not
-- ready), or turns it in (active and ready) - turning in hands over the
-- reward and moves the giver on to nextQuestId, same "! -> ? -> ! -> 0 (or
-- !)" cycle every time.
local function interactWithPerson(obj)
    if not obj.questId then
        local greeting = obj.greetingId and dynamicGreetings[obj.greetingId]() or obj.greeting
        showInteraction(greeting or { "\"...\"" }, { "Leave" })
        return
    end

    local quest = questEntries[obj.questId]
    local state = player.quests[obj.questId]

    if state == "active" and quest.isReady() then
        showInteraction(quest.turnInLines, { "Continue" })
        if quest.rewardItemId then
            table.insert(player.inventory, quest.rewardItemId)
        end
        player.quests[obj.questId] = "done"
        obj.questId = quest.nextQuestId
    elseif state == "active" then
        showInteraction(quest.activeLines, { "Leave" })
    else
        local choice = showInteraction(quest.offerLines, { "Accept", "Not now" })
        if choice == 1 then
            player.quests[obj.questId] = "active"
        end
    end
end

local SAVE_DIR = "saves"
local SAVE_SLOT_COUNT = 5

local function getSaveSlotPath(slot)
    return fs.combine(SAVE_DIR, "slot" .. slot .. ".sav")
end

local function readSaveSlot(slot)
    local path = getSaveSlotPath(slot)
    if not fs.exists(path) then
        return nil
    end
    local h = fs.open(path, "r")
    local content = h.readAll()
    h.close()
    return textutils.unserialize(content)
end

local function writeSaveSlot(slot, data)
    if not fs.exists(SAVE_DIR) then
        fs.makeDir(SAVE_DIR)
    end
    local h = fs.open(getSaveSlotPath(slot), "w")
    -- allow_repetitions: nothing in save data should genuinely be a shared
    -- table (see dynamicGreetings for how conditional dialogue avoids this
    -- exact problem), but this is cheap insurance against a future
    -- accidental one triggering the same "cannot serialize table with
    -- repeated entries" error again instead of just duplicating the data.
    h.write(textutils.serialize(data, { allow_repetitions = true }))
    h.close()
end

-- Scans every location for the save_point object a given save was made at -
-- that's the only thing about "where" a save actually remembers (see
-- buildSaveData); a save from a terminal that's since been removed just
-- can't be repositioned and falls back to wherever the player already is.
local function findSavePointById(saveId)
    for locName, loc in pairs(world) do
        for _, obj in ipairs(loc.objects or {}) do
            if obj.kind == "save_point" and obj.saveId == saveId then
                return locName, obj
            end
        end
    end
    return nil, nil
end

-- Where to actually stand on load: beside the terminal rather than on top of
-- it, so it doesn't immediately re-trigger the save/load prompt. Falls back
-- to the terminal's own tile if every neighbor is somehow blocked.
local SPAWN_OFFSETS = { { 0, 1 }, { 0, -1 }, { 1, 0 }, { -1, 0 } }
local function findSpawnSpotNear(loc, obj)
    for _, delta in ipairs(SPAWN_OFFSETS) do
        local nx, ny = obj.x + delta[1], obj.y + delta[2]
        if nx >= 1 and nx <= loc.width and ny >= 1 and ny <= loc.height and not findObjectAt(loc, nx, ny) then
            return nx, ny
        end
    end
    return obj.x, obj.y
end

-- The mutable half of the world: every location's current objects, exactly
-- as they stand right now - a picked-up item missing from the list, a door
-- left open, a quest giver mid-cycle. Objects are plain data (no functions,
-- no back-references), so unlike the body there's nothing to rebuild - the
-- whole array round-trips through textutils.serialize as-is.
local function buildWorldSnapshot()
    local snapshot = {}
    for locName, loc in pairs(world) do
        snapshot[locName] = loc.objects
    end
    return snapshot
end

-- The reverse: replaces each known location's objects outright with
-- whatever the save remembered, rather than trying to reconcile individual
-- entries - simpler, and correct as long as locations themselves (as
-- opposed to what's in them) don't get added or removed at runtime.
local function applyWorldSnapshot(snapshot)
    for locName, objects in pairs(snapshot) do
        if world[locName] then
            world[locName].objects = objects
        end
    end
end

-- Everything about the player worth remembering across a save: full body
-- (health/organs/statuses), gear, and progress - position isn't part of it,
-- just which save point made the save (see findSavePointById/applySaveData).
-- Also captures the whole world's current object state (see
-- buildWorldSnapshot) - a save should remember what's changed out there,
-- not just the player's own stats.
local function buildSaveData(saveId)
    local stats = {}
    for k, v in pairs(player.stats) do stats[k] = v end

    local inventory = {}
    for i, id in ipairs(player.inventory) do inventory[i] = id end

    local equipped = {}
    for slot, id in pairs(player.equipped) do equipped[slot] = id end

    local statuses = {}
    for id, duration in pairs(player.statuses) do statuses[id] = duration end

    local cooldowns = {}
    for id, remaining in pairs(player.cooldowns) do cooldowns[id] = remaining end

    local belt = {}
    for i = 1, player.beltSize do
        belt[i] = player.belt[i]
    end

    local ammo = {}
    for slot, count in pairs(player.ammo) do ammo[slot] = count end

    local worn = {}
    for i, id in ipairs(player.worn) do worn[i] = id end

    local quests = {}
    for id, state in pairs(player.quests) do quests[id] = state end

    local killLog = {}
    for id, count in pairs(player.killLog) do killLog[id] = count end

    return {
        saveId = saveId,
        steps = player.steps,
        name = player.name,
        pronouns = { subject = player.pronouns.subject, object = player.pronouns.object },
        stats = stats,
        inventory = inventory,
        equipped = equipped,
        statuses = statuses,
        cooldowns = cooldowns,
        belt = belt,
        beltSize = player.beltSize,
        bulkBonus = player.bulkBonus,
        ammo = ammo,
        worn = worn,
        quests = quests,
        killLog = killLog,
        body = serializeBodyPart(player.body),
        world = buildWorldSnapshot(),
    }
end

-- The reverse of buildSaveData - overwrites the live player in place with
-- everything a save remembers, then repositions to whichever save point
-- made it.
local function applySaveData(data)
    player.steps = data.steps
    player.name = data.name
    player.pronouns = { subject = data.pronouns.subject, object = data.pronouns.object }

    player.stats = {}
    for k, v in pairs(data.stats) do player.stats[k] = v end

    player.inventory = {}
    for i, id in ipairs(data.inventory) do player.inventory[i] = id end

    player.equipped = {}
    for slot, id in pairs(data.equipped) do player.equipped[slot] = id end

    player.statuses = {}
    for id, duration in pairs(data.statuses) do player.statuses[id] = duration end

    player.cooldowns = {}
    for id, remaining in pairs(data.cooldowns) do player.cooldowns[id] = remaining end

    player.beltSize = data.beltSize
    player.belt = {}
    for i = 1, data.beltSize do
        if data.belt[i] then
            player.belt[i] = data.belt[i]
        end
    end

    player.bulkBonus = data.bulkBonus

    player.ammo = {}
    for slot, count in pairs(data.ammo) do player.ammo[slot] = count end

    player.worn = {}
    for i, id in ipairs(data.worn) do player.worn[i] = id end

    player.quests = {}
    for id, state in pairs(data.quests) do player.quests[id] = state end

    player.killLog = {}
    for id, count in pairs(data.killLog) do player.killLog[id] = count end

    player.body = deserializeBodyPart(data.body, true)
    player.globalTags = recalcGlobalTags(player.body)

    applyWorldSnapshot(data.world)

    local locName, obj = findSavePointById(data.saveId)
    if locName and obj then
        player.location = locName
        player.gridX, player.gridY = findSpawnSpotNear(world[locName], obj)
    end
end

-- A slot's menu label: what's actually in it, so save/load can show a
-- summary instead of just a bare number.
local function formatSaveSlotLabel(slot)
    local data = readSaveSlot(slot)
    if not data then
        return "Slot " .. slot .. ": Empty"
    end
    local locName = findSavePointById(data.saveId)
    local place = (locName and world[locName].name) or "Unknown"
    return "Slot " .. slot .. ": Lv" .. data.stats.level .. " - " .. data.steps .. " steps - " .. place
end

-- Same digit/letter-menu convention as everywhere else, plus a trailing
-- "Back" option to cancel out without picking a slot.
local function pickSaveSlot(title)
    local options = {}
    for slot = 1, SAVE_SLOT_COUNT do
        options[slot] = formatSaveSlotLabel(slot)
    end
    options[SAVE_SLOT_COUNT + 1] = "Back"

    local choice = showInteraction({ title }, options)
    if choice == SAVE_SLOT_COUNT + 1 then
        return nil
    end
    return choice
end

local function doSave(saveId)
    local slot = pickSaveSlot("Save to which slot?")
    if not slot then
        return
    end
    if readSaveSlot(slot) then
        local choice = showInteraction({ "Overwrite this slot?" }, { "Yes", "No" })
        if choice ~= 1 then
            return
        end
    end
    writeSaveSlot(slot, buildSaveData(saveId))
    showInteraction({ "Saved." }, { "Continue" })
end

local function doLoad()
    local slot = pickSaveSlot("Load which slot?")
    if not slot then
        return
    end
    local data = readSaveSlot(slot)
    if not data then
        showInteraction({ "That slot is empty." }, { "Continue" })
        return
    end
    applySaveData(data)
    showInteraction({ "Loaded." }, { "Continue" })
end

-- The save point itself: an ID-card terminal offering save/load/quit,
-- looping back to its own menu after save or load so one visit can do
-- several things. Returns (playerDied, quitRequested) - the second is new,
-- since this is the one interaction that can end the program outright.
local function interactWithSavePoint(obj)
    while true do
        local choice = showInteraction(
            { "You insert your ID into the terminal.", "It hums to life." },
            { "Save", "Load", "Quit Game", "Leave" }
        )
        if choice == 1 then
            doSave(obj.saveId)
        elseif choice == 2 then
            doLoad()
        elseif choice == 3 then
            return false, true
        else
            return false, false
        end
    end
end

-- Picking something off the ground has no downside, so it just happens the
-- moment the player reaches it - no prompt, just a couple of log lines
-- (see logActivity) instead of the old blurb-and-choice. Shared by tryMove
-- (stepping onto it) and tryInteract (reaching for one still adjacent
-- without stepping onto it).
local function collectItem(loc, obj)
    table.insert(player.inventory, obj.itemId)
    for i, o in ipairs(loc.objects) do
        if o == obj then
            table.remove(loc.objects, i)
            break
        end
    end
    logActivity(dialogue("{{name}} picked up " .. itemEntries[obj.itemId].name .. ".", player))
end

-- Same idea for a door: opening (or closing) one is harmless enough not to
-- need a prompt either - see tryMove (bumping a closed one opens it) and
-- tryInteract (the only way to close one again). `open` names which state
-- it's ending up in, purely for the log line.
local function toggleDoor(obj, open)
    obj.open = open
    logActivity(dialogue("{{name}} " .. (open and "opened" or "closed") .. " the door.", player))
end

-- Resolves walking into whatever's occupying the destination cell -
-- anything that still warrants an actual prompt (a person, a save point, a
-- fight) rather than just happening. Returns (playerDied, quitRequested) -
-- true playerDied if the player died fighting an enemy object, true
-- quitRequested if they chose to quit at a save point; both bubble all the
-- way back up to the main loop. Items and (closed) doors never reach this -
-- both callers (tryMove, tryInteract) handle those themselves.
local function interactWithObject(loc, obj)
    if obj.kind == "person" then
        interactWithPerson(obj)
    elseif obj.kind == "save_point" then
        return interactWithSavePoint(obj)
    elseif obj.kind == "enemy" then
        local playerDied = runEncounter(obj)
        return playerDied, false
    end
    return false, false
end

-- Movement is grid-based; walking off an edge that has a matching exit
-- moves the player to the connected location, entering from the opposite
-- edge. Returns (moved, playerDied, quitRequested) - walking into an object
-- never counts as moving, but might still end the game (a fight lost, or a
-- save point's "Quit Game").
local function tryMove(dir)
    local loc = world[player.location]
    local delta = dirDelta[dir]
    local nx, ny = player.gridX + delta.dx, player.gridY + delta.dy

    if nx >= 1 and nx <= loc.width and ny >= 1 and ny <= loc.height then
        local obj = findObjectAt(loc, nx, ny)

        if obj and obj.kind == "item" then
            -- Walking onto it is the whole interaction - see collectItem.
            player.gridX, player.gridY = nx, ny
            player.steps = player.steps + 1
            collectItem(loc, obj)
            message = ""
            return true, false, false
        end

        if obj and obj.kind == "door" and not obj.open then
            -- Bumping a closed door just opens it, no prompt - but that's
            -- the whole action for this turn, same as bumping into
            -- anything else that was blocking the way; stepping through
            -- happens on the *next* move, once it's actually open.
            toggleDoor(obj, true)
            message = ""
            return false, false, false
        end

        local blocked = obj and not (obj.kind == "door" and obj.open)
        if blocked then
            local playerDied, quitRequested = interactWithObject(loc, obj)
            return false, playerDied, quitRequested
        end

        player.gridX, player.gridY = nx, ny
        player.steps = player.steps + 1
        message = ""
        return true, false, false
    end

    local nextName = loc.directions[dir]
    if not nextName then
        message = "Can't go that way."
        return false, false, false
    end

    local nextLoc = world[nextName]
    player.location = nextName
    if dir == "right" then
        player.gridX, player.gridY = 1, math.min(player.gridY, nextLoc.height)
    elseif dir == "left" then
        player.gridX, player.gridY = nextLoc.width, math.min(player.gridY, nextLoc.height)
    elseif dir == "down" then
        player.gridX, player.gridY = math.min(player.gridX, nextLoc.width), 1
    elseif dir == "up" then
        player.gridX, player.gridY = math.min(player.gridX, nextLoc.width), nextLoc.height
    end
    player.steps = player.steps + 1
    message = ""
    logActivity(dialogue("{{name}} went to " .. nextLoc.name .. ".", player))
    return true, false, false
end

-- The dedicated interact key: checks each of the four cardinal-adjacent
-- tiles (never diagonals - keeps things precise if two interactables ever
-- end up right next to each other) for something to interact with, and
-- acts on the first one found (up, then down, left, right). Doors are the
-- main reason this exists at all - opening one is automatic on a bump (see
-- tryMove), but there's no other way to *close* one again. Returns
-- (playerDied, quitRequested), same convention as tryMove/
-- interactWithObject, since anything reachable this way could end the game
-- the same way bumping into it would.
local function tryInteract()
    local loc = world[player.location]
    for _, dir in ipairs({ "up", "down", "left", "right" }) do
        local delta = dirDelta[dir]
        local obj = findObjectAt(loc, player.gridX + delta.dx, player.gridY + delta.dy)
        if obj then
            if obj.kind == "item" then
                collectItem(loc, obj)
                return false, false
            elseif obj.kind == "door" then
                toggleDoor(obj, not obj.open)
                return false, false
            else
                return interactWithObject(loc, obj)
            end
        end
    end
    return false, false
end

-- Reads a single line of free text at (x, y) in the given window - "char"
-- events give the actual typed character (already shift/caps-aware), "key"
-- only matters here for backspace/enter. Used for character creation's name
-- and custom-pronoun fields, where a numbered menu doesn't fit.
local function promptText(win, x, y, maxLen)
    local buffer = ""
    win.setCursorBlink(true)

    while true do
        win.setCursorPos(x, y)
        win.write(buffer .. string.rep(" ", maxLen - #buffer))
        win.setCursorPos(x + #buffer, y)

        local event, param = os.pullEvent()
        if event == "char" then
            if #buffer < maxLen then
                buffer = buffer .. param
            end
        elseif event == "key" then
            if param == keys.backspace then
                buffer = buffer:sub(1, -2)
            elseif param == keys.enter and #buffer > 0 then
                win.setCursorBlink(false)
                return buffer
            end
        end
    end
end

-- Quick presets read as a gender identity; "Custom" instead asks for the two
-- pronoun fields directly (subject - he/she/they - and object - him/her/
-- them), for anyone the presets don't fit. Nothing in the game's text reads
-- these yet - they're captured now for later flavor text to consume.
local PRONOUN_PRESETS = {
    { label = "Male (he/him)", subject = "he", object = "him" },
    { label = "Female (she/her)", subject = "she", object = "her" },
    { label = "Nonbinary (they/them)", subject = "they", object = "them" },
}

local function pickPronouns()
    local options = {}
    for i, preset in ipairs(PRONOUN_PRESETS) do
        options[i] = preset.label
    end
    options[#PRONOUN_PRESETS + 1] = "Custom pronouns"

    local choice = showInteraction({ "Choose your gender identity:" }, options)
    if choice <= #PRONOUN_PRESETS then
        local preset = PRONOUN_PRESETS[choice]
        return preset.subject, preset.object
    end

    combatWin.setVisible(false)
    combatWin.clear()
    combatWin.setCursorPos(1, 1)
    combatWin.write("Subject pronoun (e.g. he/she/they):")
    combatWin.setVisible(true)
    local subject = promptText(combatWin, 1, 2, 20)

    combatWin.setVisible(false)
    combatWin.clear()
    combatWin.setCursorPos(1, 1)
    combatWin.write("Object pronoun (e.g. him/her/them):")
    combatWin.setVisible(true)
    local object = promptText(combatWin, 1, 2, 20)

    return subject, object
end

-- Display order for the species menu - speciesEntries (defined alongside
-- newHumanBody/newInsectoidBody) has everything else about each one.
local SPECIES_ORDER = { "human", "insectoid" }

local function pickSpecies()
    local options = {}
    for i, id in ipairs(SPECIES_ORDER) do
        options[i] = speciesEntries[id].name
    end
    local choice = showInteraction({ "Choose your species:" }, options)
    return SPECIES_ORDER[choice]
end

-- Five points, each worth a flat +5% to one of strength/reflex/aim (added
-- once, in runCharacterCreation - not compounding, so 3 points in strength
-- is stats.strength = 1 + 3*0.05 = 1.15). "Reset" clears all of them back to
-- 0 rather than supporting per-point undo, which is enough for a one-time
-- five-point spend. Confirm is locked out until every point is spent.
local STAT_ALLOCATION_POINTS = 5
local STAT_ALLOCATION_STEP = 0.05

local function runStatAllocation()
    local points = { strength = 0, reflex = 0, aim = 0 }
    local remaining = STAT_ALLOCATION_POINTS

    while true do
        combatWin.setVisible(false)
        combatWin.clear()
        combatWin.setCursorPos(1, 1)
        combatWin.write("Allocate your stat points - " .. remaining .. " remaining")
        combatWin.setCursorPos(1, 3)
        combatWin.write("[1] Strength  +" .. (points.strength * 5) .. "%")
        combatWin.setCursorPos(1, 4)
        combatWin.write("[2] Reflex    +" .. (points.reflex * 5) .. "%")
        combatWin.setCursorPos(1, 5)
        combatWin.write("[3] Aim       +" .. (points.aim * 5) .. "%")
        combatWin.setCursorPos(1, 6)
        combatWin.write("[4] Reset")
        combatWin.setCursorPos(1, 7)
        combatWin.write(remaining == 0 and "[5] Confirm" or "[5] Confirm (spend all points first)")
        combatWin.setVisible(true)

        local _, key = os.pullEvent("key")
        if key == keys.one and remaining > 0 then
            points.strength = points.strength + 1
            remaining = remaining - 1
        elseif key == keys.two and remaining > 0 then
            points.reflex = points.reflex + 1
            remaining = remaining - 1
        elseif key == keys.three and remaining > 0 then
            points.aim = points.aim + 1
            remaining = remaining - 1
        elseif key == keys.four then
            points = { strength = 0, reflex = 0, aim = 0 }
            remaining = STAT_ALLOCATION_POINTS
        elseif key == keys.five and remaining == 0 then
            return points
        end
    end
end

-- Runs once at startup: name, pronouns, species, then stat points -
-- everything character creation is responsible for, applied straight onto
-- the live player object. Species is built here (not in the early player
-- setup above) since it needs the species menu, which needs combatWin,
-- which doesn't exist until after that setup runs.
local function runCharacterCreation()
    combatWin.setVisible(false)
    combatWin.clear()
    combatWin.setCursorPos(1, 1)
    combatWin.write("What is your name?")
    combatWin.setVisible(true)
    player.name = promptText(combatWin, 1, 2, 20)

    player.pronouns.subject, player.pronouns.object = pickPronouns()

    local species = speciesEntries[pickSpecies()]
    player.globalTags = {}
    player.body = species.build(player.globalTags)

    -- A chest implant lets the player pop adrenaline for a turn on demand
    -- via the Ability action, instead of it just being permanently on -
    -- every species starts with one, same as before species existed at all.
    installGenericOrgan(player.body, "adrenal_auto_injector", player.globalTags)
    player.globalTags = recalcGlobalTags(player.body)

    for stat, delta in pairs(species.statAdjustments) do
        player.stats[stat] = player.stats[stat] + delta
    end

    local points = runStatAllocation()
    player.stats.strength = player.stats.strength + points.strength * STAT_ALLOCATION_STEP
    player.stats.reflex = player.stats.reflex + points.reflex * STAT_ALLOCATION_STEP
    player.stats.aim = player.stats.aim + points.aim * STAT_ALLOCATION_STEP
end

runCharacterCreation()
render()

local topBarOpen = false

while true do
    local event, key = os.pullEvent("key")
    if key == keys.q then
        break
    end

    if topBarOpen then
        if key == keys.tab then
            topBarOpen = false
            pageBarWin.setVisible(false)
            render()
        elseif key == keys.left then
            topBarPage = (topBarPage - 2) % #TOP_BAR_PAGES + 1
            drawTopBar()
        elseif key == keys.right then
            topBarPage = topBarPage % #TOP_BAR_PAGES + 1
            drawTopBar()
        elseif key == ACTIVATE_KEY then
            topBarOpen = false
            pageBarWin.setVisible(false)
            runInventoryScreen() -- the only page so far
            render()
        end
    elseif key == keys.tab then
        topBarOpen = true
        topBarPage = 1
        drawTopBar()
    elseif key == keys.i then
        runInventoryScreen()
        render()
    elseif key == keys.space then
        local playerDied, quitRequested = tryInteract()
        if playerDied or quitRequested then
            break
        end
        render()
    else
        local dir = keyToDir[key]
        if dir then
            local moved, playerDied, quitRequested = tryMove(dir)
            if playerDied or quitRequested then
                break
            end
            render()
        end
    end
end