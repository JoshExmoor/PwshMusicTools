# Disc-folder name rule used by Find-CoverArt: a multi-disc album often keeps
# its cover in the album folder, with the tracks in CD1, CD2, ... sub-folders.

function Test-DiscFolderName {
    <#
        Returns $true when Name looks like a disc sub-folder: 'cd', 'disc' or
        'disk' (any case), an optional single space, '.', '_' or '-', a number,
        and optionally anything after the number that does not start with a
        digit.
        Matches:        CD1, CD 01, Disc 2, Disk_3, Disc 1 - Live, cd.2
        Does not match: CDs, Discography, CD, Disc Two, Bonus CD1
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Name)

    # -match is case-insensitive.
    return [bool]($Name -match '^(?:cd|disc|disk)[ ._-]?\d+(?:\D.*)?$')
}
