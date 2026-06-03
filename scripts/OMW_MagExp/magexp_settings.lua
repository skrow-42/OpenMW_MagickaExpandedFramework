local I = require('openmw.interfaces')

if I.Settings and I.Settings.registerGroup then
    I.Settings.registerGroup({
        key = 'SettingsMagExp_General',
        page = 'MagExpPage',
        l10n = 'OMW_MagExp',
        name = 'SettingsGeneralTitle',
        permanentStorage = true,
        order = 1,
        settings = {
            {
                key = 'DebugMode',
                name = 'SettingsDebugModeTitle',
                description = 'SettingsDebugModeDescription',
                renderer = 'checkbox',
                default = false
            }
        }
    })
end
