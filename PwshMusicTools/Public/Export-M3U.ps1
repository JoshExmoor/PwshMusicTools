function Export-M3U {
<#
.SYNOPSIS
    Write playlist entries to an M3U / M3U8 file.

.DESCRIPTION
    Export-M3U writes entries out as either a plain M3U (just paths) or an
    extended M3U (#EXTM3U header with #EXTINF duration/title lines).

    Defaults to UTF-8. Use .m3u8 (UTF-8) by convention for playlists containing
    non-ASCII paths; .m3u is traditionally the local system codepage, but UTF-8
    is the safe modern default.

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

.PARAMETER LineEnding
    The line ending to write between entries: 'CRLF' (Windows, "`r`n"), 'LF'
    (Unix, "`n"), or 'CR' (classic Mac, "`r"). Defaults to 'CRLF'. Use 'LF' when
    writing a playlist for a Linux machine.

.EXAMPLE
    # Plain playlist from a folder of audio files
    Get-ChildItem C:\Music -Filter *.flac | Export-M3U .\album.m3u

.EXAMPLE
    # Round-trip with metadata preserved
    Import-M3U .\in.m3u8 | Export-M3U .\out.m3u8 -Extended -Force

.EXAMPLE
    # Write a playlist for a Linux machine with Unix (LF) line endings
    Import-M3U .\in.m3u | Export-M3U .\out.m3u8 -Extended -Force -LineEnding LF
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object[]] $InputObject,

        [Parameter(Mandatory, Position = 0)]
        [string] $Path,

        [switch] $Extended,

        [string] $Encoding = 'UTF8',

        [switch] $Force,

        [ValidateSet('CRLF', 'LF', 'CR')]
        [string] $LineEnding = 'CRLF'
    )

    begin {
        if ((Test-Path -LiteralPath $Path) -and -not $Force) {
            throw "Destination already exists (use -Force to overwrite): $Path"
        }

        # Collect lines and join them in `end` with the requested newline, so the
        # line ending is controlled precisely rather than inherited from the OS.
        $lines = [System.Collections.Generic.List[string]]::new()
        if ($Extended) { $lines.Add('#EXTM3U') }
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
                $lines.Add("#EXTINF:$duration,$title")
            }
            $lines.Add($entryPath)
            $script:__m3uCount++
        }
    }

    end {
        $parent = Split-Path $Path -Parent
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }

        $newline = switch ($LineEnding) {
            'LF'   { "`n" }
            'CR'   { "`r" }
            default { "`r`n" }   # CRLF
        }

        # Join with the chosen newline and write with -NoNewline so neither the
        # StringBuilder nor Set-Content can substitute the OS line ending. No
        # trailing newline is added, matching the previous behavior.
        $text = ($lines -join $newline)
        Set-Content -LiteralPath $Path -Value $text -Encoding $Encoding -NoNewline
        Write-Verbose "Wrote $script:__m3uCount entr$(if ($script:__m3uCount -eq 1){'y'}else{'ies'}) to $Path"
    }
}
