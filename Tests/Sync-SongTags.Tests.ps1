BeforeAll {
    . $PSScriptRoot/TestHelpers.ps1
    Import-PwshMusicTools
}

# -Skip on a Describe is evaluated during discovery, before BeforeAll runs.
# The real end-to-end test needs TagLibSharp already cached (the suite never
# downloads it) and ffmpeg to create real audio files to tag.
BeforeDiscovery {
    $tagLibCached    = Test-Path (Join-Path $env:LOCALAPPDATA 'TagLibSharp\TagLibSharp.dll')
    $ffmpegAvailable = [bool](Get-Command ffmpeg -ErrorAction SilentlyContinue)
}

Describe 'Sync-SongTags' {

    BeforeEach {
        $script:root = New-TestDir
        $script:tgt  = Join-Path $root 'mp3'
        $script:ref  = Join-Path $root 'flac'
        New-Item -ItemType Directory -Path $tgt, $ref -Force | Out-Null

        # Never touch TagLib or real files in these tests; record the calls instead.
        Mock -ModuleName PwshMusicTools Import-TagLibSharp { }
        Mock -ModuleName PwshMusicTools Copy-AudioFileTag { }
    }

    AfterEach {
        Remove-TestDir -Path $script:root
    }

    Context 'pairing' {

        It 'pairs files by track number across formats and copies reference tags onto targets' {
            New-EmptyFile -Dir $ref -Name '01 First Song.flac'  | Out-Null
            New-EmptyFile -Dir $ref -Name '02 Second Song.flac' | Out-Null
            New-EmptyFile -Dir $tgt -Name '01 first song.mp3'   | Out-Null
            New-EmptyFile -Dir $tgt -Name '02 second song.mp3'  | Out-Null

            $r = @(Sync-SongTags -ToTagDir $tgt -ReferenceDir $ref -Confirm:$false 6>$null)

            $r.Count | Should -Be 2
            ($r | ForEach-Object Status) | Should -Be @('Tagged', 'Tagged')
            Should -Invoke -ModuleName PwshMusicTools Copy-AudioFileTag -Times 1 -Exactly -ParameterFilter {
                $ReferencePath -eq (Join-Path $ref '01 First Song.flac') -and $TargetPath -eq (Join-Path $tgt '01 first song.mp3')
            }
            Should -Invoke -ModuleName PwshMusicTools Copy-AudioFileTag -Times 1 -Exactly -ParameterFilter {
                $ReferencePath -eq (Join-Path $ref '02 Second Song.flac') -and $TargetPath -eq (Join-Path $tgt '02 second song.mp3')
            }
        }

        It 'treats "1" and "01" as the same track' {
            New-EmptyFile -Dir $ref -Name '01 Song.flac' | Out-Null
            New-EmptyFile -Dir $tgt -Name '1 song.mp3'   | Out-Null

            Sync-SongTags -ToTagDir $tgt -ReferenceDir $ref -Confirm:$false 6>$null | Out-Null

            Should -Invoke -ModuleName PwshMusicTools Copy-AudioFileTag -Times 1 -Exactly
        }

        It 'skips a pair whose titles are too dissimilar' {
            New-EmptyFile -Dir $ref -Name '01 Completely Different Title.flac' | Out-Null
            New-EmptyFile -Dir $tgt -Name '1 totally unrelated song name.mp3'  | Out-Null

            $warnings = Sync-SongTags -ToTagDir $tgt -ReferenceDir $ref -Confirm:$false 3>&1 6>$null |
                        Where-Object { $_ -is [System.Management.Automation.WarningRecord] }

            ($warnings | Out-String) | Should -Match 'Title mismatch'
            Should -Invoke -ModuleName PwshMusicTools Copy-AudioFileTag -Times 0
        }

        It 'tags a dissimilar pair when the title check is disabled' {
            New-EmptyFile -Dir $ref -Name '01 Completely Different Title.flac' | Out-Null
            New-EmptyFile -Dir $tgt -Name '1 totally unrelated song name.mp3'  | Out-Null

            Sync-SongTags -ToTagDir $tgt -ReferenceDir $ref -TitleMatchThreshold 0 -Confirm:$false 6>$null | Out-Null

            Should -Invoke -ModuleName PwshMusicTools Copy-AudioFileTag -Times 1 -Exactly
        }

        It 'skips a track that appears more than once in the target folder' {
            New-EmptyFile -Dir $ref -Name '01 Song.flac'      | Out-Null
            New-EmptyFile -Dir $tgt -Name '01 version a.mp3'  | Out-Null
            New-EmptyFile -Dir $tgt -Name '1 version b.mp3'   | Out-Null

            Sync-SongTags -ToTagDir $tgt -ReferenceDir $ref -Confirm:$false 3>$null 6>$null | Out-Null

            Should -Invoke -ModuleName PwshMusicTools Copy-AudioFileTag -Times 0
        }

        It 'skips a target with no matching reference file' {
            New-EmptyFile -Dir $ref -Name '01 Song.flac' | Out-Null
            New-EmptyFile -Dir $tgt -Name '01 Song.mp3'  | Out-Null
            New-EmptyFile -Dir $tgt -Name '02 Extra.mp3' | Out-Null

            $warnings = Sync-SongTags -ToTagDir $tgt -ReferenceDir $ref -Confirm:$false 3>&1 6>$null |
                        Where-Object { $_ -is [System.Management.Automation.WarningRecord] }

            ($warnings | Out-String) | Should -Match 'No reference file matches track 2'
            Should -Invoke -ModuleName PwshMusicTools Copy-AudioFileTag -Times 1 -Exactly
        }
    }

    Context 'options' {

        It 'overwrites by default, passing neither -FillMissingOnly nor -ExcludePictures' {
            New-EmptyFile -Dir $ref -Name '01 Song.flac' | Out-Null
            New-EmptyFile -Dir $tgt -Name '01 Song.mp3'  | Out-Null

            Sync-SongTags -ToTagDir $tgt -ReferenceDir $ref -Confirm:$false 6>$null | Out-Null

            Should -Invoke -ModuleName PwshMusicTools Copy-AudioFileTag -Times 1 -Exactly -ParameterFilter {
                -not $FillMissingOnly -and -not $ExcludePictures
            }
        }

        It 'passes -FillMissingOnly and -ExcludePictures through' {
            New-EmptyFile -Dir $ref -Name '01 Song.flac' | Out-Null
            New-EmptyFile -Dir $tgt -Name '01 Song.mp3'  | Out-Null

            Sync-SongTags -ToTagDir $tgt -ReferenceDir $ref -FillMissingOnly -ExcludePictures -Confirm:$false 6>$null | Out-Null

            Should -Invoke -ModuleName PwshMusicTools Copy-AudioFileTag -Times 1 -Exactly -ParameterFilter {
                $FillMissingOnly -and $ExcludePictures
            }
        }
    }

    Context 'safety' {

        It 'does not load TagLib or write any tags under -WhatIf' {
            New-EmptyFile -Dir $ref -Name '01 Song.flac' | Out-Null
            New-EmptyFile -Dir $tgt -Name '01 Song.mp3'  | Out-Null

            Sync-SongTags -ToTagDir $tgt -ReferenceDir $ref -WhatIf 6>$null | Out-Null

            Should -Invoke -ModuleName PwshMusicTools Import-TagLibSharp -Times 0
            Should -Invoke -ModuleName PwshMusicTools Copy-AudioFileTag -Times 0
        }

        It 'reports a failed pair and continues with the rest' {
            New-EmptyFile -Dir $ref -Name '01 Song.flac'  | Out-Null
            New-EmptyFile -Dir $ref -Name '02 Other.flac' | Out-Null
            New-EmptyFile -Dir $tgt -Name '01 Song.mp3'   | Out-Null
            New-EmptyFile -Dir $tgt -Name '02 Other.mp3'  | Out-Null
            Mock -ModuleName PwshMusicTools Copy-AudioFileTag { throw 'file is locked' } -ParameterFilter { $TargetPath -like '*01 Song.mp3' }

            $r = @(Sync-SongTags -ToTagDir $tgt -ReferenceDir $ref -Confirm:$false 3>$null 6>$null)

            ($r | Where-Object Track -eq 1).Status | Should -Be 'Failed'
            ($r | Where-Object Track -eq 1).Detail | Should -Match 'file is locked'
            ($r | Where-Object Track -eq 2).Status | Should -Be 'Tagged'
        }

        It 'refuses to use the same folder as target and reference' {
            New-EmptyFile -Dir $tgt -Name '01 Song.mp3' | Out-Null

            { Sync-SongTags -ToTagDir $tgt -ReferenceDir $tgt -Confirm:$false } | Should -Throw '*same folder*'
            Should -Invoke -ModuleName PwshMusicTools Copy-AudioFileTag -Times 0
        }

        It 'errors when the target directory does not exist' {
            { Sync-SongTags -ToTagDir (Join-Path $root 'nope') -ReferenceDir $ref -Confirm:$false } | Should -Throw
        }
    }
}

