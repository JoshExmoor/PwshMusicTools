function Sync-SongDirectories {
    <#
    .SYNOPSIS
        Runs Sync-SongFiles for every album folder that exists in both the
        rename and reference directories.

    .DESCRIPTION
        Finds the sub-folders present in both RenameDir and ReferenceDir (matched by
        name) and, for each matching pair, invokes Sync-SongFiles to rename the
        files in the rename folder so they match the reference folder. The reference
        folders are never modified.

        -WhatIf and -Confirm are forwarded to Sync-SongFiles, so -WhatIf previews
        all renames across every matched folder without changing anything.

    .PARAMETER RenameDir
        Parent folder containing the album sub-folders to be renamed. Aliased as SourceDir.

    .PARAMETER ReferenceDir
        Parent folder containing the reference album sub-folders. Aliased as DestDir.

    .PARAMETER AudioExtensions
        Audio file extensions to consider, without the leading dot. Forwarded to
        Sync-SongFiles. Defaults to m4a, flac, ogg, opus, mp3.

    .PARAMETER IgnoreExtension
        Pair files even when their extensions differ, keeping each renamed file's own
        extension. Forwarded to Sync-SongFiles.

    .EXAMPLE
        Sync-SongDirectories -RenameDir 'D:\MP3' -ReferenceDir 'D:\FLAC' -WhatIf

    .EXAMPLE
        Sync-SongDirectories -RenameDir 'D:\FLAC' -ReferenceDir 'D:\MP3' -IgnoreExtension
    #>
    [CmdletBinding(SupportsShouldProcess)]
    Param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [Alias('SourceDir')]
        [String]$RenameDir,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [Alias('DestDir')]
        [String]$ReferenceDir,

        [Parameter(Mandatory = $false)]
        [String[]]$AudioExtensions = @('m4a', 'flac', 'ogg', 'opus', 'mp3'),

        [Parameter(Mandatory = $false)]
        [Switch]$IgnoreExtension
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if (-not (Test-Path -LiteralPath $RenameDir)) {
        Write-Error "Rename directory '$RenameDir' is not a valid path."
        return
    }

    if (-not (Test-Path -LiteralPath $ReferenceDir)) {
        Write-Error "Reference directory '$ReferenceDir' is not a valid path."
        return
    }

    $RenameFolders = @(Get-ChildItem -LiteralPath $RenameDir -Directory)
    $ReferenceFolders = @(Get-ChildItem -LiteralPath $ReferenceDir -Directory)

    # Index reference folders by name for a direct, case-insensitive lookup.
    $ReferenceByName = @{}
    foreach ($folder in $ReferenceFolders) {
        $ReferenceByName[$folder.Name] = $folder
    }

    $MatchingFolders = $RenameFolders | Where-Object { $ReferenceByName.ContainsKey($_.Name) }

    if (-not $MatchingFolders) {
        Write-Host "No album folders are present in both '$RenameDir' and '$ReferenceDir'."
        return
    }

    # Forward common parameters (-WhatIf, -Confirm, -Verbose, etc.) to the per-folder
    # function, but not the directory parameters, which are supplied per folder below.
    $Forwarded = @{}
    foreach ($key in $PSBoundParameters.Keys) {
        if ($key -notin @('RenameDir', 'ReferenceDir')) {
            $Forwarded[$key] = $PSBoundParameters[$key]
        }
    }

    foreach ($RenameFolder in $MatchingFolders) {
        $ReferenceFolder = $ReferenceByName[$RenameFolder.Name]

        Write-Host ""
        Write-Host "Rename:    $($RenameFolder.FullName)"
        Write-Host "Reference: $($ReferenceFolder.FullName)"

        Sync-SongFiles -RenameDir $RenameFolder.FullName -ReferenceDir $ReferenceFolder.FullName @Forwarded
    }
}
