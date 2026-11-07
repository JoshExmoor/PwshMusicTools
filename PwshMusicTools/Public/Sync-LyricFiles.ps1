function Sync-LyricFiles {
    <#
    .SYNOPSIS
        Renames lyric files so each one has the same base name as the audio file
        it belongs to, pairing them by track number.

    .DESCRIPTION
        Within each directory, every lyric file (.lrc by default) is paired with
        an audio file by the track number in the two file names, and renamed to
        the audio file's base name while keeping its own extension. For example,
        next to "01 - The Light and The Sound.opus":

            Rocky Votolato - Suicide Medicine - 01 - The Light and The Sound.lrc
            -> 01 - The Light and The Sound.lrc

        The track number does not have to be at the start of the name, and the
        separators do not need spaces: "Rocky Votolato-Suicide Medicine-01-The
        Light and The Sound.lrc" matches the same audio file, as do mixed forms
        such as "Artist - Album-01-Title". Numbers that are part of a word
        (e.g. "Blink-182 - Album - 03 - Title" -> 3) or 4+ digits long (years)
        are passed over when a better-delimited candidate exists, and a number
        that matches one of the directory's audio tracks is preferred. Disc-
        prefixed numbers (101, 201, or "1-01") pair the same way. Titles do not
        need to agree; both names are shown so you can judge.

        A lyric file with no usable track number falls back to an exact title
        match (ignoring case, punctuation and whitespace), only when exactly one
        audio file has that title. The Method column shows TrackNumber or Title.

        Audio types: mp3, flac, opus, ogg, oga, m4a, aac, wav, wma, ape, wv,
        aiff, aif, alac, mka. Each directory is matched on its own and should
        hold one audio type; a directory with more than one is skipped with a
        warning. A track number shared by several audio files, or claimed by
        several lyric files, is skipped with a warning while the rest match.
        A lyric file that is already correctly named is left alone, an existing
        file is never overwritten, and lyric files without a match are reported
        as warnings. Files other than audio and lyric files (cover.jpg, etc.)
        are ignored.

        Confirmation is per directory: for each directory with proposed renames
        a table is shown and you are asked to accept it. Declining skips only
        that directory; the next one is still offered. Answer "Yes to All" (A)
        to accept every remaining directory, or "No to All" (L) to decline them.
        -Confirm:$false renames without prompting, and -WhatIf shows every
        table but renames nothing.

    .PARAMETER Path
        A directory to process, or a single audio or lyric file, in which case
        only that file's pairing within its directory is processed. Accepts
        pipeline input, including FileInfo / DirectoryInfo objects.

    .PARAMETER LyricExtension
        Extension of the lyric files, with or without the leading dot,
        case-insensitive. Default '.lrc'.

    .PARAMETER Recurse
        Also process every subdirectory of a directory -Path.

    .OUTPUTS
        One object per proposed rename: Directory, Track, Method, CurrentName,
        NewName, AudioFile, Path (the lyric file's original full path), Renamed
        and Note ('', 'WhatIf', 'Declined', or the failure reason).

    .EXAMPLE
        Sync-LyricFiles -Path 'D:\Music\Rocky Votolato\Suicide Medicine'

        Shows the proposed renames for one album and asks before renaming
        "Rocky Votolato - Suicide Medicine - 01 - The Light and The Sound.lrc"
        to "01 - The Light and The Sound.lrc", and so on.

    .EXAMPLE
        Sync-LyricFiles -Path 'D:\Music\Album' -LyricExtension .txt

        Pairs .txt lyric files instead of .lrc ('txt' without the dot works too).

    .EXAMPLE
        Sync-LyricFiles -Path 'D:\Music' -Recurse

        Walks the whole tree, showing one table and one prompt per album
        directory that has renames to make.

    .EXAMPLE
        Sync-LyricFiles -Path 'D:\Music' -Recurse -WhatIf

        Previews every directory's renames without changing anything.

    .EXAMPLE
        Sync-LyricFiles -Path 'D:\Music\Album\Artist-Album-03-Title.lrc' -Confirm:$false

        Renames just that lyric file to match track 3's audio file, without
        prompting.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    Param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [Alias('FullName')]
        [String[]]$Path,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [String]$LyricExtension = '.lrc',

        [Parameter(Mandatory = $false)]
        [Switch]$Recurse
    )

    begin {
        Set-StrictMode -Version Latest

        # Get-NameTrackNumber, Get-TitleKey and Get-TrackTitle are shared module
        # helpers in Private\TrackMatching.ps1; Confirm-ShouldProcess is in
        # Private\ShouldProcess.ps1.

        $lyricExt = '.' + $LyricExtension.Trim().TrimStart('.')
        if ($lyricExt -eq '.') {
            throw '-LyricExtension must name an extension, e.g. .lrc or txt.'
        }

        $audioExts = [System.Collections.Generic.HashSet[string]]::new(
            [string[]]@('.mp3', '.flac', '.opus', '.ogg', '.oga', '.m4a', '.aac', '.wav',
                        '.wma', '.ape', '.wv', '.aiff', '.aif', '.alac', '.mka'),
            [StringComparer]::OrdinalIgnoreCase)
        # A lyric extension that is also an audio extension is treated as lyrics.
        [void]$audioExts.Remove($lyricExt)

        # Directories to process, in first-seen order. The value is $null to
        # process the whole directory, or the set of files -Path named in it.
        $dirOrder = [System.Collections.Generic.List[string]]::new()
        $dirFocus = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)

        $addDir = {
            param([string]$Dir, [string]$File)
            if (-not $dirFocus.ContainsKey($Dir)) {
                $dirOrder.Add($Dir)
                $dirFocus[$Dir] = $null
                if ($File) {
                    $dirFocus[$Dir] = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                    [void]$dirFocus[$Dir].Add($File)
                }
            }
            elseif ($null -ne $dirFocus[$Dir]) {
                if ($File) { [void]$dirFocus[$Dir].Add($File) } else { $dirFocus[$Dir] = $null }
            }
        }
    }

    process {
        foreach ($p in $Path) {
            if (-not (Test-Path -LiteralPath $p)) {
                Write-Error "Path '$p' does not exist."
                continue
            }
            $item = Get-Item -LiteralPath $p -Force
            if ($item.PSIsContainer) {
                & $addDir $item.FullName $null
                if ($Recurse) {
                    Get-ChildItem -LiteralPath $item.FullName -Directory -Recurse |
                        Sort-Object FullName |
                        ForEach-Object { & $addDir $_.FullName $null }
                }
            }
            elseif ($item.Extension -eq $lyricExt -or $audioExts.Contains($item.Extension)) {
                & $addDir $item.DirectoryName $item.FullName
            }
            else {
                Write-Warning "'$($item.FullName)' is not an audio file or a '$lyricExt' lyric file. Skipping."
            }
        }
    }

    end {
        $results = [System.Collections.Generic.List[object]]::new()

        foreach ($dir in $dirOrder) {
            $focus = $dirFocus[$dir]

            # Warn only about files -Path asked for (all files when a directory
            # was given). Directory-wide problems pass no files and always show.
            $report = {
                param([string]$Message, [string[]]$About)
                if ($null -eq $focus -or -not $About -or @($About | Where-Object { $focus.Contains($_) }).Count) {
                    Write-Warning $Message
                }
            }

            $files  = @(Get-ChildItem -LiteralPath $dir -File)
            $lyrics = @($files | Where-Object { $_.Extension -eq $lyricExt } | Sort-Object Name)
            $audio  = @($files | Where-Object { $audioExts.Contains($_.Extension) } | Sort-Object Name)

            if ($lyrics.Count -eq 0) {
                if ($null -ne $focus) { & $report "No '$lyricExt' lyric files found in '$dir'." }
                continue
            }
            if ($audio.Count -eq 0) {
                & $report ("No audio files found in '{0}'; {1} lyric file(s) left unmatched." -f $dir, $lyrics.Count)
                continue
            }
            $types = @($audio | ForEach-Object { $_.Extension.ToLowerInvariant() } | Sort-Object -Unique)
            if ($types.Count -gt 1) {
                & $report ("'{0}' contains more than one audio type ({1}). Skipping this directory; one audio type per directory is expected." -f $dir, ($types -join ', '))
                continue
            }

            # --- Index the audio files by track number -------------------------

            $audioByTrack = @{}
            foreach ($a in $audio) {
                $n = Get-NameTrackNumber -Name $a.Name
                if ($null -eq $n) { continue }
                if (-not $audioByTrack.ContainsKey($n)) { $audioByTrack[$n] = [System.Collections.Generic.List[object]]::new() }
                $audioByTrack[$n].Add($a)
            }
            $knownTracks = [int[]]@($audioByTrack.Keys)
            $dupTracks = @($audioByTrack.Keys | Where-Object { $audioByTrack[$_].Count -gt 1 } | Sort-Object)

            # --- Each lyric file claims one audio file ----------------------------

            # Audio FullName -> claims; first-seen order keeps the table stable.
            $claims = [ordered]@{}
            $lyricTracks = @{}
            foreach ($l in $lyrics) {
                $n = Get-NameTrackNumber -Name $l.Name -KnownTrack $knownTracks
                $lyricTracks[$l.FullName] = $n
                if ($null -ne $n) {
                    if ($n -in $dupTracks) { continue }   # reported once per track below
                    if (-not $audioByTrack.ContainsKey($n)) {
                        & $report "No audio file in '$dir' has track $n for lyric file '$($l.Name)'. Leaving it unmatched." @($l.FullName)
                        continue
                    }
                    $target = $audioByTrack[$n][0]
                    $method = 'TrackNumber'
                }
                else {
                    # Fallback: exact normalised title, only if exactly one audio file has it.
                    $keys = @(Get-TitleKey -Name $l.Name -Loose)
                    $hits = @($audio | Where-Object {
                        $ak = @(Get-TitleKey -Name $_.Name)
                        @($keys | Where-Object { $_ -in $ak }).Count -gt 0
                    })
                    if ($hits.Count -ne 1) {
                        & $report "Could not find a track number in '$($l.Name)' and no single audio file in '$dir' has the same title. Leaving it unmatched." @($l.FullName)
                        continue
                    }
                    $target = $hits[0]
                    $n = Get-NameTrackNumber -Name $target.Name
                    $method = 'Title'
                }

                if (-not $claims.Contains($target.FullName)) {
                    $claims[$target.FullName] = [System.Collections.Generic.List[object]]::new()
                }
                $claims[$target.FullName].Add([PSCustomObject]@{
                    Lyric   = $l
                    Audio   = $target
                    Track   = $n
                    Method  = $method
                    NewName = [System.IO.Path]::GetFileNameWithoutExtension($target.Name) + $l.Extension
                })
            }

            foreach ($n in $dupTracks) {
                $audioNames = ($audioByTrack[$n] | ForEach-Object { $_.Name }) -join "', '"
                $about = @($audioByTrack[$n] | ForEach-Object { $_.FullName }) +
                         @($lyrics | Where-Object { $lyricTracks[$_.FullName] -eq $n } | ForEach-Object { $_.FullName })
                & $report "Several audio files in '$dir' share track $n ('$audioNames'). Skipping that track." $about
            }

            # --- Resolve the claims into renames -------------------------------

            $renames = [System.Collections.Generic.List[object]]::new()
            foreach ($audioPath in $claims.Keys) {
                $cl = @($claims[$audioPath])
                $about = @($audioPath) + @($cl | ForEach-Object { $_.Lyric.FullName })
                $correct = @($cl | Where-Object { $_.Lyric.Name -ceq $_.NewName })

                if ($cl.Count -gt 1) {
                    if ($correct.Count) {
                        # One lyric file already has the name; never overwrite it.
                        foreach ($c in @($cl | Where-Object { $_.Lyric.Name -cne $_.NewName })) {
                            & $report "Not renaming '$($c.Lyric.Name)' in '$dir': '$($c.NewName)' already exists and will not be overwritten." @($c.Lyric.FullName, $audioPath)
                        }
                    }
                    else {
                        $names = ($cl | ForEach-Object { $_.Lyric.Name }) -join "', '"
                        & $report "Several lyric files in '$dir' match '$($cl[0].Audio.Name)' ('$names'). Skipping that track." $about
                    }
                    continue
                }

                $c = $cl[0]
                if ($correct.Count) { continue }   # already named correctly

                $targetPath = Join-Path $dir $c.NewName
                if ((Test-Path -LiteralPath $targetPath) -and
                    -not $targetPath.Equals($c.Lyric.FullName, [StringComparison]::OrdinalIgnoreCase)) {
                    & $report "Not renaming '$($c.Lyric.Name)' in '$dir': '$($c.NewName)' already exists and will not be overwritten." $about
                    continue
                }

                if ($null -ne $focus -and -not ($focus.Contains($c.Lyric.FullName) -or $focus.Contains($audioPath))) {
                    continue
                }

                $renames.Add([PSCustomObject][ordered]@{
                    Directory   = $dir
                    Track       = $c.Track
                    Method      = $c.Method
                    CurrentName = $c.Lyric.Name
                    NewName     = $c.NewName
                    AudioFile   = $c.Audio.Name
                    Path        = $c.Lyric.FullName
                    Renamed     = $false
                    Note        = ''
                })
            }

            if ($null -eq $focus) {
                $without = @($audio | Where-Object { -not $claims.Contains($_.FullName) })
                if ($without.Count) {
                    Write-Host ("{0} audio file(s) in '{1}' have no matching lyric file: {2}" -f $without.Count, $dir, (($without | ForEach-Object { $_.Name }) -join ', '))
                }
            }

            if ($renames.Count -eq 0) { continue }

            # --- Show this directory's table and confirm it ----------------------

            Write-Host "`nThe following lyric files in '$dir' will be renamed to match their audio files:"
            $renames | Format-Table -Property Track, Method, CurrentName, NewName -AutoSize -Wrap | Out-Host

            # One prompt per directory. ShouldProcess also drives -WhatIf (reports
            # and returns $false) and remembers Yes to All / No to All.
            $target = "$($renames.Count) lyric file(s) in '$dir'"
            if (Confirm-ShouldProcess -Cmdlet $PSCmdlet -Target $target -Action 'Rename to match audio files') {
                foreach ($r in $renames) {
                    try {
                        # Already confirmed for this directory; don't prompt per file.
                        Rename-Item -LiteralPath $r.Path -NewName $r.NewName -ErrorAction Stop -Confirm:$false -WhatIf:$false
                        $r.Renamed = $true
                    }
                    catch {
                        $r.Note = "Rename failed: $($_.Exception.Message)"
                        Write-Warning "Failed to rename '$($r.Path)' to '$($r.NewName)': $($_.Exception.Message)"
                    }
                }
            }
            elseif ($WhatIfPreference) {
                foreach ($r in $renames) { $r.Note = 'WhatIf' }
            }
            else {
                foreach ($r in $renames) { $r.Note = 'Declined' }
            }

            $results.AddRange($renames)
        }

        if ($results.Count -eq 0) {
            Write-Host 'No lyric files to rename.'
        }
        else {
            $done = @($results | Where-Object Renamed).Count
            Write-Host ("Sync-LyricFiles: renamed {0} of {1} lyric file(s)." -f $done, $results.Count) -ForegroundColor $(if ($done) { 'Green' } else { 'Yellow' })
        }

        # Typed array rather than a unary comma, so @() callers don't get a nested array.
        return [object[]]$results.ToArray()
    }
}
