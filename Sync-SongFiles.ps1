<#
    Sync-SongFiles.ps1

    Dual-purpose file: it defines the Sync-SongFiles function AND can be run
    directly as a script for legacy use.

      - Run as a script:   .\Sync-SongFiles.ps1 -RenameDir X -ReferenceDir Y
        The script-level param block below binds the arguments and the shim at
        the end invokes the function with them.

      - Dot-source to load the function:   . .\Sync-SongFiles.ps1
        This defines Sync-SongFiles in the current session without executing it,
        so you (or another script) can call Sync-SongFiles later.

    The script-level param block intentionally mirrors the function's param
    block so that script invocation keeps full tab-completion, validation, and
    -WhatIf / -Confirm support.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
Param(
    # NOTE: RenameDir/ReferenceDir are intentionally NOT Mandatory at the script
    # level. A mandatory script parameter would prompt even when the file is
    # merely dot-sourced to load the function. Mandatoriness is enforced on the
    # function instead, which only runs when actually invoked.
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [Alias('SourceDir')]
    [String]$RenameDir,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [Alias('DestDir')]
    [String]$ReferenceDir,

    [Parameter()]
    [String[]]$AudioExtensions = @('m4a', 'flac', 'ogg', 'opus', 'mp3'),

    [Parameter()]
    [Switch]$IgnoreExtension,

    [Parameter()]
    [ValidateRange(0.0, 1.0)]
    [double]$TitleMatchThreshold = 0.6
)

