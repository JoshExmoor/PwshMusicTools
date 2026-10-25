# Private helpers for verifying a FLAC file's STREAMINFO MD5 signature.
#
# FLAC stores an MD5 of the entire decoded audio in its STREAMINFO block. Frame
# CRCs (which ffmpeg -err_detect crccheck verifies) do not cover it, so a file
# whose frames are individually valid but whose audio no longer matches the
# stored signature passes an ffmpeg decode check. These helpers close that gap.
#
# Test-AudioIntegrity -VerifyFlacMD5 recreates these functions inside its
# ForEach-Object -Parallel runspaces, so they must stay self-contained: no calls
# to other module functions beyond the ones defined in this file.

function Get-FlacStreamInfo {
    <#
        Parses the STREAMINFO block of a FLAC file without any external tool.
        Skips a leading ID3v2 tag if present. Returns an object with Valid,
        Reason, SampleRate, Channels, BitsPerSample, TotalSamples, MD5 (32-char
        lowercase hex) and MD5Unset ($true when the encoder stored all zeros).
    #>
    param([Parameter(Mandatory)][string] $Path)

    $invalid = { param($reason) [PSCustomObject]@{ Valid = $false; Reason = $reason } }

    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $br = [System.IO.BinaryReader]::new($fs)

        # Skip an ID3v2 tag ("ID3", version, flags, 4-byte syncsafe size).
        $offset = 0
        $head = $br.ReadBytes(10)
        if ($head.Length -eq 10 -and $head[0] -eq 0x49 -and $head[1] -eq 0x44 -and $head[2] -eq 0x33) {
            $size = (([int]$head[6] -band 0x7F) -shl 21) -bor
                    (([int]$head[7] -band 0x7F) -shl 14) -bor
                    (([int]$head[8] -band 0x7F) -shl 7) -bor
                    ([int]$head[9] -band 0x7F)
            $offset = 10 + $size
            if ($head[5] -band 0x10) { $offset += 10 }   # footer present
        }
        $fs.Position = $offset

        $magic = $br.ReadBytes(4)
        if ($magic.Length -lt 4 -or [System.Text.Encoding]::ASCII.GetString($magic) -ne 'fLaC') {
            return (& $invalid 'Not a FLAC stream (missing fLaC marker)')
        }

        # The first metadata block must be STREAMINFO (type 0, at least 34 bytes).
        $bh = $br.ReadBytes(4)
        if ($bh.Length -lt 4) { return (& $invalid 'Truncated metadata block header') }
        $type = [int]$bh[0] -band 0x7F
        $len  = ([int]$bh[1] -shl 16) -bor ([int]$bh[2] -shl 8) -bor [int]$bh[3]
        if ($type -ne 0 -or $len -lt 34) { return (& $invalid 'First metadata block is not STREAMINFO') }

        $si = $br.ReadBytes(34)
        if ($si.Length -lt 34) { return (& $invalid 'Truncated STREAMINFO block') }

        # Bytes 10..17 pack: sample rate (20 bits), channels-1 (3), bps-1 (5),
        # total samples (36). Bytes 18..33 are the MD5 signature.
        $sampleRate = ([int]$si[10] -shl 12) -bor ([int]$si[11] -shl 4) -bor ([int]$si[12] -shr 4)
        $channels   = (([int]$si[12] -shr 1) -band 0x07) + 1
        $bps        = ((([int]$si[12] -band 0x01) -shl 4) -bor ([int]$si[13] -shr 4)) + 1
        $total      = (([long]([int]$si[13] -band 0x0F)) -shl 32) -bor
                      (([long]$si[14]) -shl 24) -bor (([long]$si[15]) -shl 16) -bor
                      (([long]$si[16]) -shl 8) -bor ([long]$si[17])

        $md5Bytes = $si[18..33]
        [PSCustomObject]@{
            Valid         = $true
            Reason        = $null
            SampleRate    = $sampleRate
            Channels      = $channels
            BitsPerSample = $bps
            TotalSamples  = $total
            MD5           = (($md5Bytes | ForEach-Object { $_.ToString('x2') }) -join '')
            MD5Unset      = (@($md5Bytes | Where-Object { $_ -ne 0 }).Count -eq 0)
        }
    }
    finally {
        $fs.Dispose()
    }
}

