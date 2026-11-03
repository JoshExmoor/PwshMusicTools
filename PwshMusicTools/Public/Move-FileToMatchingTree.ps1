function Move-FileToMatchingTree {
    <#
    .SYNOPSIS
        Moves files into an existing library tree by matching the trailing folder
        names of each file's path (e.g. Artist\Album) against folders under a
        destination root.

    .DESCRIPTION
        For each source file, the last -Depth parent folder names of its path are
        compared with the trailing folder names of every directory under
        -DestinationHead, at any depth. With -Depth 2,
        'C:\NewMusic\Artist\Album\song.opus' matches 'E:\Music\Rock\Artist\Album'
        and the file is moved to 'E:\Music\Rock\Artist\Album\song.opus'.

        Matching is exact but case-insensitive. The destination folders keep their
        existing casing and the file keeps its own name. The destination directory
        list is built once per call, so large libraries are only enumerated once.

        Every processed file gets one row in -OutputCSV with the columns
        SourcePath, MovedToPath, DestinationBaseFileNameMatch and Note.
        MovedToPath holds the file's new full path only when it was actually
        moved. Otherwise:
          - no destination folder matches, or more than one does: MovedToPath is
            'Could not find destination' and Note gives the reason (listing the
            candidates for an ambiguous match);
          - any other reason the file was not moved: MovedToPath is empty and
            Note explains why. This covers a file with the same name and
            extension already in the matched folder (existing files are never
            overwritten), another source file in the batch targeting the same
            path, a declined confirmation, a failed move, and -WhatIf.
        DestinationBaseFileNameMatch is True when the matched folder already held
        a file with the same base name but a different extension (e.g. 'song.mp3'
        when moving 'song.opus'); it is False when no destination was found. It
        reflects the folder contents before any moves in this call.

        All moves are confirmed once for the whole batch. Under -WhatIf nothing is
        moved, Note says 'WhatIf: would move to <path>', and the CSV report is
        still written.

        The folder for -OutputCSV must already exist and the file must be
        writable; this is checked before anything is moved. If -OutputCSV lies
        inside a directory -Source, the report file itself is not processed.

        The report is written after the move stage even if it is interrupted
        (Ctrl+C, pipeline stop or an unexpected error). Files already moved then
        show their new path; files not yet reached have an empty MovedToPath
        and the Note 'Not processed (interrupted)'.

        The report rows are also returned to the pipeline.

    .PARAMETER Source
        A file, or a directory of files. Directories are searched recursively and
        every file found is processed.

    .PARAMETER DestinationHead
        The root of the destination library (e.g. 'E:\Music'). Must exist.

    .PARAMETER OutputCSV
        Path of the CSV report to write. Overwritten if it exists.

    .PARAMETER Depth
        How many trailing parent folders must match, 1 to 4 (default 2).
        1 matches Album only, 2 matches Artist\Album, and so on.

    .EXAMPLE
        Move-FileToMatchingTree -Source 'C:\NewMusic' -DestinationHead 'E:\Music' -OutputCSV 'C:\Temp\moved.csv' -WhatIf

        Previews where every file under C:\NewMusic would go, matching on
        Artist\Album, and writes the report without moving anything.

    .EXAMPLE
        Move-FileToMatchingTree -Source 'C:\NewMusic\Artist\Album\song.opus' -DestinationHead 'E:\Music' -OutputCSV 'C:\Temp\moved.csv' -Depth 1

        Moves a single file into the only folder under E:\Music named 'Album'.

    .EXAMPLE
        Move-FileToMatchingTree -Source 'C:\NewMusic' -DestinationHead 'E:\Music' -OutputCSV 'C:\Temp\moved.csv' -Confirm:$false |
            Where-Object DestinationBaseFileNameMatch

        Moves files without prompting and lists those that landed next to a file
        with the same base name (e.g. an existing MP3 of the same song).
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [String]$Source,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [String]$DestinationHead,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [String]$OutputCSV,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 4)]
        [int]$Depth = 2
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $noDestination = 'Could not find destination'

    # --- Validate inputs -------------------------------------------------------

    if (-not (Test-Path -LiteralPath $Source)) {
        Write-Error "Source '$Source' is not a valid path."
        return
    }
    if (-not (Test-Path -LiteralPath $DestinationHead -PathType Container)) {
        Write-Error "Destination head '$DestinationHead' is not a valid directory."
        return
    }

    # The report is the record of what moved, so make sure it can be written
    # before moving anything.
    $csvFull = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputCSV)
    $csvDir  = Split-Path -Parent $csvFull
    if (-not (Test-Path -LiteralPath $csvDir -PathType Container)) {
        Write-Error "OutputCSV folder '$csvDir' does not exist."
        return
    }
    try {
        $stream = [System.IO.File]::Open($csvFull, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::Write)
        $stream.Dispose()
    }
    catch {
        Write-Error "OutputCSV '$csvFull' is not writable: $($_.Exception.Message)"
        return
    }

    $sourceItem = Get-Item -LiteralPath $Source
    if ($sourceItem.PSIsContainer) {
        # Skip the report itself if it lives inside the source tree.
        $files = @(Get-ChildItem -LiteralPath $sourceItem.FullName -File -Recurse |
            Where-Object { $_.FullName -ne $csvFull } | Sort-Object FullName)
    }
    else {
        $files = @($sourceItem)
    }

    # --- Index destination directories once -----------------------------------
    # Key: the last $Depth segments of each directory's path relative to the
    # head, joined with '\'. Value: every full path with that tail. The
    # dictionary is case-insensitive so 'artist\album' finds 'Artist\Album'.

    $headFull = (Get-Item -LiteralPath $DestinationHead).FullName.TrimEnd('\', '/')
    $index = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new(
        [StringComparer]::OrdinalIgnoreCase)

    foreach ($dir in @(Get-ChildItem -LiteralPath $headFull -Directory -Recurse -ErrorAction SilentlyContinue)) {
        $relative = $dir.FullName.Substring($headFull.Length).TrimStart('\', '/')
        $segments = @($relative -split '[\\/]' | Where-Object { $_ })
        if ($segments.Count -lt $Depth) { continue }
        $key = ($segments[($segments.Count - $Depth)..($segments.Count - 1)]) -join '\'
        if (-not $index.ContainsKey($key)) {
            $index[$key] = [System.Collections.Generic.List[string]]::new()
        }
        $index[$key].Add($dir.FullName)
    }

    # --- Plan every file -------------------------------------------------------

    # Cache of destination folder -> file names present before any moves.
    $destFiles = @{}
    # Destination paths already claimed by an earlier file in this batch.
    $planned = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    $rows  = [System.Collections.Generic.List[object]]::new()
    $moves = [System.Collections.Generic.List[object]]::new()

    foreach ($file in $files) {
        $row = [PSCustomObject][ordered]@{
            SourcePath                   = $file.FullName
            MovedToPath                  = $noDestination
            DestinationBaseFileNameMatch = $false
            Note                         = ''
        }
        $rows.Add($row)

        # Strip the path root ('C:\' or '\\server\share\') so only real folder
        # names are counted and matched.
        $dirName = $file.DirectoryName
        $rootLen = [System.IO.Path]::GetPathRoot($dirName).Length
        $parents = @($dirName.Substring($rootLen) -split '[\\/]' | Where-Object { $_ })
        if ($parents.Count -lt $Depth) {
            $row.Note = "Source path has fewer than $Depth parent folder(s)"
            continue
        }
        $key = ($parents[($parents.Count - $Depth)..($parents.Count - 1)]) -join '\'

        if (-not $index.ContainsKey($key)) {
            $row.Note = "No destination folder matches '$key'"
            continue
        }
        $candidates = $index[$key]
        if ($candidates.Count -gt 1) {
            $row.Note = 'Multiple destination matches: ' + ($candidates -join '; ')
            continue
        }

        $destDir = $candidates[0]
        if (-not $destFiles.ContainsKey($destDir)) {
            $destFiles[$destDir] = @(Get-ChildItem -LiteralPath $destDir -File -Force -ErrorAction SilentlyContinue)
        }
        $existing = $destFiles[$destDir]

        $row.DestinationBaseFileNameMatch = [bool](@($existing | Where-Object {
            $_.BaseName -eq $file.BaseName -and $_.Extension -ne $file.Extension
        }).Count)

        # A destination was found; MovedToPath stays empty until the move succeeds.
        $row.MovedToPath = ''
        $destPath = Join-Path $destDir $file.Name
        if (@($existing | Where-Object { $_.Name -eq $file.Name }).Count) {
            $row.Note = "Destination file already exists: '$destPath'"
            continue
        }
        if (-not $planned.Add($destPath)) {
            $row.Note = "Another source file in this batch already targets '$destPath'"
            continue
        }

        $moves.Add([PSCustomObject]@{ Row = $row; Source = $file.FullName; Destination = $destPath })
    }

    # --- Move (confirmed once for the whole batch) -----------------------------

    $movedCount = 0

    # Until a file is handled its row says so, so an interrupted run (Ctrl+C,
    # pipeline stop, unexpected error) never reports an unmoved file as moved.
    foreach ($m in $moves) { $m.Row.Note = 'Not processed (interrupted)' }

    try {
        if ($moves.Count -gt 0) {
            $target = "$($moves.Count) file(s) into '$headFull'"
            if ($PSCmdlet.ShouldProcess($target, 'Move to matching folders')) {
                foreach ($m in $moves) {
                    try {
                        # The batch was already confirmed; don't prompt again per file.
                        Move-Item -LiteralPath $m.Source -Destination $m.Destination -ErrorAction Stop -Confirm:$false -WhatIf:$false
                        $m.Row.MovedToPath = $m.Destination
                        $m.Row.Note = ''
                        $movedCount++
                    }
                    catch {
                        Write-Warning "Failed to move '$($m.Source)' to '$($m.Destination)': $($_.Exception.Message)"
                        $m.Row.Note = "Move failed: $($_.Exception.Message)"
                    }
                }
            }
            elseif ($WhatIfPreference) {
                foreach ($m in $moves) { $m.Row.Note = "WhatIf: would move to '$($m.Destination)'" }
            }
            else {
                foreach ($m in $moves) { $m.Row.Note = 'Move declined' }
            }
        }
    }
    finally {
        # --- Report ------------------------------------------------------------
        # Written in 'finally' so files already moved are recorded even if the
        # move stage is interrupted. Also written under -WhatIf.
        $rows | Export-Csv -LiteralPath $csvFull -NoTypeInformation -Encoding UTF8 -WhatIf:$false -Confirm:$false
    }

    Write-Host ("Move-FileToMatchingTree: moved {0} of {1} file(s). Report: {2}" -f $movedCount, $rows.Count, $OutputCSV) -ForegroundColor $(if ($movedCount) { 'Green' } else { 'Yellow' })

    # Typed array rather than a unary comma, so @() callers don't get a nested array.
    return [object[]]$rows.ToArray()
}
