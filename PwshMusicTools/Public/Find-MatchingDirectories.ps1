<#
.SYNOPSIS
    Finds sub-directories whose relative paths exist under both of two root
    directories, by exact match or (optionally) fuzzy match.

.DESCRIPTION
    Enumerates sub-directories under each of two root paths, down to a configurable
    depth (1 to 3 levels, default 3).

    By default a directory on one side matches a directory on the other side when
    their relative paths from their respective roots are identical. For example,
    with -Depth 2, a left-side 'band\album' matches a right-side 'band\album'. It
    does NOT match 'band\live\album' (a different relative path), nor 'band\live'
    (a different depth).

    With -Fuzzy, directories are paired when their PARENT path (every segment
    except the last) is identical and their LEAF (last) segment is similar enough.
    So 'band\live\album' matches 'band\live\album (live)' (same parent 'band\live',
    similar leaf) but not 'band\studio\album' (different parent). Leaf similarity
    is a normalized Levenshtein score in the range 0..1, scored both on the raw
    leaf and on a copy with a trailing qualifier like " (live)" or "[remastered]"
    stripped (whichever scores higher). A pair is kept only if its score is at
    least -Threshold. Pairing is greedy best-first: the
    highest-scoring pairs are taken first and each directory on each side is used
    at most once (one-to-one).

    Matching is case-insensitive (consistent with Windows file systems) and the
    directory separator is normalized, so the two roots may use different styles.

.PARAMETER FirstDir
    The first root directory to search.

.PARAMETER SecondDir
    The second root directory to search.

.PARAMETER Depth
    How many levels of sub-directories to enumerate under each root, from 1 to 3.
    Defaults to 3.

.PARAMETER Fuzzy
    Match by path similarity instead of requiring identical relative paths.

.PARAMETER Threshold
    Minimum similarity score (0.0 to 1.0) for a fuzzy pair to be kept. Only used
    with -Fuzzy. Defaults to 0.8. Higher is stricter.

.OUTPUTS
    An array of PSCustomObjects, one per matched pair, each with:
      First      - full path of the matching directory under FirstDir
      Second     - full path of the matching directory under SecondDir
      MatchScore - similarity score (always 1.0 for exact matches)
      Depth      - zero-based depth of the match below the root, so a direct
                   child of the root (e.g. '<root>\artist') is 0, a grandchild
                   ('<root>\artist\album') is 1, and so on.

.EXAMPLE
    $matches = Find-MatchingDirectories -FirstDir 'D:\FLAC' -SecondDir 'D:\MP3' -Depth 2

    foreach ($m in $matches) {
        '{0}  <->  {1}' -f $m.First, $m.Second
    }

.EXAMPLE
    Find-MatchingDirectories 'D:\FLAC' 'D:\MP3' -Fuzzy -Threshold 0.75 |
        Sort-Object MatchScore |
        Format-Table First, Second, MatchScore

    Pairs directories whose leaves are at least 75% similar (e.g.
    'band\live\album' pairs with 'band\live\album (live)') and lists the
    lowest-scoring, most-uncertain matches first for review.