function Get-FlacMD5PcmCodec {
    <#
        Returns the ffmpeg PCM codec whose raw output matches what libFLAC hashes
        for a given bit depth (signed, little-endian, whole bytes per sample), or
        $null when the ffmpeg fallback cannot reproduce it. Odd depths such as 12
        or 20 bits are unsupported: ffmpeg left-aligns those samples inside a
        wider container, which would hash differently from libFLAC.
    #>
    param([Parameter(Mandatory)][int] $BitsPerSample)
    switch ($BitsPerSample) {
        8       { 'pcm_s8' }
        16      { 'pcm_s16le' }
        24      { 'pcm_s24le' }
        32      { 'pcm_s32le' }
        default { $null }
    }
}

function Get-FlacDecodedMD5 {
    <#
        Decodes the first audio stream with ffmpeg and returns the MD5 (lowercase
        hex) of the raw PCM in the given codec. Throws if ffmpeg reports no hash.
    #>
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Codec
    )
    $out = & ffmpeg -v error -nostdin -i $Path -map 0:a:0 -c:a $Codec -f md5 - 2>&1
    $m = [regex]::Match(($out | Out-String), 'MD5=([0-9a-fA-F]{32})')
    if (-not $m.Success) {
        $msg = ($out | Out-String).Trim() -replace '\s*\r?\n\s*', ' | '
        throw "ffmpeg did not produce an MD5: $msg"
    }
    $m.Groups[1].Value.ToLowerInvariant()
}

function Invoke-FlacTest {
    <#
        Runs the reference decoder's test mode ('flac -t'), which verifies frame
        CRCs and the STREAMINFO MD5. Returns the exit code and combined output.
    #>
    param(
        [Parameter(Mandatory)][string] $FlacExe,
        [Parameter(Mandatory)][string] $Path
    )
    $out = & $FlacExe -t -s $Path 2>&1
    [PSCustomObject]@{
        ExitCode = $LASTEXITCODE
        Output   = (($out | Out-String).Trim() -replace '\s*\r?\n\s*', ' | ')
    }
}

function Test-FlacMD5 {
    <#
        Verifies a FLAC file's audio against its STREAMINFO MD5 signature.
        Uses 'flac -t' when -FlacExe is given, otherwise the ffmpeg fallback.

        Result is one of:
          Match     - decoded audio matches the stored signature
          Mismatch  - decoded audio does NOT match the stored signature
          Failed    - 'flac -t' rejected the file for another reason
          Unset     - no signature stored (all zeros), nothing to compare
          Unchecked - could not be checked (not FLAC, unsupported bit depth)
          Error     - the check itself failed to run
    #>
    param(
        [Parameter(Mandatory)][string] $Path,
        [string] $FlacExe
    )

    $result = {
        param($r, $method, $detail, $stored, $decoded)
        [PSCustomObject]@{
            Result     = $r
            Method     = $method
            StoredMD5  = $stored
            DecodedMD5 = $decoded
            Detail     = $detail
        }
    }

    try { $info = Get-FlacStreamInfo -Path $Path }
    catch { return (& $result 'Error' $null "Could not read STREAMINFO: $($_.Exception.Message)" $null $null) }

    if (-not $info.Valid) { return (& $result 'Unchecked' $null $info.Reason $null $null) }
    if ($info.MD5Unset)   { return (& $result 'Unset' $null 'No MD5 signature stored in STREAMINFO' $null $null) }

    if ($FlacExe) {
        $t = Invoke-FlacTest -FlacExe $FlacExe -Path $Path
        if ($t.ExitCode -eq 0) { return (& $result 'Match' 'flac' '' $info.MD5 $null) }
        if ($t.Output -match 'MD5 signature mismatch') {
            return (& $result 'Mismatch' 'flac' "FLAC MD5 mismatch (flac -t): $($t.Output)" $info.MD5 $null)
        }
        return (& $result 'Failed' 'flac' "flac -t failed (exit $($t.ExitCode)): $($t.Output)" $info.MD5 $null)
    }

    $codec = Get-FlacMD5PcmCodec -BitsPerSample $info.BitsPerSample
    if (-not $codec) {
        return (& $result 'Unchecked' 'ffmpeg' ("{0}-bit FLAC is not supported by the ffmpeg MD5 fallback; install flac to check it" -f $info.BitsPerSample) $info.MD5 $null)
    }

    try { $decoded = Get-FlacDecodedMD5 -Path $Path -Codec $codec }
    catch { return (& $result 'Error' 'ffmpeg' $_.Exception.Message $info.MD5 $null) }

    if ($decoded -eq $info.MD5) { return (& $result 'Match' 'ffmpeg' '' $info.MD5 $decoded) }
    & $result 'Mismatch' 'ffmpeg' "FLAC MD5 mismatch: stored $($info.MD5), decoded $decoded" $info.MD5 $decoded
}
