# Private header-only image reader plus format/extension/MIME mapping helpers.
#
# Get-ImageInfo reads just enough of an image's header to report its format and
# pixel dimensions. It never reads the whole file, never decodes pixels and needs
# no System.Drawing or ffprobe, so it is cheap to run over a large collection.

function Read-ImageHeaderBytes {
    <#
        Reads exactly Count bytes starting at Offset from Stream. Returns the
        bytes (unrolled, so callers cast with [byte[]]) or nothing when fewer than
        Count bytes are available.
    #>
    param(
        [Parameter(Mandatory = $true)][System.IO.Stream]$Stream,
        [Parameter(Mandatory = $true)][long]$Offset,
        [Parameter(Mandatory = $true)][int]$Count
    )

    if ($Offset -lt 0 -or $Count -le 0 -or ($Offset + $Count) -gt $Stream.Length) { return }
    [void]$Stream.Seek($Offset, [System.IO.SeekOrigin]::Begin)
    $buffer = New-Object byte[] $Count
    $total = 0
    while ($total -lt $Count) {
        $n = $Stream.Read($buffer, $total, $Count - $total)
        if ($n -le 0) { return }
        $total += $n
    }
    return $buffer
}

function Get-ImageHeaderUInt {
    <#
        Reads an unsigned integer of Size bytes (2, 3 or 4) from Bytes at Index,
        big-endian with -BigEndian, otherwise little-endian. Returns a [long].
    #>
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][int]$Index,
        [Parameter(Mandatory = $true)][int]$Size,
        [switch]$BigEndian
    )

    [long]$value = 0
    for ($i = 0; $i -lt $Size; $i++) {
        if ($BigEndian) {
            $value = ($value -shl 8) -bor [long]$Bytes[$Index + $i]
        } else {
            $value = $value -bor ([long]$Bytes[$Index + $i] -shl (8 * $i))
        }
    }
    return $value
}

