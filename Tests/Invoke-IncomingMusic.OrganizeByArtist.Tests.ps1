BeforeAll {
    . $PSScriptRoot/TestHelpers.ps1
    Import-PwshMusicTools

    # Build an album folder of empty audio files under a given relative subpath.
    # Defined in BeforeAll so it is visible to all It blocks in Pester v5+.
    function New-Album {
        param([string]$Relative, [string[]]$Files = @('01 a.flac', '02 b.flac'))
        $dir = Join-Path $script:root $Relative
        foreach ($f in $Files) { New-EmptyFile -Dir $dir -Name $f | Out-Null }
        return $dir
    }
}

Describe 'Invoke-IncomingMusic -OrganizeByArtist' {

    BeforeEach {
        $script:root = New-TestDir
    }

    AfterEach {
        Remove-TestDir -Path $script:root
    }

    Context 'AlbumArtist consensus' {

        It 'moves a folder under Path\AlbumArtist\folder when AlbumArtist is consistent' {
            $album = New-Album -Relative 'someuser\Revolver'
            Mock -ModuleName PwshMusicTools Get-AudioTags {
                $InputObject | ForEach-Object { [PSCustomObject]@{ AlbumArtist = 'The Beatles'; Artist = 'The Beatles'; Track = 1 } }
            }

            Invoke-IncomingMusic -Path $root -OrganizeByArtist -Confirm:$false 6>$null | Out-Null

            Test-Path (Join-Path $root 'The Beatles\Revolver') | Should -BeTrue
            Test-Path $album | Should -BeFalse
        }

        It 'moves Various Artists aliases into a Various Artists folder' {
            foreach ($va in 'Various Artists', 'Various', 'VA') {
                $root2 = New-TestDir
                try {
                    $album = Join-Path $root2 'comp'
                    New-EmptyFile -Dir $album -Name '01 x.flac' | Out-Null
                    Mock -ModuleName PwshMusicTools Get-AudioTags {
                        $InputObject | ForEach-Object { [PSCustomObject]@{ AlbumArtist = $va; Artist = 'Someone'; Track = 1 } }
                    }.GetNewClosure()

                    Invoke-IncomingMusic -Path $root2 -OrganizeByArtist -Confirm:$false 6>$null | Out-Null

                    Test-Path (Join-Path $root2 'Various Artists\comp') | Should -BeTrue -Because "alias '$va' should map to Various Artists"
                }
                finally { Remove-TestDir -Path $root2 }
            }
        }

        It 'skips with a warning when AlbumArtist is present but inconsistent' {
            $album = New-Album -Relative 'messy'
            Mock -ModuleName PwshMusicTools Get-AudioTags {
                @(
                    [PSCustomObject]@{ AlbumArtist = 'Artist One'; Artist = 'Artist One'; Track = 1 }
                    [PSCustomObject]@{ AlbumArtist = 'Artist Two'; Artist = 'Artist Two'; Track = 2 }
                )
            }

            $warnings = Invoke-IncomingMusic -Path $root -OrganizeByArtist -Confirm:$false 3>&1 6>$null |
                        Where-Object { $_ -is [System.Management.Automation.WarningRecord] }

            ($warnings | Out-String) | Should -Match 'inconsistent AlbumArtist'
            Test-Path $album | Should -BeTrue   # not moved
        }
    }

    Context 'Artist fallback when AlbumArtist is blank' {

        It 'uses Artist when AlbumArtist is blank and all Artists match' {
            $album = New-Album -Relative 'u\OK Computer'
            Mock -ModuleName PwshMusicTools Get-AudioTags {
                $InputObject | ForEach-Object { [PSCustomObject]@{ AlbumArtist = ''; Artist = 'Radiohead'; Track = 1 } }
            }

            Invoke-IncomingMusic -Path $root -OrganizeByArtist -Confirm:$false 6>$null | Out-Null

            Test-Path (Join-Path $root 'Radiohead\OK Computer') | Should -BeTrue
        }

        It 'uses Various Artists when AlbumArtist is blank and Artists differ' {
            $album = New-Album -Relative 'u\mixtape'
            Mock -ModuleName PwshMusicTools Get-AudioTags {
                @(
                    [PSCustomObject]@{ AlbumArtist = ''; Artist = 'Band One'; Track = 1 }
                    [PSCustomObject]@{ AlbumArtist = ''; Artist = 'Band Two'; Track = 2 }
                )
            }

            Invoke-IncomingMusic -Path $root -OrganizeByArtist -Confirm:$false 6>$null | Out-Null

            Test-Path (Join-Path $root 'Various Artists\mixtape') | Should -BeTrue
        }
    }

    Context 'skip conditions' {

        It 'skips a folder already placed under its artist folder' {
            # The album already lives under 'The Beatles'.
            $album = New-Album -Relative 'The Beatles\Revolver'
            Mock -ModuleName PwshMusicTools Get-AudioTags {
                $InputObject | ForEach-Object { [PSCustomObject]@{ AlbumArtist = 'The Beatles'; Artist = 'The Beatles'; Track = 1 } }
            }

            $results = @(Invoke-IncomingMusic -Path $root -OrganizeByArtist -Confirm:$false 6>$null |
                         Where-Object { $_.Step -eq 'OrganizeByArtist' -and $_.Directory -like '*Revolver' })

            # It should remain in place and be reported as not moved.
            Test-Path (Join-Path $root 'The Beatles\Revolver') | Should -BeTrue
            ($results | Where-Object { $_.Directory -like '*Revolver' }).Moved | Should -Not -Contain $true
        }

        It 'skips when the destination already exists' {
            $album = New-Album -Relative 'u\Revolver'
            # Pre-create the destination so the move must be refused.
            New-Item -ItemType Directory -Path (Join-Path $root 'The Beatles\Revolver') -Force | Out-Null
            Mock -ModuleName PwshMusicTools Get-AudioTags {
                $InputObject | ForEach-Object { [PSCustomObject]@{ AlbumArtist = 'The Beatles'; Artist = 'The Beatles'; Track = 1 } }
            }

            $warnings = Invoke-IncomingMusic -Path $root -OrganizeByArtist -Confirm:$false 3>&1 6>$null |
                        Where-Object { $_ -is [System.Management.Automation.WarningRecord] }

            ($warnings | Out-String) | Should -Match 'already exists'
            Test-Path $album | Should -BeTrue   # original left in place
        }
    }

    Context '-WhatIf' {

        It 'does not move anything under -WhatIf' {
            $album = New-Album -Relative 'u\Revolver'
            Mock -ModuleName PwshMusicTools Get-AudioTags {
                $InputObject | ForEach-Object { [PSCustomObject]@{ AlbumArtist = 'The Beatles'; Artist = 'The Beatles'; Track = 1 } }
            }

            Invoke-IncomingMusic -Path $root -OrganizeByArtist -WhatIf 6>$null | Out-Null

            Test-Path $album | Should -BeTrue
            Test-Path (Join-Path $root 'The Beatles\Revolver') | Should -BeFalse
        }
    }

    Context 'folders with corrupted files' {

        BeforeEach {
            Mock -ModuleName PwshMusicTools Get-AudioTags {
                [PSCustomObject]@{ AlbumArtist = 'Band'; Artist = 'Band'; Track = 1 }
            }
        }

        It 'does not move a folder holding a file flagged CORRUPTED by an earlier run, but moves clean ones' {
            $clean  = New-Album -Relative 'u\Clean'
            $broken = New-Album -Relative 'u\Broken' -Files @('01 a.flac', 'CORRUPTED 02 b.flac')

            $r = @(Invoke-IncomingMusic -Path $root -OrganizeByArtist -Confirm:$false 3>$null 6>$null)

            Test-Path $broken                        | Should -BeTrue    # left in place
            Test-Path (Join-Path $root 'Band\Broken') | Should -BeFalse
            Test-Path (Join-Path $root 'Band\Clean')  | Should -BeTrue    # clean folder still moved
            $held = $r | Where-Object { $_.Step -eq 'OrganizeByArtist' -and $_.Directory -eq $broken }
            $held.Moved  | Should -BeFalse
            $held.Reason | Should -Match 'corrupted'
        }

        It 'does not move a folder with a file -AudioIntegrity flags in the same run' {
            $bad  = New-Album -Relative 'u\Bad'
            $good = New-Album -Relative 'u\Good'
            Mock -ModuleName PwshMusicTools Get-Command { [PSCustomObject]@{ Name = $Name } } -ParameterFilter { $Name -in 'ffmpeg', 'ffprobe' }
            Mock -ModuleName PwshMusicTools Test-AudioIntegrity {
                if ($Path -like '*\Bad') {
                    [PSCustomObject]@{ File = (Join-Path $Path '02 b.flac'); Status = 'CORRUPT'; Detail = 'Invalid data found when processing input' }
                }
            }

            Invoke-IncomingMusic -Path $root -AudioIntegrity -OrganizeByArtist -Confirm:$false 3>$null 6>$null | Out-Null

            Test-Path (Join-Path $bad 'CORRUPTED 02 b.flac') | Should -BeTrue   # renamed in place
            Test-Path (Join-Path $root 'Band\Bad')           | Should -BeFalse  # not moved
            Test-Path (Join-Path $root 'Band\Good')          | Should -BeTrue
        }

        It 'reports a held-back folder as not moved under -WhatIf, before any rename has happened' {
            $bad = New-Album -Relative 'u\Bad'
            Mock -ModuleName PwshMusicTools Get-Command { [PSCustomObject]@{ Name = $Name } } -ParameterFilter { $Name -in 'ffmpeg', 'ffprobe' }
            Mock -ModuleName PwshMusicTools Test-AudioIntegrity {
                [PSCustomObject]@{ File = (Join-Path $Path '02 b.flac'); Status = 'ERROR'; Detail = 'decode failed' }
            }

            $r = @(Invoke-IncomingMusic -Path $root -AudioIntegrity -OrganizeByArtist -WhatIf 3>$null 6>$null)

            Test-Path (Join-Path $bad '02 b.flac') | Should -BeTrue   # -WhatIf: not renamed
            $held = $r | Where-Object { $_.Step -eq 'OrganizeByArtist' -and $_.Directory -eq $bad }
            $held.Reason | Should -Match 'corrupted'
        }

        It 'lists each held-back folder, file, status and error detail at the end of the run' {
            New-Album -Relative 'u\Clean' | Out-Null
            $bad = New-Album -Relative 'u\Bad'
            Mock -ModuleName PwshMusicTools Get-Command { [PSCustomObject]@{ Name = $Name } } -ParameterFilter { $Name -in 'ffmpeg', 'ffprobe' }
            Mock -ModuleName PwshMusicTools Test-AudioIntegrity {
                if ($Path -like '*\Bad') {
                    [PSCustomObject]@{ File = (Join-Path $Path '02 b.flac'); Status = 'CORRUPT'; Detail = 'FLAC MD5 mismatch: stored aaa, decoded bbb' }
                }
            }

            $out = (Invoke-IncomingMusic -Path $root -AudioIntegrity -OrganizeByArtist -Confirm:$false 3>&1 6>&1 | Out-String)

            $out | Should -Match 'NOT MOVED: 1 folder'
            $out | Should -Match ([regex]::Escape("Folder: $bad"))
            $out | Should -Match '\[CORRUPT\] CORRUPTED 02 b\.flac'
            $out | Should -Match 'FLAC MD5 mismatch: stored aaa, decoded bbb'
            # The report comes last, after the per-step summaries.
            $out.LastIndexOf('NOT MOVED') | Should -BeGreaterThan $out.LastIndexOf('OrganizeByArtist: moved')
        }

        It 'prints no held-back report when nothing is corrupted' {
            New-Album -Relative 'u\Clean' | Out-Null

            $out = (Invoke-IncomingMusic -Path $root -OrganizeByArtist -Confirm:$false 3>&1 6>&1 | Out-String)

            $out | Should -Not -Match 'NOT MOVED'
        }
    }

    Context '-OrganizeDestination' {

        It 'creates artist folders under the destination path, not the base path' {
            $album = New-Album -Relative 'incoming\Revolver'
            $dest  = New-TestDir
            try {
                Mock -ModuleName PwshMusicTools Get-AudioTags {
                    $InputObject | ForEach-Object { [PSCustomObject]@{ AlbumArtist = 'The Beatles'; Artist = 'The Beatles'; Track = 1 } }
                }

                Invoke-IncomingMusic -Path $root -OrganizeByArtist -OrganizeDestination $dest -Confirm:$false 6>$null | Out-Null

                # Moved under the destination, not under the base path.
                Test-Path (Join-Path $dest 'The Beatles\Revolver') | Should -BeTrue
                Test-Path (Join-Path $root 'The Beatles\Revolver') | Should -BeFalse
                Test-Path $album | Should -BeFalse
            }
            finally { Remove-TestDir -Path $dest }
        }

        It 'creates the destination path if it does not exist' {
            $album = New-Album -Relative 'incoming\OK Computer'
            $dest  = Join-Path (New-TestDir) 'library'   # does not exist yet
            try {
                Mock -ModuleName PwshMusicTools Get-AudioTags {
                    $InputObject | ForEach-Object { [PSCustomObject]@{ AlbumArtist = 'Radiohead'; Artist = 'Radiohead'; Track = 1 } }
                }

                Invoke-IncomingMusic -Path $root -OrganizeByArtist -OrganizeDestination $dest -Confirm:$false 6>$null | Out-Null

                Test-Path (Join-Path $dest 'Radiohead\OK Computer') | Should -BeTrue
            }
            finally { Remove-TestDir -Path (Split-Path $dest -Parent) }
        }
    }
}
