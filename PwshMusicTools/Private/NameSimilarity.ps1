# Private: fuzzy comparison of folder names, used by Invoke-MusicIngest.
# Builds on Get-StringSimilarity (normalised Levenshtein) in TrackMatching.ps1.

function Get-NormalizedName {
    <#
        Lower-cases a name, removes everything that is not a letter, digit or
        whitespace, collapses whitespace to a single space and trims it. Digits
        are kept so 'CD1' and 'CD2' stay different.
    #>
    param([string]$Name)

    if ([string]::IsNullOrEmpty($Name)) { return '' }
    $n = $Name.ToLowerInvariant() -replace '[^\p{L}\p{N}\s]', ''
    return ($n -replace '\s+', ' ').Trim()
}

function Get-NameSimilarity {
    <#
        Similarity in [0,1] between two names after Get-NormalizedName. Names
        that both normalise to nothing (e.g. '...' and '!!!') score 1.0 only
        when the raw strings are equal ignoring case.
    #>
    param([string]$A, [string]$B)

    $na = Get-NormalizedName -Name $A
    $nb = Get-NormalizedName -Name $B
    if ($na.Length -eq 0 -and $nb.Length -eq 0) {
        if ([string]::Equals($A, $B, [StringComparison]::OrdinalIgnoreCase)) { return 1.0 }
        return 0.0
    }
    return Get-StringSimilarity -A $na -B $nb
}