function Get-ImageInfoFromStream {
    <#
        Parser shared by both Get-ImageInfo parameter sets. Fills $Result
        (DetectedFormat, Width, Height, Error) from the header bytes in Stream.
        TIFF: only the first IFD is read (tags 256 ImageWidth / 257 ImageLength).
    #>
    param(
        [Parameter(Mandatory = $true)][System.IO.Stream]$Stream,
        [Parameter(Mandatory = $true)]$Result
    )

    $len = $Stream.Length
    if ($len -le 0) { $Result.Error = 'Empty file'; return }

    $headCount = [int][Math]::Min([long]32, $len)
    $head = [byte[]](Read-ImageHeaderBytes -Stream $Stream -Offset 0 -Count $headCount)
    $h = $head.Length

    $isAscii = {
        param([int]$At, [string]$Text)
        if ($h -lt ($At + $Text.Length)) { return $false }
        for ($i = 0; $i -lt $Text.Length; $i++) {
            if ($head[$At + $i] -ne [byte][char]$Text[$i]) { return $false }
        }
        return $true
    }
    $read = {
        param([long]$Offset, [int]$Count)
        $b = Read-ImageHeaderBytes -Stream $Stream -Offset $Offset -Count $Count
        if ($null -eq $b) { return }
        return [byte[]]$b
    }

    $w = [long]0
    $ht = [long]0

    if ($h -ge 2 -and $head[0] -eq 0xFF -and $head[1] -eq 0xD8) {
        $Result.DetectedFormat = 'JPEG'
        $pos = [long]2
        $found = $false
        for ($n = 0; $n -lt 1000; $n++) {
            $b = & $read $pos 1
            if ($null -eq $b) { $Result.Error = 'Truncated header'; return }
            if (([byte[]]$b)[0] -ne 0xFF) { $Result.Error = 'Invalid JPEG marker'; return }
            $pos++
            # Skip fill bytes; the first non-0xFF byte is the marker.
            do {
                $b = & $read $pos 1
                if ($null -eq $b) { $Result.Error = 'Truncated header'; return }
                $m = ([byte[]]$b)[0]
                $pos++
            } while ($m -eq 0xFF)

            if (($m -ge 0xD0 -and $m -le 0xD7) -or $m -eq 0x01) { continue }
            if ($m -eq 0xD9 -or $m -eq 0xDA) { $Result.Error = 'No JPEG frame header'; return }

            $b = & $read $pos 2
            if ($null -eq $b) { $Result.Error = 'Truncated header'; return }
            $segLen = Get-ImageHeaderUInt -Bytes ([byte[]]$b) -Index 0 -Size 2 -BigEndian
            if ($segLen -lt 2) { $Result.Error = 'Invalid JPEG marker'; return }

            if ($m -ge 0xC0 -and $m -le 0xCF -and $m -ne 0xC4 -and $m -ne 0xC8 -and $m -ne 0xCC) {
                $b = & $read ($pos + 2) 5
                if ($null -eq $b) { $Result.Error = 'Truncated header'; return }
                $sof = [byte[]]$b
                $ht = Get-ImageHeaderUInt -Bytes $sof -Index 1 -Size 2 -BigEndian
                $w = Get-ImageHeaderUInt -Bytes $sof -Index 3 -Size 2 -BigEndian
                $found = $true
                break
            }
            # Skip the whole segment (APPn incl. EXIF thumbnails is never scanned).
            $pos += $segLen
        }
        if (-not $found) { $Result.Error = 'No JPEG frame header'; return }
    }
    elseif ($h -ge 8 -and $head[0] -eq 0x89 -and (& $isAscii 1 'PNG') -and
            $head[4] -eq 0x0D -and $head[5] -eq 0x0A -and $head[6] -eq 0x1A -and $head[7] -eq 0x0A) {
        $Result.DetectedFormat = 'PNG'
        $b = & $read 8 16
        if ($null -eq $b) { $Result.Error = 'Truncated header'; return }
        $ihdr = [byte[]]$b
        if (-not ($ihdr[4] -eq 0x49 -and $ihdr[5] -eq 0x48 -and $ihdr[6] -eq 0x44 -and $ihdr[7] -eq 0x52)) {
            $Result.Error = 'Invalid PNG'; return
        }
        $w = Get-ImageHeaderUInt -Bytes $ihdr -Index 8 -Size 4 -BigEndian
        $ht = Get-ImageHeaderUInt -Bytes $ihdr -Index 12 -Size 4 -BigEndian
    }
    elseif ((& $isAscii 0 'GIF87a') -or (& $isAscii 0 'GIF89a')) {
        $Result.DetectedFormat = 'GIF'
        $b = & $read 6 4
        if ($null -eq $b) { $Result.Error = 'Truncated header'; return }
        $g = [byte[]]$b
        $w = Get-ImageHeaderUInt -Bytes $g -Index 0 -Size 2
        $ht = Get-ImageHeaderUInt -Bytes $g -Index 2 -Size 2
    }
    elseif (& $isAscii 0 'BM') {
        $Result.DetectedFormat = 'BMP'
        $b = & $read 14 4
        if ($null -eq $b) { $Result.Error = 'Truncated header'; return }
        $dibSize = Get-ImageHeaderUInt -Bytes ([byte[]]$b) -Index 0 -Size 4
        if ($dibSize -eq 12) {
            $b = & $read 18 4
            if ($null -eq $b) { $Result.Error = 'Truncated header'; return }
            $d = [byte[]]$b
            $w = Get-ImageHeaderUInt -Bytes $d -Index 0 -Size 2
            $ht = Get-ImageHeaderUInt -Bytes $d -Index 2 -Size 2
        } else {
            $b = & $read 18 8
            if ($null -eq $b) { $Result.Error = 'Truncated header'; return }
            $d = [byte[]]$b
            $w = Get-ImageHeaderUInt -Bytes $d -Index 0 -Size 4
            $ht = Get-ImageHeaderUInt -Bytes $d -Index 4 -Size 4
            # Signed 32-bit; a negative height means a top-down bitmap.
            if ($w -ge 2147483648) { $w -= 4294967296 }
            if ($ht -ge 2147483648) { $ht -= 4294967296 }
            $w = [Math]::Abs($w)
            $ht = [Math]::Abs($ht)
        }
    }
    elseif ((& $isAscii 0 'RIFF') -and (& $isAscii 8 'WEBP')) {
        $Result.DetectedFormat = 'WebP'
        $b = & $read 12 4
        if ($null -eq $b) { $Result.Error = 'Truncated header'; return }
        $fourCC = [System.Text.Encoding]::ASCII.GetString([byte[]]$b, 0, 4)
        # Bytes needed from offset 0 for each chunk's dimension fields.
        $need = 30
        if ($fourCC -ceq 'VP8L') { $need = 25 }
        $b = & $read 0 $need
        if ($null -eq $b) {
            if ($fourCC -cne 'VP8 ' -and $fourCC -cne 'VP8L' -and $fourCC -cne 'VP8X') {
                $Result.Error = 'Unsupported WebP chunk'
            } else {
                $Result.Error = 'Truncated header'
            }
            return
        }
        $r = [byte[]]$b
        switch -CaseSensitive ($fourCC) {
            'VP8 ' {
                if (-not ($r[23] -eq 0x9D -and $r[24] -eq 0x01 -and $r[25] -eq 0x2A)) {
                    $Result.Error = 'Invalid WebP'; return
                }
                $w = (Get-ImageHeaderUInt -Bytes $r -Index 26 -Size 2) -band 0x3FFF
                $ht = (Get-ImageHeaderUInt -Bytes $r -Index 28 -Size 2) -band 0x3FFF
            }
            'VP8L' {
                if ($r[20] -ne 0x2F) { $Result.Error = 'Invalid WebP'; return }
                $v = Get-ImageHeaderUInt -Bytes $r -Index 21 -Size 4
                $w = ($v -band 0x3FFF) + 1
                $ht = (($v -shr 14) -band 0x3FFF) + 1
            }
            'VP8X' {
                $w = (Get-ImageHeaderUInt -Bytes $r -Index 24 -Size 3) + 1
                $ht = (Get-ImageHeaderUInt -Bytes $r -Index 27 -Size 3) + 1
            }
            default { $Result.Error = 'Unsupported WebP chunk'; return }
        }
    }
    elseif ($h -ge 4 -and (((& $isAscii 0 'II') -and $head[2] -eq 0x2A -and $head[3] -eq 0x00) -or
                           ((& $isAscii 0 'MM') -and $head[2] -eq 0x00 -and $head[3] -eq 0x2A))) {
        $Result.DetectedFormat = 'TIFF'
        $be = ($head[0] -eq 0x4D)
        $b = & $read 4 4
        if ($null -eq $b) { $Result.Error = 'Truncated header'; return }
        $ifd = Get-ImageHeaderUInt -Bytes ([byte[]]$b) -Index 0 -Size 4 -BigEndian:$be
        $b = & $read $ifd 2
        if ($null -eq $b) { $Result.Error = 'Truncated header'; return }
        $count = Get-ImageHeaderUInt -Bytes ([byte[]]$b) -Index 0 -Size 2 -BigEndian:$be
        if ($count -eq 0 -or $count -gt 4096) { $Result.Error = 'Invalid TIFF'; return }
        $b = & $read ($ifd + 2) ([int]$count * 12)
        if ($null -eq $b) { $Result.Error = 'Truncated header'; return }
        $entries = [byte[]]$b
        $gotW = $false
        $gotH = $false
        for ($i = 0; $i -lt $count; $i++) {
            $e = $i * 12
            $tag = Get-ImageHeaderUInt -Bytes $entries -Index $e -Size 2 -BigEndian:$be
            if ($tag -ne 256 -and $tag -ne 257) { continue }
            $type = Get-ImageHeaderUInt -Bytes $entries -Index ($e + 2) -Size 2 -BigEndian:$be
            if ($type -eq 3) {
                $val = Get-ImageHeaderUInt -Bytes $entries -Index ($e + 8) -Size 2 -BigEndian:$be
            } elseif ($type -eq 4) {
                $val = Get-ImageHeaderUInt -Bytes $entries -Index ($e + 8) -Size 4 -BigEndian:$be
            } else {
                continue
            }
            if ($tag -eq 256) { $w = $val; $gotW = $true } else { $ht = $val; $gotH = $true }
        }
        if (-not ($gotW -and $gotH)) { $Result.Error = 'Truncated header'; return }
    }
    else {
        $Result.Error = 'Unrecognised image format'
        return
    }

    if ($w -le 0 -or $ht -le 0) { $Result.Error = 'Invalid dimensions'; return }
    if ($w -gt [int]::MaxValue -or $ht -gt [int]::MaxValue) { $Result.Error = 'Invalid dimensions'; return }
    $Result.Width = [int]$w
    $Result.Height = [int]$ht
}

