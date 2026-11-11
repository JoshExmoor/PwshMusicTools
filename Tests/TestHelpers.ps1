# Shared helpers for the PwshMusicTools test suite.
#
# Dot-source this from a Pester BeforeAll block:
#     . $PSScriptRoot/TestHelpers.ps1
#     Import-PwshMusicTools
#
# It imports the module under test and exposes helpers for building disposable
# fixture directories of empty files.

function Import-PwshMusicTools {
    # Resolve the module manifest relative to the Tests folder (its parent) and
    # import it fresh so tests always exercise the current source.
    $manifest = Join-Path (Split-Path $PSScriptRoot -Parent) 'PwshMusicTools/PwshMusicTools.psd1'
    Import-Module $manifest -Force -ErrorAction Stop
}

function New-TestDir {
    <#
        Creates a unique empty directory under the system temp folder and returns
        its full path. Pair with Remove-TestDir in an AfterEach/AfterAll.
    #>
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ('pmt-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function New-EmptyFile {
    <#
        Creates an empty file at Dir\Name (creating Dir if needed) and returns the
        file's full path. Content is irrelevant for the pure-logic functions, so
        the files are left 0 bytes.
    #>
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][string]$Name
    )
    if (-not (Test-Path -LiteralPath $Dir)) {
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    }
    $full = Join-Path $Dir $Name
    New-Item -ItemType File -Path $full -Force | Out-Null
    return $full
}

function Remove-TestDir {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function New-TestImageBytes {
    <#
        Builds a minimal, valid image header (no pixel data) of the given format
        and size, for exercising the header-only Get-ImageInfo reader. PadTo pads
        the result with zero bytes up to that length. The returned byte[] is
        unrolled by the pipeline, so callers cast with [byte[]].
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('JPEG', 'JPEGExif', 'JPEGProgressive', 'PNG', 'GIF', 'BMP', 'BMPTopDown',
            'WebPVP8', 'WebPVP8L', 'WebPVP8X', 'TIFFLE', 'TIFFBE')]
        [string]$Format,
        [int]$Width = 600,
        [int]$Height = 600,
        [int]$PadTo = 0
    )

    $list = New-Object 'System.Collections.Generic.List[byte]'
    $add = { param([int[]]$Values) foreach ($v in $Values) { $list.Add([byte]($v -band 0xFF)) } }
    $ascii = { param([string]$Text) foreach ($c in $Text.ToCharArray()) { $list.Add([byte][char]$c) } }
    $be = {
        param([long]$Value, [int]$Size)
        for ($i = $Size - 1; $i -ge 0; $i--) { $list.Add([byte](($Value -shr (8 * $i)) -band 0xFF)) }
    }
    $le = {
        param([long]$Value, [int]$Size)
        for ($i = 0; $i -lt $Size; $i++) { $list.Add([byte](($Value -shr (8 * $i)) -band 0xFF)) }
    }

    switch ($Format) {
        { $_ -in 'JPEG', 'JPEGExif', 'JPEGProgressive' } {
            & $add 0xFF, 0xD8
            if ($Format -eq 'JPEGExif') {
                # APP1 EXIF segment carrying a 16x16 thumbnail JPEG with its own SOF0.
                $thumb = 0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x11, 0x08, 0x00, 0x10, 0x00, 0x10,
                         0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01, 0xFF, 0xD9
                & $add 0xFF, 0xE1
                & $be (2 + 6 + $thumb.Count) 2
                & $ascii 'Exif'
                & $add 0x00, 0x00
                & $add $thumb
            }
            # APP0 JFIF
            & $add 0xFF, 0xE0, 0x00, 0x10
            & $ascii 'JFIF'
            & $add 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00
            # DHT (non-frame C4 marker) and two fill bytes
            & $add 0xFF, 0xC4, 0x00, 0x05, 0x00, 0x00, 0x00
            & $add 0xFF, 0xFF
            # SOF0 / SOF2
            $sof = 0xC0
            if ($Format -eq 'JPEGProgressive') { $sof = 0xC2 }
            & $add 0xFF, $sof, 0x00, 0x11, 0x08
            & $be $Height 2
            & $be $Width 2
            & $add 0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01
            # SOS and EOI
            & $add 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00
            & $add 0xFF, 0xD9
        }
        'PNG' {
            & $add 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A
            & $add 0x00, 0x00, 0x00, 0x0D
            & $ascii 'IHDR'
            & $be $Width 4
            & $be $Height 4
            & $add 0x08, 0x02, 0x00, 0x00, 0x00
            & $add 0x00, 0x00, 0x00, 0x00
        }
        'GIF' {
            & $ascii 'GIF89a'
            & $le $Width 2
            & $le $Height 2
            & $add 0x00, 0x00, 0x00, 0x3B
        }
        { $_ -in 'BMP', 'BMPTopDown' } {
            $h = $Height
            if ($Format -eq 'BMPTopDown') { $h = -$Height }
            & $ascii 'BM'
            & $le 54 4
            & $le 0 4
            & $le 54 4
            & $le 40 4
            & $le $Width 4
            & $le $h 4
            & $le 1 2
            & $le 24 2
            & $add (@(0) * 24)
        }
        { $_ -like 'WebP*' } {
            & $ascii 'RIFF'
            & $le 0 4   # patched below
            & $ascii 'WEBP'
            if ($Format -eq 'WebPVP8') {
                & $ascii 'VP8 '
                & $le 10 4
                & $add 0x00, 0x00, 0x00, 0x9D, 0x01, 0x2A
                & $le $Width 2
                & $le $Height 2
            } elseif ($Format -eq 'WebPVP8L') {
                & $ascii 'VP8L'
                & $le 5 4
                & $add 0x2F
                & $le (([long]$Width - 1) -bor (([long]$Height - 1) -shl 14)) 4
            } else {
                & $ascii 'VP8X'
                & $le 10 4
                & $add 0x00, 0x00, 0x00, 0x00
                & $le ($Width - 1) 3
                & $le ($Height - 1) 3
            }
            $size = $list.Count - 8
            for ($i = 0; $i -lt 4; $i++) { $list[4 + $i] = [byte](($size -shr (8 * $i)) -band 0xFF) }
        }
        { $_ -in 'TIFFLE', 'TIFFBE' } {
            $w = $le
            if ($Format -eq 'TIFFBE') { $w = $be; & $ascii 'MM'; & $add 0x00, 0x2A }
            else { & $ascii 'II'; & $add 0x2A, 0x00 }
            & $w 8 4
            & $w 2 2
            # ImageWidth, SHORT, count 1, value left-justified in the 4-byte field
            & $w 256 2; & $w 3 2; & $w 1 4; & $w $Width 2; & $add 0x00, 0x00
            # ImageLength, LONG, count 1
            & $w 257 2; & $w 4 2; & $w 1 4; & $w $Height 4
            & $w 0 4
        }
    }

    while ($list.Count -lt $PadTo) { $list.Add([byte]0) }
    return [byte[]]$list.ToArray()
}

