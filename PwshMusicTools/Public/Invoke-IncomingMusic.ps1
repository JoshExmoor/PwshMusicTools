function Invoke-IncomingMusic {
<#
.SYNOPSIS
    Run optional processing steps over the music files in a directory tree.

.DESCRIPTION
    Invoke-IncomingMusic walks the sub-directories of a given path and performs
    one or more opt-in processing steps on the audio files it finds. Each step is
    enabled by its own switch; with no step switch the function does nothing but
    warn, so it is safe to run exploratively.

    When several steps are requested they run in a fixed, safe order: the
    read-only / in-place steps first (-AudioIntegrity, -CheckTrackNumbering) and
    the folder-moving steps (-OrganizeByArtist, -RemoveEmptyDirectories) last, so
    moving or removing a folder never pulls it out from under an earlier step.

    Steps currently available:

    -AudioIntegrity
        For every sub-directory that directly contains audio files, run
        Test-AudioIntegrity over that folder. Any file reported CORRUPT or ERROR
        is renamed with a 'CORRUPTED ' prefix so it stands out and sorts together.
        Files already prefixed are left alone (so re-runs are idempotent). Every
        flagged file is listed at the end of the run and returned as output.

        Requires ffmpeg and ffprobe on the PATH (used by Test-AudioIntegrity).

    -CheckTrackNumbering
        For every audio folder, read the track numbers from the tags and verify
        they form a complete run 1..max with no gaps. Track numbers are compared
        as integers, so 1, 01 and 001 are the same track. This step only reports
        (a warning plus a result object per folder); it changes nothing.

        Requires the TagLibSharp library used by Get-AudioTags (downloaded and
        cached on first use).

    -OrganizeByArtist
        For every audio folder, read the tags and move the folder under an artist
        folder, based on the album artist. The artist folders are created under
        -OrganizeDestination when given, otherwise under the base -Path. Writing
        <Dest> for whichever root applies:
          * all files share one AlbumArtist -> <Dest>\<AlbumArtist>\<folder>
          * AlbumArtist is 'Various Artists' / 'Various' / 'VA' -> <Dest>\Various Artists\<folder>
          * AlbumArtist blank for all files -> fall back to Artist:
              - all files share one Artist -> <Dest>\<Artist>\<folder>
              - multiple distinct Artists   -> <Dest>\Various Artists\<folder>
        A folder whose AlbumArtist tags are present but inconsistent (and not a
        Various-Artists alias) is skipped with a warning rather than guessed at.
        Folders already in the right place, and moves whose destination already
        exists, are skipped.

        Requires the TagLibSharp library used by Get-AudioTags.

    -RemoveEmptyDirectories
        Recursively remove any sub-directory whose subtree contains no files (a
        folder holding only other empty folders counts as empty). Runs last so it
        cleans up directories left behind by -OrganizeByArtist. The base -Path
        itself is never removed.

    The function supports -WhatIf and -Confirm: under -WhatIf the renames, moves,
    and removals are previewed without touching anything.

.PARAMETER Path
    The root directory whose sub-directories will be processed. Audio files
    directly in this root are included as well. For -OrganizeByArtist this is the
    base under which artist folders are created, unless -OrganizeDestination is
    given.

.PARAMETER AudioIntegrity
    Enable the audio-integrity step described above.

.PARAMETER CheckTrackNumbering
    Enable the track-numbering check described above.

.PARAMETER OrganizeByArtist
    Enable the tag-based folder-reorganization step described above.

.PARAMETER OrganizeDestination
    For -OrganizeByArtist, the base directory under which artist folders are
    created. Defaults to -Path. Created if it does not exist. Use this to move
    organized albums into a separate library root (e.g. organize from an incoming
    folder into D:\Music).

.PARAMETER RemoveEmptyDirectories
    Enable the empty-directory pruning step described above.

.PARAMETER Extension
    Audio file extensions to consider (without the leading dot). Defaults to the
    common lossless/lossy set.

.OUTPUTS
    PSCustomObjects describing the actions/findings of each enabled step:
      -AudioIntegrity      : one object per flagged file (Step 'AudioIntegrity').
      -CheckTrackNumbering : one object per folder (Step 'CheckTrackNumbering').
      -OrganizeByArtist    : one object per folder acted on or skipped (Step 'OrganizeByArtist').

.EXAMPLE
    Invoke-IncomingMusic -Path 'D:\Incoming' -AudioIntegrity

.EXAMPLE
    Invoke-IncomingMusic -Path 'D:\Incoming' -OrganizeByArtist -WhatIf

    Previews where each album folder would be moved based on its album-artist tags.

.EXAMPLE
    Invoke-IncomingMusic -Path 'D:\Incoming' -OrganizeByArtist -OrganizeDestination 'D:\Music'

    Organizes albums from the incoming folder into artist folders under a separate
    library root (D:\Music) rather than in place.

.EXAMPLE
    Invoke-IncomingMusic -Path 'D:\Incoming' -CheckTrackNumbering

    Reports any album folder with gaps in its track numbering.
#>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [string] $Path,

        [switch] $AudioIntegrity,

        [switch] $CheckTrackNumbering,

        [switch] $OrganizeByArtist,

        [string] $OrganizeDestination,

        [switch] $RemoveEmptyDirectories,

        [string[]] $Extension = @('flac','mp3','m4a','aac','ogg','opus','wav','wma','ape','wv')
    )

    begin {
        $corruptPrefix = 'CORRUPTED '
        $variousAliases = @('various artists', 'various', 'va')
        $variousFolder  = 'Various Artists'

        # Normalize a tag value for comparison: trim and treat blank as $null.
        $normTag = {
            param($v)
            if ($null -eq $v) { return $null }
            $s = ([string]$v).Trim()
            if ([string]::IsNullOrEmpty($s)) { return $null }
            return $s
        }
    }

    process {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            Write-Error "Path '$Path' is not a valid directory."
            return
        }

        if (-not ($AudioIntegrity -or $CheckTrackNumbering -or $OrganizeByArtist -or $RemoveEmptyDirectories)) {
            Write-Warning "No processing step was requested. Use -AudioIntegrity, -CheckTrackNumbering, -OrganizeByArtist, or -RemoveEmptyDirectories to select work to perform."
            return
        }

        $extRegex = '\.(' + (($Extension | ForEach-Object { [regex]::Escape($_.TrimStart('.')) }) -join '|') + ')$'
        $baseRoot = (Resolve-Path -LiteralPath $Path).ProviderPath

        # Discover the directories (root + every sub-directory) that directly
        # contain at least one audio file. Snapshot the full paths up front so a
        # folder move in -OrganizeByArtist cannot disturb iteration.
        $getAudioDirs = {
            $allDirs = @(Get-Item -LiteralPath $baseRoot) +
                       @(Get-ChildItem -LiteralPath $baseRoot -Directory -Recurse -ErrorAction SilentlyContinue)
            foreach ($dir in $allDirs) {
                $hasAudio = Get-ChildItem -LiteralPath $dir.FullName -File -ErrorAction SilentlyContinue |
                            Where-Object { $_.Extension -match $extRegex } |
                            Select-Object -First 1
                if ($hasAudio) { $dir.FullName }
            }
        }

        # =====================================================================
        # Step 1: -AudioIntegrity (rename corrupt/unreadable files in place)
        # =====================================================================
        if ($AudioIntegrity) {
            foreach ($tool in 'ffmpeg', 'ffprobe') {
                if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
                    Write-Error "-AudioIntegrity requires '$tool' on the PATH, but it was not found."
                    return
                }
            }

            $flagged = [System.Collections.Generic.List[object]]::new()

            foreach ($dirPath in (& $getAudioDirs)) {
                Write-Verbose "Checking integrity of audio files in '$dirPath'."
                $checkResults = Test-AudioIntegrity -Path $dirPath -Extension $Extension

                foreach ($r in $checkResults) {
                    if ($r.Status -ne 'CORRUPT' -and $r.Status -ne 'ERROR') { continue }

                    $file = Get-Item -LiteralPath $r.File -ErrorAction SilentlyContinue
                    if (-not $file) { continue }
                    if ($file.Name.StartsWith($corruptPrefix)) {
                        Write-Verbose "Already flagged, skipping: $($file.Name)"
                        continue
                    }

                    $newName = $corruptPrefix + $file.Name
                    $renamed = $false
                    if ($PSCmdlet.ShouldProcess($file.FullName, "Rename to '$newName' ($($r.Status))")) {
                        try {
                            Rename-Item -LiteralPath $file.FullName -NewName $newName -ErrorAction Stop
                            $renamed = $true
                        }
                        catch { Write-Warning "Failed to rename '$($file.FullName)': $($_.Exception.Message)" }
                    }

                    $flagged.Add([PSCustomObject][ordered]@{
                        Step         = 'AudioIntegrity'
                        OriginalPath = $file.FullName
                        NewName      = $newName
                        Status       = $r.Status
                        Detail       = $r.Detail
                        Renamed      = $renamed
                    })
                }
            }

            $flagged

            if ($flagged.Count -eq 0) {
                Write-Host "Audio integrity: no corrupt or unreadable files found." -ForegroundColor Green
            }
            else {
                Write-Host ("Audio integrity: {0} file(s) flagged as corrupt or unreadable:" -f $flagged.Count) -ForegroundColor Yellow
                foreach ($f in $flagged) { Write-Host ("  [{0}] {1}" -f $f.Status, $f.OriginalPath) -ForegroundColor Yellow }
            }
        }

        # =====================================================================
        # Step 2: -CheckTrackNumbering (report gaps in track numbers; read-only)
        # =====================================================================
        if ($CheckTrackNumbering) {
            $trackResults = [System.Collections.Generic.List[object]]::new()

            foreach ($dirPath in (& $getAudioDirs)) {
                Write-Verbose "Checking track numbering in '$dirPath'."

                $files = Get-ChildItem -LiteralPath $dirPath -File -ErrorAction SilentlyContinue |
                         Where-Object { $_.Extension -match $extRegex }
                if (-not $files) { continue }

                $tags = $files | Get-AudioTags

                # Normalize track numbers to integers; 0 / missing count as "no number".
                $numbers = foreach ($t in $tags) {
                    $n = 0
                    if ($t.PSObject.Properties['Track'] -and $null -ne $t.Track) { $n = [int]$t.Track }
                    if ($n -gt 0) { $n }
                }
                $numbers = @($numbers | Sort-Object -Unique)

                $complete = $false
                $missing  = @()

                if ($numbers.Count -gt 0) {
                    $max      = ($numbers | Measure-Object -Maximum).Maximum
                    $expected = 1..$max
                    $missing  = @($expected | Where-Object { $_ -notin $numbers })
                    $complete = ($missing.Count -eq 0)
                }

                $result = [PSCustomObject][ordered]@{
                    Step        = 'CheckTrackNumbering'
                    Directory   = $dirPath
                    TrackCount  = @($tags).Count
                    Numbers     = $numbers
                    Max         = if ($numbers.Count) { ($numbers | Measure-Object -Maximum).Maximum } else { 0 }
                    Missing     = $missing
                    Complete    = $complete
                }
                $trackResults.Add($result)

                if (-not $complete) {
                    if ($numbers.Count -eq 0) {
                        Write-Warning "Track numbering: no track numbers found in '$dirPath'."
                    }
                    else {
                        Write-Warning ("Track numbering: '{0}' is missing track(s): {1} (highest is {2})." -f `
                            $dirPath, ($missing -join ', '), $result.Max)
                    }
                }
            }

            $trackResults

            $incomplete = @($trackResults | Where-Object { -not $_.Complete })
            if ($incomplete.Count -eq 0) {
                Write-Host "Track numbering: all audio folders have complete track numbering." -ForegroundColor Green
            }
            else {
                Write-Host ("Track numbering: {0} folder(s) with gaps or missing numbers." -f $incomplete.Count) -ForegroundColor Yellow
            }
        }

        # =====================================================================
        # Step 3: -OrganizeByArtist (move folders under artist folders; mutating)
        # =====================================================================
        if ($OrganizeByArtist) {
            # Artist folders are created under -OrganizeDestination when supplied,
            # otherwise under the base path. Resolve/create it up front.
            if ($PSBoundParameters.ContainsKey('OrganizeDestination') -and $OrganizeDestination) {
                if (-not (Test-Path -LiteralPath $OrganizeDestination -PathType Container)) {
                    try { New-Item -ItemType Directory -Path $OrganizeDestination -Force | Out-Null }
                    catch {
                        Write-Error "OrganizeByArtist: could not create destination '$OrganizeDestination': $($_.Exception.Message)"
                        return
                    }
                }
                $organizeRoot = (Resolve-Path -LiteralPath $OrganizeDestination).ProviderPath
            }
            else {
                $organizeRoot = $baseRoot
            }

            $moveResults = [System.Collections.Generic.List[object]]::new()

            foreach ($dirPath in (& $getAudioDirs)) {
                $dir = Get-Item -LiteralPath $dirPath -ErrorAction SilentlyContinue
                if (-not $dir) { continue }

                $files = Get-ChildItem -LiteralPath $dirPath -File -ErrorAction SilentlyContinue |
                         Where-Object { $_.Extension -match $extRegex }
                if (-not $files) { continue }

                $tags = @($files | Get-AudioTags)

                # Decide the destination artist folder from the tags.
                $albumArtists = @($tags | ForEach-Object { & $normTag $_.AlbumArtist } | Where-Object { $_ })
                $distinctAA   = @($albumArtists | Sort-Object -Unique)
                $artists      = @($tags | ForEach-Object { & $normTag $_.Artist } | Where-Object { $_ })
                $distinctAr   = @($artists | Sort-Object -Unique)

                $destArtist = $null
                $reason     = $null

                if ($distinctAA.Count -ge 1) {
                    # AlbumArtist present on at least one file.
                    $allVarious = ($distinctAA.Count -ge 1) -and
                                  (@($distinctAA | Where-Object { $_.ToLowerInvariant() -notin $variousAliases }).Count -eq 0)

                    if ($allVarious) {
                        $destArtist = $variousFolder
                        $reason     = 'AlbumArtist is Various Artists'
                    }
                    elseif ($distinctAA.Count -eq 1) {
                        $destArtist = $distinctAA[0]
                        $reason     = 'AlbumArtist'
                    }
                    else {
                        # Present but inconsistent and not all Various -> ambiguous.
                        Write-Warning ("OrganizeByArtist: '{0}' has inconsistent AlbumArtist tags ({1}); skipping." -f `
                            $dirPath, ($distinctAA -join ', '))
                        $moveResults.Add([PSCustomObject][ordered]@{
                            Step        = 'OrganizeByArtist'
                            Directory   = $dirPath
                            Destination = $null
                            Reason      = 'Inconsistent AlbumArtist'
                            Moved       = $false
                        })
                        continue
                    }
                }
                else {
                    # No AlbumArtist anywhere: fall back to Artist.
                    if ($distinctAr.Count -eq 1) {
                        $destArtist = $distinctAr[0]
                        $reason     = 'Artist (AlbumArtist blank)'
                    }
                    elseif ($distinctAr.Count -gt 1) {
                        $destArtist = $variousFolder
                        $reason     = 'Multiple Artists, AlbumArtist blank'
                    }
                    else {
                        Write-Warning ("OrganizeByArtist: '{0}' has no AlbumArtist or Artist tags; skipping." -f $dirPath)
                        $moveResults.Add([PSCustomObject][ordered]@{
                            Step        = 'OrganizeByArtist'
                            Directory   = $dirPath
                            Destination = $null
                            Reason      = 'No artist tags'
                            Moved       = $false
                        })
                        continue
                    }
                }

                # Sanitize the artist name for use as a folder (strip chars illegal
                # on Windows); collapse whitespace.
                $safeArtist = ($destArtist -replace '[<>:"/\\|?*]', '_' -replace '\s+', ' ').Trim()
                $destArtistDir = Join-Path $organizeRoot $safeArtist
                $destPath      = Join-Path $destArtistDir $dir.Name

                # Already in the right place? (parent dir is the target artist folder)
                $currentParent = Split-Path $dir.FullName -Parent
                if ($currentParent.TrimEnd('\','/').Equals($destArtistDir.TrimEnd('\','/'), [StringComparison]::OrdinalIgnoreCase)) {
                    Write-Verbose "OrganizeByArtist: '$dirPath' already under '$safeArtist'; skipping."
                    $moveResults.Add([PSCustomObject][ordered]@{
                        Step = 'OrganizeByArtist'; Directory = $dirPath; Destination = $destPath
                        Reason = "$reason (already placed)"; Moved = $false
                    })
                    continue
                }

                # Destination already exists? Don't overwrite/merge.
                if (Test-Path -LiteralPath $destPath) {
                    Write-Warning ("OrganizeByArtist: destination '{0}' already exists; skipping '{1}'." -f $destPath, $dirPath)
                    $moveResults.Add([PSCustomObject][ordered]@{
                        Step = 'OrganizeByArtist'; Directory = $dirPath; Destination = $destPath
                        Reason = "$reason (destination exists)"; Moved = $false
                    })
                    continue
                }

                $moved = $false
                if ($PSCmdlet.ShouldProcess($dir.FullName, "Move to '$destPath' ($reason)")) {
                    try {
                        if (-not (Test-Path -LiteralPath $destArtistDir)) {
                            New-Item -ItemType Directory -Path $destArtistDir -Force | Out-Null
                        }
                        Move-Item -LiteralPath $dir.FullName -Destination $destPath -ErrorAction Stop
                        $moved = $true
                    }
                    catch { Write-Warning "OrganizeByArtist: failed to move '$($dir.FullName)' to '$destPath': $($_.Exception.Message)" }
                }

                $moveResults.Add([PSCustomObject][ordered]@{
                    Step        = 'OrganizeByArtist'
                    Directory   = $dirPath
                    Destination = $destPath
                    Reason      = $reason
                    Moved       = $moved
                })
            }

            $moveResults

            $movedCount = @($moveResults | Where-Object { $_.Moved }).Count
            Write-Host ("OrganizeByArtist: moved {0} of {1} audio folder(s) into artist folders." -f $movedCount, $moveResults.Count) -ForegroundColor $(if ($movedCount) { 'Green' } else { 'Yellow' })
        }

        # =====================================================================
        # Step 4: -RemoveEmptyDirectories (prune empty folders; mutating, last)
        # =====================================================================
        if ($RemoveEmptyDirectories) {
            $removeResults = [System.Collections.Generic.List[object]]::new()

            # A directory is "empty" when its subtree contains no files at all (a
            # folder holding only other empty folders is itself empty). Process
            # deepest-first (longest path first) so that removing a leaf empty
            # folder lets its now-empty parent be removed in the same pass. The
            # base -Path itself is never removed.
            $subDirs = @(Get-ChildItem -LiteralPath $baseRoot -Directory -Recurse -ErrorAction SilentlyContinue) |
                       Sort-Object { $_.FullName.Length } -Descending

            foreach ($dir in $subDirs) {
                # Re-test existence: a parent may have been removed already this pass.
                if (-not (Test-Path -LiteralPath $dir.FullName)) { continue }

                $hasFile = Get-ChildItem -LiteralPath $dir.FullName -File -Recurse -Force -ErrorAction SilentlyContinue |
                           Select-Object -First 1
                if ($hasFile) { continue }

                $removed = $false
                if ($PSCmdlet.ShouldProcess($dir.FullName, "Remove empty directory")) {
                    try {
                        Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction Stop
                        $removed = $true
                    }
                    catch { Write-Warning "RemoveEmptyDirectories: failed to remove '$($dir.FullName)': $($_.Exception.Message)" }
                }

                $removeResults.Add([PSCustomObject][ordered]@{
                    Step      = 'RemoveEmptyDirectories'
                    Directory = $dir.FullName
                    Removed   = $removed
                })
            }

            $removeResults

            $removedCount = @($removeResults | Where-Object { $_.Removed }).Count
            if ($removeResults.Count -eq 0) {
                Write-Host "Remove empty directories: none found." -ForegroundColor Green
            }
            else {
                Write-Host ("Remove empty directories: removed {0} of {1} empty folder(s)." -f $removedCount, $removeResults.Count) -ForegroundColor $(if ($removedCount) { 'Green' } else { 'Yellow' })
            }
        }
    }
}
