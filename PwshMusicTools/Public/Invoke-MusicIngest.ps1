function Invoke-MusicIngest {
    <#
    .SYNOPSIS
        Maps folders of new music to existing library folders, renames them to
        match, and runs Sync-SongFiles on each matched pair.

    .DESCRIPTION
        Step 1 - map folders. Every folder under -SourceDirectory that directly
        holds at least one audio file is a "music folder". Its depth is the
        number of folder levels from -SourceDirectory down to and including it,
        capped at 3:
          Source\Artist\Album\song.mp3        depth 2 (Artist\Album)
          Source\VA - Some Album\song.mp3     depth 1 (VA - Some Album)
          Source\Artist\Album\CD1\song.mp3    depth 3 (Artist\Album\CD1)
        A music folder deeper than 3 levels uses its last 3 folder names. The
        last N folder names are compared with the last N folder names of every
        folder anywhere under -TargetDirectory, so Source\Artist\Album matches
        Target\Genre\Artist\Album. The target folder list is built once per run.

        Exact matching ignores case and compares whole folder names. If the
        source differs from the target only in letter case, the source folders
        are renamed to the target's casing without asking. If several target
        folders match exactly, the folder is reported as Ambiguous and left alone.

        With -Fuzzy, a folder with no exact match is compared with the target
        folders folder name by folder name (case, punctuation and extra spaces
        ignored, digits kept). The score is the lowest similarity of any folder
        name, so every name must be similar. A match needs a score of at least
        -Threshold. The best candidate wins; a tie is reported as Ambiguous. For
        each fuzzy match you are asked whether to rename the source folders to
        match the target (Yes to All and No to All work as in other commands).
        Only the folder names below -SourceDirectory are renamed. A declined
        fuzzy match stays unrenamed and Step 2 does not run for it.

        Renames never merge or overwrite: if a folder of the new name already
        exists, that rename is skipped with a warning. Two music folders under
        one renamed parent both end up under the renamed parent.

        Step 2 - sync file names. For each folder with an accepted match (exact,
        or fuzzy and renamed) Sync-SongFiles is run with the source folder and
        the matched target folder, so you can rename the songs to match the
        target. A failure in one folder is a warning; the run continues.
        Sync-SongFiles asks for its own confirmation per folder unless
        -Confirm:$false is given.

        Under -WhatIf nothing is renamed. The results show the planned match,
        and Sync-SongFiles runs with -WhatIf only for folders that need no
        rename first.

        The command never deletes anything and never moves files out of
        -SourceDirectory. Junctions and symlinks are not followed. Audio files
        directly in -SourceDirectory are skipped with a warning.

        One result per music folder is returned, with the properties
        SourceFolder (path before any rename), CurrentSourceFolder (path after
        renames), Depth, MatchType (Exact, Fuzzy, None, Ambiguous or Skipped),
        TargetFolder, Score, Renamed, SyncResult and Note.

        Planned steps (NOT implemented yet):
          Step 3 - transcoding.
          Step 4 - move transcoded files and other non-music files to a holder
                   directory.

    .PARAMETER SourceDirectory
        The folder holding the new music. Must exist.

    .PARAMETER TargetDirectory
        The library folder to match against. Must exist. Alias: DestinationDirectory.

    .PARAMETER Fuzzy
        Also match similar folder names when there is no exact match.

    .PARAMETER Threshold
        Minimum similarity from 0 to 1 for a fuzzy match (default 0.8). Only
        used with -Fuzzy.

    .EXAMPLE
        Invoke-MusicIngest -SourceDirectory 'C:\Incoming' -TargetDirectory 'E:\Music'

        Matches folders exactly (ignoring case), then runs Sync-SongFiles on each match.

    .EXAMPLE
        Invoke-MusicIngest -SourceDirectory 'C:\Incoming' -TargetDirectory 'E:\Music' -Fuzzy -Threshold 0.9

        Also matches similar folder names with a score of at least 0.9 and asks
        before renaming each one.

    .EXAMPLE
        Invoke-MusicIngest -SourceDirectory 'C:\Incoming' -TargetDirectory 'E:\Music' -Fuzzy -WhatIf

        Shows the matches and planned renames without changing anything.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [String]$SourceDirectory,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [Alias('DestinationDirectory')]
        [String]$TargetDirectory,

        [Parameter(Mandatory = $false)]
        [Switch]$Fuzzy,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0.0, 1.0)]
        [double]$Threshold = 0.8
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $activity = 'Invoke-MusicIngest'
    $maxDepth = 3

    # --- Validate inputs -------------------------------------------------------

    if (-not (Test-Path -LiteralPath $SourceDirectory -PathType Container)) {
        Write-Error "Source directory '$SourceDirectory' is not a valid directory."
        return
    }
    if (-not (Test-Path -LiteralPath $TargetDirectory -PathType Container)) {
        Write-Error "Target directory '$TargetDirectory' is not a valid directory."
        return
    }

    $fixRoot = {
        param([string]$p)
        $p = (Get-Item -LiteralPath $p).FullName
        if ($p -match '^[A-Za-z]:[\\/]*$') { return $p.Substring(0, 2) + '\' }
        return $p.TrimEnd('\', '/')
    }
    $srcRoot = & $fixRoot $SourceDirectory
    $tgtRoot = & $fixRoot $TargetDirectory
    $srcPrefix = $srcRoot.TrimEnd('\', '/') + '\'
    $tgtPrefix = $tgtRoot.TrimEnd('\', '/') + '\'

    $audioExt = [System.Collections.Generic.HashSet[string]]::new(
        [string[]](Get-AudioExtension), [StringComparer]::OrdinalIgnoreCase)

    # Walks a tree without following junctions or symlinks. Returns one entry
    # per directory (root included) with whether it directly holds audio.
    $walk = {
        param([string]$Root, $AudioSet)
        $found = [System.Collections.Generic.List[object]]::new()
        $stack = [System.Collections.Generic.Stack[string]]::new()
        $stack.Push($Root)
        while ($stack.Count -gt 0) {
            $dir = $stack.Pop()
            $hasAudio = $false
            try {
                $children = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop)
            } catch {
                Write-Warning "Could not read '$dir': $($_.Exception.Message)"
                $children = @()
            }
            foreach ($c in $children) {
                if ($c.PSIsContainer) {
                    if ($c.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                    $stack.Push($c.FullName)
                } elseif ($AudioSet.Contains($c.Extension)) {
                    $hasAudio = $true
                }
            }
            $found.Add([pscustomobject]@{ Path = $dir; HasAudio = $hasAudio })
        }
        return [object[]]$found.ToArray()
    }

    $ordinalIgnore = [StringComparer]::OrdinalIgnoreCase

    # --- Build the target index once, keyed by trailing N folder names ---------

    $index = @{}
    foreach ($n in 1..$maxDepth) {
        $index[$n] = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new($ordinalIgnore)
    }
    foreach ($d in @(& $walk $tgtRoot $audioExt)) {
        if ($d.Path -ieq $tgtRoot) { continue }
        $segs = @($d.Path.Substring($tgtPrefix.Length) -split '[\\/]' | Where-Object { $_ })
        foreach ($n in 1..$maxDepth) {
            if ($segs.Count -lt $n) { continue }
            $key = $segs[($segs.Count - $n)..($segs.Count - 1)] -join '\'
            if (-not $index[$n].ContainsKey($key)) {
                $index[$n][$key] = [System.Collections.Generic.List[string]]::new()
            }
            $index[$n][$key].Add($d.Path)
        }
    }

    # --- Find the source music folders -----------------------------------------

    $newRow = {
        param([string]$Path, [int]$Depth)
        [pscustomobject][ordered]@{
            SourceFolder        = $Path
            CurrentSourceFolder = $Path
            Depth               = $Depth
            MatchType           = 'None'
            TargetFolder        = $null
            Score               = $null
            Renamed             = $false
            SyncResult          = ''
            Note                = ''
        }
    }

    $results = [System.Collections.Generic.List[object]]::new()
    $items = [System.Collections.Generic.List[object]]::new()

    $musicDirs = @(& $walk $srcRoot $audioExt | Where-Object { $_.HasAudio } |
        Sort-Object { $_.Path.ToLowerInvariant() })

    foreach ($m in $musicDirs) {
        if ($m.Path -ieq $srcRoot) {
            Write-Warning "Audio files directly in '$srcRoot' are skipped; they cannot be matched to a folder."
            $row = & $newRow $m.Path 0
            $row.MatchType = 'Skipped'
            $row.Note = 'Audio files directly in SourceDirectory; not matched'
            $results.Add($row)
            continue
        }
        $segs = @($m.Path.Substring($srcPrefix.Length) -split '[\\/]' | Where-Object { $_ })
        $depth = [Math]::Min($maxDepth, $segs.Count)
        $row = & $newRow $m.Path $depth
        $tail = @($segs[($segs.Count - $depth)..($segs.Count - 1)])
        $item = [pscustomobject]@{
            Row        = $row
            Segs       = $segs
            Depth      = $depth
            Tail       = $tail
            TargetTail = @()
            Prompt     = $false
            AutoRename = $false
            Renames    = @()
            Pending    = $false
        }
        $items.Add($item)
        $results.Add($row)
    }

    $counts = @{ Exact = 0; FuzzyAccepted = 0; FuzzyDeclined = 0; FuzzyPlanned = 0; None = 0; Ambiguous = 0; Skipped = 0 }
    $segScores = @{}

    # Rename planning state (original paths throughout).
    $plan = [System.Collections.Generic.Dictionary[string, string]]::new($ordinalIgnore)
    $claimed = [System.Collections.Generic.Dictionary[string, string]]::new($ordinalIgnore)
    $planOrder = [System.Collections.Generic.List[object]]::new()
    $applied = [System.Collections.Generic.Dictionary[string, string]]::new($ordinalIgnore)

    $origPath = { param($item, [int]$k) $srcPrefix + ($item.Segs[0..$k] -join '\') }

    # Admits all of an item's renames, or none. Returns $null or a reason.
    $tryAdmit = {
        param($item)
        $props = [System.Collections.Generic.List[object]]::new()
        for ($j = 0; $j -lt $item.Depth; $j++) {
            $newName = $item.TargetTail[$j]
            $k = $item.Segs.Count - $item.Depth + $j
            if ($item.Segs[$k] -ceq $newName) { continue }
            $orig = & $origPath $item $k
            $parent = if ($k -eq 0) { $srcRoot } else { & $origPath $item ($k - 1) }
            $props.Add([pscustomobject]@{ Orig = $orig; Parent = $parent; New = $newName; Count = $k + 1 })
        }
        $fresh = [System.Collections.Generic.List[object]]::new()
        foreach ($p in $props) {
            $existing = $null
            if ($plan.TryGetValue($p.Orig, [ref]$existing)) {
                if ($existing -ceq $p.New) { continue }
                return "Rename of '$($p.Orig)' to '$($p.New)' conflicts with a planned rename to '$existing'"
            }
            $claimKey = $p.Parent.ToLowerInvariant() + '\' + $p.New.ToLowerInvariant()
            $owner = $null
            if ($claimed.TryGetValue($claimKey, [ref]$owner) -and $owner -ine $p.Orig) {
                return "Rename target '$($p.New)' already exists (claimed by another rename in '$($p.Parent)')"
            }
            $clash = @(Get-ChildItem -LiteralPath $p.Parent -Directory -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ieq $p.New -and $_.FullName -ine $p.Orig })
            if ($clash.Count -gt 0) {
                return "Rename target '$($p.New)' already exists in '$($p.Parent)'"
            }
            $fresh.Add($p)
        }
        foreach ($p in $fresh) {
            $plan[$p.Orig] = $p.New
            $claimed[$p.Parent.ToLowerInvariant() + '\' + $p.New.ToLowerInvariant()] = $p.Orig
            $planOrder.Add($p)
        }
        $item.Renames = $props.ToArray()
        return $null
    }

    try {
        # --- Step 1: map folders to existing folders ---------------------------

        foreach ($item in $items) {
            $row = $item.Row
            Write-Progress -Activity $activity -Status $row.SourceFolder
            $key = $item.Tail -join '\'

            $hits = $null
            if ($index[$item.Depth].TryGetValue($key, [ref]$hits)) {
                if ($hits.Count -gt 1) {
                    $row.MatchType = 'Ambiguous'
                    $row.Note = 'Multiple exact matches: ' + ($hits -join '; ')
                    Write-Warning "'$($row.SourceFolder)' matches several target folders: $($hits -join '; ')"
                    continue
                }
                $row.MatchType = 'Exact'
                $row.Score = 1.0
                $row.TargetFolder = $hits[0]
                $tp = @($hits[0] -split '[\\/]' | Where-Object { $_ })
                $item.TargetTail = @($tp[($tp.Count - $item.Depth)..($tp.Count - 1)])
                if (($item.Tail -join '\') -cne ($item.TargetTail -join '\')) { $item.AutoRename = $true }
                continue
            }

            if (-not $Fuzzy) {
                $row.Note = 'No matching target folder'
                continue
            }

            $best = -1.0
            $bestPaths = [System.Collections.Generic.List[string]]::new()
            $bestKey = $null
            foreach ($k in $index[$item.Depth].Keys) {
                $ks = $k -split '\\'
                $score = 1.0
                for ($i = 0; $i -lt $item.Depth; $i++) {
                    $ck = ($item.Tail[$i] + '|' + $ks[$i]).ToLowerInvariant()
                    if (-not $segScores.ContainsKey($ck)) {
                        $segScores[$ck] = Get-NameSimilarity -A $item.Tail[$i] -B $ks[$i]
                    }
                    if ($segScores[$ck] -lt $score) { $score = $segScores[$ck] }
                    if ($score -lt $Threshold) { break }
                }
                if ($score -lt $Threshold) { continue }
                if ($score -gt $best + 1e-9) {
                    $best = $score
                    $bestPaths.Clear()
                    $bestKey = $k
                    $bestPaths.AddRange([string[]]$index[$item.Depth][$k])
                } elseif ([Math]::Abs($score - $best) -le 1e-9) {
                    $bestPaths.AddRange([string[]]$index[$item.Depth][$k])
                }
            }

            if ($bestPaths.Count -eq 0) {
                $row.Note = 'No matching target folder'
                continue
            }
            if ($bestPaths.Count -gt 1) {
                $row.MatchType = 'Ambiguous'
                $row.Note = 'Several similar target folders: ' + ($bestPaths -join '; ')
                Write-Warning "'$($row.SourceFolder)' is similar to several target folders: $($bestPaths -join '; ')"
                continue
            }
            $row.MatchType = 'Fuzzy'
            $row.Score = [Math]::Round($best, 2)
            $row.TargetFolder = $bestPaths[0]
            $item.TargetTail = @($bestKey -split '\\')
            $item.Prompt = $true
        }

        # --- Decide and plan renames, one prompt per fuzzy folder --------------

        foreach ($item in $items) {
            $row = $item.Row
            if ($item.AutoRename) {
                $why = & $tryAdmit $item
                if ($why) {
                    Write-Warning "$($row.SourceFolder): $why. Skipping rename."
                    $row.Note = $why
                } elseif ($WhatIfPreference) {
                    $item.Pending = $true
                    $row.Note = 'WhatIf: would rename to match target casing'
                } else {
                    $item.Pending = $true
                }
            } elseif ($item.Prompt) {
                $target = "'$($item.Tail -join '\')' -> '$($item.TargetTail -join '\')' (score $($row.Score))"
                if (Confirm-ShouldProcess -Cmdlet $PSCmdlet -Target $target -Action 'Rename source folder(s) to match target') {
                    $counts.FuzzyAccepted++
                    $why = & $tryAdmit $item
                    if ($why) {
                        Write-Warning "$($row.SourceFolder): $why. Skipping rename."
                        $row.Note = $why
                    } else {
                        $item.Pending = $true
                    }
                } elseif ($WhatIfPreference) {
                    $counts.FuzzyPlanned++
                    $row.Note = "WhatIf: would rename '$($item.Tail -join '\')' to '$($item.TargetTail -join '\')'"
                } else {
                    $counts.FuzzyDeclined++
                    $row.Note = 'Rename declined'
                }
            }
        }

        # --- Apply renames, children before parents ----------------------------

        if (-not $WhatIfPreference) {
            foreach ($p in @($planOrder | Sort-Object -Property Count -Descending)) {
                try {
                    $leaf = Split-Path -Leaf $p.Orig
                    if ($leaf -ieq $p.New) {
                        $tmp = $leaf + '.pmt-' + [guid]::NewGuid().ToString('N')
                        Rename-Item -LiteralPath $p.Orig -NewName $tmp -Confirm:$false -WhatIf:$false
                        try {
                            Rename-Item -LiteralPath (Join-Path $p.Parent $tmp) -NewName $p.New -Confirm:$false -WhatIf:$false
                        } catch {
                            Rename-Item -LiteralPath (Join-Path $p.Parent $tmp) -NewName $leaf -Confirm:$false -WhatIf:$false
                            throw
                        }
                    } else {
                        Rename-Item -LiteralPath $p.Orig -NewName $p.New -Confirm:$false -WhatIf:$false
                    }
                    $applied[$p.Orig] = $p.New
                } catch {
                    Write-Warning "Could not rename '$($p.Orig)' to '$($p.New)': $($_.Exception.Message)"
                }
            }
        }

        foreach ($item in $items) {
            $row = $item.Row
            $renames = @($item.Renames)
            if ($renames.Count -gt 0 -and -not $WhatIfPreference) {
                $ok = @($renames | Where-Object { $applied.ContainsKey($_.Orig) }).Count -eq $renames.Count
                $row.Renamed = $ok
                if (-not $ok) { $row.Note = 'Rename failed' }
            }
            # Current path: map each original prefix through the successful renames.
            $cur = $srcPrefix.TrimEnd('\')
            for ($k = 0; $k -lt $item.Segs.Count; $k++) {
                $name = $item.Segs[$k]
                $newName = $null
                if ($applied.TryGetValue((& $origPath $item $k), [ref]$newName)) { $name = $newName }
                $cur = $cur.TrimEnd('\') + '\' + $name
            }
            $row.CurrentSourceFolder = $cur
        }

        # --- Step 2: sync song file names for accepted matches -----------------

        $forward = @{}
        foreach ($name in 'WhatIf', 'Confirm', 'Verbose') {
            if ($PSBoundParameters.ContainsKey($name)) { $forward[$name] = $PSBoundParameters[$name] }
        }

        foreach ($item in $items) {
            $row = $item.Row
            $accepted = ($row.MatchType -eq 'Exact') -or ($row.MatchType -eq 'Fuzzy' -and $row.Renamed)
            if (-not $accepted -or -not $row.TargetFolder) { continue }
            Write-Progress -Activity $activity -Status $row.CurrentSourceFolder
            if ($WhatIfPreference -and $item.Pending) {
                $row.SyncResult = 'Not run: WhatIf, rename planned'
                continue
            }
            $syncWarn = @()
            try {
                Sync-SongFiles -RenameDir $row.CurrentSourceFolder -ReferenceDir $row.TargetFolder -IgnoreExtension -TitleMatchThreshold 0.01 @forward -WarningVariable syncWarn | Out-Host
                $w = @($syncWarn | Where-Object { $_ }).Count
                if ($WhatIfPreference) { $row.SyncResult = 'WhatIf' }
                elseif ($w -gt 0) { $row.SyncResult = "Completed with $w warning(s)" }
                else { $row.SyncResult = 'Completed' }
            } catch {
                Write-Warning "Sync-SongFiles failed for '$($row.CurrentSourceFolder)': $($_.Exception.Message)"
                $row.SyncResult = "Failed: $($_.Exception.Message)"
            }
        }
    } finally {
        Write-Progress -Activity $activity -Completed
    }

    # === Step 3 (NOT IMPLEMENTED): transcoding ===
    # Reserved for a later revision; intentionally no parameters, behaviour or
    # output.
    #region Step 3
    # (empty)
    #endregion

    # --- Summary ---------------------------------------------------------------

    foreach ($r in $results) {
        if ($r.MatchType -eq 'Exact') { $counts.Exact++ }
        elseif ($r.MatchType -eq 'None') { $counts.None++ }
        elseif ($r.MatchType -eq 'Ambiguous') { $counts.Ambiguous++ }
        elseif ($r.MatchType -eq 'Skipped') { $counts.Skipped++ }
    }
    $summary = "Invoke-MusicIngest: Exact $($counts.Exact), Fuzzy accepted $($counts.FuzzyAccepted), Fuzzy declined $($counts.FuzzyDeclined)"
    if ($WhatIfPreference) { $summary += ", Fuzzy planned (WhatIf) $($counts.FuzzyPlanned)" }
    $summary += ", None $($counts.None), Ambiguous $($counts.Ambiguous), Skipped $($counts.Skipped)"
    Write-Host $summary

    return [object[]]$results.ToArray()
}
