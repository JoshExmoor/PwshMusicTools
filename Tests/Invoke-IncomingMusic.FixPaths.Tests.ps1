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

Describe 'Invoke-IncomingMusic -FixPaths' {

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

            Invoke-IncomingMusic -Path $root -FixPaths -Confirm:$false 6>$null | Out-Null

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

                    Invoke-IncomingMusic -Path $root2 -FixPaths -Confirm:$false 6>$null | Out-Null

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

            $warnings = Invoke-IncomingMusic -Path $root -FixPaths -Confirm:$false 3>&1 6>$null |
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

            Invoke-IncomingMusic -Path $root -FixPaths -Confirm:$false 6>$null | Out-Null

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

            Invoke-IncomingMusic -Path $root -FixPaths -Confirm:$false 6>$null | Out-Null

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

            $results = @(Invoke-IncomingMusic -Path $root -FixPaths -Confirm:$false 6>$null |
                         Where-Object { $_.Step -eq 'FixPaths' -and $_.Directory -like '*Revolver' })

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

            $warnings = Invoke-IncomingMusic -Path $root -FixPaths -Confirm:$false 3>&1 6>$null |
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

            Invoke-IncomingMusic -Path $root -FixPaths -WhatIf 6>$null | Out-Null

            Test-Path $album | Should -BeTrue
            Test-Path (Join-Path $root 'The Beatles\Revolver') | Should -BeFalse
        }
    }
}
