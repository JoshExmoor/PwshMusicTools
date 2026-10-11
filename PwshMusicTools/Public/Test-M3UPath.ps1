function Test-M3UPath {
<#
.SYNOPSIS
    Test every file path in an M3U / M3U8 playlist and report which ones exist.

.DESCRIPTION
    Reads a playlist with Import-M3U, then checks each entry's path for existence
    on disk. One result object is emitted per entry (good or bad), so the output
    can be filtered, exported, or piped onward. A one-line summary of the overall
    result (e.g. "99 of 100 paths exist") is written to the host.

    By default, relative entries are resolved against the playlist's own
    directory (the M3U convention) before testing. Use -NoResolve to test the
    paths exactly as written.

.PARAMETER Path
    Path to the .m3u / .m3u8 playlist file to test. Accepts pipeline input.

.PARAMETER Encoding
    Text encoding to read the playlist with. Defaults to UTF8.

.PARAMETER NoResolve
    Test each entry's path exactly as written instead of first resolving a
    relative entry against the playlist's directory.

.PARAMETER Quiet
    Suppress the host summary line. The per-entry result objects are still
    returned.

.OUTPUTS
    One PSCustomObject per entry with:
      Path     - the (resolved) path that was tested
      Exists   - [bool] whether a file exists at that path
      Line     - 1-based entry index within the playlist
      Duration - #EXTINF duration in seconds (-1 if unknown)
      Title    - #EXTINF title, or $null

.EXAMPLE
    Test-M3UPath .\playlist.m3u8

    Tests every path and prints a summary like "48 of 50 paths exist".

.EXAMPLE
    Test-M3UPath .\playlist.m3u8 | Where-Object { -not $_.Exists }

    Lists only the missing entries.

.EXAMPLE
    Test-M3UPath .\playlist.m3u8 -Quiet | Export-Csv .\report.csv -NoTypeInformation

    Writes a CSV report without printing the host summary.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [string] $Path,

        [string] $Encoding = 'UTF8',

        [switch] $NoResolve,

        [switch] $Quiet
    )

    process {
        # Let Import-M3U handle parsing, #EXTINF metadata, and (by default)
        # resolving relative entries against the playlist's own directory.
        $importParams = @{ Path = $Path; Encoding = $Encoding }
        if (-not $NoResolve) { $importParams.Resolve = $true }

        $entries = @(Import-M3U @importParams)

        $total  = 0
        $good   = 0
        $results = foreach ($entry in $entries) {
            $exists = Test-Path -LiteralPath $entry.Path -PathType Leaf
            $total++
            if ($exists) { $good++ }

            [PSCustomObject][ordered]@{
                Path     = $entry.Path
                Exists   = [bool]$exists
                Line     = $entry.Line
                Duration = $entry.Duration
                Title    = $entry.Title
            }
        }

        # Emit the per-entry results to the pipeline.
        $results

        if (-not $Quiet) {
            $color = if ($total -eq 0) { 'Yellow' }
                     elseif ($good -eq $total) { 'Green' }
                     else { 'Yellow' }
            Write-Host ("{0} of {1} path{2} exist in '{3}'" -f $good, $total, $(if ($total -eq 1) { '' } else { 's' }), $Path) -ForegroundColor $color
        }
    }
}
