Logger = {}
Logger.__index = Logger

do
    function Logger:new(debugEnabled, inspect)
        ---@type Logger
        local object = setmetatable({}, self)

        object.debugEnabled = debugEnabled
        object.inspect = inspect
        object.inspectOptions = {
            process = function(item, path)
                if (item == "logger") then
                    return nil
                end

                return item
            end
        }

        object.eventTracker = nil

        return object
    end

    ---@type fun(message: string, vars: any)
    function Logger:info(message, vars)
        self:print("info", message, vars);
    end

    ---@type fun(message: string, vars: any)
    function Logger:debug(message, vars)
        if self.debugEnabled == false then
            return
        end

        self:print("debug", message, vars);
    end

    ---@type fun(message: string, vars: any)
    function Logger:warn(message, vars)
        if (self.eventTracker) then
            self.eventTracker:sendError(message, vars)
        end

        self:print("warn", message, vars);
    end

    ---@type fun(message: string, vars: any)
    function Logger:error(message, vars)
        if (self.eventTracker) then
            self.eventTracker:sendError(message, vars)
        end

        self:print("error", message, vars);
        self:print("error", debug.traceback())
    end

    ---@type fun(message: string)
    function Logger:fatal(message)
        if (self.eventTracker) then
            self.eventTracker:sendError(message)
        end

        env.error(string.format("%s\n%s", message, debug.traceback()), true)
    end

    ---@type fun(prefix: string, message: string, vars: any)
    function Logger:print(prefix, message, vars)
        if message == nil then
            self:error('Empty message passed')
            message = ""
        end

        local msg = "[" .. prefix .. "] " .. message
        env.info(msg)

        if (vars and self.inspect) then
            env.info(self.inspect(vars, self.inspectOptions))
            env.info('-------')
        end
    end
end

EventUtil = {}

do
    local isSP = false
    local hasClientSlots = nil

    if (net.get_server_id() == 0) then
        isSP = true
        hasClientSlots = world.getPlayer() == nil
    end

    ---@param event event
    EventUtil.isPlayerEvent = function(event)
        if event.initiator and event.initiator.getPlayerName then
            local player = event.initiator:getPlayerName()

            return player ~= nil
        end

        return false
    end

    ---@param event event
    EventUtil.isPlayerBirthEvent = function(event)
        if (isSP and not hasClientSlots) then
            -- In single-player, birth events are not triggered when there's only a "player" slot.
            -- There is however, a simulation start event that can function as birth, but only if there are no "client" slots
            if (event.id == world.event.S_EVENT_SIMULATION_START) then
                event.initiator = world.getPlayer()

                return true
            end

            return false
        end

        return event.id == world.event.S_EVENT_BIRTH and EventUtil.isPlayerEvent(event)
    end
end

Util = {}

do
    ---@param unit Unit
    ---@return number Heading in degrees
    Util.getHeading = function(unit)
        local position = unit:getPosition()
        local heading = math.deg(math.atan2(position.x.z, position.x.x))

        if (heading < 0) then
            return heading + 360
        end

        return heading
    end

    Util.pointShiftByDegrees = function(point, degrees, meters)
        return Util.pointShiftByRadians(point, math.rad(degrees), meters)
    end

    Util.pointShiftByRadians = function(point, radians, meters)
        return {
            x = point.x + math.cos(radians) * meters,
            y = point.y,
            z = point.z + math.sin(radians) * meters
        }
    end

    Util.length = function(table)
        local count = 0

        for _ in pairs(table) do
            count = count + 1
        end

        return count
    end
end


---@class MenuRegistry
---@field logger Logger
---@field menus Menu[]
MenuRegistry = {}
MenuRegistry.__index = MenuRegistry