function New-TestImage {
    <#
        Writes a minimal valid image header (see New-TestImageBytes) to Dir\Name,
        creating Dir if needed, and returns the full path. Without -Format the
        format is derived from the extension.
    #>
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][string]$Name,
        [string]$Format,
        [int]$Width = 600,
        [int]$Height = 600,
        [int]$PadTo = 0
    )
    if (-not $Format) {
        switch ([System.IO.Path]::GetExtension($Name).ToLowerInvariant()) {
            '.jpg'  { $Format = 'JPEG' }
            '.jpeg' { $Format = 'JPEG' }
            '.png'  { $Format = 'PNG' }
            '.gif'  { $Format = 'GIF' }
            '.bmp'  { $Format = 'BMP' }
            '.webp' { $Format = 'WebPVP8X' }
            '.tif'  { $Format = 'TIFFLE' }
            '.tiff' { $Format = 'TIFFLE' }
            default { throw "New-TestImage: cannot derive a format from '$Name'" }
        }
    }
    if (-not (Test-Path -LiteralPath $Dir)) {
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    }
    $full = Join-Path $Dir $Name
    $bytes = [byte[]](New-TestImageBytes -Format $Format -Width $Width -Height $Height -PadTo $PadTo)
    [System.IO.File]::WriteAllBytes($full, $bytes)
    return $full
}

function New-GarbageFile {
    <#
        Writes the ASCII bytes 'not an image' to Dir\Name (creating Dir if needed)
        and returns the full path.
    #>
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][string]$Name
    )
    if (-not (Test-Path -LiteralPath $Dir)) {
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    }
    $full = Join-Path $Dir $Name
    [System.IO.File]::WriteAllBytes($full, [System.Text.Encoding]::ASCII.GetBytes('not an image'))
    return $full
}

function Get-FileNames {
    <#
        Returns the sorted leaf names of the files directly in a directory, for
        easy comparison against an expected set.
    #>
    param([Parameter(Mandatory)][string]$Dir)
    @(Get-ChildItem -LiteralPath $Dir -File | Select-Object -ExpandProperty Name | Sort-Object)
}
