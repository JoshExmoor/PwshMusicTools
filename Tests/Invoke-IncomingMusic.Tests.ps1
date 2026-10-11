BeforeAll {
    . $PSScriptRoot/TestHelpers.ps1
    Import-PwshMusicTools
}

Describe 'Invoke-IncomingMusic' {

    Context 'no step selected' {

        It 'warns and does nothing when no step switch is given' {
            $root = New-TestDir
            try {
                $warning = Invoke-IncomingMusic -Path $root 3>&1 | Out-String
                $warning | Should -Match 'No processing step'
            }
            finally { Remove-TestDir -Path $root }
        }
    }

    Context 'input validation' {

        It 'errors when the path is not a directory' {
            { Invoke-IncomingMusic -Path (Join-Path (New-TestDir) 'nope') -AudioIntegrity -ErrorAction Stop } |
                Should -Throw
        }
    }

    Context '-AudioIntegrity (mocked Test-AudioIntegrity and tooling)' {

        BeforeEach {
            $script:root = New-TestDir
            $script:album = Join-Path $root 'Album'
            New-EmptyFile -Dir $album -Name 'good.flac'    | Out-Null
            New-EmptyFile -Dir $album -Name 'bad.flac'     | Out-Null
            New-EmptyFile -Dir $album -Name 'unreadable.flac' | Out-Null

            # Make the ffmpeg/ffprobe presence check pass without the real tools.
            Mock -ModuleName PwshMusicTools Get-Command {
                [PSCustomObject]@{ Name = $Name }
            } -ParameterFilter { $Name -in 'ffmpeg', 'ffprobe' }

            # Return controlled integrity statuses for the album's files.
            Mock -ModuleName PwshMusicTools Test-AudioIntegrity {
                $dir = $Path
                @(
                    [PSCustomObject]@{ File = (Join-Path $dir 'good.flac');       Name = 'good.flac';       Status = 'OK';      Detail = '' }
                    [PSCustomObject]@{ File = (Join-Path $dir 'bad.flac');        Name = 'bad.flac';        Status = 'CORRUPT'; Detail = 'crc error' }
                    [PSCustomObject]@{ File = (Join-Path $dir 'unreadable.flac'); Name = 'unreadable.flac'; Status = 'ERROR';   Detail = 'ffmpeg crashed' }
                )
            }
        }

        AfterEach { Remove-TestDir -Path $script:root }

        It 'renames both CORRUPT and ERROR files with the CORRUPTED prefix' {
            Invoke-IncomingMusic -Path $root -AudioIntegrity -Confirm:$false | Out-Null

            Test-Path (Join-Path $album 'CORRUPTED bad.flac')        | Should -BeTrue
            Test-Path (Join-Path $album 'CORRUPTED unreadable.flac') | Should -BeTrue
        }

        It 'leaves OK files untouched' {
            Invoke-IncomingMusic -Path $root -AudioIntegrity -Confirm:$false | Out-Null

            Test-Path (Join-Path $album 'good.flac')           | Should -BeTrue
            Test-Path (Join-Path $album 'CORRUPTED good.flac') | Should -BeFalse
        }

        It 'returns a result object per flagged file with the right status' {
            $results = @(Invoke-IncomingMusic -Path $root -AudioIntegrity -Confirm:$false 6>$null)

            $results.Count | Should -Be 2
            ($results | Where-Object { $_.OriginalPath -like '*bad.flac' }).Status        | Should -Be 'CORRUPT'
            ($results | Where-Object { $_.OriginalPath -like '*unreadable.flac' }).Status | Should -Be 'ERROR'
            ($results | Where-Object { $_.OriginalPath -like '*bad.flac' }).Renamed       | Should -BeTrue
        }

        It 'does not rename anything under -WhatIf' {
            Invoke-IncomingMusic -Path $root -AudioIntegrity -WhatIf | Out-Null

            Test-Path (Join-Path $album 'bad.flac')          | Should -BeTrue
            Test-Path (Join-Path $album 'CORRUPTED bad.flac') | Should -BeFalse
        }

        It 'reports Renamed = $false under -WhatIf but still lists the file' {
            $results = @(Invoke-IncomingMusic -Path $root -AudioIntegrity -WhatIf 6>$null)

            $results.Count | Should -Be 2
            ($results | ForEach-Object { $_.Renamed }) | Should -Not -Contain $true
        }

        It 'is idempotent: does not double-prefix an already-flagged file' {
            # Pre-create a file that is already prefixed; the mock reports it CORRUPT.
            Mock -ModuleName PwshMusicTools Test-AudioIntegrity {
                @(
                    [PSCustomObject]@{ File = (Join-Path $Path 'CORRUPTED bad.flac'); Name = 'CORRUPTED bad.flac'; Status = 'CORRUPT'; Detail = 'still bad' }
                )
            }
            New-EmptyFile -Dir $album -Name 'CORRUPTED bad.flac' | Out-Null

            $results = @(Invoke-IncomingMusic -Path $root -AudioIntegrity -Confirm:$false 6>$null)

            # Nothing flagged (the only "bad" file is already prefixed and skipped).
            $results.Count | Should -Be 0
            Test-Path (Join-Path $album 'CORRUPTED CORRUPTED bad.flac') | Should -BeFalse
        }

        It 'writes an end-of-run summary listing the flagged files' {
            $host6 = Invoke-IncomingMusic -Path $root -AudioIntegrity -Confirm:$false 6>&1 | Out-String

            $host6 | Should -Match '2 file\(s\) flagged'
            $host6 | Should -Match 'bad.flac'
            $host6 | Should -Match 'unreadable.flac'
        }

        It 'reports a clean result when nothing is corrupt' {
            Mock -ModuleName PwshMusicTools Test-AudioIntegrity {
                @([PSCustomObject]@{ File = (Join-Path $Path 'good.flac'); Name = 'good.flac'; Status = 'OK'; Detail = '' })
            }

            $host6 = Invoke-IncomingMusic -Path $root -AudioIntegrity -Confirm:$false 6>&1 | Out-String

            $host6 | Should -Match 'no corrupt or unreadable files'
        }
    }

    Context '-AudioIntegrity missing tooling' {

        It 'errors when ffmpeg/ffprobe are not available' {
            $root = New-TestDir
            New-EmptyFile -Dir (Join-Path $root 'Album') -Name 'x.flac' | Out-Null
            try {
                Mock -ModuleName PwshMusicTools Get-Command { $null } -ParameterFilter { $Name -in 'ffmpeg', 'ffprobe' }

                { Invoke-IncomingMusic -Path $root -AudioIntegrity -ErrorAction Stop } |
                    Should -Throw -ExpectedMessage '*ffmpeg*'
            }
            finally { Remove-TestDir -Path $root }
        }
    }
}
