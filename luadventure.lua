-- Fuck it, why not? Sci-fi fantasy RPG game, in lua, designed for CraftOS.

-- --debug unlocks the developer console (tilde - see debugConsole.run,
-- defined much later alongside engine.promptText): arbitrary health/item/status
-- commands that bypass normal game rules entirely, so they're opt-in only
-- rather than always reachable. Args reach this top-level chunk via `...`
-- exactly like any other CC program's command-line arguments
-- (`luadventure --debug`). Declared this early (rather than down where the
-- rest of it lives) purely so `.enabled` can be set from the startup args
-- here - everything else gets added to this same table as a field later,
-- rather than costing more top-level locals of its own (see "A note on
-- locals" in the design doc; this file is already close to Lua's 200-local
-- ceiling on the main chunk).
local debugConsole = { enabled = false }
for _, arg in ipairs({ ... }) do
    if arg == "--debug" then
        debugConsole.enabled = true
    end
end

local world = {} -- Gotta define this early...

-- A single, uniquely-named global for if I need one.
Luadventure = {

}

-- Every engine-internal function (everything below that used to be its
-- own `local function`) lives as a field on this one table instead - see
-- "A note on locals" in the design doc: a table field costs nothing
-- against the 200-local ceiling on this chunk, only a bare local does,
-- and this file was already brushing up against it. Declared this early
-- (before any of them) so `function engine.foo(...)` below can actually
-- resolve `engine` at the point each one's defined - order among them
-- doesn't matter beyond that, since every closure just captures this same
-- table by reference, not each other's values at definition time.
local engine = {}

-- All game content - organs, body parts, damage types, coverage zones,
-- statuses, weapons, items, abilities, species, the world map, quests, and
-- dynamic greetings - lives in gamedata.lua now; this file is just the
-- engine that reads it. Still pulled into their own locals below (rather
-- than writing gamedata.organEntries etc. at every call site) since engine
-- code reads them constantly - see gamedata.lua's own header comment for
-- the Luadventure bridge API that lets content call back into the engine
-- (populated further down, once everything on that list actually exists -
-- see the comment right before it).
local gamedata = require("gamedata")
local organEntries = gamedata.organEntries
local partEntries = gamedata.partEntries
local damageTypes = gamedata.damageTypes
local COVERAGE_AREAS = gamedata.COVERAGE_AREAS
local AREA_TO_ZONE = gamedata.AREA_TO_ZONE
local statusEntries = gamedata.statusEntries
local DOT_VERBS = gamedata.DOT_VERBS
local weaponEntries = gamedata.weaponEntries
local itemEntries = gamedata.itemEntries
local abilityEntries = gamedata.abilityEntries
local speciesEntries = gamedata.speciesEntries
local questEntries = gamedata.questEntries
local dynamicGreetings = gamedata.dynamicGreetings
world = gamedata.world

-- Tags in here exist for engine bookkeeping only and should never be shown on
-- normal player-facing UI (e.g. gating body access during a tutorial).
local metaTags = {
    TUTORIAL_LOCK = true,
}

function engine.isMetaTag(tag)
    return metaTags[tag] == true
end

function engine.shallowCopySet(set)
    local copy = {}
    for k, v in pairs(set or {}) do copy[k] = v end
    return copy
end

-- A part's *local* tags are its own inherent tags plus whatever's granted by
-- every organ currently installed in it, hardcoded category slots and
-- generic slots alike.
function engine.getPartLocalTags(part)
    local tags = engine.shallowCopySet(part.tags)
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

function engine.walkBody(part, fn)
    fn(part)
    for _, sub in pairs(part.subSlots) do
        if sub then engine.walkBody(sub, fn) end
    end
end

