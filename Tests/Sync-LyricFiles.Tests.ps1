BeforeAll {
    . $PSScriptRoot/TestHelpers.ps1
    Import-PwshMusicTools

    # The user's example album: 12 opus tracks, cover.jpg, and lyric files named
    # 'Rocky Votolato - Suicide Medicine - NN - <Title>' with slightly different titles.
    $script:RockyAudio = @(
        '01 - The Light and The Sound', '02 - Suicide Medicine', "03 - I'll Catch You",
        '04 - Automatic Rifle', '05 - Every Red Cent', '06 - Montana', '07 - Alabaster',
        '08 - The City Is Calling', '09 - Secrets of a Salesman',
        '10 - Prison Is Private Property', '11 - Death-Right', '12 - Mix TapesCellmates'
    )
    $script:RockyLyricTitles = @(
        'The Light and The Sound', 'Suicide Medicine', "I'll Catch You", 'Automatic Rifle',
        'Every Red Cent', 'Montana', 'Alabaster', 'The City Is Calling', 'Secrets of a Salesman',
        'Prison Is Private Property (A Life of Your Own)', 'Death Right', 'Mix Tapes+Cellmates'
    )

    function New-RockyAlbum {
        param([string]$Dir, [string]$LyricExt = '.lrc', [string]$Sep = ' - ')
        foreach ($a in $script:RockyAudio) { New-EmptyFile -Dir $Dir -Name "$a.opus" | Out-Null }
        New-EmptyFile -Dir $Dir -Name 'cover.jpg' | Out-Null
        for ($i = 0; $i -lt 12; $i++) {
            $name = 'Rocky Votolato{0}Suicide Medicine{0}{1:D2}{0}{2}{3}' -f $Sep, ($i + 1), $script:RockyLyricTitles[$i], $LyricExt
            New-EmptyFile -Dir $Dir -Name $name | Out-Null
        }
    }

    function Get-RockyExpected {
        param([string]$LyricExt = '.lrc')
        @(@($script:RockyAudio | ForEach-Object { "$_.opus"; "$_$LyricExt" }) + 'cover.jpg' | Sort-Object)
    }
}

