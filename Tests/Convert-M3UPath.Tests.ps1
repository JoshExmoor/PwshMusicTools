BeforeAll {
    . $PSScriptRoot/TestHelpers.ps1
    Import-PwshMusicTools
}

Describe 'Convert-M3UPath' {

    Context 'string input' {

        It 'rebases a Windows path onto a Unix base and flips separators' {
            $r = 'C:\mp3\album\song.mp3' | Convert-M3UPath -From 'C:\mp3' -To '/data/music' -ToStyle Unix
            $r | Should -Be '/data/music/album/song.mp3'
        }

        It 'rebases a Unix path onto a Windows base (reverse direction)' {
            $r = '/data/music/album/song.mp3' | Convert-M3UPath -From '/data/music' -To 'C:\mp3' -ToStyle Windows
            $r | Should -Be 'C:\mp3\album\song.mp3'
        }

        It 'matches the base case-insensitively' {
            $r = 'C:\MP3\Album\Song.mp3' | Convert-M3UPath -From 'c:\mp3' -To '/data/music' -ToStyle Unix
            $r | Should -Be '/data/music/Album/Song.mp3'
        }

        It 'normalizes trailing separators on the bases' {
            $r = 'C:\mp3\album\song.mp3' | Convert-M3UPath -From 'C:\mp3\' -To '/data/music/' -ToStyle Unix
            $r | Should -Be '/data/music/album/song.mp3'   # no doubled slash
        }

        It 'handles a nested structure below the base' {
            $r = 'C:\mp3\artist\album\disc1\01 song.mp3' |
                Convert-M3UPath -From 'C:\mp3' -To '/data/music' -ToStyle Unix
            $r | Should -Be '/data/music/artist/album/disc1/01 song.mp3'
        }

        It 'converts only the separators of a path not under the base' {
            # Not under 'C:\mp3': left in place, but separators still normalized.
            $r = 'D:\other\song.mp3' | Convert-M3UPath -From 'C:\mp3' -To '/data/music' -ToStyle Unix
            $r | Should -Be 'D:/other/song.mp3'
        }

        It 'rebases the base itself with no remainder' {
            $r = 'C:\mp3' | Convert-M3UPath -From 'C:\mp3' -To '/data/music' -ToStyle Unix
            $r | Should -Be '/data/music'
        }

        It 'defaults to Unix style' {
            $r = 'C:\mp3\song.mp3' | Convert-M3UPath -From 'C:\mp3' -To '/data/music'
            $r | Should -Be '/data/music/song.mp3'
        }

        It 'does not treat a sibling folder with the same prefix as under the base' {
            # 'C:\mp3extra' must NOT match base 'C:\mp3' (only a full segment boundary).
            $r = 'C:\mp3extra\song.mp3' | Convert-M3UPath -From 'C:\mp3' -To '/data/music' -ToStyle Unix
            $r | Should -Be 'C:/mp3extra/song.mp3'
        }
    }

    Context 'object input from Import-M3U' {

        It 'rewrites Path and preserves Duration and Title' {
            $entry = [PSCustomObject]@{ Path = 'C:\mp3\album\song.mp3'; Duration = 215; Title = 'Song'; Line = 1 }

            $r = $entry | Convert-M3UPath -From 'C:\mp3' -To '/data/music' -ToStyle Unix

            $r.Path     | Should -Be '/data/music/album/song.mp3'
            $r.Duration | Should -Be 215
            $r.Title    | Should -Be 'Song'
            $r.Line     | Should -Be 1
        }

        It 'processes multiple piped entries' {
            $entries = @(
                [PSCustomObject]@{ Path = 'C:\mp3\a.mp3'; Duration = 100; Title = 'A' }
                [PSCustomObject]@{ Path = 'C:\mp3\b.mp3'; Duration = 200; Title = 'B' }
            )

            $r = @($entries | Convert-M3UPath -From 'C:\mp3' -To '/data/music' -ToStyle Unix)

            $r.Count    | Should -Be 2
            $r[0].Path  | Should -Be '/data/music/a.mp3'
            $r[1].Path  | Should -Be '/data/music/b.mp3'
            $r[1].Title | Should -Be 'B'
        }
    }

    Context 'integration with Import-M3U / Export-M3U' {

        BeforeEach { $script:root = New-TestDir }
        AfterEach  { Remove-TestDir -Path $script:root }

        It 'round-trips a Windows playlist to a Linux one, preserving #EXTINF' {
            $win = Join-Path $root 'windows.m3u'
            @(
                '#EXTM3U'
                '#EXTINF:183,First Song'
                'C:\mp3\album\01 first.mp3'
                '#EXTINF:200,Second Song'
                'C:\mp3\album\02 second.mp3'
            ) | Set-Content -LiteralPath $win

            $linux = Join-Path $root 'linux.m3u8'
            Import-M3U $win |
                Convert-M3UPath -From 'C:\mp3' -To '/data/music' -ToStyle Unix |
                Export-M3U $linux -Extended -Force -LineEnding LF

            $out = @(Import-M3U $linux)
            $out.Count       | Should -Be 2
            $out[0].Path     | Should -Be '/data/music/album/01 first.mp3'
            $out[0].Duration | Should -Be 183
            $out[0].Title    | Should -Be 'First Song'
            $out[1].Path     | Should -Be '/data/music/album/02 second.mp3'
            $out[1].Title    | Should -Be 'Second Song'
        }
    }
}
