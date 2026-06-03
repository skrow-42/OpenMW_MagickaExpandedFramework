-- ============================================================
-- Spell Framework Plus for OpenMW
-- magexp_player.lua (PLAYER script)
-- ============================================================

local self    = require('openmw.self')
local core    = require('openmw.core')
local types   = require('openmw.types')
local anim    = require('openmw.animation')
local storage = require('openmw.storage')
local ui      = require('openmw.ui')
local camera  = require('openmw.camera')
local util    = require('openmw.util')
local debug   = require('openmw.debug')
local I       = require('openmw.interfaces')
local async   = require('openmw.async')
local nearby  = require('openmw.nearby')

local C = require('scripts/OMW_MagExp/magexp_constants')
local Helpers = require('scripts/OMW_MagExp/magexp_helpers')
local debugLog = require('scripts/OMW_MagExp/magexp_logger').new('[MagExp-Player]')


-- ---- State Management ----
local busyUntil        = 0
local hasQueuedLaunch  = false
local pendingLaunches  = {}

-- ---- [FEATURE 5] Charged Spell State ----
local currentChargeData = nil

-- ---- [CHARGE-AS-CAST] ----
local pendingChargeKey = nil

-- ============================================================
-- [OSSC DETECTION] Optional OSSC integration
-- ============================================================
local IS_OSSC_DEBUG = false
pcall(function()
    local s = storage.playerSection('SettingsOSSC_General')
    IS_OSSC_DEBUG = (s ~= nil and s:get('DebugMode') == true)
end)

-- ============================================================
-- [CAST START GROUP WHITELIST]
-- Only these groups trigger casting VFX on their 'start' key.
-- We deliberately exclude "spellcast" and release-phase groups.
-- ============================================================
local VFX_CAST_GROUPS = {
    quickcast = true,
    quickbuff = true,
    qcconj    = true,
    qctouch   = true,
    qcalt     = true,
    qcalts    = true,
    qcill     = true,
    qcsnap    = true,
    qcdrain   = true,
    qcskrow   = true,
}

local castStartLatched = {}
local vfxTriggeredThisCast = false
local lastCastStartSentTime = -999
local lastCastStartSpellId  = nil

local function shouldTriggerVfxOnStart(groupname)
    local g = tostring(groupname or ""):lower()
    return VFX_CAST_GROUPS[g] == true
end

local function isWhitelistedCastGroup(groupname)
    local g = tostring(groupname or ""):lower()
    return VFX_CAST_GROUPS[g] == true
end

local function sendCastStartNow(reason, groupname)
    if IS_OSSC_DEBUG then --TODO: is this needed?
        debugLog("OSSC active - sending CastStart from MagExp for group: " .. tostring(groupname))
    end

    local t = core.getSimulationTime()
    local spell = nil
    pcall(function() spell = types.Actor.getSelectedSpell(self) end)
    local spellId = spell and spell.id
    if not spellId then return end

    if lastCastStartSpellId == spellId and (t - lastCastStartSentTime) < 0.25 then
        return
    end

    lastCastStartSentTime = t
    lastCastStartSpellId  = spellId

    debugLog(string.format("CastStart (%s): group=%s spellId=%s", tostring(reason), tostring(groupname), tostring(spellId)))

    core.sendGlobalEvent('MagExp_CastStart', {
        attacker = self,
        spellId  = spellId,
    })
end

-- ============================================================
-- [HELPERS] Launch Parameter Calculation
-- ============================================================

