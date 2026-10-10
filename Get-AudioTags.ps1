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
        # ---- Ensure TagLibSharp is loaded (download + cache on first use) ----
        if (-not ('TagLib.File' -as [type])) {
            $cacheDir = Join-Path $env:LOCALAPPDATA 'TagLibSharp'
            $dllPath  = Join-Path $cacheDir 'TagLibSharp.dll'

            if (-not (Test-Path -LiteralPath $dllPath)) {
                Write-Verbose 'TagLibSharp not cached - downloading from NuGet...'
                New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null

                $nupkg = Join-Path $cacheDir 'taglibsharp.nupkg'
                $url   = 'https://www.nuget.org/api/v2/package/TagLibSharp'

                # TLS 1.2 for older Windows PowerShell defaults
                try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

                Invoke-WebRequest -Uri $url -OutFile $nupkg -UseBasicParsing

                # A .nupkg is a zip archive; extract and locate the managed DLL.
                $extractDir = Join-Path $cacheDir 'extracted'
                if (Test-Path -LiteralPath $extractDir) { Remove-Item -LiteralPath $extractDir -Recurse -Force }
                Expand-Archive -LiteralPath $nupkg -DestinationPath $extractDir -Force

                # Prefer the most compatible build: netstandard2.0 > netstandard2.1 > net* fallback.
                $candidate =
                    Get-ChildItem -Path $extractDir -Recurse -Filter 'TagLibSharp.dll' |
                    Sort-Object {
                        switch -Wildcard ($_.Directory.Name) {
                            'netstandard2.0' { 0 }
                            'netstandard2.1' { 1 }
                            'netstandard*'   { 2 }
                            default          { 3 }
                        }
                    } |
                    Select-Object -First 1

                if (-not $candidate) {
                    throw 'Could not locate TagLibSharp.dll inside the downloaded NuGet package.'
                }

                Copy-Item -LiteralPath $candidate.FullName -Destination $dllPath -Force
                Remove-Item -LiteralPath $nupkg, $extractDir -Recurse -Force -ErrorAction SilentlyContinue
            }

            Add-Type -Path $dllPath
        }
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
