local core = require('openmw.core')
local util = require('openmw.util')

local Helpers = {}

Helpers.getBaseSpellCost = function(spellId, isEnchant)
    local cost = 0

    local spellRecord
    if isEnchant then
        spellRecord = core.magic.enchantments.records[spellId]
    else
        spellRecord = core.magic.spells.records[spellId]
    end
    if not spellRecord then return cost end

    if not spellRecord.autocalcFlag then
        return spellRecord.cost
    end

    for _, effect in ipairs(spellRecord.effects) do
        local minMagnitude, maxMagnitude = 1, 1
        local baseEffect = effect.effect

        if baseEffect.hasMagnitude then
            minMagnitude = effect.magnitudeMin
            maxMagnitude = effect.magnitudeMax
        end
        if not isEnchant then
            minMagnitude = math.max(1, minMagnitude)
            maxMagnitude = math.max(1, maxMagnitude)
        end

        local x = baseEffect.hasDuration and effect.duration or 1
        if not baseEffect.isAppliedOnce then
            x = math.max(x, 1)
        end
        x = x * 0.1 * baseEffect.baseCost
        x = x * 0.5 * (effect.magnitudeMin + effect.magnitudeMax)
        x = x + 0.05 * baseEffect.baseCost * effect.area
        if effect.range == core.magic.RANGE.Target then
            x = x * 1.5
        end
        x = x * core.getGMST('fEffectCostMult')
        x = math.max(0, x)

        cost = cost + x
    end

    return cost
end

Helpers.getModifiedSpellCost = function(actor, spellId, isEnchant)
    local baseCost = Helpers.getBaseSpellCost(spellId, isEnchant)

    local cost = baseCost

    if isEnchant then
        local x = 0.01 * (110 - actor.type.stats.skills.enchant(actor).modified)
        cost = math.floor(x * cost)
        cost = math.max(cost, 1)
    end

    return cost
end

--- 
---@param spellId string
---@param actor table
---@param opts? {isGodMode?: boolean, cost?: number, ignoreFatigue? : boolean} 
Helpers.getSpellCastChance = function(spellId, actor, opts)
    local isGodMode = opts and opts.isGodMode
    local spellRecord = core.magic.spells.records[spellId]
    if not spellRecord then return 0 end
    
    local activeEffects = actor.type.activeEffects(actor)
    local isSilenced = activeEffects:getEffect(core.magic.EFFECT_TYPE.Silence).magnitude > 0

    if not (spellRecord.type == core.magic.SPELL_TYPE.Spell or spellRecord.type == core.magic.SPELL_TYPE.Power) then
        return (isSilenced and not isGodMode) and 0 or 100
    end

    if spellRecord.type == core.magic.SPELL_TYPE.Power then
        return (isSilenced and not isGodMode or not actor.type.spells(actor):canUsePower(spellId)) and 0 or 100 -- Powers can always be used if not on cooldown
    end

    if spellRecord.type == core.magic.SPELL_TYPE.Spell then
        local cost = 0

        local y = math.huge
        local lowestSkill = 0
        local effectiveSchool
        for _, effect in ipairs(spellRecord.effects) do
            local baseEffect = effect.effect
            local x = baseEffect.hasDuration and effect.duration or 1
            if not baseEffect.isAppliedOnce then
                x = math.max(x, 1)
            end
            x = x * 0.1 * baseEffect.baseCost
            x = x * 0.5 * (effect.magnitudeMin + effect.magnitudeMax)
            x = x + 0.05 * baseEffect.baseCost * effect.area
            if effect.range == core.magic.RANGE.Target then
                x = x * 1.5
            end
            x = x * core.getGMST('fEffectCostMult')

            cost = cost + x

            local s = 2 * actor.type.stats.skills[baseEffect.school](actor).modified
            if (s - x) < y then
                y = s - x
                effectiveSchool = baseEffect.school
                lowestSkill = s
            end
        end

        if not spellRecord.autocalcFlag then
            cost = spellRecord.cost
        end

        if isGodMode then
            return 100, effectiveSchool
        end

        if isSilenced then
            return 0, effectiveSchool
        end

        if spellRecord.alwaysSucceedFlag then
            return 100, effectiveSchool
        end

        --try get overridden cost from opts
        cost = opts and opts.cost or cost
        
        local magicka = actor.type.stats.dynamic.magicka(actor)
        local willpower = actor.type.stats.attributes.willpower(actor)
        local luck = actor.type.stats.attributes.luck(actor)

        if magicka.current < cost then
            return 0, effectiveSchool
        end

        local castBonus = -activeEffects:getEffect(core.magic.EFFECT_TYPE.Sound).magnitude
        local fatigueTerm = opts and opts.ignoreFatigue and 1 or Helpers.getFatigueTerm(actor)
        local castChance = (lowestSkill - util.round(cost) + castBonus + 0.2 * willpower.modified + 0.1 * luck.modified) * fatigueTerm

        return math.floor(util.clamp(castChance, 0.0, 100.0)), effectiveSchool
    end
end

local FATIGUE_BASE = core.getGMST('fFatigueBase')
local FATIGUE_MULT = core.getGMST('fFatigueMult')

---@param actor table
Helpers.getFatigueTerm = function(actor)
    local fatigue = actor.type.stats.dynamic.fatigue(actor)
    local normalizedFatigue
    if fatigue.base == 0 then
        normalizedFatigue = 1
    else
        normalizedFatigue = math.max(0, fatigue.current / fatigue.base)
    end

    return FATIGUE_BASE - FATIGUE_MULT * (1 - normalizedFatigue)
end

return Helpers