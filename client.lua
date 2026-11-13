local currentShard
local currentKey
local pendingKey
local pendingSince = 0
local lastShownAt = 0
local bannerUntil = 0
local zoneTypeTown = 1
local zoneTypeDistrict = 10
local messageStateNone = 6
local districts = config.districts
local towns = config.towns
local natives = { -- because i cba to check which ones work anymore because rdr3natives.com is bullshit half the time.
    varString = 0xFA925AC00EB830B9,
    postLocationShard = 0xD05590C1AB38F068,
    clearFeedMessage = 0x2F901291EF177B02,
    getFeedMessageState = 0x59FA676177DBE4C9,
    getMapZoneAtCoords = 0x43AD8FC02B429D33,
    getTemperatureAtCoords = 0xB98B78C3768AF6E0,
    shouldUse24HourClock = 0x0177CF20345F44DD,
    shouldUseMetricTemperature = 0xFF4AAF3275BAAB4F,
    isScreenFadedOut = 0xF5472C80DF2FF847,
    isPauseMenuActive = 0x535384D6067BA42E,
}

local function literalString(text)
    return Citizen.InvokeNative(natives.varString, 10, 'LITERAL_STRING', text, Citizen.ResultAsLong())
end

local function invokeBool(hash)
    return Citizen.InvokeNative(hash, Citizen.ResultAsInteger()) == 1
end

local function getZoneHash(coords, zoneType)
    return Citizen.InvokeNative(natives.getMapZoneAtCoords, coords.x, coords.y, coords.z, zoneType, Citizen.ResultAsInteger())
end

local function getShardState(shard)
    return Citizen.InvokeNative(natives.getFeedMessageState, shard, Citizen.ResultAsInteger())
end

local function getTemperatureCelsius()
    if GetResourceState('randol_warmth') == 'started' then
        return exports.randol_warmth:GetTemperature() -- i have my own system that has the native temp + increase/decrease values.
    end

    local coords = GetEntityCoords(PlayerPedId())
    return Citizen.InvokeNative(natives.getTemperatureAtCoords, coords.x, coords.y, coords.z, Citizen.ResultAsFloat()) or 20.0
end

local function getTimeAndTemperature()
    local hour, minute = GetClockHours(), GetClockMinutes()
    local temperature = getTemperatureCelsius()
    local useMetric = invokeBool(natives.shouldUseMetricTemperature)

    if not useMetric then
        temperature = temperature * 1.8 + 32.0
    end

    local temperatureText = ('%.1f°%s'):format(temperature, useMetric and 'C' or 'F')

    if invokeBool(natives.shouldUse24HourClock) then
        return ('%s | %02d:%02d'):format(temperatureText, hour, minute)
    end

    local period = hour >= 12 and 'PM' or 'AM'
    hour = hour % 12
    if hour == 0 then hour = 12 end

    return ('%s | %d:%02d %s'):format(temperatureText, hour, minute, period)
end

local function isShardActive()
    if not currentShard or GetGameTimer() - lastShownAt > config.duration then return false end
    return getShardState(currentShard) ~= messageStateNone
end

local function clearShard()
    if currentShard then
        Citizen.InvokeNative(natives.clearFeedMessage, currentShard)
        currentShard = nil
    end
    bannerUntil = 0
end

local function postShard(titleKey)
    local ms = config.duration
    local titlePointer = literalString(titleKey)
    local subtitlePointer = literalString(getTimeAndTemperature())

    if currentShard and getShardState(currentShard) ~= messageStateNone then
        clearShard()
        Wait(150)
    end

    local options = string.pack('<i4', ms) .. string.rep('\0', 52)
    local data = string.pack('<i8i8i8i8i8', 0, titlePointer, subtitlePointer, 0, 0)

    bannerUntil = GetGameTimer() + ms + 500
    currentShard = Citizen.InvokeNative(natives.postLocationShard, options, data, 0, 1, Citizen.ResultAsInteger())
    lastShownAt = GetGameTimer()

    Wait(100)

    local state = currentShard and getShardState(currentShard)
    local ok = state and state ~= messageStateNone

    if not ok then
        bannerUntil = 0
    end

    return ok
end

local function resolveZone(coords)
    local townLabel = config.showTowns and towns[getZoneHash(coords, zoneTypeTown)]
    if townLabel then return townLabel end

    return districts[getZoneHash(coords, zoneTypeDistrict)]
end

local function canShow()
    return not invokeBool(natives.isScreenFadedOut) and not invokeBool(natives.isPauseMenuActive)
end

local function isTownKey(key)
    return type(key) == 'string' and (key:sub(1, 5) == 'TOWN_' or key:sub(1, 11) == 'SETTLEMENT_')
end

local function isDistrictKey(key)
    return type(key) == 'string' and key:sub(1, 9) == 'DISTRICT_'
end

CreateThread(function()
    while not NetworkIsSessionStarted() do Wait(500) end

    local lastCoords = GetEntityCoords(PlayerPedId())
    while true do
        Wait(config.checkInterval)
        local coords = GetEntityCoords(PlayerPedId())

        if #(coords - lastCoords) > 80.0 then
            currentKey = nil
            pendingKey = nil
            pendingSince = 0
        end
        
        lastCoords = coords

        local key = resolveZone(coords)
        local now = GetGameTimer()

        if key ~= pendingKey then
            pendingKey = key
            pendingSince = now
        end

        if not key then
            if currentKey and now - pendingSince >= config.stableTime then
                currentKey = nil
            end
            goto continue
        end

        if key == currentKey or now - pendingSince < config.stableTime then
            goto continue
        end

        local upgradingToTown = isTownKey(key) and isDistrictKey(currentKey)

        local blocked = now - lastShownAt < config.cooldown or (not upgradingToTown and isShardActive()) or not canShow()

        if not blocked and postShard(key) then
            currentKey = key
        end

        ::continue::
    end
end)

exports('isBannerActive', function() return GetGameTimer() < bannerUntil end)

-- The above export is used to check for the UiFeedClearAllChannels()/Citizen.InvokeNative(0x6035E8FBCA32AC5E) that clears those shitty toast notifications.
-- Example of how I use it below in my own event management because it fucks with the zone displays for some reason

-- [[
--     local ignoredEvents = {
--         [`EVENT_CHALLENGE_GOAL_COMPLETE`] = true,
--         [`EVENT_CHALLENGE_REWARD`] = true,
--         [`EVENT_CHALLENGE_GOAL_UPDATE`] = true,
--         [`EVENT_DAILY_CHALLENGE_STREAK_COMPLETED`] = true,
--     }

--     CreateThread(function()
--         while true do
--             Wait(0)

--             for _, group in ipairs(GROUPS) do
--                 local count = GetNumberOfEvents(group)
--                 if count > 0 then
--                     for i = 0, count - 1 do
--                         local eventHash = GetEventAtIndex(group, i)
--                         if ignoredEvents[eventHash] then
--                             local bannerActive = exports.randol_zones:isBannerActive()
--                             if not bannerActive then
--                                 Citizen.InvokeNative(0x6035E8FBCA32AC5E)
--                             end
--                         end

--                         local def = HashToEvent[eventHash] or HashToEvent[u32(eventHash)]
--                         if def then
--                             local data = readEventData(group, i, def)
--                             if data then
--                                 TriggerEvent(prefix:format(def.name), data)
--                             end
--                         end
--                     end
--                 end
--             end
--         end
--     end)
-- ]]