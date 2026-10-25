function Sync-SongTags {
    <#
    .SYNOPSIS
        Copies the tags from each file in a reference folder onto the matching file
        in a target folder, pairing files by leading track number.

    .DESCRIPTION
        Works like Sync-SongFiles, but instead of renaming files it copies their
        metadata. Both folders are expected to hold the same album, typically in
        different formats (for example a well-tagged FLAC rip as the reference and
        an MP3 rip to tag). Files are paired by the track number at the start of the
        file name ("01" and "1" are the same track), regardless of extension.

        For each pair, the tags of the reference file are copied onto the target
        file with TagLibSharp: title, artists, album artists, album, composers,
        genres, comment, year, track and disc numbers and counts, BPM, key,
        publisher, ISRC, grouping, conductor, copyright, lyrics and embedded
        artwork. MusicBrainz IDs and ReplayGain values are not copied.

        By default the target's tags are overwritten so they match the reference,
        including clearing fields that are empty on the reference. Use
        -FillMissingOnly to copy only into fields that are empty on the target, and
        -ExcludePictures to keep the target's own artwork.

        The reference folder is never modified. The pairs are previewed and
        confirmed once for the whole batch; use -WhatIf to preview without
        changing anything.

        Requires the TagLibSharp library, which is downloaded from NuGet and cached
        on first use (see Get-AudioTags).

    .PARAMETER ToTagDir
        The folder whose files will receive the tags. Aliased as TargetDir.

    .PARAMETER ReferenceDir
        The reference folder whose tags are copied. Never modified.

    .PARAMETER AudioExtensions
        Audio file extensions to consider, without the leading dot.
        Defaults to m4a, flac, ogg, opus, mp3.

    .PARAMETER TitleMatchThreshold
        Minimum title similarity (0.0 to 1.0, default 0.6) between the file names of
        a number-matched pair before its tags are copied. Two releases can share
        track numbers while their listings differ (e.g. an edition with bonus
        tracks shifts every later title), so a pair whose titles are too dissimilar
        is skipped with a warning instead of getting the wrong song's tags. Set to 0
        to disable the check.

    .PARAMETER FillMissingOnly
        Copy a field only when it is empty on the target, leaving the target's
        existing values in place.

    .PARAMETER ExcludePictures
        Do not copy embedded artwork; keep whatever artwork the target already has.

    .OUTPUTS
        One PSCustomObject per tagged pair with Track, Target, Reference,
        TitleScore, Status ('Tagged' or 'Failed') and Detail.

    .EXAMPLE
        Sync-SongTags -ToTagDir 'D:\MP3\Album' -ReferenceDir 'D:\FLAC\Album' -WhatIf

        Previews which MP3 files would receive tags from which FLAC files.

    .EXAMPLE
        Sync-SongTags -ToTagDir 'D:\MP3\Album' -ReferenceDir 'D:\FLAC\Album'

        Copies the FLAC tags onto the MP3s, prompting once for confirmation.

    .EXAMPLE
        Sync-SongTags -ToTagDir 'D:\MP3\Album' -ReferenceDir 'D:\FLAC\Album' -FillMissingOnly -ExcludePictures -Confirm:$false

        Fills in only the MP3s' missing fields, keeps their artwork, and does not prompt.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    Param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [Alias('TargetDir')]
        [String]$ToTagDir,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [String]$ReferenceDir,

        [Parameter(Mandatory = $false)]
        [String[]]$AudioExtensions = @('m4a', 'flac', 'ogg', 'opus', 'mp3'),

        [Parameter(Mandatory = $false)]
        [ValidateRange(0.0, 1.0)]
        [double]$TitleMatchThreshold = 0.6,

        [Parameter(Mandatory = $false)]
        [Switch]$FillMissingOnly,

        [Parameter(Mandatory = $false)]
        [Switch]$ExcludePictures
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # Get-TrackNumber, Get-TrackTitle and Get-StringSimilarity are shared module
    # helpers defined in Private\TrackMatching.ps1. Import-TagLibSharp and
    # Copy-AudioFileTag are defined in Private\TagLib.ps1.

    $extAlternation = ($AudioExtensions | ForEach-Object { [Regex]::Escape($_) }) -join '|'
    $audioPattern = "^(?<track>\d+).*\.($extAlternation)$"

    # --- Validate inputs -------------------------------------------------------

    if (-not (Test-Path -LiteralPath $ToTagDir -PathType Container)) {
        Write-Error "Target directory '$ToTagDir' is not a valid directory."
        return
    }

    if (-not (Test-Path -LiteralPath $ReferenceDir -PathType Container)) {
        Write-Error "Reference directory '$ReferenceDir' is not a valid directory."
        return
    }

    $targetRoot    = (Resolve-Path -LiteralPath $ToTagDir).ProviderPath.TrimEnd('\', '/')
    $referenceRoot = (Resolve-Path -LiteralPath $ReferenceDir).ProviderPath.TrimEnd('\', '/')
    if ($targetRoot -ieq $referenceRoot) {
        Write-Error "Target and reference directories are the same folder ('$targetRoot')."
        return
    }

    # --- Gather candidate audio files -----------------------------------------

    $ToTag = @(Get-ChildItem -LiteralPath $targetRoot -File |
        Where-Object { $_.Name -match $audioPattern })
    $Reference = @(Get-ChildItem -LiteralPath $referenceRoot -File |
        Where-Object { $_.Name -match $audioPattern })

    if ($ToTag.Count -eq 0) {
        Write-Warning "No matching audio files found in target folder '$ToTagDir'. Nothing to do."
        return
    }

    if ($ToTag.Count -ne $Reference.Count) {
        Write-Warning ("Unequal number of songs: target folder has {0}, reference folder has {1}." -f $ToTag.Count, $Reference.Count)
        Write-Warning ("Target Folder: {0}" -f $ToTagDir)
        Write-Warning ("Reference Folder: {0}" -f $ReferenceDir)
    }

    # Index both sides by track number for lookup and duplicate detection.
    $ReferenceByTrack = @{}
    foreach ($RefFile in $Reference) {
        $track = Get-TrackNumber -Name $RefFile.Name
        if ($null -eq $track) { continue }
        if ($ReferenceByTrack.ContainsKey($track)) { $ReferenceByTrack[$track] += $RefFile }
        else { $ReferenceByTrack[$track] = @($RefFile) }
    }

    $TargetByTrack = @{}
    foreach ($TgtFile in $ToTag) {
        $track = Get-TrackNumber -Name $TgtFile.Name
        if ($null -eq $track) { continue }
        if ($TargetByTrack.ContainsKey($track)) { $TargetByTrack[$track] += $TgtFile }
        else { $TargetByTrack[$track] = @($TgtFile) }
    }

    # --- Determine the pairs ---------------------------------------------------

    $WarnedDuplicateTracks = @{}

    $Pairs = foreach ($File in $ToTag) {
        $track = Get-TrackNumber -Name $File.Name
        if ($null -eq $track) {
            Write-Warning "Could not determine a track number for '$($File.Name)'. Skipping."
            continue
        }

        if ($TargetByTrack[$track].Count -gt 1) {
            if (-not $WarnedDuplicateTracks.ContainsKey($track)) {
                $names = ($TargetByTrack[$track] | ForEach-Object { $_.Name }) -join ', '
                Write-Warning "Multiple files in the target folder share track $track ($names). Skipping this track."
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

        # Guard against copying the wrong song's tags when two releases share track
        # numbers but not titles (see -TitleMatchThreshold).
        $titleScore = Get-StringSimilarity -A (Get-TrackTitle -Name $File.Name) -B (Get-TrackTitle -Name $RefFile.Name)
        if ($TitleMatchThreshold -gt 0 -and $titleScore -lt $TitleMatchThreshold) {
            Write-Warning ("Title mismatch for track {0} (similarity {1:N2} < {2:N2}): target '{3}' vs reference '{4}'. Skipping - these may be different releases. Lower -TitleMatchThreshold to override." -f `
                $track, $titleScore, $TitleMatchThreshold, $File.Name, $RefFile.Name)
            continue
        }

        [PSCustomObject]@{
            Track         = $track
            TargetName    = $File.Name
            ReferenceName = $RefFile.Name
            TargetPath    = $File.FullName
            ReferencePath = $RefFile.FullName
            TitleScore    = [Math]::Round($titleScore, 2)
        }
    }

    $Pairs = @($Pairs | Sort-Object Track)

    # --- Copy the tags ---------------------------------------------------------

    if ($Pairs.Count -eq 0) {
        Write-Host "No file pairs to tag."
        return
    }

    Write-Host "Tags will be copied from the reference files onto these target files:"
    $Pairs | Format-Table -Property Track, TargetName, ReferenceName, TitleScore -AutoSize | Out-Host

    # Confirm once for the whole batch. Under -WhatIf this reports the batch and
    # returns $false, so nothing is loaded, downloaded, or written.
    $mode = if ($FillMissingOnly) { 'Fill missing tags' } else { 'Overwrite tags' }
    if ($ExcludePictures) { $mode += ', keeping existing artwork' }
    $batch = "$($Pairs.Count) file(s) in '$ToTagDir'"
    if (-not $PSCmdlet.ShouldProcess($batch, "$mode from reference folder")) {
        return
    }

    Import-TagLibSharp

    $results = foreach ($Pair in $Pairs) {
        $status = 'Tagged'
        $detail = ''
        try {
            Copy-AudioFileTag -ReferencePath $Pair.ReferencePath -TargetPath $Pair.TargetPath `
                -FillMissingOnly:$FillMissingOnly -ExcludePictures:$ExcludePictures
        }
        catch {
            $status = 'Failed'
            $detail = $_.Exception.Message
            Write-Warning "Failed to tag '$($Pair.TargetName)' from '$($Pair.ReferenceName)': $detail"
        }

        [PSCustomObject]@{
            Track      = $Pair.Track
            Target     = $Pair.TargetPath
            Reference  = $Pair.ReferencePath
            TitleScore = $Pair.TitleScore
            Status     = $status
            Detail     = $detail
        }
    }
    $results = @($results)

    $tagged = @($results | Where-Object Status -eq 'Tagged').Count
    $color  = if ($tagged -eq $results.Count) { 'Green' } else { 'Yellow' }
    Write-Host ("Tagged {0} of {1} file(s) in '{2}'." -f $tagged, $results.Count, $ToTagDir) -ForegroundColor $color

    $results
}
