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

    Context 'multi-disc (disc-prefixed) numbering' {

        BeforeEach {
            # Get-AudioTags is piped the folder's files, so the mock runs once per
            # file. Keep a single file so each mock's tag list is seen exactly once
            # (duplicates are significant here).
            Get-ChildItem -LiteralPath $album -File | Select-Object -Skip 1 | Remove-Item -Force
        }

        It 'accepts complete 1xx/2xx disc-prefixed numbering' {
            Mock -ModuleName PwshMusicTools Get-AudioTags {
                @(101, 102, 103, 201, 202, 203, 204 | ForEach-Object { [PSCustomObject]@{ Track = $_ } })
            }

            $result = @(Invoke-IncomingMusic -Path $root -CheckTrackNumbering 3>$null 6>$null |
                        Where-Object { $_.Step -eq 'CheckTrackNumbering' })

            $result.Complete     | Should -BeTrue
            $result.Missing      | Should -BeNullOrEmpty
            $result.Discs        | Should -Be @(1, 2)
            $result.MissingDiscs | Should -BeNullOrEmpty
        }

        It 'does not warn about a complete multi-disc folder' {
            Mock -ModuleName PwshMusicTools Get-AudioTags {
                @(101, 102, 201, 202 | ForEach-Object { [PSCustomObject]@{ Track = $_ } })
            }

            $warnings = Invoke-IncomingMusic -Path $root -CheckTrackNumbering 3>&1 6>$null |
                        Where-Object { $_ -is [System.Management.Automation.WarningRecord] }

            $warnings | Should -BeNullOrEmpty
        }

        It 'reports a gap within a disc and names the disc' {
            Mock -ModuleName PwshMusicTools Get-AudioTags {
                @(101, 102, 103, 201, 202, 204 | ForEach-Object { [PSCustomObject]@{ Track = $_ } })
            }

            $output = @(Invoke-IncomingMusic -Path $root -CheckTrackNumbering 3>&1 6>$null)
            $result   = @($output | Where-Object { $_.PSObject.Properties['Step'] -and $_.Step -eq 'CheckTrackNumbering' })
            $warnings = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })

            $result.Complete | Should -BeFalse
            $result.Missing  | Should -Be @(203)
            ($warnings | Out-String) | Should -Match 'disc 2 is missing track\(s\): 3\b'
            ($warnings | Out-String) | Should -Not -Match 'disc 1'
        }

        It 'reports a disc that does not start at track 01' {
            Mock -ModuleName PwshMusicTools Get-AudioTags {
                @(101, 102, 202, 203 | ForEach-Object { [PSCustomObject]@{ Track = $_ } })
            }

            $result = @(Invoke-IncomingMusic -Path $root -CheckTrackNumbering 3>$null 6>$null |
                        Where-Object { $_.Step -eq 'CheckTrackNumbering' })

            $result.Complete | Should -BeFalse
            $result.Missing  | Should -Be @(201)
        }

        It 'reports duplicate tracks within a disc' {
            Mock -ModuleName PwshMusicTools Get-AudioTags {
                @(101, 102, 102, 201 | ForEach-Object { [PSCustomObject]@{ Track = $_ } })
            }

            $output = @(Invoke-IncomingMusic -Path $root -CheckTrackNumbering 3>&1 6>$null)
            $result   = @($output | Where-Object { $_.PSObject.Properties['Step'] -and $_.Step -eq 'CheckTrackNumbering' })
            $warnings = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })

            $result.Complete   | Should -BeFalse
            $result.Duplicates | Should -Be @(102)
            ($warnings | Out-String) | Should -Match 'disc 1 has duplicate track\(s\): 2\b'
        }

        It 'reports a missing disc' {
            Mock -ModuleName PwshMusicTools Get-AudioTags {
                @(101, 102, 301, 302 | ForEach-Object { [PSCustomObject]@{ Track = $_ } })
            }

            $output = @(Invoke-IncomingMusic -Path $root -CheckTrackNumbering 3>&1 6>$null)
            $result   = @($output | Where-Object { $_.PSObject.Properties['Step'] -and $_.Step -eq 'CheckTrackNumbering' })
            $warnings = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })

            $result.Complete     | Should -BeFalse
            $result.Discs        | Should -Be @(1, 3)
            $result.MissingDiscs | Should -Be @(2)
            $result.Missing      | Should -BeNullOrEmpty
            ($warnings | Out-String) | Should -Match 'missing disc\(s\): 2\b'
        }

        It 'still flags a folder mixing plain and disc-prefixed numbers' {
            Mock -ModuleName PwshMusicTools Get-AudioTags {
                @(1, 2, 3, 101, 102 | ForEach-Object { [PSCustomObject]@{ Track = $_ } })
            }

            $result = @(Invoke-IncomingMusic -Path $root -CheckTrackNumbering 3>$null 6>$null |
                        Where-Object { $_.Step -eq 'CheckTrackNumbering' })

            $result.Complete | Should -BeFalse
            $result.Discs    | Should -BeNullOrEmpty
        }

        It 'treats a real 100+ track single disc as plain numbering' {
            Mock -ModuleName PwshMusicTools Get-AudioTags {
                @(1..120 | ForEach-Object { [PSCustomObject]@{ Track = $_ } })
            }

            $result = @(Invoke-IncomingMusic -Path $root -CheckTrackNumbering 3>$null 6>$null |
                        Where-Object { $_.Step -eq 'CheckTrackNumbering' })

            $result.Complete | Should -BeTrue
            $result.Max      | Should -Be 120
            $result.Discs    | Should -BeNullOrEmpty
        }
    }
}
