function Convert-M3UPath {
<#
.SYNOPSIS
    Rebase playlist entry paths from one known base directory to another,
    converting the path separator style for the target platform.

.DESCRIPTION
    Takes playlist entries (strings, or the objects produced by Import-M3U) and
    rewrites each entry's path so that a known base prefix is replaced with a new
    base, and the directory separators are flipped to the target platform's style.
    The structure below the base is preserved:

        'C:\mp3\album\song.mp3'  --(-From 'C:\mp3' -To '/data/music' -ToStyle Unix)-->
        '/data/music/album/song.mp3'

    This is the piece that lets a playlist written on one machine be used on
    another with the same relative layout under a different root. It is designed
    to sit between Import-M3U and Export-M3U in a pipeline, and it passes the
    Duration / Title metadata through untouched so an extended playlist survives
    the round-trip:

        Import-M3U .\windows.m3u |
            Convert-M3UPath -From 'C:\mp3' -To '/data/music' -ToStyle Unix |
            Export-M3U .\linux.m3u8 -Extended -Force -LineEnding LF

    Base matching is case-insensitive, which is correct for Windows source paths
    ('C:\MP3' and 'c:\mp3' are the same folder). An entry whose path does not
    start with -From is passed through with only its separators converted, so
    unrelated or already-rebased entries are left in place rather than dropped.

.PARAMETER InputObject
    Entries to convert. Accepts plain strings (file paths) or objects with a Path
    property (and optionally Duration / Title), such as those from Import-M3U.
    Accepts pipeline input. Metadata properties are preserved on the output.

.PARAMETER From
    The known base prefix to strip from the start of each matching path, e.g.
    'C:\mp3'. A trailing separator is optional and normalized away.

.PARAMETER To
    The new base prefix to prepend in place of -From, e.g. '/data/music'. A
    trailing separator is optional and normalized away.

.PARAMETER ToStyle
    The target path separator style for the output: 'Unix' (forward slashes,
    the default) or 'Windows' (backslashes).

.OUTPUTS
    For string input, the converted path string. For object input, a
    PSCustomObject with the same shape as the input (Path rewritten; Duration,
    Title, and Line preserved when present).

.EXAMPLE
    'C:\mp3\album\song.mp3' | Convert-M3UPath -From 'C:\mp3' -To '/data/music' -ToStyle Unix

    Returns '/data/music/album/song.mp3'.

.EXAMPLE
    Import-M3U .\windows.m3u |
        Convert-M3UPath -From 'C:\mp3' -To '/data/music' -ToStyle Unix |
        Export-M3U .\linux.m3u8 -Extended -Force -LineEnding LF

    Rebases a Windows playlist for a Linux machine, keeping the #EXTINF metadata
    and writing LF line endings.

.EXAMPLE
    Import-M3U .\linux.m3u8 |
        Convert-M3UPath -From '/data/music' -To 'C:\mp3' -ToStyle Windows |
        Export-M3U .\windows.m3u -Extended -Force

    The reverse direction: rebase a Linux playlist back onto a Windows root.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object[]] $InputObject,

        [Parameter(Mandatory)]
        [string] $From,

        [Parameter(Mandatory)]
        [string] $To,

        [ValidateSet('Unix', 'Windows')]
        [string] $ToStyle = 'Unix'
    )

    begin {
        $targetSep = if ($ToStyle -eq 'Windows') { '\' } else { '/' }

        # Normalize the bases: strip any trailing separator (of either style) so
        # the join never produces a doubled or missing separator.
        $fromBase = $From.TrimEnd('\', '/')
        $toBase   = $To.TrimEnd('\', '/')

        # Convert a path's separators to the target style.
        $toTargetSep = {
            param([string] $p)
            $p -replace '[\\/]+', $targetSep
        }
    }

    process {
        foreach ($item in $InputObject) {
            if ($null -eq $item) { continue }

            # Pull the path out, remembering whether we had a rich object so the
            # metadata can be reattached to the output.
            $entryPath = $null
            $isObject  = $false
            $duration  = $null
            $title     = $null
            $line      = $null

            if ($item -is [string]) {
                $entryPath = $item
            }
            elseif ($item.PSObject.Properties['Path']) {
                $isObject  = $true
                $entryPath = [string]$item.Path
                if ($item.PSObject.Properties['Duration']) { $duration = $item.Duration }
                if ($item.PSObject.Properties['Title'])    { $title    = $item.Title }
                if ($item.PSObject.Properties['Line'])     { $line     = $item.Line }
            }
            elseif ($item.PSObject.Properties['FullName']) {
                $entryPath = [string]$item.FullName
            }
            else {
                $entryPath = [string]$item
            }

            if ([string]::IsNullOrWhiteSpace($entryPath)) { continue }

            # Does the entry sit under the known -From base? Compare on a
            # separator-normalized copy so 'C:\mp3' matches 'C:/mp3', and do it
            # case-insensitively (Windows source paths are case-insensitive).
            $normalizedEntry = $entryPath -replace '[\\/]+', '/'
            $normalizedFrom  = $fromBase  -replace '[\\/]+', '/'

            $isUnderBase = $normalizedEntry.Equals($normalizedFrom, [StringComparison]::OrdinalIgnoreCase) -or
                           $normalizedEntry.StartsWith($normalizedFrom + '/', [StringComparison]::OrdinalIgnoreCase)

            if ($isUnderBase) {
                # Take the remainder after the base, then re-root it under -To.
                $remainder = $normalizedEntry.Substring($normalizedFrom.Length).TrimStart('/')
                $rebased   = if ($remainder) { "$toBase/$remainder" } else { $toBase }
                $newPath   = & $toTargetSep $rebased
            }
            else {
                # Not under the base: leave the path in place, only fixing separators.
                $newPath = & $toTargetSep $entryPath
            }

            if ($isObject) {
                $out = [ordered]@{ Path = $newPath }
                if ($null -ne $duration) { $out.Duration = $duration }
                if ($null -ne $title)    { $out.Title    = $title }
                if ($null -ne $line)     { $out.Line     = $line }
                [PSCustomObject]$out
            }
            else {
                $newPath
            }
        }
    }
}
