BeforeAll {
    . $PSScriptRoot/TestHelpers.ps1
    Import-PwshMusicTools

    # Build the bytes of a minimal FLAC header: optional ID3v2 tag, 'fLaC',
    # a STREAMINFO block header, and the 34-byte STREAMINFO body.
    function New-FlacHeaderBytes {
        param(
            [int]    $SampleRate    = 44100,
            [int]    $Channels      = 2,
            [int]    $BitsPerSample = 16,
            [long]   $TotalSamples  = 1234567,
            [byte[]] $Md5           = ([byte[]](1..16)),
            [int]    $BlockType     = 0,
            [switch] $WithId3
        )
        $bytes = [System.Collections.Generic.List[byte]]::new()
        if ($WithId3) {
            # 'ID3' v2.3, no flags, syncsafe size 20, then 20 bytes of padding.
            $bytes.AddRange([byte[]](0x49, 0x44, 0x33, 3, 0, 0, 0, 0, 0, 20))
            $bytes.AddRange([byte[]]::new(20))
        }
        $bytes.AddRange([System.Text.Encoding]::ASCII.GetBytes('fLaC'))
        $bytes.AddRange([byte[]](([byte](0x80 -bor $BlockType)), 0, 0, 34))

        $si = [byte[]]::new(34)
        # Bytes 0..9 (block/frame sizes) are irrelevant to the parser; leave zero.
        [UInt64] $packed = ([UInt64]$SampleRate -shl 44) -bor
                           ([UInt64]($Channels - 1) -shl 41) -bor
                           ([UInt64]($BitsPerSample - 1) -shl 36) -bor
                           [UInt64]$TotalSamples
        for ($i = 0; $i -lt 8; $i++) { $si[10 + $i] = [byte](($packed -shr (56 - 8 * $i)) -band 0xFF) }
        [Array]::Copy($Md5, 0, $si, 18, 16)
        $bytes.AddRange($si)
        $bytes.ToArray()
    }

    function New-FlacHeaderFile {
        param([string] $Dir, [string] $Name = 'test.flac', [hashtable] $Options = @{})
        $path = Join-Path $Dir $Name
        [System.IO.File]::WriteAllBytes($path, (New-FlacHeaderBytes @Options))
        $path
    }

}

# -Skip on a Describe is evaluated during discovery, before BeforeAll runs, so the
# tool check must happen here or the real-ffmpeg tests would always be skipped.
BeforeDiscovery {
    $ffmpegAvailable = [bool](Get-Command ffmpeg -ErrorAction SilentlyContinue)
}

