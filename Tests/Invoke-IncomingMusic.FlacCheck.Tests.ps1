BeforeAll {
    . $PSScriptRoot/TestHelpers.ps1
    Import-PwshMusicTools

    function New-Album {
        param([string]$Relative, [string[]]$Files = @('01 a.flac', '02 b.flac'))
        $dir = Join-Path $script:root $Relative
        foreach ($f in $Files) { New-EmptyFile -Dir $dir -Name $f | Out-Null }
        return $dir
    }

    # Mocks for a run where flaccheck.exe, ffmpeg and ffprobe exist, the scan
    # "succeeds" by writing a small report, and nothing is really opened.
    function Initialize-FlacMocks {
        param([string]$ReportContent = '<html>report</html>')
        $global:FlacCalls = [System.Collections.Generic.List[object]]::new()
        $global:FlacOpened = [System.Collections.Generic.List[string]]::new()
        $global:FlacContent = $ReportContent
        Mock -ModuleName PwshMusicTools Get-Command { [PSCustomObject]@{ Name = $Name } } -ParameterFilter { $Name -in 'flaccheck.exe', 'ffmpeg', 'ffprobe' }
        Mock -ModuleName PwshMusicTools Invoke-FlacCheckScan {
            $global:FlacCalls.Add([PSCustomObject]@{ Path = $Path; Mode = $Mode; ReportPath = $ReportPath })
            if ($global:FlacContent) { [IO.File]::WriteAllText($ReportPath, $global:FlacContent) }
            [PSCustomObject]@{ ExitCode = 1; StdErr = '' }
        }
        Mock -ModuleName PwshMusicTools Open-FlacCheckReport { $global:FlacOpened.Add($Path) }
    }
}