Describe 'Sync-LyricFiles' {

    BeforeEach {
        $script:root = New-TestDir
    }

    AfterEach {
        Remove-TestDir -Path $script:root
    }

    It 'is exported by the module' {
        (Get-Command -Module PwshMusicTools -Name Sync-LyricFiles).Name | Should -Be 'Sync-LyricFiles'
    }

    Context "the user's example album" {

        It 'renames all 12 lyric files by track number and leaves cover.jpg alone' {
            New-RockyAlbum -Dir $root

            $out = @(Sync-LyricFiles -Path $root -Confirm:$false)

            Get-FileNames -Dir $root | Should -Be (Get-RockyExpected)
            $out.Count | Should -Be 12
            @($out | Where-Object Renamed).Count | Should -Be 12
            @($out | Where-Object Method -ne 'TrackNumber').Count | Should -Be 0
            ($out | Where-Object Track -eq 10).NewName | Should -Be '10 - Prison Is Private Property.lrc'
        }

        It 'matches hyphen-only names without spaces' {
            New-RockyAlbum -Dir $root -Sep '-'

            Sync-LyricFiles -Path $root -Confirm:$false | Out-Null

            Get-FileNames -Dir $root | Should -Be (Get-RockyExpected)
        }

        It 'matches mixed separator forms' {
            New-EmptyFile -Dir $root -Name '01 - The Light and The Sound.opus' | Out-Null
            New-EmptyFile -Dir $root -Name '02 - Suicide Medicine.opus' | Out-Null
            New-EmptyFile -Dir $root -Name 'Rocky Votolato - Suicide Medicine-01-The Light and The Sound.lrc' | Out-Null
            New-EmptyFile -Dir $root -Name 'Rocky Votolato-Suicide Medicine - 02 - Suicide Medicine.lrc' | Out-Null

            Sync-LyricFiles -Path $root -Confirm:$false | Out-Null

            Get-FileNames -Dir $root | Should -Be @(
                '01 - The Light and The Sound.lrc', '01 - The Light and The Sound.opus',
                '02 - Suicide Medicine.lrc', '02 - Suicide Medicine.opus')
        }
    }

    Context '-LyricExtension' {

        It 'pairs .txt lyric files and ignores .lrc files' -TestCases @(@{ Ext = '.txt' }, @{ Ext = 'txt' }, @{ Ext = 'TXT' }) {
            param($Ext)
            New-RockyAlbum -Dir $root -LyricExt '.txt'
            New-EmptyFile -Dir $root -Name 'Other - 01 - Something.lrc' | Out-Null

            Sync-LyricFiles -Path $root -LyricExtension $Ext -Confirm:$false | Out-Null

            Get-FileNames -Dir $root | Should -Be (@(Get-RockyExpected -LyricExt '.txt') + 'Other - 01 - Something.lrc' | Sort-Object)
        }
    }

    Context '-Recurse and per-directory confirmation' {

        BeforeEach {
            $script:albumA = Join-Path $root 'Album A'
            $script:albumB = Join-Path $root 'Album B'
            foreach ($d in $albumA, $albumB) {
                New-EmptyFile -Dir $d -Name '01 - One.flac' | Out-Null
                New-EmptyFile -Dir $d -Name 'Artist - Album - 01 - One.lrc' | Out-Null
            }
            New-EmptyFile -Dir $root -Name '01 - Top.mp3' | Out-Null
            New-EmptyFile -Dir $root -Name 'Artist - Top - 01 - Top.lrc' | Out-Null
        }

        It 'processes every directory in the tree with -Recurse' {
            Sync-LyricFiles -Path $root -Recurse -Confirm:$false | Out-Null

            Get-FileNames -Dir $root   | Should -Be @('01 - Top.lrc', '01 - Top.mp3')
            Get-FileNames -Dir $albumA | Should -Be @('01 - One.flac', '01 - One.lrc')
            Get-FileNames -Dir $albumB | Should -Be @('01 - One.flac', '01 - One.lrc')
        }

        It 'only touches the top directory without -Recurse' {
            Sync-LyricFiles -Path $root -Confirm:$false | Out-Null

            Get-FileNames -Dir $root   | Should -Be @('01 - Top.lrc', '01 - Top.mp3')
            Get-FileNames -Dir $albumA | Should -Be @('01 - One.flac', 'Artist - Album - 01 - One.lrc')
        }

        It 'asks once per directory; accepting one and declining the other renames only the first' {
            Mock -ModuleName PwshMusicTools Confirm-ShouldProcess { $Target -like '*Album A*' }

            $out = @(Sync-LyricFiles -Path $albumA, $albumB)

            Should -Invoke -ModuleName PwshMusicTools Confirm-ShouldProcess -Times 2 -Exactly
            Get-FileNames -Dir $albumA | Should -Be @('01 - One.flac', '01 - One.lrc')
            Get-FileNames -Dir $albumB | Should -Be @('01 - One.flac', 'Artist - Album - 01 - One.lrc')
            ($out | Where-Object Directory -eq $albumB).Note | Should -Be 'Declined'
        }

        It 'continues to later directories after one is declined' {
            Mock -ModuleName PwshMusicTools Confirm-ShouldProcess { $Target -notlike "*'$root'*" }

            Sync-LyricFiles -Path $root -Recurse | Out-Null

            Get-FileNames -Dir $root   | Should -Be @('01 - Top.mp3', 'Artist - Top - 01 - Top.lrc')
            Get-FileNames -Dir $albumA | Should -Be @('01 - One.flac', '01 - One.lrc')
            Get-FileNames -Dir $albumB | Should -Be @('01 - One.flac', '01 - One.lrc')
        }
    }

    Context '-Path as a single file' {

        It 'processes only the named lyric file' {
            New-RockyAlbum -Dir $root
            $one = Join-Path $root 'Rocky Votolato - Suicide Medicine - 03 - I''ll Catch You.lrc'

            $out = @(Sync-LyricFiles -Path $one -Confirm:$false)

            $out.Count | Should -Be 1
            Test-Path -LiteralPath (Join-Path $root "03 - I'll Catch You.lrc") | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $root 'Rocky Votolato - Suicide Medicine - 01 - The Light and The Sound.lrc') | Should -BeTrue
        }

        It 'processes only the lyric file matching a named audio file' {
            New-RockyAlbum -Dir $root

            $out = @(Sync-LyricFiles -Path (Join-Path $root '06 - Montana.opus') -Confirm:$false)

            $out.Count | Should -Be 1
            Test-Path -LiteralPath (Join-Path $root '06 - Montana.lrc') | Should -BeTrue
        }
    }

    Context 'skipped and protected cases' {

        It 'skips a directory with more than one audio type' {
            New-EmptyFile -Dir $root -Name '01 - One.mp3'  | Out-Null
            New-EmptyFile -Dir $root -Name '02 - Two.flac' | Out-Null
            New-EmptyFile -Dir $root -Name 'A - B - 01 - One.lrc' | Out-Null

            Sync-LyricFiles -Path $root -Confirm:$false -WarningVariable w -WarningAction SilentlyContinue | Out-Null

            Get-FileNames -Dir $root | Should -Contain 'A - B - 01 - One.lrc'
            ($w -join ' ') | Should -Match 'more than one audio type'
        }

        It 'skips a duplicated audio track number but matches the rest' {
            New-EmptyFile -Dir $root -Name '01 - One.opus'    | Out-Null
            New-EmptyFile -Dir $root -Name '01 - One (Alt).opus' | Out-Null
            New-EmptyFile -Dir $root -Name '02 - Two.opus'    | Out-Null
            New-EmptyFile -Dir $root -Name 'A - B - 01 - One.lrc' | Out-Null
            New-EmptyFile -Dir $root -Name 'A - B - 02 - Two.lrc' | Out-Null

            Sync-LyricFiles -Path $root -Confirm:$false -WarningVariable w -WarningAction SilentlyContinue | Out-Null

            Get-FileNames -Dir $root | Should -Contain 'A - B - 01 - One.lrc'
            Get-FileNames -Dir $root | Should -Contain '02 - Two.lrc'
            ($w -join ' ') | Should -Match 'share track 1'
        }

        It 'skips a track claimed by two lyric files' {
            New-EmptyFile -Dir $root -Name '01 - One.opus' | Out-Null
            New-EmptyFile -Dir $root -Name 'A - B - 01 - One.lrc' | Out-Null
            New-EmptyFile -Dir $root -Name 'C - D - 01 - One.lrc' | Out-Null

            Sync-LyricFiles -Path $root -Confirm:$false -WarningAction SilentlyContinue | Out-Null

            Get-FileNames -Dir $root | Should -Be @('01 - One.opus', 'A - B - 01 - One.lrc', 'C - D - 01 - One.lrc')
        }

        It 'never overwrites an existing target' {
            New-EmptyFile -Dir $root -Name '01 - One.opus' | Out-Null
            $existing = New-EmptyFile -Dir $root -Name '01 - One.lrc'
            Set-Content -LiteralPath $existing -Value 'keep me'
            New-EmptyFile -Dir $root -Name 'A - B - 01 - One.lrc' | Out-Null

            $out = @(Sync-LyricFiles -Path $root -Confirm:$false -WarningVariable w -WarningAction SilentlyContinue)

            $out.Count | Should -Be 0
            Get-Content -LiteralPath $existing | Should -Be 'keep me'
            Get-FileNames -Dir $root | Should -Be @('01 - One.lrc', '01 - One.opus', 'A - B - 01 - One.lrc')
            ($w -join ' ') | Should -Match 'already exists'
        }

        It 'leaves an already correctly named lyric file alone' {
            New-EmptyFile -Dir $root -Name '01 - One.opus' | Out-Null
            New-EmptyFile -Dir $root -Name '01 - One.lrc'  | Out-Null

            $out = @(Sync-LyricFiles -Path $root -Confirm:$false)

            $out.Count | Should -Be 0
            Get-FileNames -Dir $root | Should -Be @('01 - One.lrc', '01 - One.opus')
        }

        It 'reports an unmatched lyric file and renames nothing for it' {
            New-EmptyFile -Dir $root -Name '01 - One.opus' | Out-Null
            New-EmptyFile -Dir $root -Name 'A - B - 07 - Seven.lrc' | Out-Null

            Sync-LyricFiles -Path $root -Confirm:$false -WarningVariable w -WarningAction SilentlyContinue | Out-Null

            Get-FileNames -Dir $root | Should -Be @('01 - One.opus', 'A - B - 07 - Seven.lrc')
            ($w -join ' ') | Should -Match 'track 7'
        }
    }

    Context 'numbers inside names' {

        It 'does not mistake numbers in the artist or title for the track number' {
            New-EmptyFile -Dir $root -Name '01 - Dumpweed.opus'     | Out-Null
            New-EmptyFile -Dir $root -Name '02 - 99 Problems.opus'  | Out-Null
            New-EmptyFile -Dir $root -Name '03 - 22.opus'           | Out-Null
            New-EmptyFile -Dir $root -Name 'Blink-182 - Enema - 01 - Dumpweed.lrc'    | Out-Null
            New-EmptyFile -Dir $root -Name 'Blink-182 - Enema - 02 - 99 Problems.lrc' | Out-Null
            New-EmptyFile -Dir $root -Name 'Blink-182 - Enema - 03 - 22.lrc'          | Out-Null

            Sync-LyricFiles -Path $root -Confirm:$false | Out-Null

            Get-FileNames -Dir $root | Should -Be @(
                '01 - Dumpweed.lrc', '01 - Dumpweed.opus', '02 - 99 Problems.lrc',
                '02 - 99 Problems.opus', '03 - 22.lrc', '03 - 22.opus')
        }

        It 'parses track numbers from common name forms' -TestCases @(
            @{ Name = '01 - Title.opus'; Expected = 1 }
            @{ Name = '01. Title.opus'; Expected = 1 }
            @{ Name = '01 Title 2 Remix.opus'; Expected = 1 }
            @{ Name = '02 - 22.opus'; Expected = 2 }
            @{ Name = 'Artist - Album - 10 - Title (Part 2).lrc'; Expected = 10 }
            @{ Name = 'Artist-Album-07-Title.lrc'; Expected = 7 }
            @{ Name = 'Blink-182 - Enema - 03 - Title.lrc'; Expected = 3 }
            @{ Name = 'Artist - 1979 - 04 - Title.lrc'; Expected = 4 }
            @{ Name = '101 - Title.flac'; Expected = 101 }
            @{ Name = '2-05 Title.flac'; Expected = 205 }
            @{ Name = 'Just A Title.lrc'; Expected = $null }
        ) {
            param($Name, $Expected)
            InModuleScope PwshMusicTools -Parameters @{ Name = $Name; Expected = $Expected } {
                param($Name, $Expected)
                Get-NameTrackNumber -Name $Name | Should -Be $Expected
            }
        }
    }

    Context 'title fallback' {

        It 'matches a lyric file without a track number on an exact normalised title' {
            New-EmptyFile -Dir $root -Name '01 - The Light and The Sound.opus' | Out-Null
            New-EmptyFile -Dir $root -Name '02 - Montana.opus' | Out-Null
            New-EmptyFile -Dir $root -Name 'Rocky Votolato - Suicide Medicine - montana.lrc' | Out-Null

            $out = @(Sync-LyricFiles -Path $root -Confirm:$false)

            $out[0].Method | Should -Be 'Title'
            Get-FileNames -Dir $root | Should -Contain '02 - Montana.lrc'
        }
    }

    Context 'declining and -WhatIf' {

        It 'renames nothing when the user declines' {
            New-RockyAlbum -Dir $root
            Mock -ModuleName PwshMusicTools Confirm-ShouldProcess { $false }

            $out = @(Sync-LyricFiles -Path $root)

            Get-FileNames -Dir $root | Should -Contain 'Rocky Votolato - Suicide Medicine - 01 - The Light and The Sound.lrc'
            @(Get-ChildItem -LiteralPath $root -Filter '0*.lrc').Count | Should -Be 0
            @($out | Where-Object Note -eq 'Declined').Count | Should -Be 12
        }

        It 'renames nothing under -WhatIf' {
            New-RockyAlbum -Dir $root

            $out = @(Sync-LyricFiles -Path $root -WhatIf)

            @(Get-ChildItem -LiteralPath $root -Filter '0*.lrc').Count | Should -Be 0
            @($out | Where-Object Note -eq 'WhatIf').Count | Should -Be 12
        }
    }

    Context 'input validation' {

        It 'errors when the path does not exist' {
            { Sync-LyricFiles -Path (Join-Path $root 'nope') -Confirm:$false -ErrorAction Stop } | Should -Throw
        }
    }
}