Describe 'Get-FlacStreamInfo' {

    BeforeEach { $script:root = New-TestDir }
    AfterEach  { Remove-TestDir -Path $script:root }

    It 'parses sample rate, channels, bit depth, total samples and MD5' {
        $md5  = [byte[]](0xDE, 0xAD, 0xBE, 0xEF, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 0xFF)
        $file = New-FlacHeaderFile -Dir $root -Options @{ SampleRate = 96000; Channels = 6; BitsPerSample = 24; TotalSamples = 68719476735; Md5 = $md5 }

        $info = InModuleScope PwshMusicTools -Parameters @{ F = $file } { Get-FlacStreamInfo -Path $F }

        $info.Valid         | Should -BeTrue
        $info.SampleRate    | Should -Be 96000
        $info.Channels      | Should -Be 6
        $info.BitsPerSample | Should -Be 24
        $info.TotalSamples  | Should -Be 68719476735   # max 36-bit value
        $info.MD5           | Should -Be 'deadbeef000102030405060708090aff'
        $info.MD5Unset      | Should -BeFalse
    }

    It 'flags an all-zero MD5 as unset' {
        $file = New-FlacHeaderFile -Dir $root -Options @{ Md5 = [byte[]]::new(16) }

        $info = InModuleScope PwshMusicTools -Parameters @{ F = $file } { Get-FlacStreamInfo -Path $F }

        $info.MD5Unset | Should -BeTrue
    }

    It 'skips a leading ID3v2 tag' {
        $file = New-FlacHeaderFile -Dir $root -Options @{ WithId3 = $true; SampleRate = 48000 }

        $info = InModuleScope PwshMusicTools -Parameters @{ F = $file } { Get-FlacStreamInfo -Path $F }

        $info.Valid      | Should -BeTrue
        $info.SampleRate | Should -Be 48000
    }

    It 'rejects a file without the fLaC marker' {
        $file = Join-Path $root 'fake.flac'
        [System.IO.File]::WriteAllBytes($file, [System.Text.Encoding]::ASCII.GetBytes('this is not flac data at all'))

        $info = InModuleScope PwshMusicTools -Parameters @{ F = $file } { Get-FlacStreamInfo -Path $F }

        $info.Valid  | Should -BeFalse
        $info.Reason | Should -Match 'fLaC'
    }

    It 'rejects a stream whose first block is not STREAMINFO' {
        $file = New-FlacHeaderFile -Dir $root -Options @{ BlockType = 4 }

        $info = InModuleScope PwshMusicTools -Parameters @{ F = $file } { Get-FlacStreamInfo -Path $F }

        $info.Valid  | Should -BeFalse
        $info.Reason | Should -Match 'STREAMINFO'
    }

    It 'rejects a truncated STREAMINFO block' {
        $file  = Join-Path $root 'short.flac'
        $bytes = New-FlacHeaderBytes
        [System.IO.File]::WriteAllBytes($file, $bytes[0..20])

        $info = InModuleScope PwshMusicTools -Parameters @{ F = $file } { Get-FlacStreamInfo -Path $F }

        $info.Valid  | Should -BeFalse
        $info.Reason | Should -Match 'Truncated'
    }
}

Describe 'Get-FlacMD5PcmCodec' {

    It 'maps <Bps>-bit to <Codec>' -ForEach @(
        @{ Bps = 8;  Codec = 'pcm_s8' }
        @{ Bps = 16; Codec = 'pcm_s16le' }
        @{ Bps = 24; Codec = 'pcm_s24le' }
        @{ Bps = 32; Codec = 'pcm_s32le' }
    ) {
        InModuleScope PwshMusicTools -Parameters @{ B = $Bps } { Get-FlacMD5PcmCodec -BitsPerSample $B } |
            Should -Be $Codec
    }

    It 'returns $null for depths the ffmpeg fallback cannot reproduce (e.g. 20-bit)' {
        InModuleScope PwshMusicTools { Get-FlacMD5PcmCodec -BitsPerSample 20 } | Should -BeNullOrEmpty
    }
}

