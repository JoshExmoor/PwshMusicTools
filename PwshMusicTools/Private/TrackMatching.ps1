# Private helpers for pairing audio files across two folders by track number.
# Shared by Sync-SongFiles (rename to match) and Sync-SongTags (copy tags).
# Get-NameTrackNumber and Get-TitleKey serve Sync-LyricFiles.

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

function Test-TrackSequence {
    <#
        Checks a folder's track numbers for completeness. Used by
        Invoke-IncomingMusic -CheckTrackNumbering.

        Plain numbering (1, 2, 3 ...): the unique numbers must form 1..max.

        Disc-prefixed numbering (101, 102 ... 201, 202 ...): detected when every
        number is >= 101 and none is a multiple of 100, i.e. each one reads as
        <disc><two-digit track> with a track of 01..99. A real single disc with
        more than 99 tracks always contains 1..99 as well, so it stays plain; a
        folder mixing plain and prefixed numbers also stays plain and is flagged
        by the plain 1..max check. In this mode each disc 1..maxDisc must be
        present, and each disc's tracks must run 01..max with no gaps or
        duplicates. Missing / Duplicates hold the disc-prefixed numbers (e.g.
        203); Problems holds one message per finding, naming the disc.

        Values <= 0 (missing tag) are ignored, as before.
    #>
    param([int[]] $Number = @())

    $raw    = @($Number | Where-Object { $_ -gt 0 })
    $unique = @($raw | Sort-Object -Unique)
    $max    = if ($unique.Count) { $unique[-1] } else { 0 }

    $discPrefixed = $unique.Count -gt 0 -and
                    @($unique | Where-Object { $_ -lt 101 -or ($_ % 100) -eq 0 }).Count -eq 0

    $missing      = [System.Collections.Generic.List[int]]::new()
    $duplicates   = [System.Collections.Generic.List[int]]::new()
    $missingDiscs = [System.Collections.Generic.List[int]]::new()
    $problems     = [System.Collections.Generic.List[string]]::new()
    $discs        = @()

    if (-not $discPrefixed) {
        if ($max -gt 0) {
            foreach ($n in 1..$max) { if ($n -notin $unique) { $missing.Add($n) } }
        }
    }
    else {
        $discs = @($unique | ForEach-Object { [int][Math]::Floor($_ / 100) } | Sort-Object -Unique)
        $dupSet = @($raw | Group-Object | Where-Object { $_.Count -gt 1 } |
                    ForEach-Object { [int]$_.Name } | Sort-Object)

        foreach ($disc in 1..$discs[-1]) {
            if ($disc -notin $discs) {
                $missingDiscs.Add($disc)
                continue
            }

            $tracks   = @($unique | Where-Object { [Math]::Floor($_ / 100) -eq $disc } | ForEach-Object { $_ % 100 })
            $discMax  = $tracks[-1]
            $discMiss = @(1..$discMax | Where-Object { $_ -notin $tracks })
            foreach ($t in $discMiss) { $missing.Add($disc * 100 + $t) }
            if ($discMiss.Count) {
                $problems.Add(("disc {0} is missing track(s): {1} (highest is {2})" -f $disc, ($discMiss -join ', '), $discMax))
            }

            $discDup = @($dupSet | Where-Object { [Math]::Floor($_ / 100) -eq $disc })
            foreach ($d in $discDup) { $duplicates.Add($d) }
            if ($discDup.Count) {
                $problems.Add(("disc {0} has duplicate track(s): {1}" -f $disc, (($discDup | ForEach-Object { $_ % 100 }) -join ', ')))
            }
        }

        if ($missingDiscs.Count) {
            $problems.Insert(0, ("is missing disc(s): {0} (highest disc is {1})" -f ($missingDiscs -join ', '), $discs[-1]))
        }
    }

    [PSCustomObject][ordered]@{
        Numbers      = $unique
        Max          = $max
        Missing      = [object[]]$missing.ToArray()
        DiscPrefixed = $discPrefixed
        Discs        = $discs
        MissingDiscs = [object[]]$missingDiscs.ToArray()
        Duplicates   = [object[]]$duplicates.ToArray()
        Complete     = ($unique.Count -gt 0 -and $missing.Count -eq 0 -and
                        $missingDiscs.Count -eq 0 -and $duplicates.Count -eq 0)
        Problems     = [object[]]$problems.ToArray()
    }
}

