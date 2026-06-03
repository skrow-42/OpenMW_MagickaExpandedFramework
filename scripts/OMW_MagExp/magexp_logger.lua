local storage = require('openmw.storage')
local async   = require('openmw.async')

local debugMode = false

local general = storage.globalSection('SettingsMagExp_General')
local function updateConfig()
    debugMode = general:get('DebugMode')
end

updateConfig()
general:subscribe(async:callback(updateConfig))


return {
    new = function(name)
        return function(...)
            if debugMode ~= true then return end
            print(name, ...)
        end
    end
}