---@class Menu
---@field index number Index of the menu, to ensure order is preserved
---@field name string Name of the menu item
---@field context any Context/self
---@field action function or nil (optional) Function to execute when selecting the menu item. Called with multiple params: context, player unit, actionParams
---@field actionParams any or nil (optional) Params to pass to the action handler
---@field condition function or nil (optional) Condition that should be evaluated before adding the menu. Called with multiple params: context, player unit, conditionParams
---@field conditionParams any or nil (optional) Params to pass to the condition handler
---@field children: Menu[] or nil (optional) Child menu items

do
    function MenuRegistry:new(logger)
        ---@type MenuRegistry
        local object = setmetatable({}, self)

        object.logger = logger

        object.menus = {}

        return object
    end

    --- Monitors player birth events and attaches menus to players.
    --- Alternatively, call :updateMenus() to manually attach menus.
    function MenuRegistry:autoAttachMenus()
        local _self = self
        local playerBirthEventHandler = {}

        ---@param event event
        function playerBirthEventHandler:onEvent(event)
            if (EventUtil.isPlayerBirthEvent(event)) then
                _self.logger:debug('menu registry event handler',
                    { eid = event.id, playerName = event.initiator:getPlayerName() })

                timer.scheduleFunction(function(initiator)
                    _self:updateMenus(initiator)
                end, event.initiator, timer.getTime() + 1)
            end
        end

        world.addEventHandler(playerBirthEventHandler)
    end

    -- TODO: support more than 9 items
    ---@param menu Menu
    function MenuRegistry:register(menu)
        local index = menu.index

        if (index == nil) then
            self.logger:error('Called MenuRegistry:register with invalid menu', { menu = menu })
            return
        end

        if (self.menus[index] ~= nil) then
            self.logger:warn('Index already in use', { index = index, menu = menu, existingMenu = self.menus[index] })
            index = index + 1
        end

        self.menus[index] = menu
    end

    --- Typically, MenuRegistry:updateMenus() should be called instead to properly remove existing menu items (e.g. on slot change)
    ---@param playerUnit Unit
    function MenuRegistry:attachMenus(playerUnit)
        self.logger:debug('Attach menus to player', playerUnit:getPlayerName(), self.menus)

        for _, menuItem in ipairs(self.menus) do
            self:_attachMenuItem(playerUnit, nil, menuItem)
        end
    end

    ---@param playerUnit Unit
    function MenuRegistry:detachMenus(playerUnit)
        missionCommands.removeItemForGroup(playerUnit:getGroup():getID())
    end

    function MenuRegistry:updateMenus(playerUnit)
        self:detachMenus(playerUnit)
        self:attachMenus(playerUnit)
    end

    ---@param playerUnit Unit
    ---@param parentMenu table
    ---@param menuItem Menu
    function MenuRegistry:_attachMenuItem(playerUnit, parentMenu, menuItem)
        local groupId = playerUnit:getGroup():getID()

        if (menuItem.condition ~= nil) then
            local status, result = pcall(menuItem.condition, menuItem.context, playerUnit, menuItem.conditionParams)

            if (status == false or result == false) then
                return
            end
        end

        if (self:_hasChildren(menuItem)) then
            local subMenu = missionCommands.addSubMenu(menuItem.name, parentMenu)

            for _, childMenuItem in ipairs(menuItem.children) do
                self:_attachMenuItem(playerUnit, subMenu, childMenuItem)
            end
        else
            missionCommands.addCommandForGroup(
                groupId,
                menuItem.name,
                parentMenu,
                menuItem.action,
                menuItem.context,
                playerUnit,
                menuItem.actionParams)
        end
    end

    ---@param menuItem Menu
    function MenuRegistry:_hasChildren(menuItem)
        return menuItem.children ~= nil and Util.length(menuItem.children) > 0
    end
end

local unitNames = {
    "P-51D-30-NA",
    "P-47D-40",
    "F4U-1D",
    "F4U-1D_CW",
    "Bf-109K-4",
    "FW-190A8",
    "FW-190D9",
    "MosquitoFBMkVI",
    "SpitfireLFMkIX",
    "SpitfireLFMkIXCW",
    "I-16",
    "La-7",
    "A-20G",
    "B-17G",
    "C-47",
    "Ju-88A4",
}