local function calculateLaunchPayload(spell, item)
    local cameraMode = camera.getMode()
    local startPos, direction

    if cameraMode == camera.MODE.FirstPerson then
        startPos  = camera.getPosition()
        direction = camera.getViewDirection()
        startPos  = startPos + camera.getUp() * -10 + camera.getLeft() * 15
    else
        startPos  = self.position + util.vector3(0, 0, 120)
        direction = camera.getViewDirection()
        startPos  = startPos + camera.getLeft() * 25
    end

    debugLog("Starting raycast from:", startPos)
    debugLog("Direction:", direction)

    local hitObject = nil
    local hitPos    = nil

    local rayOk, rayErr = pcall(function()
        local endPos = startPos + direction * 300
         debugLog("Ray end position:", endPos)

        local rayResult = nearby.castRay(startPos, endPos, { ignore = self })
         debugLog("Raycast result:", rayResult)

        if rayResult then
             debugLog("Ray hit something!")
             debugLog("hitObject:", rayResult.hitObject)
             debugLog("hitPos:", rayResult.hitPos)
            if rayResult.hitObject then
                hitObject = rayResult.hitObject
                hitPos    = rayResult.hitPos
                 debugLog("Hit object type:", hitObject.type)
                 debugLog("Hit object recordId:", hitObject.recordId)
            end
        else
             debugLog("Raycast returned nil")
        end
    end)

    if not rayOk then
         debugLog("Raycast ERROR:", rayErr)
    end

     debugLog("Final hitObject for payload:", hitObject)

    return {
        attacker   = self,
        spellId    = spell.id,
        itemObject = item,
        startPos   = startPos,
        direction  = direction,
        isGodMode  = debug.isGodMode(),
        hitObject  = hitObject,
        hitPos     = hitPos,
    }
end

-- ============================================================
-- [INTERNAL] Charge key held check helper.
-- ============================================================
local function isChargeKeyCurrentlyHeld(keyId)
    if not keyId then return false end
    local result = false
    pcall(function()
        local fn = I.MagExp
                   and I.MagExp._chargeKeyRegistry
                   and I.MagExp._chargeKeyRegistry[keyId]
        if fn then result = fn() end
    end)
    return result
end

-- ============================================================
-- [CORE] Animation Sync & Lifecycle
-- ============================================================
-- ============================================================
-- CORE TEXT KEY HANDLER
-- ============================================================
local function onTextKey(groupname, key)
    local g = tostring(groupname or ""):lower()
    local k = tostring(key):lower()

    -- VFX ONLY on the initial cast group's 'start' key
    if k == "start" then
        if shouldTriggerVfxOnStart(g) and not vfxTriggeredThisCast then
            vfxTriggeredThisCast = true
            castStartLatched[g] = true
            sendCastStartNow("textKey:start", g)
        end
    end

    -- Reset on stop
    if k == "stop" then
        if isWhitelistedCastGroup(g) or g == "spellcast" then
            castStartLatched[g] = true
            vfxTriggeredThisCast = false
        end
    end

    -- Only MagExp's own queued casts
    if not hasQueuedLaunch then return end

    -- if k == "start" then
    --     if pendingChargeKey and isChargeKeyCurrentlyHeld(pendingChargeKey) then
    --         debugLog("Charge key held at 'start' — entering charge loop")
    --         currentChargeData = {
    --             animGroup  = "spellcast",
    --             chargeKey  = pendingChargeKey,
    --             priority   = 1,
    --             blendMask  = 15,
    --             isCharging = true,
    --         }
    --         pcall(function() anim.play(self, "spellcast", 1, 15, true, 1.0) end)
    --     end
    --     return
    -- end

    -- if k == "release" then
    --     debugLog("MagExp Release Key Triggered - launching spell")
    --     for spellId, item in pairs(pendingLaunches) do
    --         local spell = core.magic.spells.records[spellId] or core.magic.enchantments.records[spellId]
    --         if spell then
    --             local payload = calculateLaunchPayload(spell, item)
    --             core.sendGlobalEvent('MagExp_CastRequest', payload)
    --         end
    --     end
    --     pendingLaunches  = {}
    --     hasQueuedLaunch  = false
    --     if currentChargeData then currentChargeData.isCharging = false end
    --     return
    -- end

    if k == "stop" then
        hasQueuedLaunch   = false
        pendingLaunches   = {}
        currentChargeData = nil
        pendingChargeKey  = nil
        vfxTriggeredThisCast = false
        return
    end
end
-- ============================================================
-- [UPDATE] Charge Key Polling + Cast latch safety cleanup
-- ============================================================
local function onUpdate(dt)
    -- Charge loop polling
    if currentChargeData and currentChargeData.isCharging then
        local chargeKey = currentChargeData.chargeKey
        local isHeld    = isChargeKeyCurrentlyHeld(chargeKey)

        if not isHeld then
            debugLog("Charge key released — proceeding to release key")
            currentChargeData.isCharging = false
            pendingChargeKey = nil
            pcall(function()
                anim.play(self, currentChargeData.animGroup,
                    currentChargeData.priority or 7,
                    currentChargeData.blendMask or 15,
                    false, 1.0)
            end)
        end
    end

    -- Safety: clear stale latches
    for g, _ in pairs(VFX_CAST_GROUPS) do
        local playing = false
        pcall(function() playing = anim.isPlaying(self, g) end)
        if not playing then
            castStartLatched[g] = nil
        end
    end