function Get-ImageInfo {
    <#
        Returns one object { DetectedFormat; Width; Height; Error } for an image
        file (-LiteralPath) or an in-memory image (-Bytes). Only header bytes are
        read. It never throws: an unreadable, missing, truncated or unknown image
        comes back with Error set (DetectedFormat stays filled when the signature
        was recognised). DetectedFormat is JPEG, PNG, GIF, BMP, WebP, TIFF or ''.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Path')][string]$LiteralPath,
        [Parameter(Mandatory = $true, ParameterSetName = 'Bytes')][AllowEmptyCollection()][byte[]]$Bytes
    )

    $result = [PSCustomObject]@{ DetectedFormat = ''; Width = 0; Height = 0; Error = '' }
    $stream = $null
    try {
        if ($PSCmdlet.ParameterSetName -eq 'Bytes') {
            $stream = [System.IO.MemoryStream]::new($Bytes, $false)
        } else {
            $stream = [System.IO.File]::Open($LiteralPath, [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        }
        Get-ImageInfoFromStream -Stream $stream -Result $result
    }
    catch {
        $result.Error = $_.Exception.Message
    }
    finally {
        if ($stream) { $stream.Dispose() }
    }
    if ($result.Error) {
        $result.Width = 0
        $result.Height = 0
    }
    return $result
}

function Get-ImageFormatFromExtension {
    <#
        Maps a file extension (with the dot, any case) to the DetectedFormat name
        Get-ImageInfo would report: .jpg/.jpeg JPEG, .png PNG, .gif GIF, .bmp BMP,
        .webp WebP, .tif/.tiff TIFF. Anything else returns ''.
    #>
    param([AllowEmptyString()][string]$Extension)

    switch ($Extension.Trim().ToLowerInvariant()) {
        '.jpg'  { return 'JPEG' }
        '.jpeg' { return 'JPEG' }
        '.png'  { return 'PNG' }
        '.gif'  { return 'GIF' }
        '.bmp'  { return 'BMP' }
        '.webp' { return 'WebP' }
        '.tif'  { return 'TIFF' }
        '.tiff' { return 'TIFF' }
    }
    return ''
}

function Get-ImageExtensionFromFormat {
    <#
        Maps a DetectedFormat name to the extension used when writing a file of
        that format: JPEG .jpg, PNG .png, GIF .gif, BMP .bmp, WebP .webp, TIFF .tif.
        Anything else returns ''.
    #>
    param([AllowEmptyString()][string]$Format)

    switch ($Format.Trim()) {
        'JPEG' { return '.jpg' }
        'PNG'  { return '.png' }
        'GIF'  { return '.gif' }
        'BMP'  { return '.bmp' }
        'WebP' { return '.webp' }
        'TIFF' { return '.tif' }
    }
    return ''
}

function Get-ImageExtensionFromMimeType {
    <#
        Maps an image MIME type (case-insensitive, trimmed) to a file extension:
        image/jpeg, image/jpg, image/pjpeg .jpg; image/png .png; image/gif .gif;
        image/bmp, image/x-ms-bmp .bmp; image/webp .webp; image/tiff .tif.
        Anything else returns ''.
    #>
    param([AllowEmptyString()][string]$MimeType)

    switch ($MimeType.Trim().ToLowerInvariant()) {
        'image/jpeg'     { return '.jpg' }
        'image/jpg'      { return '.jpg' }
        'image/pjpeg'    { return '.jpg' }
        'image/png'      { return '.png' }
        'image/gif'      { return '.gif' }
        'image/bmp'      { return '.bmp' }
        'image/x-ms-bmp' { return '.bmp' }
        'image/webp'     { return '.webp' }
        'image/tiff'     { return '.tif' }
    }
    return ''
}
