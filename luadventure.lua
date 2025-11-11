-- Fuck it, why not? Sci-fi fantasy RPG game, in lua, designed for CraftOS.
-- penits

local world = {} -- Gotta define this early...

-- A single, uniquely-named global for if I need one.
Luadventure = {

}

-- TODO
-- Part entries are a library of every potential bodypart in the game. Will be worked on later.
local partEntries = {

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
    locations -- table of directions
)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o.name = name or error("Location must have a name!", 2)
    o.directions = locations or {}
    return o
 end

local player = {
    location = "village",
    stats = {
        level = 0,
        health = 10,
        max_health = 10, -- Modified by armor and possibly clothes
        dr = 0, -- Modified by some armors.
        weight = 0, -- How many things *currently* being held by the player.
        max_inventory = 5 -- Maximum things the player can carry, modified by clothes + possibly backpack
    },
    inventory = {},
    equipped = {
        left_hand = "none",
        right_hand = "none",
        armor = "none",
        clothes = "basic_clothes", -- Default items don't take up inventory space and are always considered in the player's posession.
        backpack = "none"
    },
    body = { -- Player starts as human.
        head = "human",
        torso = "human",
        left_arm = "human",
        right_arm = "human",
        left_leg = "human",
        right_leg = "human",
        tail = "none",
        wings = "none",
        horns = "none",
    }
}

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

print(world.village.name)
for dir, dest in pairs(world.village.directions) do
    print(dir, dest)
end

print(world.grasslands.name)
for dir, dest in pairs(world.grasslands.directions) do
    print(dir, dest)
end

local source = world.village
local dest = world.village:navigate("right")
print("Right of " .. source.name .. " is " .. dest.name)