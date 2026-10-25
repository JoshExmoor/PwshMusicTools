# Private helpers built on the TagLibSharp library.
# Shared by Get-AudioTags (read tags) and Sync-SongTags (copy tags).

function Import-TagLibSharp {
    <#
        Ensures TagLibSharp is loaded. On first use it downloads the TagLibSharp
        NuGet package, extracts the managed DLL, and caches it under
        $env:LOCALAPPDATA\TagLibSharp. Later calls load the cached DLL and do not
        touch the network.
    #>
    if ('TagLib.File' -as [type]) { return }

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

function Copy-AudioFileTag {
    <#
        Copies the tags from one audio file onto another with TagLibSharp and
        saves the target. Works across formats (e.g. FLAC Vorbis comments onto MP3
        ID3v2). Requires Import-TagLibSharp to have run first.

        TagLib's Tag.CopyTo copies the standard fields (title, artists, album
        artists, album, composers, genres, comment, year, track/disc numbers and
        counts, BPM, key, publisher, ISRC, grouping, conductor, copyright and
        embedded pictures). Lyrics are copied here as well, since CopyTo omits them.

        By default every field is overwritten so the target matches the reference,
        including fields that are empty on the reference. -FillMissingOnly copies a
        field only when it is empty on the target. -ExcludePictures keeps the
        target's own embedded artwork.
    #>
    param(
        [Parameter(Mandatory)][string] $ReferencePath,
        [Parameter(Mandatory)][string] $TargetPath,
        [switch] $FillMissingOnly,
        [switch] $ExcludePictures
    )

    $overwrite = -not $FillMissingOnly
    $ref = [TagLib.File]::Create($ReferencePath)
    try {
        $tgt = [TagLib.File]::Create($TargetPath)
        try {
            $keptPictures = if ($ExcludePictures) { $tgt.Tag.Pictures } else { $null }

            $ref.Tag.CopyTo($tgt.Tag, $overwrite)

            if ($overwrite -or [string]::IsNullOrWhiteSpace($tgt.Tag.Lyrics)) {
                $tgt.Tag.Lyrics = $ref.Tag.Lyrics
            }
            if ($ExcludePictures) {
                $tgt.Tag.Pictures = $keptPictures
            }

            $tgt.Save()
        }
        finally { $tgt.Dispose() }
    }
    finally { $ref.Dispose() }
}
