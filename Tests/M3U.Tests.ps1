BeforeAll {
    . $PSScriptRoot/TestHelpers.ps1
    Import-PwshMusicTools
}

Describe 'Export-M3U / Import-M3U' {

    BeforeEach {
        $script:root = New-TestDir
    }

    AfterEach {
        Remove-TestDir -Path $script:root
    }

    Context 'Export-M3U' {

        It 'writes bare paths for a plain playlist' {
            $pl = Join-Path $root 'plain.m3u'
            @('C:\Music\a.flac', 'C:\Music\b.flac') | Export-M3U $pl

            $lines = Get-Content -LiteralPath $pl
            $lines | Should -Be @('C:\Music\a.flac', 'C:\Music\b.flac')
        }

        It 'writes an #EXTM3U header and #EXTINF lines with -Extended' {
            $pl = Join-Path $root 'ext.m3u8'
            [PSCustomObject]@{ Path = 'C:\Music\song.flac'; Duration = 215; Title = 'Song' } |
                Export-M3U $pl -Extended

            $lines = Get-Content -LiteralPath $pl
            $lines[0] | Should -Be '#EXTM3U'
            $lines[1] | Should -Be '#EXTINF:215,Song'
            $lines[2] | Should -Be 'C:\Music\song.flac'
        }

        It 'accepts FileInfo objects from Get-ChildItem' {
            $d = Join-Path $root 'album'
            New-EmptyFile -Dir $d -Name '01 a.flac' | Out-Null
            New-EmptyFile -Dir $d -Name '02 b.flac' | Out-Null
            $pl = Join-Path $root 'from-gci.m3u'

            Get-ChildItem -LiteralPath $d -Filter *.flac | Export-M3U $pl

            (Get-Content -LiteralPath $pl).Count | Should -Be 2
        }

        It 'refuses to overwrite without -Force' {
            $pl = Join-Path $root 'exists.m3u'
            'placeholder' | Set-Content -LiteralPath $pl
            { @('x') | Export-M3U $pl -ErrorAction Stop } | Should -Throw
        }

        It 'overwrites with -Force' {
            $pl = Join-Path $root 'exists.m3u'
            'placeholder' | Set-Content -LiteralPath $pl

            @('C:\Music\new.flac') | Export-M3U $pl -Force

            Get-Content -LiteralPath $pl | Should -Be @('C:\Music\new.flac')
        }
    }

    Context 'Export-M3U -LineEnding' {

        It 'writes LF-only line endings with -LineEnding LF' {
            $pl = Join-Path $root 'lf.m3u8'
            @('a.flac', 'b.flac') | Export-M3U $pl -LineEnding LF

            $raw = [System.IO.File]::ReadAllText($pl)
            $raw | Should -Not -Match "`r"           # no carriage returns at all
            $raw | Should -Be "a.flac`nb.flac"
        }

        It 'writes CRLF line endings with -LineEnding CRLF (default)' {
            $pl = Join-Path $root 'crlf.m3u8'
            @('a.flac', 'b.flac') | Export-M3U $pl -LineEnding CRLF

            $raw = [System.IO.File]::ReadAllText($pl)
            $raw | Should -Be "a.flac`r`nb.flac"
        }

        It 'defaults to CRLF when -LineEnding is omitted' {
            $pl = Join-Path $root 'default.m3u8'
            @('a.flac', 'b.flac') | Export-M3U $pl

            $raw = [System.IO.File]::ReadAllText($pl)
            $raw | Should -Be "a.flac`r`nb.flac"
        }

        It 'applies the line ending to #EXTINF lines too' {
            $pl = Join-Path $root 'ext-lf.m3u8'
            [PSCustomObject]@{ Path = 'song.flac'; Duration = 100; Title = 'Song' } |
                Export-M3U $pl -Extended -LineEnding LF

            $raw = [System.IO.File]::ReadAllText($pl)
            $raw | Should -Be "#EXTM3U`n#EXTINF:100,Song`nsong.flac"
        }
    }

    Context 'Import-M3U' {

        It 'returns one object per entry and skips comments and blank lines' {
            $pl = Join-Path $root 'in.m3u'
            @(
                '#EXTM3U'
                ''
                'C:\Music\a.flac'
                '# a stray comment'
                'C:\Music\b.flac'
            ) | Set-Content -LiteralPath $pl

            $entries = @(Import-M3U $pl)

            $entries.Count | Should -Be 2
            $entries[0].Path | Should -Be 'C:\Music\a.flac'
            $entries[1].Path | Should -Be 'C:\Music\b.flac'
            $entries[1].Line | Should -Be 2
        }

        It 'parses #EXTINF duration and title' {
            $pl = Join-Path $root 'ext-in.m3u8'
            @(
                '#EXTM3U'
                '#EXTINF:183,Great Song'
                'C:\Music\great.flac'
            ) | Set-Content -LiteralPath $pl

            $entry = Import-M3U $pl

            $entry.Duration | Should -Be 183
            $entry.Title    | Should -Be 'Great Song'
        }

        It 'reports Duration -1 and null Title for a plain entry' {
            $pl = Join-Path $root 'plain-in.m3u'
            'C:\Music\plain.flac' | Set-Content -LiteralPath $pl

            $entry = Import-M3U $pl

            $entry.Duration | Should -Be -1
            $entry.Title    | Should -BeNullOrEmpty
        }

        It 'resolves relative entries against the playlist directory with -Resolve' {
            $d = Join-Path $root 'album'
            New-EmptyFile -Dir $d -Name 'track.flac' | Out-Null
            $pl = Join-Path $d 'list.m3u'
            'track.flac' | Set-Content -LiteralPath $pl

            $entry = Import-M3U $pl -Resolve

            $entry.Path | Should -Be (Join-Path $d 'track.flac')
        }

        It 'errors on a missing playlist' {
            { Import-M3U (Join-Path $root 'nope.m3u') -ErrorAction Stop } | Should -Throw
        }
    }

    Context 'round-trip' {

        It 'preserves paths, durations, and titles through export then import' {
            $src = Join-Path $root 'src.m3u8'
            @(
                '#EXTM3U'
                '#EXTINF:100,First'
                'C:\Music\first.flac'
                '#EXTINF:200,Second'
                'C:\Music\second.flac'
            ) | Set-Content -LiteralPath $src

            $dst = Join-Path $root 'dst.m3u8'
            Import-M3U $src | Export-M3U $dst -Extended -Force
            $round = @(Import-M3U $dst)

            $round.Count | Should -Be 2
            $round[0].Path     | Should -Be 'C:\Music\first.flac'
            $round[0].Duration | Should -Be 100
            $round[0].Title    | Should -Be 'First'
            $round[1].Title    | Should -Be 'Second'
        }
    }
}