Describe 'Sync-SongTags with real files' -Skip:(-not ($tagLibCached -and $ffmpegAvailable)) {

    BeforeEach {
        $script:root = New-TestDir
        $script:tgt  = Join-Path $root 'mp3'
        $script:ref  = Join-Path $root 'flac'
        New-Item -ItemType Directory -Path $tgt, $ref -Force | Out-Null

        $refFile = Join-Path $ref '01 Real Song.flac'
        $tgtFile = Join-Path $tgt '01 Real Song.mp3'
        & ffmpeg -v error -nostdin -f lavfi -i 'sine=frequency=440:duration=1' -c:a flac `
            -metadata title='Real Song' -metadata artist='Real Artist' -metadata album='Real Album' `
            -metadata album_artist='Real Album Artist' -metadata track=1 $refFile 2>&1 | Out-Null
        & ffmpeg -v error -nostdin -f lavfi -i 'sine=frequency=440:duration=1' -c:a libmp3lame `
            -metadata title='wrong' $tgtFile 2>&1 | Out-Null
    }

    AfterEach { Remove-TestDir -Path $script:root }

    It 'copies FLAC tags onto an MP3 and leaves the reference untouched' {
        $refBefore = (Get-FileHash -LiteralPath (Join-Path $ref '01 Real Song.flac')).Hash

        Sync-SongTags -ToTagDir $tgt -ReferenceDir $ref -Confirm:$false 6>$null | Out-Null

        $t = Get-AudioTags -Path (Join-Path $tgt '01 Real Song.mp3')
        $t.Title       | Should -Be 'Real Song'
        $t.Artist      | Should -Be 'Real Artist'
        $t.Album       | Should -Be 'Real Album'
        $t.AlbumArtist | Should -Be 'Real Album Artist'
        $t.Track       | Should -Be 1
        (Get-FileHash -LiteralPath (Join-Path $ref '01 Real Song.flac')).Hash | Should -Be $refBefore
    }
}
