function Update-M3UPath {
<#
.SYNOPSIS
    Repair a playlist whose files were re-encoded to a different format by
    swapping the extension of missing entries, and write an updated playlist.

.DESCRIPTION
    Works like Test-M3UPath: every entry in the playlist is checked for existence
    on disk. When an entry is missing, Update-M3UPath checks whether a file with
    the same base name but the -Extension extension exists instead (for example
    'song.mp3' replaced by 'song.opus'). If it does, the entry is rewritten to
    point at the new file.

    The updated playlist is written to '<original name>_updated<original ext>'
    next to the source playlist, or to -Output if given. The source playlist is
    never modified.

    The output stays faithful to the source:
      * each entry keeps its original form (relative stays relative, absolute
        stays absolute); only the extension changes;
      * an extended playlist (#EXTM3U) keeps its #EXTINF duration and title;
      * the source's line endings (CRLF or LF) are preserved;
      * entries that exist, and missing entries with no replacement, are written
        through unchanged.

    One result object is emitted per entry, and a summary line is written to the
    host.

.PARAMETER Path
    Path to the .m3u / .m3u8 playlist to update. Accepts pipeline input.

.PARAMETER Extension
    The extension to try for missing entries, with or without the leading dot
    (e.g. 'opus' or '.opus'). It is lowercased when written.

.PARAMETER Output
    Path/filename for the updated playlist. Defaults to
    '<original name>_updated<original ext>' in the source playlist's directory.

.PARAMETER Encoding
    Text encoding used to read and write the playlist. Defaults to UTF8.

.PARAMETER NoResolve
    Test each entry's path exactly as written instead of resolving a relative
    entry against the playlist's directory.

.PARAMETER Force
    Overwrite the output file if it already exists.

.PARAMETER Quiet
    Suppress the host summary line. Result objects are still returned.

.OUTPUTS
    One PSCustomObject per entry with:
      Path     - the entry as written in the source playlist
      NewPath  - the entry as written to the updated playlist
      Status   - 'Found' (exists as-is), 'Updated' (replaced by the -Extension
                 file), or 'Missing' (neither exists; written unchanged)
      Line     - 1-based entry index within the playlist
      Duration - #EXTINF duration in seconds (-1 if unknown)
      Title    - #EXTINF title, or $null

.EXAMPLE
    Update-M3UPath .\playlist.m3u8 -Extension opus

    Points any missing .mp3/.flac/etc. entries at same-named .opus files and
    writes .\playlist_updated.m3u8.

.EXAMPLE
    Update-M3UPath .\playlist.m3u8 -Extension opus -Output D:\Playlists\opus.m3u8 -Force

    Writes the updated playlist to a specific path, overwriting it if present.

.EXAMPLE
    Update-M3UPath .\playlist.m3u8 -Extension opus -Quiet | Where-Object Status -eq 'Missing'

    Lists the entries that could not be found in either format.
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [string] $Path,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Extension,

        [string] $Output,

        [string] $Encoding = 'UTF8',

        [switch] $NoResolve,

        [switch] $Force,

        [switch] $Quiet
    )

    process {
        $resolved = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
        if (-not $resolved) {
            Write-Error "Playlist not found: $Path"
            return
        }
        $playlistPath = $resolved.ProviderPath
        $playlistDir  = Split-Path $playlistPath -Parent

        $newExt = '.' + $Extension.Trim().TrimStart('.').ToLowerInvariant()
        if ($newExt -eq '.') {
            Write-Error "-Extension must not be empty."
            return
        }

        # Default output: '<name>_updated<ext>' next to the source playlist.
        if ([string]::IsNullOrWhiteSpace($Output)) {
            $base   = [IO.Path]::GetFileNameWithoutExtension($playlistPath)
            $ext    = [IO.Path]::GetExtension($playlistPath)
            $Output = Join-Path $playlistDir ("{0}_updated{1}" -f $base, $ext)
        }

        # Match the source's format: extended or plain, CRLF or LF.
        $raw        = Get-Content -LiteralPath $playlistPath -Raw -Encoding $Encoding
        if ($null -eq $raw) { $raw = '' }
        $isExtended = ($raw.TrimStart([char]0xFEFF) -split "`r?`n" |
                       Where-Object { $_.Trim() } | Select-Object -First 1) -match '^\s*#EXTM3U'
        $lineEnding = if ($raw -match "`r`n") { 'CRLF' } else { 'LF' }

        # Import the entries as written (no -Resolve), so relative entries can be
        # written back relative. Resolve them here only to test existence.
        $entries = @(Import-M3U -Path $playlistPath -Encoding $Encoding)

        $resolveForTest = {
            param([string] $p)
            if ($NoResolve -or [IO.Path]::IsPathRooted($p)) { return $p }
            return (Join-Path $playlistDir $p)
        }

        $results = foreach ($entry in $entries) {
            $original = $entry.Path
            $status   = 'Found'
            $newPath  = $original

            if (-not (Test-Path -LiteralPath (& $resolveForTest $original) -PathType Leaf)) {
                $candidate = [IO.Path]::ChangeExtension($original, $newExt)
                if ($candidate -ne $original -and
                    (Test-Path -LiteralPath (& $resolveForTest $candidate) -PathType Leaf)) {
                    $status  = 'Updated'
                    $newPath = $candidate
                }
                else {
                    $status = 'Missing'
                }
            }

            [PSCustomObject][ordered]@{
                Path     = $original
                NewPath  = $newPath
                Status   = $status
                Line     = $entry.Line
                Duration = $entry.Duration
                Title    = $entry.Title
            }
        }
        $results = @($results)

        # Write the updated playlist (source playlist is never touched).
        $written = $false
        if ($PSCmdlet.ShouldProcess($Output, "Write updated playlist")) {
            $exportParams = @{
                Path       = $Output
                Encoding   = $Encoding
                LineEnding = $lineEnding
                Force      = $Force
                Extended   = $isExtended
            }
            try {
                $results |
                    ForEach-Object { [PSCustomObject]@{ Path = $_.NewPath; Duration = $_.Duration; Title = $_.Title } } |
                    Export-M3U @exportParams -ErrorAction Stop
                $written = $true
            }
            catch {
                Write-Error "Could not write '$Output': $($_.Exception.Message)"
            }
        }

        $results

        if (-not $Quiet) {
            $found   = @($results | Where-Object Status -eq 'Found').Count
            $updated = @($results | Where-Object Status -eq 'Updated').Count
            $missing = @($results | Where-Object Status -eq 'Missing').Count
            $color   = if ($missing -gt 0) { 'Yellow' } else { 'Green' }
            $target  = if ($written) { "wrote '$Output'" } else { "did not write '$Output'" }
            Write-Host ("{0} of {1} entr{2} OK ({3} found, {4} updated to {5}), {6} missing; {7}" -f `
                ($found + $updated), $results.Count, $(if ($results.Count -eq 1) { 'y' } else { 'ies' }),
                $found, $updated, $newExt, $missing, $target) -ForegroundColor $color
        }
    }
}
