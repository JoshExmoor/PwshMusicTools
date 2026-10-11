BeforeAll {
    . $PSScriptRoot/TestHelpers.ps1
    Import-PwshMusicTools
}

Describe 'Invoke-IncomingMusic -CheckTrackNumbering' {

    BeforeEach {
        $script:root  = New-TestDir
        $script:album = Join-Path $root 'Album'
        # The files' names don't matter; the mock supplies the Track tags.
        1..3 | ForEach-Object { New-EmptyFile -Dir $album -Name ("{0}.flac" -f $_) | Out-Null }
    }

    AfterEach {
        Remove-TestDir -Path $script:root
    }

    It 'reports complete when tracks are a full 1..N run' {
        Mock -ModuleName PwshMusicTools Get-AudioTags {
            @(
                [PSCustomObject]@{ Track = 1 }
                [PSCustomObject]@{ Track = 2 }
                [PSCustomObject]@{ Track = 3 }
            )
        }

        $result = @(Invoke-IncomingMusic -Path $root -CheckTrackNumbering 6>$null |
                    Where-Object { $_.Step -eq 'CheckTrackNumbering' })

        $result.Complete | Should -BeTrue
        $result.Missing  | Should -BeNullOrEmpty
        $result.Max      | Should -Be 3
    }

    It 'reports the missing track numbers when there is a gap' {
        Mock -ModuleName PwshMusicTools Get-AudioTags {
            @(
                [PSCustomObject]@{ Track = 1 }
                [PSCustomObject]@{ Track = 2 }
                [PSCustomObject]@{ Track = 5 }
            )
        }

        $result = @(Invoke-IncomingMusic -Path $root -CheckTrackNumbering 6>$null |
                    Where-Object { $_.Step -eq 'CheckTrackNumbering' })

        $result.Complete | Should -BeFalse
        $result.Max      | Should -Be 5
        $result.Missing  | Should -Be @(3, 4)
    }

    It 'normalizes 01 and 001 to the same integer track' {
        Mock -ModuleName PwshMusicTools Get-AudioTags {
            @(
                [PSCustomObject]@{ Track = 1 }    # "001"
                [PSCustomObject]@{ Track = 2 }    # "02"
                [PSCustomObject]@{ Track = 3 }
            )
        }

        $result = @(Invoke-IncomingMusic -Path $root -CheckTrackNumbering 6>$null |
                    Where-Object { $_.Step -eq 'CheckTrackNumbering' })

        $result.Complete | Should -BeTrue
    }

    It 'emits a warning when a folder has a gap' {
        Mock -ModuleName PwshMusicTools Get-AudioTags {
            @([PSCustomObject]@{ Track = 1 }, [PSCustomObject]@{ Track = 3 })
        }

        $warnings = Invoke-IncomingMusic -Path $root -CheckTrackNumbering 3>&1 6>$null |
                    Where-Object { $_ -is [System.Management.Automation.WarningRecord] }

        ($warnings | Out-String) | Should -Match 'missing track'
    }

    It 'warns when there are no track numbers at all' {
        Mock -ModuleName PwshMusicTools Get-AudioTags {
            @([PSCustomObject]@{ Track = 0 }, [PSCustomObject]@{ Track = 0 })
        }

        $warnings = Invoke-IncomingMusic -Path $root -CheckTrackNumbering 3>&1 6>$null |
                    Where-Object { $_ -is [System.Management.Automation.WarningRecord] }

        ($warnings | Out-String) | Should -Match 'no track numbers'
    }

    It 'changes nothing on disk (report-only)' {
        Mock -ModuleName PwshMusicTools Get-AudioTags {
            @([PSCustomObject]@{ Track = 1 }, [PSCustomObject]@{ Track = 3 })
        }
        $before = @(Get-ChildItem -LiteralPath $album -File | Select-Object -ExpandProperty Name | Sort-Object)

        Invoke-IncomingMusic -Path $root -CheckTrackNumbering -Confirm:$false 6>$null | Out-Null

        $after = @(Get-ChildItem -LiteralPath $album -File | Select-Object -ExpandProperty Name | Sort-Object)
        $after | Should -Be $before
    }
}
