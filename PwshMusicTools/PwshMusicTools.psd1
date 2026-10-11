@{
    # Script module associated with this manifest.
    RootModule        = 'PwshMusicTools.psm1'

    ModuleVersion     = '1.0.0'

    # Supported on Windows PowerShell 5.1 and PowerShell 7+.
    CompatiblePSEditions = @('Desktop', 'Core')

    GUID              = '620ec155-a365-468a-bc61-45ded1e73024'

    Author            = 'JoshExmoor'

    CompanyName       = 'Unknown'

    Copyright         = '(c) JoshExmoor. All rights reserved.'

    Description       = 'PowerShell tools for keeping two copies of a music library (e.g. a FLAC rip and an MP3 rip) in sync by file name, reading audio tags, checking audio file integrity, and working with M3U playlists.'

    PowerShellVersion = '5.1'

    # Functions to export. The .psm1 exports exactly the functions it dot-sources
    # from Public/, so '*' here surfaces that set without a maintenance burden.
    FunctionsToExport = @(
        'Get-AudioTags'
        'Test-AudioIntegrity'
        'Find-DirsWithMatchingFiles'
        'Find-MatchingDirectories'
        'Import-M3U'
        'Export-M3U'
        'Convert-M3UPath'
        'Sync-SongFiles'
        'Sync-SongDirectories'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('Music', 'Audio', 'FLAC', 'MP3', 'M3U', 'Playlist', 'Tags', 'TagLib', 'Rename')
            ProjectUri = 'https://github.com/JoshExmoor/PwshMusicTools'
        }
    }
}
