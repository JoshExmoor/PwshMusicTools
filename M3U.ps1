<#
.SYNOPSIS
    Import and export M3U / M3U8 playlist files in PowerShell.

.DESCRIPTION
    Import-M3U parses a playlist file and returns one object per entry, with
    the track Path plus any #EXTINF metadata (Duration, Title) found in
    extended M3U files. Blank lines and comments are skipped.

    Export-M3U writes entries back out as either a plain M3U (just paths) or
    an extended M3U (#EXTM3U header with #EXTINF duration/title lines).

    Both functions default to UTF-8. Use .m3u8 (UTF-8) by convention for
    playlists containing non-ASCII paths; .m3u is traditionally the local
    system codepage, but UTF-8 is the safe modern default.
#>

function Import-M3U {
<#
.SYNOPSIS
    Read an M3U / M3U8 playlist and return an object per entry.

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


function Export-M3U {
<#
.SYNOPSIS
    Write playlist entries to an M3U / M3U8 file.

.PARAMETER InputObject
    Entries to write. Accepts either plain strings (file paths) or objects
    with a Path property (and optionally Duration / Title), such as those
    produced by Import-M3U. Accepts pipeline input.

.PARAMETER Path
    Destination .m3u / .m3u8 file.

.PARAMETER Extended
    Write an extended M3U: emit the #EXTM3U header and a #EXTINF line
    (duration + title) before each entry. Without this switch, only the
    bare paths are written (plain M3U).

.PARAMETER Encoding
    Text encoding to write with. Defaults to UTF8.

.PARAMETER Force
    Overwrite the destination if it already exists.

.EXAMPLE
    # Plain playlist from a folder of audio files
    Get-ChildItem C:\Music -Filter *.flac | Export-M3U .\album.m3u

.EXAMPLE
    # Round-trip with metadata preserved
    Import-M3U .\in.m3u8 | Export-M3U .\out.m3u8 -Extended -Force
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object[]] $InputObject,

        [Parameter(Mandatory, Position = 0)]
        [string] $Path,

        [switch] $Extended,

        [string] $Encoding = 'UTF8',

        [switch] $Force
    )

    begin {
        if ((Test-Path -LiteralPath $Path) -and -not $Force) {
            throw "Destination already exists (use -Force to overwrite): $Path"
        }

        $sb = [System.Text.StringBuilder]::new()
        if ($Extended) { [void]$sb.AppendLine('#EXTM3U') }
        $script:__m3uCount = 0
    }

    process {
        foreach ($item in $InputObject) {
            if ($null -eq $item) { continue }

            # Accept bare strings/FileInfo or objects with a Path property.
            $entryPath = $null
            $duration  = -1
            $title     = $null

            if ($item -is [string]) {
                $entryPath = $item
            }
            elseif ($item.PSObject.Properties['Path']) {
                $entryPath = [string]$item.Path
                if ($item.PSObject.Properties['Duration'] -and $null -ne $item.Duration) {
                    $duration = [int]$item.Duration
                }
                if ($item.PSObject.Properties['Title']) { $title = $item.Title }
            }
            elseif ($item.PSObject.Properties['FullName']) {
                $entryPath = [string]$item.FullName   # Get-ChildItem FileInfo
            }
            else {
                $entryPath = [string]$item
            }

            if ([string]::IsNullOrWhiteSpace($entryPath)) { continue }

            if ($Extended) {
                if (-not $title) { $title = [IO.Path]::GetFileNameWithoutExtension($entryPath) }
                [void]$sb.AppendLine("#EXTINF:$duration,$title")
            }
            [void]$sb.AppendLine($entryPath)
            $script:__m3uCount++
        }
    }

    end {
        $parent = Split-Path $Path -Parent
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }

        # Write without a trailing blank line; honor the requested encoding.
        $text = $sb.ToString().TrimEnd("`r", "`n")
        Set-Content -LiteralPath $Path -Value $text -Encoding $Encoding
        Write-Verbose "Wrote $script:__m3uCount entr$(if ($script:__m3uCount -eq 1){'y'}else{'ies'}) to $Path"
    }
}
