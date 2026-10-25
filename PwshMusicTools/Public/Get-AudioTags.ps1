<#
.SYNOPSIS
    Reads and returns the metadata tags of common audio files
    (FLAC, MP3, M4A, OGG, Opus, and more) using the TagLib# library.

.DESCRIPTION
    Get-AudioTags uses the cross-format TagLibSharp library to read tags
    uniformly across formats, instead of relying on Windows Shell codecs
    (which do not reliably support FLAC/OGG/Opus).

    On first run it downloads the TagLibSharp NuGet package, extracts the
    managed DLL, and caches it under $env:LOCALAPPDATA\TagLibSharp. Later
    runs load the cached DLL and do not touch the network.

.PARAMETER Path
    One or more paths to audio files. Accepts pipeline input, so you can
    pipe Get-ChildItem straight into it.

.PARAMETER Raw
    Return the raw TagLib.File object instead of a flattened summary,
    giving access to every property TagLib# exposes.

.EXAMPLE
    Get-AudioTags .\song.flac

.EXAMPLE
    Get-ChildItem C:\Music -Recurse -Include *.mp3,*.flac,*.m4a,*.ogg,*.opus |
        Get-AudioTags | Format-Table FileName, Title, Artist, Album, Year

.EXAMPLE
    $t = Get-AudioTags .\track.opus -Raw
    $t.Tag.Pictures.Count     # inspect embedded artwork, etc.

.NOTES
    Requires .NET / PowerShell with internet access on first run only.
    Works in Windows PowerShell 5.1 and PowerShell 7+.
#>
function Get-AudioTags {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [string[]] $Path,

        [switch] $Raw
    )

    begin {
        # Ensure TagLibSharp is loaded (downloaded and cached on first use).
        Import-TagLibSharp
    }

    process {
        foreach ($p in $Path) {
            # Resolve so relative paths and pipeline input both work.
            $resolved = Resolve-Path -LiteralPath $p -ErrorAction SilentlyContinue
            if (-not $resolved) {
                Write-Error "File not found: $p"
                continue
            }
            $full = $resolved.ProviderPath

            try {
                $tagFile = [TagLib.File]::Create($full)
            }
            catch {
                Write-Error "Failed to read tags from '$full': $($_.Exception.Message)"
                continue
            }

            if ($Raw) {
                $tagFile
                continue
            }

            $tag = $tagFile.Tag
            $props = $tagFile.Properties

            [PSCustomObject][ordered]@{
                FileName    = Split-Path $full -Leaf
                Path        = $full
                Title       = $tag.Title
                Artist      = ($tag.Performers -join '; ')
                AlbumArtist = ($tag.AlbumArtists -join '; ')
                Album       = $tag.Album
                Year        = $tag.Year
                Track       = $tag.Track
                TrackCount  = $tag.TrackCount
                Disc        = $tag.Disc
                Genre       = ($tag.Genres -join '; ')
                Comment     = $tag.Comment
                Composers   = ($tag.Composers -join '; ')
                Duration    = $props.Duration
                Bitrate     = $props.AudioBitrate
                SampleRate  = $props.AudioSampleRate
                Channels    = $props.AudioChannels
                Codec       = (($props.Codecs | ForEach-Object { $_.Description }) -join ', ')
                Pictures    = $tag.Pictures.Count
            }

            $tagFile.Dispose()
        }
    }
}
