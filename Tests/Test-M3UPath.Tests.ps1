BeforeAll {
    . $PSScriptRoot/TestHelpers.ps1
    Import-PwshMusicTools
}

Describe 'Test-M3UPath' {

    BeforeEach {
        $script:root = New-TestDir
    }

    AfterEach {
        Remove-TestDir -Path $script:root
    }

    Context 'result objects' {

        It 'reports every path as existing when all files are present' {
            $d = Join-Path $root 'album'
            New-EmptyFile -Dir $d -Name 'a.flac' | Out-Null
            New-EmptyFile -Dir $d -Name 'b.flac' | Out-Null
            $pl = Join-Path $root 'all-good.m3u'
            @((Join-Path $d 'a.flac'), (Join-Path $d 'b.flac')) | Set-Content -LiteralPath $pl

            $results = @(Test-M3UPath $pl -Quiet)

            $results.Count | Should -Be 2
            ($results | Where-Object { $_.Exists }).Count | Should -Be 2
        }

        It 'flags a missing path as not existing' {
            $d = Join-Path $root 'album'
            New-EmptyFile -Dir $d -Name 'present.flac' | Out-Null
            $pl = Join-Path $root 'mixed.m3u'
            @((Join-Path $d 'present.flac'), (Join-Path $d 'missing.flac')) | Set-Content -LiteralPath $pl

            $results = @(Test-M3UPath $pl -Quiet)

            $results.Count | Should -Be 2
            ($results | Where-Object { $_.Path -like '*present.flac' }).Exists | Should -BeTrue
            ($results | Where-Object { $_.Path -like '*missing.flac' }).Exists | Should -BeFalse
        }

        It 'carries #EXTINF metadata and line numbers onto the results' {
            $d = Join-Path $root 'album'
            New-EmptyFile -Dir $d -Name 'song.flac' | Out-Null
            $pl = Join-Path $root 'ext.m3u8'
            @(
                '#EXTM3U'
                '#EXTINF:200,Great Song'
                (Join-Path $d 'song.flac')
            ) | Set-Content -LiteralPath $pl

            $result = Test-M3UPath $pl -Quiet

            $result.Duration | Should -Be 200
            $result.Title    | Should -Be 'Great Song'
            $result.Line     | Should -Be 1
            $result.Exists   | Should -BeTrue
        }

        It 'lets callers filter down to only the missing entries' {
            $d = Join-Path $root 'album'
            New-EmptyFile -Dir $d -Name 'ok.flac' | Out-Null
            $pl = Join-Path $root 'f.m3u'
            @((Join-Path $d 'ok.flac'), (Join-Path $d 'gone.flac')) | Set-Content -LiteralPath $pl

            $missing = @(Test-M3UPath $pl -Quiet | Where-Object { -not $_.Exists })

            $missing.Count | Should -Be 1
            $missing[0].Path | Should -BeLike '*gone.flac'
        }
    }

    Context 'relative path resolution' {

        It 'resolves relative entries against the playlist directory by default' {
            $d = Join-Path $root 'album'
            New-EmptyFile -Dir $d -Name 'track.flac' | Out-Null
            # Playlist lives in the album folder; entry is a bare relative name.
            $pl = Join-Path $d 'list.m3u'
            'track.flac' | Set-Content -LiteralPath $pl

            $result = Test-M3UPath $pl -Quiet

            $result.Exists | Should -BeTrue
            $result.Path   | Should -Be (Join-Path $d 'track.flac')
        }

        It 'tests the literal relative path with -NoResolve' {
            $d = Join-Path $root 'album'
            New-EmptyFile -Dir $d -Name 'track.flac' | Out-Null
            $pl = Join-Path $d 'list.m3u'
            'track.flac' | Set-Content -LiteralPath $pl

            # With -NoResolve the bare 'track.flac' is tested as-is (relative to the
            # current directory, not the playlist), so it will not be found here.
            $result = Test-M3UPath $pl -NoResolve -Quiet

            $result.Path | Should -Be 'track.flac'
        }
    }

    Context 'host summary' {

        It 'writes a summary line reflecting the good/total counts' {
            $d = Join-Path $root 'album'
            New-EmptyFile -Dir $d -Name 'a.flac' | Out-Null
            $pl = Join-Path $root 's.m3u'
            @((Join-Path $d 'a.flac'), (Join-Path $d 'nope.flac')) | Set-Content -LiteralPath $pl

            # Write-Host writes to the information stream (6); capture it there.
            $host6 = Test-M3UPath $pl 6>&1 | Out-String

            $host6 | Should -Match '1 of 2 paths exist'
        }

        It 'suppresses the summary with -Quiet' {
            $d = Join-Path $root 'album'
            New-EmptyFile -Dir $d -Name 'a.flac' | Out-Null
            $pl = Join-Path $root 'q.m3u'
            (Join-Path $d 'a.flac') | Set-Content -LiteralPath $pl

            $host6 = Test-M3UPath $pl -Quiet 6>&1 | Out-String

            $host6 | Should -Not -Match 'paths? exist'
        }
    }
}