function Sync-SongFiles {
    <#
    .SYNOPSIS
        Renames audio files in one folder so their names match the corresponding
        files in a reference folder, pairing files by leading track number.

    .DESCRIPTION
        Both folders are expected to contain the same album in (possibly) different
        formats or taggings. Files are paired by the track number at the start of the
        file name (e.g. "01", "1"). For each matched pair whose names differ, the file
        in the rename folder is renamed to match the reference file's name.

        By default, a pair is only renamed when both files have the same extension.
        Use -IgnoreExtension to pair files regardless of extension (e.g. a .flac file
        with a .mp3 reference); in that mode each renamed file keeps its own original
        extension and only its base name is changed to match the reference.

        The reference folder is never modified. The function supports -WhatIf and
        -Confirm; use -WhatIf to preview the renames without changing anything.

    .PARAMETER RenameDir
        The folder whose files will be renamed. Aliased as SourceDir.

    .PARAMETER ReferenceDir
        The reference folder. File names here are treated as the desired names and
        are never changed. Aliased as DestDir.

    .PARAMETER AudioExtensions
        Audio file extensions to consider, without the leading dot.
        Defaults to m4a, flac, ogg, opus, mp3.

    .PARAMETER IgnoreExtension
        Pair files even when their extensions differ. Each renamed file keeps its own
        extension; only its base name is changed to match the reference file. Without
        this switch, a pair whose extensions differ is skipped with a warning.

    .PARAMETER TitleMatchThreshold
        Minimum title similarity (0.0 to 1.0, default 0.6) required before a
        number-matched pair is actually renamed. Pairing is by leading track number,
        but two folders that are not the same release can still share track numbers
        (e.g. one edition inserts bonus tracks, shifting every later title). This
        guard compares the title portion of each pair (the name after the track
        number, minus extension) and SKIPS with a warning any pair whose titles are
        less similar than the threshold, so a shifted track listing is flagged rather
        than silently renamed to the wrong song. Set to 0 to disable the check.

    .EXAMPLE
        Sync-SongFiles -RenameDir 'D:\MP3\Album' -ReferenceDir 'D:\FLAC\Album' -WhatIf

        Previews which files in the MP3 folder would be renamed to match the FLAC folder.

    .EXAMPLE
        Sync-SongFiles -RenameDir 'D:\MP3\Album' -ReferenceDir 'D:\FLAC\Album'

        Renames the MP3 files to match the FLAC names, prompting for confirmation.

    .EXAMPLE
        Sync-SongFiles -RenameDir 'D:\FLAC\Album' -ReferenceDir 'D:\MP3\Album' -IgnoreExtension

        Renames the FLAC files to match the MP3 base names while keeping the .flac
        extension (e.g. "1 track.flac" -> "01 Track.flac" when the reference is
        "01 Track.mp3").
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
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
        [Switch]$IgnoreExtension,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0.0, 1.0)]
        [double]$TitleMatchThreshold = 0.6
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # Build a regex that matches a leading track number followed by any name and an
    # allowed audio extension. The track number is captured so pairs can be matched.
    $extAlternation = ($AudioExtensions | ForEach-Object { [Regex]::Escape($_) }) -join '|'
    $audioPattern = "^(?<track>\d+).*\.($extAlternation)$"

    function Get-TrackNumber {
        <#
            Returns the leading track number of a file name as an integer, or $null
            if the name does not start with digits. Parsing as an integer makes
            "01" and "1" compare equal and avoids the "1 matches 10" prefix problem.
        #>
        param([Parameter(Mandatory = $true)][string]$Name)

        if ($Name -match '^\d+') {
            return [int]$Matches[0]
        }
        return $null
    }

    function Get-Title {
        <#
            Extracts the comparable title portion of a file name: drops the leading
            track number and any following separator (space, dash, dot, underscore,
            parentheses), drops the extension, and lower-cases / collapses whitespace.
            "05 - You A Millionaire.flac" -> "you a millionaire".
        #>
        param([Parameter(Mandatory = $true)][string]$Name)

        $base = [System.IO.Path]::GetFileNameWithoutExtension($Name)
        # Remove leading digits and the separators that commonly follow a track number.
        $title = $base -replace '^\s*\d+\s*[-_.\)\]]*\s*', ''
        return ($title -replace '\s+', ' ').Trim().ToLowerInvariant()
    }

    function Get-Similarity {
        <#
            Normalized Levenshtein similarity in [0,1]: 1 - distance / maxLen.
            Two empty strings are defined as identical (1.0).
        #>
        param([string]$A, [string]$B)

        if ($A -eq $B) { return 1.0 }
        $lenA = $A.Length
        $lenB = $B.Length
        if ($lenA -eq 0 -or $lenB -eq 0) { return 0.0 }

        $prev = [int[]]::new($lenB + 1)
        $curr = [int[]]::new($lenB + 1)
        for ($j = 0; $j -le $lenB; $j++) { $prev[$j] = $j }

        for ($i = 1; $i -le $lenA; $i++) {
            $curr[0] = $i
            $cA = $A[$i - 1]
            for ($j = 1; $j -le $lenB; $j++) {
                $cost = if ($cA -eq $B[$j - 1]) { 0 } else { 1 }
                $del = $prev[$j] + 1
                $ins = $curr[$j - 1] + 1
                $sub = $prev[$j - 1] + $cost
                $min = $del
                if ($ins -lt $min) { $min = $ins }
                if ($sub -lt $min) { $min = $sub }
                $curr[$j] = $min
            }
            $tmp = $prev; $prev = $curr; $curr = $tmp
        }

        $distance = $prev[$lenB]
        $maxLen = [Math]::Max($lenA, $lenB)
        return 1.0 - ($distance / $maxLen)
    }

    # --- Validate inputs -------------------------------------------------------

    if (-not (Test-Path -LiteralPath $RenameDir)) {
        Write-Error "Rename directory '$RenameDir' is not a valid path."
        return
    }

    if (-not (Test-Path -LiteralPath $ReferenceDir)) {
        Write-Error "Reference directory '$ReferenceDir' is not a valid path."
        return
    }

    # --- Gather candidate audio files -----------------------------------------

    # $ToRename  : files that will be renamed.
    # $Reference : files whose names are authoritative (never modified).
    $ToRename = @(Get-ChildItem -LiteralPath $RenameDir -File |
        Where-Object { $_.Name -match $audioPattern })
    $Reference = @(Get-ChildItem -LiteralPath $ReferenceDir -File |
        Where-Object { $_.Name -match $audioPattern })

    if ($ToRename.Count -eq 0) {
        Write-Warning "No matching audio files found in rename folder '$RenameDir'. Nothing to do."
        return
    }

    if ($ToRename.Count -ne $Reference.Count) {
        Write-Warning ("Unequal number of songs: rename folder has {0}, reference folder has {1}." -f $ToRename.Count, $Reference.Count)
        Write-Warning ("Rename Folder: {0}" -f $RenameDir)
        Write-Warning ("Reference Folder: {0}" -f $ReferenceDir)
    }

    # Index reference files by track number for O(1) lookup and duplicate detection.
    $ReferenceByTrack = @{}
    foreach ($RefFile in $Reference) {
        $track = Get-TrackNumber -Name $RefFile.Name
        if ($null -eq $track) { continue }
        if ($ReferenceByTrack.ContainsKey($track)) {
            $ReferenceByTrack[$track] += $RefFile
        }
        else {
            $ReferenceByTrack[$track] = @($RefFile)
        }
    }

    # Index rename-folder files the same way, so duplicate track numbers on the
    # rename side are detected up front rather than failing later at Rename-Item
    # (two files renamed to the same target name).
    $RenameByTrack = @{}
    foreach ($RenFile in $ToRename) {
        $track = Get-TrackNumber -Name $RenFile.Name
        if ($null -eq $track) { continue }
        if ($RenameByTrack.ContainsKey($track)) {
            $RenameByTrack[$track] += $RenFile
        }
        else {
            $RenameByTrack[$track] = @($RenFile)
        }
    }

    # --- Determine the renames -------------------------------------------------

    $WarnedDuplicateTracks = @{}

    $Renames = foreach ($File in $ToRename) {
        $track = Get-TrackNumber -Name $File.Name
        if ($null -eq $track) {
            Write-Warning "Could not determine a track number for '$($File.Name)'. Skipping."
            continue
        }

        if ($RenameByTrack[$track].Count -gt 1) {
            # The loop visits each duplicate file, so warn only once per track.
            if (-not $WarnedDuplicateTracks.ContainsKey($track)) {
                $names = ($RenameByTrack[$track] | ForEach-Object { $_.Name }) -join ', '
                Write-Warning "Multiple files in the rename folder share track $track ($names). Skipping this track to avoid renaming them to the same name."
                $WarnedDuplicateTracks[$track] = $true
            }
            continue
        }

        if (-not $ReferenceByTrack.ContainsKey($track)) {
            Write-Warning "No reference file matches track $track ('$($File.Name)'). Skipping."
            continue
        }

        $refMatches = $ReferenceByTrack[$track]
        if ($refMatches.Count -gt 1) {
            $names = ($refMatches | ForEach-Object { $_.Name }) -join ', '
            Write-Warning "Multiple reference files match track $track ($names). Skipping this track."
            continue
        }

        $RefFile = $refMatches[0]

        if ($File.Extension -ne $RefFile.Extension) {
            if (-not $IgnoreExtension) {
                Write-Warning ("Extension mismatch for track {0}: rename '{1}' vs reference '{2}'. Skipping (use -IgnoreExtension to pair across extensions)." -f `
                    $track, $File.Name, $RefFile.Name)
                continue
            }
        }

        # Guard against pairing the wrong song. Files are matched by track number, but
        # two different releases can share numbers (e.g. an edition with extra tracks
        # shifts every later title). Compare the title portions and skip if they are
        # too dissimilar, so a shifted listing is flagged rather than mis-renamed.
        # The score is always computed so it can be shown in the preview table; the
        # threshold only governs whether a pair is skipped.
        $renameTitle = Get-Title -Name $File.Name
        $refTitle = Get-Title -Name $RefFile.Name
        $titleScore = Get-Similarity -A $renameTitle -B $refTitle
        if ($TitleMatchThreshold -gt 0 -and $titleScore -lt $TitleMatchThreshold) {
            Write-Warning ("Title mismatch for track {0} (similarity {1:N2} < {2:N2}): rename '{3}' vs reference '{4}'. Skipping - these may be different releases. Lower -TitleMatchThreshold to override." -f `
                $track, $titleScore, $TitleMatchThreshold, $File.Name, $RefFile.Name)
            continue
        }

        # Determine the target name. Normally this is the reference file's full name.
        # With -IgnoreExtension, keep the rename file's own extension and take only
        # the reference file's base name.
        if ($IgnoreExtension) {
            $NewName = [System.IO.Path]::GetFileNameWithoutExtension($RefFile.Name) + $File.Extension
        }
        else {
            $NewName = $RefFile.Name
        }

        if ($File.Name -ne $NewName) {
            [PSCustomObject]@{
                Track       = $track
                CurrentName = $File.Name
                NewName     = $NewName
                FullPath    = $File.FullName
                TitleScore  = [Math]::Round($titleScore, 2)
            }
        }
    }

    $Renames = @($Renames)

    # --- Apply the renames -----------------------------------------------------

    if ($Renames.Count -eq 0) {
        Write-Host "No files to rename. Names already match the reference folder."
        return
    }

    Write-Host "The following files will be renamed to match the reference folder:"
    $Renames | Format-Table -Property Track, CurrentName, NewName, TitleScore -AutoSize

    # Confirm once for the whole batch rather than once per file. ShouldProcess also
    # drives -WhatIf: under -WhatIf it reports the batch and returns $false without
    # prompting, so no renames are performed.
    $target = "$($Renames.Count) file(s) in '$RenameDir'"
    if (-not $PSCmdlet.ShouldProcess($target, "Rename to match reference folder")) {
        return
    }

    foreach ($Rename in $Renames) {
        # Confirmation already handled once above; suppress any per-item prompt that
        # an elevated $ConfirmPreference would otherwise trigger here.
        Rename-Item -LiteralPath $Rename.FullPath -NewName $Rename.NewName -Confirm:$false
    }
}

# --- Script invocation shim ------------------------------------------------
# When this file is run as a script (not dot-sourced), forward the script's
# bound parameters to the function. Dot-sourcing ('. .\Sync-SongFiles.ps1')
# sets InvocationName to '.', so the function is defined but not executed.
if ($MyInvocation.InvocationName -ne '.') {
    Sync-SongFiles @PSBoundParameters
}