AfterAll {
    Remove-Variable -Name FlacCalls, FlacOpened, FlacContent -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Invoke-FlacCheckScan command line' {
    It 'builds scan <path> --mode --format html -o --quiet --color never' {
        InModuleScope PwshMusicTools {
            function flaccheck.exe { $global:FlacArgs = $args; $global:LASTEXITCODE = 3 }
            try {
                $r = Invoke-FlacCheckScan -Path 'C:\in' -Mode 'max' -ReportPath 'C:\r.html'
                $global:FlacArgs | Should -Be @('scan', 'C:\in', '--mode', 'max', '--format', 'html', '-o', 'C:\r.html', '--quiet', '--color', 'never')
                $r.ExitCode | Should -Be 3
            }
            finally {
                Remove-Item Function:\flaccheck.exe
                Remove-Variable FlacArgs -Scope Global -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe 'Invoke-IncomingMusic -FlacCheck' {

    BeforeEach {
        $script:root = Join-Path (New-TestDir) 'incoming'
        New-Item -ItemType Directory -Path $script:root | Out-Null
        $script:outer = Split-Path $script:root -Parent
        Initialize-FlacMocks
    }

    AfterEach {
        Remove-TestDir -Path $script:outer
    }

    Context 'basic run' {
        It 'scans -Path in balanced mode, writes FlacCheck-<timestamp>.html beside the incoming root, and opens it' {
            New-Album -Relative 'Album' | Out-Null

            $r = @(Invoke-IncomingMusic -Path $root -FlacCheck -Confirm:$false 3>$null 6>$null | Where-Object Step -eq 'FlacCheck')

            $global:FlacCalls.Count | Should -Be 1
            $global:FlacCalls[0].Path | Should -Be $root
            $global:FlacCalls[0].Mode | Should -Be 'balanced'
            (Split-Path $global:FlacCalls[0].ReportPath -Parent) | Should -Be $outer
            (Split-Path $global:FlacCalls[0].ReportPath -Leaf) | Should -Match '^FlacCheck-\d{8}-\d{6}\.html$'
            $global:FlacOpened | Should -Be @($global:FlacCalls[0].ReportPath)
            $r.Count | Should -Be 1
            $r[0].ReportPath | Should -Be $global:FlacCalls[0].ReportPath
            $r[0].Ran | Should -BeTrue
            $r[0].Opened | Should -BeTrue
            $r[0].ExitCode | Should -Be 1   # non-zero exit is informational
        }

        It '-FlacCheckMode changes the mode' {
            New-Album -Relative 'Album' | Out-Null
            Invoke-IncomingMusic -Path $root -FlacCheck -FlacCheckMode max -Confirm:$false 3>$null 6>$null | Out-Null
            $global:FlacCalls[0].Mode | Should -Be 'max'
        }

        It 'rejects an invalid -FlacCheckMode' {
            { Invoke-IncomingMusic -Path $root -FlacCheck -FlacCheckMode turbo -Confirm:$false } | Should -Throw
        }

        It 'does nothing FlacCheck-related without -FlacCheck' {
            New-Album -Relative 'Album' | Out-Null
            $r = @(Invoke-IncomingMusic -Path $root -RemoveEmptyDirectories -Confirm:$false 3>$null 6>$null)
            $global:FlacCalls.Count | Should -Be 0
            $global:FlacOpened.Count | Should -Be 0
            @($r | Where-Object Step -eq 'FlacCheck').Count | Should -Be 0
        }

        It 'counts -FlacCheck as a requested step (no "no step" warning)' {
            New-Album -Relative 'Album' | Out-Null
            $w = Invoke-IncomingMusic -Path $root -FlacCheck -Confirm:$false 3>&1 6>$null |
                 Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
            ($w | Out-String) | Should -Not -Match 'No processing step'
        }
    }

    Context '-FlacCheckReportPath' {
        It 'uses the given path' {
            New-Album -Relative 'Album' | Out-Null
            $rp = Join-Path $outer 'mine.html'
            Invoke-IncomingMusic -Path $root -FlacCheck -FlacCheckReportPath $rp -Confirm:$false 3>$null 6>$null | Out-Null
            $global:FlacCalls[0].ReportPath | Should -Be $rp
            $global:FlacOpened | Should -Be @($rp)
        }

        It 'fails before anything runs or moves when the parent folder does not exist' {
            $album = New-Album -Relative 'Album'
            $err = $null
            Invoke-IncomingMusic -Path $root -FlacCheck -OrganizeByArtist -FlacCheckReportPath (Join-Path $outer 'nope\r.html') `
                -Confirm:$false -ErrorVariable err -ErrorAction SilentlyContinue 3>$null 6>$null | Out-Null
            ($err | Out-String) | Should -Match 'FlacCheckReportPath'
            $global:FlacCalls.Count | Should -Be 0
            Test-Path $album | Should -BeTrue
        }

        It 'fails when the path is a directory' {
            New-Album -Relative 'Album' | Out-Null
            $err = $null
            Invoke-IncomingMusic -Path $root -FlacCheck -FlacCheckReportPath $outer -Confirm:$false -ErrorVariable err -ErrorAction SilentlyContinue 3>$null 6>$null | Out-Null
            ($err | Out-String) | Should -Match 'is a directory'
            $global:FlacCalls.Count | Should -Be 0
        }
    }

    Context 'missing tool' {
        It 'fails early naming flaccheck.exe, with nothing moved or renamed' {
            $album = New-Album -Relative 'u\Album'
            Mock -ModuleName PwshMusicTools Get-Command { $null } -ParameterFilter { $Name -eq 'flaccheck.exe' }
            Mock -ModuleName PwshMusicTools Get-AudioTags { [PSCustomObject]@{ AlbumArtist = 'Band'; Artist = 'Band'; Track = 1 } }
            Mock -ModuleName PwshMusicTools Test-AudioIntegrity { }
            $err = $null

            Invoke-IncomingMusic -Path $root -AudioIntegrity -FlacCheck -OrganizeByArtist -Confirm:$false -ErrorVariable err -ErrorAction SilentlyContinue 3>$null 6>$null | Out-Null

            ($err | Out-String) | Should -Match 'flaccheck\.exe'
            Should -Invoke -ModuleName PwshMusicTools Test-AudioIntegrity -Times 0 -Exactly
            Test-Path $album | Should -BeTrue
            Test-Path (Join-Path $root 'Band') | Should -BeFalse
            $global:FlacCalls.Count | Should -Be 0
        }
    }

    Context 'ordering' {
        It 'runs after the integrity step and before -OrganizeByArtist moves anything' {
            $album = New-Album -Relative 'u\Album'
            $global:Order = [System.Collections.Generic.List[string]]::new()
            try {
                Mock -ModuleName PwshMusicTools Test-AudioIntegrity { $global:Order.Add('integrity') }
                Mock -ModuleName PwshMusicTools Get-AudioTags { [PSCustomObject]@{ AlbumArtist = 'Band'; Artist = 'Band'; Track = 1 } }
                Mock -ModuleName PwshMusicTools Invoke-FlacCheckScan {
                    $global:Order.Add('flaccheck:' + (Test-Path -LiteralPath (Join-Path $Path 'u\Album')))
                    [IO.File]::WriteAllText($ReportPath, 'x')
                    [PSCustomObject]@{ ExitCode = 0; StdErr = '' }
                }

                Invoke-IncomingMusic -Path $root -OrganizeByArtist -FlacCheck -AudioIntegrity -Confirm:$false 3>$null 6>$null | Out-Null

                $global:Order | Select-Object -Last 1 | Should -Be 'flaccheck:True'   # album still in place
                $global:Order.IndexOf('integrity') | Should -BeLessThan $global:Order.IndexOf('flaccheck:True')
                Test-Path (Join-Path $root 'Band\Album') | Should -BeTrue             # moved afterwards
            }
            finally { Remove-Variable Order -Scope Global -ErrorAction SilentlyContinue }
        }
    }

    Context 'corrupt files' {
        It 'scans the whole -Path once, even when -AudioIntegrity flagged a folder, and creates no temp junction folder' {
            $clean = New-Album -Relative 'Clean'
            $bad   = New-Album -Relative 'Bad'
            Mock -ModuleName PwshMusicTools Test-AudioIntegrity {
                if ($Path -like '*\Bad') {
                    [PSCustomObject]@{ File = (Join-Path $Path '02 b.flac'); Status = 'CORRUPT'; Detail = 'bad' }
                }
            }
            $tmp = [IO.Path]::GetTempPath()
            $before = @(Get-ChildItem $tmp -Filter 'FlacCheck-*' -Directory -ErrorAction SilentlyContinue).Name

            $r = @(Invoke-IncomingMusic -Path $root -AudioIntegrity -FlacCheck -Confirm:$false 3>$null 6>$null | Where-Object Step -eq 'FlacCheck')

            $global:FlacCalls.Count | Should -Be 1
            $global:FlacCalls[0].Path | Should -Be $root
            $r[0].Scanned | Should -Be @($root)
            @(Get-ChildItem $tmp -Filter 'FlacCheck-*' -Directory -ErrorAction SilentlyContinue).Name | Should -Be $before
            Test-Path (Join-Path $bad 'CORRUPTED 02 b.flac') | Should -BeTrue
            Test-Path $clean | Should -BeTrue
        }

        It 'scans the whole -Path when files carry a CORRUPTED prefix from an earlier run, without warning' {
            New-Album -Relative 'Clean' | Out-Null
            New-Album -Relative 'Old' -Files @('01 a.flac', 'CORRUPTED 02 b.flac') | Out-Null

            $w = Invoke-IncomingMusic -Path $root -FlacCheck -Confirm:$false 3>&1 6>$null |
                 Where-Object { $_ -is [System.Management.Automation.WarningRecord] }

            $global:FlacCalls.Count | Should -Be 1
            $global:FlacCalls[0].Path | Should -Be $root
            @($w).Count | Should -Be 0
        }

        It 'still scans when every folder holds corrupt files' {
            New-Album -Relative 'Old' -Files @('CORRUPTED 01 a.flac') | Out-Null
            Invoke-IncomingMusic -Path $root -FlacCheck -Confirm:$false 3>$null 6>$null | Out-Null
            $global:FlacCalls.Count | Should -Be 1
            $global:FlacCalls[0].Path | Should -Be $root
        }
    }
    Context 'opening the report' {
        It 'does not open a report that was not produced, and warns with exit code and stderr' {
            New-Album -Relative 'Album' | Out-Null
            Mock -ModuleName PwshMusicTools Invoke-FlacCheckScan { [PSCustomObject]@{ ExitCode = 2; StdErr = 'boom: bad input' } }

            $out = Invoke-IncomingMusic -Path $root -FlacCheck -Confirm:$false 3>&1 6>$null
            $w = $out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
            $r = $out | Where-Object { $_.PSObject.Properties['Step'] -and $_.Step -eq 'FlacCheck' }

            $global:FlacOpened.Count | Should -Be 0
            ($w | Out-String) | Should -Match 'no report was produced'
            ($w | Out-String) | Should -Match 'exit code 2'
            ($w | Out-String) | Should -Match 'boom: bad input'
            $r.Opened | Should -BeFalse
        }

        It 'does not open a stale report left at -FlacCheckReportPath when the scan writes nothing' {
            New-Album -Relative 'Album' | Out-Null
            $rp = Join-Path $outer 'stale.html'
            [IO.File]::WriteAllText($rp, 'old report')
            Mock -ModuleName PwshMusicTools Invoke-FlacCheckScan { [PSCustomObject]@{ ExitCode = 1; StdErr = '' } }

            $out = Invoke-IncomingMusic -Path $root -FlacCheck -FlacCheckReportPath $rp -Confirm:$false 3>&1 6>$null
            $w = $out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
            $r = $out | Where-Object { $_.PSObject.Properties['Step'] -and $_.Step -eq 'FlacCheck' }

            $global:FlacOpened.Count | Should -Be 0
            ($w | Out-String) | Should -Match 'no report was produced'
            $r.Opened | Should -BeFalse
        }

        It 'does not open an empty report' {
            New-Album -Relative 'Album' | Out-Null
            Mock -ModuleName PwshMusicTools Invoke-FlacCheckScan {
                New-Item -ItemType File -Path $ReportPath -Force | Out-Null
                [PSCustomObject]@{ ExitCode = 0; StdErr = '' }
            }
            Invoke-IncomingMusic -Path $root -FlacCheck -Confirm:$false 3>$null 6>$null | Out-Null
            $global:FlacOpened.Count | Should -Be 0
        }

        It 'opens the report when the tool exits non-zero but wrote it' {
            New-Album -Relative 'Album' | Out-Null
            Invoke-IncomingMusic -Path $root -FlacCheck -Confirm:$false 3>$null 6>$null | Out-Null   # mock exits 1
            $global:FlacOpened.Count | Should -Be 1
        }

        It 'treats a browser launch failure as a warning, not an error' {
            New-Album -Relative 'Album' | Out-Null
            Mock -ModuleName PwshMusicTools Open-FlacCheckReport { throw 'no handler' }
            $err = $null
            $w = Invoke-IncomingMusic -Path $root -FlacCheck -Confirm:$false -ErrorVariable err -ErrorAction Stop 3>&1 6>$null |
                 Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
            @($err | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] -and $_.FullyQualifiedErrorId -eq 'Microsoft.PowerShell.Commands.WriteErrorException' }).Count | Should -Be 0
            ($w | Out-String) | Should -Match 'could not open report'
        }

        It 'treats a failure to run the tool as a warning' {
            New-Album -Relative 'Album' | Out-Null
            Mock -ModuleName PwshMusicTools Invoke-FlacCheckScan { throw 'cannot start' }
            $w = Invoke-IncomingMusic -Path $root -FlacCheck -Confirm:$false 3>&1 6>$null |
                 Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
            ($w | Out-String) | Should -Match 'could not run flaccheck\.exe: cannot start'
            $global:FlacOpened.Count | Should -Be 0
        }
    }

    Context '-WhatIf' {
        It 'runs and opens nothing, and moves nothing' {
            $album = New-Album -Relative 'u\Album'
            Mock -ModuleName PwshMusicTools Get-AudioTags { [PSCustomObject]@{ AlbumArtist = 'Band'; Artist = 'Band'; Track = 1 } }

            $r = @(Invoke-IncomingMusic -Path $root -FlacCheck -OrganizeByArtist -WhatIf 3>$null 6>$null | Where-Object Step -eq 'FlacCheck')

            $global:FlacCalls.Count | Should -Be 0
            $global:FlacOpened.Count | Should -Be 0
            Test-Path $album | Should -BeTrue
            $r.Count | Should -Be 1
            $r[0].Ran | Should -BeFalse
            $r[0].Opened | Should -BeFalse
        }
    }
}
