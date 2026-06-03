local I = require('openmw.interfaces')

if I.Settings and I.Settings.registerPage then
    I.Settings.registerPage({
        key = 'MagExpPage',
        l10n = 'OMW_MagExp',
        name = 'SettingsPageTitle',
        description = 'SettingsPageDescription'
    })
end