BeforeAll {
    . $PSScriptRoot/TestHelpers.ps1
    Import-PwshMusicTools
}

Describe 'Update-M3UPath' {

    BeforeEach {
        $script:root  = New-TestDir
        $script:album = Join-Path $root 'album'
        # On disk: song.opus (the re-encoded file), keep.flac (unchanged).
        New-EmptyFile -Dir $album -Name 'song.opus' | Out-Null
        New-EmptyFile -Dir $album -Name 'keep.flac' | Out-Null
    }

    AfterEach {
        Remove-TestDir -Path $script:root
    }

    Context 'entry statuses' {

        It 'updates a missing entry to the -Extension file, keeps found ones, flags missing ones' {
            $pl = Join-Path $root 'list.m3u'
            @(
                (Join-Path $album 'song.mp3')   # missing, but song.opus exists -> Updated
                (Join-Path $album 'keep.flac')  # exists                        -> Found
                (Join-Path $album 'gone.mp3')   # missing, no gone.opus          -> Missing
            ) | Set-Content -LiteralPath $pl

            $r = @(Update-M3UPath $pl -Extension opus -Quiet)

            $r.Count | Should -Be 3
            ($r | Where-Object Line -eq 1).Status  | Should -Be 'Updated'
            ($r | Where-Object Line -eq 1).NewPath | Should -Be (Join-Path $album 'song.opus')
            ($r | Where-Object Line -eq 2).Status  | Should -Be 'Found'
            ($r | Where-Object Line -eq 2).NewPath | Should -Be (Join-Path $album 'keep.flac')
            ($r | Where-Object Line -eq 3).Status  | Should -Be 'Missing'
            ($r | Where-Object Line -eq 3).NewPath | Should -Be (Join-Path $album 'gone.mp3')
        }

        It 'accepts the extension with a leading dot and in any case' {
            $pl = Join-Path $root 'list.m3u'
            (Join-Path $album 'song.mp3') | Set-Content -LiteralPath $pl

            $r = Update-M3UPath $pl -Extension '.OPUS' -Quiet

            $r.Status  | Should -Be 'Updated'
            $r.NewPath | Should -BeExactly (Join-Path $album 'song.opus')
        }
    }

    Context 'output file' {

        It 'writes name_updated.ext next to the source by default' {
            $pl = Join-Path $root 'list.m3u8'
            (Join-Path $album 'song.mp3') | Set-Content -LiteralPath $pl

            Update-M3UPath $pl -Extension opus -Quiet | Out-Null

            $out = Join-Path $root 'list_updated.m3u8'
            Test-Path $out | Should -BeTrue
            (Get-Content -LiteralPath $out) | Should -Be @((Join-Path $album 'song.opus'))
        }

        It 'writes to -Output when given' {
            $pl  = Join-Path $root 'list.m3u'
            $out = Join-Path $root 'sub\custom.m3u8'
            (Join-Path $album 'song.mp3') | Set-Content -LiteralPath $pl

            Update-M3UPath $pl -Extension opus -Output $out -Quiet | Out-Null

            Test-Path $out | Should -BeTrue
            (Get-Content -LiteralPath $out) | Should -Be @((Join-Path $album 'song.opus'))
        }

        It 'never modifies the source playlist' {
            $pl = Join-Path $root 'list.m3u'
            (Join-Path $album 'song.mp3') | Set-Content -LiteralPath $pl
            $before = Get-Content -LiteralPath $pl -Raw

            Update-M3UPath $pl -Extension opus -Quiet | Out-Null

            Get-Content -LiteralPath $pl -Raw | Should -Be $before
        }

        It 'refuses to overwrite an existing output without -Force, and overwrites with it' {
            $pl  = Join-Path $root 'list.m3u'
            $out = Join-Path $root 'list_updated.m3u'
            (Join-Path $album 'song.mp3') | Set-Content -LiteralPath $pl
            'old content' | Set-Content -LiteralPath $out

            Update-M3UPath $pl -Extension opus -Quiet -ErrorAction SilentlyContinue | Out-Null
            (Get-Content -LiteralPath $out) | Should -Be 'old content'

            Update-M3UPath $pl -Extension opus -Quiet -Force | Out-Null
            (Get-Content -LiteralPath $out) | Should -Be @((Join-Path $album 'song.opus'))
        }

        It 'does not write anything under -WhatIf' {
            $pl = Join-Path $root 'list.m3u'
            (Join-Path $album 'song.mp3') | Set-Content -LiteralPath $pl

            Update-M3UPath $pl -Extension opus -Quiet -WhatIf | Out-Null

            Test-Path (Join-Path $root 'list_updated.m3u') | Should -BeFalse
        }
    }

    Context 'faithful output' {

        It 'keeps relative entries relative' {
            # Playlist lives in the album folder and uses bare relative names.
            $pl = Join-Path $album 'list.m3u'
            @('song.mp3', 'keep.flac') | Set-Content -LiteralPath $pl

            Update-M3UPath $pl -Extension opus -Quiet | Out-Null

            (Get-Content -LiteralPath (Join-Path $album 'list_updated.m3u')) |
                Should -Be @('song.opus', 'keep.flac')
        }

        It 'preserves #EXTINF metadata for an extended playlist' {
            $pl = Join-Path $root 'ext.m3u8'
            @(
                '#EXTM3U'
                '#EXTINF:215,My Song'
                (Join-Path $album 'song.mp3')
            ) | Set-Content -LiteralPath $pl

            Update-M3UPath $pl -Extension opus -Quiet | Out-Null

            $lines = Get-Content -LiteralPath (Join-Path $root 'ext_updated.m3u8')
            $lines[0] | Should -Be '#EXTM3U'
            $lines[1] | Should -Be '#EXTINF:215,My Song'
            $lines[2] | Should -Be (Join-Path $album 'song.opus')
        }

        It 'writes a plain playlist when the source is plain' {
            $pl = Join-Path $root 'plain.m3u'
            (Join-Path $album 'song.mp3') | Set-Content -LiteralPath $pl

            Update-M3UPath $pl -Extension opus -Quiet | Out-Null

            (Get-Content -LiteralPath (Join-Path $root 'plain_updated.m3u') -Raw) |
                Should -Not -Match '#EXT'
        }

        It 'preserves LF line endings from the source' {
            $pl = Join-Path $root 'lf.m3u'
            [IO.File]::WriteAllText($pl, ((Join-Path $album 'song.mp3') + "`n" + (Join-Path $album 'keep.flac')))

            Update-M3UPath $pl -Extension opus -Quiet | Out-Null

            $raw = [IO.File]::ReadAllText((Join-Path $root 'lf_updated.m3u'))
            $raw | Should -Not -Match "`r"
            $raw | Should -Be ((Join-Path $album 'song.opus') + "`n" + (Join-Path $album 'keep.flac'))
        }
    }

    Context 'host summary' {

        It 'reports found, updated, and missing counts' {
            $pl = Join-Path $root 'list.m3u'
            @(
                (Join-Path $album 'song.mp3')
                (Join-Path $album 'keep.flac')
                (Join-Path $album 'gone.mp3')
            ) | Set-Content -LiteralPath $pl

            $text = Update-M3UPath $pl -Extension opus 6>&1 | Out-String

            $text | Should -Match '2 of 3 entries OK \(1 found, 1 updated to \.opus\), 1 missing'
        }
    }

    Context 'input validation' {

        It 'errors on a missing playlist' {
            { Update-M3UPath (Join-Path $root 'nope.m3u') -Extension opus -ErrorAction Stop } | Should -Throw
        }
    }
}