local unitData = {
    ["P-51D-30-NA"] = {
        isFighter = true,
        fuel = 300,
    },
    ["P-47D-40"] = {
        isFighter = true,
        fuel = 400,
        additionalProps = {
            WaterTankContents = 1,
        }
    },
    ["F4U-1D"] = {
        isFighter = true,
        fuel = 400,
    },
    ["F4U-1D_CW"] = {
        isFighter = true,
        fuel = 400,
    },
    ["Bf-109K-4"] = {
        isFighter = true,
        fuel = 280,
        additionalProps = {
            MW50TankContents = 1,
        }
    },
    ["FW-190A8"] = {
        isFighter = true,
        fuel = 350,
    },
    ["FW-190D9"] = {
        isFighter = true,
        fuel = 350,
    },
    ["MosquitoFBMkVI"] = {
        isFighter = true,
        fuel = 600,
    },
    ["SpitfireLFMkIX"] = {
        isFighter = true,
        fuel = 250,
    },
    ["SpitfireLFMkIXCW"] = {
        isFighter = true,
        fuel = 250,
    },
    ["I-16"] = {
        isFighter = true,
        fuel = 180,
    },
    ["La-7"] = {
        isFighter = true,
        fuel = 300,
    },
    ["A-20G"] = {
        isFighter = false,
        fuel = 1500,
    },
    ["B-17G"] = {
        isFighter = false,
        fuel = 7600,
    },
    ["C-47"] = {
        isFighter = false,
        fuel = 1400,
    },
    ["Ju-88A4"] = {
        isFighter = false,
        fuel = 1400,
    },
}


local groupId = 100
local unitId = 100

local spawnLocation = "random" -- or "in front", "behind"
local spawnDistance = 5 -- distance from player, selectable 5-10-15-20-25-50
local spawnAspect = "random" -- or "hot", "cold", "flank-left", "flank-right"
local spawnSkill = "random" -- or "Average", "Good", "High", "Excellent"
local spawnAmount = 1 -- 1 - 4
local spawnUseMW50 = false -- or true

