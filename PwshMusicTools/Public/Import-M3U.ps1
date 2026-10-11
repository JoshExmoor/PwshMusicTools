function Import-M3U {
<#
.SYNOPSIS
    Read an M3U / M3U8 playlist and return an object per entry.

.DESCRIPTION
    Import-M3U parses a playlist file and returns one object per entry, with
    the track Path plus any #EXTINF metadata (Duration, Title) found in
    extended M3U files. Blank lines and comments are skipped.

    Defaults to UTF-8. Use .m3u8 (UTF-8) by convention for playlists containing
    non-ASCII paths; .m3u is traditionally the local system codepage, but UTF-8
    is the safe modern default.

.PARAMETER Path
    Path to the .m3u / .m3u8 file to read.

.PARAMETER Encoding
    Text encoding to read with. Defaults to UTF8.

.PARAMETER Resolve
    If set, resolves each entry's path to a full path relative to the
    playlist's own directory (M3U paths are conventionally relative to
    the playlist location). Non-existent paths are returned unchanged.

.OUTPUTS
    PSCustomObject with: Path, Duration (int seconds, -1 if unknown),
    Title (string or $null), and Line (1-based entry index).

.EXAMPLE
    Import-M3U .\playlist.m3u8

.EXAMPLE
    Import-M3U .\playlist.m3u -Resolve | Get-AudioTags
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [string] $Path,

        [string] $Encoding = 'UTF8',

        [switch] $Resolve
    )

    process {
        $resolved = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
        if (-not $resolved) {
            Write-Error "Playlist not found: $Path"
            return
        }
        $full        = $resolved.ProviderPath
        $playlistDir = Split-Path $full -Parent

        $lines = Get-Content -LiteralPath $full -Encoding $Encoding

        $index       = 0
        $pendingDur  = -1
        $pendingName = $null

        foreach ($raw in $lines) {
            $line = $raw.Trim()

            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            if ($line.StartsWith('#')) {
                # Parse #EXTINF:<seconds>,<title>  (title may be empty)
                if ($line -match '^#EXTINF:\s*(-?\d+(?:\.\d+)?)\s*,(.*)$') {
                    $pendingDur  = [int][math]::Round([double]$matches[1])
                    $pendingName = $matches[2].Trim()
                    if ([string]::IsNullOrEmpty($pendingName)) { $pendingName = $null }
                }
                # All other #-directives (#EXTM3U, #PLAYLIST, comments) are ignored.
                continue
            }

            $entryPath = $line
            if ($Resolve -and $entryPath -notmatch '^[a-zA-Z]:[\\/]|^\\\\|^[a-zA-Z][a-zA-Z0-9+.\-]*://') {
                # Relative local path -> make absolute against the playlist dir.
                $candidate = Join-Path $playlistDir $entryPath
                try { $entryPath = (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).ProviderPath }
                catch { $entryPath = $candidate }
            }

            $index++
            [PSCustomObject][ordered]@{
                Path     = $entryPath
                Duration = $pendingDur
                Title    = $pendingName
                Line     = $index
            }

            # Reset pending EXTINF for the next entry.
            $pendingDur  = -1
            $pendingName = $null
        }
    }
}