-- Global tags are gathered from every organ anywhere on the body that grants
-- one. Call this again after installing/removing any organ that touches
-- globals - it isn't tracked incrementally.
function engine.recalcGlobalTags(torso)
    local tags = {}
    engine.walkBody(torso, function(part)
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
function engine.tagsSatisfied(requiredTags, localTags, globalTags)
    for _, tag in ipairs(requiredTags or {}) do
        if not (localTags[tag] or globalTags[tag]) then
            return false
        end
    end
    return true
end

function engine.tagsAbsent(forbiddenTags, localTags, globalTags)
    for _, tag in ipairs(forbiddenTags or {}) do
        if localTags[tag] or globalTags[tag] then
            return false
        end
    end
    return true
end

-- `aimDifficulty` (default 1, most templates omit it) divides a part's
-- starting health here, and its hit chance later (see engine.getFinalHitChance) -
-- the same factor both ways, so a part that's harder to land a hit on also
-- folds faster once one actually connects.
function engine.instantiatePart(templateId)
    local template = partEntries[templateId] or error("Unknown part template: " .. tostring(templateId), 2)
    local organs = {}
    for category, organId in pairs(template.organSlots or {}) do
        organs[category] = organId
    end
    local aimDifficulty = template.aimDifficulty or 1
    local health = math.floor(template.health / aimDifficulty + 0.5)
    return {
        template = templateId,
        tags = engine.shallowCopySet(template.tags),
        health = health,
        maxHealth = health,
        zone = template.zone,
        aimDifficulty = aimDifficulty,
        organs = organs,
        genericOrgans = {},
        statuses = {},
        subSlotDefs = template.subSlots or {},
        subSlots = {},
    }
end

function engine.newTorso()
    return {
        template = "torso",
        tags = { MORTAL = true },
        health = 100,
        maxHealth = 100,
        zone = "torso",
        aimDifficulty = 1,
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
function engine.attachPart(parent, slotName, templateId, globalTags)
    local slotDef = parent.subSlotDefs[slotName] or error("No such slot: " .. slotName, 2)
    local localTags = engine.getPartLocalTags(parent)
    if not engine.tagsSatisfied(slotDef.requires, localTags, globalTags) then
        return false, "slot locked"
    end
    local child = engine.instantiatePart(templateId)
    child.parent = parent
    parent.subSlots[slotName] = child
    return true
end

-- Swaps the organ filling one of a part's hardcoded category slots.
function engine.installCategoryOrgan(part, category, organId, globalTags)
    local organDef = organEntries[organId] or error("Unknown organ: " .. tostring(organId), 2)
    local localTags = engine.getPartLocalTags(part)
    if not engine.tagsSatisfied(organDef.requires, localTags, globalTags) then
        return false, "missing required tag"
    end
    if not engine.tagsAbsent(organDef.conflicts, localTags, globalTags) then
        return false, "conflicting tag present"
    end
    part.organs[category] = organId
    return true
end

-- Installs an organ into the next free generic (cybernetic) slot.
function engine.installGenericOrgan(part, organId, globalTags)
    local organDef = organEntries[organId] or error("Unknown organ: " .. tostring(organId), 2)
    local localTags = engine.getPartLocalTags(part)
    if not engine.tagsSatisfied(organDef.requires, localTags, globalTags) then
        return false, "missing required tag"
    end
    if not engine.tagsAbsent(organDef.conflicts, localTags, globalTags) then
        return false, "conflicting tag present"
    end
    table.insert(part.genericOrgans, organId)
    return true
end

-- Captures a body part's mutable state (health, installed organs, statuses)
-- plus its shape (template id, subSlots), recursively - for save games.
-- Deliberately drops `parent` (a back-reference, which would make this a
-- cycle) and `subSlotDefs`/`tags`/`zone` (all three come straight back off
-- the template on reload, via engine.instantiatePart/engine.newTorso, so saving them too
-- would just be redundant and risks going stale if templates ever change).
function engine.serializeBodyPart(part)
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
        subSlots[slotName] = engine.serializeBodyPart(sub)
    end
    return {
        template = part.template,
        health = part.health,
        maxHealth = part.maxHealth,
        rootLabel = part.rootLabel, -- only ever set on the root; nil elsewhere
        endurance = part.endurance, -- a species trait, not template-derived (see engine.newInsectoidBody) - nil for anyone without one
        organs = organs,
        genericOrgans = genericOrgans,
        statuses = statuses,
        subSlots = subSlots,
    }
end

-- Rebuilds a body part (and everything attached below it) from
-- engine.serializeBodyPart's output. The root is always a fresh torso; every other
-- part is re-instantiated from its own template rather than trusting saved
-- shape data directly, so a loaded body can't desync from what a freshly
-- created one would look like. Bypasses engine.attachPart's slot-lock checks on
-- purpose - the save already proves this exact tree once existed.
function engine.deserializeBodyPart(data, isRoot)
    local part = isRoot and engine.newTorso() or engine.instantiatePart(data.template)
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
        local child = engine.deserializeBodyPart(childData, false)
        child.parent = part
        part.subSlots[slotName] = child
    end
    return part
end

-- Combines a fresh application with whatever's already active: -1
-- (permanent) always wins outright; otherwise a stacking status adds the
-- two together, while a true-duration status just takes the higher one.
function engine.combineDuration(existing, incoming, stacks)
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
function engine.applyPartStatus(part, statusId, amount)
    local def = statusEntries[statusId]
    part.statuses[statusId] = engine.combineDuration(part.statuses[statusId], amount or def.duration, def.stacks)
end

function engine.applyCharacterStatus(combatant, statusId, amount)
    local def = statusEntries[statusId]
    combatant.statuses[statusId] = engine.combineDuration(combatant.statuses[statusId], amount or def.duration, def.stacks)
end

-- Ticks every active status on a combatant (itself and every part of its
-- body) down by one round, removing anything that hits 0. Permanent (-1)
-- statuses are left untouched. Called once a full round has actually
-- elapsed - an instant ability doesn't trigger this, since the turn hasn't
-- ended yet.
function engine.decrementStatuses(combatant)
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
    engine.walkBody(combatant.body, function(part)
        tick(part.statuses)
    end)
end

-- Same idea as engine.decrementStatuses, but for ability cooldowns - those are
-- character-wide only, never part-scoped.
function engine.decrementCooldowns(combatant)
    for abilityId, remaining in pairs(combatant.cooldowns) do
        if remaining <= 1 then
            combatant.cooldowns[abilityId] = nil
        else
            combatant.cooldowns[abilityId] = remaining - 1
        end
    end
end

-- Unlike tags, numeric modifiers (like STRENGTH) flow up through a part's
-- ancestors - a reinforced upper arm makes the hand attached to it hit
-- harder, not just the arm itself.
function engine.getOwnModifier(part, key)
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

function engine.getAncestorMultiplier(part, key)
    local mult = 1
    local current = part
    while current do
        mult = mult * engine.getOwnModifier(current, key)
        current = current.parent
    end
    return mult
end

-- The apparel coverage zone that protects this part. Most parts just have
-- their own (see partEntries); an exposed one (horns, antennae, wings, a
-- stinger) never sets one at all, so this walks up to the nearest ancestor
-- that does - a horn on the head is protected exactly as well as the head
-- itself, never independently covered.
function engine.getPartZone(part)
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
function engine.hasIgnoreCondition(combatant)
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
function engine.getConditionMultiplier(combatant, part)
    if part.health <= 0 then
        return 0
    end
    if engine.hasIgnoreCondition(combatant) then
        return 1
    end
    return part.health / part.maxHealth
end

-- A limb's effective strength: walk the same ancestor chain as
-- engine.getAncestorMultiplier, but fold in each ancestor's own condition right
-- alongside its own organ/status modifier - a damaged (or fractured) upper
-- arm should weaken a punch the same way either way, not just via organs.
-- This is what actually feeds the STRENGTH and REFLEX stats now, rather
-- than raw condition or raw organ bonus alone.
function engine.getLimbStrength(combatant, part)
    local strength = 1
    local current = part
    while current do
        strength = strength * engine.getOwnModifier(current, "strength") * engine.getConditionMultiplier(combatant, current)
        current = current.parent
    end
    return strength
end

-- True once any MORTAL-tagged part (torso, head, ...) has hit 0 health.
function engine.isDead(torso)
    local dead = false
    engine.walkBody(torso, function(part)
        if engine.getPartLocalTags(part).MORTAL and part.health <= 0 then
            dead = true
        end
    end)
    return dead
end

-- A destroyed limb takes everything attached to it down with it - a
-- destroyed arm can't attack, and neither can a perfectly healthy hand
-- still hanging off the end of it. Checked by both engine.pickAttack (unarmed or
-- otherwise) and weapon-granted abilities.
function engine.isLimbFunctional(part)
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
function engine.partLabel(parentLabel, slotName)
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
-- `torso.rootLabel` would let a species call the root part something other
-- than "torso" without changing anything about how it actually works
-- structurally - unused today (a torso is what every creature has, so no
-- species relabels its own), but left in for whatever eventually wants it.
function engine.collectLabeledParts(torso)
    local parts = {}
    local function walk(part, label, depth)
        table.insert(parts, { label = label, part = part, depth = depth })
        for slotName, sub in pairs(part.subSlots) do
            if sub then
                walk(sub, engine.partLabel(label, slotName), depth + 1)
            end
        end
    end
    walk(torso, torso.rootLabel or "torso", 0)
    return parts
end

-- Carrying capacity: 10x average limb strength across the whole body, plus
-- whatever flat bonus equipment grants (backpacks etc - none exist yet, but
-- bulkBonus is where they'd add in).
function engine.getAverageLimbStrength(combatant)
    local parts = engine.collectLabeledParts(combatant.body)
    local total = 0
    for _, entry in ipairs(parts) do
        total = total + engine.getLimbStrength(combatant, entry.part)
    end
    return total / #parts
end

function engine.getBulkCapacity(combatant)
    return 10 * engine.getAverageLimbStrength(combatant) + combatant.bulkBonus
end

-- "Light" bulk (0.1) displays as L rather than a fraction; anything else is
-- just the plain number.
function engine.formatBulk(bulk)
    if bulk == 0.1 then
        return "L"
    end
    return tostring(bulk)
end

-- Total bulk currently carried, belt and main inventory both counting
-- toward the same cap - the belt doesn't grant extra capacity, just a
-- combat-usable place to keep a few things.
function engine.getTotalBulk(combatant)
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
function engine.countCarriedItem(combatant, itemId)
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
function engine.getMaxEnergyCharges(combatant)
    return engine.countCarriedItem(combatant, "battery") * itemEntries.battery.chargeCapacity
end

-- Removes up to `amount` of a given item id from a combatant's inventory
-- (never the belt - ammo isn't something you'd keep there). Returns how
-- many were actually removed.
function engine.removeInventoryItems(combatant, itemId, amount)
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
function engine.getAmmoItemId(weapon)
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
function engine.reloadWeapon(combatant, slot)
    local weapon = weaponEntries[combatant.equipped[slot]]
    local missing = weapon.ammoCapacity - (combatant.ammo[slot] or 0)
    local loaded = engine.removeInventoryItems(combatant, engine.getAmmoItemId(weapon), missing)
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
function engine.depositAmmo(combatant, weaponId, amount)
    local weapon = weaponEntries[weaponId]
    if not weapon or not weapon.ammoCapacity or not amount or amount <= 0 then
        return
    end
    local ammoItemId = engine.getAmmoItemId(weapon)
    for _ = 1, amount do
        table.insert(combatant.inventory, ammoItemId)
    end
end

-- Unequipping a weapon (for any reason - swapping it out, a destroyed
-- hand, eventually looting an enemy's gun) spills whatever it had loaded
-- back into the inventory (see engine.depositAmmo) and clears the slot's count -
-- whatever ends up there next reloads from scratch, same as picking up a
-- stranger's weapon in real life would need to.
function engine.returnAmmoToInventory(combatant, weaponId, ammoKey)
    engine.depositAmmo(combatant, weaponId, combatant.ammo[ammoKey])
    combatant.ammo[ammoKey] = nil
end

-- True if wearing this item wouldn't put it on the same layer as, and
-- overlapping any area with, something already worn - clothing can't
-- overlap. Not wired into any live "wear it" action yet (nothing offers one
-- this turn), but it's the rule anything that does add one should call.
function engine.canWearItem(combatant, itemId)
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
function engine.getAreaCoverage(combatant, area, damageType)
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
function engine.getCoverage(combatant, part, damageType)
    local zone = engine.getPartZone(part)
    if not zone then
        return 0
    end
    local total, count = 0, 0
    for _, area in ipairs(COVERAGE_AREAS[zone]) do
        if area ~= "belt" then
            total = total + engine.getAreaCoverage(combatant, area, damageType)
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
-- 0 has any effect right now (see engine.isDead).
function engine.damagePart(owner, part, amount, damageType)
    local resistance = 1
    if damageType ~= "untyped" then
        resistance = (part.resistances and part.resistances[damageType]) or 1
    end
    local endurance = part.endurance or 0
    local coverage = engine.getCoverage(owner, part, damageType)
    local applied = math.max(0, math.floor(amount * resistance * (1 - endurance) - coverage + 0.5))
    part.health = math.max(0, part.health - applied)
    return applied
end

-- The healing counterpart to engine.damagePart: never overheals past maxHealth,
-- returns the actual amount restored.
function engine.healPart(part, amount)
    local healed = math.min(amount, part.maxHealth - part.health)
    part.health = part.health + healed
    return healed
end

-- Runs once a round, before engine.decrementStatuses: any part-scoped status with
-- damagePerStack (bleed, poison) deals damage equal to its *current* stack
-- count to its own part, using that status's own damage type. Returns a
-- list of {label, dealt, statusId} for whatever ticked, so the caller can
-- report it (statusId picks the right verb - see DOT_VERBS) - the actual
-- stack removal is engine.decrementStatuses' ordinary decrement, run right after
-- this.
function engine.applyDamageOverTime(combatant)
    local ticks = {}
    for _, entry in ipairs(engine.collectLabeledParts(combatant.body)) do
        for statusId, duration in pairs(entry.part.statuses) do
            local def = statusEntries[statusId]
            if def.damagePerStack and duration > 0 then
                local dealt = engine.damagePart(combatant, entry.part, duration, def.damagePerStack)
                table.insert(ticks, { label = entry.label, dealt = dealt, statusId = statusId })
            end
        end
    end
    return ticks
end

-- Standard human body: torso plus the four default limbs, each with the
-- baseline human organ set already filling their hardcoded slots. Shared by
-- the player and any humanoid NPC.
function engine.newHumanBody(globalTags)
    globalTags = globalTags or {}
    local body = engine.newTorso()
    engine.attachPart(body, "head", "human_head", globalTags)
    engine.attachPart(body, "left_arm", "human_arm", globalTags)
    engine.attachPart(body, "right_arm", "human_arm", globalTags)
    engine.attachPart(body, "left_leg", "human_leg", globalTags)
    engine.attachPart(body, "right_leg", "human_leg", globalTags)
    engine.attachPart(body.subSlots.left_arm, "hand", "human_hand", globalTags)
    engine.attachPart(body.subSlots.right_arm, "hand", "human_hand", globalTags)
    engine.attachPart(body.subSlots.left_leg, "foot", "human_foot", globalTags)
    engine.attachPart(body.subSlots.right_leg, "foot", "human_foot", globalTags)
    return body
end

-- Insectoid body plan: chitin skin/bone on the torso itself, which is what
-- unlocks the tail slot for a separate abdomen part (chitin-skinned too),
-- itself carrying its own stinger sub-part (see gamedata.lua's
-- partEntries.abdomen/partEntries.stinger - a small, precise structure at
-- the abdomen's tip rather than the abdomen's whole mass, hence its own
-- steep aimDifficulty), and the wing slots (deliberately left empty -
-- nothing attaches there yet). The torso itself is never relabeled or
-- otherwise repurposed - a torso is what every creature has, so this
-- species' own anatomy is expressed entirely in what attaches to it. A
-- head with its own antennae slot and an inherent UNSIGHTLY global tag.
-- Arms/legs/hands/feet are unchanged from the human plan - nothing about
-- this species is different there.
function engine.newInsectoidBody(globalTags)
    globalTags = globalTags or {}
    local body = engine.newTorso()
    engine.installCategoryOrgan(body, "skin", "chitin_skin", globalTags)
    engine.installCategoryOrgan(body, "bone", "chitin_bone", globalTags)

    -- chitin_bone's global grants (TAILED, WINGED) need to be knowable
    -- right now to unlock the tail slot below, rather than waiting on the
    -- caller's own post-construction engine.recalcGlobalTags pass.
    local unlockedTags = engine.recalcGlobalTags(body)
    for tag in pairs(globalTags) do
        unlockedTags[tag] = true
    end

    engine.attachPart(body, "head", "insectoid_head", unlockedTags)
    engine.attachPart(body, "left_arm", "human_arm", unlockedTags)
    engine.attachPart(body, "right_arm", "human_arm", unlockedTags)
    engine.attachPart(body, "left_leg", "human_leg", unlockedTags)
    engine.attachPart(body, "right_leg", "human_leg", unlockedTags)
    engine.attachPart(body.subSlots.left_arm, "hand", "human_hand", unlockedTags)
    engine.attachPart(body.subSlots.right_arm, "hand", "human_hand", unlockedTags)
    engine.attachPart(body.subSlots.left_leg, "foot", "human_foot", unlockedTags)
    engine.attachPart(body.subSlots.right_leg, "foot", "human_foot", unlockedTags)
    engine.attachPart(body, "tail", "abdomen", unlockedTags)
    engine.attachPart(body.subSlots.tail, "stinger", "stinger", unlockedTags)
    engine.attachPart(body.subSlots.head, "antennae", "antenna", unlockedTags)
    engine.installGenericOrgan(body.subSlots.head, "insectoid_features", unlockedTags)

    -- The endurance side of chitin skin's tradeoff: not extra health, a
    -- flat 10% damage reduction on every hit (see engine.damagePart) - applied to
    -- every part uniformly rather than baked into any one template, since
    -- most of these parts (arms/legs/hands/feet) are shared with the human
    -- body plan and shouldn't get it there. The reflex penalty side is
    -- applied separately, to the character stat itself - see speciesEntries.
    engine.walkBody(body, function(part)
        part.endurance = 0.1
    end)

    return body
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

-- Overwritten by character creation (see engine.runCharacterCreation, run once at
-- startup) - defaulted here so nothing reads a nil name/pronoun if that
-- somehow doesn't happen first.
player.name = "Adventurer"
player.pronouns = { subject = "they", object = "them" }

-- Per-quest progress ("active", "done" - not-yet-taken is just absent), and
-- a running tally of kills by typeId (see engine.showVictoryScreen) - quest
-- completion conditions read these instead of a bespoke flag per encounter.
player.quests = {}
player.killLog = {}

-- Body/globalTags are built once species is actually chosen (see
-- engine.runCharacterCreation, run once at startup, right before the first
-- engine.render) - defaulted here only so nothing reads a nil body if that
-- somehow doesn't happen first.
player.globalTags = {}
player.body = engine.newHumanBody(player.globalTags)

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


-- Environment interactions: * is an item, auto-collected (and logged, see
-- engine.logActivity) the moment the player steps onto it - no blurb needed
-- anymore; # is a solid wall (just a rectangle); !/?/0 are people (quest
-- not yet taken / quest active / nothing more to say); -/| are doors
-- (horizontal/vertical), opened or closed with no prompt either (see
-- engine.tryMove/engine.tryInteract) and shown as `.` while open; $ is a save point -
-- `saveId` is how a save file remembers which one made it, so loading
-- knows where to put the player back (see engine.findSavePointById).

--[[
    Screen is split into four corners:
    top-left     - compact numeric stats
    top-right    - sprite/portrait (placeholder for now)
    bottom-left  - map/text/table area, currently the walkable grid
    bottom-right - activity log (see engine.logActivity)
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
-- feedback goes instead. See engine.logActivity.
local logWin = window.create(term.current(), leftWidth + 1, topHeight + 1, screenW - leftWidth, screenH - topHeight)

-- Combat's "idle" state (waiting on the player's next action) gets the same
-- four-corner treatment as the overworld, rather than a single full-screen
-- window - map top-left, the action menu bottom-left, a scrolling combat
-- log top-right (see engine.logCombat - routine events report here instead of
-- interrupting with a prompt), and the enemies in the scene bottom-right
-- (Tab cycles which one's selected - see engine.drawEnemyList/engine.promptAction).
local combatMapWin = window.create(term.current(), 1, 1, leftWidth, topHeight)
local combatLogWin = window.create(term.current(), leftWidth + 1, 1, screenW - leftWidth, topHeight)
local combatActionWin = window.create(term.current(), 1, topHeight + 1, leftWidth, screenH - topHeight)
local combatEnemyWin = window.create(term.current(), leftWidth + 1, topHeight + 1, screenW - leftWidth, screenH - topHeight)

-- A full-screen takeover, shared by combat's own sub-pickers (choosing an
-- attack, a limb, an ability, a reload/belt target), victory/death,
-- engine.dialogue (engine.showInteraction), and character creation - anything that needs
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
-- engine.writeWrapped (below) and the activity log, which needs the lines as data
-- (to keep in its own scrolling buffer) rather than written straight to a
-- window.
function engine.wrapText(text, maxWidth)
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
-- actually fits gets drawn (see engine.drawLog), so this can just grow forever
-- without needing to cap or scroll it manually.
local activityLog = {}

function engine.drawLog()
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
-- full-screen messaging (engine.showCombatMessage) and doesn't need this; this is
-- specifically for everything that used to need a "press any key" prompt
-- but really didn't (picking something up, a door opening) or is otherwise
-- worth a record of (using an item outside a fight).
function engine.logActivity(message)
    local width = logWin.getSize()
    for _, line in ipairs(engine.wrapText(message, width)) do
        table.insert(activityLog, line)
    end
    engine.drawLog()
end

-- {{token}} -> a bit of the given character's identity, for writing engine.dialogue
-- without hardcoding whichever name/pronouns the player picked at character
-- creation. {{name}}, {{subject}}, and {{object}} are the real fields;
-- {{he}}/{{she}} and {{him}}/{{her}} are just aliases for subject/object, so
-- a line can be written with an imagined character in mind (he, she,
-- whichever reads naturally) and still come out in whoever's actually
-- playing. Unrecognized tokens are left alone rather than blanked out.
-- Moved up here (from beside engine.showInteraction, which also uses it) so
-- engine.logActivity's own callers - some of them well before that point in the
-- file - can use it too.
local DIALOGUE_ALIASES = {
    subject = "subject", he = "subject", she = "subject",
    object = "object", him = "object", her = "object",
}

function engine.dialogue(str, who)
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

function engine.drawStats()
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

function engine.drawSprite()
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
function engine.findObjectAt(loc, x, y)
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
function engine.getObjectGlyph(obj)
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

-- Where a viewW x viewH window should start reading from in `loc` to keep
-- (focusX, focusY) centered in it - clamped per axis so it never scrolls
-- past a room edge, and collapsing to 1 (no scrolling at all) whenever
-- the room is smaller than the viewport in that dimension.
function engine.getCameraOrigin(loc, focusX, focusY, viewW, viewH)
    local function axis(focus, size, view)
        local maxOrigin = math.max(1, size - view + 1)
        return math.max(1, math.min(focus - math.floor(view / 2), maxOrigin))
    end
    return axis(focusX, loc.width, viewW), axis(focusY, loc.height, viewH)
end

-- Shared by engine.drawMain and engine.drawCombatField: draws a
-- camera-centered viewport of `loc` into `win`, translating grid
-- coordinates to screen ones. Row 1 is always the location name; the
-- window's last row is always left alone (reserved for the caller's own
-- status line, if it has one - whether or not that row is filled in
-- keeps the usable viewport height identical frame to frame instead of
-- jumping around). `extraCells` (a list of `{x=, y=, glyph=}`) overlays
-- on top of the room itself - the player's own "@" always, combat's
-- enemies too. A cell outside the room's own bounds (the camera showing
-- past a small room's edge) renders as "~" rather than a real glyph.
-- Doesn't touch window visibility/clearing - the caller wraps that,
-- since it may still need to write into the reserved last row first.
-- Returns the camera origin used, so callers that need to translate grid
-- coordinates back into screen ones later (see combatState.flash) can.
function engine.drawRoomView(win, loc, focusX, focusY, extraCells)
    local winW, winH = win.getSize()
    local viewW, viewH = winW, winH - 2
    local camX, camY = engine.getCameraOrigin(loc, focusX, focusY, viewW, viewH)

    win.setCursorPos(1, 1)
    win.write(loc.name)

    local overlay = {}
    for _, cell in ipairs(extraCells) do
        overlay[cell.y] = overlay[cell.y] or {}
        overlay[cell.y][cell.x] = cell.glyph
    end

    for row = 1, viewH do
        local gridY = camY + row - 1
        local line = {}
        for col = 1, viewW do
            local gridX = camX + col - 1
            if gridX < 1 or gridX > loc.width or gridY < 1 or gridY > loc.height then
                line[col] = "~"
            elseif overlay[gridY] and overlay[gridY][gridX] then
                line[col] = overlay[gridY][gridX]
            else
                local obj = engine.findObjectAt(loc, gridX, gridY)
                line[col] = obj and engine.getObjectGlyph(obj) or "."
            end
        end
        win.setCursorPos(1, row + 1)
        win.write(table.concat(line))
    end

    return camX, camY
end

function engine.drawMain()
    local loc = world[player.location]

    mainWin.setVisible(false)
    mainWin.clear()

    engine.drawRoomView(mainWin, loc, player.gridX, player.gridY, {
        { x = player.gridX, y = player.gridY, glyph = "@" },
    })

    if message ~= "" then
        local _, winH = mainWin.getSize()
        mainWin.setCursorPos(1, winH)
        mainWin.write(message)
    end

    mainWin.setVisible(true)
end

function engine.render()
    engine.drawStats()
    engine.drawSprite()
    engine.drawMain()
    -- Re-draws the log's corner from its own retained buffer - a full-
    -- screen modal (combat, the inventory) draws right over it, and
    -- toggling setVisible(true) alone is a no-op if it's already true, so
    -- this can't just reassert visibility; it has to actually redraw.
    engine.drawLog()
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

function engine.drawTopBar()
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

-- Moved up from beside engine.pickAttack (which also uses it) so the inventory
-- screen's equip-slot detail panel can use it too.
function engine.formatDamageRange(range)
    if range.min == range.max then
        return tostring(range.min)
    end
    return range.min .. "-" .. range.max
end

-- Every MANIPULATE-tagged limb on a body, in the same stable depth-first
-- order engine.collectLabeledParts already produces - the set of slots a weapon
-- can actually be equipped into (see the inventory's "equip" rows), rather
-- than a hardcoded pair of hands that wouldn't generalize to some future
-- multi-limbed species.
function engine.getManipulateLimbs(combatant)
    local limbs = {}
    for _, entry in ipairs(engine.collectLabeledParts(combatant.body)) do
        if engine.getPartLocalTags(entry.part).MANIPULATE then
            table.insert(limbs, entry)
        end
    end
    return limbs
end

-- Every MANIPULATE hand currently wielding the same weapon as the one in
-- `label` - just that hand alone for an ordinary one-handed weapon (or an
-- empty one), every hand sharing a two-handed one otherwise, always in
-- stable body-tree order (see engine.collectLabeledParts). The first entry is
-- always the "canonical" hand for the group: where its one shared ammo
-- pool actually lives (character.ammo is still keyed per equip slot, so a
-- two-handed weapon just doesn't use the second one), and what represents
-- the whole thing in the inventory screen/attack list/ability list, so it
-- never gets listed or asked about twice over. Can come back shorter than
-- however many hands the weapon actually needs (`handedness == "two-
-- handed"` means 2, everything else 1) - gripped in just one hand
-- (see changeGrip, or drawing one from the belt/ground mid-fight) is
-- still "held", just not enough to actually use - every usability check
-- needs both this AND a hand count, not just this alone.
function engine.getWieldingHands(combatant, label)
    local weaponId = combatant.equipped[label]
    local weapon = weaponId and weaponEntries[weaponId]
    local hands = {}
    for _, entry in ipairs(engine.collectLabeledParts(combatant.body)) do
        if engine.getPartLocalTags(entry.part).MANIPULATE then
            if entry.label == label
                or (weapon and weapon.handedness == "two-handed" and combatant.equipped[entry.label] == weaponId) then
                table.insert(hands, entry)
            end
        end
    end
    return hands
end

-- A melee weapon's effective strength multiplier: a single hand's own
-- engine.getLimbStrength normally, or the average across every hand holding a
-- two-handed one - a reinforced arm on one side of the grip still pulls
-- its own weight, but a fracture on the other side drags the whole swing
-- down too, not just its own half. Ranged weapons never call this at all
-- (strength doesn't scale them regardless of hand count).
function engine.getWeaponStrength(combatant, entry, weapon)
    if weapon.handedness ~= "two-handed" then
        return engine.getLimbStrength(combatant, entry.part)
    end
    local hands = engine.getWieldingHands(combatant, entry.label)
    local total = 0
    for _, hand in ipairs(hands) do
        total = total + engine.getLimbStrength(combatant, hand.part)
    end
    return total / #hands
end

-- A unified view of "a slot that can hold a weapon or a plain item" - a
-- hand (`{kind="equip", slot=label}`) or a belt slot
-- (`{kind="belt", index=N}`). Both the inventory screen and the in-combat
-- Equipment action work with these, so what a slot holds and how it's
-- read/written lives in one place instead of two.

-- Every hand and belt slot, hands first, in the same stable order
-- engine.getManipulateLimbs/1..beltSize already give - except a two-handed
-- weapon's secondary hand (see engine.getWieldingHands), which is left out
-- entirely rather than listed as its own slot: it isn't one to swap into
-- or out of independently, only alongside its canonical hand.
function engine.getAllSlots(combatant)
    local slots = {}
    for _, limb in ipairs(engine.getManipulateLimbs(combatant)) do
        local weaponId = combatant.equipped[limb.label]
        local isSecondaryHand = weaponId and engine.getWieldingHands(combatant, limb.label)[1].label ~= limb.label
        if not isSecondaryHand then
            table.insert(slots, { kind = "equip", slot = limb.label })
        end
    end
    for i = 1, combatant.beltSize do
        table.insert(slots, { kind = "belt", index = i })
    end
    return slots
end

function engine.slotsEqual(a, b)
    return a.kind == b.kind and a.slot == b.slot and a.index == b.index
end

-- Whatever's in a slot: returns (weaponId, itemId) - at most one is ever
-- set, both nil if it's empty. A hand's own field (`equipped`) holds
-- either a weaponId or a plain itemId directly (disambiguated by which
-- table recognizes it - the two ids only ever collide when they *are* the
-- same thing, a weapon's own item form); a belt slot always holds an
-- itemId, which might itself represent a holstered weapon (`weaponId` on
-- the item entry) or a plain item.
function engine.getSlotContents(combatant, slotDescriptor)
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
function engine.getSlotAmmoKey(slotDescriptor)
    if slotDescriptor.kind == "equip" then
        return slotDescriptor.slot
    end
    return "belt" .. slotDescriptor.index
end

-- Empties a slot and hands back whatever was in it (weaponId, itemId,
-- ammo) so the caller can decide where it goes - this never sends
-- anything to the inventory itself, see engine.returnAmmoToInventory/
-- engine.depositAmmo for that.
function engine.clearSlot(combatant, slotDescriptor)
    local weaponId, itemId = engine.getSlotContents(combatant, slotDescriptor)
    local ammo = weaponId and combatant.ammo[engine.getSlotAmmoKey(slotDescriptor)] or nil
    if weaponId then
        combatant.ammo[engine.getSlotAmmoKey(slotDescriptor)] = nil
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
-- anything itself; clear the slot first (see engine.clearSlot) if it might not be.
function engine.fillSlot(combatant, slotDescriptor, weaponId, itemId, ammo)
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
-- empty. Used for a deliberate reassignment (the Equipment action) as
-- well as filling an empty slot from another one.
function engine.swapSlots(combatant, a, b)
    local aWeapon, aItem, aAmmo = engine.clearSlot(combatant, a)
    local bWeapon, bItem, bAmmo = engine.clearSlot(combatant, b)
    engine.fillSlot(combatant, a, bWeapon, bItem, bAmmo)
    engine.fillSlot(combatant, b, aWeapon, aItem, aAmmo)
end

-- Whether any currently-equipped weapon (either hand) actually uses ammo -
-- the action menu only shows Reload at all when this is true.
function engine.hasAmmoWeapon(combatant)
    for _, limb in ipairs(engine.getManipulateLimbs(combatant)) do
        local weaponId = engine.getSlotContents(combatant, { kind = "equip", slot = limb.label })
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
-- each. Each row carries enough to both engine.render its own list line and build
-- a detail panel for it.
function engine.getInventoryRows(combatant)
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
                countText = countText, bulkText = engine.formatBulk(item.bulk),
            })
        else
            table.insert(rows, {
                kind = "belt", index = i, itemId = nil,
                name = "Belt: Empty", countText = "", bulkText = "",
            })
        end
    end

    for _, limb in ipairs(engine.getManipulateLimbs(combatant)) do
        local weaponId, itemId = engine.getSlotContents(combatant, { kind = "equip", slot = limb.label })
        -- A two-handed weapon occupies more than one of these limbs at
        -- once (see engine.getWieldingHands) - only its canonical (first) hand
        -- gets a row at all, combining every hand's label into one, so it
        -- reads as one held weapon rather than two identical-looking rows
        -- fighting over which one's "real."
        local hands = weaponId and engine.getWieldingHands(combatant, limb.label) or nil
        local isSecondaryHand = hands and #hands > 1 and hands[1].label ~= limb.label
        if not isSecondaryHand then
            local label = limb.label
            if hands and #hands > 1 then
                local labels = {}
                for _, hand in ipairs(hands) do
                    table.insert(labels, hand.label)
                end
                label = table.concat(labels, "+")
            end
            if itemId then
                local item = itemEntries[itemId]
                table.insert(rows, {
                    kind = "equip", slot = limb.label, itemId = itemId,
                    name = label .. ": " .. item.name,
                    countText = "", bulkText = engine.formatBulk(item.bulk),
                })
            else
                local weapon = weaponId and weaponEntries[weaponId] or weaponEntries.strike
                -- A two-handed weapon gripped in fewer hands than it
                -- needs (see pickWieldingHands/changeGrip) still shows
                -- up here normally - this is the only hint on the row
                -- itself that it won't actually fire like this.
                local griptag = ""
                if weaponId and weapon.handedness == "two-handed" and hands and #hands < 2 then
                    griptag = " (can't fire - needs both hands)"
                end
                table.insert(rows, {
                    kind = "equip", slot = limb.label, weaponId = weaponId,
                    name = label .. ": " .. weapon.name .. griptag,
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
    end

    local groups = {}
    for _, itemId in ipairs(combatant.inventory) do
        local group = groups[itemId]
        if not group then
            group = {
                kind = "inventory", itemId = itemId, count = 0,
                name = itemEntries[itemId].name, bulkText = engine.formatBulk(itemEntries[itemId].bulk),
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
function engine.clampInventoryScroll(selection, scrollOffset, totalRows, visibleCount)
    if selection < scrollOffset + 1 then
        scrollOffset = selection - 1
    elseif selection > scrollOffset + visibleCount then
        scrollOffset = selection - visibleCount
    end
    return math.max(0, math.min(scrollOffset, math.max(0, totalRows - visibleCount)))
end

local INVENTORY_LIST_TOP = 4 -- row 1: title, row 2: page tabs, row 3: column headers

function engine.formatInventoryRow(name, countText, bulkText)
    return ("%-13s %-5s %-4s"):format(name:sub(1, 13), countText or "", bulkText or "")
end

-- Left half is the scrollable list (belt/ammo/inventory rows); right half is
-- detail on whatever's currently selected. Row 2 is the page-tab strip from
-- Tab - a skeleton for now (just the one "Inventory" page), meant for
-- whatever other pages come along later, exactly as originally pitched.
function engine.drawInventoryScreen(rows, selection, scrollOffset, pageBarVisible, currentPage, pages, carrying)
    inventoryWin.setVisible(false)
    inventoryWin.clear()

    local leftW = math.floor(screenW / 2)
    local rightX = leftW + 2

    inventoryWin.setCursorPos(1, 1)
    inventoryWin.write(carrying and ("Carrying: " .. carrying.name) or "Inventory")
    inventoryWin.setCursorPos(rightX, 1)
    inventoryWin.write(("Bulk %s/%s"):format(engine.formatBulk(engine.getTotalBulk(player)), engine.formatBulk(engine.getBulkCapacity(player))))

    if pageBarVisible then
        local tabs = {}
        for i, name in ipairs(pages) do
            table.insert(tabs, i == currentPage and ("[" .. name .. "]") or (" " .. name .. " "))
        end
        inventoryWin.setCursorPos(1, 2)
        inventoryWin.write(table.concat(tabs, " "))
    end

    inventoryWin.setCursorPos(1, 3)
    inventoryWin.write(engine.formatInventoryRow("Name", "Count", "Bulk"))

    local visibleCount = screenH - 1 - INVENTORY_LIST_TOP + 1
    for i = 1, visibleCount do
        local row = rows[scrollOffset + i]
        if row then
            local marker = (scrollOffset + i == selection) and ">" or " "
            inventoryWin.setCursorPos(1, INVENTORY_LIST_TOP + i - 1)
            inventoryWin.write(marker .. engine.formatInventoryRow(row.name, row.countText, row.bulkText))
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
                table.insert(detail, "Damage: " .. engine.formatDamageRange(weapon.damage) .. " " .. weapon.damageType)
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
                table.insert(detail, "Bulk: " .. engine.formatBulk(itemEntries[selected.itemId].bulk))
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
                table.insert(detail, "Bulk: " .. engine.formatBulk(itemEntries[selected.itemId].bulk))
                for _, abilityId in ipairs(itemEntries[selected.itemId].abilities or {}) do
                    table.insert(detail, "Grants: " .. abilityEntries[abilityId].name)
                end
                table.insert(detail, "")
                table.insert(detail, "[Move] to unequip")
            else
                local weapon = selected.weaponId and weaponEntries[selected.weaponId] or weaponEntries.strike
                table.insert(detail, "Damage: " .. engine.formatDamageRange(weapon.damage) .. " " .. weapon.damageType)
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
function engine.runInventoryScreen()
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
        rows = engine.getInventoryRows(player)
        selection = math.min(selection, math.max(1, #rows))
        scrollOffset = engine.clampInventoryScroll(selection, scrollOffset, #rows, visibleCount)
        engine.drawInventoryScreen(rows, selection, scrollOffset, pageBarVisible, currentPage, pages, carrying)
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
            -- carrying.from.slots is every hand it was lifted from (see
            -- Move's pickup handling above) - just one, normally, both
            -- for a two-handed weapon. Ammo only ever goes back on the
            -- first (canonical) one, same as it was taken from.
            for i, slot in ipairs(carrying.from.slots) do
                player.equipped[slot] = carrying.weaponId or carrying.itemId
                if carrying.weaponId and i == 1 then
                    player.ammo[slot] = carrying.ammo
                end
            end
        end
        carrying = nil
    end

    -- The dedicated picker Move falls into when a weapon needs more than
    -- one hand (see weaponEntries.handedness) - a plain "drop it on this
    -- slot" can't express "these two slots at once" the way it can a
    -- single hand. Same arrow-key-navigate/Enter-to-act feel as the rest
    -- of the inventory screen (rather than the digit-select combat
    -- pickers use) since it's part of that same flow. Each hand toggles
    -- independently (green once selected, back to white if toggled off
    -- again), capped at `handsNeeded`. Confirm needs at least one hand
    -- picked, but doesn't require all of them - equipping it "improperly"
    -- (see engine.getWieldingHands/changeGrip) is allowed, just gated behind a
    -- warning once fewer than `handsNeeded` are selected, since it won't
    -- actually be usable that way. Returns the chosen hand labels in
    -- stable body-tree order (so whichever's first is always the same
    -- one - see engine.getWieldingHands), or nil if the player backs out via
    -- Cancel (or declines the warning) instead. Nested here (rather than
    -- a top-level local) since only Move's own drop-handling below ever
    -- calls it - see "A note on locals" in the design doc.
    local function pickWieldingHands(handsNeeded, weaponName)
        local limbs = engine.getManipulateLimbs(player)
        local selected = {}
        local selectedCount = 0
        local cursor = 1
        local confirmRow = #limbs + 1
        local cancelRow = #limbs + 2

        local function selectedHands()
            local hands = {}
            for _, limb in ipairs(limbs) do
                if selected[limb.label] then
                    table.insert(hands, limb.label)
                end
            end
            return hands
        end

        while true do
            inventoryWin.setVisible(false)
            inventoryWin.clear()
            inventoryWin.setCursorPos(1, 1)
            inventoryWin.write(("Which %d hands hold the %s?"):format(handsNeeded, weaponName))

            for i, limb in ipairs(limbs) do
                local marker = (cursor == i) and ">" or " "
                inventoryWin.setCursorPos(1, 2 + i)
                inventoryWin.write(marker)
                if selected[limb.label] then
                    inventoryWin.setTextColor(colors.green)
                    inventoryWin.write("[x] " .. limb.label)
                    inventoryWin.setTextColor(colors.white)
                else
                    inventoryWin.write("[ ] " .. limb.label)
                end
            end

            local confirmMarker = (cursor == confirmRow) and ">" or " "
            inventoryWin.setCursorPos(1, 2 + #limbs + 1)
            local confirmLabel
            if selectedCount == 0 then
                confirmLabel = "Confirm (pick a hand)"
            elseif selectedCount < handsNeeded then
                confirmLabel = ("Confirm (%d/%d hands - won't be able to fire)"):format(selectedCount, handsNeeded)
            else
                confirmLabel = "Confirm"
            end
            inventoryWin.write(confirmMarker .. confirmLabel)

            local cancelMarker = (cursor == cancelRow) and ">" or " "
            inventoryWin.setCursorPos(1, 2 + #limbs + 2)
            inventoryWin.write(cancelMarker .. "Cancel")

            inventoryWin.setVisible(true)

            local _, key = os.pullEvent("key")
            if key == keys.up then
                cursor = math.max(1, cursor - 1)
            elseif key == keys.down then
                cursor = math.min(cancelRow, cursor + 1)
            elseif key == ACTIVATE_KEY then
                if cursor == cancelRow then
                    return nil
                elseif cursor == confirmRow and selectedCount == handsNeeded then
                    return selectedHands()
                elseif cursor == confirmRow and selectedCount > 0 then
                    -- Fewer hands than it needs - still allowed (see
                    -- changeGrip, the in-combat equivalent), but worth
                    -- warning about before committing to it, since
                    -- there's no way to tell just from the row afterward
                    -- that it's holding a paperweight.
                    inventoryWin.setVisible(false)
                    inventoryWin.clear()
                    inventoryWin.setCursorPos(1, 1)
                    inventoryWin.write(("With just %d hand%s, you won't be able to fire the %s."):format(
                        selectedCount, selectedCount == 1 and "" or "s", weaponName
                    ))
                    inventoryWin.setCursorPos(1, 3)
                    inventoryWin.write("[1] Equip anyway")
                    inventoryWin.setCursorPos(1, 4)
                    inventoryWin.write("[2] Back")
                    inventoryWin.setVisible(true)

                    while true do
                        local _, warnKey = os.pullEvent("key")
                        if warnKey == keys.one then
                            return selectedHands()
                        elseif warnKey == keys.two then
                            break
                        end
                    end
                elseif cursor == confirmRow then
                    -- Nothing picked yet - same "just don't respond"
                    -- convention as everywhere else invalid.
                else
                    local label = limbs[cursor].label
                    if selected[label] then
                        selected[label] = nil
                        selectedCount = selectedCount - 1
                    elseif selectedCount < handsNeeded then
                        selected[label] = true
                        selectedCount = selectedCount + 1
                    end
                end
            end
        end
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
                        engine.removeInventoryItems(player, entry.itemId, 1)
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
                        -- entry.slot is already the canonical hand for a
                        -- two-handed weapon (see engine.getInventoryRows - only
                        -- its row exists at all), so this lifts every
                        -- hand it occupies together, ammo included.
                        local hands = engine.getWieldingHands(player, entry.slot)
                        local ammo = player.ammo[hands[1].label]
                        local slots = {}
                        for _, hand in ipairs(hands) do
                            player.ammo[hand.label] = nil
                            player.equipped[hand.label] = "none"
                            table.insert(slots, hand.label)
                        end
                        carrying = {
                            weaponId = entry.weaponId, itemId = weaponEntries[entry.weaponId].itemId, ammo = ammo,
                            name = weaponEntries[entry.weaponId].name,
                            from = { kind = "equip", slots = slots },
                        }
                    elseif entry.kind == "equip" and entry.itemId then
                        player.equipped[entry.slot] = "none"
                        carrying = {
                            itemId = entry.itemId,
                            name = itemEntries[entry.itemId].name,
                            from = { kind = "equip", slots = { entry.slot } },
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
                if carrying.weaponId and weaponEntries[carrying.weaponId].handedness == "two-handed" and entry and entry.kind == "equip" then
                    -- A two-handed weapon can't just take the one slot it
                    -- was dropped on - which other hand joins it is
                    -- genuinely ambiguous the moment there's more than a
                    -- pair to choose from (a multi-limbed body), so this
                    -- always asks rather than guessing. Cancelling leaves
                    -- carrying untouched, same as dropping nowhere valid
                    -- normally would - try again, or Move it to the bag.
                    local hands = pickWieldingHands(2, weaponEntries[carrying.weaponId].name)
                    if hands then
                        for _, slot in ipairs(hands) do
                            local oldWeaponId, oldItemId = engine.getSlotContents(player, { kind = "equip", slot = slot })
                            if oldWeaponId then
                                engine.returnAmmoToInventory(player, oldWeaponId, slot)
                                local oldItemForm = weaponEntries[oldWeaponId].itemId
                                if oldItemForm then
                                    table.insert(player.inventory, oldItemForm)
                                end
                            elseif oldItemId then
                                table.insert(player.inventory, oldItemId)
                            end
                        end
                        for i, slot in ipairs(hands) do
                            player.equipped[slot] = carrying.weaponId
                            player.ammo[slot] = (i == 1) and carrying.ammo or nil
                        end
                        carrying = nil
                    end
                elseif carrying.weaponId and entry and entry.kind == "equip" then
                    if entry.weaponId then
                        engine.returnAmmoToInventory(player, entry.weaponId, entry.slot)
                        local oldItemId = weaponEntries[entry.weaponId].itemId
                        if oldItemId then
                            table.insert(player.inventory, oldItemId)
                        end
                    elseif entry.itemId then
                        table.insert(player.inventory, entry.itemId)
                    end
                    player.equipped[entry.slot] = carrying.weaponId
                    player.ammo[entry.slot] = carrying.ammo
                    carrying = nil
                elseif carrying.itemId and not carrying.weaponId and entry and entry.kind == "equip" then
                    if entry.weaponId then
                        engine.returnAmmoToInventory(player, entry.weaponId, entry.slot)
                        local oldItemId = weaponEntries[entry.weaponId].itemId
                        if oldItemId then
                            table.insert(player.inventory, oldItemId)
                        end
                    elseif entry.itemId then
                        table.insert(player.inventory, entry.itemId)
                    end
                    player.equipped[entry.slot] = carrying.itemId
                    carrying = nil
                elseif entry and entry.kind == "belt" and (carrying.itemId or carrying.weaponId)
                    -- A two-handed weapon doesn't fit in a belt slot at
                    -- all - falls through to the general-bag catch-all
                    -- below instead, same as any other invalid drop.
                    and not (carrying.weaponId and weaponEntries[carrying.weaponId].handedness == "two-handed") then
                    if entry.itemId then
                        if entry.weaponId then
                            engine.returnAmmoToInventory(player, entry.weaponId, "belt" .. entry.index)
                        end
                        table.insert(player.inventory, entry.itemId)
                    end
                    player.belt[entry.index] = carrying.itemId
                    if carrying.weaponId then
                        player.ammo["belt" .. entry.index] = carrying.ammo or 0
                    end
                    carrying = nil
                else
                    if carrying.itemId then
                        table.insert(player.inventory, carrying.itemId)
                    end
                    if carrying.weaponId then
                        engine.depositAmmo(player, carrying.weaponId, carrying.ammo)
                    end
                    carrying = nil
                end
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
                    engine.reloadWeapon(player, entry.slot)
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
                                engine.removeInventoryItems(player, entry.itemId, 1)
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
function engine.gridDistance(ax, ay, bx, by)
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

function engine.spawnTestDummy()
    local enemy = testDummyType:new()
    enemy.body = engine.newHumanBody()
    enemy.typeId = "test_dummy"

    -- Test case for damage types: a thick skull shrugs off blunt hits but is
    -- an easier target for anything that punches through.
    enemy.body.subSlots.head.resistances = { bludgeoning = 0.8, piercing = 1.2 }

    -- Test case for coverage inheritance: no species actually has horns yet,
    -- but attaching one anyway proves it protects exactly as well as the
    -- head it's stuck to, despite having no coverage zone of its own.
    engine.attachPart(enemy.body.subSlots.head, "horns", "horn", {})

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
function engine.getEffectiveAim(combatant)
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
function engine.getEffectiveReflex(combatant)
    local legs = { combatant.body.subSlots.left_leg, combatant.body.subSlots.right_leg }
    local total, count = 0, 0
    for _, leg in ipairs(legs) do
        if leg then
            total = total + engine.getLimbStrength(combatant, leg)
            count = count + 1
        end
    end
    local condition = count > 0 and (total / count) or 1
    return combatant.stats.reflex * condition
end

function engine.getHitChance(attacker, defender)
    return engine.getEffectiveAim(attacker) * (1 - engine.getEffectiveReflex(defender) / 2)
end

-- Spread only bites once there's actual empty space between attacker and
-- target - point blank (distance 1) is zero tiles walked, so it's a no-op
-- for anything with range 1, which is why ordinary melee never feels it.
-- `targetPart` is optional (callers that haven't picked one yet, like
-- engine.pickAttack's own weapon-choice preview, just skip this step) - when
-- given, its `aimDifficulty` (see engine.instantiatePart) divides the chance down
-- further, on top of spread: a small or fast-moving part is harder to land
-- a hit on than aiming dead center.
function engine.getFinalHitChance(attacker, defender, weapon, distance, targetPart)
    local base = engine.getHitChance(attacker, defender)
    local spreadPenalty = (weapon.spread / 100) * (distance - 1)
    local chance = math.max(0, base - spreadPenalty)
    local aimDifficulty = (targetPart and targetPart.aimDifficulty) or 1
    return chance / aimDifficulty
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
function engine.digitLabel(i)
    if i < 10 then
        return tostring(i)
    elseif i == 10 then
        return "0"
    else
        return string.char(string.byte("a") + i - 11)
    end
end

-- Window writes don't wrap on their own - text just runs past the edge and
-- gets silently clipped. Writes `text` at (x, y) using engine.wrapText, and
-- returns how many rows it used so the caller can stack whatever comes
-- next below it instead of assuming one line is always one row.
function engine.writeWrapped(win, x, y, text)
    local width = win.getSize()
    local maxWidth = math.max(1, width - x + 1)
    local lines = engine.wrapText(text, maxWidth)
    for i, line in ipairs(lines) do
        win.setCursorPos(x, y + i - 1)
        win.write(line)
    end
    return #lines
end

-- Reserved for the moments that genuinely warrant taking over the whole
-- screen and stopping the player in their tracks - victory, death - rather
-- than every routine swing and status tick (see engine.logCombat below for those).
function engine.showCombatMessage(lines, wait)
    combatWin.setVisible(false)
    combatWin.clear()
    local row = 1
    for _, line in ipairs(lines) do
        row = row + engine.writeWrapped(combatWin, 1, row, line)
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
-- activityLog/engine.drawLog/engine.logActivity (see those), just scoped to a single
-- fight and drawn into combatLogWin instead. Reset per encounter (see
-- engine.resetCombatLog) rather than left to grow across fights.
local combatActivityLog = {}

function engine.drawCombatLog()
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
-- a "Press any key" prompt. engine.showCombatMessage is still there for the small
-- handful of moments that actually deserve the player's full attention.
-- Pauses for combatState.logDelay after drawing so each line has a moment
-- to register before the next one appears - every call site gets this for
-- free, rather than each one having to remember to pace itself.
function engine.logCombat(message)
    local width = combatLogWin.getSize()
    for _, line in ipairs(engine.wrapText(message, width)) do
        table.insert(combatActivityLog, line)
    end
    engine.drawCombatLog()
    sleep(combatState.logDelay)
end

function engine.resetCombatLog()
    combatActivityLog = {}
    engine.drawCombatLog()
end

-- Shows the same real room engine.drawMain does (walls, doors, items and
-- all - see engine.drawRoomView) with every combatant in the scene
-- overlaid on top, so position (and thus range/spread) is something the
-- player can actually see and plan around. Drawn into its own top-left
-- pane rather than sharing a full-screen window with the action menu.
-- Stashes the camera origin it used on combatState so combatState.flash
-- can translate a hit's grid coordinates into the same screen space.
function engine.drawCombatField(loc, scene)
    combatMapWin.setVisible(false)
    combatMapWin.clear()

    local extraCells = { { x = player.gridX, y = player.gridY, glyph = "@" } }
    for _, foe in ipairs(scene) do
        table.insert(extraCells, { x = foe.gridX, y = foe.gridY, glyph = "E" })
    end

    combatState.cameraX, combatState.cameraY = engine.drawRoomView(combatMapWin, loc, player.gridX, player.gridY, extraCells)

    combatMapWin.setVisible(true)
end

-- Briefly flips a single map cell to red, for a hit landing - the map's
-- already sitting there visible from the last engine.drawCombatField, so this
-- just paints straight over the one cell rather than redrawing the whole
-- pane, then paints it back once combatState.logDelay has passed. Grid
-- coordinates have to go through the same camera translation
-- engine.drawRoomView used (see combatState.cameraX/Y, stashed by
-- engine.drawCombatField) now that the map can scroll - a cell that's
-- currently off-screen just doesn't flash at all rather than writing
-- into an unrelated part of the window.
function combatState.flash(x, y, symbol)
    local camX, camY = combatState.cameraX or 1, combatState.cameraY or 1
    local screenX, screenY = x - camX + 1, y - camY + 1
    local winW, winH = combatMapWin.getSize()
    if screenX < 1 or screenX > winW or screenY < 1 or screenY > winH - 2 then
        return
    end

    combatMapWin.setTextColor(colors.red)
    combatMapWin.setCursorPos(screenX, screenY + 1)
    combatMapWin.write(symbol)
    sleep(combatState.logDelay)
    combatMapWin.setTextColor(colors.white)
    combatMapWin.setCursorPos(screenX, screenY + 1)
    combatMapWin.write(symbol)
end

-- The bottom-right pane: every foe still in the scene, health included, with
-- the currently-selected one marked - Tab cycles it (see engine.promptAction).
-- Fight/Look/an ability's targeting all act on whichever's selected here.
function engine.drawEnemyList(scene, selectedIndex)
    combatEnemyWin.setVisible(false)
    combatEnemyWin.clear()
    combatEnemyWin.setCursorPos(1, 1)
    combatEnemyWin.write("Enemies (Tab to cycle)")
    for i, foe in ipairs(scene) do
        local marker = (i == selectedIndex) and ">" or " "
        local status = engine.isDead(foe.body) and " (dead)" or ""
        engine.writeWrapped(combatEnemyWin, 1, i + 2, ("%s%s  %d/%d%s"):format(
            marker, foe.name, foe.body.health, foe.body.maxHealth, status
        ))
    end
    combatEnemyWin.setVisible(true)
end

-- `combatState.loc`/`.scene` don't change for the life of an encounter, and
-- neither does `.selectedIndex` except via Tab - tracked here so anything
-- mid-resolution (an ability effect, engine.runEquipmentAction, a picker returning) can
-- put the map/enemy panes back the way they should look without needing
-- loc/scene threaded all the way through every call. Set once near the top
-- of engine.runEncounter and whenever the selection changes.

-- A fullscreen sub-picker (choosing an attack, a limb, an ability, a
-- reload/belt target) draws right over the map/enemy panes the same way
-- engine.showCombatMessage does - unlike engine.showCombatMessage's old blocking
-- "Press any key" though, resolution now continues straight into a paced
-- sequence of engine.logCombat/combatState.flash calls, so whatever picker was
-- showing needs putting right first, or those would be flashing over stale
-- picker text instead of the actual map. Call this right after any such
-- picker returns, before resolution logging begins.
function combatState.redrawPanes()
    if combatState.loc then
        engine.drawCombatField(combatState.loc, combatState.scene)
        engine.drawEnemyList(combatState.scene, combatState.selectedIndex)
        engine.drawCombatLog()

        -- The action menu itself isn't rebuilt here - reconstructing it
        -- needs `restricted`, which isn't in scope from every call site
        -- (an ability effect, engine.runEquipmentAction) - but its pane still needs
        -- clearing, or whatever a sub-picker just drew stays sitting there
        -- until the next real engine.promptAction call. Blank is a perfectly
        -- valid resting state since nothing reads a selection out of it
        -- mid-resolution anyway.
        combatActionWin.setVisible(false)
        combatActionWin.clear()
        combatActionWin.setVisible(true)
    end
end

-- restricted is true mid a quick action's bonus turn: Fight/Ability still
-- show up (some of what they offer might still be quick/instant), Look and
-- Idle always do since both are always quick or better, but Move's tag
-- reflects whether it would actually be allowed right now.
local ACTION_LABELS = {
    fight = "Fight", look = "Look (instant)", reload = "Reload (quick)",
    ability = "Ability", belt = "Equipment", idle = "Idle (quick)", flee = "Flee",
}

-- The main in-combat menu: Fight/Look/[Reload]/Ability/Belt/Idle/Flee,
-- numbered dynamically since Reload only appears when an equipped weapon
-- actually uses ammo (see engine.hasAmmoWeapon). Movement isn't a menu entry at
-- all - arrow keys reposition immediately, without a separate confirmation
-- step, so the player never has to open a sub-prompt just to take a step.
-- Tab cycles which enemy in the scene is selected (see engine.drawEnemyList) right
-- here in the same loop, without counting as a turn or an action of its
-- own. Returns (action, moveDir, selectedIndex); moveDir is only
-- meaningful when action == "move".
function engine.promptAction(loc, scene, selectedIndex, restricted)
    engine.drawCombatField(loc, scene)
    engine.drawEnemyList(scene, selectedIndex)
    engine.drawCombatLog()

    local moveTag = engine.getEffectiveReflex(player) >= REFLEX_QUICK_THRESHOLD and "quick" or "full"

    local options = { "fight", "look" }
    if engine.hasAmmoWeapon(player) then
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
        combatActionWin.write("[" .. engine.digitLabel(i) .. "] " .. ACTION_LABELS[action])
        row = row + 1
    end
    combatActionWin.setCursorPos(1, row)
    combatActionWin.write("Arrow keys to move (" .. moveTag .. ")")
    combatActionWin.setVisible(true)

    while true do
        local _, key = os.pullEvent("key")
        if key == keys.tab then
            selectedIndex = selectedIndex % #scene + 1
            engine.drawEnemyList(scene, selectedIndex)
        elseif debugConsole.enabled and debugConsole.openKeys[key] then
            debugConsole.run()
            combatState.redrawPanes()
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

function engine.scaleDamageRange(range, mult)
    return {
        min = math.floor(range.min * mult + 0.5),
        max = math.floor(range.max * mult + 0.5),
    }
end

-- Whatever's equipped in a limb's matching equip slot, or a bare Strike if
-- there's nothing there (or nothing anymore - see the inventory's equip
-- slots).
function engine.getWieldedWeapon(equipped, label)
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
function engine.getAttackWeapon(entry, equipped)
    if engine.getPartLocalTags(entry.part).MANIPULATE then
        return engine.getWieldedWeapon(equipped, entry.label)
    end
    local template = partEntries[entry.part.template]
    return template and template.naturalWeapon and weaponEntries[template.naturalWeapon] or nil
end

-- Lists every limb the attacker can actually fight with as a weapon choice
-- - MANIPULATE limbs (hands, by default) plus anything with a natural
-- weapon of its own (a stinger) - but only the ones currently in range and
-- still functional (see engine.isLimbFunctional: a destroyed arm takes its hand
-- down with it, a destroyed stinger just takes itself). A two-handed
-- weapon only ever shows up once, off its canonical hand (see
-- engine.getWieldingHands), and needs every hand holding it functional, not just
-- the one this loop happens to be looking at. Range is a hard cap, not a
-- penalty. STRENGTH only scales melee weapons (averaged across every hand
-- for a two-handed one - see engine.getWeaponStrength); spread is folded into the
-- shown hit chance for every weapon, melee included, since it's driven by
-- actual distance rather than weapon type. When restricted (mid a quick
-- action's bonus turn), two-handed weapons are left out entirely, same as
-- an out-of-range one - an out-of-ammo weapon is left out the same way.
-- Returns nil if nothing qualifies at all, or "back" (as the first value)
-- if the player explicitly backed out instead of picking one.
function engine.pickAttack(equipped, enemy, distance, restricted)
    local limbs = engine.collectLabeledParts(player.body)
    local options = {}
    for _, entry in ipairs(limbs) do
        local weapon = engine.getAttackWeapon(entry, equipped)
        if weapon then
            -- A two-handed weapon only ever surfaces once, from its
            -- canonical hand (see engine.getWieldingHands), needs every hand
            -- holding it functional (same idea as engine.isLimbFunctional's own
            -- ancestor walk, one level removed), and needs enough of them
            -- in the first place - gripped in just one hand (see
            -- changeGrip) is held, not usable.
            local isTwoHanded = weapon.handedness == "two-handed"
            local hands = isTwoHanded and engine.getWieldingHands(player, entry.label) or { entry }
            local isCanonical = hands[1].label == entry.label
            local enoughHands = #hands >= (isTwoHanded and 2 or 1)
            local allFunctional = true
            for _, hand in ipairs(hands) do
                if not engine.isLimbFunctional(hand.part) then
                    allFunctional = false
                    break
                end
            end
            if isCanonical and enoughHands and allFunctional then
                local isQuick = not isTwoHanded
                local hasAmmo = not weapon.ammoCapacity
                    or (player.ammo[entry.label] or 0) >= (weapon.ammoPerShot or 1)
                if distance <= weapon.range and (not restricted or isQuick) and hasAmmo then
                    table.insert(options, entry)
                end
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
        local weapon = engine.getAttackWeapon(entry, equipped)
        local hitPercent = math.floor(engine.getFinalHitChance(player, enemy, weapon, distance) * 100 + 0.5)
        local speedTag = weapon.handedness == "two-handed" and " (full)" or " (quick)"
        local ammoTag = weapon.ammoCapacity and (" [%d/%d ammo]"):format(player.ammo[entry.label] or 0, weapon.ammoCapacity) or ""
        local label = entry.label
        if weapon.handedness == "two-handed" then
            local labels = {}
            for _, hand in ipairs(engine.getWieldingHands(player, entry.label)) do
                table.insert(labels, hand.label)
            end
            label = table.concat(labels, "+")
        end
        local line
        if weapon.type == "melee" then
            local strength = player.stats.strength * engine.getWeaponStrength(player, entry, weapon)
            local scaled = engine.scaleDamageRange(weapon.damage, strength)
            line = ("[%s] %s - %s %s dmg x %d%% STR = %s dmg (%d%% to hit)%s%s"):format(
                engine.digitLabel(i), label, weapon.name, engine.formatDamageRange(weapon.damage),
                math.floor(strength * 100 + 0.5), engine.formatDamageRange(scaled), hitPercent, speedTag, ammoTag
            )
        else
            line = ("[%s] %s - %s %s dmg (ranged, %d%% to hit)%s%s"):format(
                engine.digitLabel(i), label, weapon.name, engine.formatDamageRange(weapon.damage), hitPercent, speedTag, ammoTag
            )
        end
        row = row + engine.writeWrapped(combatWin, 1, row, line)
    end
    local backIndex = #options + 1
    engine.writeWrapped(combatWin, 1, row, "[" .. engine.digitLabel(backIndex) .. "] Back")
    combatWin.setVisible(true)

    while true do
        local _, key = os.pullEvent("key")
        local index = keyToNumber[key]
        if index == backIndex then
            return "back", nil
        elseif index and options[index] then
            return options[index], engine.getAttackWeapon(options[index], equipped)
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
function engine.pickLimb(prompt, torso)
    local parts = engine.collectLabeledParts(torso)

    combatWin.setVisible(false)
    combatWin.clear()
    combatWin.setCursorPos(1, 1)
    combatWin.write(prompt)
    local row = 3
    for i, entry in ipairs(parts) do
        row = row + engine.writeWrapped(combatWin, 1, row, ("[%s] %s%s  %d/%d"):format(
            engine.digitLabel(i), string.rep("  ", entry.depth), entry.label, entry.part.health, entry.part.maxHealth
        ))
    end
    local backIndex = #parts + 1
    engine.writeWrapped(combatWin, 1, row, "[" .. engine.digitLabel(backIndex) .. "] Back")
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

-- Populates the bridge table gamedata.lua's content reaches back into the
-- engine through - see its own header comment for the full list with
-- signatures. Done here, in one block, once everything on that list
-- actually exists as a local (engine.pickLimb, just above, is the last one) -
-- gamedata.lua's own top-level code (building its tables, defining ability
-- effects/species builds/quest checks/greetings as functions) already ran
-- when it was required, further up, but nothing in it actually calls
-- Luadventure.anything eagerly - every reference sits inside a function
-- body that doesn't run until real gameplay, well after this point.
Luadventure.player = player
Luadventure.logActivity = engine.logActivity
Luadventure.logCombat = engine.logCombat
Luadventure.dialogue = engine.dialogue
Luadventure.pickLimb = engine.pickLimb
Luadventure.damagePart = engine.damagePart
Luadventure.healPart = engine.healPart
Luadventure.applyPartStatus = engine.applyPartStatus
Luadventure.applyCharacterStatus = engine.applyCharacterStatus
Luadventure.isDead = engine.isDead
Luadventure.isLimbFunctional = engine.isLimbFunctional
Luadventure.getLimbStrength = engine.getLimbStrength
Luadventure.getFinalHitChance = engine.getFinalHitChance
Luadventure.gridDistance = engine.gridDistance
Luadventure.collectLabeledParts = engine.collectLabeledParts
Luadventure.getPartLocalTags = engine.getPartLocalTags
Luadventure.walkBody = engine.walkBody
Luadventure.combatState = combatState
Luadventure.newTorso = engine.newTorso
Luadventure.attachPart = engine.attachPart
Luadventure.installCategoryOrgan = engine.installCategoryOrgan
Luadventure.installGenericOrgan = engine.installGenericOrgan
Luadventure.recalcGlobalTags = engine.recalcGlobalTags
Luadventure.newHumanBody = engine.newHumanBody
Luadventure.newInsectoidBody = engine.newInsectoidBody

-- A read-only version of engine.pickLimb's list, for the Look action - a size-up,
-- not a targeting prompt, so it never asks the player to choose one, just
-- waits for any key to close.
function engine.viewLimbs(prompt, torso)
    local parts = engine.collectLabeledParts(torso)

    combatWin.setVisible(false)
    combatWin.clear()
    combatWin.setCursorPos(1, 1)
    combatWin.write(prompt)
    local row = 3
    for _, entry in ipairs(parts) do
        row = row + engine.writeWrapped(combatWin, 1, row, ("%s%s  %d/%d"):format(
            string.rep("  ", entry.depth), entry.label, entry.part.health, entry.part.maxHealth
        ))
    end
    engine.writeWrapped(combatWin, 1, row + 1, "Press any key.")
    combatWin.setVisible(true)

    os.pullEvent("key")
end

-- Every ability granted by any organ anywhere in the combatant's body, by
-- anything currently equipped (a weapon's own abilities, like the chain
-- sword's Rev it up! or the laser pistol's Charge Shot), or by anything in
-- the belt (a consumable's own use-ability). Entries on cooldown are left
-- out entirely, same as engine.pickAttack simply not listing an out-of-range
-- weapon. Each entry carries the specific part that granted it (the
-- wielding hand, for a weapon ability), since an effect like Rev it up!
-- needs to know whose strength to use; a weapon ability also carries the
-- equip slot itself, since an ammo-based one (Charge Shot) needs to know
-- which ammo pool to draw from. itemId is set when it came from the belt,
-- so using it can consume it.
function engine.collectAbilities(combatant)
    local abilities = {}
    local function tryAdd(source, part, itemId, slot)
        for _, abilityId in ipairs(source.abilities or {}) do
            if abilityEntries[abilityId] and not combatant.cooldowns[abilityId] then
                table.insert(abilities, { id = abilityId, ability = abilityEntries[abilityId], part = part, itemId = itemId, slot = slot })
            end
        end
    end

    engine.walkBody(combatant.body, function(part)
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
            local hands = engine.getWieldingHands(combatant, slot)
            -- Only the canonical hand adds the weapon's abilities - same
            -- weapon, same ability, whichever hand(s) hold it (see
            -- engine.getWieldingHands); every hand sharing a two-handed one needs
            -- to still be working, same as an ordinary attack does (see
            -- engine.pickAttack) - Rev it up! shouldn't be usable with one side
            -- of a two-handed grip destroyed any more than a one-handed
            -- weapon is with its own hand gone - and it needs enough hands
            -- in the first place, gripped in just one (see changeGrip)
            -- isn't enough to swing it at all, let alone use what it grants.
            if hands[1].label == slot and #hands >= (weapon.handedness == "two-handed" and 2 or 1) then
                local allFunctional = true
                for _, hand in ipairs(hands) do
                    if not engine.isLimbFunctional(hand.part) then
                        allFunctional = false
                        break
                    end
                end
                if allFunctional then
                    tryAdd(weapon, hands[1].part, nil, slot)
                end
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
-- engine.pickAttack coming up empty when nothing's in range. When restricted (mid
-- a quick action's bonus turn), full-speed abilities are left out entirely.
function engine.pickAbility(combatant, restricted)
    local abilities = engine.collectAbilities(combatant)
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
        row = row + engine.writeWrapped(combatWin, 1, row, "[" .. engine.digitLabel(i) .. "] " .. entry.ability.name .. tag)
    end
    local backIndex = #abilities + 1
    engine.writeWrapped(combatWin, 1, row, "[" .. engine.digitLabel(backIndex) .. "] Back")
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
function engine.pickReloadTarget(combatant)
    local options = {}
    for slot, weaponId in pairs(combatant.equipped) do
        local weapon = weaponEntries[weaponId]
        -- A two-handed weapon's ammo only ever lives on its canonical hand
        -- (see engine.getWieldingHands) - skip a secondary hand entirely rather
        -- than offering to "reload" a pool that isn't actually there.
        local isSecondaryHand = weapon and engine.getWieldingHands(combatant, slot)[1].label ~= slot
        if weapon and not isSecondaryHand and weapon.ammoCapacity and (combatant.ammo[slot] or 0) < weapon.ammoCapacity then
            if engine.countCarriedItem(combatant, engine.getAmmoItemId(weapon)) > 0 then
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
        row = row + engine.writeWrapped(combatWin, 1, row, ("[%s] %s (%s) - %d/%d ammo"):format(
            engine.digitLabel(i), opt.weapon.name, opt.slot, combatant.ammo[opt.slot] or 0, opt.weapon.ammoCapacity
        ))
    end
    local backIndex = #options + 1
    engine.writeWrapped(combatWin, 1, row, "[" .. engine.digitLabel(backIndex) .. "] Back")
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

-- Display helpers shared by the Equipment action's pickers - "which slot"
-- and "what's in it", read off engine.getSlotContents rather than duplicating
-- the weapon-vs-item-vs-empty branching at every call site.
function engine.slotDisplayName(slotDescriptor)
    if slotDescriptor.kind == "equip" then
        return slotDescriptor.slot
    end
    return "Belt " .. slotDescriptor.index
end

function engine.slotOccupantName(combatant, slotDescriptor)
    local weaponId, itemId = engine.getSlotContents(combatant, slotDescriptor)
    if weaponId then
        return weaponEntries[weaponId].name
    elseif itemId then
        return itemEntries[itemId].name
    end
    return "Empty"
end

-- The Equipment action (renamed from Belt - it's grown well past just
-- that): every hand and belt slot shown together (a consumable held in a
-- hand behaves exactly like one on the belt), doing whatever its contents
-- imply - swap a weapon to another slot, use up a consumable on the spot,
-- or holster/draw a weapon from elsewhere (another slot, or one lying on
-- the ground this fight) into an empty one. A two-handed weapon is the
-- exception throughout: it can't go on the belt at all, a slot holding
-- one offers "change grip" instead of a swap, and drawing one always
-- lands in just one hand (see changeGrip and the branches below). When
-- restricted (mid a quick action's bonus turn), the swap/draw sub-actions
-- are always full - rather than filtering every slot up front by what
-- sub-action it implies, this follows the same "let them pick it, then
-- reject it" pattern Move has always used for a full action taken while
-- quickened; changing grip is quick either way, so it's never gated on
-- `restricted` at all. Returns the resolved speed, or nil if nothing
-- happened.
function engine.runEquipmentAction(combatant, droppedItems, enemy, restricted)
    -- Toggles a two-handed weapon between properly gripped (every hand it
    -- needs) and a single-hand "improper" carry it's still held by, just
    -- not usable with (see engine.getWieldingHands/engine.pickAttack) - quick either
    -- way, unlike actually drawing a fresh one from the belt or the
    -- ground below. Reducing asks which hand to keep if there's a real
    -- choice; increasing just claims however many empty hands it still
    -- needs, refusing if there aren't enough free, and migrates the
    -- shared ammo pool to whichever hand ends up canonical if that's not
    -- the one it was already on (see engine.getWieldingHands - canonical is
    -- whichever hand comes first in body-tree order, which adding a hand
    -- can change). Returns "quick" on success, nil (with its own message)
    -- otherwise. Only ever called for a two-handed weapon - see below.
    local function changeGrip(slot)
        local weaponId = combatant.equipped[slot]
        local weapon = weaponEntries[weaponId]
        local needed = 2
        local hands = engine.getWieldingHands(combatant, slot)

        if #hands >= needed then
            combatWin.setVisible(false)
            combatWin.clear()
            combatWin.setCursorPos(1, 1)
            combatWin.write("Keep the " .. weapon.name .. " in which hand?")
            local grow = 3
            for i, hand in ipairs(hands) do
                grow = grow + engine.writeWrapped(combatWin, 1, grow, "[" .. engine.digitLabel(i) .. "] " .. hand.label)
            end
            local gBackIndex = #hands + 1
            engine.writeWrapped(combatWin, 1, grow, "[" .. engine.digitLabel(gBackIndex) .. "] Back")
            combatWin.setVisible(true)

            local kept
            while true do
                local _, key = os.pullEvent("key")
                local index = keyToNumber[key]
                if index == gBackIndex then
                    return nil
                elseif index and hands[index] then
                    kept = hands[index]
                    break
                end
            end

            local ammo = combatant.ammo[hands[1].label]
            for _, hand in ipairs(hands) do
                if hand.label ~= kept.label then
                    combatant.equipped[hand.label] = "none"
                    combatant.ammo[hand.label] = nil
                end
            end
            combatant.equipped[kept.label] = weaponId
            combatant.ammo[kept.label] = ammo
            combatState.redrawPanes()
            engine.logCombat("You shift the " .. weapon.name .. " to a one-handed grip.")
            return "quick"
        end

        local freeHands = {}
        for _, limb in ipairs(engine.getManipulateLimbs(combatant)) do
            local slotWeaponId, slotItemId = engine.getSlotContents(combatant, { kind = "equip", slot = limb.label })
            if not slotWeaponId and not slotItemId and #freeHands < needed - #hands then
                table.insert(freeHands, limb)
            end
        end
        if #freeHands < needed - #hands then
            engine.logCombat("Not enough free hands to grip it properly.")
            return nil
        end

        local oldCanonical = hands[1].label
        for _, limb in ipairs(freeHands) do
            combatant.equipped[limb.label] = weaponId
        end
        local newCanonical = engine.getWieldingHands(combatant, slot)[1].label
        if newCanonical ~= oldCanonical then
            combatant.ammo[newCanonical] = combatant.ammo[oldCanonical]
            combatant.ammo[oldCanonical] = nil
        end
        combatState.redrawPanes()
        engine.logCombat("You grip the " .. weapon.name .. " properly.")
        return "quick"
    end

    local slots = engine.getAllSlots(combatant)

    combatWin.setVisible(false)
    combatWin.clear()
    combatWin.setCursorPos(1, 1)
    combatWin.write("Equipment - which slot?")
    local row = 3
    for i, slotDescriptor in ipairs(slots) do
        row = row + engine.writeWrapped(combatWin, 1, row, ("[%s] %s: %s"):format(
            engine.digitLabel(i), engine.slotDisplayName(slotDescriptor), engine.slotOccupantName(combatant, slotDescriptor)
        ))
    end
    local backIndex = #slots + 1
    engine.writeWrapped(combatWin, 1, row, "[" .. engine.digitLabel(backIndex) .. "] Back")
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

    local weaponId, itemId = engine.getSlotContents(combatant, chosen)

    if weaponId then
        -- A two-handed weapon only ever gets "change grip" here - a full
        -- re-equip (which two hands, from scratch) is the overworld
        -- inventory screen's own picker, and it can't go on the belt at
        -- all (see the empty-slot branch below), so there's nothing else
        -- a slot holding one could offer. Change grip is quick, so this
        -- isn't gated on `restricted` the way an actual swap is below.
        if weaponEntries[weaponId].handedness == "two-handed" then
            combatWin.setVisible(false)
            combatWin.clear()
            combatWin.setCursorPos(1, 1)
            combatWin.write(weaponEntries[weaponId].name .. " - what do you want to do?")
            engine.writeWrapped(combatWin, 1, 3, "[1] Change grip (quick)")
            engine.writeWrapped(combatWin, 1, 4, "[2] Back")
            combatWin.setVisible(true)

            while true do
                local _, key = os.pullEvent("key")
                local index = keyToNumber[key]
                if index == 2 then
                    return nil
                elseif index == 1 then
                    return changeGrip(chosen.slot)
                end
            end
        end

        if restricted then
            engine.logCombat("You don't have time to swap weapons.")
            return nil
        end

        local destinations = {}
        for _, slotDescriptor in ipairs(slots) do
            if not engine.slotsEqual(slotDescriptor, chosen) then
                table.insert(destinations, slotDescriptor)
            end
        end

        combatWin.setVisible(false)
        combatWin.clear()
        combatWin.setCursorPos(1, 1)
        combatWin.write("Swap " .. weaponEntries[weaponId].name .. " to where?")
        local drow = 3
        for i, slotDescriptor in ipairs(destinations) do
            drow = drow + engine.writeWrapped(combatWin, 1, drow, ("[%s] %s: %s"):format(
                engine.digitLabel(i), engine.slotDisplayName(slotDescriptor), engine.slotOccupantName(combatant, slotDescriptor)
            ))
        end
        local dBackIndex = #destinations + 1
        engine.writeWrapped(combatWin, 1, drow, "[" .. engine.digitLabel(dBackIndex) .. "] Back")
        combatWin.setVisible(true)

        while true do
            local _, key = os.pullEvent("key")
            local index = keyToNumber[key]
            if index == dBackIndex then
                return nil
            elseif index and destinations[index] then
                local destination = destinations[index]
                local destWeaponId, destItemId = engine.getSlotContents(combatant, destination)
                engine.swapSlots(combatant, chosen, destination)
                combatState.redrawPanes()
                if destWeaponId then
                    engine.logCombat("You swap your " .. weaponEntries[weaponId].name .. " for the " .. weaponEntries[destWeaponId].name .. "!")
                elseif destItemId then
                    engine.logCombat("You stow your " .. weaponEntries[weaponId].name .. " and take the " .. itemEntries[destItemId].name .. " in hand.")
                else
                    engine.logCombat("You holster your " .. weaponEntries[weaponId].name .. ".")
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
        engine.clearSlot(combatant, chosen)
        return ability.speed
    else
        if restricted then
            engine.logCombat("You don't have time to holster a weapon.")
            return nil
        end

        -- A two-handed weapon can't be *holstered* mid-fight (nowhere to
        -- put it - see the belt's own restriction), but it can still be
        -- *drawn* into a bare hand, same "just don't list it" filtering
        -- as everywhere else applied only to the belt side of things.
        local candidates = {}
        for _, slotDescriptor in ipairs(slots) do
            local candidateWeaponId = engine.getSlotContents(combatant, slotDescriptor)
            if candidateWeaponId and not (chosen.kind == "belt" and weaponEntries[candidateWeaponId].handedness == "two-handed") then
                table.insert(candidates, { kind = "slot", slotDescriptor = slotDescriptor, weaponId = candidateWeaponId })
            end
        end
        for i, dropped in ipairs(droppedItems) do
            if not (chosen.kind == "belt" and weaponEntries[dropped.weaponId].handedness == "two-handed") then
                table.insert(candidates, { kind = "dropped", index = i, weaponId = dropped.weaponId })
            end
        end

        if #candidates == 0 then
            engine.logCombat("Nothing to holster.")
            return nil
        end

        combatWin.setVisible(false)
        combatWin.clear()
        combatWin.setCursorPos(1, 1)
        combatWin.write("Holster which weapon?")
        local crow = 3
        for i, candidate in ipairs(candidates) do
            local source = candidate.kind == "slot" and engine.slotDisplayName(candidate.slotDescriptor) or "ground"
            crow = crow + engine.writeWrapped(combatWin, 1, crow, ("[%s] %s (%s)"):format(
                engine.digitLabel(i), weaponEntries[candidate.weaponId].name, source
            ))
        end
        local cBackIndex = #candidates + 1
        engine.writeWrapped(combatWin, 1, crow, "[" .. engine.digitLabel(cBackIndex) .. "] Back")
        combatWin.setVisible(true)

        while true do
            local _, key = os.pullEvent("key")
            local index = keyToNumber[key]
            if index == cBackIndex then
                return nil
            elseif index and candidates[index] then
                local candidate = candidates[index]
                -- A two-handed weapon drawn this way always ends up in
                -- just this one hand (see changeGrip for reaching a
                -- proper grip afterward) - wherever it's coming from
                -- empties out entirely, ammo included, rather than
                -- trying to fill a second hand nobody chose.
                if weaponEntries[candidate.weaponId].handedness == "two-handed" then
                    local ammo = 0
                    if candidate.kind == "slot" then
                        local hands = engine.getWieldingHands(combatant, candidate.slotDescriptor.slot)
                        ammo = combatant.ammo[hands[1].label] or 0
                        for _, hand in ipairs(hands) do
                            combatant.equipped[hand.label] = "none"
                            combatant.ammo[hand.label] = nil
                        end
                    else
                        table.remove(droppedItems, candidate.index)
                    end
                    combatant.equipped[chosen.slot] = candidate.weaponId
                    combatant.ammo[chosen.slot] = ammo
                elseif candidate.kind == "slot" then
                    engine.swapSlots(combatant, chosen, candidate.slotDescriptor)
                else
                    table.remove(droppedItems, candidate.index)
                    engine.fillSlot(combatant, chosen, candidate.weaponId, nil, 0)
                end
                combatState.redrawPanes()
                engine.logCombat("You draw the " .. weaponEntries[candidate.weaponId].name .. "!")
                return "full"
            end
        end
    end
end

-- Knocks whatever's equipped in a slot right out of the player's hands -
-- a destroyed hand (see engine.runEncounter's enemy-attack branch), or later, some
-- disarm effect. A two-handed weapon only actually falls once every hand
-- holding it is gone (see engine.getWieldingHands) - called again later for the
-- last one, it clears every slot the group occupied together and returns
-- its one shared ammo pool (tracked on whichever hand was canonical) to
-- the bag exactly once, not per hand. A weapon is removed from `equipped`
-- entirely and tracked in `droppedItems` until it's picked back up mid-
-- fight (see engine.runEquipmentAction's empty-slot branch) or auto-returned to the
-- inventory once the encounter ends; a plain consumable just falls
-- straight back into the pack instead, since it was never "wielded" in
-- the first place - there's nothing to clatter to the ground or reclaim.
-- Returns the dropped weapon's id, or nil if that slot had nothing
-- equipped, held a plain item instead of a weapon, or is still held by
-- another functional hand.
function engine.dropEquippedItem(droppedItems, slot)
    local weaponId, itemId = engine.getSlotContents(player, { kind = "equip", slot = slot })
    if itemId then
        player.equipped[slot] = "none"
        table.insert(player.inventory, itemId)
        return nil
    end
    if not weaponId then
        return nil
    end
    local hands = engine.getWieldingHands(player, slot)
    for _, hand in ipairs(hands) do
        if hand.label ~= slot and engine.isLimbFunctional(hand.part) then
            return nil
        end
    end
    engine.returnAmmoToInventory(player, weaponId, hands[1].label)
    for _, hand in ipairs(hands) do
        player.equipped[hand.label] = "none"
    end
    table.insert(droppedItems, { slot = slot, weaponId = weaponId })
    return weaponId
end

-- "The scene" is whoever's left to fight this encounter - just one enemy
-- for now, but written as a list so a real search-and-destroy encounter
-- (several foes at once) falls out for free later.
function engine.sceneCleared(scene)
    for _, foe in ipairs(scene) do
        if not engine.isDead(foe.body) then
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
function engine.showVictoryScreen(scene)
    local lines = { "Victory!", "" }
    for _, foe in ipairs(scene) do
        player.killLog[foe.typeId] = (player.killLog[foe.typeId] or 0) + 1
        table.insert(lines, "The " .. foe.name .. " collapses.")
    end
    table.insert(lines, "")
    table.insert(lines, "Press any key.")
    engine.showCombatMessage(lines, true)
end

-- "The test dummy" for one, "the test dummy and the goblin" for two, an
-- Oxford-comma list for more - for the activity log's "fought" line, which
-- otherwise reads oddly for a scene with more than one foe in it (nothing
-- spawns more than one yet, but scene's already a list - see "Victory").
function engine.joinEnemyNames(scene)
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
function engine.runEncounter(triggeringObject)
    local startX, startY = player.gridX, player.gridY
    local enemy = engine.spawnTestDummy()
    local scene = { enemy }
    local loc = world[player.location]

    -- Whichever entry in `scene` Fight/Look/an ability's targeting acts on
    -- - Tab cycles this in engine.promptAction. Only one foe exists yet, so this
    -- never actually moves, but the plumbing's in place for whenever a
    -- second one shows up.
    local selectedEnemyIndex = 1
    combatState.loc, combatState.scene, combatState.selectedIndex = loc, scene, selectedEnemyIndex

    -- Fights happen wherever the enemy actually is on the map, not
    -- somewhere randomly reshuffled - real walls/doors only mean anything
    -- if position carries over from the moment the fight actually starts.
    enemy.gridX, enemy.gridY = triggeringObject.x, triggeringObject.y

    engine.resetCombatLog()
    engine.logActivity(engine.dialogue("{{name}} fought " .. engine.joinEnemyNames(scene) .. ".", player))
    engine.logCombat("A " .. enemy.name .. " attacks!")

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
    -- engine.isLimbFunctional).
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
        if engine.sceneCleared(scene) then
            engine.showVictoryScreen(scene)
            engine.logActivity(engine.dialogue("{{name}} won the fight!", player))

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

        local action, moveDir, newSelectedIndex = engine.promptAction(loc, scene, selectedEnemyIndex, quickened)
        selectedEnemyIndex = newSelectedIndex
        combatState.selectedIndex = selectedEnemyIndex
        local foe = scene[selectedEnemyIndex]

        if action == "flee" then
            engine.logCombat("You break off and flee.")
            engine.logActivity(engine.dialogue("{{name}} fled.", player))
            returnUnclaimedDrops()
            return false
        end

        -- Set by whichever branch below actually resolves something; nil
        -- means "nothing happened" (rejected/no-op), which re-prompts
        -- without changing `quickened` at all.
        local speed = nil

        if action == "move" then
            local moveIsQuick = engine.getEffectiveReflex(player) >= REFLEX_QUICK_THRESHOLD
            if quickened and not moveIsQuick then
                engine.logCombat("You don't have time to move.")
            else
                local delta = dirDelta[moveDir]
                local nx, ny = player.gridX + delta.dx, player.gridY + delta.dy
                if nx >= 1 and nx <= loc.width and ny >= 1 and ny <= loc.height then
                    player.gridX, player.gridY = nx, ny
                    speed = moveIsQuick and "quick" or "full"

                    -- The step itself should feel instant - redraw the map
                    -- with the player already in the new spot right away,
                    -- rather than leaving it showing the old position for
                    -- as long as whatever comes next (the enemy's turn,
                    -- with its own paced engine.logCombat calls) takes to resolve.
                    combatState.redrawPanes()
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
            engine.viewLimbs("The " .. foe.name .. "'s condition:", foe.body)
            speed = "instant"
        end

        if action == "ability" then
            local entry = engine.pickAbility(player, quickened)
            combatState.redrawPanes()
            if entry == "back" then
                -- cancelled, nothing happened
            elseif not entry then
                engine.logCombat("You have nothing to use.")
            else
                local result = entry.ability.effect(player, foe, entry.part, entry.slot)

                if result ~= "noop" then
                    if entry.itemId and entry.slot then
                        -- A consumable held in a hand rather than the belt
                        -- (see engine.collectAbilities) - consumed by clearing
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
            local distance = engine.gridDistance(player.gridX, player.gridY, foe.gridX, foe.gridY)
            local attacker, weapon = engine.pickAttack(player.equipped, foe, distance, quickened)
            combatState.redrawPanes()

            if attacker == "back" then
                -- cancelled, nothing happened
            elseif not attacker then
                engine.logCombat("Nothing is in range.")
            else
                local target, label = engine.pickLimb("Target the " .. foe.name .. "'s:", foe.body)
                combatState.redrawPanes()

                if target then
                    local hitChance = engine.getFinalHitChance(player, foe, weapon, distance, target)
                    local hitPercent = math.floor(hitChance * 100 + 0.5)
                    speed = weapon.handedness == "two-handed" and "full" or "quick"

                    -- Firing burns ammo whether it hits or not.
                    if weapon.ammoCapacity then
                        player.ammo[attacker.label] = player.ammo[attacker.label] - (weapon.ammoPerShot or 1)
                    end

                    local attackerLabel = attacker.label
                    if weapon.handedness == "two-handed" then
                        local labels = {}
                        for _, hand in ipairs(engine.getWieldingHands(player, attacker.label)) do
                            table.insert(labels, hand.label)
                        end
                        attackerLabel = table.concat(labels, "+")
                    end

                    engine.logCombat("Your " .. attackerLabel .. " swings with " .. weapon.name .. " at the " .. foe.name .. "'s " .. label .. " (" .. hitPercent .. "% to hit)...")

                    if math.random() > hitChance then
                        engine.logCombat("You miss!")
                    else
                        local strength = 1
                        if weapon.type == "melee" then
                            strength = player.stats.strength * engine.getWeaponStrength(player, attacker, weapon)
                        end
                        local roll = math.random(weapon.damage.min, weapon.damage.max)
                        local raw = math.floor(roll * strength + 0.5)
                        local dealt = engine.damagePart(foe, target, raw, weapon.damageType)
                        if weapon.onHit then
                            weapon.onHit(target)
                        end

                        engine.logCombat("Hits for " .. dealt .. "! (" .. target.health .. "/" .. target.maxHealth .. ")")
                        combatState.flash(foe.gridX, foe.gridY, "E")
                    end
                end
            end
        end

        if action == "reload" then
            local target = engine.pickReloadTarget(player)
            combatState.redrawPanes()
            if target == "back" then
                -- cancelled, nothing happened
            elseif not target then
                engine.logCombat("Nothing to reload.")
            else
                local loaded = engine.reloadWeapon(player, target.slot)
                engine.logCombat("You reload the " .. target.weapon.name .. ". Loaded " .. loaded .. " (" .. player.ammo[target.slot] .. "/" .. target.weapon.ammoCapacity .. ")")
                speed = "quick"
            end
        end

        if action == "belt" then
            speed = engine.runEquipmentAction(player, droppedItems, foe, quickened)
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
            if not engine.sceneCleared(scene) then
                local decision = enemy:decide({
                    self = enemy,
                    player = player,
                    distance = engine.gridDistance(player.gridX, player.gridY, enemy.gridX, enemy.gridY),
                })

                if decision.action == "move" then
                    enemy.gridX = math.max(1, math.min(loc.width, enemy.gridX + decision.dx))
                    enemy.gridY = math.max(1, math.min(loc.height, enemy.gridY + decision.dy))
                    engine.logCombat("The " .. enemy.name .. " closes in!")
                elseif decision.action == "attack" then
                    local weapon = weaponEntries.strike
                    local distance = engine.gridDistance(player.gridX, player.gridY, enemy.gridX, enemy.gridY)
                    -- Picked before the roll (not after landing a hit) so
                    -- its aimDifficulty, if any, actually factors into the
                    -- chance - same order the player's own Fight action
                    -- already uses (engine.pickLimb, then engine.getFinalHitChance).
                    local parts = engine.collectLabeledParts(player.body)
                    local pick = parts[math.random(#parts)]
                    local enemyHitChance = engine.getFinalHitChance(enemy, player, weapon, distance, pick.part)
                    local enemyHitPercent = math.floor(enemyHitChance * 100 + 0.5)

                    engine.logCombat("The " .. enemy.name .. " attacks (" .. enemyHitPercent .. "% to hit)...")

                    if math.random() > enemyHitChance then
                        engine.logCombat("It misses!")
                    else
                        local roll = math.random(weapon.damage.min, weapon.damage.max)
                        local raw = math.floor(roll * enemy.stats.strength + 0.5)
                        local dealt = engine.damagePart(player, pick.part, raw, weapon.damageType)
                        if weapon.onHit then
                            weapon.onHit(pick.part)
                        end

                        engine.logCombat("Hits your " .. pick.label .. " for " .. dealt .. "! (" .. pick.part.health .. "/" .. pick.part.maxHealth .. ")")
                        combatState.flash(player.gridX, player.gridY, "@")

                        -- Death is the one AI-turn outcome that still stops
                        -- the player in their tracks with a full screen,
                        -- same as victory - everything else here is routine
                        -- enough for the log.
                        if engine.isDead(player.body) then
                            engine.showCombatMessage({ "You died.", "", "Press any key." }, true)
                            returnUnclaimedDrops()
                            return true
                        end

                        -- A destroyed hand can't hold onto anything - the
                        -- weapon actually falls, rather than just sitting
                        -- unusable in a slot attached to a ruined hand (an
                        -- arm being destroyed instead just disables
                        -- attacking - see engine.isLimbFunctional/engine.pickAttack -
                        -- nothing gets dropped for that).
                        if pick.part.health <= 0 then
                            local droppedWeaponId = engine.dropEquippedItem(droppedItems, pick.label)
                            if droppedWeaponId then
                                engine.logCombat("Your " .. pick.label .. " goes limp - the " .. weaponEntries[droppedWeaponId].name .. " clatters to the ground!")
                            end
                        end
                    end
                end
                -- decision.action == "idle": nothing happens.
            end

            -- A full round has now actually elapsed - this is "the start of
            -- your next turn" as far as status durations (and anything that
            -- ticks damage before decrementing, like bleed) are concerned.
            for _, tick in ipairs(engine.applyDamageOverTime(player)) do
                local verb = DOT_VERBS[tick.statusId] or "takes damage"
                engine.logCombat("Your " .. tick.label .. " " .. verb .. " for " .. tick.dealt .. "!")
                combatState.flash(player.gridX, player.gridY, "@")
            end
            for _, tick in ipairs(engine.applyDamageOverTime(enemy)) do
                local verb = DOT_VERBS[tick.statusId] or "takes damage"
                engine.logCombat("The " .. enemy.name .. "'s " .. tick.label .. " " .. verb .. " for " .. tick.dealt .. "!")
                combatState.flash(enemy.gridX, enemy.gridY, "E")
            end

            if engine.isDead(player.body) then
                engine.showCombatMessage({ "You died.", "", "Press any key." }, true)
                returnUnclaimedDrops()
                return true
            end

            engine.decrementStatuses(player)
            engine.decrementStatuses(enemy)
            engine.decrementCooldowns(player)
            engine.decrementCooldowns(enemy)
        end
    end
end

-- A blurb followed by a numbered menu of choices, for exploration-time
-- interactions - same digit/letter scheme as everywhere else, just outside
-- combat. Lines are run through engine.dialogue() first, so any blurb/greeting/
-- quest line in the game can freely use {{name}}/{{subject}}/{{object}}
-- without every call site needing to remember to do it itself.
function engine.showInteraction(lines, options)
    combatWin.setVisible(false)
    combatWin.clear()
    local row = 1
    for _, line in ipairs(lines) do
        row = row + engine.writeWrapped(combatWin, 1, row, engine.dialogue(line, player))
    end
    row = row + 1 -- blank line before the option list
    for i, option in ipairs(options) do
        row = row + engine.writeWrapped(combatWin, 1, row, "[" .. engine.digitLabel(i) .. "] " .. option)
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
function engine.interactWithPerson(obj)
    if not obj.questId then
        local greeting = obj.greetingId and dynamicGreetings[obj.greetingId]() or obj.greeting
        engine.showInteraction(greeting or { "\"...\"" }, { "Leave" })
        return
    end

    local quest = questEntries[obj.questId]
    local state = player.quests[obj.questId]

    if state == "active" and quest.isReady() then
        engine.showInteraction(quest.turnInLines, { "Continue" })
        if quest.rewardItemId then
            table.insert(player.inventory, quest.rewardItemId)
        end
        player.quests[obj.questId] = "done"
        obj.questId = quest.nextQuestId
    elseif state == "active" then
        engine.showInteraction(quest.activeLines, { "Leave" })
    else
        local choice = engine.showInteraction(quest.offerLines, { "Accept", "Not now" })
        if choice == 1 then
            player.quests[obj.questId] = "active"
        end
    end
end

local SAVE = { dir = "saves", slotCount = 5 }

function engine.getSaveSlotPath(slot)
    return fs.combine(SAVE.dir, "slot" .. slot .. ".sav")
end

function engine.readSaveSlot(slot)
    local path = engine.getSaveSlotPath(slot)
    if not fs.exists(path) then
        return nil
    end
    local h = fs.open(path, "r")
    local content = h.readAll()
    h.close()
    return textutils.unserialize(content)
end

function engine.writeSaveSlot(slot, data)
    if not fs.exists(SAVE.dir) then
        fs.makeDir(SAVE.dir)
    end
    local h = fs.open(engine.getSaveSlotPath(slot), "w")
    -- allow_repetitions: nothing in save data should genuinely be a shared
    -- table (see dynamicGreetings for how conditional engine.dialogue avoids this
    -- exact problem), but this is cheap insurance against a future
    -- accidental one triggering the same "cannot serialize table with
    -- repeated entries" error again instead of just duplicating the data.
    h.write(textutils.serialize(data, { allow_repetitions = true }))
    h.close()
end

-- Scans every location for the save_point object a given save was made at -
-- that's the only thing about "where" a save actually remembers (see
-- engine.buildSaveData); a save from a terminal that's since been removed just
-- can't be repositioned and falls back to wherever the player already is.
function engine.findSavePointById(saveId)
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
function engine.findSpawnSpotNear(loc, obj)
    for _, delta in ipairs(SPAWN_OFFSETS) do
        local nx, ny = obj.x + delta[1], obj.y + delta[2]
        if nx >= 1 and nx <= loc.width and ny >= 1 and ny <= loc.height and not engine.findObjectAt(loc, nx, ny) then
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
function engine.buildWorldSnapshot()
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
function engine.applyWorldSnapshot(snapshot)
    for locName, objects in pairs(snapshot) do
        if world[locName] then
            world[locName].objects = objects
        end
    end
end

-- Everything about the player worth remembering across a save: full body
-- (health/organs/statuses), gear, and progress - position isn't part of it,
-- just which save point made the save (see engine.findSavePointById/engine.applySaveData).
-- Also captures the whole world's current object state (see
-- engine.buildWorldSnapshot) - a save should remember what's changed out there,
-- not just the player's own stats.
function engine.buildSaveData(saveId)
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
        body = engine.serializeBodyPart(player.body),
        world = engine.buildWorldSnapshot(),
    }
end

-- The reverse of engine.buildSaveData - overwrites the live player in place with
-- everything a save remembers, then repositions to whichever save point
-- made it.
function engine.applySaveData(data)
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

    player.body = engine.deserializeBodyPart(data.body, true)
    player.globalTags = engine.recalcGlobalTags(player.body)

    engine.applyWorldSnapshot(data.world)

    local locName, obj = engine.findSavePointById(data.saveId)
    if locName and obj then
        player.location = locName
        player.gridX, player.gridY = engine.findSpawnSpotNear(world[locName], obj)
    end
end

-- A slot's menu label: what's actually in it, so save/load can show a
-- summary instead of just a bare number.
function engine.formatSaveSlotLabel(slot)
    local data = engine.readSaveSlot(slot)
    if not data then
        return "Slot " .. slot .. ": Empty"
    end
    local locName = engine.findSavePointById(data.saveId)
    local place = (locName and world[locName].name) or "Unknown"
    return "Slot " .. slot .. ": Lv" .. data.stats.level .. " - " .. data.steps .. " steps - " .. place
end

-- Same digit/letter-menu convention as everywhere else, plus a trailing
-- "Back" option to cancel out without picking a slot.
function engine.pickSaveSlot(title)
    local options = {}
    for slot = 1, SAVE.slotCount do
        options[slot] = engine.formatSaveSlotLabel(slot)
    end
    options[SAVE.slotCount + 1] = "Back"

    local choice = engine.showInteraction({ title }, options)
    if choice == SAVE.slotCount + 1 then
        return nil
    end
    return choice
end

function engine.doSave(saveId)
    local slot = engine.pickSaveSlot("Save to which slot?")
    if not slot then
        return
    end
    if engine.readSaveSlot(slot) then
        local choice = engine.showInteraction({ "Overwrite this slot?" }, { "Yes", "No" })
        if choice ~= 1 then
            return
        end
    end
    engine.writeSaveSlot(slot, engine.buildSaveData(saveId))
    engine.showInteraction({ "Saved." }, { "Continue" })
end

function engine.doLoad()
    local slot = engine.pickSaveSlot("Load which slot?")
    if not slot then
        return
    end
    local data = engine.readSaveSlot(slot)
    if not data then
        engine.showInteraction({ "That slot is empty." }, { "Continue" })
        return
    end
    engine.applySaveData(data)
    engine.showInteraction({ "Loaded." }, { "Continue" })
end

-- The save point itself: an ID-card terminal offering save/load/quit,
-- looping back to its own menu after save or load so one visit can do
-- several things. Returns (playerDied, quitRequested) - the second is new,
-- since this is the one interaction that can end the program outright.
function engine.interactWithSavePoint(obj)
    while true do
        local choice = engine.showInteraction(
            { "You insert your ID into the terminal.", "It hums to life." },
            { "Save", "Load", "Quit Game", "Leave" }
        )
        if choice == 1 then
            engine.doSave(obj.saveId)
        elseif choice == 2 then
            engine.doLoad()
        elseif choice == 3 then
            return false, true
        else
            return false, false
        end
    end
end

-- Picking something off the ground has no downside, so it just happens the
-- moment the player reaches it - no prompt, just a couple of log lines
-- (see engine.logActivity) instead of the old blurb-and-choice. Shared by engine.tryMove
-- (stepping onto it) and engine.tryInteract (reaching for one still adjacent
-- without stepping onto it).
function engine.collectItem(loc, obj)
    table.insert(player.inventory, obj.itemId)
    for i, o in ipairs(loc.objects) do
        if o == obj then
            table.remove(loc.objects, i)
            break
        end
    end
    engine.logActivity(engine.dialogue("{{name}} picked up " .. itemEntries[obj.itemId].name .. ".", player))
end

-- Same idea for a door: opening (or closing) one is harmless enough not to
-- need a prompt either - see engine.tryMove (bumping a closed one opens it) and
-- engine.tryInteract (the only way to close one again). `open` names which state
-- it's ending up in, purely for the log line.
function engine.toggleDoor(obj, open)
    obj.open = open
    engine.logActivity(engine.dialogue("{{name}} " .. (open and "opened" or "closed") .. " the door.", player))
end

-- Resolves walking into whatever's occupying the destination cell -
-- anything that still warrants an actual prompt (a person, a save point, a
-- fight) rather than just happening. Returns (playerDied, quitRequested) -
-- true playerDied if the player died fighting an enemy object, true
-- quitRequested if they chose to quit at a save point; both bubble all the
-- way back up to the main loop. Items and (closed) doors never reach this -
-- both callers (engine.tryMove, engine.tryInteract) handle those themselves.
function engine.interactWithObject(loc, obj)
    if obj.kind == "person" then
        engine.interactWithPerson(obj)
    elseif obj.kind == "save_point" then
        return engine.interactWithSavePoint(obj)
    elseif obj.kind == "enemy" then
        local playerDied = engine.runEncounter(obj)
        return playerDied, false
    end
    return false, false
end

-- Movement is grid-based; walking off an edge that has a matching exit
-- moves the player to the connected location, entering from the opposite
-- edge. Returns (moved, playerDied, quitRequested) - walking into an object
-- never counts as moving, but might still end the game (a fight lost, or a
-- save point's "Quit Game").
function engine.tryMove(dir)
    local loc = world[player.location]
    local delta = dirDelta[dir]
    local nx, ny = player.gridX + delta.dx, player.gridY + delta.dy

    if nx >= 1 and nx <= loc.width and ny >= 1 and ny <= loc.height then
        local obj = engine.findObjectAt(loc, nx, ny)

        if obj and obj.kind == "item" then
            -- Walking onto it is the whole interaction - see engine.collectItem.
            player.gridX, player.gridY = nx, ny
            player.steps = player.steps + 1
            engine.collectItem(loc, obj)
            message = ""
            return true, false, false
        end

        if obj and obj.kind == "door" and not obj.open then
            -- Bumping a closed door just opens it, no prompt - but that's
            -- the whole action for this turn, same as bumping into
            -- anything else that was blocking the way; stepping through
            -- happens on the *next* move, once it's actually open.
            engine.toggleDoor(obj, true)
            message = ""
            return false, false, false
        end

        local blocked = obj and not (obj.kind == "door" and obj.open)
        if blocked then
            local playerDied, quitRequested = engine.interactWithObject(loc, obj)
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
    engine.logActivity(engine.dialogue("{{name}} went to " .. nextLoc.name .. ".", player))
    return true, false, false
end

-- The dedicated interact key: checks each of the four cardinal-adjacent
-- tiles (never diagonals - keeps things precise if two interactables ever
-- end up right next to each other) for something to interact with, and
-- acts on the first one found (up, then down, left, right). Doors are the
-- main reason this exists at all - opening one is automatic on a bump (see
-- engine.tryMove), but there's no other way to *close* one again. Returns
-- (playerDied, quitRequested), same convention as engine.tryMove/
-- engine.interactWithObject, since anything reachable this way could end the game
-- the same way bumping into it would.
function engine.tryInteract()
    local loc = world[player.location]
    for _, dir in ipairs({ "up", "down", "left", "right" }) do
        local delta = dirDelta[dir]
        local obj = engine.findObjectAt(loc, player.gridX + delta.dx, player.gridY + delta.dy)
        if obj then
            if obj.kind == "item" then
                engine.collectItem(loc, obj)
                return false, false
            elseif obj.kind == "door" then
                engine.toggleDoor(obj, not obj.open)
                return false, false
            else
                return engine.interactWithObject(loc, obj)
            end
        end
    end
    return false, false
end

-- Reads a single line of free text at (x, y) in the given window - "char"
-- events give the actual typed character (already shift/caps-aware), "key"
-- only matters here for backspace/enter. Used for character creation's name
-- and custom-pronoun fields, where a numbered menu doesn't fit.
function engine.promptText(win, x, y, maxLen)
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

-- The rest of the debug console (`debugConsole` itself, and `.enabled`,
-- were declared way up near the top of the file - see the comment there).

-- Which key opens it (see debugConsole.run) - keys.grave is the "real"
-- CC:Tweaked keycode for backtick/tilde, but CraftOS-PC's ncurses CLI
-- renderer (what this project is actually developed/tested against)
-- instead passes the raw ASCII value through for this particular key - 96
-- unshifted (`), 126 shifted (~) - neither of which matches keys.grave.
-- Checking all three covers both that renderer and a real Minecraft
-- client.
debugConsole.openKeys = { [keys.grave] = true, [96] = true, [126] = true }

-- Finds a labeled part on the player's own body by name - every debug
-- command below targets the player only (no enemy-targeting syntax yet;
-- nothing needs it while there's only one enemy type to test against).
function debugConsole.findPart(label)
    for _, entry in ipairs(engine.collectLabeledParts(player.body)) do
        if entry.label == label then
            return entry.part
        end
    end
    return nil
end

-- Every debug command name -> function(args) -> a result string. `args` is
-- whatever space-separated tokens followed the command name. A bad limb/
-- item/status name is reported back as a normal result rather than
-- raising, so a typo doesn't need special-casing to avoid crashing the
-- console - see debugConsole.runCommand for the one pcall that catches
-- anything that slips through anyway.
debugConsole.commands = {
    -- setHealth <limb> <health> - clamps to [0, maxHealth], same range any
    -- ordinary damage/heal would land in.
    setHealth = function(args)
        if not args[1] or not tonumber(args[2]) then
            return "Usage: setHealth <limb> <health>"
        end
        local part = debugConsole.findPart(args[1])
        if not part then
            return "No such limb: " .. args[1]
        end
        part.health = math.max(0, math.min(part.maxHealth, tonumber(args[2])))
        return args[1] .. " set to " .. part.health .. "/" .. part.maxHealth
    end,

    -- give <itemId> [count] - straight into the inventory, no bulk check -
    -- debug commands are meant to bypass normal rules on purpose.
    give = function(args)
        if not args[1] or not itemEntries[args[1]] then
            return "Usage: give <itemId> [count] - unknown item: " .. tostring(args[1])
        end
        local count = tonumber(args[2]) or 1
        for _ = 1, count do
            table.insert(player.inventory, args[1])
        end
        return "Gave " .. count .. "x " .. itemEntries[args[1]].name
    end,

    -- addStatus <limb> <status> [amount] - only part-scoped statuses
    -- (bleed, poison, fracture) - character-wide ones (adrenaline) aren't
    -- reachable this way, since every command here targets a limb.
    -- `amount` overrides the status's own default duration/stack count,
    -- same as engine.applyPartStatus always allowed.
    addStatus = function(args)
        if not args[1] or not args[2] then
            return "Usage: addStatus <limb> <status> [amount]"
        end
        local part = debugConsole.findPart(args[1])
        if not part then
            return "No such limb: " .. args[1]
        end
        local def = statusEntries[args[2]]
        if not def or def.scope ~= "part" then
            return "No such part status: " .. args[2]
        end
        engine.applyPartStatus(part, args[2], tonumber(args[3]))
        return "Applied " .. args[2] .. " to " .. args[1] .. " (" .. part.statuses[args[2]] .. ")"
    end,

    -- clearStatus <limb> <status|all>
    clearStatus = function(args)
        if not args[1] or not args[2] then
            return "Usage: clearStatus <limb> <status|all>"
        end
        local part = debugConsole.findPart(args[1])
        if not part then
            return "No such limb: " .. args[1]
        end
        if args[2] == "all" then
            part.statuses = {}
            return "Cleared all statuses from " .. args[1]
        end
        part.statuses[args[2]] = nil
        return "Cleared " .. args[2] .. " from " .. args[1]
    end,

    help = function()
        return "setHealth <limb> <hp> | give <item> [n] | addStatus <limb> <status> [n] | clearStatus <limb> <status|all> | exit"
    end,
}

-- Splits on whitespace - "setHealth left_hand 50" becomes {"setHealth",
-- "left_hand", "50"}. No quoting support; nothing here needs it, since
-- every limb/item/status id is already a single bare token.
function debugConsole.splitLine(line)
    local tokens = {}
    for token in line:gmatch("%S+") do
        table.insert(tokens, token)
    end
    return tokens
end

-- Runs one line, returns (resultLine, shouldClose). A totally unexpected
-- error (a bug in a command itself, not just a bad argument) is caught
-- here too, so a broken debug command can't take the whole game down.
function debugConsole.runCommand(line)
    local tokens = debugConsole.splitLine(line)
    local name = tokens[1]
    if not name then
        return nil, false
    end
    if name == "exit" or name == "close" then
        return nil, true
    end

    local fn = debugConsole.commands[name]
    if not fn then
        return "Unknown command: " .. name .. " (try 'help')", false
    end

    local args = {}
    for i = 2, #tokens do
        args[i - 1] = tokens[i]
    end

    local ok, result = pcall(fn, args)
    if not ok then
        return "Error: " .. tostring(result), false
    end
    return result, false
end

-- A slim scrollback + input line, fullscreen like every other one-off
-- prompt (reuses combatWin) - gated behind DEBUG_MODE at both places this
-- can be opened from (the overworld's main loop, combat's engine.promptAction),
-- so there's no path to it at all unless --debug was passed at startup.
-- Opening/closing it doesn't cost a turn or otherwise touch the action
-- economy - closing (via 'exit'/'close') just hands control back to
-- whatever had it, same as it never happened.
function debugConsole.run()
    local transcript = { "Debug console - 'help' for commands, 'exit' to close." }

    local function redraw()
        combatWin.setVisible(false)
        combatWin.clear()
        local width, height = combatWin.getSize()
        local inputRow = height
        local visibleCount = inputRow - 1
        local startIndex = math.max(1, #transcript - visibleCount + 1)
        for i = startIndex, #transcript do
            combatWin.setCursorPos(1, i - startIndex + 1)
            combatWin.write(transcript[i])
        end
        combatWin.setCursorPos(1, inputRow)
        combatWin.write("> ")
        combatWin.setVisible(true)
        return width, inputRow
    end

    while true do
        local width, inputRow = redraw()
        local line = engine.promptText(combatWin, 3, inputRow, width - 3)

        for _, wrapped in ipairs(engine.wrapText("> " .. line, width)) do
            table.insert(transcript, wrapped)
        end

        local result, shouldClose = debugConsole.runCommand(line)
        if shouldClose then
            return
        end
        if result then
            for _, wrapped in ipairs(engine.wrapText(result, width)) do
                table.insert(transcript, wrapped)
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

function engine.pickPronouns()
    local options = {}
    for i, preset in ipairs(PRONOUN_PRESETS) do
        options[i] = preset.label
    end
    options[#PRONOUN_PRESETS + 1] = "Custom pronouns"

    local choice = engine.showInteraction({ "Choose your gender identity:" }, options)
    if choice <= #PRONOUN_PRESETS then
        local preset = PRONOUN_PRESETS[choice]
        return preset.subject, preset.object
    end

    combatWin.setVisible(false)
    combatWin.clear()
    combatWin.setCursorPos(1, 1)
    combatWin.write("Subject pronoun (e.g. he/she/they):")
    combatWin.setVisible(true)
    local subject = engine.promptText(combatWin, 1, 2, 20)

    combatWin.setVisible(false)
    combatWin.clear()
    combatWin.setCursorPos(1, 1)
    combatWin.write("Object pronoun (e.g. him/her/them):")
    combatWin.setVisible(true)
    local object = engine.promptText(combatWin, 1, 2, 20)

    return subject, object
end

-- Display order for the species menu - speciesEntries (defined alongside
-- engine.newHumanBody/engine.newInsectoidBody) has everything else about each one.
local SPECIES_ORDER = { "human", "insectoid" }

function engine.pickSpecies()
    local options = {}
    for i, id in ipairs(SPECIES_ORDER) do
        options[i] = speciesEntries[id].name
    end
    local choice = engine.showInteraction({ "Choose your species:" }, options)
    return SPECIES_ORDER[choice]
end

-- Five points, each worth a flat +5% to one of strength/reflex/aim (added
-- once, in engine.runCharacterCreation - not compounding, so 3 points in strength
-- is stats.strength = 1 + 3*0.05 = 1.15). "Reset" clears all of them back to
-- 0 rather than supporting per-point undo, which is enough for a one-time
-- five-point spend. Confirm is locked out until every point is spent.
local STAT_ALLOCATION = { points = 5, step = 0.05 }

function engine.runStatAllocation()
    local points = { strength = 0, reflex = 0, aim = 0 }
    local remaining = STAT_ALLOCATION.points

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
            remaining = STAT_ALLOCATION.points
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
function engine.runCharacterCreation()
    combatWin.setVisible(false)
    combatWin.clear()
    combatWin.setCursorPos(1, 1)
    combatWin.write("What is your name?")
    combatWin.setVisible(true)
    player.name = engine.promptText(combatWin, 1, 2, 20)

    player.pronouns.subject, player.pronouns.object = engine.pickPronouns()

    local species = speciesEntries[engine.pickSpecies()]
    player.globalTags = {}
    player.body = species.build(player.globalTags)

    -- A chest implant lets the player pop adrenaline for a turn on demand
    -- via the Ability action, instead of it just being permanently on -
    -- every species starts with one, same as before species existed at all.
    engine.installGenericOrgan(player.body, "adrenal_auto_injector", player.globalTags)
    player.globalTags = engine.recalcGlobalTags(player.body)

    for stat, delta in pairs(species.statAdjustments) do
        player.stats[stat] = player.stats[stat] + delta
    end

    local points = engine.runStatAllocation()
    player.stats.strength = player.stats.strength + points.strength * STAT_ALLOCATION.step
    player.stats.reflex = player.stats.reflex + points.reflex * STAT_ALLOCATION.step
    player.stats.aim = player.stats.aim + points.aim * STAT_ALLOCATION.step
end

-- The title screen, shown once at startup before there's any character to
-- speak of yet - engine.showInteraction's engine.dialogue() templating is safe to call
-- this early since none of these lines actually contain a {{...}} token
-- (engine.dialogue only ever touches player.name/pronouns for a match it finds).
-- Load Save applies straight onto the live player object via engine.applySaveData
-- - the same path the in-game save terminal's own Load uses - so loading
-- doesn't need a throwaway character run through creation first. Returns
-- "new", "load", or "quit".
function engine.runMainMenu()
    while true do
        local choice = engine.showInteraction({ "Luadventure", "" }, { "New Game", "Load Save", "Quit" })
        if choice == 1 then
            return "new"
        elseif choice == 2 then
            local slot = engine.pickSaveSlot("Load which slot?")
            if slot then
                local data = engine.readSaveSlot(slot)
                if not data then
                    engine.showInteraction({ "That slot is empty." }, { "Continue" })
                else
                    engine.applySaveData(data)
                    return "load"
                end
            end
            -- cancelled or empty: back to the main menu
        else
            return "quit"
        end
    end
end

local menuChoice = engine.runMainMenu()
if menuChoice == "quit" then
    return
end
if menuChoice == "new" then
    engine.runCharacterCreation()
end
engine.render()

local topBarOpen = false

while true do
    local event, key = os.pullEvent("key")
    if key == keys.q then
        break
    end

    if debugConsole.enabled and debugConsole.openKeys[key] then
        debugConsole.run()
        engine.render()
    elseif topBarOpen then
        if key == keys.tab then
            topBarOpen = false
            pageBarWin.setVisible(false)
            engine.render()
        elseif key == keys.left then
            topBarPage = (topBarPage - 2) % #TOP_BAR_PAGES + 1
            engine.drawTopBar()
        elseif key == keys.right then
            topBarPage = topBarPage % #TOP_BAR_PAGES + 1
            engine.drawTopBar()
        elseif key == ACTIVATE_KEY then
            topBarOpen = false
            pageBarWin.setVisible(false)
            engine.runInventoryScreen() -- the only page so far
            engine.render()
        end
    elseif key == keys.tab then
        topBarOpen = true
        topBarPage = 1
        engine.drawTopBar()
    elseif key == keys.i then
        engine.runInventoryScreen()
        engine.render()
    elseif key == keys.space then
        local playerDied, quitRequested = engine.tryInteract()
        if playerDied or quitRequested then
            break
        end
        engine.render()
    else
        local dir = keyToDir[key]
        if dir then
            local moved, playerDied, quitRequested = engine.tryMove(dir)
            if playerDied or quitRequested then
                break
            end
            engine.render()
        end
    end
end