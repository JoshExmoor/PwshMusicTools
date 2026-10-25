# Private helpers for pairing audio files across two folders by track number.
# Shared by Sync-SongFiles (rename to match) and Sync-SongTags (copy tags).

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