end

-- ============================================================
-- [EVENT] MagExp_StartQuickCast
-- ============================================================
local function startQuickCast(data)
    local spellId = data.spellId
    local spell   = core.magic.spells.records[spellId] or core.magic.enchantments.records[spellId]
    if not spell then return end

    debugLog("Initiating Quick Cast sequence for: " .. spellId)

    pendingChargeKey = data.chargeKey or nil

    -- Cast VFX is handled by the animation hooks (addPlayBlendedAnimationHandler / textKey:start).
    -- Do NOT send MagExp_CastStart here — it will be sent when the anim starts.
    core.sendGlobalEvent('MagExp_ProcessCast', {
        actor     = self,
        spellId   = spellId,
        item      = data.item,
        isFree    = data.isFree,
        isGodMode = debug.isGodMode()
    })
end

-- ============================================================
-- [EVENT] MagExp_CastResult
-- ============================================================
local function handleCastResult(data)
    if data.success then
        debugLog("Cast Authorization: SUCCESS")

        hasQueuedLaunch = true
        pendingLaunches[data.spellId] = data.item

        anim.playBlended(self, "spellcast", { priority = 1, blend = 0.2 })
    else
        debugLog("Cast Authorization: FAILED (Roll/Magicka)")
        ui.showMessage(C.MSG.SPELL_FAILED)
        pendingChargeKey = nil
    end
end

-- ============================================================
-- ANIMATION HOOKS
-- ============================================================
if I.AnimationController then
    I.AnimationController.addTextKeyHandler('', onTextKey)

    if I.AnimationController.addPlayBlendedAnimationHandler then
        I.AnimationController.addPlayBlendedAnimationHandler(function(groupname, options)
            local g = tostring(groupname or ""):lower()
            if isWhitelistedCastGroup(g) then
                castStartLatched[g] = false   -- reset latch so 'start' key can fire VFX
            end
        end)
    end
end

-- ============================================================
-- EVENT + ENGINE HANDLER TABLE
-- ============================================================
local handlers = {
    engineHandlers = {
        onUpdate = onUpdate,
    },
    eventHandlers = {
        MagExp_StartQuickCast = startQuickCast,
        MagExp_CastResult     = handleCastResult,

        -- [SKILL] Progression from global script
        MagExp_AwardSkillProgress = function(data)
            if not data or not data.school or not data.progress then return end

            local skillMap = {
                alteration  = "alteration",
                conjuration = "conjuration",
                destruction = "destruction",
                illusion    = "illusion",
                mysticism   = "mysticism",
                restoration = "restoration",
            }

            local skillId = skillMap[data.school:lower()]
            if not skillId then
                debugLog("Unknown school for skill progression:", tostring(data.school))
                return
            end

            local skillStat = types.Player.stats.skills[skillId]
            if not skillStat then
                debugLog("Skill stat not found for:", skillId)
                return
            end

            local stat = skillStat(self)
            if stat and stat.progress ~= nil then
                stat.progress = stat.progress + data.progress
                debugLog(string.format("Awarded %.2f progress to %s", data.progress, skillId))
            end
        end,

        -- [FEATURE 5] Custom animation override from launchSpellAnim()
        MagExp_PlaySpellAnim = function(data)
            if not data or not data.animGroup then return end
            local group    = data.animGroup
            local mask     = data.blendMask or 15
            local priority = data.priority  or 7

            debugLog("PlaySpellAnim: " .. group .. " (priority=" .. priority .. " mask=" .. mask .. ")")
            anim.play(self, group, priority, mask, false, 1.0)

            if data.isCharged then
                currentChargeData = {
                    animGroup  = group,
                    chargeKey  = data.chargeKey,
                    priority   = priority,
                    blendMask  = mask,
                    isCharging = true,
                }
                debugLog("Charged spell started:", group, "key=", tostring(data.chargeKey))
            end
        end,

        -- [FEATURE 5] Graceful release of charged spell animation
        MagExp_ReleaseSpellAnim = function(data)
            if not data or not data.animGroup then return end
            debugLog("MagExp_ReleaseSpellAnim: " .. data.animGroup)
            pcall(function()
                anim.play(self, data.animGroup,
                    currentChargeData and currentChargeData.priority or 7,
                    currentChargeData and currentChargeData.blendMask or 15,
                    false, 1.0)
            end)
            if currentChargeData then
                currentChargeData.isCharging = false
            end
        end,

        -- VFX Utilities
        AddVfx = function(data)
            if not data or not data.model then return end
            debugLog(string.format("AddVfx model=%s vfxId=%s bone=%s",
                tostring(data.model),
                tostring(data.options and data.options.vfxId),
                tostring(data.options and data.options.boneName)
            ))
            anim.addVfx(self, data.model, data.options)
        end,

        RemoveVfx = function(vfxId)
            anim.removeVfx(self, vfxId)
        end,

        RemoveVfxDirect = function(vfxId)
            anim.removeVfx(self, vfxId)
        end,

        -- UI Utilities
        Ui_ShowMessage = function(msg)
            if type(msg) == "string" then ui.showMessage(msg) end
        end,

        -- Resource consumption
        MagExp_ConsumeResource = function(data)
            pcall(function()
                if data.magickaCost then
                    local magicka = types.Actor.stats.dynamic.magicka(self)
                    magicka.current = math.max(0, magicka.current - data.magickaCost)
                end
                if (data.itemCountCost and data.itemRecordId) or (data.itemChargeCost and data.itemRecordId) then
                    core.sendGlobalEvent('MagExp_ApplyInventoryConsume', {
                        attacker       = self,
                        item           = data.item,
                        itemCountCost  = data.itemCountCost,
                        itemRecordId   = data.itemRecordId,
                        itemChargeCost = data.itemChargeCost,
                    })
                end
            end)
        end,
    }
}

