local core = require('openmw.core')

local l10n = core.l10n('OMW_MagExp')

local Constants = {}

-- ---- Message Constants ----
Constants.MSG = {
    SPELL_FAILED = core.getGMST('sMagicSkillFail'),
    INSUFFICIENT_CHARGE = core.getGMST('sMagicInsufficientCharge'),
    INSUFFICIENT_MAGICKA = core.getGMST('sMagicInsufficientSP'),
    INSUFFICIENT_ITEMS = l10n('MSG_INSUFFICIENT_ITEMS'),
    ITEM_REQUIRED = l10n('MSG_ITEM_REQUIRED')
}

return Constants