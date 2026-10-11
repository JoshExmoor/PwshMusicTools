BeforeAll {
    . $PSScriptRoot/TestHelpers.ps1
    Import-PwshMusicTools
}

Describe 'Sync-SongFiles' {

    BeforeEach {
        $script:root = New-TestDir
        $script:ren  = Join-Path $root 'rename'
        $script:ref  = Join-Path $root 'reference'
        New-Item -ItemType Directory -Path $ren, $ref -Force | Out-Null
    }

    AfterEach {
        Remove-TestDir -Path $script:root
    }

    Context 'basic renaming by track number' {

        It 'renames rename-folder files to match the reference names' {
            New-EmptyFile -Dir $ref -Name '01 First Song.flac' | Out-Null
            New-EmptyFile -Dir $ref -Name '02 Second Song.flac' | Out-Null
            New-EmptyFile -Dir $ren -Name '1 first song.flac'   | Out-Null
            New-EmptyFile -Dir $ren -Name '2 second song.flac'  | Out-Null

            Sync-SongFiles -RenameDir $ren -ReferenceDir $ref -Confirm:$false

            Get-FileNames -Dir $ren | Should -Be @('01 First Song.flac', '02 Second Song.flac')
        }

        It 'treats "1" and "01" as the same track' {
            New-EmptyFile -Dir $ref -Name '01 Song.flac' | Out-Null
            New-EmptyFile -Dir $ren -Name '1 song.flac'  | Out-Null

            Sync-SongFiles -RenameDir $ren -ReferenceDir $ref -Confirm:$false

            Test-Path (Join-Path $ren '01 Song.flac') | Should -BeTrue
            Test-Path (Join-Path $ren '1 song.flac')  | Should -BeFalse
        }

        It 'never modifies the reference folder' {
            New-EmptyFile -Dir $ref -Name '01 Reference Name.flac' | Out-Null
            New-EmptyFile -Dir $ren -Name '1 other name.flac'      | Out-Null

            Sync-SongFiles -RenameDir $ren -ReferenceDir $ref -Confirm:$false

            Get-FileNames -Dir $ref | Should -Be @('01 Reference Name.flac')
        }
    }

    Context '-WhatIf' {

        It 'does not rename anything under -WhatIf' {
            New-EmptyFile -Dir $ref -Name '01 First Song.flac' | Out-Null
            New-EmptyFile -Dir $ren -Name '1 first song.flac'  | Out-Null

            Sync-SongFiles -RenameDir $ren -ReferenceDir $ref -WhatIf

            Get-FileNames -Dir $ren | Should -Be @('1 first song.flac')
        }
    }

    Context 'extension handling' {

        It 'skips a pair whose extensions differ by default' {
            New-EmptyFile -Dir $ref -Name '01 Song.mp3'  | Out-Null
            New-EmptyFile -Dir $ren -Name '1 song.flac'  | Out-Null

            Sync-SongFiles -RenameDir $ren -ReferenceDir $ref -Confirm:$false -WarningAction SilentlyContinue

            # Unchanged: the .flac was not renamed to the .mp3 name.
            Get-FileNames -Dir $ren | Should -Be @('1 song.flac')
        }

        It 'pairs across extensions with -IgnoreExtension and keeps the original extension' {
            New-EmptyFile -Dir $ref -Name '01 Proper Title.mp3' | Out-Null
            New-EmptyFile -Dir $ren -Name '1 proper title.flac' | Out-Null

            Sync-SongFiles -RenameDir $ren -ReferenceDir $ref -IgnoreExtension -Confirm:$false

            # Base name matches the reference, extension stays .flac.
            Get-FileNames -Dir $ren | Should -Be @('01 Proper Title.flac')
        }
    }

    Context 'duplicate track numbers' {

        It 'skips a track that appears more than once in the rename folder' {
            New-EmptyFile -Dir $ref -Name '01 Song.flac'    | Out-Null
            New-EmptyFile -Dir $ren -Name '01 version a.flac' | Out-Null
            New-EmptyFile -Dir $ren -Name '1 version b.flac'  | Out-Null

            Sync-SongFiles -RenameDir $ren -ReferenceDir $ref -Confirm:$false -WarningAction SilentlyContinue

            # Neither duplicate is renamed (would collide on the same target name).
            Get-FileNames -Dir $ren | Should -Be @('01 version a.flac', '1 version b.flac')
        }

        It 'skips a track matched by multiple reference files' {
            New-EmptyFile -Dir $ref -Name '01 ref one.flac' | Out-Null
            New-EmptyFile -Dir $ref -Name '1 ref two.flac'  | Out-Null
            New-EmptyFile -Dir $ren -Name '1 song.flac'     | Out-Null

            Sync-SongFiles -RenameDir $ren -ReferenceDir $ref -Confirm:$false -WarningAction SilentlyContinue

            Get-FileNames -Dir $ren | Should -Be @('1 song.flac')
        }
    }

    Context 'title similarity guard' {

        It 'skips a number-matched pair whose titles are too dissimilar' {
            # Same track number, completely different titles -> likely different releases.
            New-EmptyFile -Dir $ref -Name '01 Completely Different Title.flac' | Out-Null
            New-EmptyFile -Dir $ren -Name '1 totally unrelated song name.flac' | Out-Null

            Sync-SongFiles -RenameDir $ren -ReferenceDir $ref -Confirm:$false -WarningAction SilentlyContinue

            Get-FileNames -Dir $ren | Should -Be @('1 totally unrelated song name.flac')
        }

        It 'renames the dissimilar pair when the threshold is disabled (0)' {
            New-EmptyFile -Dir $ref -Name '01 Completely Different Title.flac' | Out-Null
            New-EmptyFile -Dir $ren -Name '1 totally unrelated song name.flac' | Out-Null

            Sync-SongFiles -RenameDir $ren -ReferenceDir $ref -TitleMatchThreshold 0 -Confirm:$false

            Get-FileNames -Dir $ren | Should -Be @('01 Completely Different Title.flac')
        }
    }

    Context 'no-op cases' {

        It 'changes nothing when names already match' {
            New-EmptyFile -Dir $ref -Name '01 Song.flac' | Out-Null
            New-EmptyFile -Dir $ren -Name '01 Song.flac' | Out-Null

            Sync-SongFiles -RenameDir $ren -ReferenceDir $ref -Confirm:$false

            Get-FileNames -Dir $ren | Should -Be @('01 Song.flac')
        }

        It 'warns and does nothing when the rename folder has no audio files' {
            New-EmptyFile -Dir $ref -Name '01 Song.flac' | Out-Null
            New-EmptyFile -Dir $ren -Name 'notes.txt'    | Out-Null

            Sync-SongFiles -RenameDir $ren -ReferenceDir $ref -Confirm:$false -WarningAction SilentlyContinue

            Get-FileNames -Dir $ren | Should -Be @('notes.txt')
        }
    }

    Context 'input validation' {

        It 'errors when the rename directory does not exist' {
            { Sync-SongFiles -RenameDir (Join-Path $root 'nope') -ReferenceDir $ref -Confirm:$false -ErrorAction Stop } |
                Should -Throw
        }
    }
}