function Get-TrackTitle {
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

function Get-StringSimilarity {
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

function Get-NameTrackNumber {
    <#
        Finds the track number anywhere in a file name, for names that do not
        always start with it ("Artist - Album - 05 - Title.lrc",
        "Artist-Album-05-Title.lrc"). Used by Sync-LyricFiles. Returns an [int]
        or $null.

        Candidates are 1-3 digit numbers not glued to a letter or digit
        ("Track5", "5th" and "1979" are never candidates). A disc-track token
        "1-01" / "2.05" becomes 101 / 205, the disc-prefixed form
        Test-TrackSequence understands; "101" is kept as-is. 0 is ignored.

        A candidate is "strong" when it is delimited like a track number:
        preceded by the start of the name or a '-' / '_' / '(' / '[' (spaces
        allowed), and followed by the end, a '-' / '_' / '.' / ')' / ']' (spaces
        allowed), or - for a number at the very start - a space ("01 Title").
        Bare hyphens count, so "Artist-Album-01-Title" works.

        The candidates are narrowed in order, each step applied only if it
        leaves at least one candidate:
          1. drop a number that ends the name (it is the title: "02 - 22");
          2. keep numbers in -KnownTrack (the audio track numbers, if given);
          3. keep strong candidates;
          4. keep 1-2 digit numbers over 3-digit ones ("Blink-182-Enema-03-x");
        then take the one at the start of the name if there is one ("01 Title
        2 Remix" -> 1), otherwise the last one, nearest the title.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [int[]]$KnownTrack
    )

    $base = [System.IO.Path]::GetFileNameWithoutExtension($Name).Trim()
    $pattern = '(?<![\p{L}\p{N}])(?:(?<disc>\d)[-.](?<dt>\d{2})|(?<n>\d{1,3}))(?![\p{L}\p{N}])'

    $cands = foreach ($m in [regex]::Matches($base, $pattern)) {
        $value = if ($m.Groups['disc'].Success) {
            [int]$m.Groups['disc'].Value * 100 + [int]$m.Groups['dt'].Value
        }
        else {
            [int]$m.Groups['n'].Value
        }
        if ($m.Groups['disc'].Success -and [int]$m.Groups['dt'].Value -eq 0) { continue }
        if ($value -lt 1) { continue }

        $pre  = $base.Substring(0, $m.Index)
        $post = $base.Substring($m.Index + $m.Length)
        $atStart = $pre.Trim().Length -eq 0
        $atEnd   = $post.Trim().Length -eq 0
        $preStrong  = $atStart -or $pre -match '[-_(\[]\s*$'
        $postStrong = $atEnd -or $post -match '^\s*[-_.)\]]' -or ($atStart -and $post -match '^\s')

        [PSCustomObject]@{
            Value   = $value
            Digits  = if ($m.Groups['disc'].Success) { 3 } else { $m.Groups['n'].Value.Length }
            AtStart = $atStart
            AtEnd   = $atEnd
            Strong  = ($preStrong -and $postStrong)
        }
    }
    $cands = @($cands)
    if ($cands.Count -eq 0) { return $null }

    $steps = @(
        { -not $_.AtEnd }
        { -not $KnownTrack -or $_.Value -in $KnownTrack }
        { $_.Strong }
        { $_.Digits -le 2 }
    )
    foreach ($keep in $steps) {
        $kept = @($cands | Where-Object $keep)
        if ($kept.Count) { $cands = $kept }
    }

    $first = @($cands | Where-Object AtStart)
    if ($first.Count) { return $first[0].Value }
    return $cands[-1].Value
}

function Get-TitleKey {
    <#
        Returns the normalised title keys of a file name, for exact title
        matching that ignores case, punctuation and whitespace: the whole base
        name, its last ' - ' segment, and Get-TrackTitle's form (leading track
        number removed). -Loose also adds the last bare-hyphen segment, for
        lyric names like "Artist-Album-Title". Empty keys are dropped. Used by
        Sync-LyricFiles for its title fallback.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [switch]$Loose
    )

    $base = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    $parts = @($base, @($base -split '[\s_]+-[\s_]+')[-1], (Get-TrackTitle -Name $Name))
    if ($Loose) { $parts += @($base -split '-')[-1] }

    $keys = foreach ($s in $parts) {
        $k = $s.ToLowerInvariant() -replace '[^\p{L}\p{N}]', ''
        if ($k) { $k }
    }
    return [object[]]@($keys | Select-Object -Unique)
}