-- ============================================================
-- [PUBLIC LOCAL API] For other player scripts
-- ============================================================
local MagExp_PlayerInterface = {
    Helpers = Helpers,
    consumeSpellCost = function(spellId, itemObject)
        if debug.isGodMode() then return true end
        local spell = core.magic.spells.records[spellId]
        local isEnchantment = false
        if not spell then
            spell = core.magic.enchantments.records[spellId]
            isEnchantment = spell ~= nil
        end
        if not spell then return true end
        local cost = spell.cost or 0
        if cost <= 0 then return true end

        if isEnchantment and itemObject and type(itemObject) ~= "string" and itemObject:isValid() then
            if spell.type == core.magic.ENCHANTMENT_TYPE.CastOnce then
                if itemObject.count > 0 then
                    core.sendGlobalEvent('MagExp_ApplyInventoryConsume', {
                        attacker = self,
                        item = itemObject,
                        itemCountCost = 1,
                        itemRecordId = itemObject.recordId,
                    })
                    return true
                else
                    ui.showMessage(C.MSG.INSUFFICIENT_ITEMS)
                    return false
                end
            else
                local skill = 0
                pcall(function() skill = types.Player.stats.skills.enchant(self).modified end)
                cost = math.max(1, math.floor(0.01 * (110 - skill) * cost))
                local currentCharge, haveCharge = 0, false
                pcall(function()
                    local itemData = types.Item.itemData(itemObject)
                    if itemData and itemData.enchantmentCharge ~= nil then
                        currentCharge = itemData.enchantmentCharge
                        haveCharge = true
                    end
                end)
                if not haveCharge then
                    currentCharge = spell.charge or 0
                end
                if currentCharge >= cost then
                    core.sendGlobalEvent('MagExp_ApplyInventoryConsume', {
                        attacker = self,
                        item = itemObject,
                        itemChargeCost = cost,
                        itemRecordId = itemObject.recordId,
                    })
                    return true
                else
                    ui.showMessage(C.MSG.INSUFFICIENT_CHARGE)
                    return false
                end
            end
        else
            local magicka = types.Actor.stats.dynamic.magicka(self)
            if magicka.current >= cost then
                magicka.current = magicka.current - cost
                return true
            else
                ui.showMessage(C.MSG.INSUFFICIENT_MAGICKA)
                return false
            end
        end
    end
}

return {
    interfaceName  = "MagExp_Player",
    interface      = MagExp_PlayerInterface,
    engineHandlers = handlers.engineHandlers,
    eventHandlers  = handlers.eventHandlers,
}