Describe 'Test-FlacMD5' {

    BeforeEach { $script:root = New-TestDir }
    AfterEach  { Remove-TestDir -Path $script:root }

    Context 'ffmpeg fallback' {

        It 'reports Match when the decoded MD5 equals the stored one' {
            $file = New-FlacHeaderFile -Dir $root
            InModuleScope PwshMusicTools -Parameters @{ F = $file } {
                Mock Get-FlacDecodedMD5 { '0102030405060708090a0b0c0d0e0f10' }
                $r = Test-FlacMD5 -Path $F
                $r.Result | Should -Be 'Match'
                $r.Method | Should -Be 'ffmpeg'
                Should -Invoke Get-FlacDecodedMD5 -Times 1 -ParameterFilter { $Codec -eq 'pcm_s16le' }
            }
        }

        It 'reports Mismatch when the decoded MD5 differs' {
            $file = New-FlacHeaderFile -Dir $root
            InModuleScope PwshMusicTools -Parameters @{ F = $file } {
                Mock Get-FlacDecodedMD5 { 'ffffffffffffffffffffffffffffffff' }
                $r = Test-FlacMD5 -Path $F
                $r.Result     | Should -Be 'Mismatch'
                $r.StoredMD5  | Should -Be '0102030405060708090a0b0c0d0e0f10'
                $r.DecodedMD5 | Should -Be 'ffffffffffffffffffffffffffffffff'
                $r.Detail     | Should -Match 'MD5 mismatch'
            }
        }

        It 'reports Unchecked for a bit depth the fallback cannot handle' {
            $file = New-FlacHeaderFile -Dir $root -Options @{ BitsPerSample = 20 }
            InModuleScope PwshMusicTools -Parameters @{ F = $file } {
                Mock Get-FlacDecodedMD5 { throw 'should not be called' }
                $r = Test-FlacMD5 -Path $F
                $r.Result | Should -Be 'Unchecked'
                $r.Detail | Should -Match '20-bit'
                Should -Invoke Get-FlacDecodedMD5 -Times 0
            }
        }

        It 'reports Error when ffmpeg cannot produce a hash' {
            $file = New-FlacHeaderFile -Dir $root
            InModuleScope PwshMusicTools -Parameters @{ F = $file } {
                Mock Get-FlacDecodedMD5 { throw 'ffmpeg did not produce an MD5' }
                (Test-FlacMD5 -Path $F).Result | Should -Be 'Error'
            }
        }
    }

    Context 'flac -t' {

        It 'reports Match when flac -t succeeds' {
            $file = New-FlacHeaderFile -Dir $root
            InModuleScope PwshMusicTools -Parameters @{ F = $file } {
                Mock Invoke-FlacTest { [PSCustomObject]@{ ExitCode = 0; Output = '' } }
                Mock Get-FlacDecodedMD5 { throw 'should not be called' }
                $r = Test-FlacMD5 -Path $F -FlacExe 'C:\tools\flac.exe'
                $r.Result | Should -Be 'Match'
                $r.Method | Should -Be 'flac'
                Should -Invoke Get-FlacDecodedMD5 -Times 0
            }
        }

        It 'reports Mismatch when flac -t reports an MD5 signature mismatch' {
            $file = New-FlacHeaderFile -Dir $root
            InModuleScope PwshMusicTools -Parameters @{ F = $file } {
                Mock Invoke-FlacTest { [PSCustomObject]@{ ExitCode = 1; Output = 'test.flac: ERROR, MD5 signature mismatch' } }
                (Test-FlacMD5 -Path $F -FlacExe 'flac.exe').Result | Should -Be 'Mismatch'
            }
        }

        It 'reports Failed when flac -t rejects the file for another reason' {
            $file = New-FlacHeaderFile -Dir $root
            InModuleScope PwshMusicTools -Parameters @{ F = $file } {
                Mock Invoke-FlacTest { [PSCustomObject]@{ ExitCode = 1; Output = 'test.flac: ERROR while decoding data' } }
                $r = Test-FlacMD5 -Path $F -FlacExe 'flac.exe'
                $r.Result | Should -Be 'Failed'
                $r.Detail | Should -Match 'decoding data'
            }
        }
    }

    Context 'no signature to compare' {

        It 'reports Unset without running either tool' {
            $file = New-FlacHeaderFile -Dir $root -Options @{ Md5 = [byte[]]::new(16) }
            InModuleScope PwshMusicTools -Parameters @{ F = $file } {
                Mock Invoke-FlacTest { throw 'should not be called' }
                Mock Get-FlacDecodedMD5 { throw 'should not be called' }
                (Test-FlacMD5 -Path $F -FlacExe 'flac.exe').Result | Should -Be 'Unset'
                (Test-FlacMD5 -Path $F).Result                       | Should -Be 'Unset'
                Should -Invoke Invoke-FlacTest -Times 0
                Should -Invoke Get-FlacDecodedMD5 -Times 0
            }
        }

        It 'reports Unchecked for a file that is not FLAC' {
            $file = Join-Path $root 'fake.flac'
            [System.IO.File]::WriteAllBytes($file, [System.Text.Encoding]::ASCII.GetBytes('nope'))
            InModuleScope PwshMusicTools -Parameters @{ F = $file } {
                (Test-FlacMD5 -Path $F).Result | Should -Be 'Unchecked'
            }
        }
    }
}

