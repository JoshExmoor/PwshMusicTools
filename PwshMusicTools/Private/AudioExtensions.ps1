# Private: the audio file extensions the module treats as music.
# Shared by Sync-LyricFiles (which files lyrics are matched to) and
# Find-CoverArt (which folders are expected to have cover art).

function Get-AudioExtension {
    <#
        Returns the audio extensions, lower-case with the leading dot. Callers
        compare case-insensitively, e.g. by building a HashSet with
        [StringComparer]::OrdinalIgnoreCase.
    #>
    return [string[]]@('.mp3', '.flac', '.opus', '.ogg', '.oga', '.m4a', '.aac', '.wav',
                       '.wma', '.ape', '.wv', '.aiff', '.aif', '.alac', '.mka')
}
