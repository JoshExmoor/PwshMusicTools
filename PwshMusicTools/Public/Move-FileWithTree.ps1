function Move-FileWithTree {
    <#
    .SYNOPSIS
        Moves files to another root folder, keeping the last -Depth parent folder
        names of each file's path, or its path relative to -BaseDir.

    .DESCRIPTION
        For each source file, the last -Depth parent folder names of its path are
        recreated under -DestinationHead and the file is moved there. With
        -Depth 3, 'C:\base\genre\artist\album\song.mp3' is moved to
        'C:\newbase\genre\artist\album\song.mp3'. Depth 1 keeps the album folder
        only, depth 2 keeps artist\album, and so on.

        Unlike Move-FileToMatchingTree, which only moves into folders that
        already exist, this command builds the destination tree itself:
        -DestinationHead and any missing folders below it are created as needed.
        Folder and file names keep the casing of the source path.

        Instead of -Depth, -BaseDir keeps each file's whole path relative to a
        base folder, so files at different depths can be moved in one run. With
        -BaseDir 'C:\Base' -DestinationHead 'C:\NewBase',
        'C:\Base\genre\artist\album\song.mp3' moves to
        'C:\NewBase\genre\artist\album\song.mp3' and
        'C:\Base\artist\album\song.mp3' moves to
        'C:\NewBase\artist\album\song.mp3'. A file directly in -BaseDir moves
        directly into -DestinationHead. Matching is case-insensitive on whole
        folder names, so 'C:\Base' does not match 'C:\Baseline'. Exactly one of
        -Depth or -BaseDir must be given.

        A directory -Source is searched recursively and every file found is
        processed, whatever its extension. Each file uses its own last -Depth
        parent folders, so files at different depths keep their own tails.

        A file is skipped with a warning and not moved when:
          - it has fewer than -Depth parent folders below the drive or UNC share
            root;
          - with -BaseDir, it is not inside -BaseDir;
          - a file with the same name already exists at its destination
            (existing files are never overwritten);
          - another source file in the same batch targets the same destination.

        All moves are confirmed once for the whole batch, including files piped
        in one at a time. Under -WhatIf nothing is moved and no folders are
        created, but each file's planned destination is still returned.

        Source folders left empty by the moves are not removed; run
        Remove-EmptyDirectories on the source afterwards to clean them up.

        Returns one object per file with SourcePath, DestinationPath, Moved and
        Note. DestinationPath is the planned or actual destination (empty when
        the file has too few parent folders or is outside -BaseDir). Moved is True only when the file
        was actually moved; otherwise Note explains why.

    .PARAMETER Source
        A file, or a directory of files. Directories are searched recursively.
        Accepts pipeline input, including the output of Get-ChildItem.

    .PARAMETER DestinationHead
        The destination root (e.g. 'C:\newbase'). Created if it does not exist.

    .PARAMETER Depth
        How many trailing parent folders of each file to keep, 1 to 10.
        1 keeps Album only, 2 keeps Artist\Album, 3 keeps Genre\Artist\Album.
        Cannot be combined with -BaseDir.

    .PARAMETER BaseDir
        An existing folder. Each file's path relative to it is recreated under
        -DestinationHead. Files outside it are skipped. Cannot be combined with
        -Depth.

    .EXAMPLE
        Move-FileWithTree -Source 'C:\base\genre\artist\album\song.mp3' -DestinationHead 'C:\newbase' -Depth 3

        Moves the file to 'C:\newbase\genre\artist\album\song.mp3', creating the
        genre, artist and album folders if needed.

    .EXAMPLE
        Move-FileWithTree -Source 'C:\base' -DestinationHead 'C:\newbase' -Depth 2 -WhatIf

        Previews where every file under C:\base would go, keeping Artist\Album,
        without moving anything or creating folders.

    .EXAMPLE
        Move-FileWithTree -Source 'C:\Base' -DestinationHead 'C:\NewBase' -BaseDir 'C:\Base'

        Moves 'C:\Base\genre\artist\album\song.mp3' to
        'C:\NewBase\genre\artist\album\song.mp3' and, in the same run,
        'C:\Base\artist\album\song.mp3' to 'C:\NewBase\artist\album\song.mp3'.

    .EXAMPLE
        Get-ChildItem 'C:\base' -Filter *.flac -Recurse | Move-FileWithTree -DestinationHead 'C:\newbase' -Depth 1 -Confirm:$false
        Remove-EmptyDirectories -Path 'C:\base' -Confirm:$false

        Moves only the FLAC files into album folders under C:\newbase without
        prompting, then removes the source folders the moves left empty.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Depth')]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('FullName')]
        [ValidateNotNullOrEmpty()]
        [String]$Source,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [String]$DestinationHead,

        [Parameter(Mandatory = $true, ParameterSetName = 'Depth')]
        [ValidateRange(1, 10)]
        [int]$Depth,

        [Parameter(Mandatory = $true, ParameterSetName = 'BaseDir')]
        [ValidateNotNullOrEmpty()]
        [String]$BaseDir
    )

    begin {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'

        $headFull = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DestinationHead)
        if (Test-Path -LiteralPath $headFull -PathType Leaf) {
            throw "Destination head '$DestinationHead' is a file, not a directory."
        }

        $useBaseDir = $PSCmdlet.ParameterSetName -eq 'BaseDir'
        if ($useBaseDir) {
            if (-not (Test-Path -LiteralPath $BaseDir -PathType Container)) {
                throw "Base directory '$BaseDir' is not an existing directory."
            }
            # Normalise to a full path with no trailing separator (except a bare
            # root such as 'C:\'), then match on whole segments via '<base>\'.
            $baseFull = (Get-Item -LiteralPath $BaseDir -Force).FullName
            if ($baseFull -ne [System.IO.Path]::GetPathRoot($baseFull)) {
                $baseFull = $baseFull.TrimEnd('\', '/')
            }
            $basePrefix = if ($baseFull.EndsWith('\') -or $baseFull.EndsWith('/')) { $baseFull } else { $baseFull + '\' }
        }

        # Collected across all pipeline input so the batch is confirmed once.
        $files = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
        $seen  = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    }

    process {
        if (-not (Test-Path -LiteralPath $Source)) {
            Write-Error "Source '$Source' is not a valid path." -ErrorAction Continue
            return
        }
        $item = Get-Item -LiteralPath $Source -Force
        $found = if ($item.PSIsContainer) {
            @(Get-ChildItem -LiteralPath $item.FullName -File -Recurse -Force | Sort-Object FullName)
        }
        else {
            @($item)
        }
        foreach ($f in $found) {
            if ($seen.Add($f.FullName)) { $files.Add($f) }
        }
    }

    end {
        # --- Plan every file ---------------------------------------------------

        # Destination paths already claimed by an earlier file in this batch.
        $planned = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

        $rows  = [System.Collections.Generic.List[object]]::new()
        $moves = [System.Collections.Generic.List[object]]::new()

        foreach ($file in $files) {
            $row = [PSCustomObject][ordered]@{
                SourcePath      = $file.FullName
                DestinationPath = ''
                Moved           = $false
                Note            = ''
            }
            $rows.Add($row)

            $dirName = $file.DirectoryName
            if ($useBaseDir) {
                # Keep the path relative to -BaseDir. Case-insensitive, whole
                # segments only, so 'C:\Base' does not match 'C:\Baseline\x.mp3'.
                if ($dirName.Equals($baseFull, [StringComparison]::OrdinalIgnoreCase)) {
                    $tail = ''
                }
                elseif ($dirName.StartsWith($basePrefix, [StringComparison]::OrdinalIgnoreCase)) {
                    $tail = $dirName.Substring($basePrefix.Length).TrimEnd('\', '/')
                }
                else {
                    $row.Note = "Source is not under base directory '$baseFull'"
                    Write-Warning "Skipping '$($file.FullName)': $($row.Note)."
                    continue
                }
            }
            else {
                # Strip the path root ('C:\' or '\\server\share\') so only real
                # folder names are counted.
                $rootLen = [System.IO.Path]::GetPathRoot($dirName).Length
                $parents = @($dirName.Substring($rootLen) -split '[\\/]' | Where-Object { $_ })
                if ($parents.Count -lt $Depth) {
                    $row.Note = "Source path has fewer than $Depth parent folder(s)"
                    Write-Warning "Skipping '$($file.FullName)': $($row.Note)."
                    continue
                }
                $tail = ($parents[($parents.Count - $Depth)..($parents.Count - 1)]) -join '\'
            }

            # A file directly in -BaseDir has an empty tail and goes straight into the head.
            $destDir  = if ($tail) { Join-Path $headFull $tail } else { $headFull }
            $destPath = Join-Path $destDir $file.Name
            $row.DestinationPath = $destPath

            if (Test-Path -LiteralPath $destPath) {
                $row.Note = "Destination file already exists: '$destPath'"
                Write-Warning "Skipping '$($file.FullName)': $($row.Note)."
                continue
            }
            if (-not $planned.Add($destPath)) {
                $row.Note = "Another source file in this batch already targets '$destPath'"
                Write-Warning "Skipping '$($file.FullName)': $($row.Note)."
                continue
            }

            $moves.Add([PSCustomObject]@{ Row = $row; Source = $file.FullName; DestDir = $destDir; Destination = $destPath })
        }

        # --- Move (confirmed once for the whole batch) -------------------------

        $movedCount = 0
        if ($moves.Count -gt 0) {
            $target = if ($useBaseDir) {
                "$($moves.Count) file(s) into '$headFull' (keeping paths relative to '$baseFull')"
            }
            else {
                "$($moves.Count) file(s) into '$headFull' (keeping $Depth folder level(s))"
            }
            if ($PSCmdlet.ShouldProcess($target, 'Move with folder tree')) {
                foreach ($m in $moves) {
                    try {
                        # The batch was already confirmed; don't prompt again per item.
                        if (-not (Test-Path -LiteralPath $m.DestDir -PathType Container)) {
                            New-Item -ItemType Directory -Path $m.DestDir -Force -Confirm:$false -WhatIf:$false | Out-Null
                        }
                        Move-Item -LiteralPath $m.Source -Destination $m.Destination -ErrorAction Stop -Confirm:$false -WhatIf:$false
                        $m.Row.Moved = $true
                        $movedCount++
                    }
                    catch {
                        $m.Row.Note = "Move failed: $($_.Exception.Message)"
                        Write-Warning "Failed to move '$($m.Source)' to '$($m.Destination)': $($_.Exception.Message)"
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

        Write-Host ("Move-FileWithTree: moved {0} of {1} file(s)." -f $movedCount, $rows.Count) -ForegroundColor $(if ($movedCount) { 'Green' } else { 'Yellow' })

        # Typed array rather than a unary comma, so @() callers don't get a nested array.
        return [object[]]$rows.ToArray()
    }
}