Describe 'FLAC MD5 helpers in a -Parallel runspace' {

    BeforeEach { $script:root = New-TestDir }
    AfterEach  { Remove-TestDir -Path $script:root }

    It 'can be recreated from Private\FlacMD5.ps1 the way Test-AudioIntegrity does it' {
        # Mirrors Test-AudioIntegrity: read the helper file from disk, then
        # dot-source it inside a fresh ForEach-Object -Parallel runspace.
        $file = New-FlacHeaderFile -Dir $root -Options @{ SampleRate = 44100 }
        $helperFile = Join-Path (Get-Module PwshMusicTools).ModuleBase 'Private\FlacMD5.ps1'
        $src = Get-Content -LiteralPath $helperFile -Raw

        $info = 1 | ForEach-Object -Parallel {
            . ([scriptblock]::Create($using:src))
            Get-FlacStreamInfo -Path $using:file
        }

        $info.Valid      | Should -BeTrue
        $info.SampleRate | Should -Be 44100
    }
}

Describe 'Test-AudioIntegrity -VerifyFlacMD5 helper loading' {

    # Regression: the helpers used to be looked up as loaded module functions,
    # so a session without them (old loader, file dot-sourced on its own) got a
    # wall of Get-Item errors and a silently blank Md5Check.

    BeforeEach {
        $script:root = New-TestDir
        $script:flac = New-FlacHeaderFile -Dir $root
        $moduleBase  = (Get-Module PwshMusicTools).ModuleBase
        # A standalone copy of the module layout, loaded WITHOUT the module loader.
        $script:copy = Join-Path $root 'copy'
        New-Item -ItemType Directory -Path (Join-Path $copy 'Public') -Force | Out-Null
        Copy-Item (Join-Path $moduleBase 'Public\Test-AudioIntegrity.ps1') (Join-Path $copy 'Public')
        $script:privateSrc = Join-Path $moduleBase 'Private'
    }

    AfterEach { Remove-TestDir -Path $script:root }

    It 'works when Test-AudioIntegrity is loaded without the module loader' {
        Copy-Item $privateSrc (Join-Path $copy 'Private') -Recurse
        . (Join-Path $copy 'Public\Test-AudioIntegrity.ps1')

        { Test-AudioIntegrity -Path $flac -VerifyFlacMD5 -ErrorAction Stop | Out-Null } | Should -Not -Throw
    }

    It 'stops with a clear error when the Private folder is missing' {
        . (Join-Path $copy 'Public\Test-AudioIntegrity.ps1')

        { Test-AudioIntegrity -Path $flac -VerifyFlacMD5 } |
            Should -Throw -ExpectedMessage '*-VerifyFlacMD5 needs*FlacMD5.ps1*'
    }
}

Describe 'Test-AudioIntegrity -VerifyFlacMD5 (real ffmpeg)' -Skip:(-not $ffmpegAvailable) {

    BeforeEach {
        $script:root = New-TestDir
        $script:flac = Join-Path $root 'tone.flac'
        # One second of a sine tone; ffmpeg's FLAC encoder writes the MD5.
        & ffmpeg -v error -nostdin -f lavfi -i 'sine=frequency=440:duration=1' -c:a flac $flac 2>&1 | Out-Null
    }

    AfterEach { Remove-TestDir -Path $script:root }

    It 'passes an intact FLAC file' {
        $r = Test-AudioIntegrity -Path $flac -VerifyFlacMD5
        $r.Status   | Should -Be 'OK'
        $r.Md5Check | Should -Be 'Match'
    }

    It 'flags a FLAC file whose stored MD5 no longer matches the audio' {
        # Flip one byte of the stored MD5. Frame CRCs are untouched, so a plain
        # decode check still passes; only the MD5 check catches it.
        $bytes = [System.IO.File]::ReadAllBytes($flac)
        $md5Offset = 4 + 4 + 18   # 'fLaC' + block header + STREAMINFO offset
        $bytes[$md5Offset] = $bytes[$md5Offset] -bxor 0xFF
        [System.IO.File]::WriteAllBytes($flac, $bytes)

        (Test-AudioIntegrity -Path $flac).Status | Should -Be 'OK'

        $r = Test-AudioIntegrity -Path $flac -VerifyFlacMD5
        $r.Status   | Should -Be 'CORRUPT'
        $r.Md5Check | Should -Be 'Mismatch'
    }
}