local function spawn(_, _, selectedUnit)
    groupId = groupId + 1

    local unitName = selectedUnit
    if (selectedUnit == "random") then
        unitName = unitNames[math.random(1, #unitNames)]
    end

    local spawnPoint = {
        x = 0,
        y = 0,
        z = 0,
    }

    ---@type Unit
    local playerUnit = world.getPlayer()
    local playerPoint = playerUnit:getPoint()
    local playerHeading = Util.getHeading(playerUnit)

    local heading = playerHeading

    if (spawnLocation == "random") then
        heading = math.random(0, 359)
    elseif (spawnLocation == "front") then
        heading = heading
    elseif (spawnLocation == "behind") then
        heading = heading - 180

        if (heading < 0) then
            heading = heading + 360
        end
    end

    spawnPoint = Util.pointShiftByDegrees(playerPoint, heading, spawnDistance * 1000)
    local unitHeading = 0

    if (spawnAspect == "random") then
        unitHeading = math.random(0, 359)
    elseif (spawnAspect == "hot") then
        unitHeading = playerHeading - 180
    elseif (spawnAspect == "cold") then
        unitHeading = playerHeading
    elseif (spawnAspect == "flank-left") then
        unitHeading = playerHeading - 90
    elseif (spawnAspect == "flank-right") then
        unitHeading = playerHeading + 90
    end

    if (unitHeading > 360) then
        unitHeading = unitHeading - 360
    elseif (unitHeading < 0) then
        unitHeading = unitHeading + 360
    end

    local unitSkill = spawnSkill
    if (spawnSkill == "random") then
        local skills = { "Average", "Good", "High", "Excellent" }

        unitSkill = skills[math.random(1, #skills)]
    end

    local data = unitData[unitName]

    local wp1 = Util.pointShiftByDegrees(spawnPoint, unitHeading, 10000)

    local waypoint = {
        x = wp1.x,
        y = wp1.z,
        alt = playerPoint.y,
        type = "Turning Point",
        action = "Turning Point",
        alt_type = "BARO",
        speed = 100 * (1 + 0.06 * playerPoint.y / 1000),
        task = {
            id = "ComboTask",
            params = {
                {
                    id = "WrappedAction",
                    params = {
                        action = {
                            id = "Option",
                            params = {
                                name = AI.Option.Air.id.ALLOW_FORMATION_SIDE_SWAP,
                                value = true,
                            }
                        }
                    }
                },
                {
                    id = "WrappedAction",
                    params = {
                        action = {
                            id = "Option",
                            params = {
                                -- WW2 fighter vic close
                                name = AI.Option.Air.id.FORMATION,
                                value = 917505,
                                variantIndex = 1,
                                formationIndex = 14,
                            }
                        }
                    }
                },
                {
                    id = "WrappedAction",
                    params = {
                        action = {
                            id = "Option",
                            params = {
                                name = AI.Option.Air.id.FORCED_ATTACK,
                                value = true,
                            }
                        }
                    }
                },
                {
                    id = 'EngageUnit',
                    params = {
                        unitId = playerUnit:getID(),
                    }
                }
            },
        }
    }

    local waypoints = {
        waypoint
    }

    if (not data.isFighter) then
        for index = 1, 3 do
            local waypointDestination = Util.pointShiftByDegrees(spawnPoint, math.random(1, 359), 15000)

            local wp = {
                x = waypointDestination.x,
                y = waypointDestination.z,
                alt = playerPoint.y,
                type = "Turning Point",
                action = "Turning Point",
                alt_type = "BARO",
                speed = 100 * (1 + 0.06 * playerPoint.y / 1000),
                task = {},
            }

            if (index == 3) then
                wp.task = {
                    id = "ComboTask",
                    params = {
                        tasks = {
                            {
                                id = "WrappedAction",
                                params = {
                                    action = {
                                        id = 'SwitchWaypoint',
                                        params = {
                                            goToWaypointIndex = 1,
                                        }
                                    }
                                }
                            }
                        }
                    },
                }
            end

            table.insert(waypoints, wp)
        end
    end

    local groupData = {
        groupId = groupId,
        name = string.format("group-%d-%s", groupId, unitName),
        tasks = {},
        task = "CAP",
        uncontrolled = false,
        hidden = false,
        communication = false,
        route = {
            points = waypoints,
        },
        units = {},
    }

    local offset = 0

    for index = 1, spawnAmount do
        local unitSpawnPoint = spawnPoint

        if (index > 1) then
            local headingOffset = unitHeading + 135

            if (headingOffset > 360) then
                headingOffset = headingOffset - 360
            end

            unitSpawnPoint = Util.pointShiftByDegrees(spawnPoint, headingOffset, offset)
        end

        local unit = {
            unitId = unitId,
            name = string.format("unit-%d-%s", unitId, unitName),
            type = unitName,
            x = unitSpawnPoint.x,
            y = unitSpawnPoint.z,
            speed = 100 * (1 + 0.06 * playerPoint.y / 1000),
            heading = math.rad(unitHeading),
            alt = playerPoint.y,
            skill = unitSkill,
            payload = {
                gun = 100,
                fuel = data.fuel,
                ammo_type = 1,
                flare = 0,
                chaff = 0,
            },
            callsign = {
                [1] = groupId,
                [2] = 1,
                ["name"] = string.format("target-%d", unitId),
                [3] = index,
            },
        }

        if (spawnUseMW50 and data.additionalProps) then
            -- todo verify
            unit.AddPropAircraft = data.additionalProps
        end

        unitId = unitId + 1
        offset = offset + 5

        table.insert(groupData.units, unit)
    end

    coalition.addGroup(country.id.CJTF_RED, Group.Category.AIRPLANE, groupData)
end

local logger = Logger:new(true)
local menuRegistry = MenuRegistry:new(logger)

local function isMW50Enabled()
    return spawnUseMW50
end

local function isMW50Disabled()
    return not spawnUseMW50
end

local function outputConfig()
    trigger.action.outText(
        string.format(
            "Using options:\nLocation: %s\nDistance: %s\nAspect: %s\nSkill: %s\nAmount: %s\nMW50 enabled: %s",
            tostring(spawnLocation),
            tostring(spawnDistance),
            tostring(spawnAspect),
            tostring(spawnSkill),
            tostring(spawnAmount),
            tostring(spawnUseMW50)
        ), 10)
end

local function setSpawnLocation(_, _, location)
    spawnLocation = location
    outputConfig()
end

local function setSpawnDistance(_, _, range)
    spawnDistance = range
    outputConfig()
end

local function setSpawnAspect(_, _, aspect)
    spawnAspect = aspect
    outputConfig()
end

local function setSpawnSkill(_, _, skill)
    spawnSkill = skill
    outputConfig()
end

local function setSpawnAmount(_, _, amount)
    spawnAmount = amount
    outputConfig()
end

local function setMW50Enabled(_, _, enabled)
    spawnUseMW50 = enabled
    outputConfig()
    menuRegistry:updateMenus(world.getPlayer())
end

local function despawn()
    local groups = coalition.getGroups(coalition.side.RED, Group.Category.AIRPLANE)

    for _, group in ipairs(groups) do
        group:destroy()
    end
end

local function nudgeAI()
    local groups = coalition.getGroups(coalition.side.RED, Group.Category.AIRPLANE)

    for _, group in ipairs(groups) do
        local controller = group:getController()

        ---@type Unit
        local playerUnit = world.getPlayer()

        controller:knowTarget(playerUnit, true, true)
        controller:pushTask(
            {
                id = 'EngageUnit',
                params = {
                    unitId = playerUnit:getID(),
                }
            }
        )
    end
end

local function getDistanceConfigMenuItems()
    local menuItems = {}
    local distances = { 5, 10, 15, 20, 25, 50 }

    local index = 1
    for _, distance in ipairs(distances) do
        local menuItem = {
            index = index,
            name = string.format("%s km", distance),
            context = nil,
            action = setSpawnDistance,
            actionParams = distance
        }

        table.insert(menuItems, menuItem)
        index = index + 1
    end

    return menuItems
end

local function getSpawnUnitMenuItems(units)
    local menuItems = {}

    local index = 1
    for _, unitName in ipairs(units) do
        local menuItem = {
            index = index,
            name = unitName,
            context = nil,
            action = spawn,
            actionParams = unitName
        }

        table.insert(menuItems, menuItem)
        index = index + 1
    end

    return menuItems
end

local spawnMenu = {
    index = 1,
    name = "Spawn unit(s)",
    children = {
        {
            index = 1,
            name = "Random unit(s)",
            context = nil,
            action = spawn,
            actionParams = "random",
        },
        {
            index = 2,
            name = "Select US fighter(s)",
            children = getSpawnUnitMenuItems({ "P-51D-30-NA", "P-47D-40", "F4U-1D", "F4U-1D_CW", }),
        },
        {
            index = 3,
            name = "Select British fighter(s)",
            children = getSpawnUnitMenuItems({ "MosquitoFBMkVI", "SpitfireLFMkIX", "SpitfireLFMkIXCW", }),
        },
        {
            index = 4,
            name = "Select German fighter(s)",
            children = getSpawnUnitMenuItems({ "Bf-109K-4", "FW-190A8", "FW-190D9", }),
        },
        {
            index = 5,
            name = "Select Soviet fighter(s)",
            children = getSpawnUnitMenuItems({ "I-16", "La-7", }),
        },
        {
            index = 6,
            name = "Select bomber(s)/transport",
            children = getSpawnUnitMenuItems({ "A-20G", "B-17G", "C-47", "Ju-88A4", }),
        }
    }
}

local configMenu = {
    index = 2,
    name = "Spawn options",
    children = {
        {
            index = 1,
            name = "Select spawn location",
            children = {
                {
                    index = 1,
                    name = "Random",
                    context = nil,
                    action = setSpawnLocation,
                    actionParams = "random"
                },
                {
                    index = 2,
                    name = "In front of player",
                    context = nil,
                    action = setSpawnLocation,
                    actionParams = "front"
                },
                {
                    index = 3,
                    name = "Behind player",
                    context = nil,
                    action = setSpawnLocation,
                    actionParams = "behind"
                },
            },
        },
        {
            index = 2,
            name = "Select spawn distance",
            children = getDistanceConfigMenuItems(),
        },
        {
            index = 3,
            name = "Select enemy aspect",
            children = {
                {
                    index = 1,
                    name = "Random",
                    context = nil,
                    action = setSpawnAspect,
                    actionParams = "random",
                },
                {
                    index = 2,
                    name = "Hot",
                    context = nil,
                    action = setSpawnAspect,
                    actionParams = "hot",
                },
                {
                    index = 3,
                    name = "Cold",
                    context = nil,
                    action = setSpawnAspect,
                    actionParams = "cold",
                },
                {
                    index = 4,
                    name = "Flank left",
                    context = nil,
                    action = setSpawnAspect,
                    actionParams = "flank-left",
                },
                {
                    index = 5,
                    name = "Flank right",
                    context = nil,
                    action = setSpawnAspect,
                    actionParams = "flank-right",
                },
            },
        },
        {
            index = 4,
            name = "Select spawn skill",
            children = {
                {
                    index = 1,
                    name = "Random",
                    context = nil,
                    action = setSpawnSkill,
                    actionParams = "random",
                },
                {
                    index = 2,
                    name = "Average",
                    context = nil,
                    action = setSpawnSkill,
                    actionParams = "Average",
                },
                {
                    index = 3,
                    name = "Good",
                    context = nil,
                    action = setSpawnSkill,
                    actionParams = "Good",
                },
                {
                    index = 4,
                    name = "High",
                    context = nil,
                    action = setSpawnSkill,
                    actionParams = "High",
                },
                {
                    index = 5,
                    name = "Excellent",
                    context = nil,
                    action = setSpawnSkill,
                    actionParams = "Excellent",
                },
            },
        },
        {
            index = 5,
            name = "Select amount",
            children = {
                {
                    index = 1,
                    name = "1",
                    context = nil,
                    action = setSpawnAmount,
                    actionParams = 1,
                },
                {
                    index = 2,
                    name = "2",
                    context = nil,
                    action = setSpawnAmount,
                    actionParams = 2,
                },
                {
                    index = 3,
                    name = "3",
                    context = nil,
                    action = setSpawnAmount,
                    actionParams = 3,
                },
                {
                    index = 4,
                    name = "4",
                    context = nil,
                    action = setSpawnAmount,
                    actionParams = 4,
                },
            },
        },
        {
            index = 6,
            name = "Disable MW50 (in supported units)",
            condition = isMW50Enabled,
            action = setMW50Enabled,
            actionParams = false,
        },
        {
            index = 7,
            name = "Enable MW50 (in supported units)",
            condition = isMW50Disabled,
            action = setMW50Enabled,
            actionParams = true,
        },
        {
            index = 8,
            name = "Delete enemies",
            action = despawn,
        },
        {
            index = 9,
            name = "Nudge AI",
            action = nudgeAI,
        },
    }
}

menuRegistry:register(spawnMenu)
menuRegistry:register(configMenu)

menuRegistry:autoAttachMenus()