#>
function Find-MatchingDirectories {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$FirstDir,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$SecondDir,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 3)]
        [int]$Depth = 3,

        [Parameter(Mandatory = $false)]
        [switch]$Fuzzy,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0.0, 1.0)]
        [double]$Threshold = 0.8
    )

    if (-not (Test-Path -LiteralPath $FirstDir -PathType Container)) {
        throw "First directory '$FirstDir' is not a valid directory."
    }
    if (-not (Test-Path -LiteralPath $SecondDir -PathType Container)) {
        throw "Second directory '$SecondDir' is not a valid directory."
    }

    # Resolve to full, canonical paths so relative-path extraction is reliable.
    $firstRoot = (Resolve-Path -LiteralPath $FirstDir).Path
    $secondRoot = (Resolve-Path -LiteralPath $SecondDir).Path

    # --- Helpers -----------------------------------------------------------

    function Get-Entries {
        <#
            Returns one record per sub-directory under $Root: its normalized
            relative key, segment count (depth), the parent path (all segments
            except the last), the leaf (last) segment, and the full path.
        #>
        param([string]$Root, [int]$MaxDepth)

        # -Depth is 0-based for the levels BELOW the root, so a $MaxDepth of 1
        # (one level under the root) uses -Depth 0.
        $dirs = Get-ChildItem -LiteralPath $Root -Directory -Recurse -Depth ($MaxDepth - 1)

        foreach ($dir in $dirs) {
            $relative = $dir.FullName.Substring($Root.Length).Trim('\', '/')
            $key = ($relative -replace '[\\/]+', '\').ToLowerInvariant()
            $segments = $key -split '\\'
            $leaf = $segments[-1]
            $parent = if ($segments.Count -gt 1) { ($segments[0..($segments.Count - 2)] -join '\') } else { '' }
            [PSCustomObject]@{
                Key      = $key
                Segments = $segments.Count
                Parent   = $parent
                Leaf     = $leaf
                FullPath = $dir.FullName
            }
        }
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
        if ($lenA -eq 0 -or $lenB -eq 0) {
            return 0.0
        }

        # Two-row dynamic programming Levenshtein (O(lenA*lenB) time, O(lenB) space).
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

    function Get-NormalizedLeaf {
        <#
            Strips a trailing qualifier such as " (live)", " [remastered]" or
            " {2019}" and collapses whitespace. This lets a base name match a
            qualified variant: "album" and "album (live)" both normalize to
            "album". Only a trailing bracketed group is removed, so an internal
            parenthetical (rare in folder names) is left alone.
        #>
        param([string]$Leaf)
        $s = $Leaf -replace '\s*[\(\[\{][^\(\[\{]*[\)\]\}]\s*$', ''
        return ($s -replace '\s+', ' ').Trim()
    }

    function Get-LeafScore {
        <#
            Scores a pair of leaf names on two signals and returns both so the
            caller can rank honestly:

              Score          - raw normalized Levenshtein similarity of the leaves
                               AS WRITTEN. This is what is reported as MatchScore,
                               so a pair whose names differ never claims 1.0.
              QualifierScore - similarity after stripping a trailing qualifier
                               (e.g. " [2026 Remaster]", " (live)") from each leaf.
                               Lets a base name pair with a qualified variant even
                               though the raw names differ.
              Candidate      - the better of the two, used only to decide whether a
                               pair clears -Threshold at all.
              QualifierOnly  - $true when the pair matches via qualifier stripping
                               but is NOT a raw exact match; used to rank a genuine
                               exact match ahead of a qualifier-only one.
        #>
        param([string]$A, [string]$B)
        $raw        = Get-Similarity -A $A -B $B
        $qualifier  = Get-Similarity -A (Get-NormalizedLeaf $A) -B (Get-NormalizedLeaf $B)
        $candidate  = if ($qualifier -gt $raw) { $qualifier } else { $raw }
        [PSCustomObject]@{
            Score         = $raw
            QualifierScore = $qualifier
            Candidate     = $candidate
            QualifierOnly = ($raw -lt 1.0 -and $qualifier -gt $raw)
        }
    }

    $firstEntries = @(Get-Entries -Root $firstRoot -MaxDepth $Depth)
    $secondEntries = @(Get-Entries -Root $secondRoot -MaxDepth $Depth)

    $result = [System.Collections.Generic.List[object]]::new()

    if (-not $Fuzzy) {
        # Exact: index the second side by key and intersect.
        $secondByKey = @{}
        foreach ($e in $secondEntries) {
            if (-not $secondByKey.ContainsKey($e.Key)) { $secondByKey[$e.Key] = $e }
        }
        foreach ($e in $firstEntries) {
            if ($secondByKey.ContainsKey($e.Key)) {
                $result.Add([PSCustomObject]@{
                        First      = $e.FullPath
                        Second     = $secondByKey[$e.Key].FullPath
                        MatchScore = 1.0
                        Depth      = $e.Segments - 1
                    })
            }
        }
        # Return a typed [object[]]. Casting (rather than a unary-comma wrapper)
        # keeps a 0- or 1-element result a well-formed array for @() and indexing
        # callers, without the comma's side effect of re-nesting under @(...).
        return [object[]]$result.ToArray()
    }

    # Fuzzy: for a pair to be a candidate, the PARENT path (everything above the
    # leaf) must match exactly, and only the LEAF (last) segment is scored for
    # similarity. This keeps fuzziness where it belongs - 'band\live\album' pairs
    # with 'band\live\album (live)' but never with 'band\studio\album'. Comparing
    # only same-depth entries falls out naturally from the exact-parent rule.
    $candidates = foreach ($f in $firstEntries) {
        foreach ($s in $secondEntries) {
            if ($f.Segments -ne $s.Segments) { continue }
            if ($f.Parent -ne $s.Parent) { continue }
            $leaf = Get-LeafScore -A $f.Leaf -B $s.Leaf
            # A pair qualifies if EITHER the raw or the qualifier-stripped score
            # clears the threshold, but the reported Score is always the raw one.
            if ($leaf.Candidate -ge $Threshold) {
                [PSCustomObject]@{
                    First         = $f
                    Second        = $s
                    Score         = $leaf.Score
                    QualifierOnly = $leaf.QualifierOnly
                    ExactKey      = ($f.Key -eq $s.Key)
                }
            }
        }
    }

    # Rank best-first so the greedy one-to-one picker takes the strongest pairs
    # first. Order of preference:
    #   1. a genuine exact match (raw Score 1.0) over a qualifier-only match, so
    #      "The Album"<->"The Album" always beats "The Album"<->"The Album [Remaster]";
    #   2. higher raw Score;
    #   3. exact relative-key match (tie-break);
    #   4. key, for deterministic output.
    $ordered = $candidates | Sort-Object `
        @{ Expression = { -not $_.QualifierOnly }; Descending = $true }, `
        @{ Expression = 'Score'; Descending = $true }, `
        @{ Expression = 'ExactKey'; Descending = $true }, `
        @{ Expression = { $_.First.Key } }

    $usedFirst = @{}
    $usedSecond = @{}
    foreach ($c in $ordered) {
        if ($usedFirst.ContainsKey($c.First.Key)) { continue }
        if ($usedSecond.ContainsKey($c.Second.FullPath)) { continue }

        $result.Add([PSCustomObject]@{
                First      = $c.First.FullPath
                Second     = $c.Second.FullPath
                MatchScore = [Math]::Round($c.Score, 4)
                Depth      = $c.First.Segments - 1
            })
        $usedFirst[$c.First.Key] = $true
        $usedSecond[$c.Second.FullPath] = $true
    }

    # Return a typed [object[]]. Casting (rather than a unary-comma wrapper)
    # keeps a 0- or 1-element result a well-formed array for @() and indexing
    # callers, without the comma's side effect of re-nesting under @(...).
    return [object[]]$result.ToArray()
}
